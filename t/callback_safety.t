use strict;
use warnings;
use Test::More;

BEGIN {
    package Auto::Timer;
    $INC{'Auto/Timer.pm'} = __FILE__;

    package API::Log;
    our (@ALOG, @DBUG);
    sub alog { push @ALOG, $_[0]; return 1 }
    sub dbug { push @DBUG, $_[0]; return 1 }
    $INC{'API/Log.pm'} = __FILE__;

    package Auto;
    our (%SOCKET, %SETTINGS);
}

use lib 'lib';
require API::Std;

my ($ok, $result) = API::Std::callback_run('successful test', sub { return 42 });
ok($ok, 'successful callback reports success');
is($result, 42, 'successful callback preserves scalar result');
is(scalar @API::Log::ALOG, 0, 'successful callback is not logged as a failure');

my $fatal_handler_ran = 0;
{
    local $SIG{__DIE__} = sub {
        return if $^S;
        $fatal_handler_ran++;
    };
    ($ok, $result) = API::Std::callback_run('failing test', sub { die "module exploded\n" });
}
ok(!$ok, 'exception reports callback failure');
ok(!defined $result, 'failed callback has no result');
is($fatal_handler_ran, 0, 'exception remains inside the eval boundary');
like($API::Log::ALOG[-1], qr/^Callback failure \[failing test\]: module exploded/, 'exception and callback identity are logged');

API::Std::event_add('test_event');
my @ran;
API::Std::hook_add('test_event', 'broken.module', sub {
    push @ran, 'broken';
    die 'hook failed';
}, 1);
API::Std::hook_add('test_event', 'healthy.module', sub {
    push @ran, 'healthy';
    return -1;
}, 1);
API::Std::hook_add('test_event', 'should.not.run', sub {
    push @ran, 'late';
    return 1;
}, 2);

ok(API::Std::event_run('test_event'), 'event dispatcher survives a broken hook');
is_deeply(\@ran, ['broken', 'healthy'], 'later hooks run and normal stop semantics are preserved');
like($API::Log::ALOG[-1], qr/event test_event hook broken\.module/, 'event failure identifies the broken hook');

done_testing;
