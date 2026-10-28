local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local Packets = require(ReplicatedStorage.Shared.Packets)

local CombatService = Nova.new("CombatService")
	:withDependencies({ "InventoryService" })
	:withSignals({ "ShotFired" })
	:withFlags({ NewRecoil = false })
	:withConfig({ Range = 500, Damage = 25, RecoilDamage = 30 })
	:withLifecycle({
		init = function(self)
			self.inventory = Nova.get("InventoryService") -- allowed: it is declared above
			self.aims = {} :: { [Player]: { pitch: number, yaw: number } }
		end,
		start = function(self)
			Packets.Fire:listen(function(player, shot)
				self:_onFire(player, shot)
			end)
			Packets.Aim:listen(function(player, aim)
				self.aims[player] = aim
			end)
			self.trove:Connect(Players.PlayerRemoving, function(player)
				self.aims[player] = nil
			end)
		end,
	})

function CombatService:_onFire(player: Player, shot)
	if not self.inventory:hasWeapon(player, shot.weapon) then
		self.log:debug("Fire with a weapon the player does not have", player.Name, shot.weapon)
		return
	end
	self:getSignal("ShotFired"):Fire(player, shot)
	-- Hit checks and rewinding belong here, against shot.shotTime on the server clock.
	local result = workspace:Raycast(shot.origin, shot.direction * self:getConfig("Range"))
	local model = result and result.Instance:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		Packets.HitConfirm:sendTo(player, {
			target = model,
			damage = if self:flag("NewRecoil") then self:getConfig("RecoilDamage") else self:getConfig("Damage"),
			headshot = result.Instance.Name == "Head",
		})
	end
end

return CombatService
