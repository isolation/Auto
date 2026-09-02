# lib/Core/IRC.pm - Core IRC hooks and timers.
# Copyright (C) 2010-2012 Xelhua Development Group, et al.
# This program is free software; rights to this code are stated in doc/LICENSE.
                     # Trigger event on_cprivmsg.
package Core::IRC;
use strict;
use warnings;
use English qw(-no_match_vars);
use API::Std qw(hook_add timer_add conf_get trans);
use API::IRC qw(notice usrc);

# Events.
API::Std::event_add('on_cprivmsg');
API::Std::event_add('on_uprivmsg');

our (%usercmd);

# PRIVMSG parser for commands.
hook_add('on_privmsg', 'irc.privmsg.parse', sub {
    my ($src, @ex) = @_;
    my %data = %$src;
    my @argv;
    for (my $i = 4; $i < scalar(@ex); $i++) {
        push(@argv, $ex[$i]);
    }
    $data{target} = $data{nick};
    my ($cmd, $cprefix, $rprefix);
    # Check if it's to a channel or to us.
    if (lc($ex[2]) eq lc($State::IRC::botinfo{$src->{svr}}{nick})) {
        # It is coming to us in a private message.

        # Check for a prefix.
        $cprefix = (conf_get('fantasy_pf'))[0][0];

        # Ensure it's a valid length.
        if (length($ex[3]) > 2) {
            $cmd = uc substr $ex[3], 1;
            if (substr($cmd, 0, 1) eq $cprefix) { $cmd = substr $cmd, 1 }
            if (defined $API::Std::CMDS{$cmd}) {
                # If this is indeed a command, continue.
                if ($API::Std::CMDS{$cmd}{lvl} == 1 or $API::Std::CMDS{$cmd}{lvl} == 2) {
                    # Ensure the level is private or all.
                    if (API::Std::ratelimit_check(%data)) {
                        # Continue if the user has not passed the ratelimit amount.
                        if ($API::Std::CMDS{$cmd}{priv}) {
                            # If this command requires a privilege...
                            if (API::Std::has_priv(API::Std::match_user(%data), $API::Std::CMDS{$cmd}{priv})) {
                                # Make sure they have it.
                                &{ $API::Std::CMDS{$cmd}{'sub'} }(\%data, @argv);
                            }
                            else {
                                # Else give them the boot.
                                notice($data{svr}, $data{nick}, API::Std::trans("Permission denied").".");
                            }
                        }
                        else {
                            # Else execute the command without any extra checks.
                            &{ $API::Std::CMDS{$cmd}{'sub'} }(\%data, @argv);
                        }
                    }
                    else {
                        # Send them a notice about their bad deed.
                        notice($data{svr}, $data{nick}, trans('Rate limit exceeded').q{.});
                    }
                }
            }
        }

        # Trigger event on_uprivmsg.
        shift @ex; shift @ex; shift @ex;
        $ex[0] = substr $ex[0], 1;
        API::Std::event_run("on_uprivmsg", (\%data, @ex));
    }
    else {
        # It is coming to us in a channel message.
        $data{chan} = $ex[2];
        $data{target} = $ex[2];
        # Ensure it's a valid length before continuing.
        if (length($ex[3]) > 1) {
            $cprefix = (conf_get("fantasy_pf"))[0][0];
            $rprefix = substr($ex[3], 1, 1);
            $cmd = uc(substr($ex[3], 2));
            if (defined $API::Std::CMDS{$cmd} and $rprefix eq $cprefix) {
                # If this is indeed a command, continue.
                if ($API::Std::CMDS{$cmd}{lvl} == 0 or $API::Std::CMDS{$cmd}{lvl} == 2) {
                    # Ensure the level is public or all.
                    if (API::Std::ratelimit_check(%data)) {
                        # Continue if the user has not passed the ratelimit amount.
                        if ($API::Std::CMDS{$cmd}{priv}) {
                            # If this command takes a privilege...
                            if (API::Std::has_priv(API::Std::match_user(%data), $API::Std::CMDS{$cmd}{priv})) {
                                # Make sure they have it.
                                &{ $API::Std::CMDS{$cmd}{'sub'} }(\%data, @argv);
                            }
                            else {
                                # Else give them the boot.
                                notice($data{svr}, $data{nick}, API::Std::trans('Permission denied').q{.});
                            }
                        }
                        else {
                            # Else continue executing without any extra checks.
                            &{ $API::Std::CMDS{$cmd}{'sub'} }(\%data, @argv);
                        }
                    }
                    else {
                        # Send them a notice about their bad deed.
                        notice($data{svr}, $data{nick}, trans('Rate limit exceeded').q{.});
                    }
                }
                elsif ($API::Std::CMDS{$cmd}{lvl} == 3) {
                    # Or if it's a logchan command...
                    my ($lcn, $lcc) = split '/', (conf_get('logchan'))[0][0];
                    if ($lcn eq $data{svr} and lc $lcc eq lc $data{chan}) {
                        # Check if it's being sent from the logchan.
                        if ($API::Std::CMDS{$cmd}{priv}) {
                            # If this command takes a privilege...
                            if (API::Std::has_priv(API::Std::match_user(%data), $API::Std::CMDS{$cmd}{priv})) {
                                # Make sure they have it.
                                &{ $API::Std::CMDS{$cmd}{'sub'} }(\%data, @argv);
                            }
                            else {
                                # Else give them the boot.
                                notice($data{svr}, $data{nick}, API::Std::trans('Permission denied').q{.});
                            }
                        }
                        else {
                            # Else continue executing without any extra checks.
                            &{ $API::Std::CMDS{$cmd}{'sub'} }(\%data, @argv);
                        }
                    }
                }
            }
        }

        # Trigger event on_cprivmsg.
        my $target = $ex[2]; delete $data{chan};
        shift @ex; shift @ex; shift @ex;
        $ex[0] = substr $ex[0], 1;
        API::Std::event_run("on_cprivmsg", (\%data, $target, @ex));
    }

    return 1;
}, 1);

