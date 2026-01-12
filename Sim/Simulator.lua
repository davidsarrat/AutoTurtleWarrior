--[[
	Auto Turtle Warrior - Sim/Simulator
	Support module for the simulation engine

	ARCHITECTURE:
	=============
	Main decision engine is in Engine.lua (tactical layer, 9s horizon).
	This file contains:

	1. COOLDOWN TOGGLE SYSTEM (Active)
	   - ATW.IsCooldownAllowed() - Check if CD enabled by toggles
	   - ATW.BURST_COOLDOWNS, ATW.RECKLESS_COOLDOWNS - CD categories
	   - ATW.SetBurst(), ATW.SetReckless(), ATW.SetSustain() - Toggle functions

	2. TIME-WINDOW SIMULATION (Active)
	   - ATW.SimulateTimeWindow() - 30s simulation for Rend spread comparison
	   - ATW.FindOptimalStrategy() - Compare "normal" vs "rend_spread"
	   - ATW.PrintStrategyComparison() - Debug output

	3. LEGACY DPR FUNCTIONS (Deprecated)
	   - ATW.CalculateDPR() - Old damage-per-rage calculation
	   - ATW.GetSimStats() - Old stats gathering
	   - These are kept for compatibility but NOT used for decisions

	See docs/Toggles.md for cooldown toggle documentation.
	See docs/Simulation.md for full simulation architecture.
]]--

ATW.Sim = {
	-- Simulation settings
	LookAhead = 3,        -- How many abilities to predict
	TimeWindow = 30,      -- 30 second simulation window

	-- DoT tracking for simulation
	ActiveDoTs = {},      -- {[guid] = {ability, appliedAt, ticksRemaining}}

	-- Cache
	LastCalc = 0,
	CachedPriority = nil,
}

---------------------------------------
-- [LEGACY] Calculate DPR (Damage Per Rage)
-- DEPRECATED: Used by GetPriorityList() fallback only.
-- Main decisions now use Engine.GetActionDamage() with full simulation.
---------------------------------------
function ATW.CalculateDPR(abilityName, stats, rage)
	local ability = ATW.Abilities[abilityName]
	if not ability then return 0 end

	-- Get effective rage cost
	local cost = ability.effectiveRage and ability.effectiveRage(stats) or ATW.GetRageCost(abilityName)

	-- Zero cost abilities have infinite DPR (use if available)
	if cost <= 0 then
		return 9999
	end

	-- Calculate damage
	local damage = ability.damage(stats, rage)

	-- Apply Enrage bonus if active (TurtleWoW: 15%)
	if ATW.Buff("player", "Spell_Shadow_UnholyFrenzy") then
		damage = damage * 1.15
	end

	-- Apply Death Wish bonus if active (20%)
	if ATW.Buff("player", "Spell_Shadow_DeathPact") then
		damage = damage * 1.20
	end

	-- Apply crit modifier
	local critChance = (stats.Crit or 0) / 100
	local critMult = 2.0  -- Warriors have 2x crit
	local avgDamage = damage * (1 + (critChance * (critMult - 1)))

	return avgDamage / cost
end

---------------------------------------
-- [LEGACY] Get current player stats for sim
-- DEPRECATED: SimulateAhead/TimeWindow use actual API data.
-- Kept for GetPriorityList() compatibility.
---------------------------------------
function ATW.GetSimStats()
	ATW.UpdateStats()

	local stats = {
		AP = ATW.Stats.AP or 0,
		Crit = ATW.Stats.Crit or 0,
		MainHandSpeed = ATW.Stats.MainHandSpeed or 2.6,
		OffHandSpeed = ATW.Stats.OffHandSpeed or 0,
		HasOffHand = ATW.Stats.HasOffHand or false,
		MHDmg = 100,  -- Estimate, could be calculated from AP/speed
	}

	-- Estimate weapon damage from AP and speed
	-- Average weapon DPS ~= level * 1.5 for good weapons at 60
	-- MH damage = DPS * speed
	local estimatedDPS = 50 + (stats.AP / 14)  -- Rough estimate
	stats.MHDmg = estimatedDPS * stats.MainHandSpeed

	return stats
end

---------------------------------------
-- [LEGACY] Check if ability is usable now
-- DEPRECATED: Engine.GetValidActions() handles this with full state.
---------------------------------------
function ATW.CanUseAbility(abilityName, rage, stance)
	local ability = ATW.Abilities[abilityName]
	if not ability then return false end

	-- Check condition
	if ability.condition and not ability.condition(ATW.State) then
		return false
	end

	-- Check rage
	local cost = ATW.GetRageCost(abilityName)
	if rage < cost then
		return false
	end

	-- Check cooldown
	if not ATW.Ready(ability.name) then
		return false
	end

	-- Check stance (0 = any stance)
	if ability.stance and ability.stance[1] ~= 0 then
		local validStance = false
		for _, s in ipairs(ability.stance) do
			if s == stance then
				validStance = true
				break
			end
		end
		if not validStance then
			-- Find first available stance for this ability
			local targetStance = nil
			for _, s in ipairs(ability.stance) do
				if ATW.AvailableStances[s] then
					targetStance = s
					break
				end
			end

			-- Can't use if no valid stance is available
			if not targetStance then
				return false
			end

			-- Could stance dance, but costs rage
			local danceRage = AutoTurtleWarrior_Config.DanceRage or 10
			if rage < cost + danceRage then
				return false
			end

			-- Check GCD from last stance change
			if ATW.State.LastStance + 1.5 > GetTime() then
				return false
			end

			-- Mark that we need to dance
			return "dance", targetStance
		end
	end

	return true
end

