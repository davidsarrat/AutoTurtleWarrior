--[[
	Auto Turtle Warrior - Detection/AoE
	AoE detection using nameplates and enemy counting
	Includes per-GUID Rend tracking for multi-target spreading

	REND TRACKING SYSTEM (Robust Combat Log Verification):
	======================================================
	1. On cast attempt: Store as PENDING (guid, time, name)
	2. On combat log "X suffers Y from your Rend": CONFIRM pending -> add to tracker
	3. On failure (out of range, resist, immune): CANCEL pending
	4. Pending timeout (5s): Auto-cancel if no confirmation

	This ensures we NEVER track a Rend that didn't actually apply.
]]--

---------------------------------------
-- Rend Range Constant
-- Rend has 5 yard range (melee)
---------------------------------------
ATW.REND_RANGE = 5

---------------------------------------
-- Per-GUID Rend Tracking
-- Tracks which targets have Rend CONFIRMED via combat log
-- Format: {[guid] = {appliedAt, expiresAt, name}}
---------------------------------------
ATW.RendTracker = {
	targets = {},           -- Confirmed Rends
	pending = {},           -- Pending confirmations: {[guid] = {time, name}}
	REND_DURATION = 22,     -- TurtleWoW Rend lasts 22 seconds (ranks 5-7)
	PENDING_TIMEOUT = 4,    -- Timeout for pending entries (first tick at 3s)
}

---------------------------------------
-- Record a PENDING Rend cast (not confirmed yet)
-- Call this when we ATTEMPT to cast Rend on a GUID
---------------------------------------
function ATW.RendTracker.OnRendCastAttempt(guid, targetName)
	if not guid then return end

	local now = GetTime()
	ATW.RendTracker.pending[guid] = {
		time = now,
		name = targetName,
	}

	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		ATW.Debug("RendTracker: PENDING cast on " .. (targetName or "?") .. " [" .. string.sub(guid, 1, 8) .. "]")
	end
end

---------------------------------------
-- CONFIRM a Rend via combat log tick
-- Call this when we see "X suffers Y damage from your Rend"
---------------------------------------
function ATW.RendTracker.ConfirmRend(guid, targetName)
	if not guid then return false end

	local now = GetTime()
	local duration = ATW.GetRendDuration and ATW.GetRendDuration() or ATW.RendTracker.REND_DURATION

	-- Add/refresh in confirmed targets
	ATW.RendTracker.targets[guid] = {
		appliedAt = now,
		expiresAt = now + duration,
		name = targetName,
	}

	-- Remove from pending
	ATW.RendTracker.pending[guid] = nil

	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		ATW.Debug("RendTracker: CONFIRMED on " .. (targetName or "?") .. " [" .. string.sub(guid, 1, 8) .. "] (" .. duration .. "s)")
	end

	return true
end

---------------------------------------
-- CANCEL a pending Rend (failed to apply)
-- Call this on resist, immune, out of range, etc.
---------------------------------------
function ATW.RendTracker.CancelPending(guid)
	if not guid then return end

	local pending = ATW.RendTracker.pending[guid]
	if pending then
		if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
			ATW.Debug("RendTracker: CANCELLED pending on " .. (pending.name or "?") .. " [" .. string.sub(guid, 1, 8) .. "]")
		end
		ATW.RendTracker.pending[guid] = nil
	end
end

---------------------------------------
-- Legacy function: Record that we applied Rend to a GUID
-- NOW: This just creates a PENDING entry, not confirmed
---------------------------------------
function ATW.RendTracker.OnRendApplied(guid)
	if not guid then return end

	-- Get target name for verification
	local name = nil
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, result = pcall(function() return UnitName(guid) end)
		if ok then name = result end
	end

	-- Create pending entry (will be confirmed by combat log)
	ATW.RendTracker.OnRendCastAttempt(guid, name)
end

