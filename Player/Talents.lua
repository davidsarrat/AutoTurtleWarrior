--[[
	Auto Turtle Warrior - Player/Talents
	Talent detection, spell rank detection, and loading
	All talents and spells used by Engine.lua simulation

	Spell data source: Zebouski/WarriorSim-TurtleWoW
	https://github.com/Zebouski/WarriorSim-TurtleWoW
]]--

---------------------------------------
-- Spell Data Tables (by rank)
-- All values from Zebouski/WarriorSim-TurtleWoW
---------------------------------------

-- Rend: base total damage, duration in seconds
-- TurtleWoW has 22s duration for rank 5-7 (not 21s like retail)
ATW.RendData = {
	-- [rank] = { damage, duration, level }
	[1] = { damage = 15,  duration = 10, level = 4 },
	[2] = { damage = 28,  duration = 13, level = 10 },
	[3] = { damage = 45,  duration = 16, level = 20 },
	[4] = { damage = 66,  duration = 19, level = 30 },
	[5] = { damage = 98,  duration = 22, level = 40 },
	[6] = { damage = 126, duration = 22, level = 50 },
	[7] = { damage = 147, duration = 22, level = 60 },
}

-- Execute: base damage + (rage * coefficient)
-- Formula: baseDmg + (usedRage * coeff)
ATW.ExecuteData = {
	-- [rank] = { base, coeff, level }
	[1] = { base = 75,  coeff = 4,  level = 24 },
	[2] = { base = 150, coeff = 8,  level = 32 },
	[3] = { base = 225, coeff = 12, level = 40 },
	[4] = { base = 300, coeff = 16, level = 48 },
	[5] = { base = 600, coeff = 15, level = 56 },
}

-- Heroic Strike: bonus damage added to weapon damage
ATW.HeroicStrikeData = {
	-- [rank] = { bonus, level }
	[1] = { bonus = 11,  level = 1 },
	[2] = { bonus = 21,  level = 8 },
	[3] = { bonus = 32,  level = 16 },
	[4] = { bonus = 44,  level = 24 },
	[5] = { bonus = 58,  level = 32 },
	[6] = { bonus = 80,  level = 40 },
	[7] = { bonus = 111, level = 48 },
	[8] = { bonus = 138, level = 56 },
	[9] = { bonus = 157, level = 60 },
}

-- Mortal Strike: bonus damage (uses normalized weapon damage)
ATW.MortalStrikeData = {
	-- [rank] = { bonus, level }
	[1] = { bonus = 105, level = 40 },
	[2] = { bonus = 110, level = 48 },
	[3] = { bonus = 115, level = 54 },
	[4] = { bonus = 120, level = 60 },
}

-- Cleave: bonus damage per target (hits 2 targets)
ATW.CleaveData = {
	-- [rank] = { bonus, level }
	[1] = { bonus = 5,  level = 20 },
	[2] = { bonus = 10, level = 30 },
	[3] = { bonus = 18, level = 40 },
	[4] = { bonus = 32, level = 50 },
	[5] = { bonus = 50, level = 60 },
}

-- Overpower: bonus damage (uses normalized weapon damage)
ATW.OverpowerData = {
	-- [rank] = { bonus, level }
	[1] = { bonus = 5,  level = 12 },
	[2] = { bonus = 15, level = 28 },
	[3] = { bonus = 25, level = 44 },
	[4] = { bonus = 35, level = 60 },
}

-- Hamstring: flat damage
ATW.HamstringData = {
	-- [rank] = { damage, level }
	[1] = { damage = 5,  level = 8 },
	[2] = { damage = 18, level = 32 },
	[3] = { damage = 45, level = 54 },
}

-- Slam: bonus damage (uses weapon damage + bonus)
ATW.SlamData = {
	-- [rank] = { bonus, level }
	[1] = { bonus = 32, level = 30 },
	[2] = { bonus = 43, level = 38 },
	[3] = { bonus = 68, level = 46 },
	[4] = { bonus = 87, level = 54 },
}