---------------------------------------
-- [LEGACY] Get priority-sorted ability list
-- DEPRECATED: Not used for main decisions.
-- Engine.SimulateDecisionHorizon() provides pure simulation-based decisions.
-- Returns: { {name, dpr, needsDance, targetStance}, ... }
---------------------------------------
function ATW.GetPriorityList()
	local stats = ATW.GetSimStats()
	local rage = UnitMana("player")
	local stance = ATW.Stance()
	local inExecute = ATW.InExecutePhase and ATW.InExecutePhase()
	local enemyCount = ATW.EnemyCount and ATW.EnemyCount() or 1

	-- Check rage pooling
	local shouldPool, poolFor, poolTime = false, nil, 0
	if ATW.ShouldPoolRage then
		shouldPool, poolFor, poolTime = ATW.ShouldPoolRage()
	end

	-- Get rage efficiency score
	local rageEfficiency = 1.0
	if ATW.GetRageEfficiency then
		rageEfficiency = ATW.GetRageEfficiency()
	end

	local priorities = {}

	-- Define ability priority order with conditions
	-- NOTE: Pummel is NOT in this list - it's handled separately via interrupt system
	local abilityOrder = {
		-- Buffs that should be maintained
		"BattleShout",

		-- Charge when out of combat
		"Charge",

		-- Cooldowns (if enabled)
		"DeathWish",
		"Recklessness",

		-- Rage generation
		"Bloodrage",
		"BerserkerRage",

		-- AoE setup
		"SweepingStrikes",

		-- Execute phase
		"Execute",

		-- Core rotation
		"Bloodthirst",
		"MortalStrike",
		"Whirlwind",

		-- Procs
		"Overpower",

		-- DoT (Rend with AP scaling in TurtleWoW)
		"Rend",

		-- Rage dumps
		"Cleave",
		"HeroicStrike",
	}

	for _, abilityName in ipairs(abilityOrder) do
		local ability = ATW.Abilities[abilityName]
		if ability then
			-- Skip cooldowns not allowed by current toggle settings
			local skipCD = ability.isCooldown and not ATW.IsCooldownAllowed(abilityName)
			if skipCD then
				-- Skip this cooldown (disabled by toggle)
			else
				local canUse, targetStance = ATW.CanUseAbility(abilityName, rage, stance)

				if canUse then
					local dpr = ATW.CalculateDPR(abilityName, stats, rage)
					local needsDance = (canUse == "dance")

					-- Adjust DPR for special cases

					-- Execute is massively efficient in execute phase
					if abilityName == "Execute" and inExecute then
						dpr = dpr * 2
					end

					-- Overpower has limited window (4s), boost priority when active
					-- Higher boost if window is about to expire
					if abilityName == "Overpower" and ATW.State.Overpower then
						local windowRemaining = 4 - (GetTime() - ATW.State.Overpower)
						if windowRemaining > 0 then
							if windowRemaining <= 1.5 then
								-- Window about to expire - very high priority
								dpr = dpr * 3
							elseif windowRemaining <= 2.5 then
								-- Window closing soon - high priority
								dpr = dpr * 2
							else
								-- Window open - moderate boost
								dpr = dpr * 1.5
							end
						end
					end

					-- Whirlwind scales with targets
					if abilityName == "Whirlwind" and enemyCount > 1 then
						-- Already calculated in damage function
					end

					-- Cleave only worth it with 2+ targets
					if abilityName == "Cleave" and enemyCount < 2 then
						dpr = 0
					end

					-- Heroic Strike / Cleave - factor in swing timer
					if abilityName == "HeroicStrike" or abilityName == "Cleave" then
						-- Check if we should queue at all
						local shouldQueue, reason = ATW.ShouldQueueSwingAbility()
						if not shouldQueue then
							dpr = 0
						else
							-- Multiply by swing queue priority (0-1 based on timing)
							local swingPriority = ATW.GetSwingQueuePriority()
							dpr = dpr * swingPriority

							-- If swing is imminent and high rage, boost priority
							if swingPriority > 0.7 and rage >= 70 then
								dpr = dpr * 1.5
							end
						end
					end

					-- Off-GCD abilities get priority boost
					if not ability.gcd then
						dpr = dpr + 1000
					end

					-- Buff abilities with no damage get fixed priority
					if ability.damage(stats) == 0 then
						if abilityName == "BattleShout" then
							dpr = 5000  -- Very high, buff is important
						elseif abilityName == "Bloodrage" then
							dpr = 4000  -- High priority for rage gen
						elseif abilityName == "BerserkerRage" then
							dpr = 3500
						elseif abilityName == "DeathWish" then
							dpr = 3000
						elseif abilityName == "Recklessness" then
							dpr = 2500
						elseif abilityName == "SweepingStrikes" and enemyCount >= 2 then
							dpr = 4500
						elseif abilityName == "Charge" then
							dpr = 6000  -- Highest for gap closer
						end
					end

					-- NOTE: Pummel interrupt handled separately via CastingTracker

					-- Apply ability-specific priority modifiers
					if ability.priorityMod then
						local mod = ability.priorityMod
						-- Support function-based priority modifiers
						if type(mod) == "function" then
							mod = mod()
						end
						dpr = dpr * mod
					end

					-- Rage pooling logic: reduce priority of non-essential abilities
					-- when we should be saving rage for an important ability
					if shouldPool and dpr < 5000 then
						-- Don't reduce priority of the ability we're pooling for
						if abilityName ~= poolFor then
							-- Reduce based on rage cost and time until pooled ability
							local cost = ATW.GetRageCost(abilityName)
							if cost > 0 then
								-- Higher cost abilities get penalized more when pooling
								local poolPenalty = 1 - (cost / 100) * (1 - poolTime / 5)
								if poolPenalty < 0.2 then poolPenalty = 0.2 end
								dpr = dpr * poolPenalty
							end
						else
							-- Boost the ability we're waiting for
							dpr = dpr * 1.5
						end
					end

					-- Apply rage efficiency modifier to rage-spending abilities
					if ability.rage and ability.rage > 0 and rageEfficiency < 1.0 then
						-- Low efficiency = we should be more conservative
						dpr = dpr * (0.5 + rageEfficiency * 0.5)
					end

					if dpr > 0 then
						table.insert(priorities, {
							name = abilityName,
							dpr = dpr,
							needsDance = needsDance,
							targetStance = targetStance,
							ability = ability,
							pooling = shouldPool and abilityName == poolFor,
						})
					end
				end
			end
		end
	end

	-- Sort by DPR (highest first)
	table.sort(priorities, function(a, b)
		return a.dpr > b.dpr
	end)

	return priorities
end

