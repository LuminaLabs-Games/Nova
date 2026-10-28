# NovaData

The player data layer every LuminaLabs game copied in as `src/server/Data`, now a package. It runs
ProfileStore sessions, replicated to clients with Replica, and handles developer product receipts,
cross-server messages, migrations, versioned resets and wipe marks. It does not need Nova, so it
works in a Shard game too.

```toml
# wally.toml
[dependencies]
NovaData = "luminalabsgames/novadata@0.1.0"
ReplicaShared = "luminalabsgames/replicashared@1.0.0" # see "Requirements"

[server-dependencies]
ProfileStore = "lm-loleris/profilestore@1.0.3"
```

## Requirements

- **ProfileStore** must be the game's own server dependency. NovaData finds it at
  `ServerScriptService.ServerPackages.ProfileStore`, or you can pass `profileStore = require(...)`.
- **ReplicaShared** must be listed in the game's own `wally.toml`. ReplicaServer and ReplicaClient
  1.0.x require it at `ReplicatedStorage.Packages.ReplicaShared`, and Wally only creates that link
  for packages the game lists itself. Every LuminaLabs game already lists it.

## Setup

```lua
-- ServerScriptService/Boot.server.luau
Nova.boot({
	modules = script.Parent.Services,
	before = function()
		NovaData.start({
			template = require(script.Parent.DataTemplate), -- every new save starts as this
			productionPlaceId = 1234567890,
		})
	end,
})

-- StarterPlayerScripts/Boot.client.luau
Nova.boot({ modules = script.Parent.Controllers, after = NovaData.request })
```

`start` does not yield; saves load on their own threads. The client calls `request` once, after
every controller's observers are connected.

## Server

```lua
local profile = NovaData.awaitProfile(player) -- yields; nil if they left or it failed
local profile = NovaData.getProfile(player)   -- nil until loaded, never yields

profile:Get("Cash")                            -- a key name
profile:Get("Experience")                      -- a name unique in the template: Stats.Experience
profile:Get("Stats.Level")                     -- a dotted path
profile:Get({ "Inventory", itemId })           -- a list path, for keys the template does not have
profile:Set("Cash", 100)
profile:Increment("Cash", 25)                  -- never below 0; Decrement too
if profile:Spend("Cash", 50) then ... end      -- takes it only if they have it
profile:Insert({ "Inventory" }, item)          -- returns the index
profile:Remove({ "Inventory" }, 3)             -- returns what was removed
profile:GetPlayer(), profile:GetUserId(), profile:GetProfile(), profile:GetReplica(), profile:IsActive()

NovaData.observeProfiles(function(player, profile)
	-- each loaded save, now and later
	return function() end -- runs as they leave, before the session closes
end)
```

The profile methods keep the names from the Shard-era template, so service code ports as it is.

- **Always write through these methods.** The save and the replica share one table. A write
  straight into a table that `Get` returned is saved but never reaches the client.
- **Names are looked up in the template, not the live save.** A top-level key always wins. A
  nested name works when only one table in the template has it. A misspelt or ambiguous name
  errors and says what it could be. (The template version searched the live save and returned
  whichever match it found first.)

| Function | |
| --- | --- |
| `onProduct(productId, fn(profile, receipt))` | What a developer product grants. Errors or returning `false` mean it did not land, and Roblox retries. Each purchase is granted once and acknowledged only after it is saved. The purchase history holds 1,000 entries |
| `onMessage(kind, fn(profile, message))` | Handles ProfileStore messages like `{ "Gift", "Cash", 25000 }`. Return `true` once it has landed. Unknown kinds are kept, not lost. Register at require time |
| `sendMessage(userId, message)` | Queues a message for any save, online or offline, on any server |
| `markForWipe(player)` | Empties the save back to the template the next time it opens (purchase history kept). Send the player away afterwards |
| `isMock()`, `keyFor(userId)`, `store()` | Whether this server uses the mock store, the DataStore key, and the ProfileStore store for offline reads |

**When a save opens,** these steps run before any service or client can see it:

1. A save marked for a wipe is emptied.
2. A save from before `reset.version` is rebuilt from the template. It keeps `reset.keep` and the
   purchase history.
3. `Reconcile` fills in any template keys the save is missing.
4. `migrations` run in order on a copy, starting from the save's `DataVersion`. If one throws, the
   player is kicked and their save stays exactly as it was. Brand-new, wiped and reset saves skip
   migrations. Migrations must not yield.

### Options

| Option | Default | |
| --- | --- | --- |
| `template` | required | The table every new save starts as |
| `productionPlaceId` | `0` | Live servers in this place save under `productionSuffix`. Everything else, Studio included, uses `developmentSuffix` |
| `developmentSuffix`, `productionSuffix` | `"_DEVELOPMENT"`, `"_PRODUCTION"` | Change the development suffix to give every tester a fresh save |
| `mock` | `true` | In Studio, use the mock store, which starts empty every playtest |
| `replicateTo` | `"owner"` | `"everyone"` when other players' data is shown (for example a nametag level). The template replicated every save to every client |
| `migrations` | `{}` | A list of `function(data, player)` |
| `versionKey` | `"DataVersion"` | Where the migration count is stored. Keep it out of the template |
| `reset` | none | `{ version = "2026-11-01", keep = { "Passes" } }` |
| `receipts` | `true` | Set to false to handle `ProcessReceipt` yourself |
| `spentKey` | none | For example `"RobuxSpent"`: adds each receipt's Robux, counted once per purchase |
| `purchaseHistory` | `1000` | How many purchase ids each save remembers |
| `storeName`, `token` | `"PlayerStore"`, `"PlayerData"` | |
| `loadFailedMessage`, `sessionEndedMessage` | | Kick messages |

## Client

```lua
NovaData.observe("Cash", function(cash) ... end) -- once the data arrives, then on every change at or under the path
NovaData.read("Stats.Level")                      -- nil until it arrives
NovaData.ready(10)                                -- yields until it arrives; false on a timeout
NovaData.readFor(otherPlayer, "Stats.Level")      -- only with replicateTo = "everyone"
```

These replace the block every NeedohEscape controller repeated: `ReplicaClient.OnNew("PlayerData")`,
a check that the replica belonged to the local player, then an `OnSet` per key. Paths resolve the
same way as on the server. Writes happen on the server only, so send a packet and let a service do
the write.

## What changed from the Shard-era template

- **Fixed:** a player who left while their save loaded still got a replica and a profile entry.
- **Fixed:** `GetUserId` returned a field that was never set, so the by-UserId cleanup never ran.
- **Fixed:** `GetProfileAsync` busy-waited every frame. `awaitProfile` waits on the load itself.
- **Changed:** replication goes to the owner only, unless `replicateTo = "everyone"`.
- **Folded in from CarSteal:** message handlers registered by kind, wipe marks, versioned resets,
  the 1,000-entry purchase history, and grants that error instead of consuming a receipt.
- **New:** migrations, which run on a copy and leave a save untouched if one fails.
