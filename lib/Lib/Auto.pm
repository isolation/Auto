# lib/Lib/Auto.pm - Core Auto subroutines.
# Copyright (C) 2010-2012 Xelhua Development Group, et al.
# This program is free software; rights to this code are stated in doc/LICENSE.
package Lib::Auto;
use strict;
use warnings;
use feature qw(say);
use English qw(-no_match_vars);
use Sys::Hostname;
use feature qw(switch);
use API::Std qw(hook_add conf_get err timer_add timer_del);
use API::Log qw(dbug alog);
use API::Socket qw(add_socket);
our $VERSION = 3.000000;
our (%RECONNECT_ATTEMPTS, %RECONNECT_TIMER);

use constant DEFAULT_RECONNECT_DELAY     => 5;
use constant DEFAULT_RECONNECT_MAX_DELAY => 300;

# Core events.
API::Std::event_add('on_shutdown');
API::Std::event_add('on_rehash');

# Update checker.
sub checkver {
    if (!$Auto::NUC and Auto::RSTAGE ne 'd') {
        say '* Connecting to update server...';
        my $uss = IO::Socket::IP->new(
            'Proto'    => 'tcp',
            'PeerAddr' => 'dist.ethrik.net',
            'PeerPort' => 80,
            'Timeout'  => 30
        ) or err(1, 'Cannot connect to update server! Aborting update check.');
        send $uss, "GET http://dist.ethrik.net/auto/version.txt\n", 0;
        my $dll = q{};
        while (my $data = readline $uss) {
            $data =~ s/(\n|\r)//g;
            my ($v, $c) = split m/[=]/, $data;

            if ($v eq 'url') {
                $dll = $c;
            }
            elsif ($v eq 'version') {
                if (Auto::VER.q{.}.Auto::SVER.q{.}.Auto::REV.Auto::RSTAGE ne $c) {
                    say('!!! NOTICE !!! Your copy of Auto is outdated. Current version: '.Auto::VER.q{.}.Auto::SVER.q{.}.Auto::REV.Auto::RSTAGE.' - Latest version: '.$c);
                    say('!!! NOTICE !!! You can get the latest Auto by downloading '.$dll);
                }
                else {
                    say('* Auto is up-to-date.');
                }
            }
        }
    }
}

# Checkin.
sub checkin {
    if ((conf_get('contact_home'))[0][0]) {
        my $getid = 0;
        my $uidfile = ($Auto::UPREFIX ? "$Auto::bin{etc}/auto.uid" : "$Auto::Bin/../etc/auto.uid");
        if (!-e $uidfile) { $getid = 1; }
        if ($getid) {
            say '* Connecting to master server...';
            my $uss = IO::Socket::IP->new(
                'Proto'    => 'tcp',
                'PeerAddr' => 'checkin.ethrik.net',
                'PeerPort' => 8082,
                'Timeout'  => 30
            ) or err(1, 'Cannot connect to master server! Aborting check-in.', 0) and return;
            send $uss, "NEWID\r\n", 0;
            while (my $data = readline $uss) {
                $data =~ s/(\n|\r)//g;
                if ($data =~ m/RESULT: (.*)/ixsm) {
                    if ($1 !~ m/ERR_/ixsm) {
                        if ($1 =~ m/ Your unique ID: (.*)/ism) {
                            say("* Detected new Auto install. Got UID: $1");
                            open my $FUID, '>', $uidfile or err(1, 'Cannot open UID file. Aborting check-in.');;
                            print {$FUID} $1 or err(1, 'Cannot write to UID file. Aborting check-in.');
                            close $FUID;
                        }
                    }
                    else {
                        err(1, "Master server returned error: $1. Aborting check-in.", 0);
                    }
                }
            }
        }
        open my $FUID, '<', $uidfile or err(1, 'Cannot open UID file. Aborting check-in.', 0) and return;
        my @FUID = <$FUID>;
        close $FUID;
        $Auto::CUID = $FUID[0];
        say '* Connecting to master server...';                                           
        my $uss = IO::Socket::IP->new(
            'Proto'    => 'tcp',
            'PeerAddr' => 'checkin.ethrik.net',
            'PeerPort' => 8082,
            'Timeout'  => 30
        ) or err(1, 'Cannot connect to master server! Aborting check-in.', 0) and return;
        my $version = Auto::VER.q{.}.Auto::SVER.q{.}.Auto::REV.Auto::RSTAGE;
        send $uss, "UPDATE $Auto::CUID $version $OSNAME\r\n", 0;
        while (my $data = readline $uss) {
            $data =~ s/(\n|\r)//g;
            if ($data =~ m/RESULT: (.*)/ixsm) {
                if ($1 !~ m/ERR_/ixsm) {
                    say("*$1");
                }
                else {
                    err(1, "Master server returned error: $1. Aborting check-in.", 0);
                }
            }
        }

    }
}

