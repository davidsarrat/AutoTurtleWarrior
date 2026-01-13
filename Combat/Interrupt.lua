--[[
	Auto Turtle Warrior - Combat/Interrupt
	Enemy cast detection and auto-interrupt system using SuperWoW UNIT_CASTEVENT

	DETECTION METHODS:
	==================
	1. UNIT_CASTEVENT (SuperWoW) - Primary method
	   - eventType "START" = spell cast started
	   - eventType "CHANNEL" = channeled spell started
	   - eventType "CAST" = cast completed (stop tracking)
	   - eventType "FAIL" = cast interrupted/failed (stop tracking)

	2. Combat Log (Fallback)
	   - "X begins to cast Y" pattern
	   - Less reliable, only works for current target
]]--

---------------------------------------
-- Casting Tracker
-- Tracks enemy casts for interrupt decisions
---------------------------------------
ATW.CastingTracker = {
	-- Active casts: {[casterGUID] = {spellID, spellName, startTime, duration, endTime}}
	casts = {},

	-- Configuration
	CAST_TIMEOUT = 10,          -- Max cast time to track (cleanup stale entries)
	INTERRUPT_RANGE = 5,        -- Pummel range (melee)
}

---------------------------------------
-- Record enemy cast start
---------------------------------------
function ATW.CastingTracker.OnCastStart(casterGUID, spellID, duration)
	if not casterGUID then return end

	local now = GetTime()

	-- Get spell name
	local spellName = nil
	if spellID and SpellInfo then
		local ok, name = pcall(function() return SpellInfo(spellID) end)
		if ok then spellName = name end
	end

	-- Get caster name
	local casterName = nil
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, name = pcall(function() return UnitName(casterGUID) end)
		if ok then casterName = name end
	end

	-- Calculate end time
	local castDuration = (duration and duration > 0) and (duration / 1000) or 3
	local endTime = now + castDuration

	ATW.CastingTracker.casts[casterGUID] = {
		spellID = spellID,
		spellName = spellName,
		casterName = casterName,
		startTime = now,
		duration = castDuration,
		endTime = endTime,
	}

	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		ATW.Debug("Cast START: " .. (casterName or "?") .. " -> " .. (spellName or "spell#" .. (spellID or "?")) .. " (" .. string.format("%.1f", castDuration) .. "s)")
	end
end

---------------------------------------
-- Record enemy cast end (completed, failed, interrupted)
---------------------------------------
function ATW.CastingTracker.OnCastEnd(casterGUID)
	if not casterGUID then return end

	local cast = ATW.CastingTracker.casts[casterGUID]
	if cast then
		if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
			ATW.Debug("Cast END: " .. (cast.casterName or "?"))
		end
		ATW.CastingTracker.casts[casterGUID] = nil
	end
end

---------------------------------------
-- Check if a GUID is currently casting
---------------------------------------
function ATW.CastingTracker.IsCasting(guid)
	if not guid then return false end

	local cast = ATW.CastingTracker.casts[guid]
	if not cast then return false end

	-- Check if cast has expired
	local now = GetTime()
	if now >= cast.endTime then
		ATW.CastingTracker.casts[guid] = nil
		return false
	end

	return true
end

---------------------------------------
-- Get cast info for a GUID
-- Returns: spellName, remainingTime, casterName (or nil)
---------------------------------------
function ATW.CastingTracker.GetCastInfo(guid)
	if not guid then return nil end

	local cast = ATW.CastingTracker.casts[guid]
	if not cast then return nil end

	local now = GetTime()
	if now >= cast.endTime then
		ATW.CastingTracker.casts[guid] = nil
		return nil
	end

	local remaining = cast.endTime - now
	return cast.spellName, remaining, cast.casterName
end

---------------------------------------
-- Cleanup expired casts
---------------------------------------
function ATW.CastingTracker.Cleanup()
	local now = GetTime()

	for guid, cast in pairs(ATW.CastingTracker.casts) do
		if now >= cast.endTime or (now - cast.startTime) > ATW.CastingTracker.CAST_TIMEOUT then
			ATW.CastingTracker.casts[guid] = nil
		end
	end
end

---------------------------------------
-- Reset all tracking
---------------------------------------
function ATW.CastingTracker.Reset()
	ATW.CastingTracker.casts = {}
end

---------------------------------------
-- Find best interrupt target
-- Returns: guid, spellName, remainingTime, distance (or nil)
-- Prioritizes: closest enemy in melee range that's casting
---------------------------------------
function ATW.GetInterruptTarget()
	-- Check if Pummel is enabled
	if not AutoTurtleWarrior_Config.PummelEnabled then
		return nil
	end

	-- Cleanup expired entries first
	ATW.CastingTracker.Cleanup()

	local bestTarget = nil
	local bestDistance = 999
	local bestSpell = nil
	local bestRemaining = 0

	-- Check current target first (priority)
	if UnitExists("target") and UnitCanAttack("player", "target") then
		local targetGUID = nil
		if ATW.HasSuperWoW and ATW.HasSuperWoW() then
			local ok, _, guid = pcall(function() return UnitExists("target") end)
			if ok then targetGUID = guid end
		end

		if targetGUID and ATW.CastingTracker.IsCasting(targetGUID) then
			local dist = ATW.GetDistance and ATW.GetDistance("target") or 0
			if dist <= ATW.CastingTracker.INTERRUPT_RANGE then
				local spellName, remaining = ATW.CastingTracker.GetCastInfo(targetGUID)
				return targetGUID, spellName, remaining, dist
			end
		end
	end

	-- Check all tracked casters
	for guid, cast in pairs(ATW.CastingTracker.casts) do
		-- Check if in range and attackable
		local dist = ATW.GetDistance and ATW.GetDistance(guid)

		if dist and dist <= ATW.CastingTracker.INTERRUPT_RANGE then
			-- Verify it's attackable
			local canAttack = false
			if ATW.HasSuperWoW and ATW.HasSuperWoW() then
				local ok, result = pcall(function() return UnitCanAttack("player", guid) end)
				if ok then canAttack = (result == 1) end
			end

			if canAttack then
				local spellName, remaining = ATW.CastingTracker.GetCastInfo(guid)
				if remaining and remaining > 0 then
					-- Prioritize closest
					if dist < bestDistance then
						bestTarget = guid
						bestDistance = dist
						bestSpell = spellName
						bestRemaining = remaining
					end
				end
			end
		end
	end

	if bestTarget then
		return bestTarget, bestSpell, bestRemaining, bestDistance
	end

	return nil