---------------------------------------
-- Check if GUID has CONFIRMED Rend (combat log verified)
-- This is the ROBUST method - only returns true for verified Rends
-- Used by the main HasRend() in Helpers.lua as secondary source
---------------------------------------
function ATW.RendTracker.HasRendConfirmed(guid)
	if not guid then return false end

	local now = GetTime()

	-- ONLY check confirmed targets (combat log verified)
	local data = ATW.RendTracker.targets[guid]
	if data then
		if now < data.expiresAt then
			return true  -- Confirmed and not expired
		else
			-- Expired, clean up
			ATW.RendTracker.targets[guid] = nil
		end
	end

	return false
end

---------------------------------------
-- Check if GUID has Rend (confirmed OR recent pending)
-- LEGACY - kept for backwards compatibility
-- PREFER HasRendConfirmed() for robust checks
---------------------------------------
function ATW.RendTracker.HasRend(guid)
	if not guid then return false end

	-- First check confirmed
	if ATW.RendTracker.HasRendConfirmed(guid) then
		return true
	end

	-- Check PENDING entries (short window to prevent spam-casting)
	-- This is a SOFT check - use HasRendConfirmed for robust checks
	local pending = ATW.RendTracker.pending[guid]
	if pending then
		local now = GetTime()
		local age = now - pending.time
		local timeout = ATW.RendTracker.PENDING_TIMEOUT or 4
		if age < timeout then
			return true
		else
			-- Timed out - cast probably failed
			ATW.RendTracker.pending[guid] = nil
		end
	end

	return false
end

---------------------------------------
-- Get remaining Rend duration on GUID
-- Returns duration for confirmed Rends, or estimated for pending
---------------------------------------
function ATW.RendTracker.GetRendRemaining(guid)
	if not guid then return 0 end

	local now = GetTime()

	-- Check confirmed targets
	local data = ATW.RendTracker.targets[guid]
	if data then
		local remaining = data.expiresAt - now
		if remaining > 0 then
			return remaining
		else
			ATW.RendTracker.targets[guid] = nil
		end
	end

	-- Check pending (assume full duration if recently cast)
	local pending = ATW.RendTracker.pending[guid]
	if pending then
		local age = now - pending.time
		if age < 5 then
			-- Estimate remaining: full duration minus age
			local duration = ATW.GetRendDuration and ATW.GetRendDuration() or ATW.RendTracker.REND_DURATION
			return math.max(0, duration - age)
		else
			ATW.RendTracker.pending[guid] = nil
		end
	end

	return 0
end

---------------------------------------
-- Clean up expired entries (confirmed and pending)
---------------------------------------
function ATW.RendTracker.Cleanup()
	local now = GetTime()

	-- Cleanup confirmed targets
	for guid, data in pairs(ATW.RendTracker.targets) do
		if now >= data.expiresAt then
			ATW.RendTracker.targets[guid] = nil
		end
	end

	-- Cleanup stale pending entries (>5s old)
	for guid, pending in pairs(ATW.RendTracker.pending) do
		if now - pending.time >= 5 then
			ATW.RendTracker.pending[guid] = nil
		end
	end
end

---------------------------------------
-- Reset all tracking (on combat end, etc.)
---------------------------------------
function ATW.RendTracker.Reset()
	ATW.RendTracker.targets = {}
	ATW.RendTracker.pending = {}
end

---------------------------------------
-- Find pending entry by target name
-- Used when combat log doesn't have GUID
-- Returns: guid or nil
---------------------------------------
function ATW.RendTracker.FindPendingByName(targetName)
	if not targetName then return nil end

	local now = GetTime()
	for guid, pending in pairs(ATW.RendTracker.pending) do
		if pending.name == targetName and (now - pending.time) < 5 then
			return guid
		end
	end
	return nil
end

-- Expose globally for convenience
function ATW.HasRendOnGUID(guid)
	return ATW.RendTracker.HasRend(guid)
end