sub rehash {
    # Parse configuration file.
    my %newsettings = $Auto::CONF->parse or err(2, 'Failed to parse configuration file!', 0) and return;

    # Check for required configuration values.
    my @REQCVALS = qw(locale expire_logs server fantasy_pf ratelimit bantype loop);
    foreach my $REQCVAL (@REQCVALS) {
        if (!defined $newsettings{$REQCVAL}) {
            err(2, "Missing required configuration value: $REQCVAL", 0) and return;
        }
    }
    undef @REQCVALS;

    # Set new configuration.
    %Auto::SETTINGS = %newsettings;

    # Expire old logs.
    API::Log::expire_logs();

    # Parse privileges.
    my %PRIVILEGES;
    # If there are any privsets.
    if (conf_get('privset')) {
        # Get them.
        my %tcprivs = conf_get('privset');

        foreach my $tckpriv (keys %tcprivs) {
            # For each privset, get the inner values.
            my %mcprivs = conf_get("privset:$tckpriv");

            # Iterate through them.
            foreach my $mckpriv (keys %mcprivs) {
                # Switch statement for the values.
                given ($mckpriv) {
                    # If it's 'priv', save it as a privilege.
                    when ('priv') {
                        if (defined $PRIVILEGES{$tckpriv}) {
                            # If this privset exists, push to it.
                            for (0..@{($mcprivs{$mckpriv})[0]}) {
                                push @{ $PRIVILEGES{$tckpriv} }, ($mcprivs{$mckpriv})[0][$_];
                            }
                        }
                        else {
                            # Otherwise, create it.
                            @{ $PRIVILEGES{$tckpriv} } = (($mcprivs{$mckpriv})[0][0]);
                            if (scalar @{($mcprivs{$mckpriv})[0]} > 1) {
                                for (1..@{($mcprivs{$mckpriv})[0]}) {
                                    push @{ $PRIVILEGES{$tckpriv} }, ($mcprivs{$mckpriv})[0][$_];
                                }
                            }
                        }
                    }
                    # If it's 'inherit', inherit the privileges of another privset.
                    when ('inherit') {
                        # If the privset we're inheriting exists, continue.
                        if (defined $PRIVILEGES{($mcprivs{$mckpriv})[0][0]}) {
                            # Iterate through each privilege.
                            foreach (@{ $PRIVILEGES{($mcprivs{$mckpriv})[0][0]} }) {
                                # And save them to the privset inheriting them
                                if (defined $PRIVILEGES{$tckpriv}) {
                                    # If this privset exists, push to it.
                                    push @{ $PRIVILEGES{$tckpriv} }, $_;
                                }
                                else {
                                    # Otherwise, create it.
                                    @{ $PRIVILEGES{$tckpriv} } = ($_);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    %Auto::PRIVILEGES = %PRIVILEGES;

    # Load modules.
    if (conf_get('module')) {
        alog '* Loading modules...';
        foreach (@{ (conf_get('module'))[0] }) {
            if (!API::Std::mod_exists($_)) { my $module = Auto::mod_load($_); if ($module) { alog "* Module $_ failed to load: $module"; } else { alog "* Module $_ loaded."; } }
        }
    }

    ## Create sockets.
    alog '* Connecting to servers...';
    # Get servers from config.
    my %cservers = conf_get('server');
    # Iterate through each configured server.
    foreach my $cskey (keys %cservers) {
        if (!defined $Auto::SOCKET{$cskey}) {
            ircsock(\%{$cservers{$cskey}}, $cskey);
        }
    }

    # Check for server connections.
    if (!keys %Auto::SOCKET) {
        err(2, 'No IRC connections -- Retrying in the background.', 0);
        schedule_reconnect($_) foreach keys %cservers;
    }

    # Now trigger on_rehash.
    API::Std::event_run('on_rehash');

    return 1;
}

# Socket creation.
sub ircsock {
    my ($cdata, $svrname) = @_;

    # Set IPv6/SSL data.
    my $use6 = 0;
    my $usessl = 0;
    if (defined $cdata->{'ipv6'}[0]) { $use6 = $cdata->{'ipv6'}[0] }
    if (defined $cdata->{'ssl'}[0]) { $usessl = $cdata->{'ssl'}[0] }

    # Prepare socket data.
    my %conndata = (
        Proto => 'tcp',
        PeerAddr  => $cdata->{'host'}[0],
        PeerPort  => $cdata->{'port'}[0],
        Timeout   => 20,
        Domain    => ($use6 ? Socket::AF_INET6 : Socket::AF_INET)
    );

    # Check for appropriate build data.
    if ($usessl) {
        if ($Auto::ENFEAT !~ m/ssl/ixsm) { err(2, '** Auto not built with SSL support: Aborting connection to '.$svrname, 0); return }
    }

    # CertFP.
    if ($usessl) {
        if (defined $cdata->{'certfp'}[0]) {
            if ($cdata->{'certfp'}[0] eq 1) {
                $conndata{'SSL_use_cert'} = 1;
                if (defined $cdata->{'certfp_cert'}[0]) {
                    $conndata{'SSL_cert_file'} = "$Auto::bin{etc}/certs/".$cdata->{'certfp_cert'}[0];
                }
                if (defined $cdata->{'certfp_key'}[0]) {
                    $conndata{'SSL_key_file'} = "$Auto::bin{etc}/certs/".$cdata->{'certfp_key'}[0];
                }
                if (defined $cdata->{'certfp_pass'}[0]) {
                    $conndata{'SSL_passwd_cb'} = sub { return $cdata->{'certfp_pass'}[0] };
                }
            }
        }
    }

    # Set SSL cert verification mode.
    if ($usessl) {
        $conndata{'SSL_verify_mode'} = ($cdata->{'verify_ssl'}[0] ? 0x01 : 0x00);
    }

    # Create the socket.
    my $pkg = ($usessl ? 'IO::Socket::SSL' : 'IO::Socket');
    $conndata{LocalAddr} = $cdata->{'bind'}[0] if defined $cdata->{'bind'}[0]; 
    my $object = $pkg->new(%conndata) or say "$!" and return;
    add_socket($svrname, $object, \&Proto::IRC::ircparse) or return;

    # Create a CAP entry if it doesn't already exist.
    if (!$Proto::IRC::cap{$svrname}) { $Proto::IRC::cap{$svrname} = 'multi-prefix' }
    # Send PASS if we have one.
    if (defined $cdata->{'pass'}[0]) {
        Auto::socksnd($svrname, 'PASS :'.$cdata->{'pass'}[0]) or return;
    }
    # Send CAP LS.
    Auto::socksnd($svrname, 'CAP LS');
    # Trigger on_preconnect.
    API::Std::event_run('on_preconnect', $svrname);
    # Send NICK/USER.
    API::IRC::nick($svrname, $cdata->{'nick'}[0]);
    Auto::socksnd($svrname, 'USER '.$cdata->{'ident'}[0].q{ }.hostname.q{ }.$cdata->{'host'}[0].' :'.$cdata->{'realname'}[0]) or return;
    # Success!
    alog '** Successfully connected to server: '.$svrname;
    dbug '** Successfully connected to server: '.$svrname;

    return 1;
}

sub _config_number {
    my ($svr, $name, $default) = @_;
    my @value = conf_get("server:$svr:$name");
    @value = conf_get($name) if !@value or !defined $value[0];
    return $default if !@value or !defined $value[0] or
        !defined $value[0][0] or $value[0][0] <= 0;
    return $value[0][0];
}

sub schedule_reconnect {
    my ($svr) = @_;
    return if defined $Auto::SOCKET{$svr} or defined $RECONNECT_TIMER{$svr};

    my %servers = conf_get('server');
    return if !defined $servers{$svr};

    my $attempt = $RECONNECT_ATTEMPTS{$svr} || 0;
    my $delay = _config_number($svr, 'reconnect_delay', DEFAULT_RECONNECT_DELAY);
    my $maximum = _config_number($svr, 'reconnect_max_delay', DEFAULT_RECONNECT_MAX_DELAY);
    my $remaining_attempts = $attempt;
    while ($remaining_attempts-- > 0 and $delay < $maximum) { $delay *= 2 }
    $delay = $maximum if $delay > $maximum;
    $RECONNECT_ATTEMPTS{$svr} = $attempt + 1;

    my $safe_svr = $svr;
    $safe_svr =~ s/[^a-z0-9_]/_/ig;
    my $timer_name = join('_', 'irc_reconnect', $safe_svr, $attempt);
    $RECONNECT_TIMER{$svr} = $timer_name;
    alog "* Reconnecting to $svr in $delay seconds.";
    dbug "* Reconnecting to $svr in $delay seconds.";

    timer_add($timer_name, 1, $delay, sub {
        delete $RECONNECT_TIMER{$svr};
        return 1 if defined $Auto::SOCKET{$svr};
        my %current_servers = conf_get('server');
        return 1 if !defined $current_servers{$svr};
        if (!ircsock(\%{$current_servers{$svr}}, $svr)) {
            schedule_reconnect($svr);
        }
        return 1;
    });
    return 1;
}

sub connection_ready {
    my ($svr) = @_;
    if (defined $RECONNECT_TIMER{$svr}) {
        timer_del($RECONNECT_TIMER{$svr});
        delete $RECONNECT_TIMER{$svr};
    }
    delete $RECONNECT_ATTEMPTS{$svr};
    return 1;
}

# Shutdown.
hook_add('on_shutdown', 'shutdown.core_cleanup', sub {
    if (defined $Auto::DB) { $Auto::DB->disconnect }
    if ($Auto::UPREFIX) { if (-e "$Auto::bin{cwd}/auto.pid") { unlink "$Auto::bin{cwd}/auto.pid" } }
    else { if (-e "$Auto::Bin/auto.pid") { unlink "$Auto::Bin/auto.pid" } }
    return 1;
});

###################
# Signal handlers #
###################

# SIGTERM
sub signal_term {
    API::Std::event_run('on_sigterm');
    API::Std::event_run('on_shutdown');
    foreach (keys %Auto::SOCKET) { API::IRC::quit($_, 'Caught SIGTERM') if Auto::is_ircsock($_); }
    dbug '!!! Caught SIGTERM; terminating...';
    alog '!!! Caught SIGTERM; terminating...';
    sleep 1;
    exit;
}

# SIGINT
sub signal_int {
    API::Std::event_run('on_sigint');
    API::Std::event_run('on_shutdown');
    foreach (keys %Auto::SOCKET) { API::IRC::quit($_, 'Caught SIGINT') if Auto::is_ircsock($_); }
    dbug '!!! Caught SIGINT; terminating...';
    alog '!!! Caught SIGINT; terminating...';
    sleep 1;
    exit;
}

# SIGHUP
sub signal_hup {
    dbug '!!! Caught SIGHUP; rehashing';
    alog '!!! Caught SIGHUP; rehashing';
    rehash();
    API::Std::event_run('on_sighup');
    return 1;
}

# __WARN__
sub signal_perlwarn {
    my ($warnmsg) = @_;
    $warnmsg =~ s/(\n|\r)//xsmg;
    alog 'Perl Warning: '.$warnmsg;
    if ($Auto::DEBUG) { say 'Perl Warning: '.$warnmsg }
    return 1;
}

# __DIE__
sub signal_perldie {
    my ($diemsg) = @_;
    $diemsg =~ s/(\n|\r)//xsmg;

    return if $EXCEPTIONS_BEING_CAUGHT;
    alog 'Perl Fatal: '.$diemsg.' -- Terminating program!';
    foreach (keys %Auto::SOCKET) { API::IRC::quit($_, 'A fatal error occurred!') if Auto::is_ircsock($_); }
    API::Std::event_run('on_shutdown');
    sleep 1;
    say 'FATAL: '.$diemsg;
    exit;
}


1;
# vim: set ai et sw=4 ts=4:
