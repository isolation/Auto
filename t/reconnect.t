use strict;
use warnings;
use Test::More;

BEGIN {
    package API::Std;
    use Exporter qw(import);
    our @EXPORT_OK = qw(hook_add conf_get err timer_add timer_del);
    our (%TIMERS, @DELETED);
    sub hook_add { return 1 }
    sub err { return 1 }
    sub conf_get {
        my ($name) = @_;
        return (testnet => { host => ['localhost'], port => [6667] }) if $name eq 'server';
        return [5] if $name eq 'reconnect_delay';
        return [20] if $name eq 'reconnect_max_delay';
        return;
    }
    sub timer_add {
        my ($name, $type, $delay, $callback) = @_;
        $TIMERS{$name} = [$type, $delay, $callback];
        return 1;
    }
    sub timer_del { push @DELETED, $_[0]; delete $TIMERS{$_[0]}; return 1 }
    sub event_add { return 1 }
    sub event_run { return 1 }
    $INC{'API/Std.pm'} = __FILE__;

    package API::Log;
    use Exporter qw(import);
    our @EXPORT_OK = qw(dbug alog);
    sub dbug { return 1 }
    sub alog { return 1 }
    $INC{'API/Log.pm'} = __FILE__;

    package API::Socket;
    use Exporter qw(import);
    our @EXPORT_OK = qw(add_socket);
    sub add_socket { return 1 }
    $INC{'API/Socket.pm'} = __FILE__;

    package Auto;
    our (%SOCKET, %SETTINGS);
    sub RSTAGE () { 'd' }
    sub VER () { 3 }
    sub SVER () { 0 }
    sub REV () { 0 }

    package Socket;
    sub AF_INET () { 2 }
    sub AF_INET6 () { 30 }
}

use lib 'lib';
require Lib::Auto;

{
    no warnings 'redefine';
    local *Lib::Auto::ircsock = sub { return };

    ok(Lib::Auto::schedule_reconnect('testnet'), 'first reconnect is scheduled');
    is($API::Std::TIMERS{irc_reconnect_testnet_0}[1], 5, 'first delay uses configured base');
    $API::Std::TIMERS{irc_reconnect_testnet_0}[2]->();
    is($API::Std::TIMERS{irc_reconnect_testnet_1}[1], 10, 'failed reconnect doubles delay');
    $API::Std::TIMERS{irc_reconnect_testnet_1}[2]->();
    is($API::Std::TIMERS{irc_reconnect_testnet_2}[1], 20, 'backoff reaches configured cap');
    $API::Std::TIMERS{irc_reconnect_testnet_2}[2]->();
    is($API::Std::TIMERS{irc_reconnect_testnet_3}[1], 20, 'backoff remains capped');
}

ok(Lib::Auto::connection_ready('testnet'), 'successful registration resets reconnect state');
ok(!defined $Lib::Auto::RECONNECT_ATTEMPTS{testnet}, 'attempt counter was cleared');
is_deeply(\@API::Std::DELETED, ['irc_reconnect_testnet_3'], 'pending reconnect timer was cancelled');

done_testing;