-- Battle Shout: AP bonus
ATW.BattleShoutData = {
	-- [rank] = { ap, level }
	[1] = { ap = 15,  level = 1 },
	[2] = { ap = 35,  level = 12 },
	[3] = { ap = 55,  level = 22 },
	[4] = { ap = 85,  level = 32 },
	[5] = { ap = 130, level = 42 },
	[6] = { ap = 185, level = 52 },
	[7] = { ap = 232, level = 60 },
}

-- Bloodthirst: TurtleWoW formula is 200 + AP * 0.35
-- Only 1 rank (talent ability)
ATW.BloodthirstData = {
	base = 200,
	apCoeff = 0.35,
}

-- Whirlwind: uses normalized weapon damage, no bonus
-- Only 1 rank
ATW.WhirlwindData = {
	normSpeed = 2.4,  -- Normalized speed for 1H
}

---------------------------------------
-- Find highest rank of a spell in spellbook
-- Returns: rank number (1-N) or 0 if not known
---------------------------------------
function ATW.GetMaxSpellRank(spellName)
	local maxRank = 0
	local id = 1

	for t = 1, GetNumSpellTabs() do
		local _, _, _, n = GetSpellTabInfo(t)
		for s = 1, n do
			local name, rank = GetSpellName(id, BOOKTYPE_SPELL)
			if name == spellName then
				-- Parse rank from "Rank X" string
				local _, _, rankNum = strfind(rank or "", "(%d+)")
				if rankNum then
					local r = tonumber(rankNum)
					if r and r > maxRank then
						maxRank = r
					end
				elseif maxRank == 0 then
					-- Spell with no rank (rank 1 implied)
					maxRank = 1
				end
			end
			id = id + 1
		end
	end

	return maxRank
end

---------------------------------------
-- Check if a spell is known
---------------------------------------
function ATW.HasSpell(spellName)
	return ATW.GetMaxSpellRank(spellName) > 0
end

---------------------------------------
-- Get Rend duration based on current max rank
-- Returns: duration in seconds
---------------------------------------
function ATW.GetRendDuration()
	local rank = ATW.Spells and ATW.Spells.RendRank or 0
	if rank <= 0 then
		-- Rend not known, return 0
		return 0
	end
	local data = ATW.RendData[rank]
	return data and data.duration or 21  -- Default to max if rank unknown
end

---------------------------------------
-- Get Rend base damage based on current max rank
-- Note: Improved Rend talent adds 10/20% damage in TurtleWoW
---------------------------------------
function ATW.GetRendDamage()
	local rank = ATW.Spells and ATW.Spells.RendRank or 0
	if rank <= 0 then return 0 end

	local data = ATW.RendData[rank]
	if not data then return 0 end

	local baseDamage = data.damage

	-- Apply Improved Rend talent (TurtleWoW: 2 points for 10/20%)
	local impRend = ATW.Talents and ATW.Talents.ImpRend or 0
	if impRend > 0 then
		baseDamage = baseDamage * (1 + impRend * 0.10)  -- 10% per point
	end

	return baseDamage
end

---------------------------------------
-- Get number of Rend ticks based on duration
-- Rend ticks every 3 seconds
---------------------------------------
function ATW.GetRendTicks()
	local duration = ATW.GetRendDuration()
	return math.floor(duration / 3)  -- 9s=3, 12s=4, 15s=5, 18s=6, 21s=7
end

---------------------------------------
-- Get Rend damage per tick (base only, no AP)
---------------------------------------
function ATW.GetRendTickDamage()
	local totalDamage = ATW.GetRendDamage()
	local ticks = ATW.GetRendTicks()
	if ticks <= 0 then return 0 end
	return totalDamage / ticks
end

---------------------------------------
-- Execute: Get base damage and rage coefficient
---------------------------------------
function ATW.GetExecuteBase()
	local rank = ATW.Spells and ATW.Spells.ExecuteRank or 0
	if rank <= 0 then return 600 end  -- Default to max
	local data = ATW.ExecuteData[rank]
	return data and data.base or 600
