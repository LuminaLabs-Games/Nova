--[[
	The client half of Nova's self-test: drives the real wire against SelfTestService. Runs after
	boot when NovaSelfTest is on, prints a [NovaTest] line per check, and puts "passed/total" on
	this client's ReplicatedStorage as NovaClientTests.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Events = require(ReplicatedStorage.Shared.Events)
local Packets = require(ReplicatedStorage.Shared.Packets)

local function waitUntil(condition: () -> boolean, timeout: number): boolean
	local deadline = os.clock() + timeout
	while not condition() do
		if os.clock() > deadline then
			return false
		end
		task.wait()
	end
	return true
end

return function()
	local passed, total = 0, 0
	local function check(name: string, ok: any, detail: any?)
		total += 1
		if ok then
			passed += 1
			print(`[NovaTest] PASS client: {name}`)
		else
			warn(`[NovaTest] FAIL client: {name}{if detail ~= nil then " (" .. tostring(detail) .. ")" else ""}`)
		end
	end
	local function errors(fn: () -> any, text: string): (boolean, any)
		local ok, err = pcall(fn)
		return not ok and string.find(tostring(err), text, 1, true) ~= nil, err
	end

	-- Boot ---------------------------------------------------------------------------------------
	local report = Nova.report()
	check("the client booted after the server reported ready", report.state == "ready" and report.server and report.server.ready)
	check("the client knows what failed on the server", report.server and string.find(tostring(report.server.failed), "SelfTestBroken.init", 1, true), report.server and report.server.failed)
	check("NovaClientReady and NovaClientFailed are set for a join screen", workspace:GetAttribute("NovaClientReady") == true and string.find(tostring(workspace:GetAttribute("NovaClientFailed")), "server:", 1, true))

	-- Flags --------------------------------------------------------------------------------------
	check("the provider's per-player value was settled before boot", Nova.flags.get("StreakDisplay") == "badge", Nova.flags.get("StreakDisplay"))
	check("a studio value applies on the client too", Nova.flags.get("SkipIntro") == true)
	check("a client cannot set a flag", errors(function()
		Nova.flags.set("NewRecoil", true)
	end, "server only"))
	local seen = {}
	local watching = Nova.flags.observe("NewRecoil", function(value)
		table.insert(seen, tostring(value))
	end)
	Packets.SelfTest:invoke("flip")
	waitUntil(function()
		return #seen >= 2
	end, 3)
	Packets.SelfTest:invoke("unflip")
	waitUntil(function()
		return #seen >= 3
	end, 3)
	watching:Disconnect()
	check("a live flip on the server reaches a client observer", table.concat(seen, ",") == "false,true,false", table.concat(seen, ","))

	-- Net: mistakes are errors -------------------------------------------------------------------
	check("a misspelt packet errors", errors(function()
		return (Packets :: any).Fier
	end, "Did you mean Fire"))
	check("sending a server packet from the client errors", errors(function()
		(Packets.HitConfirm :: any):send({})
	end, "sent by the server"))
	check("a bad value errors at the send, with its path", errors(function()
		Packets.Fire:send({ weapon = 300, origin = Vector3.zero, direction = Vector3.zAxis, shotTime = 0 })
	end, "Fire.weapon: 300 is outside u8's range"))

	-- Net: requests ------------------------------------------------------------------------------
	local crafted = Packets.CraftItem:invoke({ recipe = 12 })
	local refused = Packets.CraftItem:invoke({ recipe = 99 })
	check("a request gets its reply", crafted.ok == true and refused.ok == false and refused.reason == "unknown recipe")
	check("two remotes in total", Packets.SelfTest:invoke("remotes") == 2)

	local part = workspace:FindFirstChild("Baseplate") or workspace:FindFirstChildWhichIsA("BasePart", true)
	local pose = CFrame.new(812.5, -40.25, 3.75) * CFrame.Angles(0.3, -2.1, 1.2)
	local sent = {
		u8 = 200, u16 = 60000, u32 = 4000000000, i8 = -100, i16 = -30000, i32 = -2000000000,
		f32 = 0.1, f64 = 1 / 3, flag = true, name = "Nova ✓", position = Vector3.new(1.5, -2, 1e4),
		direction = Vector3.new(1, 2, -3).Unit, yaw = -2.5, pose = pose, part = part, mode = "jump",
		some = 7, list = { 1, 2, 3 }, nested = { a = 9, b = "ok" },
	}
	local back = Packets.Roundtrip:invoke(sent)
	local exact = true
	for _, key in { "u8", "u16", "u32", "i8", "i16", "i32", "f64", "flag", "name", "part", "mode", "some" } do
		if back[key] ~= sent[key] then
			exact = false
			warn(`[NovaTest] {key}: sent {tostring(sent[key])}, got {tostring(back[key])}`)
		end
	end
	local _, angle = (pose:Inverse() * back.pose):ToAxisAngle()
	check("every type survives the wire both ways", exact
		and back.none == nil
		and math.abs(back.f32 - 0.1) < 1e-6
		and (back.position - sent.position).Magnitude < 1e-3
		and back.direction:Dot(sent.direction) > 0.99999
		and math.abs(back.yaw - sent.yaw) < 1e-3
		and (back.pose.Position - pose.Position).Magnitude < 1e-3
		and math.abs(angle) < 1e-3
		and #back.list == 3 and back.list[3] == 3
		and back.nested.a == 9 and back.nested.b == "ok")

	-- Net: two 40 KB requests in one frame go over the server's 64 KB batch limit, so the client
	-- must split them into two calls.
	local strikesBeforeBulk = Packets.SelfTest:invoke("strikes")
	local sizes = {}
	for i = 1, 2 do
		task.spawn(function()
			sizes[i] = Packets.Bulk:invoke(string.rep("x", 40000))
		end)
	end
	waitUntil(function()
		return sizes[1] ~= nil and sizes[2] ~= nil
	end, 5)
	check("a frame of sends over 64 KB is split, not refused", sizes[1] == 40000 and sizes[2] == 40000 and Packets.SelfTest:invoke("strikes") == strikesBeforeBulk, `{tostring(sizes[1])}, {tostring(sizes[2])}`)

	-- Net: an Instance comes back from the server ------------------------------------------------
	local dummy = workspace:WaitForChild("SelfTestDummy", 5)
	local hit = nil
	local hits = Packets.HitConfirm:listen(function(confirm)
		hit = confirm
	end)
	Packets.Fire:send({ weapon = 1, origin = Vector3.new(0, 50, 0), direction = Vector3.new(0, 0, -1), shotTime = workspace:GetServerTimeNow() })
	waitUntil(function()
		return hit ~= nil
	end, 3)
	hits:Disconnect()
	check("a hit comes back carrying the Model it hit", hit and dummy and hit.target == dummy and hit.headshot == true and hit.damage == 25, hit and hit.target)

	-- Net: an unreliable newest-only stream ------------------------------------------------------
	local ticks = {}
	local stream = Packets.Snapshot:listen(function(snapshot)
		table.insert(ticks, snapshot.tick)
	end)
	task.wait(1)
	stream:Disconnect()
	local ordered = #ticks >= 5
	for i = 2, #ticks do
		ordered = ordered and ticks[i] > ticks[i - 1]
	end
	check("an unreliable stream arrives, newest only", ordered, `{#ticks} snapshots`)

	-- Net: rate limits and strikes ---------------------------------------------------------------
	local pongs = 0
	local pong = Packets.Pong:listen(function()
		pongs += 1
	end)
	local before = Packets.SelfTest:invoke("strikes")
	for _ = 1, 30 do
		Packets.Ping:send()
	end
	task.wait(1)
	local after = Packets.SelfTest:invoke("strikes")
	pong:Disconnect()
	check("a burst gets one second's worth through (rate 10)", pongs >= 10 and pongs <= 12, `{pongs} pongs`)
	check("traffic over the rate counts strikes", after - before >= 18, `{after - before} strikes`)

	local remote = ReplicatedStorage.Packages.Nova.Net:FindFirstChild("Reliable") :: RemoteEvent
	local strikesBefore = Packets.SelfTest:invoke("strikes")
	remote:FireServer(buffer.fromstring("\255\255\255"))
	local strikesAfter = Packets.SelfTest:invoke("strikes")
	check("a malformed batch is one strike and breaks nothing", strikesAfter == strikesBefore + 1 and Packets.CraftItem:invoke({ recipe = 12 }).ok, `{strikesAfter - strikesBefore} strikes`)

	-- Bus ----------------------------------------------------------------------------------------
	local opened = nil
	local listener = Events.PageOpened:Connect(function(page)
		opened = page
	end)
	Events.PageOpened:Fire("Inventory")
	listener:Disconnect()
	check("the bus delivers on the client", opened == "Inventory")

	-- NovaData ---------------------------------------------------------------------------------
	local NovaData = require(ReplicatedStorage.Packages.NovaData)
	check("this player's data arrives", NovaData.ready(15))
	check("a nested name and a dotted path resolve on the client too", NovaData.read("Experience") == 0 and NovaData.read("Pets.Dog.Level") == 1)
	check("a name in two places errors on the client too", errors(function()
		return NovaData.read("Level")
	end, "more than one place"))
	check("a client cannot call the server's functions", errors(function()
		return NovaData.getProfile(game:GetService("Players").LocalPlayer)
	end, "server only"))
	local bandages = {}
	local watching = NovaData.observe("Bandages", function(count)
		table.insert(bandages, count)
	end)
	waitUntil(function()
		return #bandages >= 1
	end, 2)
	Packets.CraftItem:invoke({ recipe = 12 })
	waitUntil(function()
		return #bandages >= 2
	end, 3)
	watching:Disconnect()
	check("observe sees the server's write", #bandages >= 2 and bandages[2] == bandages[1] + 1, table.concat(bandages, ","))

	print(`[NovaTest] client: {passed}/{total} passed`)
	ReplicatedStorage:SetAttribute("NovaClientTests", `{passed}/{total}`)
end
