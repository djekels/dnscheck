#!/usr/bin/perl
#
# $Id: $
#
# Copyright (c) 2007 .SE (The Internet Infrastructure Foundation).
#                    All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
# GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
# IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
# IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
######################################################################
use 5.8.0;

use warnings;
use strict;

use DNSCheck;

use Getopt::Long;
use Sys::Syslog;
use POSIX ":sys_wait_h";
use Time::HiRes 'sleep';

use vars qw[
  %running
  %reaped
  %problem
  $debug
  $verbose
  $check
  $limit
  $running
];

%running = ();
%reaped  = ();
%problem = ();
$debug   = 0;
$verbose = 0;
$check   = DNSCheck->new;
$limit   = $check->config->get("daemon")->{maxchild};
$running = 1;

# Kick everything off
main();

################################################################
# Utility functions and program setup
################################################################

sub slog {
    my $priority = shift;

    # See perldoc on sprintf for why we have to write it like this
    my $msg = sprintf($_[0], @_[1 .. $#_]);

    printf("%s (%d): %s\n", uc($priority), $$, $msg) if $debug;
    syslog($priority, @_);
}

sub setup {
    my $errfile = $check->config->get("daemon")->{errorlog};
    my $pidfile = $check->config->get("daemon")->{pidfile};

    GetOptions('debug' => \$debug, 'verbose' => \$verbose);
    openlog($check->config->get("syslog")->{ident},
        'pid', $check->config->get("syslog")->{facility});
    slog 'info', "$0 starting.";
    detach() unless $debug;
    open STDERR,  '>>', $errfile or die "Failed to open error log: $!";
    open PIDFILE, '>',  $pidfile or die "Failed to open PID file: $!";
    print PIDFILE $$;
    close PIDFILE;
    $SIG{CHLD} = \&REAPER;
    $SIG{TERM} = sub { $running = 0 };
}

sub detach
{  # Instead of using ioctls and setfoo calls we use the old double-fork method.
    my $pid;

    # Once...
    $pid = fork;
    exit if $pid;
    die "Fork failed: $!" unless defined($pid);

    # ...and again
    $pid = fork;
    exit if $pid;
    die "Fork failed: $!" unless defined($pid);
    slog('info', 'Detached.');
}

################################################################
# Dispatcher
################################################################

sub dispatch {
    my $domain;

    if (scalar keys %running < $limit) {
        $domain = get_entry();
        slog 'debug', "Fetched $domain from database." if defined($domain);
    } else {

        # slog 'info', 'Process limit reached.';
    }

    if (defined($domain)) {
        process($domain);
        return 0.0;
    } else {
        return 0.25;
    }
}

sub get_entry {
    my $dbh = $check->dbh;
    my ($id, $domain);

    do eval {
        $dbh->begin_work;
        ($id, $domain) = $dbh->selectrow_array(
q[SELECT id, domain FROM queue WHERE inprogress IS NULL ORDER BY priority DESC, id ASC LIMIT 1 FOR UPDATE]
        );
        $dbh->do(q[UPDATE queue SET inprogress = NOW() WHERE id = ?],
            undef, $id);
        $dbh->commit;
    };
    if ($@) {
        slog 'warn', "Database error in get_entry: $@";
        return undef;
    }

    return $domain;
}

sub process {
    my $domain = shift;

    my $pid = fork;

    if ($pid) {    # True values, so parent
        $running{$pid} = $domain;
        slog 'debug', "Child process $pid has been started.";
    } elsif ($pid == 0) {    # Zero value, so child
        running_in_child($domain);
    } else {                 # Undefined value, so error
        die "Fork failed: $!";
    }
}

sub running_in_child {
    my $domain = shift;

    # Reuse the old configuration, but get new everything else.
    my $dc  = DNSCheck->new({ with_config_object => $check->config });
    my $dbh = $dc->dbh;
    my $log = $dc->logger;

    $dbh->do(q[INSERT INTO tests (domain,begin) VALUES (?,NOW())],
        undef, $domain);

    my $test_id = $dbh->{'mysql_insertid'};
    my $line    = 0;

    $dc->zone->test($domain);

    my $sth = $dbh->prepare(
        q[
        INSERT INTO results
          (test_id,line,module_id,parent_module_id,timestamp,level,message,
          arg0,arg1,arg2,arg3,arg4,arg5,arg6,arg7,arg8,arg9)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ]
    );
    while (defined(my $e = $log->get_next_entry)) {
        next if ($e->{level} eq 'DEBUG');
        $line++;
        $sth->execute(
            $test_id,               $line,           $e->{module_id},
            $e->{parent_module_id}, $e->{timestamp}, $e->{level},
            $e->{tag},              $e->{arg}[0],    $e->{arg}[1],
            $e->{arg}[2],           $e->{arg}[3],    $e->{arg}[4],
            $e->{arg}[5],           $e->{arg}[6],    $e->{arg}[7],
            $e->{arg}[8],           $e->{arg}[9],
        );
    }

    $dbh->do(
q[UPDATE tests SET end = NOW(), count_critical = ?, count_error = ?, count_warning = ?, count_notice = ?, count_info = ?
  WHERE id = ?],
        undef, $log->count_critical, $log->count_error, $log->count_warning,
        $log->count_notice, $log->count_info, $test_id
    );

# Everything went well, so exit nicely (if they didn't go well, we've already died not-so-nicely).
    exit(0);
}

################################################################
# Child process handling
################################################################

sub monitor_children {
    my @pids = keys
      %reaped;    # Can't trust %reaped to stay static while we work through it

    foreach my $pid (@pids) {
        slog 'debug', "Child process $pid has died.";

        my $domain   = $running{$pid};
        my $exitcode = $reaped{$pid};
        delete $running{$pid};
        delete $reaped{$pid};
        cleanup($domain, $exitcode);
    }
}

sub cleanup {
    my $domain   = shift;
    my $exitcode = shift;
    my $dbh      = $check->dbh;

    my $status = $exitcode >> 8;
    my $signal = $exitcode & 127;

    if ($status == 0) {

        # Child died nicely.
        $dbh->do(q[DELETE FROM queue WHERE domain = ?], undef, $domain);
    } else {

        # Child blew up. Clean up.
        $problem{$domain} += 1;
        slog 'warning', "Unclean exit when testing $domain (status $status).";
        $dbh->do(q[UPDATE queue SET inprogress = NULL WHERE domain = ?],
            undef, $domain);
        $dbh->do(
q[DELETE FROM tests WHERE begin IS NOT NULL AND end IS NULL AND domain = ?],
            undef, $domain
        );
    }
}

sub REAPER {
    my $child;

    while (($child = waitpid(-1, WNOHANG)) > 0) {
        $reaped{$child} = $?;
    }
    $SIG{CHLD} = \&REAPER;
}

################################################################
# Main program
################################################################

sub main {
    setup();
    while ($running) {
        my $skip = dispatch();
        monitor_children();
        sleep($skip);
    }
    slog 'info', "Waiting for %d children to exit.", scalar keys %running;
    monitor_children until (keys %running == 0);
    unlink $check->config->get("daemon")->{pidfile};
    slog 'info', "$0 exiting normally.";
}

__END__

=head1 NAME

dnscheck-dispatcher - daemon program to run tests from a database queue

=head2 SYNOPSIS

    dnscheck-dispatcher [--debug]
    
=head2 DESCRIPTION

This daemon puts itself into the background (unless the --debug flag is given)
and repeatedly queries the table C<queue> in the configured database for
domains to test. When it gets one, it spawns a new process to run the tests.
If there are no domains to check, or if the configured maximum number of
active child processes has been reached, it sleeps 0.25 seconds and then tries
again. It keeps doing this until it is terminated by a SIGTERM. At that point,
it will wait until all children have died and cleanups been performed before it
removes its PID file and then exits.

=head2 OPTIONS

=over

=item --debug

Prevents the daemon from going into the background and duplicates log
information to standard output (it still goes to syslog as well).

=back

=head1 CONFIGURATION

L<dnscheck-dispatcher> shares configuration files with the L<DNSCheck> perl
modules. Or, to be more precise, it creates such an object and then queries
its configuration object for its configuration information. It also uses the
L<DNSCheck> object to get its database connection.

There are two keys in the configuration YAML files that are of interest for
the dispatcher. The first one is C<syslog>. It has the subkeys C<ident>, which
specifies the name the daemon will use when talking to syslogd, and
C<facility>, which specifies the syslog facility to use.

The second one is C<daemon>. It has the subkeys C<pidfile>, C<errorlog> and
C<maxchild>. They specify, in order, the file where the daemon will write its
PID after it has detached, the file it will redirect its standard error to and
the maximum number of concurrent child processes it may have. Make sure to set
the pathnames to values where the user the daemon is running under has write
permission, since it will terminated if they are specified but can't be
written to.

If everything works as intended nothing should ever be written to the
errorlog. All normal log outout goes to syslog (and, with the debug flag,
standard output).