---------------------------------------
-- Get next recommended ability
-- Returns: abilityName, isStanceSwitch, targetStance, targetGUID
-- 100% SIMULATION-BASED - Uses Engine.GetRecommendation()
-- NO FALLBACK to legacy priority systems
--
-- Stance switches are now FIRST-CLASS ACTIONS:
-- - isStanceSwitch=true means use CastShapeshiftForm(targetStance)
-- - isStanceSwitch=false means cast the ability normally
---------------------------------------
function ATW.GetNextAbility()
	-- Engine simulation is REQUIRED - no fallback
	if not ATW.Engine or not ATW.Engine.GetRecommendation then
		ATW.Debug("ERROR: Engine.GetRecommendation not available!")
		return nil
	end

	local ok, abilityName, isOffGCD, pooling, timeToExecute, targetGUID, targetStance, isStanceSwitch = pcall(ATW.Engine.GetRecommendation)

	if not ok then
		ATW.Debug("ERROR: Engine.GetRecommendation failed: " .. tostring(abilityName))
		return nil
	end

	if not abilityName then
		-- No ability recommended (waiting/pooling)
		return nil
	end

	-- Debug info about pooling
	if pooling and AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		ATW.Debug("Pooling rage for Execute in " .. string.format("%.1f", timeToExecute or 0) .. "s")
	end

	-- Return action info
	-- isStanceSwitch tells Rotation to use CastShapeshiftForm
	-- isOffGCD tells Rotation to chain the next action after this one
	return abilityName, isStanceSwitch, targetStance, targetGUID, isOffGCD
end

---------------------------------------
-- Simulate N steps ahead with time tracking
-- Returns: { {ability, expectedDamage, rageAfter, timeOffset}, ... }
-- Uses Engine.SimulateAhead for full simulation if available
---------------------------------------
function ATW.SimulateAhead(steps)
	steps = steps or ATW.Sim.LookAhead

	-- Try Engine simulation first (Zebouski-style)
	if ATW.Engine and ATW.Engine.SimulateAhead then
		local ok, results = pcall(ATW.Engine.SimulateAhead, steps, 30)
		if ok and results and table.getn(results) > 0 then
			return results
		end
	end

	-- Fallback: original DPR-based simulation
	local stats = ATW.GetSimStats()
	local simRage = UnitMana("player")
	local simStance = ATW.Stance()
	local simTime = 0
	local simGCD = 0  -- Time until GCD is ready
	local results = {}

	-- Track simulated cooldowns (offset from now)
	local simCooldowns = {}

	-- Get estimated rage per second
	local rps = 0
	if ATW.EstimateRagePerSecond then
		rps = ATW.EstimateRagePerSecond()
	else
		rps = 6  -- Fallback estimate
	end

	-- Get current cooldown states
	for name, ability in pairs(ATW.Abilities) do
		if ability.cd and ability.cd > 0 then
			local spellID = ATW.SpellID and ATW.SpellID(ability.name)
			if spellID then
				local start, duration = GetSpellCooldown(spellID, BOOKTYPE_SPELL)
				if start and start > 0 and duration then
					local remaining = (start + duration) - GetTime()
					if remaining > 0 then
						simCooldowns[name] = remaining
					end
				end
			end
		end
	end

	for i = 1, steps do
		-- Advance time to next GCD if needed
		if simGCD > 0 then
			-- Add rage for time passing
			simRage = simRage + (rps * simGCD)
			if simRage > 100 then simRage = 100 end
			simTime = simTime + simGCD

			-- Reduce all cooldowns
			for name, cd in pairs(simCooldowns) do
				simCooldowns[name] = cd - simGCD
				if simCooldowns[name] <= 0 then
					simCooldowns[name] = nil
				end
			end
			simGCD = 0
		end

		-- Find best ability at this simulated time
		local bestAbility = nil
		local bestDPR = 0
		local bestNeedsDance = false
		local bestTargetStance = nil

		for name, ability in pairs(ATW.Abilities) do
			-- Skip if on cooldown in sim
			if not simCooldowns[name] then
				-- Check basic conditions
				local canUse = true
				local needsDance = false
				local targetStance = nil

				-- Check rage
				local cost = ATW.GetRageCost(name)
				if simRage < cost then
					canUse = false
				end

				-- Check stance
				if canUse and ability.stance and ability.stance[1] ~= 0 then
					local validStance = false
					for _, s in ipairs(ability.stance) do
						if s == simStance then
							validStance = true
							break
						end
					end
					if not validStance then
						-- Need stance dance
						local danceRage = AutoTurtleWarrior_Config.DanceRage or 10
						if simRage >= cost + danceRage then
							needsDance = true
							for _, s in ipairs(ability.stance) do
								if ATW.AvailableStances and ATW.AvailableStances[s] then
									targetStance = s
									break
								end
							end
							if not targetStance then
								canUse = false
							end
						else
							canUse = false
						end
					end
				end

				-- Check condition (simplified for sim)
				if canUse and ability.condition then
					-- Skip complex conditions in simulation
					-- NOTE: Pummel handled separately via Combat/Interrupt.lua, not in simulation
					if name == "Execute" then
						canUse = ATW.InExecutePhase and ATW.InExecutePhase()
					elseif name == "Overpower" then
						canUse = (i == 1 and ATW.State.Overpower)  -- Only first step
					elseif name == "BattleShout" then
						canUse = (i == 1 and not ATW.Buff("player", "Ability_Warrior_BattleShout"))
					elseif name == "Charge" then
						canUse = false  -- Skip in simulation
					elseif name == "SunderArmor" then
						canUse = false  -- Disabled for Fury
					end
				end

				if canUse then
					local dpr = ATW.CalculateDPR(name, stats, simRage)

					-- Apply priority modifiers
					if ability.priorityMod then
						local mod = ability.priorityMod
						if type(mod) == "function" then
							mod = mod()
						end
						dpr = dpr * mod
					end

					if dpr > bestDPR then
						bestDPR = dpr
						bestAbility = ability
						bestNeedsDance = needsDance
						bestTargetStance = targetStance
					end
				end
			end
		end

		if not bestAbility then break end

		-- "Cast" the ability
		local cost = ATW.GetRageCost(bestAbility.name or "")
		local damage = bestAbility.damage(stats, simRage)

		-- Handle stance dance
		if bestNeedsDance then
			simRage = simRage - (AutoTurtleWarrior_Config.DanceRage or 10)
			simStance = bestTargetStance
		end

		-- Spend rage
		simRage = simRage - cost
		if simRage < 0 then simRage = 0 end

		-- Add rage gen
		if bestAbility.rageGen then
			simRage = simRage + bestAbility.rageGen
		end

		-- Set cooldown
		if bestAbility.cd and bestAbility.cd > 0 then
			-- Find ability name
			for name, ab in pairs(ATW.Abilities) do
				if ab == bestAbility then
					simCooldowns[name] = bestAbility.cd
					break
				end
			end
		end

		-- Set GCD if applicable
		if bestAbility.gcd then
			simGCD = 1.5
		end

		-- Find ability name for result (use the key we found during search)
		local abilityName = nil
		for name, ab in pairs(ATW.Abilities) do
			if ab == bestAbility then
				abilityName = name
				break
			end
		end

		-- Skip if we couldn't identify the ability
		if not abilityName then
			break
		end

		table.insert(results, {
			ability = abilityName,
			damage = damage,
			rageAfter = simRage,
			timeOffset = simTime,
			needsDance = bestNeedsDance,
		})
	end

	return results
