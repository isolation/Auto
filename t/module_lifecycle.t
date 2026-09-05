use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use Symbol ();

BEGIN {
    # Exercise the real Auto::Timer against a small loop/periodic-timer stand-in.
    package IO::Async::Timer::Periodic;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub start { $_[0]{started} = 1 }
    sub stop { $_[0]{started} = 0 }
    $INC{'IO/Async/Timer/Periodic.pm'} = __FILE__;

    package Local::Loop;
    sub new { bless { members => {} }, shift }
    sub add { $_[0]{members}{$_[1]} = $_[1]; 1 }
    sub remove {
        die "loop removal failed\n" if $_[0]{fail_remove};
        delete $_[0]{members}{$_[1]}; 1;
    }

    package API::Log;
    use Exporter 'import';
    our @EXPORT_OK = qw(alog dbug slog);
    our @MESSAGES;
    sub alog { push @MESSAGES, $_[0]; 1 }
    sub dbug { 1 }
    sub slog { 1 }
    $INC{'API/Log.pm'} = __FILE__;

    package API::IRC;
    use Exporter 'import';
    our @EXPORT_OK = qw(privmsg notice quit usrc who kick ban);
    our @NOTICES;
    sub notice { push @NOTICES, $_[2]; 1 }
    sub privmsg { 1 } sub quit { 1 } sub usrc { 1 }
    sub who { 1 } sub kick { 1 } sub ban { 1 }
    $INC{'API/IRC.pm'} = __FILE__;

    package Local::DB;
    sub do { 1 }

    package Auto;
    our (%SOCKET, %SETTINGS, %TIMERS, $DEBUG, $loop, $DB, $ENFEAT);
    $loop = Local::Loop->new;
    $DB = bless {}, 'Local::DB';
    $ENFEAT = 'sqlite';

    package main;
    # Use Class::Unload when installed. The fallback permits registry/lifecycle
    # tests on development machines without the bot's CPAN dependencies.
    unless (eval { require Class::Unload; 1 }) {
        *Class::Unload::unload = sub { Symbol::delete_package($_[1]); 1 };
        $INC{'Class/Unload.pm'} = __FILE__;
    }
}

use lib 'lib';
require API::Std;
require Core::Cmd;
my $dir = tempdir(CLEANUP => 1);
my $root = abs_path('.');

# Load only the main program's path-selection wrapper, without booting the bot.
{
    open my $fh, '<', "$root/bin/auto" or die $!;
    local $/;
    my $source = <$fh>;
    my ($loader) = $source =~ /(sub mod_load \{.*?\n\})/s;
    die 'Cannot find Auto::mod_load' unless $loader;
    eval 'package Auto; our %bin; '.$loader;
    die $@ if $@;
    $Auto::bin{mod} = $dir;
}


sub fixture {
    my ($name, $init, $void, $extra, $tail) = @_;
    open my $fh, '>', "$dir/$name.pm" or die $!;
    print {$fh} "package M::$name;\nuse strict; use warnings;\n",
        "use API::Std qw(cmd_add cmd_del hook_add hook_del rchook_add rchook_del timer_add timer_del);\n",
        "sub _init { $init }\n", (defined $void ? "sub _void { $void }\n" : ''),
        ($extra || ''), "\nAPI::Std::mod_init('$name', 'test', '1.00', '3.0.0a11');\n", ($tail || '');
    close $fh or die $!;
    return "$dir/$name.pm";
}
sub load_fixture { API::Std::mod_load($_[0], "$dir/$_[0].pm") }
sub command { $API::Std::CMDS{$_[0]}{'sub'}->() }
sub fire_timer {
    my ($name) = @_;
    my $timer = $Auto::TIMERS{$name};
    $timer->{on_tick}->($timer);
}

