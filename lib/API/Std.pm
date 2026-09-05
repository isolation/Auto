# lib/API/Std.pm - Standard API subroutines.
# Copyright (C) 2010-2012 Xelhua Development Group, et al.
# This program is free software; rights to this code are stated in doc/LICENSE.
package API::Std;
use strict;
use warnings;
use feature qw(say);
use Auto::Timer;
use Exporter;
use base qw(Exporter);

our (%LANGE, %MODULE, %EVENTS, %HOOKS, %CMDS, %ALIASES, %RAWHOOKS);
our @EXPORT_OK = qw(conf_get trans err awarn timer_add timer_del cmd_add 
                    cmd_del hook_add hook_del rchook_add rchook_del match_user
                    has_priv mod_exists ratelimit_check fpfmt hook_exists callback_run);

# Run an extension callback without allowing an uncaught exception to terminate
# the event loop. Returns a success flag followed by the callback's scalar result.
sub callback_run {
    my ($description, $callback, @args) = @_;
    my $result;
    my $ok = eval {
        $result = $callback->(@args);
        1;
    };
    my $exception = $@;

    if (!$ok) {
        $exception = 'unknown exception' if !defined $exception or $exception eq q{};
        $exception =~ s/[\r\n]+/ /gsm;
        $exception =~ s/\s+$//sm;
        my $message = "Callback failure [$description]: $exception";
        API::Log::alog($message);
        API::Log::dbug($message);
        return (0, undef);
    }

    return (1, $result);
}


# Each load gets a distinct owner, so callbacks retained across a reload cannot
# execute old module code or register resources in the new module's name.
our ($MODULE_CONTEXT, $MODULE_ERROR);
our (%PACKAGE_OWNER, %RAW_OWNER, %EVENT_OWNER, %ALIAS_OWNER);

sub _module_log {
    my ($message) = @_;
    API::Log::alog('MODULES: '.$message);
    API::Log::dbug('MODULES: '.$message);
    API::Log::slog('MODULES: '.$message) if keys %Auto::SOCKET;
}

sub _registration_owner {
    return $MODULE_CONTEXT if defined $MODULE_CONTEXT;
    for (my $depth = 1; my @frame = caller $depth; $depth++) {
        return $PACKAGE_OWNER{$frame[0]} if $PACKAGE_OWNER{$frame[0]};
    }
    return;
}

sub _owned_callback {
    my ($owner, $callback) = @_;
    return sub {
        return if $owner && $owner->{state} ne 'active' && $owner->{state} ne 'loading';
        # Zero also prevents an unrelated core callback from inheriting its caller.
        local $MODULE_CONTEXT = $owner || 0;
        return $callback->(@_);
    };
}

sub _can_register {
    my ($owner) = @_;
    return !$owner || $owner->{state} eq 'loading' || $owner->{state} eq 'active';
}

sub _is_teardown {
    return $MODULE_CONTEXT && $MODULE_CONTEXT->{state} eq 'unloading';
}

# Sweep only this load's registrations; another module may have reused a name.
# Stop timers before dropping code. A loop failure leaves the owner recoverable.
sub _module_cleanup {
    my ($owner) = @_;
    my @errors;
    foreach my $name (keys %Auto::TIMERS) {
        next unless $Auto::TIMERS{$name}{module_owner}
            && $Auto::TIMERS{$name}{module_owner} == $owner;
        my $ok = eval { timer_del($name); 1 };
        push @errors, "timer $name: $@" unless $ok;
    }
    foreach my $name (keys %CMDS) {
        delete $CMDS{$name} if $CMDS{$name}{module_owner}
            && $CMDS{$name}{module_owner} == $owner;
    }
    foreach my $event (keys %HOOKS) {
        foreach my $priority (keys %{$HOOKS{$event}}) {
            my $hooks = $HOOKS{$event}{$priority};
            @$hooks = grep { !$_->[2] || $_->[2] != $owner } @$hooks;
            delete $HOOKS{$event}{$priority} unless @$hooks;
        }
        delete $HOOKS{$event} unless keys %{$HOOKS{$event}};
    }
    foreach my $cmd (keys %RAW_OWNER) {
        foreach my $name (keys %{$RAW_OWNER{$cmd}}) {
            next unless $RAW_OWNER{$cmd}{$name} == $owner;
            delete $RAWHOOKS{$cmd}{$name};
            delete $RAW_OWNER{$cmd}{$name};
        }
        delete $RAW_OWNER{$cmd} unless keys %{$RAW_OWNER{$cmd}};
    }
    foreach my $name (keys %ALIAS_OWNER) {
        next unless $ALIAS_OWNER{$name} == $owner;
        delete $ALIASES{$name};
        delete $ALIAS_OWNER{$name};
    }
    foreach my $name (keys %EVENT_OWNER) {
        next unless $EVENT_OWNER{$name} == $owner;
        delete $EVENTS{$name};
        delete $EVENT_OWNER{$name};
        # Keep other modules' hooks dormant until the event is registered again.
    }
    return join '; ', @errors;
}