end

---------------------------------------
-- [LEGACY] Debug: Print priority list (DPR-based)
-- Use /atw decision for simulation-based comparisons
---------------------------------------
function ATW.PrintPriority()
	local priorities = ATW.GetPriorityList()

	ATW.Print("--- Priority List ---")

	-- Show Rend spreading status
	if ATW.ShouldSpreadRend then
		local shouldSpread, targetCount = ATW.ShouldSpreadRend()
		if shouldSpread then
			ATW.Print("|cff00ff00[REND SPREAD: " .. targetCount .. " targets]|r")
		end
	end

	for i, p in ipairs(priorities) do
		if i <= 5 then
			local dance = p.needsDance and " (dance)" or ""
			local pooling = p.pooling and " |cffff9900[POOL]|r" or ""
			ATW.Print(i .. ". " .. p.name .. " - DPR: " .. string.format("%.1f", p.dpr) .. dance .. pooling)
		end
	end
end

---------------------------------------
-- [LEGACY] Debug: Print simulation (uses fallback SimulateAhead)
-- Use /atw decision for Engine simulation results
---------------------------------------
function ATW.PrintSim()
	local sim = ATW.SimulateAhead(5)

	ATW.Print("--- Simulation (5 steps) ---")
	local totalDmg = 0
	local lastTime = 0
	for i, s in ipairs(sim) do
		local timeStr = string.format("+%.1fs", s.timeOffset or 0)
		local danceStr = s.needsDance and " [dance]" or ""
		ATW.Print(i .. ". " .. s.ability .. " " .. timeStr .. " -> " ..
			string.format("%.0f", s.damage) .. " dmg, " ..
			string.format("%.0f", s.rageAfter) .. " rage" .. danceStr)
		totalDmg = totalDmg + s.damage
		lastTime = s.timeOffset or 0
	end
	local dps = totalDmg / (lastTime > 0 and lastTime or 1)
	ATW.Print("Total: " .. string.format("%.0f", totalDmg) .. " damage")
	ATW.Print("Est. DPS: " .. string.format("%.0f", dps))

	-- Show pooling info
	if ATW.ShouldPoolRage then
		local shouldPool, forAbility, waitTime = ATW.ShouldPoolRage()
		if shouldPool then
			ATW.Print("|cffff9900POOLING|r for " .. forAbility .. " in " .. string.format("%.1f", waitTime) .. "s")
		end
	end
end

---------------------------------------
-- Cooldown Toggle System (Priority-based)
-- BurstEnabled = Death Wish + Racials
-- RecklessEnabled = Recklessness
-- Both OFF = Sustain mode
---------------------------------------

-- Cooldown categories
ATW.BURST_COOLDOWNS = {
	DeathWish = true,
	BloodFury = true,
	Berserking = true,
	Perception = true,
}

ATW.RECKLESS_COOLDOWNS = {
	Recklessness = true,
}

---------------------------------------
-- CENTRALIZED COOLDOWN CHECK
-- ALL simulation/decision code MUST use this
---------------------------------------
function ATW.IsCooldownAllowed(cdName)
	local cfg = AutoTurtleWarrior_Config

	-- Check if it's a burst cooldown
	if ATW.BURST_COOLDOWNS[cdName] then
		return cfg.BurstEnabled == true
	end

	-- Special case: Bloodrage in burst mode
	if cdName == "Bloodrage" then
		local burstMode = cfg.BloodrageBurstMode
		if burstMode == nil then burstMode = true end
		if burstMode then
			return cfg.BurstEnabled == true
		end
	end

	-- Check if it's a reckless cooldown
	if ATW.RECKLESS_COOLDOWNS[cdName] then
		return cfg.RecklessEnabled == true
	end

	-- Non-toggle cooldowns (BerserkerRage, etc.) always allowed
	return true
end

---------------------------------------
-- Toggle functions
---------------------------------------
function ATW.SetBurst(enabled)
	AutoTurtleWarrior_Config.BurstEnabled = enabled
	if enabled then
		ATW.Print("Burst: |cff00ff00ON|r (DW + Racials)")
	else
		ATW.Print("Burst: |cffff0000OFF|r")
	end
	-- Invalidate caches
	ATW.InvalidateCooldownCache()
end

function ATW.ToggleBurst()
	ATW.SetBurst(not AutoTurtleWarrior_Config.BurstEnabled)
end

function ATW.SetReckless(enabled)
	AutoTurtleWarrior_Config.RecklessEnabled = enabled
	if enabled then
		ATW.Print("Reckless: |cff00ff00ON|r (Recklessness)")
	else
		ATW.Print("Reckless: |cffff0000OFF|r")
	end
	-- Invalidate caches
	ATW.InvalidateCooldownCache()
end

function ATW.ToggleReckless()
	ATW.SetReckless(not AutoTurtleWarrior_Config.RecklessEnabled)
end

function ATW.SetSustain()
	AutoTurtleWarrior_Config.BurstEnabled = false
	AutoTurtleWarrior_Config.RecklessEnabled = false
	ATW.Print("Sustain mode: |cff888888All CDs OFF|r")
	ATW.InvalidateCooldownCache()
end

---------------------------------------
-- Invalidate caches when mode changes
---------------------------------------
function ATW.InvalidateCooldownCache()
	-- Clear Strategic plan cache
	if ATW.Strategic then
		ATW.Strategic.plan = nil
		ATW.Strategic.lastPlanTime = 0
	end
	-- Clear Engine cache
	if ATW.Engine and ATW.Engine.Cache then
		ATW.Engine.Cache.lastState = nil
		ATW.Engine.Cache.lastResult = nil
	end
