--[[
	Auto Turtle Warrior - Combat/Consumables

	Auto-use of bag items relevant to PvE DPS:
	- Healing potions (HP threshold)
	- Healthstone (HP threshold)
	- Lifeblood (Herbalism, HP threshold)
	- Mighty Rage Potion (synced with bursts)
	- Engineering damage items (Goblin Sapper Charge, Dense Dynamite, Iron Grenade)

	All checks: item present in bags, not on cooldown, situation matches
	(HP threshold for defensives, burst window for offensives, AoE count
	for engineering AoE).
]]--

ATW.Consumables = ATW.Consumables or {}

local Consumables = ATW.Consumables

---------------------------------------
-- Item ID groups (vanilla / TurtleWoW). For each "kind" we list the IDs
-- in priority order (best/highest rank first) so we use the strongest
-- item available before falling back to weaker ranks.
---------------------------------------
Consumables.ITEMS = {
	healing_potion = {
		13446,  -- Major Healing Potion (700-900)
		3928,   -- Superior Healing Potion (455-585)
		1710,   -- Greater Healing Potion (315-405)
		929,    -- Healing Potion (185-235)
		858,    -- Lesser Healing Potion (140-180)
		118,    -- Minor Healing Potion (70-90)
	},
	healthstone = {
		19013, 19012, 19011, 19010, 19009, 19008, 19007, 19006, 19005, 19004,  -- Major variants
		5512, 5511, 5510, 5509, 19005,  -- Lesser/regular variants
	},
	mighty_rage = {
		13442,  -- Mighty Rage Potion (45-75 rage + 60 STR for 20s)
	},
	rage_potion = {
		13442,  -- Mighty Rage Potion
		5633,   -- Great Rage Potion (30-45 rage)
		5634,   -- Rage Potion (20-40 rage)
	},
	-- Engineering damage items
	sapper_charge = {
		10646,  -- Goblin Sapper Charge (450-750 fire AoE, hits self for 375)
	},
	dense_dynamite = {
		18641,  -- Dense Dynamite (340-460 fire single target)
	},
	solid_dynamite = {
		10507,  -- Solid Dynamite (213-287)
	},
	iron_grenade = {
		4390,   -- Iron Grenade (140-180 + 3s stun)
	},
	thorium_grenade = {
		15993,  -- Thorium Grenade (300-500 + 3s stun)
	},
}

---------------------------------------
-- Configuration thresholds (defaults; user-tunable via slash commands)
---------------------------------------
Consumables.HP_HEALING_POTION = 35   -- use healing potion below this %
Consumables.HP_HEALTHSTONE = 40      -- use healthstone below this %
Consumables.HP_LIFEBLOOD = 50        -- use Lifeblood below this %
Consumables.MIN_AOE_FOR_SAPPER = 3   -- minimum mob count for Sapper Charge
Consumables.SELF_DMG_HP_GUARD = 60   -- don't Sapper if HP below this (self-dmg risk)

---------------------------------------
-- Cache: itemID -> { bag, slot, lastSeen } so we don't bag-scan every frame.
---------------------------------------
Consumables._bagCache = {}
Consumables._lastBagScan = 0
local BAG_SCAN_INTERVAL = 1.0  -- seconds

---------------------------------------
-- Scan all bags for a specific itemID. Returns bag, slot or nil.
---------------------------------------
function Consumables.FindItemBagSlot(itemId)
	for bag = 0, 4 do
		local numSlots = GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local link = GetContainerItemLink(bag, slot)
			if link then
				local _, _, idStr = string.find(link, "item:(%d+)")
				if idStr and tonumber(idStr) == itemId then
					return bag, slot
				end
			end
		end
	end
	return nil, nil
end

---------------------------------------
-- Find any item from a kind list (returns itemId, bag, slot of first
-- matching present item, in list-priority order).
---------------------------------------
function Consumables.FindAnyOfKind(kind)
	local list = Consumables.ITEMS[kind]
	if not list then return nil end
	for _, itemId in ipairs(list) do
		local bag, slot = Consumables.FindItemBagSlot(itemId)
		if bag then return itemId, bag, slot end
	end
	return nil
end

---------------------------------------
-- Check item cooldown by bag/slot. Returns: ready, secondsRemaining.
---------------------------------------
function Consumables.IsBagItemReady(bag, slot)
	local start, duration = GetContainerItemCooldown(bag, slot)
	if not start or start == 0 then return true, 0 end
	local now = GetTime()
	local remaining = (start + duration) - now
	if remaining <= 0 then return true, 0 end
	return false, remaining
end

---------------------------------------
-- Check if a specific kind is ready (item present + off-cooldown).
-- Returns: ready, itemId, bag, slot, secondsRemaining.
---------------------------------------
function Consumables.IsKindReady(kind)
	local itemId, bag, slot = Consumables.FindAnyOfKind(kind)
	if not itemId then return false end
	local ready, remaining = Consumables.IsBagItemReady(bag, slot)
	return ready, itemId, bag, slot, remaining
end

---------------------------------------
-- Use a kind: presses the first available + ready item of that kind.
-- Returns true if used.
---------------------------------------
function Consumables.UseKind(kind)
	local ready, itemId, bag, slot = Consumables.IsKindReady(kind)
	if not ready then return false end
	UseContainerItem(bag, slot)
	if ATW.Debug then
		ATW.Debug("Consumable -> " .. kind .. " (item " .. itemId .. ")")
	end
	return true