subtest 'unchanged version and ownership through callbacks' => sub {
    API::Std::event_add('shared');
    API::Std::cmd_add('CORE', 0, 0, {}, sub {
        API::Std::timer_add('core_late', 2, 10, sub { 1 });
    });
    API::Std::hook_add('shared', 'core', sub { 1 });
    API::Std::rchook_add('NOTICE', 'core', sub { 1 });
    fixture('Owner', q{
        cmd_add('OWN', 0, 0, {}, sub {
            API::Std::timer_add('late_command', 2, 10, sub { 1 });
            $API::Std::CMDS{CORE}{'sub'}->();
            return 10;
        }) or return;
        hook_add('shared', 'own', sub { timer_add('late_hook', 2, 10, sub { 1 }) }) or return;
        rchook_add('NOTICE', 'own', sub { timer_add('late_raw', 2, 10, sub { 1 }) }) or return;
        timer_add('own_timer', 1, 10, sub { timer_add('late_timer', 2, 10, sub { 1 }) }) or return;
        API::Std::cmd_alias('OWN_ALIAS', 'OWN');
        API::Std::event_add('own_event');
        return 1;
    }, 'return 1;', q{
        sub later { timer_add('late_direct', 2, 10, sub { 1 }) }
    });
    is(load_fixture('Owner'), undef, 'module loads');
    like(load_fixture('Owner'), qr/already loaded/, 'duplicate load rejected before running source');
    is(command('OWN'), 10, 'command executes');
    API::Std::event_run('shared');
    $API::Std::RAWHOOKS{NOTICE}{own}->();
    fire_timer('own_timer');
    M::Owner->can('later')->();
    ok(!exists $Auto::TIMERS{own_timer}, 'one-shot timer expires');
    ok(exists $Auto::TIMERS{$_}, "$_ registered") for qw(late_command late_hook late_raw late_timer late_direct core_late);
    my $old_callback = $API::Std::CMDS{OWN}{'sub'};
    ok(API::Std::mod_void('Owner'), 'core sweeps resources omitted by _void');
    ok(!exists $Auto::TIMERS{$_}, "$_ removed") for qw(late_command late_hook late_raw late_timer late_direct);
    ok(exists $Auto::TIMERS{core_late}, 'nested core callback retains independent ownership');
    ok(!exists $API::Std::CMDS{OWN}, 'command removed');
    ok(!exists $API::Std::ALIASES{OWN_ALIAS}, 'alias removed');
    ok(!exists $API::Std::EVENTS{own_event}, 'event removed');
    ok(!API::Std::hook_exists('shared', 'own'), 'hook removed');
    ok(!exists $API::Std::RAWHOOKS{NOTICE}{own}, 'raw hook removed');
    ok(API::Std::hook_exists('shared', 'core'), 'core hook preserved');
    ok(exists $API::Std::RAWHOOKS{NOTICE}{core}, 'core raw hook preserved');
    fixture('Owner', q{cmd_add('OWN', 0, 0, {}, sub { 20 }); return 1;}, 'return 1;');
    is(load_fixture('Owner'), undef, 'reload does not require version bump');
    is(command('OWN'), 20, 'new code executes');
    is($old_callback->(), undef, 'retained callback from previous load is inert');
    ok(!exists $Auto::TIMERS{late_command}, 'old callback cannot recreate resources');
    ok(API::Std::mod_void('Owner'), 'second unload succeeds');
};

subtest 'failed initialization rolls back every registration type' => sub {
    for my $ending ('return;', 'die "init exploded\\n";') {
        fixture('Broken', q{
            cmd_add('BROKEN', 0, 0, {}, sub { 1 });
            hook_add('shared', 'broken', sub { 1 });
            rchook_add('NOTICE', 'broken', sub { 1 });
            timer_add('broken', 2, 10, sub { 1 });
            API::Std::cmd_alias('BROKEN_ALIAS', 'BROKEN');
            API::Std::event_add('broken_event');
        }.$ending, 'return 1;');
        like(load_fixture('Broken'), qr/_init returned failure|init exploded/, 'initialization error reported');
        ok(!API::Std::mod_exists('Broken'), 'failed module is not registered');
        ok(!exists $API::Std::CMDS{BROKEN}, 'command rolled back');
        ok(!API::Std::hook_exists('shared', 'broken'), 'hook rolled back');
        ok(!exists $API::Std::RAWHOOKS{NOTICE}{broken}, 'raw hook rolled back');
        ok(!exists $Auto::TIMERS{broken}, 'timer rolled back');
        ok(!exists $API::Std::ALIASES{BROKEN_ALIAS}, 'alias rolled back');
        ok(!exists $API::Std::EVENTS{broken_event}, 'event rolled back');
        ok(!M::Broken->can('_init'), 'package removed');
    }
    fixture('Broken', q{cmd_add('BROKEN', 0, 0, {}, sub { 1 }); return 1;}, 'return 1;');
    is(load_fixture('Broken'), undef, 'fixed module loads without restart');
    ok(API::Std::mod_void('Broken'), 'fixed module unloads');
};

