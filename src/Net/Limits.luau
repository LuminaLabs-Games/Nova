--!strict
--[[
	Limits: per-player rate buckets and abuse strikes, server side.

	`rate = 20` on a packet is a token bucket per player per packet: 20 a second, with a burst of
	one second's worth, so a client that lags and then delivers a second of traffic at once is not
	punished. Over the limit, the packet is dropped and counted.

	A strike is anything a real client could not have sent: a malformed batch, a value out of range,
	a packet the server sends, or traffic over a rate. Nova only counts them. What abuse means is the
	game's call: `Net.onAbuse(function(player, packetName, reason) ... end)` sees every one, and can
	log, flag or kick. Rate strikes can come from a laggy honest client, so act on a sustained count,
	not on one.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Parent.Signal)

local IS_STUDIO = RunService:IsStudio()

type Bucket = { tokens: number, last: number }

local Limits = {}

local buckets: { [Player]: { [number]: Bucket } } = {}
local strikes: { [Player]: number } = {}
local abused = Signal.new()
local lastWarning: { [string]: number } = {}

--- True when `player` may send one more `packet` now (and takes the token).
function Limits.take(player: Player, id: number, rate: number): boolean
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local now = os.clock()
	local capacity = math.max(rate, 1)
	local bucket = perPlayer[id]
	if not bucket then
		bucket = { tokens = capacity, last = now }
		perPlayer[id] = bucket
	end
	bucket.tokens = math.min(capacity, bucket.tokens + (now - bucket.last) * rate)
	bucket.last = now
	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

function Limits.strike(player: Player, packetName: string?, reason: string)
	strikes[player] = (strikes[player] or 0) + 1
	abused:Fire(player, packetName, reason)
	if IS_STUDIO or #(abused :: any)._listeners == 0 then
		-- One line per player and reason every 5 seconds, so a flood does not bury the Output.
		local key = `{player.UserId}:{packetName}:{string.sub(reason, 1, 24)}`
		local now = os.clock()
		if not lastWarning[key] or now - lastWarning[key] > 5 then
			lastWarning[key] = now
			warn(`[Nova.Net] strike {strikes[player]} for {player.Name}: {packetName or "batch"}: {reason}`)
		end
	end
end

function Limits.onAbuse(fn: (player: Player, packetName: string?, reason: string) -> ()): Signal.Connection
	return abused:Connect(fn)
end

function Limits.strikes(player: Player): number
	return strikes[player] or 0
end

Players.PlayerRemoving:Connect(function(player)
	-- Deferred, after any batch still being handled for this player in the same frame.
	task.defer(function()
		buckets[player] = nil
		strikes[player] = nil
	end)
end)

return Limits
