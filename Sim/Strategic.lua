--[[
	Auto Turtle Warrior - Sim/Strategic
	Long-term strategic planning for cooldown usage and AoE strategies

	Architecture:
	┌─────────────────────────────────────────┐
	│  STRATEGIC LAYER (every 2-5 seconds)   │
	│  - Plans cooldown usage                │
	│  - Compares AoE strategies             │
	│  - Considers full boss TTD             │
	└─────────────────────────────────────────┘
	                    │
	                    ▼
	┌─────────────────────────────────────────┐
	│  TACTICAL LAYER (every 100-200ms)      │
	│  - Decides which ability to use NOW    │
	│  - Short horizon (6-9 seconds)         │
	│  - Respects strategic plan             │
	└─────────────────────────────────────────┘
]]--

ATW.Strategic = {}

local Strategic = ATW.Strategic

---------------------------------------
-- Configuration
---------------------------------------
Strategic.PLAN_INTERVAL = 2000      -- Re-plan every 2 seconds
Strategic.SYNC_WINDOW = 10000       -- Sync cooldowns if within 10s of each other
Strategic.EXECUTE_THRESHOLD = 20    -- Execute phase at 20% HP
Strategic.RECK_SAVE_THRESHOLD = 45000 -- Save Recklessness if execute < 45s away

---------------------------------------
-- State
---------------------------------------
Strategic.plan = nil
Strategic.lastPlanTime = 0
Strategic.lastState = nil

---------------------------------------
-- Cooldown Synergy Groups
-- Cooldowns that should be used together for multiplicative benefit
---------------------------------------
Strategic.SYNERGY_GROUPS = {
	-- Primary burst window: Death Wish + racials
	burst = {
		primary = "DeathWish",      -- +20% damage (multiplicative)
		sync = {
			"BloodFury",            -- +120 AP at 60
			"Berserking",           -- +10-15% haste
			"Perception",           -- +2% crit (TurtleWoW)
		},
	},
	-- Execute burst: Recklessness for 100% crit Executes
	execute = {
		primary = "Recklessness",   -- +100% crit
		-- Don't sync other CDs - they're better used earlier
	},
}

---------------------------------------
-- Cooldown Data (for planning)
---------------------------------------
Strategic.COOLDOWN_DATA = {
	DeathWish = {
		cd = 180000,        -- 3 minutes
		duration = 30000,   -- 30 seconds
		effect = "damage",  -- Type of effect
		value = 1.20,       -- +20% damage multiplier
		priority = 1,       -- High priority
	},
	Recklessness = {
		cd = 1800000,       -- 30 minutes (long CD)
		duration = 15000,   -- 15 seconds
		effect = "crit",
		value = 100,        -- +100% crit
		priority = 2,       -- Save for execute if possible
	},
	BloodFury = {
		cd = 120000,        -- 2 minutes
		duration = 15000,
		effect = "ap",
		value = 120,        -- +120 AP at 60
		priority = 3,
	},
	Berserking = {
		cd = 180000,        -- 3 minutes
		duration = 10000,
		effect = "haste",
		value = 1.10,       -- +10% haste (base)
		priority = 3,
	},
	Perception = {
		cd = 180000,        -- 3 minutes
		duration = 20000,
		effect = "crit",
		value = 2,          -- +2% crit
		priority = 3,
	},
}

---------------------------------------
-- Create Strategic Plan
-- Called every PLAN_INTERVAL
---------------------------------------
function Strategic.CreatePlan(state)
	local plan = {
		cooldowns = {},         -- When to use each cooldown
		aoeStrategy = "auto",   -- "rend_spread", "cleave_pure", "hybrid", "auto"
		phase = "normal",       -- "normal", "pre_execute", "execute"
		timestamp = GetTime(),
	}

	local ttd = state.targetTTD or 60000
	local hpPercent = state.targetHPPercent or 100

	---------------------------------------
	-- Determine current phase
	---------------------------------------
	if hpPercent < Strategic.EXECUTE_THRESHOLD then
		plan.phase = "execute"
	else
		-- Estimate time to execute phase
		local timeToExecute = Strategic.EstimateTimeToExecute(state)
		if timeToExecute and timeToExecute < 15000 then
			plan.phase = "pre_execute"
		else
			plan.phase = "normal"
		end
		plan.timeToExecute = timeToExecute
	end

	---------------------------------------
	-- Plan cooldown usage
	---------------------------------------
	Strategic.PlanCooldowns(state, plan)

	---------------------------------------
	-- Determine AoE strategy
	---------------------------------------
	if state.enemyCount and state.enemyCount > 1 then
		plan.aoeStrategy = Strategic.DetermineAoEStrategy(state)
	end

	return plan
