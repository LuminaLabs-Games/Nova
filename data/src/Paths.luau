--!strict
--[[
	Paths: how a key name becomes a path into a save.

	A path is a list of keys (`{ "Stats", "Level" }`), a dotted string (`"Stats.Level"`), or a key
	name (`"Cash"`, or `"Level"` for Stats.Level). Names are looked up in the data TEMPLATE, once,
	when the data layer starts:
	  * a top-level key always wins;
	  * a nested key works when exactly one table in the template has it;
	  * a name in more than one place, or in none, is an error that says what it could be.

	The template's shape is the index, never a live save. The Shard-era template searched the live
	data recursively, so a nested "Level" came back from whichever table the iteration reached first,
	and a key a save happened to hold (an inventory item id) could match. A key the template does not
	have, such as an item id under Inventory, is reached with a list path.

	The compiled index is plain data so it can ride to the client on the replica's tags, and both
	sides resolve a name the same way.
]]

export type Path = { any }
export type Compiled = {
	names: { [string]: Path },
	ambiguous: { [string]: string },
}

local Paths = {}

local function isDictionary(value: any): boolean
	return type(value) == "table" and #value == 0 and next(value) ~= nil
end

local function distance(a: string, b: string): number
	a, b = string.lower(a), string.lower(b)
	local previous = {}
	for j = 0, #b do
		previous[j] = j
	end
	for i = 1, #a do
		local current = { [0] = i }
		for j = 1, #b do
			local cost = if string.byte(a, i) == string.byte(b, j) then 0 else 1
			current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
		end
		previous = current
	end
	return previous[#b]
end

--- " Did you mean Cash?" for a misspelt name, or "".
function Paths.suggest(name: string, candidates: { [string]: any }): string
	local best, bestDistance = nil, math.max(2, math.floor(#name / 3)) + 1
	for candidate in candidates do
		local d = distance(name, candidate)
		if d < bestDistance or (d == bestDistance and best and candidate < best) then
			best, bestDistance = candidate, d
		end
	end
	return if best then ` Did you mean {best}?` else ""
end

function Paths.compile(template: { [string]: any }): Compiled
	local names: { [string]: Path } = {}
	local nested: { [string]: { Path } } = {}
	local function walk(node: { [string]: any }, prefix: Path)
		for key, value in node do
			if type(key) ~= "string" then
				continue
			end
			local path = table.clone(prefix)
			table.insert(path, key)
			if #prefix == 0 then
				names[key] = path
			else
				nested[key] = nested[key] or {}
				table.insert(nested[key], path)
			end
			if isDictionary(value) then
				walk(value, path)
			end
		end
	end
	walk(template, {})

	local ambiguous: { [string]: string } = {}
	for name, found in nested do
		if names[name] then
			continue -- a top-level key of the same name wins
		end
		if #found == 1 then
			names[name] = found[1]
		else
			local spelled = {}
			for i, path in found do
				spelled[i] = table.concat(path, ".")
			end
			table.sort(spelled)
			ambiguous[name] = table.concat(spelled, ", ")
		end
	end
	return { names = names, ambiguous = ambiguous }
end

--[[ The path `path` stands for. Errors (level 0: the caller adds where) on a name the template does
	not have, or has in more than one place. ]]
function Paths.resolve(compiled: Compiled, path: any): Path
	local kind = type(path)
	if kind == "table" then
		if #path == 0 then
			error("an empty path; name at least one key", 0)
		end
		return path
	elseif kind == "string" then
		local found = compiled.names[path]
		if found then
			return found
		end
		if string.find(path, ".", 1, true) then
			local parts: Path = string.split(path, ".")
			for i, part in parts do
				if string.match(part, "^%d+$") then
					parts[i] = tonumber(part)
				end
			end
			return parts
		end
		local where = compiled.ambiguous[path]
		if where then
			error(`"{path}" is in more than one place in the data template ({where}); pass the one you mean`, 0)
		end
		error(`"{path}" is not in the data template.{Paths.suggest(path, compiled.names)} For a key the template does not have, pass a list path such as \{ "Inventory", itemId \}`, 0)
	end
	error(`a path is a key name, "A.B" or a list of keys; got a {typeof(path)}`, 0)
end

--- The value at `path` in `data`, or nil when any step is missing.
function Paths.read(data: any, path: Path): any
	local node = data
	for _, key in path do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
	end
	return node
end

--- True when a change at `changed` can alter the value at `watched` (one is a prefix of the other).
function Paths.overlaps(changed: { any }, watched: Path): boolean
	for i = 1, math.min(#changed, #watched) do
		if changed[i] ~= watched[i] then
			return false
		end
	end
	return true
end

return Paths