subtest 'file failures and diagnostics' => sub {
    my $warn_handler = sub {};
    my $die_handler = sub {};
    local $SIG{__WARN__} = $warn_handler;
    local $SIG{__DIE__} = $die_handler;
    fixture('FileError', 'return 1;', 'return 1;', '', 'die "after init\\n";');
    like(load_fixture('FileError'), qr/after init/, 'failure after mod_init reported');
    ok(!API::Std::mod_exists('FileError'), 'post-init failure rolls back registry');
    fixture('FileError', 'return 1;', 'return 1;', 'sub stale { 1 } my $invalid = ;');
    like(load_fixture('FileError'), qr/syntax error|not allowed/, 'syntax error reported');
    ok(!M::FileError->can('stale'), 'definitions compiled before syntax failure removed');
    fixture('FileError', 'warn "visible warning\\n"; return 1;', undef);
    is(load_fixture('FileError'), undef, 'corrected source loads');
    is($SIG{__WARN__}, $warn_handler, 'warning handler restored');
    is($SIG{__DIE__}, $die_handler, 'exception handler restored');
    ok(grep(/visible warning/, @API::Log::MESSAGES), 'warning is logged');
    ok(!API::Std::mod_void('FileError'), 'missing cleanup method reported');
    like($API::Std::MODULE_ERROR, qr/No _void/, 'missing method error preserved');
    ok(API::Std::mod_void('FileError', 1), 'missing cleanup method recoverable with FORCE');
    like(API::Std::mod_load('Absent', "$dir/Absent.pm"), qr/Cannot read/, 'file read error reported');
};

subtest 'real module cleanup bugs recover without module edits' => sub {
    API::Std::event_add('on_whoreply');
    API::Std::event_add('on_rcjoin');
    API::Std::event_add('on_cprivmsg');
    $Auto::SETTINGS{badwords} = [1];
    for my $name (qw(Ping Greet Badwords)) {
        for (1..2) {
            is(API::Std::mod_load($name, "$root/modules/$name.pm"), undef, "$name loads (cycle $_)");
            API::Std::cmd_del('AWAY') if $name eq 'Ping';
            ok(API::Std::mod_void($name), "$name unloads despite missing/malformed cleanup (cycle $_)");
        }
    }
    ok(!API::Std::hook_exists('on_rcjoin', 'greet_onjoin'), 'Greet hook removed');
    ok(!API::Std::hook_exists('on_cprivmsg', 'act_on_badword'), 'Badwords hook removed');
};

subtest 'refusals, partial cleanup, and forced recovery' => sub {
    fixture('Refusal', q{cmd_add('REFUSE', 0, 0, {}, sub { 1 }); return 1;}, 'return;');
    is(load_fixture('Refusal'), undef, 'refusing module loads');
    ok(!API::Std::mod_void('Refusal'), 'false return remains a veto');
    ok(API::Std::mod_exists('Refusal') && exists $API::Std::CMDS{REFUSE}, 'veto retains module and command');
    ok(API::Std::mod_void('Refusal', 1), 'explicit FORCE overrides veto');
    ok(!exists $API::Std::CMDS{REFUSE}, 'forced unload removes command');
    fixture('Partial', q{
        cmd_add('PARTIAL_A', 0, 0, {}, sub { 1 });
        cmd_add('PARTIAL_B', 0, 0, {}, sub { 1 }); return 1;
    }, q{
        cmd_del('PARTIAL_A') or return;
        die "cleanup exploded\n" unless $main::allow_cleanup;
        cmd_del('PARTIAL_B') or return; return 1;
    });
    is(load_fixture('Partial'), undef, 'partial-cleanup module loads');
    ok(!API::Std::mod_void('Partial'), 'cleanup exception contained');
    like($API::Std::MODULE_ERROR, qr/cleanup exploded/, 'cleanup exception preserved');
    ok(!exists $API::Std::CMDS{PARTIAL_A}, 'first deletion already happened');
    our $allow_cleanup = 1;
    ok(API::Std::mod_void('Partial'), 'retry tolerates previously removed command');
    fixture('Throws', q{cmd_add('THROWS', 0, 0, {}, sub { 1 }); return 1;}, 'die "always fails\\n";');
    is(load_fixture('Throws'), undef, 'throwing module loads');
    ok(API::Std::mod_void('Throws', 1), 'FORCE recovers throwing cleanup');
    ok(!exists $API::Std::CMDS{THROWS}, 'throwing cleanup leaves no command');
};

