# Nova

Shard v2. Nova keeps the Shard features our games actually use (the builder, `get`, per-module
logs, dependencies, cleanup, signals, config, feature flags) and cuts the rest. It adds a boot that
one broken module cannot take down, live feature flags, an event bus with real connections, and a
typed, buffer-packed network layer.

```toml
# wally.toml
[dependencies]
Nova = "luminalabsgames/nova@0.1.0"
```

Nova's only dependency is `sleitnick/trove`. The player data layer is a separate package in this
repo, [NovaData](data/README.md) (`luminalabsgames/novadata`). It runs in Nova's `before` hook on
the server and its `after` hook on the client. The repo also publishes LuminaLabs' patched
[Iris](iris/README.md) (`luminalabsgames/iris`) for debug and admin UI, used in place of
`sirmallard/iris`. Nova does not depend on it.

## A game's layout

```
ReplicatedStorage/Shared/    Packets.luau, Events.luau, Flags.luau
ServerScriptService/         Boot.server.luau, Services/
StarterPlayerScripts/        Boot.client.luau, Controllers/
```

```lua
-- ServerScriptService/Boot.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Nova = require(ReplicatedStorage.Packages.Nova)

Nova.boot({
	modules = script.Parent.Services,
	flags = ReplicatedStorage.Shared.Flags,
	before = function()
		Data:initialize() -- the data layer stays game code, and runs before any init
	end,
})

-- StarterPlayerScripts/Boot.client.luau
Nova.boot({
	modules = script.Parent.Controllers,
	flags = ReplicatedStorage.Shared.Flags,
	waitForServer = 60,
	after = function()
		ReplicaClient.RequestData()
	end,
})
```

Controllers live in StarterPlayerScripts from the start, so their path is the same in edit mode
and in a playtest. `modules` takes a folder or a list of folders. Nova requires every ModuleScript
under it, but not the children of a ModuleScript, which belong to that module.

## Modules

```lua
local CombatService = Nova.new("CombatService")
	:withDependencies({ "InventoryService" })
	:withSignals({ "ShotFired" })
	:withFlags({ NewRecoil = false })
	:withConfig({ Range = 500 })
	:withCleanup(function(self) ... end)
	:withLifecycle({
		init = function(self)
			self.inventory = Nova.get("InventoryService") -- allowed: declared above
		end,
		start = function(self)
			Packets.Fire:listen(function(player, shot) ... end)
		end,
	})
```

`Nova.new` makes a service on the server and a controller on the client. You can also declare the
phases as plain `function CombatService:init()` and `:start()` methods.

| On the module | |
| --- | --- |
| `self.name`, `self.log`, `self.trove` | The only fields Nova adds. Its own state lives under `_nova`, so game fields cannot shadow it. |
| `:getSignal(name)` | Returns a signal from `withSignals`. A misspelt name errors and suggests the closest one. |
| `:flag(name, player?)` | Returns a flag's value (see Flags). |
| `:getConfig(key, default?)` | Returns a value from `withConfig`. A missing key errors unless you pass a default. |
| `:withCleanup(fn \| thing)` | Adds to `self.trove`. A function is called with `self`. |
| `:destroy()` | Cleans the trove and disconnects the signals. Nova calls this on a module that fails to boot. |

| Nova | |
| --- | --- |
| `Nova.get(name)` | Never returns nil. An unknown name errors and suggests the closest names. During init it returns only the caller's dependencies (and theirs), and a module that failed to boot errors. |
| `Nova.await(name, timeout?)` | For code outside a module. Yields on a signal until `get` can answer, and errors after `timeout` seconds (30 by default). |
| `Nova.report()` | Returns what failed, what was skipped, the timing of each phase, the slowest phase and the server's status. |
| `Nova.log`, `Nova.logger(name)`, `Nova.setLogLevel(level)` | Logging for code outside a module. |

## Boot

1. **One order for both phases.** Modules are sorted by `withDependencies`, with ties broken by
   name, and `start` follows that order too. Shard ordered `init` only.