end

function ATW.GetExecuteCoeff()
	local rank = ATW.Spells and ATW.Spells.ExecuteRank or 0
	if rank <= 0 then return 15 end  -- Default to max
	local data = ATW.ExecuteData[rank]
	return data and data.coeff or 15
end

---------------------------------------
-- Heroic Strike: Get bonus damage
---------------------------------------
function ATW.GetHeroicStrikeBonus()
	local rank = ATW.Spells and ATW.Spells.HeroicStrikeRank or 0
	if rank <= 0 then return 157 end  -- Default to max
	local data = ATW.HeroicStrikeData[rank]
	return data and data.bonus or 157
end

---------------------------------------
-- Mortal Strike: Get bonus damage
---------------------------------------
function ATW.GetMortalStrikeBonus()
	local rank = ATW.Spells and ATW.Spells.MortalStrikeRank or 0
	if rank <= 0 then return 120 end  -- Default to max
	local data = ATW.MortalStrikeData[rank]
	return data and data.bonus or 120
end

---------------------------------------
-- Cleave: Get bonus damage
---------------------------------------
function ATW.GetCleaveBonus()
	local rank = ATW.Spells and ATW.Spells.CleaveRank or 0
	if rank <= 0 then return 50 end  -- Default to max
	local data = ATW.CleaveData[rank]
	return data and data.bonus or 50
end

---------------------------------------
-- Overpower: Get bonus damage
---------------------------------------
function ATW.GetOverpowerBonus()
	local rank = ATW.Spells and ATW.Spells.OverpowerRank or 0
	if rank <= 0 then return 35 end  -- Default to max
	local data = ATW.OverpowerData[rank]
	return data and data.bonus or 35
end

---------------------------------------
-- Hamstring: Get damage
---------------------------------------
function ATW.GetHamstringDamage()
	local rank = ATW.Spells and ATW.Spells.HamstringRank or 0
	if rank <= 0 then return 45 end  -- Default to max
	local data = ATW.HamstringData[rank]
	return data and data.damage or 45
end

---------------------------------------
-- Slam: Get bonus damage
---------------------------------------
function ATW.GetSlamBonus()
	local rank = ATW.Spells and ATW.Spells.SlamRank or 0
	if rank <= 0 then return 87 end  -- Default to max
	local data = ATW.SlamData[rank]
	return data and data.bonus or 87
end

---------------------------------------
-- Battle Shout: Get AP bonus
---------------------------------------
function ATW.GetBattleShoutAP()
	local rank = ATW.Spells and ATW.Spells.BattleShoutRank or 0
	if rank <= 0 then return 232 end  -- Default to max
	local data = ATW.BattleShoutData[rank]
	return data and data.ap or 232
end

---------------------------------------
-- Bloodthirst: Get damage (200 + AP * 0.35)
---------------------------------------
function ATW.GetBloodthirstDamage(ap)
	ap = ap or (ATW.Stats and ATW.Stats.AP) or 1000
	return ATW.BloodthirstData.base + (ap * ATW.BloodthirstData.apCoeff)
end