end

---------------------------------------
-- Lifeblood (Herbalism). It's a self-buff cast, not a bag item — but it
-- shares the consumable category for the "low HP defensive" decision.
-- Cast it via CastSpellByName if the player knows it.
---------------------------------------
function Consumables.UseLifeblood()
	if not ATW.Has or not ATW.Has.Lifeblood then return false end
	local _, _, _, _, _, remaining = nil, nil, nil, nil, nil, 0
	-- Check spell cooldown via SpellID lookup
	if ATW.SpellID then
		local sid = ATW.SpellID("Lifeblood")
		if sid then
			local start, duration = GetSpellCooldown(sid, BOOKTYPE_SPELL)
			if start and start > 0 then
				local rem = (start + duration) - GetTime()
				if rem > 0 then return false end
			end
		end
	end
	CastSpellByName("Lifeblood")
	if ATW.Debug then ATW.Debug("Consumable -> Lifeblood") end
	return true
end

---------------------------------------
-- Pick the best DEFENSIVE consumable to use right now, given player HP %.
-- Returns: kind name (string) or nil.
---------------------------------------
function Consumables.PickDefensive()
	local hp = UnitHealth("player") or 0
	local maxHp = UnitHealthMax("player") or 1
	local hpPct = (hp / maxHp) * 100

	-- Below HEALING_POTION threshold — try healing potion first, then HS
	if hpPct <= Consumables.HP_HEALING_POTION
	   and Consumables.IsKindReady("healing_potion") then
		return "healing_potion"
	end
	if hpPct <= Consumables.HP_HEALTHSTONE
	   and Consumables.IsKindReady("healthstone") then
		return "healthstone"
	end
	if hpPct <= Consumables.HP_LIFEBLOOD
	   and ATW.Has and ATW.Has.Lifeblood then
		-- Lifeblood handled separately (it's a spell, not a bag item)
		return "lifeblood"
	end

	return nil
end

---------------------------------------
-- Pick the best OFFENSIVE consumable for the current burst window.
-- Returns: kind name or nil.
---------------------------------------
function Consumables.PickOffensive(state)
	state = state or {}

	-- Mighty Rage Potion: use during DeathWish/Recklessness if rage low
	-- and we're in a burst window (these CDs active or about to be).
	local dwActive = state.deathwishActive
	local reckActive = state.recklessnessActive
	local inBurst = dwActive or reckActive
	if inBurst then
		local rage = UnitMana("player") or 100
		if rage < 70 and Consumables.IsKindReady("mighty_rage") then
			return "mighty_rage"
		end
	end

	-- Engineering damage items in AoE / burst windows
	local enemyCount = state.enemyCount or 1
	local hpPct = ((UnitHealth("player") or 0) / (UnitHealthMax("player") or 1)) * 100

	-- Sapper Charge: AoE windows with safe HP
	if enemyCount >= Consumables.MIN_AOE_FOR_SAPPER
	   and hpPct >= Consumables.SELF_DMG_HP_GUARD
	   and Consumables.IsKindReady("sapper_charge") then
		return "sapper_charge"
	end

	-- Dense Dynamite (or solid): single-target burst when CDs active
	if inBurst then
		if Consumables.IsKindReady("dense_dynamite") then
			return "dense_dynamite"
		end
		if Consumables.IsKindReady("solid_dynamite") then
			return "solid_dynamite"
		end
	end

	-- Thorium Grenade as offensive AoE-stun fallback
	if enemyCount >= 2 and Consumables.IsKindReady("thorium_grenade") then
		return "thorium_grenade"
	end

	return nil
end

---------------------------------------
-- Execute a picked consumable kind. Returns true if pressed.
---------------------------------------
function Consumables.UsePickedKind(kind)
	if not kind then return false end
	if kind == "lifeblood" then return Consumables.UseLifeblood() end
	return Consumables.UseKind(kind)
end

---------------------------------------
-- Debug: print state of all known consumable kinds.
---------------------------------------
function Consumables.PrintState()
	if not ATW.Print then return end
	ATW.Print("=== Consumables ===")
	for kind, _ in pairs(Consumables.ITEMS) do
		local ready, itemId, bag, slot, remaining = Consumables.IsKindReady(kind)
		if itemId then
			local status = ready and "|cff00ff00READY|r"
			              or string.format("|cffffaa00%.0fs|r", remaining or 0)
			ATW.Print(string.format("  %s: item %d in bag %d slot %d %s",
				kind, itemId, bag, slot, status))
		end
	end
	if ATW.Has and ATW.Has.Lifeblood then
		ATW.Print("  lifeblood: spell available")
	end
	local hp = UnitHealth("player") or 0
	local maxHp = UnitHealthMax("player") or 1
	ATW.Print(string.format("  HP: %.0f%%  thresholds  pot<%d  HS<%d  LB<%d",
		(hp/maxHp)*100,
		Consumables.HP_HEALING_POTION,
		Consumables.HP_HEALTHSTONE,
		Consumables.HP_LIFEBLOOD))
end
