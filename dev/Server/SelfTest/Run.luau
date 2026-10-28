--[[
	The server half of Nova's self-test. Runs after boot when the NovaSelfTest flag is on, prints a
	[NovaTest] line per check, and puts "passed/total" on ReplicatedStorage as NovaServerTests.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Record = require(script.Parent.Record)

local t = Nova.Net.types

-- The angle between two directions, accurate near zero (acos of a float32 dot floors at 0.028 degrees).
local function degreesBetween(a: Vector3, b: Vector3): number
	return math.deg(math.atan2(a:Cross(b).Magnitude, a:Dot(b)))
end

return function()
	local passed, total = 0, 0
	local function check(name: string, ok: any, detail: any?)
		total += 1
		if ok then
			passed += 1
			print(`[NovaTest] PASS server: {name}`)
		else
			warn(`[NovaTest] FAIL server: {name}{if detail ~= nil then " (" .. tostring(detail) .. ")" else ""}`)
		end
	end
	local function errors(fn: () -> any, text: string): (boolean, any)
		local ok, err = pcall(fn)
		return not ok and string.find(tostring(err), text, 1, true) ~= nil, err
	end
	local function listed(list: { any }, name: string, phase: string?): boolean
		for _, entry in list do
			if entry.name == name and (phase == nil or entry.phase == phase) then
				return true
			end
		end
		return false
	end

	-- Boot: one failure costs one module ---------------------------------------------------------
	local report = Nova.report()
	check("an init that throws fails that module", listed(report.failed, "SelfTestBroken", "init"))
	check("an init that yields fails that module", listed(report.failed, "SelfTestYield", "init"))
	check("a module whose dependency failed is skipped", listed(report.skipped, "SelfTestDependent"))
	check("a module whose script throws after Nova.new is failed, not booted empty", listed(report.failed, "SelfTestBadBuilder", "require") and errors(function()
		return Nova.get("SelfTestBadBuilder")
	end, "failed during boot"))
	check("everything else booted", report.state == "ready" and #report.failed == 3 and #report.skipped == 1, `{#report.failed} failed, {#report.skipped} skipped`)
	local serverFailed = workspace:GetAttribute("NovaServerFailed")
	check("the server announced ready, naming the failures", workspace:GetAttribute("NovaServerReady") == true and string.find(tostring(serverFailed), "SelfTestBroken.init", 1, true), serverFailed)

	-- Boot: order --------------------------------------------------------------------------------
	local order = table.concat(Record.order, ",")
	check("init and start follow dependencies, not names", order == "ZetaSource.init,AlphaConsumer.init,ZetaSource.start,AlphaConsumer.start", order)
	local at = Record.at
	check("a start that waits holds up nobody", at.alphaStart and at.slowStartBegan and at.slowStartEnded and at.alphaStart > at.slowStartBegan and at.alphaStart < at.slowStartEnded)
	check("Nova.get during init allows a dependency's dependency", Record.transitiveGet == "SelfTestRoot", Record.transitiveGet)
	check("Nova.get during init refuses an undeclared module", string.find(tostring(Record.undeclaredGet), "does not depend on", 1, true), Record.undeclaredGet)

	-- Nova.get and the builder --------------------------------------------------------------------
	check("Nova.get of a misspelt name suggests the right one", errors(function()
		return Nova.get("CombatServce")
	end, "Did you mean CombatService"))
	check("Nova.get of a failed module errors", errors(function()
		return Nova.get("SelfTestBroken")
	end, "failed during boot"))
	check("Nova.await returns at once after boot", Nova.await("CombatService", 1) == Nova.get("CombatService"))
	local combat = Nova.get("CombatService")
	check("a builder after boot errors", errors(function()
		combat:withDependencies({ "X" })
	end, "after Nova.boot read"))
	check("getSignal of a misspelt name errors", errors(function()
		combat:getSignal("ShotFird")
	end, "Did you mean ShotFired"))
	check("getConfig of a misspelt key errors", errors(function()
		combat:getConfig("Rnage")
	end, "Did you mean Range"))

	-- Flags --------------------------------------------------------------------------------------
	local folder = ReplicatedStorage:FindFirstChild("NovaFlags")
	check("a misspelt flag errors", errors(function()
		return Nova.flags.get("NewRecoli")
	end, "Did you mean NewRecoil"))
	check("a studio value applies in Studio", Nova.flags.get("SkipIntro") == true)
	check("NovaFlags lists every flag", folder and folder:GetAttribute("StaminaV2") == true and folder:GetAttribute("NovaDebug") == "")
	check("set refuses the wrong type", errors(function()
		Nova.flags.set("NewRecoil", "yes" :: any)
	end, "is a boolean"))
	local seen = {}
	local watching = Nova.flags.observe("StaminaV2", function(value)
		table.insert(seen, tostring(value))
	end)
	Nova.flags.set("StaminaV2", false)
	task.wait()
	Nova.flags.set("StaminaV2", nil)
	task.wait()
	watching:Disconnect()
	check("observe runs now and on every live change", table.concat(seen, ",") == "true,false,true", table.concat(seen, ","))
	for _, player in Players:GetPlayers() do
		check(`the provider's value reaches {player.Name}`, Nova.flags.get("StreakDisplay", player) == "badge" and Nova.flags.get("StreakDisplay") == "notification")
	end

	-- Bus ----------------------------------------------------------------------------------------
	local Events = require(ReplicatedStorage.Shared.Events)
	check("a misspelt bus event errors", errors(function()
		return Events.PageOpend
	end, "Did you mean PageOpened"))
	local a, b = 0, 0
	local first = Events.PageOpened:Connect(function()
		a += 1
	end)
	local second = Events.PageOpened:Connect(function()
		b += 1
	end)
	first:Disconnect()
	Events.PageOpened:Fire("Inventory")
	second:Disconnect()
	check("disconnecting one listener leaves the others (Dispatcher wiped them all)", a == 0 and b == 1)
	local reached = false
	local thrower = Events.PageOpened:Connect(function()
		error("deliberate listener error (NovaSelfTest)")
	end)
	local after = Events.PageOpened:Connect(function()
		reached = true
	end)
	local published = pcall(function()
		Events.PageOpened:Fire("Map")
	end)
	thrower:Disconnect()
	after:Disconnect()
	check("a listener that throws stops neither the others nor the publisher", published and reached)
	Events.Showcasing:set(true)
	local late = nil
	local observer = Events.Showcasing:observe(function(on)
		late = on
	end)
	observer:Disconnect()
	Events.Showcasing:set(false)
	check("a state observer that connects late gets the current value", late == true)

	-- Codecs -------------------------------------------------------------------------------------
	local function roundtrip(codec: any, value: any): (any, number)
		local w = t.newWriter(4)
		codec.write(w, value, "test")
		local r = { buf = w.buf, cursor = 0, len = w.cursor, instances = w.instances, instanceCursor = 0, strict = true, stale = false }
		local out = codec.read(r)
		assert(r.cursor == w.cursor, "read a different number of bytes than were written")
		return out, w.cursor
	end
	local function strictRead(codec: any, bytes: { number }): (boolean, any)
		local buf = buffer.create(#bytes)
		for i, byte in bytes do
			buffer.writeu8(buf, i - 1, byte)
		end
		return pcall(codec.read, { buf = buf, cursor = 0, len = #bytes, instances = {}, instanceCursor = 0, strict = true, stale = false })
	end

	check("integers round trip at their limits", roundtrip(t.u8, 255) == 255 and roundtrip(t.i8, -128) == -128 and roundtrip(t.u32, 4294967295) == 4294967295 and roundtrip(t.i32, -2147483648) == -2147483648)
	check("f32 keeps 7 digits, f64 is exact", math.abs(roundtrip(t.f32, 1 / 3) - 1 / 3) < 1e-7 and roundtrip(t.f64, math.pi) == math.pi)
	check("strings round trip, UTF-8 included", roundtrip(t.string(8), "héllo") == "héllo")
	check("writing invalid UTF-8 errors at the send, not as a strike at the server", errors(function()
		roundtrip(t.string(8), "\255")
	end, "not valid UTF-8"))
	check("an f32 at its range's edge still passes the server's check after rounding", roundtrip(t.f32({ min = 0, max = 0.3 }), 0.3) ~= nil)

	local rng = Random.new(7)
	local worstDirection, worstRotation, worstPosition = 0, 0, 0
	for _ = 1, 300 do
		local direction = rng:NextUnitVector()
		local out = roundtrip(t.unitVector, direction)
		worstDirection = math.max(worstDirection, degreesBetween(out, direction))
		local pose = CFrame.new(rng:NextNumber(-2000, 2000), rng:NextNumber(-500, 500), rng:NextNumber(-2000, 2000))
			* CFrame.fromAxisAngle(rng:NextUnitVector(), rng:NextNumber(-math.pi, math.pi))
		local decoded = roundtrip(t.cframe, pose)
		for _, axis in { "XVector", "YVector", "ZVector" } do
			worstRotation = math.max(worstRotation, degreesBetween((pose :: any)[axis], (decoded :: any)[axis]))
		end
		worstPosition = math.max(worstPosition, (decoded.Position - pose.Position).Magnitude)
	end
	check(`unitVector is within 0.01 degrees (worst {string.format("%.4f", worstDirection)})`, worstDirection < 0.01)
	check(`cframe rotation is within 0.01 degrees (worst {string.format("%.4f", worstRotation)})`, worstRotation < 0.01)
	check(`cframe position is within a millimetre at 2,000 studs (worst {string.format("%.5f", worstPosition)})`, worstPosition < 0.001)
	local yaw = roundtrip(t.angle, 1)
	local wrapped = roundtrip(t.angle, 4)
	check("angle keeps 0.0055 degree steps and decodes to (-pi, pi]", math.abs(yaw - 1) < 1e-4 and math.abs(wrapped - (4 - 2 * math.pi)) < 1e-4)
	local _, cframeBytes = roundtrip(t.cframe, CFrame.new())
	local _, unitBytes = roundtrip(t.unitVector, Vector3.xAxis)
	local _, angleBytes = roundtrip(t.angle, 0)
	check("cframe is 19 bytes, unitVector 4, angle 2", cframeBytes == 19 and unitBytes == 4 and angleBytes == 2)

	local shape = t.struct({
		mode = t.enum({ "idle", "run" }),
		some = t.optional(t.u8),
		none = t.optional(t.u8),
		list = t.array(t.u16, 4),
		nested = t.struct({ a = t.u8 }),
		part = t.instance("BasePart"),
	})
	local part = Instance.new("Part")
	local out, bytes = roundtrip(shape, { mode = "run", some = 4, list = { 1, 2, 65535 }, nested = { a = 9 }, part = part })
	check("enum, optional, array, nested struct and instance round trip", out.mode == "run" and out.some == 4 and out.none == nil and #out.list == 3 and out.list[3] == 65535 and out.nested.a == 9 and out.part == part)
	check("an instance costs no buffer bytes", bytes == 1 + 2 + 1 + 1 + 3 * 2 + 1, bytes)
	part:Destroy()

	check("writing a value out of range errors with its path", errors(function()
		roundtrip(t.struct({ weapon = t.u8 }), { weapon = 300 })
	end, "test.weapon: 300 is outside u8's range"))
	check("writing a field the struct lacks errors", errors(function()
		roundtrip(t.struct({ weapon = t.u8 }), { weapon = 1, wepon = 2 })
	end, "\"wepon\" is not a field"))
	check("writing a string past its max errors", errors(function()
		roundtrip(t.string(4), "toolong")
	end, "longer than string(4)"))
	check("strict reads reject NaN", not (strictRead(t.f32, { 0, 0, 192, 127 })))
	check("strict reads reject a string past its max", not (strictRead(t.string(2), { 3, 97, 98, 99 })))
	check("strict reads reject a bool that is not 0 or 1", not (strictRead(t.bool, { 2 })))
	check("strict reads reject an enum index past the list", not (strictRead(t.enum({ "a" }), { 9 })))
	check("strict reads enforce a declared range", not (strictRead(t.u8({ max = 5 }), { 7 })))
	check("reads never run past the end", not (strictRead(t.vector3, { 0, 0, 0 })))

	-- NovaData ---------------------------------------------------------------------------------
	local NovaData = require(ReplicatedStorage.Packages.NovaData)
	local Receipts = require(ReplicatedStorage.Packages.NovaData.Receipts) :: any
	local player = Players:GetPlayers()[1]
	local profile = if player then NovaData.awaitProfile(player, 15) else nil
	check("a player's save loads, on the mock store in Studio", profile ~= nil and NovaData.isMock())
	if player and profile then
		check("a fresh save is already at the latest migration", profile:Get({ "DataVersion" }) == 1, profile:Get({ "DataVersion" }))
		check("a key name, a unique nested name and a dotted path all resolve", profile:Get("Cash") == 0 and profile:Get("Experience") == 0 and profile:Get("Pets.Dog.Level") == 1)
		check("a name in two places errors and lists both", errors(function()
			return profile:Get("Level")
		end, "Pets.Dog.Level, Stats.Level"))
		check("a misspelt key errors with the closest name", errors(function()
			return profile:Get("Csh")
		end, "Did you mean Cash"))
		profile:Set("Cash", 100)
		check("Increment and Decrement never go below 0", profile:Increment("Cash", -500) == 0 and profile:Increment("Cash", 70) == 70 and profile:Decrement("Cash", 20) == 50)
		check("Spend takes only what they have", profile:Spend("Cash", 30) == true and profile:Spend("Cash", 30) == false and profile:Get("Cash") == 20)
		local inserted = profile:Insert({ "Inventory" }, "Sword")
		profile:Insert({ "Inventory" }, "Shield")
		check("Insert and Remove edit a list", inserted == 1 and profile:Remove({ "Inventory" }, 1) == "Sword" and profile:Get({ "Inventory", 1 }) == "Shield")
		check("Increment of something that is not a number errors", errors(function()
			profile:Increment("Inventory", 1)
		end, "needs a number"))
		check("GetUserId answers (the template's never did)", profile:GetUserId() == player.UserId)

		local observed = nil
		local observing = NovaData.observeProfiles(function(who)
			observed = who
		end)
		task.wait()
		observing:Disconnect()
		check("observeProfiles runs for a save already loaded", observed == player)

		local grants = 0
		NovaData.onProduct(1, function(buyer)
			grants += 1
			buyer:Increment("Cash", 1000)
		end)
		NovaData.onProduct(2, function()
			return false
		end)
		local purchaseId = `selftest-{os.clock()}`
		local first = Receipts.process({ PlayerId = player.UserId, ProductId = 1, PurchaseId = purchaseId, CurrencySpent = 10 }, NovaData.awaitProfile)
		local second = Receipts.process({ PlayerId = player.UserId, ProductId = 1, PurchaseId = purchaseId, CurrencySpent = 10 }, NovaData.awaitProfile)
		check("a receipt delivered twice grants once, and only once it is saved", first == Enum.ProductPurchaseDecision.PurchaseGranted and second == Enum.ProductPurchaseDecision.PurchaseGranted and grants == 1, `{first}, {second}, {grants} grants`)
		local refused = Receipts.process({ PlayerId = player.UserId, ProductId = 2, PurchaseId = `{purchaseId}-2` }, NovaData.awaitProfile)
		check("a grant that returns false is left for Roblox to retry", refused == Enum.ProductPurchaseDecision.NotProcessedYet)
		check("markForWipe marks a live save", NovaData.markForWipe(player) == true and profile:GetProfile().Data.WipeOnNextLoad == true)
		profile:GetProfile().Data.WipeOnNextLoad = nil
		check("sendMessage queues a message for a save", NovaData.sendMessage(player.UserId, { "SelfTestNote" }) == true)
	end

	print(`[NovaTest] server: {passed}/{total} passed`)
	ReplicatedStorage:SetAttribute("NovaServerTests", `{passed}/{total}`)
end