end

---------------------------------------
-- Estimate time until execute phase (<20% HP)
---------------------------------------
function Strategic.EstimateTimeToExecute(state)
	local hpPercent = state.targetHPPercent or 100

	if hpPercent <= Strategic.EXECUTE_THRESHOLD then
		return 0
	end

	-- Use TTD tracking data if available
	if ATW.GetTargetTTD then
		local ttd = ATW.GetTargetTTD()
		if ttd and ttd > 0 then
			-- TTD is time to 0%, we want time to 20%
			-- Assuming linear damage: time_to_20 = ttd * (hp - 20) / hp
			local timeToExecute = ttd * (hpPercent - Strategic.EXECUTE_THRESHOLD) / hpPercent
			return timeToExecute * 1000  -- Convert to ms
		end
	end

	-- Fallback: estimate based on rough DPS
	-- This is less accurate but better than nothing
	return nil
end

---------------------------------------
-- Plan when to use each cooldown
-- IMPORTANT: Only plan cooldowns the player actually HAS
-- IMPORTANT: Uses ATW.IsCooldownAllowed() for toggle checks
---------------------------------------
function Strategic.PlanCooldowns(state, plan)
	local ttd = state.targetTTD or 60000
	local timeToExecute = plan.timeToExecute

	---------------------------------------
	-- Helper: Check if player has a spell/talent
	-- Uses cached ATW.Has table (updated on load/level/talent change)
	---------------------------------------
	local function hasAbility(name)
		if not ATW.Has then return false end
		return ATW.Has[name] or false
	end

	---------------------------------------
	-- Helper: Check if cooldown is allowed by toggles
	-- Uses centralized ATW.IsCooldownAllowed()
	---------------------------------------
	local function cdAllowed(cdName)
		return ATW.IsCooldownAllowed and ATW.IsCooldownAllowed(cdName) or false
	end

	---------------------------------------
	-- RECKLESSNESS - Special handling (controlled by Reckless toggle)
	-- 100% crit is MASSIVE for Execute spam
	-- Requires Berserker Stance (learned at level 30)
	---------------------------------------
	local reckCD = state.cooldowns and state.cooldowns.Recklessness or 999999

	if cdAllowed("Recklessness") and hasAbility("Recklessness") and reckCD <= 0 then
		-- Recklessness is ready
		if plan.phase == "execute" then
			-- In execute phase - USE NOW
			plan.cooldowns.Recklessness = {
				action = "use_now",
				reason = "Execute phase - 100% crit Executes",
				priority = 100,  -- Maximum priority
			}
		elseif timeToExecute and timeToExecute < Strategic.RECK_SAVE_THRESHOLD then
			-- Execute coming soon - SAVE IT
			plan.cooldowns.Recklessness = {
				action = "save",
				reason = "Execute phase in " .. string.format("%.0f", timeToExecute/1000) .. "s",
				useAt = "execute_phase",
			}
		elseif ttd < 20000 then
			-- Boss dying soon, won't reach execute - USE NOW
			plan.cooldowns.Recklessness = {
				action = "use_now",
				reason = "Boss dying soon, maximize damage",
				priority = 90,
			}
		else
			-- Far from execute, long fight - consider using for uptime
			-- But Recklessness has 30min CD, usually save it
			plan.cooldowns.Recklessness = {
				action = "save",
				reason = "Long CD, saving for execute phase",
				useAt = "execute_phase",
			}
		end
	end

	---------------------------------------
	-- DEATH WISH - Primary damage CD (Fury Talent)
	-- Short CD (3min), controlled by Burst toggle
	---------------------------------------
	if cdAllowed("DeathWish") and hasAbility("DeathWish") then
		local dwCD = state.cooldowns and state.cooldowns.DeathWish or 999999

		if dwCD <= 0 then
			-- Check if we should sync with racials
			local syncWith = Strategic.FindSyncPartners(state, "DeathWish")

			if table.getn(syncWith) > 0 then
				plan.cooldowns.DeathWish = {
					action = "use_now",
					reason = "Sync with " .. table.concat(syncWith, ", "),
					priority = 80,
					syncWith = syncWith,
				}
			else
				-- No sync partners ready, but DW is short CD - use anyway
				plan.cooldowns.DeathWish = {
					action = "use_now",
					reason = "+20% damage, maximize uptime",
					priority = 70,
				}
			end
		end
	end

	---------------------------------------
	-- Get Death Wish CD for sync decisions (even if player doesn't have it)
	---------------------------------------
	local hasDW = hasAbility("DeathWish")
	local dwCD = hasDW and (state.cooldowns and state.cooldowns.DeathWish or 999999) or 999999

	---------------------------------------
	-- BLOOD FURY (Orc) - Sync with Death Wish, controlled by Burst toggle
	---------------------------------------
	if cdAllowed("BloodFury") and hasAbility("BloodFury") then
		local bfCD = state.cooldowns and state.cooldowns.BloodFury or 999999

		if bfCD <= 0 then
			if hasDW and dwCD <= 0 then
				-- Death Wish also ready - sync them
				plan.cooldowns.BloodFury = {
					action = "use_now",
					reason = "Sync with Death Wish",
					priority = 75,
				}
			elseif hasDW and dwCD < Strategic.SYNC_WINDOW then
				-- DW coming soon - wait for sync
				plan.cooldowns.BloodFury = {
					action = "wait",
					waitFor = "DeathWish",
					waitTime = dwCD,
					reason = "Wait " .. string.format("%.1f", dwCD/1000) .. "s for Death Wish sync",
				}
			else
				-- No DW or DW too far away, use Blood Fury alone
				plan.cooldowns.BloodFury = {
					action = "use_now",
					reason = "+120 AP for 15s",
					priority = 60,
				}
			end
		end
	end

	---------------------------------------
	-- BERSERKING (Troll) - Similar to Blood Fury, controlled by Burst toggle
	---------------------------------------
	if cdAllowed("Berserking") and hasAbility("Berserking") then
		local berserkCD = state.cooldowns and state.cooldowns.Berserking or 999999

		if berserkCD <= 0 then
			if hasDW and dwCD <= 0 then
				plan.cooldowns.Berserking = {
					action = "use_now",
					reason = "Sync with Death Wish",
					priority = 75,
				}
			elseif hasDW and dwCD < Strategic.SYNC_WINDOW then
				plan.cooldowns.Berserking = {
					action = "wait",
					waitFor = "DeathWish",
					waitTime = dwCD,
					reason = "Wait for Death Wish sync",
				}
			else
				plan.cooldowns.Berserking = {
					action = "use_now",
					reason = "+10-15% haste",
					priority = 60,
				}
			end
		end
	end

	---------------------------------------
	-- PERCEPTION (Human) - Use on cooldown, controlled by Burst toggle
	---------------------------------------
	if cdAllowed("Perception") and hasAbility("Perception") then
		local percCD = state.cooldowns and state.cooldowns.Perception or 999999

		if percCD <= 0 then
			-- Perception is passive crit, no need to sync
			plan.cooldowns.Perception = {
				action = "use_now",
				reason = "+2% crit",
				priority = 50,
			}
		end
	end
end

---------------------------------------
-- Find cooldowns that can sync together
-- Uses cached ATW.Has table and respects toggle settings
---------------------------------------
function Strategic.FindSyncPartners(state, cdName)
	local partners = {}

	if not ATW.Has then return partners end

	-- Helper to check if CD is allowed
	local function cdAllowed(name)
		return ATW.IsCooldownAllowed and ATW.IsCooldownAllowed(name) or false
	end

	-- Check racial cooldowns (only if allowed by Burst toggle)
	local racialCDs = {"BloodFury", "Berserking", "Perception"}

	for _, racial in ipairs(racialCDs) do
		if racial ~= cdName and cdAllowed(racial) then
			local cd = state.cooldowns and state.cooldowns[racial] or 999999
			-- Has the racial AND it's ready AND it's allowed
			if ATW.Has[racial] and cd <= 0 then
				table.insert(partners, racial)
			end
		end
	end

	-- Check Death Wish if we're looking at a racial (only if allowed)
	if cdName ~= "DeathWish" and cdAllowed("DeathWish") then
		local dwCD = state.cooldowns and state.cooldowns.DeathWish or 999999
		if ATW.Has.DeathWish and dwCD <= 0 then
			table.insert(partners, "DeathWish")
		end
	end

	return partners
end

---------------------------------------
-- Determine best AoE strategy
-- Compare: Rend spreading vs Cleave/WW pure
---------------------------------------
function Strategic.DetermineAoEStrategy(state)
	local enemyCount = state.enemyCount or 1
	if enemyCount <= 1 then
		return "single_target"
	end

	-- Get enemy data
	local enemies = state.enemies or {}
	local rendableCount = 0
	local avgTTD = 0
	local totalTTD = 0

	for _, enemy in ipairs(enemies) do
		if not enemy.bleedImmune and not enemy.inExecute then
			if enemy.ttd and enemy.ttd >= 9000 then  -- At least 3 ticks worth
				rendableCount = rendableCount + 1
				totalTTD = totalTTD + enemy.ttd
			end
		end
	end

	if rendableCount > 0 then
		avgTTD = totalTTD / rendableCount
	end

	---------------------------------------
	-- Strategy decision based on math
	---------------------------------------
	-- Rend (TurtleWoW): ~147 base + (AP * 0.05 * 7 ticks) = ~147 + 350 = ~500 damage
	-- Costs: 10 rage + 1 GCD per target
	--
	-- Cleave: ~200 weapon + 50 bonus = ~250 * 2 targets = ~500 damage
	-- Costs: 20 rage (no GCD, on next swing)
	--
	-- Whirlwind: ~200 weapon * 4 targets = ~800 damage
	-- Costs: 25 rage + 1 GCD
	---------------------------------------

	local ap = state.ap or 1000
	local rendDamagePerTarget = (ATW.GetRendDamage and ATW.GetRendDamage() or 147) + (ap * 0.05 * 7)
	local weaponDmg = ((state.mhDmgMin or 100) + (state.mhDmgMax or 200)) / 2
	local cleaveDamage = (weaponDmg + 50) * math.min(enemyCount, 2)
	local wwDamage = weaponDmg * math.min(enemyCount, 4)

	-- Calculate total Rend value
	local totalRendValue = 0
	local gcdsNeeded = 0

	for _, enemy in ipairs(enemies) do
		if not enemy.bleedImmune and not enemy.inExecute and not enemy.hasRend then
			if enemy.ttd and enemy.ttd >= 9000 then
				-- Calculate actual ticks based on TTD
				local ticks = math.min(7, math.floor(enemy.ttd / 3000))
				local rendValue = (ATW.GetRendTickDamage and ATW.GetRendTickDamage() or 21) + (ap * 0.05)
				totalRendValue = totalRendValue + (rendValue * ticks)
				gcdsNeeded = gcdsNeeded + 1
			end
		end
	end

	-- Compare strategies over 15 seconds (10 GCDs)
	local horizonGCDs = 10

	-- Strategy A: Rend spread then Cleave/WW
	local rendSpreadDamage = totalRendValue
	local remainingGCDs = horizonGCDs - gcdsNeeded
	if remainingGCDs > 0 then
		-- Fill with WW and BT
		local wwCasts = math.floor(remainingGCDs * 0.3)  -- WW every ~3 GCDs
		local btCasts = remainingGCDs - wwCasts
		rendSpreadDamage = rendSpreadDamage + (wwCasts * wwDamage) + (btCasts * (200 + ap * 0.35))
	end

	-- Strategy B: Pure Cleave/WW (ignore Rend)
	local pureAoEDamage = 0
	local wwCasts = math.floor(horizonGCDs * 0.3)
	local btCasts = horizonGCDs - wwCasts
	pureAoEDamage = (wwCasts * wwDamage) + (btCasts * (200 + ap * 0.35))
	-- Add Cleave value (off-GCD)
	pureAoEDamage = pureAoEDamage + (cleaveDamage * 5)  -- ~5 Cleaves in 15s

	-- Compare
	local rendAdvantage = (rendSpreadDamage - pureAoEDamage) / pureAoEDamage * 100

	if rendAdvantage > 5 then
		return "rend_spread"
	elseif rendAdvantage < -5 then
		return "cleave_pure"
	else
		-- Close call - use hybrid (Rend on high TTD targets only)
		return "hybrid"
	end
end

---------------------------------------
-- Get current strategic plan
-- Creates new plan if needed
---------------------------------------
function Strategic.GetPlan(state)
	local now = GetTime() * 1000

	-- Check if we need a new plan
	local needNewPlan = false

	if not Strategic.plan then
		needNewPlan = true
	elseif now - Strategic.lastPlanTime > Strategic.PLAN_INTERVAL then
		needNewPlan = true
	elseif Strategic.StateChangedSignificantly(Strategic.lastState, state) then
		needNewPlan = true
	end

	if needNewPlan then
		Strategic.plan = Strategic.CreatePlan(state)
		Strategic.lastPlanTime = now
		Strategic.lastState = state
	end

	return Strategic.plan
end

---------------------------------------
-- Check if state changed enough to re-plan
---------------------------------------
function Strategic.StateChangedSignificantly(oldState, newState)
	if not oldState then return true end

	-- Phase change (entered execute)
	local oldInExecute = oldState.targetHPPercent and oldState.targetHPPercent < 20
	local newInExecute = newState.targetHPPercent and newState.targetHPPercent < 20
	if oldInExecute ~= newInExecute then
		return true
	end

	-- Major cooldown became ready
	local majorCDs = {"DeathWish", "Recklessness", "BloodFury", "Berserking"}
	for _, cd in ipairs(majorCDs) do
		local oldCD = oldState.cooldowns and oldState.cooldowns[cd] or 999999
		local newCD = newState.cooldowns and newState.cooldowns[cd] or 999999
		if oldCD > 0 and newCD <= 0 then
			return true  -- CD just came off cooldown
		end
	end

	-- Enemy count changed significantly
	local oldCount = oldState.enemyCount or 1
	local newCount = newState.enemyCount or 1
	if math.abs(oldCount - newCount) >= 2 then
		return true
	end

	return false
end

---------------------------------------
-- Check if strategic plan says to use a cooldown now
-- Returns: cdName, priority (or nil if nothing to use)
---------------------------------------
function Strategic.GetPriorityCooldown(state)
	local plan = Strategic.GetPlan(state)
	if not plan or not plan.cooldowns then
		return nil, 0
	end

	local bestCD = nil
	local bestPriority = 0

	for cdName, cdPlan in pairs(plan.cooldowns) do
		if cdPlan.action == "use_now" and cdPlan.priority then
			if cdPlan.priority > bestPriority then
				bestCD = cdName
				bestPriority = cdPlan.priority
			end
		end
	end

	return bestCD, bestPriority
end

---------------------------------------
-- Check if we should wait for sync
-- Returns: shouldWait, waitFor, waitTime
---------------------------------------
function Strategic.ShouldWaitForSync(state, cdName)
	local plan = Strategic.GetPlan(state)
	if not plan or not plan.cooldowns then
		return false, nil, 0
	end

	local cdPlan = plan.cooldowns[cdName]
	if cdPlan and cdPlan.action == "wait" then
		return true, cdPlan.waitFor, cdPlan.waitTime
	end

	return false, nil, 0
end

---------------------------------------
-- Get current AoE strategy from plan
---------------------------------------
function Strategic.GetAoEStrategy(state)
	local plan = Strategic.GetPlan(state)
	return plan and plan.aoeStrategy or "auto"
end

---------------------------------------
-- Debug: Print current strategic plan
---------------------------------------
function Strategic.PrintPlan()
	local state = nil
	if ATW.Engine and ATW.Engine.CaptureCurrentState then
		state = ATW.Engine.CaptureCurrentState()
	end

	if not state then
		ATW.Print("Cannot capture state for strategic plan")
		return
	end

	local plan = Strategic.GetPlan(state)

	ATW.Print("=== Strategic Plan ===")

	-- Show cooldown toggle status
	if ATW.GetCooldownModeString then
		ATW.Print("CD Mode: " .. ATW.GetCooldownModeString())
	end

	ATW.Print("Phase: " .. (plan.phase or "unknown"))
	if plan.timeToExecute then
		ATW.Print("Time to Execute: " .. string.format("%.1f", plan.timeToExecute/1000) .. "s")
	end
	ATW.Print("AoE Strategy: " .. (plan.aoeStrategy or "N/A"))

	ATW.Print("")
	ATW.Print("Cooldown Plan:")
	for cdName, cdPlan in pairs(plan.cooldowns) do
		local actionStr = cdPlan.action or "?"
		local reasonStr = cdPlan.reason or ""
		if cdPlan.priority then
			actionStr = actionStr .. " (P" .. cdPlan.priority .. ")"
		end
		ATW.Print("  " .. cdName .. ": " .. actionStr)
		if reasonStr ~= "" then
			ATW.Print("    -> " .. reasonStr)
		end
	end
end