end

---------------------------------------
-- Check if we should interrupt now
-- Returns: shouldInterrupt, targetGUID, spellName
---------------------------------------
function ATW.ShouldInterrupt()
	-- Check if enabled
	if not AutoTurtleWarrior_Config.PummelEnabled then
		return false, nil, nil
	end

	-- Check if we have Pummel
	if not (ATW.Has and ATW.Has.Pummel) then
		return false, nil, nil
	end

	-- Check if Pummel is ready
	local pummelCD = ATW.GetCooldownRemaining and ATW.GetCooldownRemaining("Pummel") or 0
	if pummelCD > 0 then
		return false, nil, nil
	end

	-- Check rage (Pummel costs 10)
	local rage = UnitMana("player") or 0
	if rage < 10 then
		return false, nil, nil
	end

	-- Check stance (Pummel works in Battle and Berserker in TurtleWoW)
	local stance = ATW.Stance and ATW.Stance() or 0
	if stance ~= 1 and stance ~= 3 then
		return false, nil, nil
	end

	-- Find interrupt target
	local targetGUID, spellName, remaining, distance = ATW.GetInterruptTarget()

	if targetGUID and remaining and remaining > 0.3 then  -- At least 0.3s remaining to react
		return true, targetGUID, spellName
	end

	return false, nil, nil
end

---------------------------------------
-- Execute interrupt on target GUID
-- Targets the enemy, uses Pummel, returns to previous target
---------------------------------------
function ATW.ExecuteInterrupt(targetGUID)
	if not targetGUID then return false end

	-- Store current target
	local hadTarget = UnitExists("target")
	local oldTargetGUID = nil
	if hadTarget and ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, _, guid = pcall(function() return UnitExists("target") end)
		if ok then oldTargetGUID = guid end
	end

	-- Target the caster
	local targeted = false
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok = pcall(function() TargetUnit(targetGUID) end)
		targeted = ok and UnitExists("target")
	end

	if not targeted then
		return false
	end

	-- Use Pummel
	ATW.Cast("Pummel", true)

	-- NOTE: Do NOT clear the cast here!
	-- - If Pummel succeeds, the guardrail will detect it going on cooldown
	-- - If Pummel fails, the enemy is still casting and we need to keep tracking
	-- - UNIT_CASTEVENT will naturally clear when cast ends ("CAST" or "FAIL" event)

	-- Return to previous target (if different)
	if oldTargetGUID and oldTargetGUID ~= targetGUID then
		pcall(function() TargetUnit(oldTargetGUID) end)
	elseif not hadTarget then
		ClearTarget()
	end

	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		local spellName = ATW.CastingTracker.casts[targetGUID] and ATW.CastingTracker.casts[targetGUID].spellName or "?"
		ATW.Print("|cff00ff00INTERRUPT|r: " .. (spellName or "cast"))
	end

	return true
end

---------------------------------------
-- Toggle functions
---------------------------------------
function ATW.SetPummel(enabled)
	AutoTurtleWarrior_Config.PummelEnabled = enabled
	if enabled then
		ATW.Print("Auto-Interrupt: |cff00ff00ON|r (Pummel)")
	else
		ATW.Print("Auto-Interrupt: |cffff0000OFF|r")
	end
end

function ATW.TogglePummel()
	ATW.SetPummel(not AutoTurtleWarrior_Config.PummelEnabled)
end

---------------------------------------
-- Debug: Print current casting enemies
---------------------------------------
function ATW.PrintCastingEnemies()
	ATW.Print("=== Casting Enemies ===")

	local pummelEnabled = AutoTurtleWarrior_Config.PummelEnabled
	ATW.Print("Auto-Interrupt: " .. (pummelEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"))

	ATW.CastingTracker.Cleanup()

	local count = 0
	local now = GetTime()

	for guid, cast in pairs(ATW.CastingTracker.casts) do
		count = count + 1
		local remaining = cast.endTime - now
		local dist = ATW.GetDistance and ATW.GetDistance(guid) or "?"
		local inRange = (type(dist) == "number" and dist <= 5) and "|cff00ff00" or "|cffff0000"

		ATW.Print("  " .. (cast.casterName or "?") .. ": " .. (cast.spellName or "?"))
		ATW.Print("    " .. inRange .. string.format("%.1f", dist or 0) .. "yd|r | " .. string.format("%.1f", remaining) .. "s left")
	end

	if count == 0 then
		ATW.Print("  (no enemies casting)")
	end

	-- Show Pummel status
	local pummelCD = ATW.GetCooldownRemaining and ATW.GetCooldownRemaining("Pummel") or 0
	if pummelCD > 0 then
		ATW.Print("Pummel CD: " .. string.format("%.1f", pummelCD) .. "s")
	else
		ATW.Print("Pummel: |cff00ff00READY|r")
	end
end