end

---------------------------------------
-- Get current mode string for display
---------------------------------------
function ATW.GetCooldownModeString()
	local burst = AutoTurtleWarrior_Config.BurstEnabled
	local reckless = AutoTurtleWarrior_Config.RecklessEnabled

	if burst and reckless then
		return "|cffff0000FULL|r (Burst + Reckless)"
	elseif burst then
		return "|cffff8800BURST|r (DW + Racials)"
	elseif reckless then
		return "|cffff00ffRECKLESS ONLY|r"
	else
		return "|cff888888SUSTAIN|r (No CDs)"
	end
end

---------------------------------------
-- Print current CD status
---------------------------------------
function ATW.PrintCooldownStatus()
	local burst = AutoTurtleWarrior_Config.BurstEnabled
	local reckless = AutoTurtleWarrior_Config.RecklessEnabled

	ATW.Print("=== Cooldown Status ===")
	ATW.Print("Mode: " .. ATW.GetCooldownModeString())
	ATW.Print("  Burst: " .. (burst and "|cff00ff00ON|r" or "|cffff0000OFF|r") .. " (DW, Blood Fury, Berserking, Perception)")
	ATW.Print("  Reckless: " .. (reckless and "|cff00ff00ON|r" or "|cffff0000OFF|r") .. " (Recklessness)")
end

-- Legacy compatibility
function ATW.GetCooldownMode()
	local burst = AutoTurtleWarrior_Config.BurstEnabled
	local reckless = AutoTurtleWarrior_Config.RecklessEnabled
	if burst and reckless then return "reckless"
	elseif burst then return "burst"
	else return "sustain" end
end

function ATW.ToggleCooldowns()
	ATW.PrintCooldownStatus()
end

