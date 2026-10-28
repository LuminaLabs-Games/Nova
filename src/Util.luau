--!strict
-- Small helpers shared by the rest of Nova.

local Util = {}

local function distance(a: string, b: string): number
	a, b = string.lower(a), string.lower(b)
	local la, lb = #a, #b
	if la == 0 then
		return lb
	end
	if lb == 0 then
		return la
	end
	local previous = table.create(lb + 1, 0)
	for j = 0, lb do
		previous[j + 1] = j
	end
	for i = 1, la do
		local current = { i }
		local ca = string.byte(a, i)
		for j = 1, lb do
			local cost = if ca == string.byte(b, j) then 0 else 1
			current[j + 1] = math.min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
		end
		previous = current
	end
	return previous[lb + 1]
end

--[[
	" Did you mean CombatService?" for a misspelt name, or "" when nothing is close. `candidates` is
	a list or the keys of a dictionary.
]]
function Util.suggest(name: string, candidates: { [any]: any }): string
	local names = {}
	for key, value in candidates do
		local candidate = if type(key) == "string" then key else value
		if type(candidate) == "string" then
			table.insert(names, candidate)
		end
	end
	local limit = math.max(2, math.floor(#name / 3))
	local scored = {}
	for _, candidate in names do
		local d = distance(name, candidate)
		if d <= limit then
			table.insert(scored, { candidate, d })
		end
	end
	if #scored == 0 then
		return ""
	end
	table.sort(scored, function(x, y)
		return if x[2] == y[2] then x[1] < y[1] else x[2] < y[2]
	end)
	local picks = {}
	for i = 1, math.min(3, #scored) do
		picks[i] = scored[i][1]
	end
	return " Did you mean " .. table.concat(picks, " or ") .. "?"
end

--- Sorted keys of a dictionary.
function Util.keys(dictionary: { [string]: any }): { string }
	local keys = {}
	for key in dictionary do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--- Errors when `options` holds a key that is not in `allowed`, naming the closest one.
function Util.checkKeys(options: { [any]: any }, allowed: { string }, what: string)
	local set = {}
	for _, key in allowed do
		set[key] = true
	end
	for key in options do
		if not set[key] then
			error(`{what} got an unknown option "{tostring(key)}".{Util.suggest(tostring(key), allowed)}`, 3)
		end
	end
end

return Util