function ATW.OnRendCast(guid)
	ATW.RendTracker.OnRendApplied(guid)

	-- Debug output
	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		local shortGUID = guid and (string.sub(guid, 1, 8) .. "...") or "nil"
		ATW.Print("Rend applied to GUID: " .. shortGUID)
	end
end

---------------------------------------
-- Combat Log Rend Detection
-- Parses combat log to CONFIRM Rend ticks
-- This is the ONLY way Rends get confirmed in the tracker
---------------------------------------
function ATW.ParseRendCombatLog(msg)
	if not msg then return end

	-- Pattern: "X suffers Y damage from your Rend."
	-- This fires every 3 seconds when Rend is active
	local _, _, targetName = string.find(msg, "^(.+) suffers %d+ damage from your Rend")

	if targetName then
		-- Find the pending entry for this target name
		-- This handles same-name mobs by using the GUID we stored at cast time
		local pendingGUID = ATW.RendTracker.FindPendingByName(targetName)

		if pendingGUID then
			-- CONFIRM the pending Rend
			ATW.RendTracker.ConfirmRend(pendingGUID, targetName)
			return true
		end

		-- No pending found - check if this refreshes an existing confirmed Rend
		-- For existing tracked Rends, the tick just confirms it's still active
		-- (no action needed, timer was set correctly at confirmation)

		if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
			ATW.Debug("Rend tick: " .. targetName .. " (already confirmed or not ours)")
		end

		return true
	end

	-- Pattern: "Your Rend was resisted by X" or "Your Rend failed. X is immune."
	local _, _, resistedTarget = string.find(msg, "Your Rend was resisted by (.+)")
	local _, _, immuneTarget = string.find(msg, "Your Rend failed%. (.+) is immune")

	if resistedTarget or immuneTarget then
		local failedTarget = resistedTarget or immuneTarget

		-- Find and cancel the pending entry for this target
		local pendingGUID = ATW.RendTracker.FindPendingByName(failedTarget)
		if pendingGUID then
			ATW.RendTracker.CancelPending(pendingGUID)

			if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
				ATW.Print("Rend FAILED (resist/immune): " .. failedTarget)
			end
		end

		return true
	end

	return false
end

---------------------------------------
-- Parse UI Error Messages for Rend failure
-- Called from Events.lua on UI_ERROR_MESSAGE
-- Handles: "Out of range", "Target not in line of sight", etc.
---------------------------------------
function ATW.ParseRendFailure(errorMsg)
	if not errorMsg then return end

	-- Check for failure messages that would affect our pending Rend
	local isFailure = strfind(errorMsg, "Out of range") or
	                  strfind(errorMsg, "not in line of sight") or
	                  strfind(errorMsg, "facing the wrong way") or
	                  strfind(errorMsg, "Invalid target") or
	                  strfind(errorMsg, "No target")

	if isFailure then
		-- Check if we have any recent pending Rends (within 1 second)
		-- The error comes immediately after cast attempt
		local now = GetTime()
		for guid, pending in pairs(ATW.RendTracker.pending) do
			if now - pending.time < 1 then
				ATW.RendTracker.CancelPending(guid)

				if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
					ATW.Print("Rend FAILED (UI error): " .. errorMsg)
				end
				return true
			end
		end
	end

	return false
end