subtest 'timer expiration, replacement, and recovery' => sub {
    fixture('Timers', q{
        timer_add('replace', 1, 10, sub {
            timer_del('replace'); timer_add('replace', 2, 10, sub { 1 });
        });
        timer_add('explode', 2, 10, sub { die "tick exploded\n" });
        return 1;
    }, q{timer_del('explode') or return; return 1;});
    is(load_fixture('Timers'), undef, 'timer module loads');
    my $old = $Auto::TIMERS{replace};
    fire_timer('replace');
    isnt($Auto::TIMERS{replace}, $old, 'old timer cannot delete replacement');
    ok($Auto::TIMERS{replace}{started}, 'replacement remains started');
    fire_timer('explode');
    ok(!exists $Auto::TIMERS{explode}, 'throwing timer removed');
    ok(API::Std::mod_void('Timers'), 'missing failed timer does not block unload');
    ok(!exists $Auto::TIMERS{replace}, 'replacement owned by module and swept');
    fixture('Timers', q{timer_add('cleanup_retry', 2, 10, sub { 1 }); return 1;}, 'return 1;');
    is(load_fixture('Timers'), undef, 'module loads for loop failure');
    $Auto::loop->{fail_remove} = 1;
    ok(!API::Std::mod_void('Timers'), 'loop cleanup failure is not reported as success');
    like($API::Std::MODULE_ERROR, qr/loop removal failed/, 'loop failure reported');
    ok(API::Std::mod_exists('Timers'), 'failed cleanup remains recoverable');
    $Auto::loop->{fail_remove} = 0;
    ok(API::Std::mod_void('Timers', 1), 'cleanup can be retried');
};

subtest 'name reuse never transfers ownership accidentally' => sub {
    fixture('First', q{
        cmd_add('REUSE', 0, 0, {}, sub { 1 });
        timer_add('reuse', 2, 10, sub { 1 });
        rchook_add('NOTICE', 'reuse', sub { 1 });
        return 1;
    }, q{cmd_del('REUSE'); timer_del('reuse'); rchook_del('NOTICE', 'reuse'); return 1;});
    is(load_fixture('First'), undef, 'first owner loads');
    API::Std::cmd_del('REUSE'); API::Std::timer_del('reuse'); API::Std::rchook_del('NOTICE', 'reuse');
    fixture('Second', q{
        cmd_add('REUSE', 0, 0, {}, sub { 2 });
        timer_add('reuse', 2, 10, sub { 2 });
        rchook_add('NOTICE', 'reuse', sub { 2 });
        return 1;
    }, 'return 1;');
    is(load_fixture('Second'), undef, 'second owner reuses removed names');
    ok(API::Std::mod_void('First'), 'first owner unloads');
    is(command('REUSE'), 2, 'second command preserved');
    ok(exists $Auto::TIMERS{reuse}, 'second timer preserved');
    is($API::Std::RAWHOOKS{NOTICE}{reuse}->(), 2, 'second raw hook preserved');
    ok(API::Std::mod_void('Second'), 'second owner unloads');
};


subtest 'top-level registrations and an ignored init failure roll back' => sub {
    fixture('Early', 'return;', 'return 1;', q{
        cmd_add('EARLY', 0, 0, {}, sub { 1 });
        timer_add('early', 2, 10, sub { 1 });
    }, '1;');
    like(load_fixture('Early'), qr/_init returned failure/, 'trailing true value cannot hide init failure');
    ok(!exists $API::Std::CMDS{EARLY}, 'top-level command rolled back');
    ok(!exists $Auto::TIMERS{early}, 'top-level timer rolled back');
    fixture('Collision', q{
        cmd_add('COLLISION', 0, 0, {}, sub { 1 });
        timer_add('core_late', 2, 10, sub { die 'wrong callback' }) or return;
        return 1;
    }, 'return 1;');
    like(load_fixture('Collision'), qr/_init returned failure/, 'occupied timer name fails registration');
    ok(!exists $API::Std::CMDS{COLLISION}, 'earlier registration rolled back');
    ok(exists $Auto::TIMERS{core_late}, 'colliding core timer preserved');
};

