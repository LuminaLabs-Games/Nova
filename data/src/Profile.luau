--!strict
--[[
	Profile: one player's save, as services see it (`NovaData.getProfile(player)`).

		profile:Get("Cash")                      -- a key name, "Stats.Level", or { "Inventory", id }
		profile:Set("Cash", 100)
		profile:Increment("Cash", 25)            -- never below 0
		if profile:Spend("Cash", 50) then ... end -- takes it only if they can afford it
		profile:Insert({ "Inventory" }, item)
		profile:Remove({ "Inventory" }, 3)

	WRITE THROUGH THESE, NEVER INTO A TABLE `Get` RETURNED. The save and the replica share one table,
	so a direct write is saved but never reaches the client. Every method here goes through the
	replica, which writes the save and replicates in one step.

	The names match the Shard-era PlayerProfile (Get, Set, Increment, Decrement, CanAfford,
	GetPlayer, GetProfile, GetReplica, IsActive), so a service ports without edits. What changed:
	name lookup uses the template (see Paths), a misspelt key errors instead of reading nil,
	`GetUserId` answers (it returned a field nothing set), and `Spend` checks and takes in one call.
]]

local Paths = require(script.Parent.Paths)

export type PathLike = string | { any }

export type Profile = {
	Get: (self: Profile, path: PathLike?) -> any,
	Set: (self: Profile, path: PathLike, value: any) -> any,
	Increment: (self: Profile, path: PathLike, amount: number) -> number?,
	Decrement: (self: Profile, path: PathLike, amount: number) -> number?,
	CanAfford: (self: Profile, path: PathLike, cost: number) -> boolean,
	Spend: (self: Profile, path: PathLike, cost: number) -> boolean,
	Insert: (self: Profile, path: PathLike, value: any, index: number?) -> number?,
	Remove: (self: Profile, path: PathLike, index: number) -> any,
	GetPlayer: (self: Profile) -> Player,
	GetUserId: (self: Profile) -> number,
	GetProfile: (self: Profile) -> any,
	GetReplica: (self: Profile) -> any,
	IsActive: (self: Profile) -> boolean,
}

local Profile = {}
Profile.__index = Profile

function Profile.new(player: Player, profile: any, replica: any, paths: Paths.Compiled): Profile
	return (setmetatable({
		_player = player,
		_userId = player.UserId,
		_profile = profile,
		_replica = replica,
		_paths = paths,
	}, Profile) :: any) :: Profile
end

-- Resolves `path`, pointing an error at the game code that called the method.
local function resolve(self: any, path: any): Paths.Path
	local ok, result = pcall(Paths.resolve, self._paths, path)
	if not ok then
		error(`NovaData: {result}`, 3)
	end
	return result
end

local function number(self: any, path: Paths.Path, what: string): number
	local value = Paths.read(self._profile.Data, path)
	if type(value) ~= "number" then
		error(`NovaData: {what} needs a number at {table.concat(path :: any, ".")}, which holds a {typeof(value)}`, 3)
	end
	return value
end

--- The value at `path`, or the whole save with no path. Nil once the session has ended.
function Profile.Get(self: any, path: PathLike?): any
	if not self._profile:IsActive() then
		return nil
	end
	if path == nil then
		return self._profile.Data
	end
	return Paths.read(self._profile.Data, resolve(self, path))
end

--- Writes and replicates. Returns the value, or nil once the session has ended.
function Profile.Set(self: any, path: PathLike, value: any): any
	if not self._profile:IsActive() then
		return nil
	end
	self._replica:Set(resolve(self, path), value)
	return value
end

--- Adds `amount` (negative to take away), never going below 0. Returns the new value.
function Profile.Increment(self: any, path: PathLike, amount: number): number?
	if not self._profile:IsActive() then
		return nil
	end
	local resolved = resolve(self, path)
	local value = math.max(0, number(self, resolved, "Increment") + amount)
	self._replica:Set(resolved, value)
	return value
end

--- Takes `amount` away, never going below 0. Returns the new value.
function Profile.Decrement(self: any, path: PathLike, amount: number): number?
	if not self._profile:IsActive() then
		return nil
	end
	local resolved = resolve(self, path)
	local value = math.max(0, number(self, resolved, "Decrement") - amount)
	self._replica:Set(resolved, value)
	return value
end

function Profile.CanAfford(self: any, path: PathLike, cost: number): boolean
	if not self._profile:IsActive() then
		return false
	end
	local value = Paths.read(self._profile.Data, resolve(self, path))
	return type(value) == "number" and value >= cost
end

--[[ Takes `cost` only if they have it, and says whether it did. One call, so nothing can spend the
	same balance between the check and the take. ]]
function Profile.Spend(self: any, path: PathLike, cost: number): boolean
	if not self._profile:IsActive() then
		return false
	end
	local resolved = resolve(self, path)
	local value = number(self, resolved, "Spend")
	if value < cost then
		return false
	end
	self._replica:Set(resolved, value - cost)
	return true
end

--- Appends to (or inserts into) the list at `path`. Returns the index it went in at.
function Profile.Insert(self: any, path: PathLike, value: any, index: number?): number?
	if not self._profile:IsActive() then
		return nil
	end
	return self._replica:TableInsert(resolve(self, path), value, index)
end

--- Removes entry `index` from the list at `path`. Returns what was removed.
function Profile.Remove(self: any, path: PathLike, index: number): any
	if not self._profile:IsActive() then
		return nil
	end
	return self._replica:TableRemove(resolve(self, path), index)
end

function Profile.GetPlayer(self: any): Player
	return self._player
end

function Profile.GetUserId(self: any): number
	return self._userId
end

--- The ProfileStore profile underneath (Data, LastSavedData, OnSave, Save, ...).
function Profile.GetProfile(self: any): any
	return self._profile
end

function Profile.GetReplica(self: any): any
	return self._replica
end

function Profile.IsActive(self: any): boolean
	return self._profile:IsActive()
end

return Profile
