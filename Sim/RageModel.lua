--[[
	Auto Turtle Warrior - Sim/RageModel
	Rage generation and economy modeling
]]--

ATW.Rage = {
	-- Rage generation constants (level 60)
	CONVERSION_FACTOR = 230.6,  -- Damage to rage conversion
	HIT_FACTOR = 7.5,           -- Rage per hit factor
	TAKEN_FACTOR = 2.5,         -- Rage when taking damage
	OH_PENALTY = 0.5,           -- Off-hand generates 50% rage

	-- Unbridled Wrath
	UW_RAGE = 1,                -- Rage per proc
	UW_CHANCE = 0,              -- Set by talents (0-75%)

	-- Tracking
	lastRage = 0,
	ragePerSecond = 0,          -- Estimated rage/s in current fight
	sampleStart = 0,
	sampleRage = 0,
}

---------------------------------------
-- Initialize rage model from talents
---------------------------------------
function ATW.InitRageModel()
	-- Unbridled Wrath: 15/30/45/60/75% chance
	local _, _, _, _, points = GetTalentInfo(2, 3)  -- Fury tree, row 3
	ATW.Rage.UW_CHANCE = (points or 0) * 15
end

---------------------------------------
-- Estimate rage generated per MH swing
---------------------------------------
function ATW.EstimateMHRageGen()
	local stats = ATW.Stats
	local ap = stats.AP or 0
	local speed = stats.MainHandSpeed or 2.6

	-- Estimate MH damage: (WeaponDPS + AP/14) * speed
	local weaponDPS = 50 + (ap / 14)  -- Rough estimate
	local avgDamage = weaponDPS * speed

	-- Base rage from hit
	local baseRage = (avgDamage / ATW.Rage.CONVERSION_FACTOR) * ATW.Rage.HIT_FACTOR

	-- Add Unbridled Wrath average
	local uwRage = ATW.Rage.UW_RAGE * (ATW.Rage.UW_CHANCE / 100)

	return baseRage + uwRage
end

---------------------------------------
-- Estimate rage generated per OH swing
---------------------------------------
function ATW.EstimateOHRageGen()
	local stats = ATW.Stats
	if not stats.HasOffHand then return 0 end

	local ap = stats.AP or 0
	local speed = stats.OffHandSpeed or 2.6

	-- OH does 50% damage
	local weaponDPS = (50 + (ap / 14)) * 0.5
	local avgDamage = weaponDPS * speed

	-- Base rage (also 50% for OH)
	local baseRage = (avgDamage / ATW.Rage.CONVERSION_FACTOR) * ATW.Rage.HIT_FACTOR * ATW.Rage.OH_PENALTY

	-- Unbridled Wrath also procs on OH
	local uwRage = ATW.Rage.UW_RAGE * (ATW.Rage.UW_CHANCE / 100)

	return baseRage + uwRage
end

---------------------------------------
-- Estimate rage per second in combat
---------------------------------------
function ATW.EstimateRagePerSecond()
	local stats = ATW.Stats
	local mhSpeed = stats.MainHandSpeed or 2.6
	local ohSpeed = stats.OffHandSpeed or 0

	-- Rage from MH swings
	local mhRagePerSwing = ATW.EstimateMHRageGen()
	local mhRPS = mhRagePerSwing / mhSpeed

	-- Rage from OH swings
	local ohRPS = 0
	if stats.HasOffHand and ohSpeed > 0 then
		local ohRagePerSwing = ATW.EstimateOHRageGen()
		ohRPS = ohRagePerSwing / ohSpeed
	end

	-- Bloodrage: 20 rage per 60s = 0.33 rps average
	local bloodrageRPS = 0.33

	return mhRPS + ohRPS + bloodrageRPS
end

---------------------------------------
-- Predict rage at future time
-- timeAhead: seconds in the future
-- spentRage: rage we plan to spend
---------------------------------------
function ATW.PredictRage(timeAhead, spentRage)
	local currentRage = UnitMana("player")
	local rps = ATW.EstimateRagePerSecond()

	local futureRage = currentRage + (rps * timeAhead) - (spentRage or 0)

	-- Cap at 100
	if futureRage > 100 then futureRage = 100 end
	if futureRage < 0 then futureRage = 0 end

	return futureRage
