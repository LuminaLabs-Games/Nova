local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Packets = require(ReplicatedStorage.Shared.Packets)

--- Aim goes out at a fixed rate, under the packet's rate of 60: a client running at 240 fps would
--- otherwise send 240 a second and earn a strike for each one over.
local AIM_HZ = 30

local CombatController = Nova.new("CombatController"):withLifecycle({
	start = function(self)
		Packets.HitConfirm:listen(function(hit)
			local name = if hit.target then hit.target.Name else "something not streamed in"
			self.log:info(`Hit {name} for {hit.damage}{if hit.headshot then " (headshot)" else ""}`)
		end)
		local since = 0
		self.trove:Connect(RunService.Heartbeat, function(dt)
			since += dt
			local camera = workspace.CurrentCamera
			if since < 1 / AIM_HZ or not camera then
				return
			end
			since = 0
			local look = camera.CFrame.LookVector
			Packets.Aim:send({ pitch = math.asin(look.Y), yaw = math.atan2(-look.X, -look.Z) })
		end)
	end,
})

--- Fires `weapon` from the camera. The server checks the hit against shotTime.
function CombatController:fire(weapon: number)
	local camera = workspace.CurrentCamera
	Packets.Fire:send({
		weapon = weapon,
		origin = camera.CFrame.Position,
		direction = camera.CFrame.LookVector,
		shotTime = workspace:GetServerTimeNow(),
	})
end

return CombatController
