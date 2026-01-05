--[[
	Auto Turtle Warrior - Player/Stats
	Dynamic player statistics tracking
]]--

ATW.Stats = {
	-- Base stats
	Strength = 0,
	Agility = 0,
	Stamina = 0,

	-- Combat stats
	AP = 0,              -- Total Attack Power
	Crit = 0,            -- Critical Strike %

	-- Health/Resource
	HP = 0,
	MaxHP = 0,
	Rage = 0,

	-- Weapon info
	MainHandSpeed = 0,
	OffHandSpeed = 0,
	HasOffHand = false,

	-- Timestamps
	LastUpdate = 0,
}

---------------------------------------
-- Calculate Crit from Agility
-- Vanilla formula: 5% base + 1% per 20 AGI at level 60
---------------------------------------
local function CalcCritFromAgility(agi)
	local level = UnitLevel("player")
	-- AGI per 1% crit scales with level (roughly 20 at 60)
	local agiPerCrit = 20
	if level < 60 then
		agiPerCrit = 10 + (level / 6)  -- Rough scaling
	end
	local baseCrit = 5  -- Warriors have ~5% base crit
	return baseCrit + (agi / agiPerCrit)
end

---------------------------------------
-- Update Stats
---------------------------------------
function ATW.UpdateStats()
	local stats = ATW.Stats

	-- Base stats
	stats.Strength = UnitStat("player", 1) or 0
	stats.Agility = UnitStat("player", 2) or 0
	stats.Stamina = UnitStat("player", 3) or 0

	-- Attack Power (base + buffs - debuffs)
	local base, posBuff, negBuff = UnitAttackPower("player")
	stats.AP = (base or 0) + (posBuff or 0) + (negBuff or 0)

	-- Critical Strike (calculated from agility in vanilla)
	stats.Crit = CalcCritFromAgility(stats.Agility)

	-- Health
	stats.HP = UnitHealth("player") or 0
	stats.MaxHP = UnitHealthMax("player") or 1

	-- Rage
	stats.Rage = UnitMana("player") or 0

	-- Weapon speeds
	local mainSpeed, offSpeed = UnitAttackSpeed("player")
	stats.MainHandSpeed = mainSpeed or 2.6
	stats.OffHandSpeed = offSpeed or 0
	stats.HasOffHand = offSpeed ~= nil and offSpeed > 0

	stats.LastUpdate = GetTime()
end

---------------------------------------
-- Stat Getters (convenience functions)
---------------------------------------
function ATW.GetAP()
	return ATW.Stats.AP
end

function ATW.GetCrit()
	return ATW.Stats.Crit
end

function ATW.GetHealthPercent()
	if ATW.Stats.MaxHP == 0 then return 100 end
	return (ATW.Stats.HP / ATW.Stats.MaxHP) * 100
end

function ATW.GetRage()
	return UnitMana("player")
end

---------------------------------------
-- Debug: Print Stats
---------------------------------------
function ATW.PrintStats()
	ATW.UpdateStats()
	local s = ATW.Stats
	ATW.Print("--- Player Stats ---")
	ATW.Print("STR: " .. s.Strength .. " | AGI: " .. s.Agility)
	ATW.Print("AP: " .. s.AP .. " | Crit: " .. string.format("%.1f", s.Crit) .. "%")
	ATW.Print("MH Speed: " .. string.format("%.1f", s.MainHandSpeed) .. "s" ..
		(s.HasOffHand and (" | OH: " .. string.format("%.1f", s.OffHandSpeed) .. "s") or ""))
end
