--[[
	Auto Turtle Warrior - Combat/Stance
	Stance management, detection, and optimization
]]--

-- Stance names for lookup
ATW.StanceNames = {
	[1] = "Battle Stance",
	[2] = "Defensive Stance",
	[3] = "Berserker Stance",
}

-- Cache of available stances
ATW.AvailableStances = {
	[1] = false,
	[2] = false,
	[3] = false,
}

---------------------------------------
-- Stance Detection
---------------------------------------
function ATW.Stance()
	for i = 1, 3 do
		local _, _, active = GetShapeshiftFormInfo(i)
		if active then return i end
	end
	return 0
end

---------------------------------------
-- Check if a stance is learned
---------------------------------------
function ATW.HasStance(stanceNum)
	local stanceName = ATW.StanceNames[stanceNum]
	if not stanceName then return false end
	return ATW.SpellID(stanceName) ~= nil
end

---------------------------------------
-- Detect all available stances
-- Call on VARIABLES_LOADED and level up
---------------------------------------
function ATW.DetectStances()
	for i = 1, 3 do
		ATW.AvailableStances[i] = ATW.HasStance(i)
	end

	-- Debug output
	if AutoTurtleWarrior_Config.Debug then
		local stances = ""
		if ATW.AvailableStances[1] then stances = stances .. "Battle " end
		if ATW.AvailableStances[2] then stances = stances .. "Defensive " end
		if ATW.AvailableStances[3] then stances = stances .. "Berserker " end
		ATW.Debug("Stances: " .. stances)
	end
end

---------------------------------------
-- Get the best DPS stance available
-- Returns: stance number (1 or 3)
---------------------------------------
function ATW.GetBestDPSStance()
	-- Berserker is best for Fury (BT, WW, Berserker Rage)
	if ATW.AvailableStances[3] then
		return 3
	end
	-- Fall back to Battle
	if ATW.AvailableStances[1] then
		return 1
	end
	return 0
end

---------------------------------------
-- Auto-detect primary stance
-- Called on load to set optimal default
---------------------------------------
function ATW.AutoDetectPrimaryStance()
	ATW.DetectStances()

	local bestStance = ATW.GetBestDPSStance()

	-- Only auto-set if user hasn't manually configured
	if AutoTurtleWarrior_Config.PrimaryStance == nil or
	   AutoTurtleWarrior_Config.PrimaryStance == 0 then
		AutoTurtleWarrior_Config.PrimaryStance = bestStance
	end

	-- If configured stance isn't available, fall back
	if not ATW.AvailableStances[AutoTurtleWarrior_Config.PrimaryStance] then
		AutoTurtleWarrior_Config.PrimaryStance = bestStance
	end

	return AutoTurtleWarrior_Config.PrimaryStance
end

---------------------------------------
-- Calculate optimal stance for current situation
-- Returns: recommended stance number
---------------------------------------
function ATW.GetOptimalStance()
	local rage = UnitMana("player")
	local inCombat = UnitAffectingCombat("player")
	local st = ATW.Stance()
	local state = ATW.State
	local talents = ATW.Talents

	-- If we don't have Berserker, Battle is our DPS stance
	if not ATW.AvailableStances[3] then
		return 1
	end

	-- Out of combat: Battle for Charge
	if not inCombat and ATW.Ready("Charge") then
		local dist = ATW.GetDistance and ATW.GetDistance("target")
		if dist and dist >= 8 and dist <= 25 then
			return 1
		end
	end

	-- Check what abilities are ready
	local btReady = talents.HasBT and ATW.Ready("Bloodthirst")
	local wwReady = ATW.Ready("Whirlwind")
	local opReady = state.Overpower and ATW.Ready("Overpower")

	-- If BT or WW is ready, we NEED Berserker
	if btReady or wwReady then
		return 3
	end

	-- Overpower proc: worth going Battle if main abilities on CD
	if opReady and not btReady and not wwReady then
		-- Check if it's worth the stance dance
		-- Overpower is very efficient (5 rage, high damage, can't miss)
		return 1
	end

	-- AoE: Sweeping Strikes setup
	local aoe = ATW.InAoE and ATW.InAoE()
	if aoe and not ATW.Buff("player", "Ability_Rogue_SliceDice") and ATW.Ready("Sweeping Strikes") then
		return 1
	end

	-- Execute phase: prefer Berserker (for Berserker Rage synergy)
	if ATW.InExecutePhase and ATW.InExecutePhase() then
		return 3
	end

	-- Default: stay in primary DPS stance
	return AutoTurtleWarrior_Config.PrimaryStance or 3
end

---------------------------------------
-- Check if we should switch stance
-- Returns: true if switch recommended
---------------------------------------
function ATW.ShouldSwitchStance()
	local current = ATW.Stance()
	local optimal = ATW.GetOptimalStance()
	local rage = UnitMana("player")

	-- Same stance, no switch needed
	if current == optimal then
		return false, nil
	end

	-- Check if target stance is available
	if not ATW.AvailableStances[optimal] then
		return false, nil
	end

	-- Check if we can afford the dance (rage consideration)
	if not ATW.CanDance(rage) then
		return false, nil
	end

	-- Check GCD from last stance change
	if ATW.State.LastStance + 1.5 > GetTime() then
		return false, nil
	end

	return true, optimal
end

---------------------------------------
-- Stance Dancing
---------------------------------------
function ATW.CanDance(rage)
	local maxRage = ATW.Talents.TM + AutoTurtleWarrior_Config.DanceRage
	return rage <= maxRage
end

function ATW.GoStance(stance, reason)
	-- Check GCD
	if ATW.State.LastStance + 1.5 > GetTime() then
		return false
	end

	-- Check if stance is available
	if not ATW.AvailableStances[stance] then
		ATW.Debug("Stance " .. stance .. " not learned!")
		return false
	end

	if not ATW.State.OldStance then
		ATW.State.OldStance = ATW.Stance()
	end

	ATW.Debug("Stance: " .. reason)
	CastShapeshiftForm(stance)
	ATW.State.LastStance = GetTime()
	return true
end

---------------------------------------
-- Weapon Checks
---------------------------------------
function ATW.HasWeapon()
	local link = GetInventoryItemLink("player", 16)
	if not link then return false end

	local _, _, code = strfind(link, "(%d+):")
	local _, itemLink = GetItemInfo(code)

	-- Exclude fishing poles
	if itemLink == "item:7005:0:0:0" or itemLink == "item:2901:0:0:0" then
		return false
	end

	return not GetInventoryItemBroken("player", 16)
end

function ATW.HasShield()
	local link = GetInventoryItemLink("player", 17)
	if not link then return false end

	local _, _, code = strfind(link, "(%d+):")
	local _, _, _, _, _, itemType = GetItemInfo(code)

	return itemType == "Shields" and not GetInventoryItemBroken("player", 17)
end