---------------------------------------
-- Load known spells and their max ranks
---------------------------------------
function ATW.LoadSpells()
	ATW.Spells = ATW.Spells or {}

	-- Core combat spells (ranked)
	ATW.Spells.RendRank = ATW.GetMaxSpellRank("Rend")
	ATW.Spells.HasRend = ATW.Spells.RendRank > 0
	ATW.Spells.ExecuteRank = ATW.GetMaxSpellRank("Execute")
	ATW.Spells.HeroicStrikeRank = ATW.GetMaxSpellRank("Heroic Strike")
	ATW.Spells.CleaveRank = ATW.GetMaxSpellRank("Cleave")
	ATW.Spells.OverpowerRank = ATW.GetMaxSpellRank("Overpower")
	ATW.Spells.HamstringRank = ATW.GetMaxSpellRank("Hamstring")
	ATW.Spells.SlamRank = ATW.GetMaxSpellRank("Slam")
	ATW.Spells.WhirlwindRank = ATW.GetMaxSpellRank("Whirlwind")
	ATW.Spells.BattleShoutRank = ATW.GetMaxSpellRank("Battle Shout")

	-- Talent abilities (only 1 rank)
	ATW.Spells.BloodthirstRank = ATW.GetMaxSpellRank("Bloodthirst")
	ATW.Spells.MortalStrikeRank = ATW.GetMaxSpellRank("Mortal Strike")

	-- Utility spells (needed for simulator to know if learned)
	ATW.Spells.ChargeRank = ATW.GetMaxSpellRank("Charge")
	ATW.Spells.BloodrageRank = ATW.GetMaxSpellRank("Bloodrage")
	ATW.Spells.BerserkerRageRank = ATW.GetMaxSpellRank("Berserker Rage")
	ATW.Spells.PummelRank = ATW.GetMaxSpellRank("Pummel")

	-- Cooldown abilities (talent-based, only 1 rank)
	ATW.Spells.DeathWishRank = ATW.GetMaxSpellRank("Death Wish")
	ATW.Spells.RecklessnessRank = ATW.GetMaxSpellRank("Recklessness")
	ATW.Spells.SweepingStrikesRank = ATW.GetMaxSpellRank("Sweeping Strikes")

	-- Update RendTracker duration with actual spell rank
	if ATW.RendTracker and ATW.Spells.RendRank > 0 then
		ATW.RendTracker.REND_DURATION = ATW.GetRendDuration()
	end

	-- Debug output
	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		ATW.Print("Spells loaded:")
		ATW.Print("  Rend R" .. ATW.Spells.RendRank .. " | Exec R" .. ATW.Spells.ExecuteRank ..
			" | HS R" .. ATW.Spells.HeroicStrikeRank)
		ATW.Print("  BT: " .. (ATW.Spells.BloodthirstRank > 0 and "Yes" or "No") ..
			" | MS R" .. ATW.Spells.MortalStrikeRank)
		ATW.Print("  WW R" .. ATW.Spells.WhirlwindRank .. " | Slam R" .. ATW.Spells.SlamRank ..
			" | Charge R" .. ATW.Spells.ChargeRank)
	end
end