end

---------------------------------------
-- Check if we can afford ability at time T
---------------------------------------
function ATW.CanAffordAt(abilityName, timeAhead)
	local cost = ATW.GetRageCost(abilityName)
	local predictedRage = ATW.PredictRage(timeAhead, 0)
	return predictedRage >= cost
end

---------------------------------------
-- Should we pool rage for an upcoming ability?
-- Returns: true if we should wait, ability name to wait for
---------------------------------------
function ATW.ShouldPoolRage()
	local rage = UnitMana("player")
	local talents = ATW.Talents

	-- Check Bloodthirst CD
	if talents.HasBT then
		local btID = ATW.SpellID("Bloodthirst")
		if btID then
			local start, duration = GetSpellCooldown(btID, BOOKTYPE_SPELL)
			if start and start > 0 and duration then
				local remaining = (start + duration) - GetTime()
				if remaining > 0 and remaining <= 3 then
					-- BT coming off CD in 3s or less
					local predictedRage = ATW.PredictRage(remaining, 0)
					if predictedRage < 30 then
						-- Won't have enough rage, pool now
						return true, "Bloodthirst", remaining
					end
				end
			end
		end
	end

	-- Check Execute phase approaching
	if ATW.WillReachExecute and ATW.WillReachExecute(5) then
		local execCost = talents.ExecCost or 15
		if rage < 50 then
			-- Pool rage for Execute spam
			return true, "Execute", 5
		end
	end

	-- Check Whirlwind CD
	local wwID = ATW.SpellID("Whirlwind")
	if wwID then
		local start, duration = GetSpellCooldown(wwID, BOOKTYPE_SPELL)
		if start and start > 0 and duration then
			local remaining = (start + duration) - GetTime()
			if remaining > 0 and remaining <= 2 then
				local predictedRage = ATW.PredictRage(remaining, 0)
				if predictedRage < 25 then
					return true, "Whirlwind", remaining
				end
			end
		end
	end

	return false, nil, 0
end

---------------------------------------
-- Calculate rage efficiency score
-- Higher = better time to spend rage
---------------------------------------
function ATW.GetRageEfficiency()
	local rage = UnitMana("player")
	local shouldPool, forAbility, waitTime = ATW.ShouldPoolRage()

	-- If we should pool, low efficiency
	if shouldPool then
		return 0.2, forAbility, waitTime
	end

	-- High rage = high efficiency (need to dump)
	if rage >= 80 then
		return 1.0, nil, 0
	end

	-- Medium rage with main abilities on CD = medium efficiency
	if rage >= 50 then
		return 0.7, nil, 0
	end

	-- Low rage = save it
	return 0.4, nil, 0
end

---------------------------------------
-- Debug: Print rage model info
---------------------------------------
function ATW.PrintRageModel()
	ATW.InitRageModel()

	local mhRage = ATW.EstimateMHRageGen()
	local ohRage = ATW.EstimateOHRageGen()
	local rps = ATW.EstimateRagePerSecond()
	local efficiency, poolFor, waitTime = ATW.GetRageEfficiency()
	local shouldPool, ability, time = ATW.ShouldPoolRage()

	ATW.Print("--- Rage Model ---")
	ATW.Print("MH swing: " .. string.format("%.1f", mhRage) .. " rage")
	if ATW.Stats.HasOffHand then
		ATW.Print("OH swing: " .. string.format("%.1f", ohRage) .. " rage")
	end
	ATW.Print("Est. RPS: " .. string.format("%.1f", rps) .. " rage/sec")
	ATW.Print("UW chance: " .. ATW.Rage.UW_CHANCE .. "%")

	ATW.Print("Efficiency: " .. string.format("%.1f", efficiency * 100) .. "%")
	if shouldPool then
		ATW.Print("POOLING for " .. ability .. " in " .. string.format("%.1f", time) .. "s")
	end

	-- Predict 5s ahead
	local future = ATW.PredictRage(5, 0)
	ATW.Print("Rage in 5s: " .. string.format("%.0f", future))
end