---------------------------------------
-- Debug: Print Rend tracker status
-- Shows both CONFIRMED and PENDING entries
---------------------------------------
function ATW.PrintRendTracker()
	ATW.Print("=== Rend Tracker ===")

	local now = GetTime()

	-- Show CONFIRMED Rends
	local confirmedCount = 0
	for guid, data in pairs(ATW.RendTracker.targets) do
		confirmedCount = confirmedCount + 1
		local remaining = data.expiresAt - now
		local shortGUID = string.sub(guid, 1, 12) .. "..."
		local nameStr = data.name and (" (" .. data.name .. ")") or ""
		ATW.Print("  |cff00ff00CONFIRMED|r " .. shortGUID .. nameStr .. ": " .. string.format("%.1f", remaining) .. "s")
	end

	-- Show PENDING Rends
	local pendingCount = 0
	for guid, pending in pairs(ATW.RendTracker.pending) do
		pendingCount = pendingCount + 1
		local age = now - pending.time
		local shortGUID = string.sub(guid, 1, 12) .. "..."
		local nameStr = pending.name and (" (" .. pending.name .. ")") or ""
		ATW.Print("  |cffffff00PENDING|r " .. shortGUID .. nameStr .. ": " .. string.format("%.1f", age) .. "s ago")
	end

	if confirmedCount == 0 and pendingCount == 0 then
		ATW.Print("  (no targets tracked)")
	else
		ATW.Print("Total: " .. confirmedCount .. " confirmed, " .. pendingCount .. " pending")
	end
end

---------------------------------------
-- Nameplate GUID Detection (SuperWoW)
---------------------------------------
function ATW.GetNameplateGUID(frame)
	if not ATW.HasSuperWoW() then
		return nil
	end

	local ok, guid = pcall(function()
		return frame:GetName(1)
	end)

	if ok and guid and guid ~= "" then
		return guid
	end
	return nil
end

---------------------------------------
-- Count Enemies in Range (with optional range override)
---------------------------------------
function ATW.EnemyCount(customRange)
	local range = customRange or AutoTurtleWarrior_Config.WWRange or 8
	local count = 0

	local numChildren = WorldFrame:GetNumChildren()
	if not numChildren or numChildren == 0 then
		return 0
	end

	local children = { WorldFrame:GetChildren() }

	for i = 1, numChildren do
		local frame = children[i]

		-- Check if it's a nameplate (visible, no name)
		if frame and frame:IsVisible() and not frame:GetName() then
			local frameChildren = { frame:GetChildren() }

			for _, child in ipairs(frameChildren) do
				if child and child:GetObjectType() == "StatusBar" then
					local guid = ATW.GetNameplateGUID(frame)

					if guid and UnitCanAttack("player", guid) == 1 then
						local dist = ATW.GetDistance(guid)
						if dist and dist <= range then
							count = count + 1
						end
					end
					break
				end
			end
		end
	end

	return count
end

---------------------------------------
-- Count Enemies in Melee Range (5 yards)
-- Used for Rend spreading decisions
---------------------------------------
function ATW.MeleeEnemyCount()
	return ATW.EnemyCount(5)
end

