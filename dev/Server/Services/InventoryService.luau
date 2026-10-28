local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Nova = require(ReplicatedStorage.Packages.Nova)
local NovaData = require(ReplicatedStorage.Packages.NovaData)
local Packets = require(ReplicatedStorage.Shared.Packets)

local InventoryService = Nova.new("InventoryService")
	:withConfig({ WeaponSlots = 3, Recipes = { [12] = "Bandage" } })
	:withLifecycle({
		start = function(self)
			Packets.CraftItem:handle(function(player, request)
				local item = self:getConfig("Recipes")[request.recipe]
				if not item then
					return { ok = false, reason = "unknown recipe" }
				end
				local profile = NovaData.getProfile(player)
				if not profile then
					return { ok = false, reason = "your data has not loaded yet" }
				end
				profile:Increment("Bandages", 1)
				self.log:debug("Crafted", player.Name, item)
				return { ok = true }
			end)
		end,
	})

function InventoryService:hasWeapon(_player: Player, slot: number): boolean
	return slot >= 1 and slot <= self:getConfig("WeaponSlots")
end

return InventoryService
