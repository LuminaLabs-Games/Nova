-- The server half of the self-test: a per-player flag provider, a dummy to shoot, and the requests
-- the client's self-test drives.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Packets = require(ReplicatedStorage.Shared.Packets)

return Nova.new("SelfTestService"):withLifecycle({
	init = function(self)
		if not self:flag("NovaSelfTest") then
			return
		end
		-- What one player sees: StreakDisplay is "badge" for everyone in the test, against the
		-- server's "notification".
		Nova.flags.setProvider(function(name, _player)
			if name == "StreakDisplay" then
				return "badge"
			end
			return nil
		end)
	end,
	start = function(self)
		if not self:flag("NovaSelfTest") then
			return
		end
		local dummy = Instance.new("Model")
		dummy.Name = "SelfTestDummy"
		local body = Instance.new("Part")
		body.Name = "Head"
		body.Anchored = true
		body.Size = Vector3.new(4, 4, 1)
		body.Position = Vector3.new(0, 50, -30)
		body.Parent = dummy
		Instance.new("Humanoid").Parent = dummy
		dummy.PrimaryPart = body
		dummy.Parent = workspace
		self.trove:Add(dummy)

		Packets.Roundtrip:handle(function(_player, value)
			return value
		end)
		Packets.Bulk:handle(function(_player, text)
			return #text
		end)
		Packets.SelfTest:handle(function(player, action)
			if action == "flip" then
				Nova.flags.set("NewRecoil", true)
			elseif action == "unflip" then
				Nova.flags.set("NewRecoil", nil)
			elseif action == "strikes" then
				return Nova.Net.strikes(player)
			elseif action == "remotes" then
				local remotes = 0
				for _, item in ReplicatedStorage.Packages:GetDescendants() do
					if item:IsA("BaseRemoteEvent") or item:IsA("RemoteFunction") then
						remotes += 1
					end
				end
				return remotes
			end
			return 0
		end)
	end,
})
