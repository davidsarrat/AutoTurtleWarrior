--[[
	Auto Turtle Warrior - Detection/AoE
	AoE detection using nameplates and enemy counting
	Includes per-GUID Rend tracking for multi-target spreading
]]--

---------------------------------------
-- Per-GUID Rend Tracking
-- Tracks which targets have Rend applied (by us)
-- Format: {[guid] = {appliedAt, expiresAt}}
---------------------------------------
ATW.RendTracker = {
	targets = {},
	REND_DURATION = 21,  -- Rend lasts 21 seconds
}

-- Record that we applied Rend to a GUID
function ATW.RendTracker.OnRendApplied(guid)
	if not guid then return end

	local now = GetTime()
	ATW.RendTracker.targets[guid] = {
		appliedAt = now,
		expiresAt = now + ATW.RendTracker.REND_DURATION,
	}

	-- Debug: show full GUID being stored
	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		ATW.Debug("RendTracker: STORED guid=" .. guid)
	end
end

-- Check if GUID has Rend (that hasn't expired)
function ATW.RendTracker.HasRend(guid)
	if not guid then return false end

	local data = ATW.RendTracker.targets[guid]
	if not data then
		-- Debug: show GUID not found
		if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
			ATW.Debug("RendTracker: CHECK guid=" .. guid .. " -> NOT FOUND")
		end
		return false
	end

	local now = GetTime()
	if now >= data.expiresAt then
		-- Expired, clean up
		ATW.RendTracker.targets[guid] = nil
		if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
			ATW.Debug("RendTracker: CHECK guid=" .. guid .. " -> EXPIRED")
		end
		return false
	end

	-- Debug: show GUID found with time remaining
	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		local remaining = data.expiresAt - now
		ATW.Debug("RendTracker: CHECK guid=" .. guid .. " -> HAS REND (" .. string.format("%.1f", remaining) .. "s)")
	end

	return true
end

-- Get remaining Rend duration on GUID
function ATW.RendTracker.GetRendRemaining(guid)
	if not guid then return 0 end

	local data = ATW.RendTracker.targets[guid]
	if not data then return 0 end

	local remaining = data.expiresAt - GetTime()
	if remaining < 0 then
		ATW.RendTracker.targets[guid] = nil
		return 0
	end

	return remaining
end

-- Clean up expired entries
function ATW.RendTracker.Cleanup()
	local now = GetTime()
	for guid, data in pairs(ATW.RendTracker.targets) do
		if now >= data.expiresAt then
			ATW.RendTracker.targets[guid] = nil
		end
	end
end

-- Reset all tracking (on combat end, etc.)
function ATW.RendTracker.Reset()
	ATW.RendTracker.targets = {}
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
-- Parses combat log to verify Rend is ticking
-- This catches Rend applied by other means or refreshes tracking
---------------------------------------
function ATW.ParseRendCombatLog(msg)
	if not msg then return end

	-- Pattern: "X suffers Y damage from your Rend."
	-- This fires every 3 seconds when Rend is active
	-- Note: Lua 5.0 doesn't have string.match, use string.find with captures
	local _, _, targetName = string.find(msg, "^(.+) suffers %d+ damage from your Rend")

	if targetName then
		-- Check if we have a pending Rend cast waiting for confirmation
		-- This is the KEY to handling multiple mobs with same name:
		-- We use the EXACT GUID we stored at cast time, verified by name match
		if ATW.State and ATW.State.PendingRendGUID then
			local pendingTime = ATW.State.PendingRendTime or 0
			local pendingName = ATW.State.PendingRendName

			-- Only use pending if within 5 seconds (first tick is at 3s, with some margin)
			if GetTime() - pendingTime < 5 then
				-- Name must match exactly - this confirms it's OUR cast
				if pendingName and pendingName == targetName then
					-- CONFIRM: Use the exact GUID we saved at cast time
					ATW.RendTracker.OnRendApplied(ATW.State.PendingRendGUID)

					if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
						local shortGUID = string.sub(ATW.State.PendingRendGUID, 1, 8)
						ATW.Print("Rend CONFIRMED: " .. targetName .. " [" .. shortGUID .. "]")
					end

					-- Clear pending - successfully confirmed
					ATW.State.PendingRendGUID = nil
					ATW.State.PendingRendTime = nil
					ATW.State.PendingRendName = nil
					return true
				end
			else
				-- Pending expired, clear it
				ATW.State.PendingRendGUID = nil
				ATW.State.PendingRendTime = nil
				ATW.State.PendingRendName = nil
			end
		end

		-- No pending or name didn't match - this is a tick from an already-tracked Rend
		-- We do NOT update the tracker here because:
		-- 1. We can't reliably identify WHICH mob if there are duplicates
		-- 2. The tracker already has the correct 21s duration from initial confirmation
		-- 3. This avoids incorrectly refreshing the wrong mob's timer

		if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
			ATW.Debug("Rend tick (already tracked): " .. targetName)
		end

		return true
	end

	-- Pattern: "Your Rend was resisted by X" or "Your Rend failed. X is immune."
	-- Note: Lua 5.0 doesn't have string.match, use string.find with captures
	local _, _, resistedTarget = string.find(msg, "Your Rend was resisted by (.+)")
	local _, _, immuneTarget = string.find(msg, "Your Rend failed%. (.+) is immune")

	if resistedTarget or immuneTarget then
		local failedTarget = resistedTarget or immuneTarget

		-- Remove tracking if the failed target matches our pending name
		-- Since we now track immediately on cast, we need to REMOVE on failure
		if ATW.State and ATW.State.PendingRendName == failedTarget then
			-- CRITICAL: Remove from tracker (we added optimistically on cast)
			if ATW.State.PendingRendGUID and ATW.RendTracker then
				ATW.RendTracker.targets[ATW.State.PendingRendGUID] = nil
				if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
					ATW.Debug("RendTracker: REMOVED (failed) guid=" .. ATW.State.PendingRendGUID)
				end
			end
			ATW.State.PendingRendGUID = nil
			ATW.State.PendingRendTime = nil
			ATW.State.PendingRendName = nil

			if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
				ATW.Print("Rend FAILED: " .. failedTarget)
			end
		end

		return true
	end

	return false
end

---------------------------------------
-- Debug: Print Rend tracker status
---------------------------------------
function ATW.PrintRendTracker()
	ATW.Print("=== Rend Tracker ===")

	local count = 0
	local now = GetTime()

	for guid, data in pairs(ATW.RendTracker.targets) do
		count = count + 1
		local remaining = data.expiresAt - now
		local shortGUID = string.sub(guid, 1, 12) .. "..."
		ATW.Print("  " .. shortGUID .. ": " .. string.format("%.1f", remaining) .. "s remaining")
	end

	if count == 0 then
		ATW.Print("  (no targets tracked)")
	else
		ATW.Print("Total: " .. count .. " targets")
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