sub _module_release {
    my ($owner) = @_;
    local $MODULE_CONTEXT = $owner;
    $owner->{state} = 'unloading';
    my $error = _module_cleanup($owner);
    if (!$error && $owner->{pkg}) {
        my $ok = eval {
            require Class::Unload;
            Class::Unload->unload($owner->{pkg});
            1;
        };
        $error = "package cleanup: $@" unless $ok;
    }
    if ($error) {
        # Keep a recovery entry even if initialization never finished.
        $owner->{state} = 'failed';
        $MODULE{$owner->{name}} ||= { name => $owner->{name}, pkg => $owner->{pkg},
            version => '?', author => '?', owner => $owner };
        return $error;
    }
    delete $PACKAGE_OWNER{$owner->{pkg}} if $owner->{pkg}
        && $PACKAGE_OWNER{$owner->{pkg}} && $PACKAGE_OWNER{$owner->{pkg}} == $owner;
    delete $MODULE{$owner->{name}} if $MODULE{$owner->{name}}
        && $MODULE{$owner->{name}}{owner} == $owner;
    $owner->{state} = 'unloaded';
    return;
}

# File execution and initialization are one transaction. Return an error string
# on failure and undef on success, matching Auto::mod_load's historical API.
sub mod_load {
    my ($name, $path) = @_;
    return "Module $name is already loaded" if mod_exists($name);
    # Bundled modules use M::<filename>. Remember that namespace even when
    # compilation fails before mod_init can tell us its package.
    my ($basename) = $name =~ m{(?:^|/)([A-Za-z_]\w*)$};
    my $pkg = defined $basename ? 'M::'.$basename : undef;
    return "Package $pkg is already registered" if $pkg && $PACKAGE_OWNER{$pkg};
    my $owner = { name => $name, state => 'loading', pkg => $pkg };
    local $MODULE_CONTEXT = $owner;
    my ($result, $error);
    my $ok = eval {
        local $SIG{__DIE__} = sub {};
        local $SIG{__WARN__} = sub { _module_log("$name warning: $_[0]") };
        local $@;
        local $!;
        $result = do $path;
        $error = $@ || $owner->{error};
        $error ||= "Cannot read $path: $!" if !defined $result && $!;
        1;
    };
    $error ||= $@ unless $ok;
    $error ||= $owner->{error};
    $error ||= 'Module initialization failed' unless $result && $owner->{initialized};
    if ($error) {
        my $cleanup = _module_release($owner);
        $error .= "; cleanup failed: $cleanup (use MODUNLOAD $owner->{name} FORCE)" if $cleanup;
        _module_log("Failed to load $name: $error");
        return $error;
    }
    $owner->{state} = 'active';
    _module_log("$name successfully loaded.");
    return;
}

# Initialize a module using the existing four-argument module interface.
sub mod_init {
    my ($name, $author, $version, $autover) = @_;
    my $pkg = caller;
    my $loading = $MODULE_CONTEXT && $MODULE_CONTEXT->{state} eq 'loading';
    my $owner = $loading ? $MODULE_CONTEXT : { name => $name, state => 'loading' };
    local $MODULE_CONTEXT = $owner;
    my $error;
    if ($owner->{initialized} || $MODULE{$name} || $PACKAGE_OWNER{$pkg}) {
        $error = "Module $name or package $pkg is already registered";
    }
    else {
        $owner->{name} = $name;
        $owner->{pkg} = $pkg;
        $PACKAGE_OWNER{$pkg} = $owner;
        if (!defined $autover || $autover !~ m/^3\.0\.0a(7|8|9|10|11|12)$/xsm) {
            $error = 'Incompatible with your version of Auto';
        }
        elsif (!$pkg->can('_init')) {
            $error = 'No _init subroutine';
        }
        else {
            my $result;
            my $ok = eval { $result = $pkg->_init(); 1 };
            $error = $@ unless $ok;
            $error ||= '_init returned failure' unless $result;
        }
    }
    if ($error) {
        $owner->{error} = $error;
        _module_log("Failed to initialize $name: $error");
        _module_release($owner) unless $loading;
        return;
    }
    $MODULE{$name} = { name => $name, version => $version, author => $author,
        pkg => $pkg, owner => $owner };
    $owner->{initialized} = 1;
    $owner->{state} = 'active' unless $loading;
    return 1;
}