subtest 'cleanup failure during rollback leaves a recovery path' => sub {
    fixture('RollbackRetry', q{
        timer_add('rollback_retry', 2, 10, sub { 1 });
        die "init failed\n";
    }, 'return 1;');
    $Auto::loop->{fail_remove} = 1;
    like(load_fixture('RollbackRetry'), qr/init failed.*cleanup failed/s, 'both init and cleanup failures reported');
    ok(API::Std::mod_exists('RollbackRetry'), 'recovery entry retained');
    is($API::Std::MODULE{RollbackRetry}{owner}{state}, 'failed', 'remaining callbacks disabled');
    like(load_fixture('RollbackRetry'), qr/already loaded/, 'cannot overwrite failed cleanup state');
    $Auto::loop->{fail_remove} = 0;
    ok(API::Std::mod_void('RollbackRetry', 1), 'FORCE retries cleanup after external failure resolves');
    ok(!exists $Auto::TIMERS{rollback_retry}, 'remaining timer removed');
};

subtest 'unload during event dispatch does not skip another module' => sub {
    API::Std::event_add('during_unload');
    fixture('During', q{
        hook_add('during_unload', 'unload_self', sub { API::Std::mod_void('During'); return 1 });
        hook_add('during_unload', 'old_callback', sub { die 'stale hook executed' }, 3);
        return 1;
    }, 'return 1;');
    is(load_fixture('During'), undef, 'self-unloading module loads');
    my $ran = 0;
    API::Std::hook_add('during_unload', 'other', sub { $ran++; return 1 });
    my $before = scalar @API::Log::MESSAGES;
    ok(API::Std::event_run('during_unload'), 'dispatcher tolerates disappearing registrations');
    is($ran, 1, 'other hook at same priority still runs');
    ok(!API::Std::mod_exists('During'), 'module unloaded');
    ok(!grep(/stale hook executed/, @API::Log::MESSAGES[$before..$#API::Log::MESSAGES]), 'old later-priority callback did not run');
};

subtest 'package unload failure can be retried' => sub {
    fixture('PackageRetry', q{cmd_add('PKG_RETRY', 0, 0, {}, sub { 1 }); return 1;}, 'return 1;');
    is(load_fixture('PackageRetry'), undef, 'module loads');
    {
        no warnings 'redefine';
        local *Class::Unload::unload = sub { die "package unload failed\n" };
        ok(!API::Std::mod_void('PackageRetry'), 'package failure reported');
        like($API::Std::MODULE_ERROR, qr/package unload failed/, 'original failure preserved');
    }
    ok(!exists $API::Std::CMDS{PKG_RETRY}, 'core registrations were already cleaned');
    ok(API::Std::mod_void('PackageRetry', 1), 'package cleanup can be retried');
};

subtest 'IRC commands expose failures and validate FORCE before unloading' => sub {
    my $src = { svr => 'test', nick => 'admin' };
    fixture('CLI', q{cmd_add('CLI_TEST', 0, 0, {}, sub { 1 }); return 1;}, 'return;');
    local $Auto::bin{mod} = $dir;
    is(Auto::mod_load('CLI'), undef, 'CLI fixture loads through main program wrapper');
    Core::Cmd::cmd_modreload($src, 'CLI');
    like($API::IRC::NOTICES[-1], qr/_void returned failure/, 'reload shows actual unload failure, not zero');
    Core::Cmd::cmd_modunload($src, 'CLI', 'typo');
    like($API::IRC::NOTICES[-1], qr/Syntax:/, 'invalid option rejected');
    ok(API::Std::mod_exists('CLI'), 'invalid option does not unload module');
    Core::Cmd::cmd_modreload($src, 'CLI', 'FORCE');
    like($API::IRC::NOTICES[-1], qr/successfully reloaded/, 'FORCE reload works');
    Core::Cmd::cmd_modunload($src, 'CLI', 'FORCE');
    like($API::IRC::NOTICES[-1], qr/successfully unloaded/, 'FORCE unload works');
};

is(scalar keys %API::Std::MODULE, 0, 'all tested modules have been fully removed');
done_testing;