function ATW.LoadTalents()
	local _, _, _, _, r

	---------------------------------------
	-- ARMS TREE
	---------------------------------------

	-- Improved Heroic Strike (Arms tier 1, slot 1)
	-- Reduces rage cost by 1/2/3
	_, _, _, _, r = GetTalentInfo(1, 1)
	ATW.Talents.HSCost = 15 - r

	-- Deflection (Arms tier 1, slot 2) - Parry
	-- Not used in sim

	-- Improved Rend (Arms tier 2, slot 1)
	-- TurtleWoW: 2 points for +10/20% Rend DAMAGE (not duration!)
	-- Vanilla: 3 points for +15/25/35% damage
	_, _, _, _, r = GetTalentInfo(1, 3)
	ATW.Talents.ImpRend = r  -- 0/1/2 points in TurtleWoW

	-- Improved Charge (Arms tier 2, slot 2)
	-- +3/6 rage on Charge
	_, _, _, _, r = GetTalentInfo(1, 4)
	ATW.Talents.ChargeRage = 9 + (r * 3)  -- Base 9 + talent

	-- Tactical Mastery (Arms tier 3, slot 1)
	-- Retain 5/10/15/20/25 rage when switching stances
	_, _, _, _, r = GetTalentInfo(1, 5)
	ATW.Talents.TM = r * 5

	-- Improved Overpower (Arms tier 5, slot 1)
	-- +25/50% crit chance on Overpower
	_, _, _, _, r = GetTalentInfo(1, 9)
	ATW.Talents.ImpOP = r * 25

	-- Anger Management (Arms tier 5, slot 2)
	-- Generates 1 rage every 3 seconds
	_, _, _, _, r = GetTalentInfo(1, 10)
	ATW.Talents.AngerManagement = r > 0

	-- Deep Wounds (Arms tier 6, slot 1)
	-- Causes 20/40/60% weapon damage over 12s on crit
	_, _, _, _, r = GetTalentInfo(1, 11)
	ATW.Talents.DeepWounds = r  -- 0/1/2/3 points

	-- Impale (Arms tier 6, slot 2)
	-- +10/20% crit damage on abilities
	_, _, _, _, r = GetTalentInfo(1, 12)
	ATW.Talents.Impale = r  -- 0/1/2 points

	-- Sweeping Strikes (Arms tier 7)
	_, _, _, _, r = GetTalentInfo(1, 13)
	ATW.Talents.HasSS = r > 0

	-- Mortal Strike (Arms tier 9, slot 1)
	_, _, _, _, r = GetTalentInfo(1, 17)
	ATW.Talents.HasMS = r > 0

	---------------------------------------
	-- FURY TREE
	---------------------------------------

	-- Booming Voice (Fury tier 1, slot 1) - Shout range/duration
	-- Not used in sim

	-- Cruelty (Fury tier 1, slot 2)
	-- +1/2/3/4/5% crit chance
	_, _, _, _, r = GetTalentInfo(2, 2)
	ATW.Talents.Cruelty = r  -- 0-5% crit

	-- Unbridled Wrath (Fury tier 2, slot 3)
	-- 8/16/24/32/40% chance for +1 rage on hit (2H gets +2 in TurtleWoW)
	_, _, _, _, r = GetTalentInfo(2, 5)
	ATW.Talents.UnbridledWrath = r * 8  -- Percentage chance

	-- Improved Execute (Fury tier 5, slot 2)
	-- Reduces Execute cost by 2/5 rage
	_, _, _, _, r = GetTalentInfo(2, 10)
	ATW.Talents.ExecCost = 15 - math.floor(r * 2.5)

	-- Enrage / Wrecking Crew (Fury tier 5, slot 3)
	-- On crit, +5/10/15/20/25% damage for 12s
	_, _, _, _, r = GetTalentInfo(2, 11)
	ATW.Talents.Enrage = r  -- 0-5 points (5/10/15/20/25% dmg)

	-- Flurry (Fury tier 6, slot 1)
	-- On crit, +10/15/20/25/30% attack speed for 3 swings
	_, _, _, _, r = GetTalentInfo(2, 12)
	ATW.Talents.Flurry = r  -- 0-5 points

	-- Death Wish (Fury tier 7, slot 1)
	_, _, _, _, r = GetTalentInfo(2, 13)
	ATW.Talents.HasDW = r > 0

	-- Improved Berserker Rage (Fury tier 7, slot 3)
	-- Generates rage when used
	_, _, _, _, r = GetTalentInfo(2, 15)
	ATW.Talents.HasIBR = r > 0

	-- Bloodthirst (Fury tier 9, slot 1)
	_, _, _, _, r = GetTalentInfo(2, 17)
	ATW.Talents.HasBT = r > 0

	---------------------------------------
	-- PROTECTION TREE (minimal)
	---------------------------------------

	-- Shield Specialization could matter for DPS warrior but usually not taken
	-- Skipping most Protection talents for DPS sim

	---------------------------------------
	-- Debug output
	---------------------------------------
	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		ATW.Print("Talents loaded:")
		ATW.Print("  TM: " .. ATW.Talents.TM .. " | Cruelty: " .. ATW.Talents.Cruelty .. "%")
		ATW.Print("  UW: " .. ATW.Talents.UnbridledWrath .. "% | Flurry: " .. (ATW.Talents.Flurry or 0))
		ATW.Print("  DW: " .. (ATW.Talents.DeepWounds or 0) .. " | Impale: " .. (ATW.Talents.Impale or 0))
		ATW.Print("  BT: " .. (ATW.Talents.HasBT and "Yes" or "No") .. " | MS: " .. (ATW.Talents.HasMS and "Yes" or "No"))
		ATW.Print("  AM: " .. (ATW.Talents.AngerManagement and "Yes" or "No"))
	end
end
