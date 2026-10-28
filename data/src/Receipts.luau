--!strict
--[[
	Receipts: developer product purchases, granted exactly once.

		NovaData.onProduct(CashConfig.SmallPackId, function(profile, receipt)
			profile:Increment("Cash", 10000)
		end)

	A GRANT THAT DID NOT LAND MUST SAY SO. A handler that errors, or returns false, leaves the receipt
	unprocessed and Roblox delivers it again later. Returning quietly would acknowledge Robux for
	nothing (CarSteal's revive, boost and pull grants did that until 2026-09-28).

	A RECEIPT LANDS AT INCONVENIENT TIMES: mid-match, days later on a retry, on a server that never
	saw the purchase start. So a grant should write something durable to the profile (a counter, an
	entitlement) and let the feature spend it, not depend on what is on screen.

	Exactly once comes from ProfileStore's recipe: the purchase id is recorded in the save in the same
	step as the grant, and the purchase is acknowledged only after that save has reached the
	DataStore. The history keeps the last 1,000 ids (CarSteal raised it from 100 in a security review:
	a buyer of repeatable products could otherwise push an unacknowledged id out and get it twice).

	Handlers are registered by the feature that owns the product, at require time or in init, never
	in the data layer itself, so the data layer never learns what a cash pack is.
]]

local Players = game:GetService("Players")

local Receipts = {}

export type Handler = (profile: any, receipt: { [string]: any }) -> any

Receipts.handlers = {} :: { [number]: Handler }
Receipts.historyKey = "PurchaseIdCache"
Receipts.historySize = 1000
Receipts.spentKey = nil :: string?

local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet
local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted

--[[ Grants `receipt` on `wrapped` (a NovaData profile) at most once, and answers only when the
	grant is saved. ]]
function Receipts.grant(wrapped: any, receipt: { [string]: any }, handler: Handler): Enum.ProductPurchaseDecision
	local profile = wrapped:GetProfile()
	if not profile:IsActive() then
		return NOT_YET
	end
	local data = profile.Data
	local history = data[Receipts.historyKey]
	if type(history) ~= "table" then
		history = {}
		data[Receipts.historyKey] = history
	end
	local purchaseId = receipt.PurchaseId

	if not table.find(history, purchaseId) then
		local ok, result = pcall(handler, wrapped, receipt)
		if not ok or result == false then
			warn(`[NovaData] developer product {receipt.ProductId} was not granted to {receipt.PlayerId}; Roblox will deliver it again. {if ok then "The handler returned false" else tostring(result)}`)
			return NOT_YET
		end
		local spentKey = Receipts.spentKey
		if spentKey and type(receipt.CurrencySpent) == "number" then
			local spent = data[spentKey]
			wrapped:Set({ spentKey }, (if type(spent) == "number" then spent else 0) + receipt.CurrencySpent)
		end
		while #history >= Receipts.historySize do
			table.remove(history, 1)
		end
		table.insert(history, purchaseId)
	end

	local function saved(): boolean
		local savedHistory = profile.LastSavedData[Receipts.historyKey]
		return type(savedHistory) == "table" and table.find(savedHistory, purchaseId) ~= nil
	end
	if saved() then
		return GRANTED
	end
	while profile:IsActive() do
		local lastSaved = profile.LastSavedData
		profile:Save()
		if profile.LastSavedData == lastSaved then
			profile.OnAfterSave:Wait()
		end
		if saved() then
			return GRANTED
		end
		if profile:IsActive() then
			task.wait(10)
		end
	end
	return NOT_YET
end

--[[ MarketplaceService.ProcessReceipt. `awaitProfile(player)` yields for the buyer's profile, or
	nil when they are not here. ]]
function Receipts.process(receipt: { [string]: any }, awaitProfile: (Player) -> any): Enum.ProductPurchaseDecision
	local handler = Receipts.handlers[receipt.ProductId]
	if not handler then
		warn(`[NovaData] no handler for developer product {receipt.ProductId}; the receipt waits until one is registered with NovaData.onProduct`)
		return NOT_YET
	end
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return NOT_YET
	end
	local wrapped = awaitProfile(player)
	if not wrapped then
		return NOT_YET
	end
	return Receipts.grant(wrapped, receipt, handler)
end

return Receipts