---------------------------------------
-- Time-Based Simulation with DoT Tracking
-- Simulates combat considering each mob's TTD
-- Returns: totalDamage, sequence of abilities
---------------------------------------
function ATW.SimulateTimeWindow(seconds, strategy)
	strategy = strategy or "normal"  -- "normal", "rend_spread", "no_rend"

	local stats = ATW.GetSimStats()
	local simTime = 0
	local simRage = UnitMana("player") or 0
	local simStance = ATW.Stance()
	local totalDamage = 0
	local sequence = {}

	-- Rage per second estimate (for fallback rage gen)
	local rps = 0
	if ATW.EstimateRagePerSecond then
		rps = ATW.EstimateRagePerSecond()
	else
		rps = 6  -- Fallback estimate
	end

	-- Get enemies for multi-target strategies
	local enemies = {}
	local enemiesWW = {}  -- Enemies in Whirlwind range (8 yards)
	if ATW.GetEnemiesWithTTD then
		enemies = ATW.GetEnemiesWithTTD(5)  -- Melee range for Rend/Cleave (5 yards)
		enemiesWW = ATW.GetEnemiesWithTTD(8)  -- Whirlwind range (8 yards)
	end
	local numEnemies = table.getn(enemies)
	local numEnemiesWW = table.getn(enemiesWW)

	-- Dynamic lookahead based on average TTD of enemies
	-- Use the minimum of: provided seconds, average TTD, or 15s max
	local avgTTD = 0
	local minTTD = 999
	if numEnemies > 0 then
		for _, enemy in ipairs(enemies) do
			avgTTD = avgTTD + enemy.ttd
			if enemy.ttd < minTTD then
				minTTD = enemy.ttd
			end
		end
		avgTTD = avgTTD / numEnemies
	else
		-- Single target from current target
		avgTTD = ATW.GetTargetTTD and ATW.GetTargetTTD() or 30
		minTTD = avgTTD
	end

	-- Lookahead = min(requested, avgTTD, 30s cap)
	seconds = seconds or ATW.Sim.TimeWindow or 30
	seconds = math.min(seconds, avgTTD, 30)  -- 30s simulation window
	if seconds < 3 then seconds = 3 end  -- Minimum 3s simulation

	-- DoT tracking: {target, tickDamage, nextTick, ticksRemaining, targetTTD, appliedAt}
	local activeDoTs = {}

	-- Track simulated enemy deaths (by TTD)
	-- Each enemy "dies" when simTime >= their TTD
	local enemyDeathTimes = {}
	for i, enemy in ipairs(enemies) do
		enemyDeathTimes[i] = enemy.ttd
	end

	-- Cooldown tracking
	local simCooldowns = {}
	for name, ability in pairs(ATW.Abilities) do
		if ability.cd and ability.cd > 0 then
			local spellID = ATW.SpellID and ATW.SpellID(ability.name)
			if spellID then
				local start, duration = GetSpellCooldown(spellID, BOOKTYPE_SPELL)
				if start and start > 0 and duration then
					local remaining = (start + duration) - GetTime()
					if remaining > 0 then
						simCooldowns[name] = remaining
					end
				end
			end
		end
	end

	-- Rend constants (dynamic based on spell rank)
	-- ATW.GetRendTickDamage() includes Improved Rend talent bonus
	local REND_BASE_TICK = ATW.GetRendTickDamage and ATW.GetRendTickDamage() or 21
	local REND_AP_SCALE = 0.05  -- 5% AP per tick (constant)
	local REND_TICK_INTERVAL = 3
	local REND_TOTAL_TICKS = ATW.GetRendTicks and ATW.GetRendTicks() or 7

	-- Auto-attack simulation
	local mhSpeed = stats.MainHandSpeed or 2.6
	local ohSpeed = stats.OffHandSpeed or 0
	local hasOH = stats.HasOffHand or false

	-- Estimate weapon damage from stats
	local mhDmgMin = stats.MHDmg or 100
	local mhDmgMax = mhDmgMin * 1.3  -- Rough estimate
	local ohDmgMin = mhDmgMin * 0.5  -- OH does 50% damage
	local ohDmgMax = mhDmgMax * 0.5

	-- Next swing times
	local nextMHSwing = 0
	local nextOHSwing = hasOH and 0 or 999999

	-- Get current swing timer state if available
	if ATW.GetMHSwingRemaining then
		nextMHSwing = ATW.GetMHSwingRemaining() or 0
	end
	if ATW.GetOHSwingRemaining and hasOH then
		nextOHSwing = ATW.GetOHSwingRemaining() or 0
	end

	-- HS/Cleave queue tracking for simulation
	-- nil = nothing queued, "hs" = Heroic Strike, "cleave" = Cleave
	local simSwingQueued = nil

	-- Rage generation constants
	local RAGE_CONVERSION = 230.6
	local RAGE_HIT_FACTOR = 7.5
	local OH_RAGE_PENALTY = 0.5

	-- Track auto-attack damage separately for debug
	local autoAttackDamage = 0

	-- Strategy: Rend spread first (exclude bleed immune targets)
	local rendTargets = {}
	local rendTargetTTDs = {}  -- Track TTD for each Rend target
	if strategy == "rend_spread" and numEnemies >= 2 then
		for i, enemy in ipairs(enemies) do
			-- Skip bleed immune enemies (6s minimum for 2+ ticks)
			if not enemy.bleedImmune and enemy.ttd >= 6 and table.getn(rendTargets) < 4 then
				table.insert(rendTargets, enemy.guid)
				table.insert(rendTargetTTDs, enemy.ttd)
			end
		end
	end
	local rendIndex = 1

	-- Main simulation loop
	local nextGCD = 0

	while simTime < seconds do
		-- Process DoT ticks (only if target is still alive)
		local dotsToRemove = {}
		for i, dot in ipairs(activeDoTs) do
			-- Check if target died (simTime >= target's TTD)
			local targetDead = (simTime >= dot.targetTTD)

			if not targetDead then
				while dot.nextTick <= simTime and dot.ticksRemaining > 0 do
					-- Only count tick if it happens before target dies
					if dot.nextTick < dot.targetTTD then
						totalDamage = totalDamage + dot.tickDamage
					end
					dot.ticksRemaining = dot.ticksRemaining - 1
					dot.nextTick = dot.nextTick + REND_TICK_INTERVAL
				end
			end

			-- Remove DoT if target dead or no ticks remaining
			if targetDead or dot.ticksRemaining <= 0 then
				table.insert(dotsToRemove, i)
			end
		end
		-- Remove expired DoTs (reverse order)
		for i = table.getn(dotsToRemove), 1, -1 do
			table.remove(activeDoTs, dotsToRemove[i])
		end

		-- Count alive enemies at current simTime
		local aliveEnemies = 0
		for i, enemy in ipairs(enemies) do
			if simTime < enemy.ttd then
				aliveEnemies = aliveEnemies + 1
			end
		end

		-- Process auto-attacks (MH and OH swings)
		-- MH Swing
		if simTime >= nextMHSwing and aliveEnemies > 0 then
			local avgMHDmg = (mhDmgMin + mhDmgMax) / 2

			if simSwingQueued == "hs" then
				-- Heroic Strike replaces white hit
				-- Damage = weapon + 157 + AP bonus (1 target)
				local hsDmg = avgMHDmg + (stats.AP * mhSpeed / 14) + 157
				totalDamage = totalDamage + hsDmg
				autoAttackDamage = autoAttackDamage + hsDmg  -- Count as auto (it's on swing)
				-- No rage generated (HS costs rage instead)
				simSwingQueued = nil

				table.insert(sequence, {
					time = simTime,
					ability = "MH+HS",
					rage = simRage,
				})
			elseif simSwingQueued == "cleave" then
				-- Cleave replaces white hit
				-- Damage = weapon + 50 + AP bonus, hits 2 targets (main + 1 additional)
				local cleaveDmg = avgMHDmg + (stats.AP * mhSpeed / 14) + 50
				-- Cleave hits 2 targets: main target + 1 additional (if available)
				local cleaveTargets = math.min(aliveEnemies, 2)
				cleaveDmg = cleaveDmg * cleaveTargets
				totalDamage = totalDamage + cleaveDmg
				autoAttackDamage = autoAttackDamage + cleaveDmg
				-- No rage generated (Cleave costs rage instead)
				simSwingQueued = nil

				table.insert(sequence, {
					time = simTime,
					ability = "MH+Cleave",
					rage = simRage,
				})
			else
				-- Normal white hit
				totalDamage = totalDamage + avgMHDmg
				autoAttackDamage = autoAttackDamage + avgMHDmg
				-- Generate rage from hit
				local rageFromHit = (avgMHDmg / RAGE_CONVERSION) * RAGE_HIT_FACTOR
				simRage = simRage + rageFromHit
				if simRage > 100 then simRage = 100 end
			end

			nextMHSwing = simTime + mhSpeed
		end

		-- OH Swing
		if hasOH and simTime >= nextOHSwing and aliveEnemies > 0 then
			local avgOHDmg = (ohDmgMin + ohDmgMax) / 2

			-- OH always does white hit (no HS on OH)
			totalDamage = totalDamage + avgOHDmg
			autoAttackDamage = autoAttackDamage + avgOHDmg

			-- Generate rage (50% penalty for OH)
			local rageFromHit = (avgOHDmg / RAGE_CONVERSION) * RAGE_HIT_FACTOR * OH_RAGE_PENALTY
			simRage = simRage + rageFromHit
			if simRage > 100 then simRage = 100 end

			nextOHSwing = simTime + ohSpeed
		end

		-- Wait for GCD if needed
		if simTime < nextGCD then
			local waitTime = nextGCD - simTime
			-- Don't add passive rage here - we're generating it from swings now
			simTime = nextGCD

			-- Reduce cooldowns
			for name, cd in pairs(simCooldowns) do
				simCooldowns[name] = cd - waitTime
				if simCooldowns[name] <= 0 then
					simCooldowns[name] = nil
				end
			end
		end

		-- Choose ability based on strategy
		local chosenAbility = nil
		local abilityName = nil

		-- Strategy: Rend spread - prioritize applying Rend to all targets first
		if strategy == "rend_spread" and rendIndex <= table.getn(rendTargets) then
			-- Check if we can Rend (rage, stance)
			if simRage >= 10 then
				local needDance = (simStance ~= 1 and simStance ~= 2)
				local danceRage = AutoTurtleWarrior_Config.DanceRage or 10

				if needDance and simRage >= 10 + danceRage then
					-- Stance dance to Battle
					simRage = simRage - danceRage
					simStance = 1
				end

				if simStance == 1 or simStance == 2 then
					-- Get the enemy's TTD from our tracked list
					local targetTTD = 30  -- Default
					if rendIndex <= table.getn(rendTargetTTDs) then
						targetTTD = rendTargetTTDs[rendIndex]
					end

					-- Only apply Rend if target will live long enough for at least 2 ticks
					local timeRemaining = targetTTD - simTime
					if timeRemaining >= 6 then
						chosenAbility = ATW.Abilities.Rend
						abilityName = "Rend"

						-- Apply Rend DoT with TTD tracking
						local tickDmg = REND_BASE_TICK + (stats.AP * REND_AP_SCALE)
						table.insert(activeDoTs, {
							target = rendTargets[rendIndex],
							tickDamage = tickDmg,
							nextTick = simTime + REND_TICK_INTERVAL,
							ticksRemaining = REND_TOTAL_TICKS,
							targetTTD = targetTTD,  -- Track when this target dies
							appliedAt = simTime,
						})
						rendIndex = rendIndex + 1
					else
						-- Skip this target, not worth Rending
						rendIndex = rendIndex + 1
					end
				end
			end
		end

		-- Count alive enemies at 8 yards for Whirlwind
		local aliveEnemiesWW = 0
		for i, enemy in ipairs(enemiesWW) do
			if simTime < enemy.ttd then
				aliveEnemiesWW = aliveEnemiesWW + 1
			end
		end

		-- Normal rotation (or fallback if Rend spread not possible)
		if not chosenAbility then
			-- Priority: Rage Gen > BT > WW > Execute > OP > Cleave/HS
			-- Cleave preferred over HS when 2+ targets in melee
			local priorities = {
				-- Rage generation abilities (off-GCD, use when low rage)
				{name = "Bloodrage", rage = 0, stance = {0}, offGCD = true, rageGen = 20, condition = function()
					-- Use when below 50 rage and health is decent
					local hp = ATW.GetHealthPercent and ATW.GetHealthPercent() or 100
					return simRage < 50 and hp >= 50
				end},
				{name = "BerserkerRage", rage = 0, stance = {3}, offGCD = true, condition = function()
					-- Use when in Berserker stance (no rage cost, no GCD)
					return ATW.Talents and ATW.Talents.HasIBR
				end},
				-- Core rotation
				{name = "Bloodthirst", rage = 30, stance = {3}},
				{name = "Whirlwind", rage = 25, stance = {3}, condition = function()
					-- WW worth using at 8 yards with targets
					return aliveEnemiesWW >= 1
				end},
				{name = "Execute", rage = 15, stance = {1, 3}, condition = function()
					return ATW.InExecutePhase and ATW.InExecutePhase()
				end},
				{name = "Overpower", rage = 5, stance = {1}, condition = function()
					return simTime == 0 and ATW.State.Overpower
				end},
				-- Cleave: 2 targets, costs 20 rage, preferred with 2+ enemies
				{name = "Cleave", rage = 20, stance = {0}, condition = function()
					return aliveEnemies >= 2  -- Need 2+ targets in melee (5yd)
				end},
				{name = "HeroicStrike", rage = 15, stance = {0}},
			}

			for _, prio in ipairs(priorities) do
				local ability = ATW.Abilities[prio.name]
				if ability and not simCooldowns[prio.name] then
					-- Check condition
					if prio.condition and not prio.condition() then
						-- Skip
					elseif simRage >= prio.rage then
						-- Check stance
						local validStance = (prio.stance[1] == 0)
						if not validStance then
							for _, s in ipairs(prio.stance) do
								if s == simStance then
									validStance = true
									break
								end
							end
						end

						-- Stance dance if needed
						if not validStance then
							local danceRage = AutoTurtleWarrior_Config.DanceRage or 10
							if simRage >= prio.rage + danceRage then
								simRage = simRage - danceRage
								simStance = prio.stance[1]
								validStance = true
							end
						end

						if validStance then
							chosenAbility = ability
							abilityName = prio.name
							break
						end
					end
				end
			end
		end

		-- Track if we used an off-GCD ability (can use another after)
		local usedOffGCD = false

		-- Execute chosen ability
		if chosenAbility then
			local cost = ATW.GetRageCost(abilityName)
			simRage = simRage - cost

			-- Handle rage generation from abilities
			if chosenAbility.rageGen then
				simRage = simRage + chosenAbility.rageGen
				if simRage > 100 then simRage = 100 end
			end

			-- Check for off-GCD ability from priority (for iteration)
			local isOffGCD = not chosenAbility.gcd

			-- Calculate damage (instant abilities)
			if abilityName ~= "Rend" then
				-- Heroic Strike / Cleave are queued, not instant
				if abilityName == "HeroicStrike" then
					-- Queue HS for next MH swing (damage calculated when swing happens)
					simSwingQueued = "hs"
					-- Don't add damage here - it's added when the swing lands
				elseif abilityName == "Cleave" then
					-- Queue Cleave for next MH swing (damage calculated when swing happens)
					simSwingQueued = "cleave"
					-- Don't add damage here - it's added when the swing lands
				else
					local dmg = chosenAbility.damage(stats, simRage + cost)

					-- Whirlwind hits multiple ALIVE targets (8 yard range, max 4)
					if abilityName == "Whirlwind" then
						local wwTargets = math.min(aliveEnemiesWW, 4)
						if wwTargets < 1 then wwTargets = 1 end
						-- Base damage from Abilities already includes normalization
						-- We just multiply by number of targets hit
						dmg = dmg * wwTargets
					end

					-- Only count damage if there are alive targets
					if aliveEnemies > 0 or numEnemies == 0 then
						totalDamage = totalDamage + dmg
					end
				end
			end

			-- Set cooldown
			if chosenAbility.cd and chosenAbility.cd > 0 then
				simCooldowns[abilityName] = chosenAbility.cd
			end

			-- Advance GCD
			if chosenAbility.gcd then
				nextGCD = simTime + 1.5
			end

			table.insert(sequence, {
				time = simTime,
				ability = abilityName,
				rage = simRage,
			})
		else
			-- No ability available, wait 0.5s
			simTime = simTime + 0.5
			simRage = simRage + (rps * 0.5)
			if simRage > 100 then simRage = 100 end
		end

		-- Small time increment to prevent infinite loop
		if chosenAbility and chosenAbility.gcd then
			simTime = simTime + 1.5
		elseif chosenAbility then
			-- Off-GCD ability - minimal time increment (can chain)
			simTime = simTime + 0.05
			usedOffGCD = true
		end

		-- Safety: prevent infinite loops if stuck
		if not chosenAbility and simTime < seconds then
			simTime = simTime + 0.1
		end
	end

	-- Add remaining DoT damage (only ticks before target dies)
	for _, dot in ipairs(activeDoTs) do
		-- Calculate how many ticks will actually happen before target dies
		local timeUntilDeath = dot.targetTTD - simTime
		if timeUntilDeath > 0 then
			-- How many ticks can fit in remaining time?
			local possibleTicks = math.floor(timeUntilDeath / REND_TICK_INTERVAL)
			local actualTicks = math.min(dot.ticksRemaining, possibleTicks)

			if actualTicks > 0 then
				local remainingDmg = dot.tickDamage * actualTicks
				totalDamage = totalDamage + remainingDmg
			end
		end
	end

	-- Return results including auto-attack breakdown
	return totalDamage, sequence, seconds, autoAttackDamage
end

---------------------------------------
-- Compare strategies to find optimal
-- Returns: bestStrategy, damageGain
---------------------------------------
function ATW.FindOptimalStrategy()
	-- Get enemies info
	local enemies = {}
	if ATW.GetEnemiesWithTTD then
		enemies = ATW.GetEnemiesWithTTD(5)
	end
	local numEnemies = table.getn(enemies)

	-- Only compare if we have multiple targets
	if numEnemies < 2 then
		return "normal", 0
	end

	-- Count targets worth Rending (TTD > 6s for 2+ ticks)
	local worthyTargets = 0
	for _, enemy in ipairs(enemies) do
		if enemy.ttd >= 6 then
			worthyTargets = worthyTargets + 1
		end
	end

	if worthyTargets < 2 then
		return "normal", 0
	end

	-- Simulate both strategies (30s window)
	local normalDmg = ATW.SimulateTimeWindow(30, "normal")
	local rendSpreadDmg = ATW.SimulateTimeWindow(30, "rend_spread")

	local gain = rendSpreadDmg - normalDmg
	local gainPercent = (gain / normalDmg) * 100

	if rendSpreadDmg > normalDmg then
		return "rend_spread", gainPercent
	else
		return "normal", 0
	end
end

---------------------------------------
-- Debug: Print strategy comparison
---------------------------------------
function ATW.PrintStrategyComparison()
	local enemies = {}
	if ATW.GetEnemiesWithTTD then
		enemies = ATW.GetEnemiesWithTTD(5)
	end

	local numEnemies = table.getn(enemies)

	-- Show enemy info
	ATW.Print("--- Strategy Comparison ---")
	ATW.Print("Enemies in melee (5yd): " .. numEnemies)

	-- Count bleed immune
	local bleedImmune = 0
	if numEnemies > 0 then
		ATW.Print("Enemy info:")
		for i, enemy in ipairs(enemies) do
			if i <= 4 then
				local immuneStr = enemy.bleedImmune and " |cffff0000[IMMUNE]|r" or ""
				local typeStr = enemy.creatureType and (" (" .. enemy.creatureType .. ")") or ""
				ATW.Print("  #" .. i .. ": TTD " .. string.format("%.1f", enemy.ttd) .. "s" .. typeStr .. immuneStr)
				if enemy.bleedImmune then
					bleedImmune = bleedImmune + 1
				end
			end
		end
	end

	local normalDmg, normalSeq, normalWindow, normalAuto = ATW.SimulateTimeWindow(30, "normal")
	local rendDmg, rendSeq, rendWindow, rendAuto = ATW.SimulateTimeWindow(30, "rend_spread")

	ATW.Print("")
	ATW.Print("Lookahead: " .. string.format("%.1f", normalWindow) .. "s")
	ATW.Print("Auto-attack dmg: " .. string.format("%.0f", normalAuto) .. " (MH+OH)")
	ATW.Print("")
	ATW.Print("Normal rotation: " .. string.format("%.0f", normalDmg) .. " total")
	ATW.Print("  Abilities: " .. string.format("%.0f", normalDmg - normalAuto))
	ATW.Print("  Auto: " .. string.format("%.0f", normalAuto))

	if numEnemies >= 2 and bleedImmune < numEnemies then
		ATW.Print("")
		ATW.Print("Rend spread: " .. string.format("%.0f", rendDmg) .. " total")
		ATW.Print("  Abilities: " .. string.format("%.0f", rendDmg - rendAuto))
		ATW.Print("  Auto: " .. string.format("%.0f", rendAuto))

		local diff = rendDmg - normalDmg
		local diffPercent = 0
		if normalDmg > 0 then
			diffPercent = (diff / normalDmg) * 100
		end

		ATW.Print("")
		if diff > 0 then
			ATW.Print("|cff00ff00REND SPREAD WINS|r: +" .. string.format("%.1f", diffPercent) .. "%")
		else
			ATW.Print("|cffff0000NORMAL WINS|r: " .. string.format("%.1f", diffPercent) .. "%")
		end
	elseif bleedImmune > 0 then
		ATW.Print("")
		ATW.Print("|cffff9900" .. bleedImmune .. " targets are BLEED IMMUNE|r")
	end

	-- Show sequences (abilities only, not auto-attacks)
	ATW.Print("")
	ATW.Print("Normal sequence:")
	local shown = 0
	for i, s in ipairs(normalSeq) do
		if s.ability ~= "MH+HS" and shown < 6 then
			ATW.Print("  " .. string.format("+%.1fs", s.time) .. " " .. s.ability .. " (" .. string.format("%.0f", s.rage) .. " rage)")
			shown = shown + 1
		end
	end

	if numEnemies >= 2 and bleedImmune < numEnemies then
		ATW.Print("")
		ATW.Print("Rend spread sequence:")
		shown = 0
		for i, s in ipairs(rendSeq) do
			if s.ability ~= "MH+HS" and shown < 6 then
				ATW.Print("  " .. string.format("+%.1fs", s.time) .. " " .. s.ability .. " (" .. string.format("%.0f", s.rage) .. " rage)")
				shown = shown + 1
			end
		end
	end
end