sub mod_exists {
    return exists $MODULE{$_[0]};
}

# A false _void result remains a veto. FORCE explicitly requests recovery of
# core registrations even if module-specific cleanup refuses or throws.
sub mod_void {
    my ($name, $force) = @_;
    $MODULE_ERROR = undef;
    my $module = $MODULE{$name};
    if (!$module) {
        $MODULE_ERROR = 'Module is not loaded';
        return;
    }
    my $owner = $module->{owner};
    if ($owner->{state} eq 'unloading' || $owner->{state} eq 'loading') {
        $MODULE_ERROR = 'Module lifecycle operation already in progress';
        return;
    }
    local $MODULE_CONTEXT = $owner;
    my $previous_state = $owner->{state};
    $owner->{state} = 'unloading';
    my ($result, $error);
    if ($module->{pkg} && $module->{pkg}->can('_void')) {
        my $ok = eval { $result = $module->{pkg}->_void(); 1 };
        $error = $@ unless $ok;
        $error ||= '_void returned failure' unless $result;
    }
    else {
        $error = 'No _void subroutine';
    }
    if ($error) {
        _module_log("$name cleanup: $error");
        if (!$force) {
            $owner->{state} = $previous_state;
            $MODULE_ERROR = "$error; use MODUNLOAD $name FORCE to recover core registrations";
            return;
        }
        _module_log("Forcing unload of $name despite module cleanup failure.");
    }
    $MODULE_ERROR = _module_release($owner);
    if ($MODULE_ERROR) {
        _module_log("Failed to unload $name: $MODULE_ERROR");
        return;
    }
    _module_log("Successfully unloaded $name.");
    return 1;
}

# Add a command to Auto.
sub cmd_add {
    my ($cmd, $lvl, $priv, $help, $sub) = @_;
    $cmd = uc $cmd;

    if (defined $API::Std::CMDS{$cmd}) { return }
    if ($lvl =~ m/[^0-3]/sm) { return } ## no critic qw(RegularExpressions::RequireExtendedFormatting)

    my $owner = _registration_owner();
    return unless _can_register($owner);

    $API::Std::CMDS{$cmd}{lvl}   = $lvl;
    $API::Std::CMDS{$cmd}{help}  = $help;
    $API::Std::CMDS{$cmd}{priv}  = $priv;
    $API::Std::CMDS{$cmd}{module_owner} = $owner;
    $API::Std::CMDS{$cmd}{'sub'} = _owned_callback($owner, $sub);

    return 1;
}

# Alias a command to another.
sub cmd_alias {
    my ($alias, $cmd) = @_;
    
    # Prepare data.
    $alias = uc $alias;
    $cmd = uc $cmd;
    
    my $owner = _registration_owner();
    return unless _can_register($owner);
    # Do not overwrite another owner's alias during module initialization.
    return if $owner && exists $ALIASES{$alias}
        && (!$ALIAS_OWNER{$alias} || $ALIAS_OWNER{$alias} != $owner);
    $ALIASES{$alias} = $cmd;
    if ($owner) { $ALIAS_OWNER{$alias} = $owner }
    else { delete $ALIAS_OWNER{$alias} }

    return 1;
}

# Delete a command from Auto.
sub cmd_del {
    my ($cmd) = @_;
    $cmd = uc $cmd;

    if (defined $API::Std::CMDS{$cmd}) {
        return if _is_teardown() && (!$CMDS{$cmd}{module_owner}
            || $CMDS{$cmd}{module_owner} != $MODULE_CONTEXT);
        delete $API::Std::CMDS{$cmd};
    }
    else {
        return _is_teardown() ? 1 : undef;
    }

    return 1;
}

# Add an event to Auto.
sub event_add {
    my ($name) = @_;

    my $owner = _registration_owner();
    return unless _can_register($owner);
    if (!defined $EVENTS{lc $name}) {
        $EVENTS{lc $name} = 1;
        $EVENT_OWNER{lc $name} = $owner if $owner;
        return 1;
    }
    else {
        API::Log::dbug('DEBUG: Attempt to add a pre-existing event ('.lc $name.')! Ignoring...');
        return;
    }
}