---------------------------------------
-- Get enemies in range with TTD info
-- Returns: { {guid, distance, ttd, bleedImmune, creatureType, hasRend, rendRemaining, hp, maxHp}, ... }
---------------------------------------
function ATW.GetEnemiesWithTTD(maxRange)
	maxRange = maxRange or 8
	local enemies = {}

	-- Cleanup expired Rend tracking
	if ATW.RendTracker then
		ATW.RendTracker.Cleanup()
	end

	local numChildren = WorldFrame:GetNumChildren()
	if not numChildren or numChildren == 0 then
		return enemies
	end

	local children = { WorldFrame:GetChildren() }

	for i = 1, numChildren do
		local frame = children[i]

		if frame and frame:IsVisible() and not frame:GetName() then
			local frameChildren = { frame:GetChildren() }

			for _, child in ipairs(frameChildren) do
				if child and child:GetObjectType() == "StatusBar" then
					local guid = ATW.GetNameplateGUID(frame)

					if guid and UnitCanAttack("player", guid) == 1 then
						local dist = ATW.GetDistance(guid)
						if dist and dist <= maxRange then
							-- Get TTD for this unit
							local ttd = 30  -- Default
							if ATW.GetUnitTTD then
								ttd = ATW.GetUnitTTD(guid) or 30
							end

							-- Check bleed immunity
							local bleedImmune, creatureType = false, nil
							if ATW.IsBleedImmuneGUID then
								bleedImmune, creatureType = ATW.IsBleedImmuneGUID(guid)
							end

							-- Check Rend status
							-- Priority 1: Use SuperWoW's UnitDebuff(guid) for real debuff check
							-- Priority 2: Fall back to manual tracking
							local hasRend = false
							local rendRemaining = 0

							-- ATW.HasRend uses SuperWoW if available, falls back to tracking
							if ATW.HasRend then
								hasRend = ATW.HasRend(guid)
							elseif ATW.RendTracker then
								hasRend = ATW.RendTracker.HasRend(guid)
							end

							-- Duration still comes from tracking (SuperWoW UnitDebuff doesn't return duration)
							if ATW.GetRendRemaining then
								rendRemaining = ATW.GetRendRemaining(guid)
							elseif ATW.RendTracker then
								rendRemaining = ATW.RendTracker.GetRendRemaining(guid)
							end

							-- Get HP using SuperWoW's UnitHealth(guid)
							-- This is more reliable than parsing nameplate StatusBars
							local hp, maxHp = nil, nil
							if ATW.HasSuperWoW and ATW.HasSuperWoW() then
								local okHp, valHp = pcall(function()
									return UnitHealth(guid)
								end)
								local okMax, valMax = pcall(function()
									return UnitHealthMax(guid)
								end)
								if okHp and valHp and okMax and valMax and valMax > 0 then
									hp = valHp
									maxHp = valMax
								end
							end

							table.insert(enemies, {
								guid = guid,
								distance = dist,
								ttd = ttd,
								bleedImmune = bleedImmune,
								creatureType = creatureType,
								hasRend = hasRend,
								rendRemaining = rendRemaining,
								hp = hp,
								maxHp = maxHp,
							})
						end
					end
					break
				end
			end
		end
	end

	return enemies
end

---------------------------------------
-- Calculate if multi-Rend spreading is optimal
-- No arbitrary thresholds - uses HP-based rule + simulation
-- Returns: shouldSpreadRend, targetCount, damageGain%
---------------------------------------
function ATW.ShouldSpreadRend()
	-- Get enemies in melee range (5 yards) with TTD
	local meleeEnemies = ATW.GetEnemiesWithTTD(5)
	local meleeCount = table.getn(meleeEnemies)

	-- No enemies = nothing to spread
	if meleeCount < 1 then
		return false, 0, 0
	end

	-- Count enemies worth Rending using HP-based rule (not arbitrary TTD threshold)
	-- Uses same logic as Engine.ShouldApplyRendToGUID
	local worthyTargets = 0
	for _, enemy in ipairs(meleeEnemies) do
		-- Skip if already has Rend or is bleed immune
		if not enemy.hasRend and not enemy.bleedImmune then
			-- Get HP%
			local hpPercent = 100
			if enemy.hp and enemy.maxHp and enemy.maxHp > 0 then
				hpPercent = (enemy.hp / enemy.maxHp) * 100
			end

			-- Use HP-based rule: >= 30% HP is worth Rending
			-- (simulation-based: 30% HP = ~9s TTD = 3 Rend ticks minimum)
			if hpPercent >= 30 then
				worthyTargets = worthyTargets + 1
			end
		end
	end

	-- Return target count - let caller decide what to do with it
	-- No arbitrary "need X targets" threshold
	if worthyTargets >= 1 then
		-- Use time-based simulation for accurate damage comparison
		if ATW.FindOptimalStrategy then
			local strategy, gainPercent = ATW.FindOptimalStrategy()
			if strategy == "rend_spread" and gainPercent > 0 then
				return true, worthyTargets, gainPercent
			end
		end
	end

	return false, worthyTargets, 0
end

---------------------------------------
-- AoE Mode Detection
---------------------------------------
function ATW.InAoE()
	local mode = AutoTurtleWarrior_Config.AoE

	if mode == "on" then
		return true
	elseif mode == "off" then
		return false
	end

	-- Auto mode: check enemy count
	return ATW.EnemyCount() >= AutoTurtleWarrior_Config.AoECount
end
