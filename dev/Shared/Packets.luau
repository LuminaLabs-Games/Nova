--[[
	Every packet in the game, required by both sides. Ids come from the sorted names, so both sides
	always agree. See the Nova README for the types.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Packages.Nova).Net
local t = Net.types

-- Every type Nova.Net has, for the self-test's round trip.
local Everything = t.struct({
	u8 = t.u8,
	u16 = t.u16,
	u32 = t.u32,
	i8 = t.i8,
	i16 = t.i16,
	i32 = t.i32,
	f32 = t.f32,
	f64 = t.f64,
	flag = t.bool,
	name = t.string(32),
	position = t.vector3,
	direction = t.unitVector,
	yaw = t.angle,
	pose = t.cframe,
	part = t.instance("BasePart"),
	mode = t.enum({ "idle", "run", "jump" }),
	some = t.optional(t.u8),
	none = t.optional(t.u8),
	list = t.array(t.u16, 8),
	nested = t.struct({ a = t.u8({ max = 9 }), b = t.string(8) }),
})

return Net.define({
	-- client to server, reliable: a shot the server must see
	Fire = Net.packet({
		from = "client",
		data = t.struct({
			weapon = t.u8,
			origin = t.vector3,
			direction = t.unitVector,
			shotTime = t.f64, -- workspace:GetServerTimeNow() when fired
		}),
		rate = 20,
	}),

	-- client to server, unreliable: where I am looking, every frame
	Aim = Net.packet({
		from = "client",
		reliable = false,
		latestOnly = true,
		data = t.struct({ pitch = t.angle, yaw = t.angle }),
		rate = 60,
	}),

	-- server to client
	HitConfirm = Net.packet({
		from = "server",
		data = t.struct({ target = t.instance("Model"), damage = t.u16, headshot = t.bool }),
	}),

	-- server to every client, unreliable: a stream where only the newest matters
	Snapshot = Net.packet({
		from = "server",
		reliable = false,
		latestOnly = true,
		data = t.struct({ tick = t.u32, pose = t.cframe }),
	}),

	-- client asks, server answers
	CraftItem = Net.request({
		data = t.struct({ recipe = t.u16 }),
		reply = t.struct({ ok = t.bool, reason = t.optional(t.string(64)) }),
		rate = 5,
		timeout = 10,
	}),

	-- the self-test's round trip and controls (dev place only)
	Roundtrip = Net.request({ data = Everything, reply = Everything, rate = 30 }),
	SelfTest = Net.request({
		data = t.enum({ "flip", "unflip", "strikes", "remotes" }),
		reply = t.i32,
		rate = 30,
	}),
	Bulk = Net.request({ data = t.string(40000), reply = t.u32, rate = 30 }),
	Ping = Net.packet({ from = "client", rate = 10 }),
	Pong = Net.packet({ from = "server" }),
})