# Delete an event from Auto.
sub event_del {
    my ($name) = @_;

    if (defined $EVENTS{lc $name}) {
        return if _is_teardown() && (!$EVENT_OWNER{lc $name}
            || $EVENT_OWNER{lc $name} != $MODULE_CONTEXT);
        delete $EVENT_OWNER{lc $name};
        delete $EVENTS{lc $name};
        delete $HOOKS{lc $name} unless _is_teardown();
        return 1;
    }
    else {
        API::Log::dbug('DEBUG: Attempt to delete a non-existing event ('.lc $name.')! Ignoring...');
        return;
    }
}

# Trigger an event.
sub event_run {
    my ($event, @args) = @_;

    if (defined $EVENTS{lc $event} and defined $HOOKS{lc $event}) {
        PRIORITY: foreach my $priority (sort { $a <=> $b } keys %{ $HOOKS{lc $event} }) {
            my @callbacks = @{$API::Std::HOOKS{lc $event}{$priority} || []};
            foreach my $cb (@callbacks) {
                my ($ok, $result) = callback_run('event '.$event.' hook '.$cb->[0], $cb->[1], @args);
                next if !$ok;
                if (defined $result and int $result == -1) { last PRIORITY }
            }
        }
    }

    return 1;
}

# Add a hook to Auto.
sub hook_add {
    my ($event, $name, $sub) = @_;

    my $priority = (defined $_[3] ? $_[3] : 2);
    my $owner = _registration_owner();
    return unless _can_register($owner);

    if (!hook_exists($event, $name)) {
        if (defined $API::Std::EVENTS{lc $event}) {
            $API::Std::HOOKS{lc $event}{$priority} ||= [];
            push @{$API::Std::HOOKS{lc $event}{$priority}}, [$name, _owned_callback($owner, $sub), $owner];
            return 1;
        }
        else {
            return;
        }
    }
    else {
        return;
    }
}

# Delete a hook from Auto.
sub hook_del {
    my ($event, $name) = @_;
    return _is_teardown() ? 1 : undef unless defined $event && defined $name;

    foreach my $priority (keys %{$API::Std::HOOKS{lc $event} || {}}) {
        my $a = $API::Std::HOOKS{lc $event}{$priority};
        @$a = grep { lc $_->[0] ne lc $name
            || (_is_teardown() && (!$_->[2] || $_->[2] != $MODULE_CONTEXT)) } @$a;

        # Check if there's any hooks left for this priority.
        if (scalar @$a == 0) {
            # There isn't.
            delete $API::Std::HOOKS{lc $event}{$priority};
        }
    }
    return 1;
}

# Check if a hook exists.
sub hook_exists {
    my ($event, $name) = @_;
    return unless defined $event && defined $name;
    foreach my $priority (keys %{$API::Std::HOOKS{lc $event} || {}}) {
        my $a = $API::Std::HOOKS{lc $event}{$priority};
        if (grep { lc $_->[0] eq lc $name } @$a) { return 1; }
    }
    return;
}


# Add a timer to Auto.
sub timer_add {
    my ($name, $type, $time, $sub) = @_;
    $name = lc $name;

    # Check for invalid type/time.
    if ($type =~ m/[^1-2]/sm) { ## no critic qw(RegularExpressions::RequireExtendedFormatting)
        return;
    }
    if ($time =~ m/[^0-9]/sm) { ## no critic qw(RegularExpressions::RequireExtendedFormatting)
        return;
    }

    my $owner = _registration_owner();
    return unless _can_register($owner);
    if (!defined $Auto::TIMERS{$name}) {
        my $timer = Auto::Timer->new(
            name     => $name,
            function => _owned_callback($owner, $sub),
            delay    => $time,
            type     => $type
        );
        return unless $timer;
        $timer->{module_owner} = $owner;
        $Auto::TIMERS{$name} = $timer;
        $timer->go;
        return 1;
    }

    # An existing timer is not a successful registration.
    return;
}

# Delete a timer from Auto.
sub timer_del {
    my ($name) = @_;
    $name = lc $name;

    if (defined $Auto::TIMERS{$name})
    {
        return if _is_teardown() && (!$Auto::TIMERS{$name}{module_owner}
            || $Auto::TIMERS{$name}{module_owner} != $MODULE_CONTEXT);
        $Auto::TIMERS{$name}->stop;
        $Auto::loop->remove($Auto::TIMERS{$name});
        delete $Auto::TIMERS{$name};
        return 1;
    }

    return _is_teardown() ? 1 : undef;
}

