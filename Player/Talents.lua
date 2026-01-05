--[[
	Auto Turtle Warrior - Player/Talents
	Talent detection, spell rank detection, and loading
	All talents and spells used by Engine.lua simulation
]]--

---------------------------------------
-- Rend Spell Data (by rank)
-- Source: https://www.wowhead.com/classic/spell=772/rend
---------------------------------------
ATW.RendData = {
	-- [rank] = { damage, duration, level }
	[1] = { damage = 15,  duration = 9,  level = 4 },
	[2] = { damage = 28,  duration = 12, level = 10 },
	[3] = { damage = 45,  duration = 15, level = 20 },
	[4] = { damage = 66,  duration = 18, level = 30 },
	[5] = { damage = 98,  duration = 21, level = 40 },
	[6] = { damage = 126, duration = 21, level = 50 },
	[7] = { damage = 147, duration = 21, level = 60 },
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
-- Load known spells and their max ranks
---------------------------------------
function ATW.LoadSpells()
	ATW.Spells = ATW.Spells or {}

	-- Rend (key spell for tracking)
	ATW.Spells.RendRank = ATW.GetMaxSpellRank("Rend")
	ATW.Spells.HasRend = ATW.Spells.RendRank > 0

	-- Update RendTracker duration with actual spell rank
	if ATW.RendTracker and ATW.Spells.RendRank > 0 then
		ATW.RendTracker.REND_DURATION = ATW.GetRendDuration()
	end

	-- Other combat spells (for reference)
	ATW.Spells.ExecuteRank = ATW.GetMaxSpellRank("Execute")
	ATW.Spells.WhirlwindRank = ATW.GetMaxSpellRank("Whirlwind")
	ATW.Spells.BloodthirstRank = ATW.GetMaxSpellRank("Bloodthirst")
	ATW.Spells.MortalStrikeRank = ATW.GetMaxSpellRank("Mortal Strike")
	ATW.Spells.HeroicStrikeRank = ATW.GetMaxSpellRank("Heroic Strike")
	ATW.Spells.BattleShoutRank = ATW.GetMaxSpellRank("Battle Shout")

	-- Debug output
	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		ATW.Print("Spells loaded:")
		ATW.Print("  Rend: Rank " .. ATW.Spells.RendRank ..
			" (" .. ATW.GetRendDamage() .. " dmg / " .. ATW.GetRendDuration() .. "s)")
		ATW.Print("  Execute: Rank " .. ATW.Spells.ExecuteRank)
		ATW.Print("  BT: Rank " .. ATW.Spells.BloodthirstRank ..
			" | MS: Rank " .. ATW.Spells.MortalStrikeRank)
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
