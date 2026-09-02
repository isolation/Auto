use strict;
use warnings;
use Test::More;
use IO::Handle;

BEGIN {
    package API::Log;
    use Exporter qw(import);
    our @EXPORT_OK = qw(alog dbug);
    sub alog { return 1 }
    sub dbug { return 1 }
    $INC{'API/Log.pm'} = __FILE__;

    package API::Std;
    use Exporter qw(import);
    our @EXPORT_OK = qw(conf_get err timer_add timer_del awarn trans);
    our (%TIMERS, %RAWHOOKS, @EVENTS, @ERRORS);
    sub conf_get {
        my ($name) = @_;
        return [120] if $name eq 'heartbeat_interval';
        return [60] if $name eq 'heartbeat_timeout';
        return;
    }
    sub err { push @ERRORS, $_[1]; return 1 }
    sub timer_add {
        my ($name, $type, $delay, $callback) = @_;
        $TIMERS{lc $name} = [$type, $delay, $callback];
        return 1;
    }
    sub timer_del { delete $TIMERS{lc $_[0]}; return 1 }
    sub event_run { push @EVENTS, [@_]; return 1 }
    sub callback_run {
        my (undef, $callback, @args) = @_;
        return (1, $callback->(@args));
    }
    sub event_add { return 1 }
    sub mod_exists { return }
    sub awarn { return 1 }
    sub trans { return $_[0] }
    $INC{'API/Std.pm'} = __FILE__;

    package API::IRC;
    $INC{'API/IRC.pm'} = __FILE__;

    package IO::Async::Stream;
    our $LAST;
    sub new {
        my ($class, %options) = @_;
        $LAST = bless { options => \%options, writes => [] }, $class;
        return $LAST;
    }
    sub write { push @{$_[0]{writes}}, $_[1]; return 1 }
    sub close_now { $_[0]{closed_now}++; return 1 }
    sub close_when_empty { $_[0]{closed_when_empty}++; return 1 }

    package Local::Loop;
    sub new { bless {}, shift }
    sub add { $_[0]{added} = $_[1]; return 1 }

    package Auto;
    our (%SOCKET, $loop, $APID);
    sub is_ircsock { return $_[0] eq 'testnet' }
}

use lib 'lib';
require API::Socket;
require Proto::IRC;

$Auto::loop = Local::Loop->new;
$Auto::APID = 4242;
open my $raw_handle, '<', '/dev/null' or die "Cannot open /dev/null: $!";
my $handle = IO::Handle->new_from_fd(fileno($raw_handle), 'r');

ok(API::Socket::add_socket('testnet', $handle, sub { return 1 }), 'adds mocked IRC stream');
my $heartbeat = $API::Std::TIMERS{irc_heartbeat_testnet};
is($heartbeat->[1], 60, 'heartbeat checks at the shorter timeout interval');

$Auto::SOCKET{testnet}{last_activity} = time - 121;
$heartbeat->[2]->();
like($IO::Async::Stream::LAST->{writes}[0], qr/^PING :auto-4242-/, 'idle connection receives a nonce PING');
my $token = $Auto::SOCKET{testnet}{ping_token};

ok(!API::Socket::pong_received('testnet', ':wrong-token'), 'unmatched PONG is ignored');
ok(defined $Auto::SOCKET{testnet}{ping_sent}, 'unmatched PONG leaves deadline active');
ok(Proto::IRC::ircparse('testnet', ':irc.example PONG irc.example :'.$token), 'matching PONG is parsed');
ok(!defined $Auto::SOCKET{testnet}{ping_sent}, 'matching PONG clears deadline');

$Auto::SOCKET{testnet}{ping_sent} = time - 61;
$Auto::SOCKET{testnet}{ping_token} = 'expired';
$heartbeat->[2]->();
ok(!defined $Auto::SOCKET{testnet}, 'heartbeat timeout removes dead socket');
is($IO::Async::Stream::LAST->{closed_now}, 1, 'dead socket closes immediately');
is_deeply($API::Std::EVENTS[0], ['on_disconnect', 'testnet'], 'disconnect event is emitted');
$heartbeat->[2]->();
is(scalar @API::Std::EVENTS, 1, 'repeated failure callback is idempotent');

ok(API::Socket::add_socket('testnet', $handle, sub { return 1 }), 'stream can be added again');
$IO::Async::Stream::LAST->{options}{on_read_error}->(undef, 'connection reset');
ok(!defined $Auto::SOCKET{testnet}, 'read error follows disconnect path');

ok(API::Socket::add_socket('testnet', $handle, sub { return 1 }), 'stream can be added after read error');
$IO::Async::Stream::LAST->{options}{on_write_error}->(undef, 'broken pipe');
ok(!defined $Auto::SOCKET{testnet}, 'write error follows disconnect path');

ok(API::Socket::add_socket('testnet', $handle, sub { return 1 }), 'stream can be added after write error');
$IO::Async::Stream::LAST->{options}{on_read_eof}->();
ok(!defined $Auto::SOCKET{testnet}, 'EOF follows disconnect path');

done_testing;
