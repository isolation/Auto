# Module loading and recovery

Modules keep the existing interface: call `API::Std::mod_init` with the module
name, author, version, and compatible Auto version; return true from `_init`
and `_void` on success. Editing a module does not require changing its version
number before reloading it.

The core tracks commands, event hooks, raw hooks, timers, aliases, and events
registered through `API::Std`. Registrations made while loading a module or
inside its registered callbacks belong to that load. Direct calls from a loaded
module's package also retain ownership. Each successful unload removes any
remaining registrations belonging to that module, including ones its `_void`
forgot to delete. Retained core callbacks from a previous load become inert.

If loading fails, the core removes registrations from that attempt. This covers
an `_init` that returns false or throws, and a file that fails after `_init` has
succeeded. Namespace cleanup before `mod_init` is reached assumes the bundled
module convention, `M::<filename>`. Missing resources are treated as already
cleaned during `_void`, so an unload can be retried after partial cleanup.
Outside teardown, delete operations retain their ordinary missing-resource
behavior. Adding a timer with an occupied name returns failure; it does not
replace the existing timer or acquire ownership of it.

## Recovering a module

Use the normal commands first:

```
MODRELOAD ModuleName
MODUNLOAD ModuleName
```

A false return or exception from `_void` does not automatically override a
module's refusal to unload. The command reports the reason. If cleanup is
broken, explicit recovery is available:

```
MODUNLOAD ModuleName FORCE
MODRELOAD ModuleName FORCE
```

`FORCE` attempts `_void`, then cleans up the module's core registrations even if
`_void` fails or is missing. It uses the same privileges as ordinary module
management. Failure to stop/remove a timer or unload a package is still reported
as failure, with a registry entry retained so cleanup can be retried. Callbacks
for a module whose core cleanup failed are disabled until it is unloaded.

Reload unloads the old module before executing the edited file. If loading the
new file fails, its registrations are cleaned up; the previous implementation
is not restored. Correct the source/configuration and use `MODLOAD ModuleName`.
If cleanup itself failed, resolve that error and use `MODUNLOAD ModuleName FORCE`
first.

## Module-owned external resources

Modules remain responsible for resources outside `API::Std`, such as private
sockets, subprocesses, HTTP requests, callbacks registered with other libraries,
and changes to another module's state. `FORCE` cannot guarantee cleanup of those
resources. Failed initialization must clean up any such private resources itself.
Modules should use the registration APIs rather than writing directly to core
hashes, and `_void` should tolerate resources that are already gone. If a module
intends to veto unloading, it should do so before modifying its resources.

After updating the core, restart the bot once to activate these changes and
begin tracking ownership. The new manager cannot reconstruct ownership of
resources registered by the old core.

## Verification

Run `prove t/*.t`. The module lifecycle tests use temporary module files and the
real registration and timer code. They use stand-ins for networking, the event
loop, and the database; they use `Class::Unload` if installed, otherwise a symbol
table cleanup stand-in. These tests do not connect a live IRC bot.
