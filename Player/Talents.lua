--[[
	Auto Turtle Warrior - Player/Talents
	Talent detection, spell rank detection, and loading
	All talents and spells used by Engine.lua simulation

	Spell data source: Zebouski/WarriorSim-TurtleWoW
	https://github.com/Zebouski/WarriorSim-TurtleWoW

	FILE STRUCTURE:
	===============
	1. SPELL DATA TABLES (line ~15)
	   - RendData, ExecuteData, HeroicStrikeData, etc.
	   - Base values by rank for damage calculations

	2. SPELL LOOKUP FUNCTIONS (line ~125)
	   - GetMaxSpellRank(), HasSpell()
	   - Get damage values: GetRendDamage(), GetExecuteBase(), etc.

	3. LOADING FUNCTIONS (line ~325)
	   - LoadSpells() - Detect learned spells and ranks
	   - LoadTalents() - Read talent points from API

	4. RACIAL DATA & FUNCTIONS (line ~520)
	   - RacialData table with TurtleWoW values
	   - LoadRacials(), IsRacialReady()
	   - Blood Fury, Berserking, Perception support

	5. ATW.Has CACHE (line ~672)
	   - LoadAvailableAbilities() - Caches all ability availability
	   - Engine uses ATW.Has.AbilityName for fast lookups
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
-- Current TurtleWoW reverted Execute back to vanilla values and removed the
-- short cooldown. Improved Execute reduces rage cost again.
ATW.ExecuteData = {
	-- [rank] = { base, coeff, level }
	[1] = { base = 125, coeff = 3,  level = 24 },
	[2] = { base = 200, coeff = 6,  level = 32 },
	[3] = { base = 325, coeff = 9,  level = 40 },
	[4] = { base = 450, coeff = 12, level = 48 },
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
-- Get Rend duration based on cached value (set by LoadSpells)
-- Returns: duration in seconds
-- PREFER using ATW.RendDuration directly instead of calling this function
---------------------------------------
function ATW.GetRendDuration()
	-- Use cached value if available (set by LoadSpells)
	if ATW.RendDuration and ATW.RendDuration > 0 then
		return ATW.RendDuration
	end
	-- Fallback: calculate from rank (shouldn't be needed after LoadSpells)
	local rank = ATW.Spells and ATW.Spells.RendRank or 0
	if rank <= 0 then
		return 0
	end
	local data = ATW.RendData[rank]
	return data and data.duration or 22
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
-- Get number of Rend ticks based on cached duration
-- Rend ticks every 3 seconds
-- Uses ATW.RendTicks if available (set by LoadSpells)
---------------------------------------
function ATW.GetRendTicks()
	-- Use cached value if available
	if ATW.RendTicks and ATW.RendTicks > 0 then
		return ATW.RendTicks
	end
	-- Fallback to calculation (shouldn't be needed after LoadSpells)
	local duration = (ATW.RendDuration and ATW.RendDuration > 0) and ATW.RendDuration or 22
	return math.floor(duration / 3)
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
	local baseAP = data and data.ap or 232

	-- Apply Improved Battle Shout talent (Fury/Arms)
	-- +5/10/15/20/25% Battle Shout AP (5 talent points)
	if ATW.Talents and ATW.Talents.ImprovedBattleShout and ATW.Talents.ImprovedBattleShout > 0 then
		baseAP = baseAP * (1 + ATW.Talents.ImprovedBattleShout * 0.05)
	end

	return baseAP
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

	---------------------------------------
	-- CACHE REND VALUES (use these everywhere instead of calling functions)
	-- This prevents fallback values from being used mid-combat
	---------------------------------------
	if ATW.Spells.RendRank > 0 then
		local rendData = ATW.RendData[ATW.Spells.RendRank]
		if rendData then
			ATW.RendDuration = rendData.duration  -- Cached duration in seconds
			ATW.RendTicks = math.floor(rendData.duration / 3)  -- Cached tick count
			ATW.RendBaseDamage = rendData.damage  -- Cached base damage
		else
			-- Fallback for unknown rank (shouldn't happen)
			ATW.RendDuration = 22
			ATW.RendTicks = 7
			ATW.RendBaseDamage = 147
		end
	else
		-- No Rend learned - set defaults
		ATW.RendDuration = 0
		ATW.RendTicks = 0
		ATW.RendBaseDamage = 0
	end

	-- Update RendTracker with cached value
	if ATW.RendTracker then
		ATW.RendTracker.REND_DURATION = ATW.RendDuration
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
	-- TurtleWoW: +5/10 rage on Charge
	_, _, _, _, r = GetTalentInfo(1, 4)
	ATW.Talents.ChargeRage = 9 + (r * 5)  -- Base 9 + talent

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
	-- TurtleWoW: 20/40/60% weapon damage over 6s, ticking every 1.5s
	_, _, _, _, r = GetTalentInfo(1, 11)
	ATW.Talents.DeepWounds = r  -- 0/1/2/3 points

	-- Two-Handed Weapon Specialization
	-- TurtleWoW: 3 points, +2/4/6% damage with 2H weapons.
	-- Scan by name because the tree was shuffled in CC2.
	ATW.Talents.TwoHandSpec = 0
	for i = 1, 30 do
		local name, _, _, _, rank = GetTalentInfo(1, i)
		if name and string.find(name, "Two") and string.find(name, "Handed") and string.find(name, "Weapon Specialization") then
			ATW.Talents.TwoHandSpec = rank or 0
			break
		end
	end

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

	-- Improved Battle Shout (Fury tier 2 or Arms tier 2, 5 points)
	-- +5/10/15/20/25% Battle Shout AP
	-- Index unknown - scan by name in both Fury and Arms trees
	ATW.Talents.ImprovedBattleShout = 0
	for tree = 1, 2 do  -- Scan Arms (1) and Fury (2)
		for i = 1, 30 do
			local name, _, _, _, rank = GetTalentInfo(tree, i)
			if name and (string.find(name, "Improved Battle Shout") or string.find(name, "Battle Shout") and string.find(name, "Improved")) then
				ATW.Talents.ImprovedBattleShout = rank  -- 0-5 points
				break
			end
		end
		if ATW.Talents.ImprovedBattleShout > 0 then break end
	end

	-- Cruelty (Fury tier 1, slot 2)
	-- +1/2/3/4/5% crit chance
	_, _, _, _, r = GetTalentInfo(2, 2)
	ATW.Talents.Cruelty = r  -- 0-5% crit

	-- Unbridled Wrath (Fury tier 2, slot 3)
	-- TurtleWoW: 15/30/45/60/75% chance for +1 rage on hit (2H gets +2)
	_, _, _, _, r = GetTalentInfo(2, 5)
	ATW.Talents.UnbridledWrath = r * 15  -- Percentage chance

	-- Improved Execute
	-- TurtleWoW later reverted Execute cooldown behavior back to vanilla:
	-- no Execute CD, and this talent reduces rage cost by 2/5 again.
	ATW.Talents.ImprovedExecute = 0
	for i = 1, 30 do
		local name, _, _, _, rank = GetTalentInfo(2, i)
		if name and (string.find(name, "Improved Execute") or string.find(name, "Reckless Execute")) then
			ATW.Talents.ImprovedExecute = rank or 0
			break
		end
	end
	ATW.Talents.RecklessExecute = 0  -- Legacy key; cooldown reduction is no longer current.
	if ATW.Talents.ImprovedExecute >= 2 then
		ATW.Talents.ExecCost = 10
	elseif ATW.Talents.ImprovedExecute == 1 then
		ATW.Talents.ExecCost = 13
	else
		ATW.Talents.ExecCost = 15
	end

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

	-- Improved Whirlwind (Fury tier 5, 3 points) - NEW in 1.17.2
	-- Reduces Whirlwind cooldown by 1/1.5/2 seconds
	-- Source: https://turtle-wow.fandom.com/wiki/Patch_1.17.2
	-- Index unknown - scan by name
	ATW.Talents.ImprovedWhirlwind = 0
	for i = 1, 30 do
		local name, _, _, _, rank = GetTalentInfo(2, i)
		if name and string.find(name, "Improved Whirlwind") then
			ATW.Talents.ImprovedWhirlwind = rank  -- 0-3 points
			break
		end
	end

	-- Dual Wield Specialization (Fury tier 6, 5 points)
	-- +5/10/15/20/25% offhand weapon damage
	-- Index unknown - scan by name
	ATW.Talents.DualWieldSpec = 0
	for i = 1, 30 do
		local name, _, _, _, rank = GetTalentInfo(2, i)
		if name and string.find(name, "Dual Wield Specialization") then
			ATW.Talents.DualWieldSpec = rank  -- 0-5 points
			break
		end
	end

	---------------------------------------
	-- ARMS TREE (continued)
	---------------------------------------

	-- Master of Arms (Arms, 5 points) - TurtleWoW
	-- Replaces weapon-specific specializations
	-- Effect varies by equipped weapon type:
	-- - Axe: +1/2/3/4/5% crit
	-- - Mace: +4/8/12/16/20% armor penetration
	-- - Sword: +1/2/3/4/5% chance for extra attack after hit
	-- - Polearm: +0.4/0.8/1.2/1.6/2.0 yard range
	-- Source: https://turtle-wow.fandom.com/wiki/Patch_1.17.2
	-- Index unknown - scan by name
	ATW.Talents.MasterOfArms = 0
	for i = 1, 30 do
		local name, _, _, _, rank = GetTalentInfo(1, i)
		if name and string.find(name, "Master of Arms") then
			ATW.Talents.MasterOfArms = rank  -- 0-5 points
			break
		end
	end

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
		ATW.Print("  Master of Arms: " .. (ATW.Talents.MasterOfArms or 0) .. " points")
		ATW.Print("  Improved Execute: " .. (ATW.Talents.ImprovedExecute or 0) .. " points")
		ATW.Print("  Improved Whirlwind: " .. (ATW.Talents.ImprovedWhirlwind or 0) .. " points")
		ATW.Print("  Dual Wield Spec: " .. (ATW.Talents.DualWieldSpec or 0) .. " points")
		ATW.Print("  Improved Battle Shout: " .. (ATW.Talents.ImprovedBattleShout or 0) .. " points")
	end
end

---------------------------------------
-- Racial Ability Data (TurtleWoW values)
-- Source: TurtleWoW Patch 1.17.2
---------------------------------------
ATW.RacialData = {
	-- Blood Fury (Orc): +AP = level * 2, off GCD
	BloodFury = {
		name = "Blood Fury",
		race = "Orc",
		duration = 15,
		cooldown = 120,
		apBonus = function() return UnitLevel("player") * 2 end,  -- 120 AP at 60
		offGCD = true,
	},
	-- Berserking (Troll): 10-15% haste based on HP, costs 5 rage
	Berserking = {
		name = "Berserking",
		race = "Troll",
		duration = 10,
		cooldown = 180,
		rageCost = 5,
		hasteMin = 10,  -- At full HP
		hasteMax = 15,  -- At low HP (TurtleWoW reduced from 30%)
		offGCD = false,
	},
	-- Perception (Human): +2% crit (TurtleWoW bonus)
	Perception = {
		name = "Perception",
		race = "Human",
		duration = 20,
		cooldown = 180,
		critBonus = 2,  -- TurtleWoW: +2% physical and spell crit
		offGCD = false,
	},
}

---------------------------------------
-- Detect player race and available racials
---------------------------------------
function ATW.LoadRacials()
	ATW.Racials = ATW.Racials or {}

	-- Get player race
	local _, race = UnitRace("player")
	ATW.Racials.Race = race

	-- Check for racial abilities in spellbook
	ATW.Racials.HasBloodFury = ATW.HasSpell("Blood Fury")
	ATW.Racials.HasBerserking = ATW.HasSpell("Berserking")
	ATW.Racials.HasPerception = ATW.HasSpell("Perception")

	-- Weapon skill racials (TurtleWoW: +3 instead of +5)
	ATW.Racials.HasSwordSpec = false  -- Human
	ATW.Racials.HasMaceSpec = false   -- Human/Dwarf
	ATW.Racials.HasAxeSpec = false    -- Orc

	if race == "Human" then
		ATW.Racials.HasSwordSpec = true
		ATW.Racials.HasMaceSpec = true
		ATW.Racials.WeaponSkillBonus = 3  -- TurtleWoW reduced from 5
	elseif race == "Dwarf" then
		ATW.Racials.HasMaceSpec = true
		ATW.Racials.WeaponSkillBonus = 3
	elseif race == "Orc" then
		ATW.Racials.HasAxeSpec = true
		ATW.Racials.WeaponSkillBonus = 3
	else
		ATW.Racials.WeaponSkillBonus = 0
	end

	-- Debug output
	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		ATW.Print("Racials loaded:")
		ATW.Print("  Race: " .. (race or "Unknown"))
		if ATW.Racials.HasBloodFury then
			ATW.Print("  Blood Fury: YES (+AP=" .. ATW.RacialData.BloodFury.apBonus() .. ")")
		end
		if ATW.Racials.HasBerserking then
			ATW.Print("  Berserking: YES (10-15% haste)")
		end
		if ATW.Racials.HasPerception then
			ATW.Print("  Perception: YES (+2% crit)")
		end
		if ATW.Racials.WeaponSkillBonus > 0 then
			ATW.Print("  Weapon Skill: +" .. ATW.Racials.WeaponSkillBonus)
		end
	end
end

---------------------------------------
-- Get Blood Fury AP bonus (level-scaled)
---------------------------------------
function ATW.GetBloodFuryAP()
	if not ATW.Racials or not ATW.Racials.HasBloodFury then
		return 0
	end
	return UnitLevel("player") * 2
end

---------------------------------------
-- Get Berserking haste % based on current HP
-- TurtleWoW: 10% at full HP, 15% at low HP
---------------------------------------
function ATW.GetBerserkingHaste()
	if not ATW.Racials or not ATW.Racials.HasBerserking then
		return 0
	end

	local hp = UnitHealth("player")
	local maxHp = UnitHealthMax("player")
	if not hp or not maxHp or maxHp <= 0 then
		return 10  -- Default to min
	end

	local hpPercent = hp / maxHp
	-- Linear interpolation: 100% HP = 10%, 0% HP = 15%
	local haste = 10 + (1 - hpPercent) * 5
	return math.floor(haste)
end

---------------------------------------
-- Get Perception crit bonus (TurtleWoW)
---------------------------------------
function ATW.GetPerceptionCrit()
	if not ATW.Racials or not ATW.Racials.HasPerception then
		return 0
	end
	return 2  -- +2% crit during Perception
end

---------------------------------------
-- Check if a racial cooldown is ready
---------------------------------------
function ATW.IsRacialReady(racialName)
	-- Check if we have the racial
	if racialName == "Blood Fury" and not (ATW.Racials and ATW.Racials.HasBloodFury) then
		return false
	elseif racialName == "Berserking" and not (ATW.Racials and ATW.Racials.HasBerserking) then
		return false
	elseif racialName == "Perception" and not (ATW.Racials and ATW.Racials.HasPerception) then
		return false
	end

	-- Check cooldown via GetCooldownRemaining (returns 0 if ready OR spell not found)
	-- This is more robust than Ready() which returns nil if spell not found
	if ATW.GetCooldownRemaining then
		return ATW.GetCooldownRemaining(racialName) <= 0
	end

	return true  -- Assume ready if we can't check
end

---------------------------------------
-- CACHED AVAILABLE ABILITIES
-- This table is populated once on load and updated on events
-- Use ATW.Has.AbilityName instead of checking APIs repeatedly
---------------------------------------
ATW.Has = {}

function ATW.LoadAvailableAbilities()
	-- Clear previous state
	ATW.Has = {}

	---------------------------------------
	-- Talent-based abilities
	---------------------------------------
	ATW.Has.Bloodthirst = ATW.Talents and ATW.Talents.HasBT or false
	ATW.Has.MortalStrike = ATW.Talents and ATW.Talents.HasMS or false
	ATW.Has.DeathWish = ATW.Talents and ATW.Talents.HasDW or false
	ATW.Has.SweepingStrikes = ATW.Talents and ATW.Talents.HasSS or false
	ATW.Has.ImprovedBerserkerRage = ATW.Talents and ATW.Talents.HasIBR or false
	ATW.Has.AngerManagement = ATW.Talents and ATW.Talents.AngerManagement or false

	---------------------------------------
	-- Spell-based abilities (learned by level/trainer)
	---------------------------------------
	ATW.Has.Execute = ATW.Spells and ATW.Spells.ExecuteRank and ATW.Spells.ExecuteRank > 0 or false
	ATW.Has.Rend = ATW.Spells and ATW.Spells.RendRank and ATW.Spells.RendRank > 0 or false
	ATW.Has.HeroicStrike = ATW.Spells and ATW.Spells.HeroicStrikeRank and ATW.Spells.HeroicStrikeRank > 0 or false
	ATW.Has.Cleave = ATW.Spells and ATW.Spells.CleaveRank and ATW.Spells.CleaveRank > 0 or false
	ATW.Has.Overpower = ATW.Spells and ATW.Spells.OverpowerRank and ATW.Spells.OverpowerRank > 0 or false
	ATW.Has.Whirlwind = ATW.Spells and ATW.Spells.WhirlwindRank and ATW.Spells.WhirlwindRank > 0 or false
	ATW.Has.Slam = ATW.Spells and ATW.Spells.SlamRank and ATW.Spells.SlamRank > 0 or false
	ATW.Has.Hamstring = ATW.Spells and ATW.Spells.HamstringRank and ATW.Spells.HamstringRank > 0 or false
	ATW.Has.BattleShout = ATW.Spells and ATW.Spells.BattleShoutRank and ATW.Spells.BattleShoutRank > 0 or false
	ATW.Has.Charge = ATW.Spells and ATW.Spells.ChargeRank and ATW.Spells.ChargeRank > 0 or false
	ATW.Has.Bloodrage = ATW.Spells and ATW.Spells.BloodrageRank and ATW.Spells.BloodrageRank > 0 or false
	ATW.Has.BerserkerRage = ATW.Spells and ATW.Spells.BerserkerRageRank and ATW.Spells.BerserkerRageRank > 0 or false
	ATW.Has.Pummel = ATW.Spells and ATW.Spells.PummelRank and ATW.Spells.PummelRank > 0 or false
	ATW.Has.Recklessness = ATW.Spells and ATW.Spells.RecklessnessRank and ATW.Spells.RecklessnessRank > 0 or false

	---------------------------------------
	-- Racial abilities
	---------------------------------------
	ATW.Has.BloodFury = ATW.Racials and ATW.Racials.HasBloodFury or false
	ATW.Has.Berserking = ATW.Racials and ATW.Racials.HasBerserking or false
	ATW.Has.Perception = ATW.Racials and ATW.Racials.HasPerception or false

	---------------------------------------
	-- Debug output
	---------------------------------------
	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		local count = 0
		for k, v in pairs(ATW.Has) do
			if v then count = count + 1 end
		end
		ATW.Print("Available abilities cached: " .. count .. " total")
	end
end