# Hook onto a raw command.
sub rchook_add {
    my ($cmd, $name, $sub) = @_;
    $cmd = uc $cmd;

    # If the hook already exists, ignore it.
    if (defined $RAWHOOKS{$cmd}{$name}) { return }
    
    my $owner = _registration_owner();
    return unless _can_register($owner);
    $RAWHOOKS{$cmd}{$name} = _owned_callback($owner, $sub);
    $RAW_OWNER{$cmd}{$name} = $owner if $owner;

    return 1;
}

# Delete a raw command hook.
sub rchook_del {
    my ($cmd, $name) = @_;
    $cmd = uc $cmd;

    # Make sure the hook exists.
    if (!defined $RAWHOOKS{$cmd}{$name}) { return _is_teardown() ? 1 : undef }
    return if _is_teardown() && (!$RAW_OWNER{$cmd}{$name}
        || $RAW_OWNER{$cmd}{$name} != $MODULE_CONTEXT);

    # Delete it.
    delete $RAWHOOKS{$cmd}{$name};
    delete $RAW_OWNER{$cmd}{$name};

    return 1;
}

# Configuration value getter.
sub conf_get {
    my ($value) = @_;

    # Create an array out of the value.
    my @val;
    if ($value =~ m/:/sm) { ## no critic qw(RegularExpressions::RequireExtendedFormatting)
        @val = split m/[:]/sm, $value; ## no critic qw(RegularExpressions::RequireExtendedFormatting)
    }
    else {
        @val = ($value);
    }
    # Undefine this as it's unnecessary now.
    undef $value;

    # Get the count of elements in the array.
    my $count = scalar @val;

    # Return the requested configuration value(s).
    if ($count == 1) {
        if (ref $Auto::SETTINGS{$val[0]} eq 'HASH') {
            return %{ $Auto::SETTINGS{$val[0]} };
        }
        else {
            return $Auto::SETTINGS{$val[0]};
        }
    }
    elsif ($count == 2) {
        if (ref $Auto::SETTINGS{$val[0]}{$val[1]} eq 'HASH') {
            return %{ $Auto::SETTINGS{$val[0]}{$val[1]} };
        }
        else {
            return $Auto::SETTINGS{$val[0]}{$val[1]};
        }
    }
    elsif ($count == 3) {
        if (ref $Auto::SETTINGS{$val[0]}{$val[1]}{$val[2]} eq 'HASH') {
            return %{ $Auto::SETTINGS{$val[0]}{$val[1]}{$val[2]} };
        }
        else {
            return $Auto::SETTINGS{$val[0]}{$val[1]}{$val[2]};
        }
    }
    else {
        return;
    }
}

# Translation subroutine.
sub trans {
    my $id = shift;
    $id =~ s/ /_/gsm;

    if (defined $API::Std::LANGE{$id}) {
        return sprintf $API::Std::LANGE{$id}, @_;
    }
    else {
        $id =~ s/_/ /gsm;
        return $id;
    }
}