2. **`init` must not yield.** A yielding init is failed and named. `WaitForChild`, DataStore calls
   and anything else that waits belong in `start`.
3. **Each `start` runs on its own thread, in order.** A start that waits holds up nobody. If you
   need something another module makes in its start, wait for that thing, not for the module.
4. **One failure costs one module** (CarSteal's BootGuard, built in). A module that fails to load,
   or throws in init or start, is logged with a traceback and marked failed. Modules that declared
   it as a dependency are skipped, and everything else boots.
5. **Stalls are named.** A require, hook or start still running after 10 seconds
   (`stallWarning`) is named in the log.
6. **Mistakes stop the boot before any init runs:** two modules with one name (the duplicate
   ModuleScript trap), a dependency that does not exist, or a dependency cycle (printed `A > B > A`).
7. **The client never waits forever.** Once every start has returned, the server sets
   `NovaServerReady` on Workspace (and `NovaServerFailed` naming any failures). The client waits up
   to `waitForServer` seconds for it, then boots anyway and says why. It then waits up to 10 more
   seconds for this player's flags to settle (see Flags).

For a join screen, these attributes are on Workspace: `NovaServerReady`, `NovaServerFailed`, and
on the client only, `NovaClientReady`, `NovaClientFailed`, `NovaBootSlowest` and
`NovaBootSlowestSeconds`. They are on Workspace because attributes the server sets on
ReplicatedFirst never reach clients.

## Flags

```lua
-- ReplicatedStorage/Shared/Flags.luau: every flag in the game
return {
	NewRecoil = false,
	StreakDisplay = "notification",                -- "badge" | "notification"
	SkipIntro = { default = false, studio = true }, -- a different value in Studio playtests
}

if self:flag("NewRecoil") then ... end
Nova.flags.observe("StreakDisplay", function(value) ... end) -- runs now, then on every change
```

A flag's value comes from these sources, highest first:

1. **One player:** a `Flag_<Name>` attribute on the Player. The server writes it from
   `Nova.flags.setProvider(fn(name, player))`, for example an A/B group, or from
   `Nova.flags.setFor(player, name, value)`, for example an admin command.
2. **The whole server, live:** an attribute on `ReplicatedStorage.NovaFlags`. The server creates
   this object at boot with every flag on it, so the Properties panel lists them all, and
   `Nova.flags.set(name, value)` flips one. `set(name, nil)` puts it back to its default.
3. **The default** in Flags.luau, or a module's `withFlags` when Flags.luau lacks the flag. When
   both give a value and they differ, boot warns and Flags.luau wins.

Clients read flags and never write them. Only a flag the server knows (Flags.luau, or a service's
`withFlags`) can be flipped live. A flag that only a controller declares is a fixed default, and
the client boot warns about it. A flag is a boolean, number or string, and a value of the
wrong type is ignored with a warning. A name nobody declared errors (`flag("NewRecoli")`) instead
of reading as off. If a `NovaFlags` object is saved in the place, its values override the defaults
for the whole place, and the boot log lists every flag it changes.

**Debug logs:** the built-in `NovaDebug` flag holds a list of module names (`"CombatService,
InventoryService"`, or `"*"` for all). `self.log:debug(...)` lines from those modules print. Like
any flag you can flip it live, or set it per player to see one tester's client logs. This replaces
1.0.8's `debugMode` flag, which each service had to declare.

## Bus

Events and states shared by a whole side (server or client). It replaces Dispatcher.

```lua
-- ReplicatedStorage/Shared/Events.luau
return Nova.bus.define({
	PageOpened = Nova.bus.event() :: Nova.Event<string>,
	Showcasing = Nova.bus.state(false),
})

local connection = Events.PageOpened:Connect(function(page) ... end)
connection:Disconnect()              -- removes this listener and no other
Events.PageOpened:Fire("Inventory")
Events.Showcasing:set(true)
Events.Showcasing:observe(function(on) ... end) -- runs now with the current value, then on change
```

Every listener runs on its own thread, straight away and in order, so one that throws or yields
affects nobody else. Events have no return values: to ask another module something, call it. A
misspelt event errors.

## Net

```lua
-- ReplicatedStorage/Shared/Packets.luau, required by both sides
local Net = require(ReplicatedStorage.Packages.Nova).Net
local t = Net.types

return Net.define({
	Fire = Net.packet({
		from = "client",
		data = t.struct({ weapon = t.u8, origin = t.vector3, direction = t.unitVector, shotTime = t.f64 }),
		rate = 20, -- per player, per second
	}),
	Aim = Net.packet({
		from = "client", reliable = false, latestOnly = true,
		data = t.struct({ pitch = t.angle, yaw = t.angle }), rate = 60,
	}),
	HitConfirm = Net.packet({
		from = "server",
		data = t.struct({ target = t.instance("Model"), damage = t.u16, headshot = t.bool }),
	}),
	CraftItem = Net.request({
		data = t.struct({ recipe = t.u16 }),
		reply = t.struct({ ok = t.bool, reason = t.optional(t.string(64)) }),
		rate = 5, timeout = 10,
	}),
})
```

```lua
-- client
Packets.Fire:send(shot)
Packets.HitConfirm:listen(function(hit) ... end)
local reply = Packets.CraftItem:invoke({ recipe = 12 }) -- yields; errors on failure or timeout

-- server
Packets.Fire:listen(function(player, shot) ... end)
Packets.HitConfirm:sendTo(player, hit) -- also sendAll, sendExcept, sendList, sendFilter, sendNear
Packets.CraftItem:handle(function(player, request) return { ok = true } end)
Nova.Net.onAbuse(function(player, packetName, reason) ... end)
```

| Type | Bytes | Notes |
| --- | --- | --- |
| `u8 u16 u32`, `i8 i16 i32` | 1, 2, 4 | Out-of-range values error on send |
| `f32 f64` | 4, 8 | NaN and infinity are rejected |
| `bool` | 1 | |
| `string(max)` | 1–2 + length | Longer than `max` errors on send. The server also rejects invalid UTF-8 |
| `vector3` | 12 | |
| `unitVector` | 4 | Octahedral encoding, worst error under 0.01° |
| `angle` | 2 | Radians in 0.0055° steps, decoded to (−π, π] |
| `cframe` | 19 | Position plus a smallest-three quaternion, worst rotation error under 0.01° |
| `instance(class?)` | 0 | Sent beside the buffer and read back in order. Can arrive nil on a client that has not streamed it in |
| `enum({ ... })` | 1 | A list of strings, sent as its index |
| `optional(T)` | 1 + T | |
| `array(T, max)` | 1–2 + n × T | |
| `struct({ ... })` | sum of fields | Field names are never sent, and a field the struct lacks errors on send |

Any number type takes a range that the server enforces, for example `t.u8({ max = 5 })` or
`t.f32({ min = 0, max = 1 })`.

- **Two remotes in total**, one reliable and one unreliable, created under the package. Each side
  sends one call per channel per frame, so reliable packets keep their order. A frame's reliable
  batch is split at 64 KB, the most the server accepts in one call. `Net.define` refuses a client
  packet that could never fit.
- **Packet ids** are the sorted names (1 byte, or 2 past 255 packets). A game has exactly one
  `Net.define`.
- **Unreliable batches** are flushed early to stay under 900 bytes (Roblox drops unreliable calls
  over 1,000). A packet that could never fit is an error at `Net.define`. `latestOnly` adds a
  2-byte sequence number, and the receiver drops anything older than the newest it has seen.
- **The server checks every read.** A malformed batch is dropped whole and counts one strike.
  `rate` is a token bucket per player per packet, with a burst of one second's worth. A client
  packet without a `rate` gets a Studio warning, and `rate = math.huge` means "no limit, on
  purpose". The game decides what strikes mean, through `Net.onAbuse`.
- **Packets that arrive before anything listens** are held (up to 64 per packet) and delivered to
  the first listener, as a RemoteEvent would. Reliable batches that arrive before this side's
  `Net.define` are held too. Unreliable ones are dropped, because nobody wants an old stream.
- **Requests** go client to server only. A handler that errors sends the client a plain failure,
  and the full error stays in the server log.
- `Net.stats()` prints sends, bytes and drops per packet per second, so a packet hogging bandwidth
  shows up by name.

Checking hits and rewinding positions belong in the game's combat code.

## From Shard to Nova

| Shard | Nova |
| --- | --- |
| `Shard.new(name)` | `Nova.new(name)` |
| `:withLifecycle({ init, start })` | Same, and `init` must not yield |
| `:withDependencies({ ... })` | Same, and it orders `start` too |
| `:withSignals`, `:getSignal(name)` | Same |
| `:withCleanup(fn)` | Same, but it now runs, and `fn` gets `self`. Shard never ran these |
| `:withConfig`, `:getConfig(key)` | Same. A missing key errors unless a default is given |
| `:withFeatureFlags`, `:isFeatureEnabled(name)` | `Flags.luau` or `:withFlags`, then `self:flag(name)` |
| `debugMode` flag and `self.log:setDebugEnabled` | The `NovaDebug` flag |
| `:withRemoteEvents({ "Name" })` then `:getRemoteEvent("Name"):Fire(...)` | `Packets.Name:send(data)`, declared once in Packets.luau |
| `:withRemoteEvents({ { Name = fn } })` | `Packets.Name:listen(fn)` |
| `FireClient`, `FireAll`, `FireAllExcept`, `FireFilter` | `sendTo`, `sendAll`, `sendExcept`, `sendFilter` |
| `:withRemoteFunctions` then `Invoke` | `Net.request`, then `:invoke` and `:handle` |
| `Dispatcher:Subscribe(name, fn)` / `:Publish(name, ...)` | `Events.Name:Connect(fn)` / `:Fire(...)` |
| A Started / Ended event pair | `Events.Name:set(on)` and `:observe(fn)` |
| `Shard.get(name)` | `Nova.get(name)` |
| `Shard.waitFor(name)` | `Nova.await(name, timeout)` |
| `Shard.init()`, `Shard.start()`, BootGuard, `ShardServerStarted` | `Nova.boot({ ... })` |
| `self.log:info(...)` | Same |

These are cut, because no game uses them: `withTags`/`getByTag`, `withBindableEvents/Functions`,
`withProfiling`/timers/metrics (use the MicroProfiler), `withHealthCheck`, `Shard.Player`,
`Shard.Server` and the Value package, the global `Shard.createRemote*` functions,
`getAllServices`/`exists`/`getDependencyGraph`/`getFrameworkStats`, and `HandleProgressionEvent`.

## Developing Nova

The Nova Development place runs this repo through `dev.project.json`. Use `rojo serve
dev.project.json`, or run `scripts/build-dev.sh` and import the five models in `build/`.
`dev/wally.toml` declares the dev place's packages the way a game would (Trove, Replica,
ProfileStore). Nova and NovaData themselves come from `src/` and `data/src/`.

- `dev/` is a small game that uses everything (Combat, Inventory, World and Ping, with crafting
  saved through NovaData), together with self-test fixtures.
- **Self-test:** add a Configuration named `NovaFlags` to ReplicatedStorage in edit mode, with a
  boolean attribute `NovaSelfTest = true`, then playtest. The server and client each print a
  `[NovaTest]` line per check (62 server and 25 client checks, covering failure isolation, ordering,
  flags, the bus, every codec, the wire end to end, and NovaData's paths, writes, receipts and
  replication). They leave `NovaServerTests` and
  `NovaClientTests` on ReplicatedStorage. The fixtures fail on purpose, so remove the override
  afterwards.