# Command alias parsing for channel messages.
hook_add('on_cprivmsg', 'irc.commands.aliases', sub {
    my ($src, $chan, $cmd, @args) = @_;

    # Check for valid length.
    if (length $cmd >= 2) {
        my $ipref = substr $cmd, 0, 1, q{};
        my $upref = (conf_get('fantasy_pf'))[0][0];
        # Check if the prefix is valid.
        if ($upref eq $ipref) {
            # It is, check for an alias.
            if (defined $API::Std::ALIASES{uc $cmd}) {
                # Get aliased command.
                my @actual;
                if ($API::Std::ALIASES{uc $cmd} =~ m/ /xsm) { @actual = split /\s/xsm, $API::Std::ALIASES{uc $cmd} }
                else { @actual = ($API::Std::ALIASES{uc $cmd}) }
                # Prepare data.
                my @msg = (
                        q{:}.$src->{nick}.q{!}.$src->{user}.q{@}.$src->{host},
                        'PRIVMSG',
                        $chan,
                        q{:}.$upref.$actual[0],
                );
                # Rest of the data.
                if (scalar @actual > 1) { for (1..$#actual) { push @msg, $actual[$_] } }
                if (defined $args[0]) { foreach (@args) { push @msg, $_ } }
                # Simulate a PRIVMSG.
                Proto::IRC::privmsg($src->{svr}, @msg);
            }
        }
    }

    return 1;
}, 1);
                        
# Command alias parsing for private messages.
hook_add('on_uprivmsg', 'irc.commands.aliases', sub {
    my ($src, $cmd, @args) = @_;
    my $cprefix = (conf_get('fantasy_pf'))[0][0];
    if (substr($cmd, 0, 1) eq $cprefix) { $cmd = substr $cmd, 1 }

    # Check for an alias.
    if (defined $API::Std::ALIASES{uc $cmd}) {
        # Get aliased command.
        my @actual;
        if ($API::Std::ALIASES{uc $cmd} =~ m/ /xsm) { @actual = split /\s/xsm, $API::Std::ALIASES{uc $cmd} }
        else { @actual = ($API::Std::ALIASES{uc $cmd}) }
        # Prepare data.	
        my @msg = (
            q{:}.$src->{nick}.q{!}.$src->{user}.q{@}.$src->{host},
            'PRIVMSG',
            $State::IRC::botinfo{$src->{svr}}{nick},
            q{:}.$actual[0],
        );
        # Rest of the data.
        if (scalar @actual > 1) { for (1..$#actual) { push @msg, $actual[$_] } }
        if (defined $args[0]) { foreach (@args) { push @msg, $_ } }
        # Simulate a PRIVMSG.
        Proto::IRC::privmsg($src->{svr}, @msg);
    }

    return 1;
}, 1);

# CTCP VERSION reply.
hook_add('on_uprivmsg', 'ctcp_replies.version', sub {
    my ($src, @msg) = @_;

    if ($msg[0] eq "\001VERSION\001") {
        if (Auto::RSTAGE ne 'd') {
            notice($src->{svr}, $src->{nick}, "\001VERSION ".Auto::NAME." ".Auto::VER.".".Auto::SVER.".".Auto::REV.Auto::RSTAGE." $OSNAME\001");
        }
        else {
            notice($src->{svr}, $src->{nick}, "\001VERSION ".Auto::NAME." ".Auto::VER.".".Auto::SVER.".".Auto::REV.Auto::RSTAGE."-$Auto::VERGITREV $OSNAME\001");
        }
    }

    return 1;
}, 1);

# CTCP TIME reply.
hook_add('on_uprivmsg', 'ctcp_replies.time', sub {
    my ($src, @msg) = @_;

    if ($msg[0] eq "\001TIME\001") {
        notice($src->{svr}, $src->{nick}, "\001TIME ".POSIX::strftime('%a %b %d %H:%M:%S %Y', localtime)."\001");
    }

    return 1;
}, 1);
                        
# QUIT hook; delete user from chanusers.
hook_add('on_quit', 'state.chanusers_update.quit', sub {
    my ($src, undef) = @_;
    my %src = %{ $src };

    # Delete the user from all channels.
    foreach my $ccu (keys %{ $State::IRC::chanusers{$src{svr}}}) {
        if (defined $State::IRC::chanusers{$src{svr}}{$ccu}{lc $src{nick}}) { delete $State::IRC::chanusers{$src{svr}}{$ccu}{lc $src{nick}} }
    }
    if (defined $State::IRC::userinfo{$src{svr}}{lc $src{nick}}) {
        delete $State::IRC::userinfo{$src{svr}}{lc $src{nick}};
    }

    return 1;
}, 1);

# Modes on connect.
hook_add('on_connect', 'connect.set_umodes', sub {
    my ($svr) = @_;

    if (conf_get("server:$svr:modes")) {
        my $connmodes = (conf_get("server:$svr:modes"))[0][0];
        API::IRC::umode($svr, $connmodes);
    }

    return 1;
}, 1);

# Self-WHO on connect.
hook_add('on_connect', 'connect.self_who', sub {
    my ($svr) = @_;

    API::IRC::who($svr, $State::IRC::botinfo{$svr}{nick});

    return 1;
}, 1);

# Plaintext auth.
hook_add('on_connect', 'connect.auth.plaintext', sub {
    my ($svr) = @_;
    
    if (conf_get("server:$svr:idstr")) {
        my $idstr = (conf_get("server:$svr:idstr"))[0][0];
        Auto::socksnd($svr, $idstr);
    }

    return 1;
}, 1);

# WHO reply.
hook_add('on_whoreply', 'state.self_who.parse', sub {
    my ($svr, $nick, undef, $user, $mask, undef, undef, undef, undef) = @_;

    # Check if it's for us.
    if ($nick eq $State::IRC::botinfo{$svr}{nick}) {
        # It is. Set data.
        $State::IRC::botinfo{$svr}{user} = $user;
        $State::IRC::botinfo{$svr}{mask} = $mask;
    }

    return 1;
}, 1);

# Auto join.
hook_add('on_connect', 'autojoin', sub {
    my ($svr) = @_;

    # Get the auto-join from the config.
    return if !conf_get("server:$svr:ajoin");
    my @cajoin = @{ (conf_get("server:$svr:ajoin"))[0] };
    
    # Join the channels.
    if (!defined $cajoin[1]) {
        # For single-line ajoins.
        my @sajoin = split(',', $cajoin[0]);
        
        foreach (@sajoin) {
            # Check if a key was specified.
            if ($_ =~ m/\s/xsm) {
                # There was, join with it.
                my ($chan, $key) = split / /;
                API::IRC::cjoin($svr, $chan, $key);
            }
            else {
                # Else join without one.
                API::IRC::cjoin($svr, $_);
            }
        }
    }
    else {
        # For multi-line ajoins.
        foreach (@cajoin) {
            # Check if a key was specified.
            if ($_ =~ m/\s/xsm) {
                # There was, join with it.
                my ($chan, $key) = split / /;
                API::IRC::cjoin($svr, $chan, $key);
            }
            else {
                # Else join without one.
                API::IRC::cjoin($svr, $_);
            }
        }
    }
    # And logchan, if applicable.
    if (conf_get('logchan')) {
        my ($lcn, $lcc) = split '/', (conf_get('logchan'))[0][0];
        if ($lcn eq $svr) {
            API::IRC::cjoin($svr, $lcc);
        }
    }

    return 1;
}, 1);

# ISUPPORT - Set prefixes and channel modes.
hook_add('on_isupport', 'state.svrmodes.parse', sub {
    my (($svr, @ex)) = @_;

    # Find PREFIX and CHANMODES.
    foreach my $ex (@ex) {
        if ($ex =~ m/^PREFIX/xsm) {
            # Found PREFIX.
            my $rpx = substr($ex, 8);
            my ($pm, $pp) = split('\)', $rpx);
            my @apm = split(//, $pm);
            my @app = split(//, $pp);
            foreach my $ppm (@apm) {
                # Store data.
                $Proto::IRC::csprefix{$svr}{$ppm} = shift(@app);
            }
        }
        elsif ($ex =~ m/^CHANMODES/xsm) {
            # Found CHANMODES.
            my ($mtl, $mtp, $mtpp, $mts) = split m/[,]/xsm, substr($ex, 10);
            # List modes.
            foreach (split(//, $mtl)) { $Proto::IRC::chanmodes{$svr}{$_} = 1 }
            # Modes with parameter.
            foreach (split(//, $mtp)) { $Proto::IRC::chanmodes{$svr}{$_} = 2 }
            # Modes with parameter when +.
            foreach (split(//, $mtpp)) { $Proto::IRC::chanmodes{$svr}{$_} = 3 }
            # Modes without parameter.
            foreach (split(//, $mts)) { $Proto::IRC::chanmodes{$svr}{$_} = 4 }
        }
    }

    return 1;
}, 1);

sub clear_usercmd_timer {
    # If ratelimit is set to 1 in config, add this timer.
    if ((conf_get('ratelimit'))[0][0] eq 1) {
        # Clear usercmd hash every X seconds.
        timer_add('clear_usercmd', 2, (conf_get('ratelimit_time'))[0][0], sub {
            foreach (keys %Core::IRC::usercmd) {
                $Core::IRC::usercmd{$_} = 0;
            }

            return 1;
        });
    }

    return 1;
}

# Server data deletion on disconnect.
hook_add('on_disconnect', 'state.svrlist.del', sub {
    my ($svr) = @_;

    # Delete all data related to the server.
    if (defined $Proto::IRC::got_001{$svr}) { delete $Proto::IRC::got_001{$svr} }
    if (defined $State::IRC::botinfo{$svr}) { delete $State::IRC::botinfo{$svr} }
    if (defined $Proto::IRC::botchans{$svr}) { delete $Proto::IRC::botchans{$svr} }
    if (defined $State::IRC::chanusers{$svr}) { delete $State::IRC::chanusers{$svr} }
    if (defined $State::IRC::userinfo{$svr}) { delete $State::IRC::userinfo{$svr} }
    if (defined $Proto::IRC::csprefix{$svr}) { delete $Proto::IRC::csprefix{$svr} }
    if (defined $Proto::IRC::chanmodes{$svr}) { delete $Proto::IRC::chanmodes{$svr} }
    if (defined $Proto::IRC::cap{$svr}) { delete $Proto::IRC::cap{$svr} }

    return 1;
}, 1);

# Reconnect after socket and IRC state have been cleaned up.
hook_add('on_disconnect', 'connection.reconnect', sub {
    my ($svr) = @_;
    Lib::Auto::schedule_reconnect($svr);
    return 1;
}, 2);

# Track our usermodes.
hook_add('on_umode', 'state.self_umodes', sub {
    my (($svr, $modes)) = @_;

    # Remove anything after a space.
    $modes =~ s/(\s.*)//xsm;

    # Split the modes.
    my @modes = split //, $modes;

    # Set operator to 1.
    my $op = 1;
    # Iterate through the modes.
    foreach (@modes) {
        if ($_ eq '-') { $op = 0 }
        elsif ($_ eq '+') { $op = 1 }
        else {
            # Adjust our modes.
            if ($op) {
                $State::IRC::botinfo{$svr}{modes} .= $_;
            }
            else {
                $State::IRC::botinfo{$svr}{modes} =~ s/($_)//xsm;
            }
        }
    }

    return 1;
}, 1);


1;
# vim: set ai et sw=4 ts=4:
