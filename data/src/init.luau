--!strict
--[[
	NovaData: the starter player data layer every LuminaLabs game had copied as src/server/Data,
	made a package. ProfileStore sessions, replicated to clients with Replica, plus developer
	product receipts, cross-server messages, migrations, versioned resets and wipe marks.

	It does not need Nova and works beside Shard too. With Nova:

		-- ServerScriptService/Boot.server.luau
		Nova.boot({
			modules = script.Parent.Services,
			before = function()
				NovaData.start({ template = require(script.Parent.DataTemplate), productionPlaceId = 123 })
			end,
		})

		-- StarterPlayerScripts/Boot.client.luau
		Nova.boot({ modules = script.Parent.Controllers, after = NovaData.request })

	Server: start, getProfile, awaitProfile, observeProfiles, onProduct, onMessage, sendMessage,
	markForWipe, isMock, keyFor, store. Client: request, ready, read, readFor, observe. Calling one
	on the wrong side errors.

	ProfileStore is the game's own server dependency (lm-loleris/profilestore). README.md has the
	whole API.
]]

local RunService = game:GetService("RunService")

local Profile = require(script.Profile)

export type Profile = Profile.Profile

local IS_SERVER = RunService:IsServer()

local NovaData = {}

NovaData.version = "0.1.0"

-- The real functions on their own side (so error levels point at the caller), stubs on the other.
-- Neither module touches Replica or ProfileStore until start/request, so requiring is side-effect free.
local function side(module: ModuleScript, isServer: boolean, names: { string })
	local implementation: any = if IS_SERVER == isServer then require(module) :: any else nil
	for _, name in names do
		(NovaData :: any)[name] = if implementation
			then implementation[name]
			else function()
				error(`NovaData.{name} is {if isServer then "server" else "client"} only`, 2)
			end
	end
end

side(script.Server, true, {
	"start",
	"getProfile",
	"awaitProfile",
	"observeProfiles",
	"onProduct",
	"onMessage",
	"sendMessage",
	"markForWipe",
	"isMock",
	"keyFor",
	"store",
})
side(script.Client, false, { "request", "ready", "read", "readFor", "observe" })

return NovaData :: {
	version: string,
	start: (options: { [string]: any }) -> (),
	getProfile: (player: Player) -> Profile?,
	awaitProfile: (player: Player, timeout: number?) -> Profile?,
	observeProfiles: (fn: (player: Player, profile: Profile) -> (() -> ())?) -> { Disconnect: (any) -> () },
	onProduct: (productId: number, fn: (profile: Profile, receipt: { [string]: any }) -> any) -> (),
	onMessage: (kind: string, fn: (profile: Profile, message: { any }) -> boolean) -> (),
	sendMessage: (userId: number, message: { any }) -> boolean,
	markForWipe: (player: Player) -> boolean,
	isMock: () -> boolean,
	keyFor: (userId: number) -> string,
	store: () -> any,
	request: (options: { token: string? }?) -> (),
	ready: (timeout: number?) -> boolean,
	read: (path: any?) -> any,
	readFor: (player: Player, path: any?) -> any,
	observe: (path: any, fn: (value: any) -> ()) -> { Connected: boolean, Disconnect: (any) -> () },
}