# Match user subroutine.
sub match_user {
    my (%user) = @_;

    # Get data from config.
    if (!conf_get('user')) { return }
    my %uhp = conf_get('user');

    # Create an array of matches.
    my @matches = ();

    foreach my $userkey (keys %uhp) {
        # For each user block.
        my %ulhp = %{ $uhp{$userkey} };
        foreach my $uhk (keys %ulhp) {
            # For each user.

            if ($uhk eq 'net') {
                if (defined $user{svr}) {
                    if (lc $user{svr} ne lc(($ulhp{$uhk})[0][0])) {
                        # config.user:net conflicts with irc.user:svr.
                        last;
                    }
                }
            }
            elsif ($uhk eq 'mask') {
                # Put together the user information.
                my $mask = $user{nick}.q{!}.$user{user}.q{@}.$user{host};
                if (API::IRC::match_mask($mask, ($ulhp{$uhk})[0][0])) {
                    # We've got a host match.
                    push @matches, $userkey;
                }
            }
            elsif ($uhk eq 'chanstatus' and defined $ulhp{'net'}) {
                my ($ccst, $ccnm) = split m/[:]/sm, ($ulhp{$uhk})[0][0]; ## no critic qw(RegularExpressions::RequireExtendedFormatting)
                my $svr = $ulhp{net}[0];
                if (defined $Auto::SOCKET{$svr}) {
                    if ($ccnm eq 'CURRENT' and defined $user{chan}) {
                        if (defined $State::IRC::chanusers{$svr}{$user{chan}}{lc $user{nick}}) {
                            if ($State::IRC::chanusers{$svr}{$user{chan}}{lc $user{nick}} =~ m/($ccst)/sm) { push @matches, $userkey; } ## no critic qw(RegularExpressions::RequireExtendedFormatting)
                        }
                    }
                    else {
                        foreach my $bcj (keys %{ $Proto::IRC::botchans{$svr} }) {
                            if (lc($bcj) eq lc($ccnm)) {
                                if (defined $State::IRC::chanusers{$svr}{$bcj}{lc $user{nick}}) {
                                    if ($State::IRC::chanusers{$svr}{$bcj}{lc $user{nick}} =~ m/($ccst)/sm) { push @matches, $userkey; } ## no critic qw(RegularExpressions::RequireExtendedFormatting)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return @matches;
}

# Privilege subroutine.
sub has_priv {
    my (@matches, $cpriv) = @_;

    foreach my $cuser (@matches) {
        if (conf_get("user:$cuser:privs")) {
            my $cups = (conf_get("user:$cuser:privs"))[0][0];

            if (defined $Auto::PRIVILEGES{$cups}) {
                foreach (@{ $Auto::PRIVILEGES{$cups} }) {
                    if ($_) { if ($_ eq $cpriv or $_ eq 'ALL') { return 1 } }
                }
            }
        }
    }

    return;
}

# Ratelimit check subroutine.
sub ratelimit_check {
    my (%src) = @_;

    # Check if ratelimit is set to on.
    if ((conf_get('ratelimit'))[0][0] == 1) {
        if (!defined $Core::IRC::usercmd{$src{nick}.'@'.$src{host}.'/'.$src{svr}}) {
            # Set a usercmd entry for this user.
            $Core::IRC::usercmd{$src{nick}.'@'.$src{host}.'/'.$src{svr}} = 0;
        }

        # If the user has not passed the rate limit.
        if ($Core::IRC::usercmd{$src{nick}.'@'.$src{host}.'/'.$src{svr}} <= (conf_get('ratelimit_amount'))[0][0]) {
            # Increment their uses and return 1.

            $Core::IRC::usercmd{$src{nick}.'@'.$src{host}.'/'.$src{svr}}++;
            return 1;
        }
        else {
            # Increment their uses and return false.
            $Core::IRC::usercmd{$src{nick}.'@'.$src{host}.'/'.$src{svr}}++;
            return;
        }
    }
    else {
        # It isn't. Return 1.
        return 1;
    }

    return 1;
}

# Error subroutine.
sub err { ## no critic qw(Subroutines::ProhibitBuiltinHomonyms)
    my ($lvl, $msg, $fatal) = @_;

    # Check for an invalid level.
    if ($lvl =~ m/[^0-9]/sm) { ## no critic qw(RegularExpressions::RequireExtendedFormatting)
        return;
    }
    if ($fatal =~ m/[^0-1]/sm) { ## no critic qw(RegularExpressions::RequireExtendedFormatting)
        return;
    }

    # Level 1: Print to screen.
    if ($lvl >= 1) {
        say "ERROR: $msg";
    }
    # Level 2: Log to file.
    if ($lvl >= 2) {
        API::Log::alog("ERROR: $msg");
    }
    # Level 3: Log to IRC.
    if ($lvl >= 3) {
        API::Log::slog("ERROR: $msg");
    }

    # If it's a fatal error, exit the program.
    if ($fatal) {
        event_run('on_shutdown');
        exit;
    }

    return 1;
}

# Warn subroutine.
sub awarn {
    my ($lvl, $msg) = @_;

    # Check for an invalid level.
    if ($lvl =~ m/[^0-9]/sm) { ## no critic qw(RegularExpressions::RequireExtendedFormatting)
        return;
    }

    # Level 1: Print to screen.
    if ($lvl >= 1) {
        say "WARNING: $msg";
    }
    # Level 2: Log to file.
    if ($lvl >= 2) {
        API::Log::alog("WARNING: $msg");
    }
    # Level 3: Log to IRC.
    if ($lvl >= 3) {
        API::Log::slog("WARNING: $msg");
    }

    return 1;
}

# Formatting a file path.
sub fpfmt {
    my ($path) = @_;

    if ($path =~ m/\s/xsm) { return "\"$path\"" }
    else { return $path }
}


1;
# vim: set ai et sw=4 ts=4:
