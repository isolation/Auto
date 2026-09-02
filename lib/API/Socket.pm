# lib/API/Socket.pm - Socket manipulation subroutines.
# Copyright (C) 2010-2012 Ethrik Development Group, et al.
# This program is free software; rights to this code are stated in doc/LICENSE.
package API::Socket;
use strict;
use warnings;
use API::Log qw(alog dbug);
use API::Std qw(conf_get err timer_add timer_del);
use Exporter;
use base qw(Exporter);
use POSIX;

our @EXPORT_OK = qw(add_socket del_socket send_socket is_socket on_disconnect pong_received);

use constant DEFAULT_HEARTBEAT_INTERVAL => 120;
use constant DEFAULT_HEARTBEAT_TIMEOUT  => 60;

sub _config_number {
    my ($id, $name, $default) = @_;
    my @value = conf_get("server:$id:$name");
    @value = conf_get($name) if !@value or !defined $value[0];
    return $default if !@value or !defined $value[0] or
        !defined $value[0][0] or $value[0][0] <= 0;
    return $value[0][0];
}

sub _heartbeat_timer_name {
    my ($id) = @_;
    $id =~ s/[^a-z0-9_]/_/ig;
    return 'irc_heartbeat_'.$id;
}

sub _heartbeat_tick {
    my ($id) = @_;
    return if !defined $Auto::SOCKET{$id} or !Auto::is_ircsock($id);

    my $now = time;
    my $timeout = _config_number($id, 'heartbeat_timeout', DEFAULT_HEARTBEAT_TIMEOUT);
    if (defined $Auto::SOCKET{$id}{ping_sent}) {
        if (($now - $Auto::SOCKET{$id}{ping_sent}) >= $timeout) {
            on_disconnect($id, 'IRC heartbeat timed out');
        }
        return;
    }

    my $interval = _config_number($id, 'heartbeat_interval', DEFAULT_HEARTBEAT_INTERVAL);
    return if (($now - $Auto::SOCKET{$id}{last_activity}) < $interval);

    my $token = join('-', 'auto', $Auto::APID || $$, $now, int(rand 1_000_000));
    $Auto::SOCKET{$id}{ping_token} = $token;
    $Auto::SOCKET{$id}{ping_sent} = $now;
    send_socket($id, "PING :$token");
    return 1;
}

sub pong_received {
    my ($id, $token) = @_;
    return if !defined $Auto::SOCKET{$id};
    $token =~ s/^:// if defined $token;
    return if !defined $token or !defined $Auto::SOCKET{$id}{ping_token};
    return if $token ne $Auto::SOCKET{$id}{ping_token};

    delete $Auto::SOCKET{$id}{ping_token};
    delete $Auto::SOCKET{$id}{ping_sent};
    $Auto::SOCKET{$id}{last_activity} = time;
    return 1;
}

sub add_socket {
    my ($id, $object, $handler) = @_;
    alog('add_socket(): Socket already exists.') and return if defined($Auto::SOCKET{$id});
    alog('add_socket(): Specified handler is not valid.') and return if ref($handler) ne 'CODE';
    alog('add_socket(): Specified socket object is not defined.') and return if !defined $object;
    alog('add_socket(): Specified socket object is not a valid IO::Socket object.') and return if !$object->isa('IO::Handle');
    $Auto::SOCKET{$id}{handler} = $handler;
    $Auto::SOCKET{$id}{socket} = $object;
    $Auto::SOCKET{$id}{last_activity} = time;
    if (Auto::is_ircsock($id) and ref($object) ne 'IO::Socket::SSL') {
        binmode($object, ':encoding(UTF-8)');
    }
    my $stream = $Auto::SOCKET{$id}{stream} = IO::Async::Stream->new(
        handle  => $object,
        on_read => sub {
            my (undef, $buffref, $eof) = @_;
            $Auto::SOCKET{$id}{last_activity} = time if defined $Auto::SOCKET{$id};
            while ($$buffref =~ s/^(.*)\n//) {
                my $type = (Auto::is_ircsock($id) ? 'IRC' : 'Socket');
                dbug "[$type] $id << $1";
                API::Std::callback_run("socket $id handler", $handler, $id, $1);
            }
        },
        on_read_eof => sub {
            API::Socket::on_disconnect($id, 'read EOF');
        },
        on_read_error => sub {
            my (undef, $errno) = @_;
            API::Socket::on_disconnect($id, "read error: $errno");
        },
        on_write_error => sub {
            my (undef, $errno) = @_;
            API::Socket::on_disconnect($id, "write error: $errno");
        }
    );
    $Auto::loop->add($stream);
    if (Auto::is_ircsock($id)) {
        my $interval = _config_number($id, 'heartbeat_interval', DEFAULT_HEARTBEAT_INTERVAL);
        my $timeout = _config_number($id, 'heartbeat_timeout', DEFAULT_HEARTBEAT_TIMEOUT);
        my $check_interval = ($interval < $timeout ? $interval : $timeout);
        timer_add(_heartbeat_timer_name($id), 2, $check_interval, sub { _heartbeat_tick($id) });
    }
    alog("add_socket(): Socket $id added.");
    return 1;
}

sub del_socket {
    my ($id, $immediate) = @_;
    return if !defined($Auto::SOCKET{$id});
    my $stream = $Auto::SOCKET{$id}{stream};
    timer_del(_heartbeat_timer_name($id)) if Auto::is_ircsock($id);
    delete $Auto::SOCKET{$id};
    if ($immediate) { $stream->close_now }
    else { $stream->close_when_empty }
    alog("del_socket(): Socket $id deleted.");
    return 1;
}

sub send_socket {
    my ($id, $data) = @_;
    if (defined($Auto::SOCKET{$id})) {
        if (Auto::is_ircsock($id)) {
            $Auto::SOCKET{$id}{stream}->write("$data\r\n");
            dbug "[IRC] $id >> $data";
        }
        else {
            $Auto::SOCKET{$id}{stream}->write($data);
            dbug "[Socket] $id >> $data";
        }
    }
    else {
        return;
    }
    return 1;
}

sub is_socket {
    my ($id) = @_;
    return 1 if defined($Auto::SOCKET{$id});
    return 0;
}

sub on_disconnect {
    my ($id, $reason) = @_;
    return if !defined $Auto::SOCKET{$id};
    my $is_irc = Auto::is_ircsock($id);
    err(2, "Lost connection to $id".(defined $reason ? " ($reason)" : q{}).'!', 0);
    del_socket($id, 1);
    API::Std::event_run('on_disconnect', $id) if $is_irc;
    my $i = 0;
    foreach (keys %Auto::SOCKET) { $i++ if Auto::is_ircsock($_); }
    if (!$i and $is_irc) {
        dbug '* No active IRC connections; waiting to reconnect.';
        alog '* No active IRC connections; waiting to reconnect.';
    }
    return 1;
}


1;
# vim: set ai et sw=4 ts=4:
