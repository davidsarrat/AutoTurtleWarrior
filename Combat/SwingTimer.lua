--[[
	Auto Turtle Warrior - Combat/SwingTimer
	Tracks main hand and off-hand swing timers
	Detects Heroic Strike/Cleave queue status
]]--

ATW.Swing = {
	-- Timestamps
	lastMH = 0,          -- Last main hand swing
	lastOH = 0,          -- Last off-hand swing

	-- Weapon speeds (updated from Stats)
	MHSpeed = 2.6,
	OHSpeed = 2.6,

	-- Queue status
	queued = nil,        -- nil, "Heroic Strike", or "Cleave"
	queuedTime = 0,      -- When it was queued

	-- Combat state
	inCombat = false,
	lastCombatAction = 0,

	-- Detection method
	usingCastEvent = false,  -- true if using SuperWoW UNIT_CASTEVENT (more reliable)
}

---------------------------------------
-- Get time until next main hand swing
---------------------------------------
function ATW.GetMHSwingRemaining()
	local swing = ATW.Swing
	if swing.lastMH == 0 then return 0 end

	local elapsed = GetTime() - swing.lastMH
	local remaining = swing.MHSpeed - elapsed

	if remaining < 0 then remaining = 0 end
	return remaining
end

---------------------------------------
-- Get time until next off-hand swing
---------------------------------------
function ATW.GetOHSwingRemaining()
	local swing = ATW.Swing
	if not ATW.Stats.HasOffHand then return 999 end
	if swing.lastOH == 0 then return 0 end

	local elapsed = GetTime() - swing.lastOH
	local remaining = swing.OHSpeed - elapsed

	if remaining < 0 then remaining = 0 end
	return remaining
end

---------------------------------------
-- Check if HS/Cleave is queued
---------------------------------------
function ATW.IsSwingQueued()
	return ATW.Swing.queued ~= nil
end

function ATW.GetQueuedSwing()
	return ATW.Swing.queued
end

---------------------------------------
-- Update swing timer from combat log
-- Call this from combat log event handlers
---------------------------------------
function ATW.OnMeleeSwing(isMainHand, isSpecial)
	local swing = ATW.Swing
	local now = GetTime()

	if isMainHand then
		swing.lastMH = now
		-- If it was a special (HS/Cleave), clear the queue
		if isSpecial then
			swing.queued = nil
			swing.queuedTime = 0
		end
	else
		swing.lastOH = now
	end

	-- Update weapon speeds from stats
	swing.MHSpeed = ATW.Stats.MainHandSpeed or 2.6
	swing.OHSpeed = ATW.Stats.OffHandSpeed or 2.6

	swing.lastCombatAction = now
end

---------------------------------------
-- Called when HS or Cleave is cast
---------------------------------------
function ATW.OnSwingAbilityQueued(abilityName)
	ATW.Swing.queued = abilityName
	ATW.Swing.queuedTime = GetTime()
end

---------------------------------------
-- Calculate if it's a good time for HS/Cleave
-- Returns: priority modifier (0-1, higher = better time)
---------------------------------------
function ATW.GetSwingQueuePriority()
	local swing = ATW.Swing
	local remaining = ATW.GetMHSwingRemaining()
	local speed = swing.MHSpeed

	-- Already queued? Don't queue again
	if swing.queued then
		return 0
	end

	-- If swing is imminent (within 0.5s), high priority
	if remaining <= 0.5 then
		return 1.0
	end

	-- If swing is soon (within 1s), medium priority
	if remaining <= 1.0 then
		return 0.7
	end

	-- If swing is far (more than half the swing time), low priority
	if remaining > speed * 0.5 then
		return 0.2
	end

	-- Default medium-low
	return 0.4
end

---------------------------------------
-- Should we use HS/Cleave right now?
-- Considers: rage, swing timer, ability CDs
---------------------------------------
function ATW.ShouldQueueSwingAbility()
	local rage = UnitMana("player")
	local swing = ATW.Swing

	-- Already queued
	if swing.queued then
		return false, "already queued"
	end

	-- Check rage threshold
	local rageDumpThreshold = AutoTurtleWarrior_Config.HSRage or 50
	if rage < rageDumpThreshold then
		return false, "low rage"
	end

	-- Check if main abilities are on CD
	local btReady = ATW.Talents.HasBT and ATW.Ready("Bloodthirst")
	local wwReady = ATW.Ready("Whirlwind")

	-- If BT or WW is ready, don't waste rage on HS
	if btReady or wwReady then
		return false, "main abilities ready"
	end

	-- Check swing timer - only queue when swing is IMMINENT
	-- This minimizes the window for needing to cancel
	local remaining = ATW.GetMHSwingRemaining()

	-- Queue window: only when swing is < 0.5s away
	-- This is "just in time" queuing - less chance of needing to cancel
	local QUEUE_WINDOW = 0.5  -- Queue when swing is within 500ms

	-- High rage emergency - queue earlier to avoid cap (at 0.8s)
	if rage >= 85 then
		if remaining <= 0.8 then
			return true, "rage cap prevention"
		end
		return false, "waiting (high rage)"
	end

	-- Normal case: queue very close to swing
	if remaining <= QUEUE_WINDOW then
		return true, "swing imminent"
	end

	return false, "waiting (" .. string.format("%.1f", remaining) .. "s)"
end

---------------------------------------
-- Parse combat log for swing detection (legacy fallback)
-- Kept for compatibility but UNIT_CASTEVENT is preferred
---------------------------------------
function ATW.ParseCombatLogForSwing(msg, event)
	if not msg then return end

	-- Only use combat log if UNIT_CASTEVENT is not available
	-- UNIT_CASTEVENT is much more reliable (SuperWoW feature)
	if ATW.Swing.usingCastEvent then
		-- Only parse for HS/Cleave hit confirmation
		if event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
			if strfind(msg, "Your Heroic Strike") or strfind(msg, "Your Cleave") then
				ATW.Swing.queued = nil
				ATW.Swing.queuedTime = 0
			end
		end
		return
	end

	-- Fallback: Main hand white hits via combat log (less reliable)
	local isHit = false
	local isSpecial = false
	local isMainHand = true

	if event == "CHAT_MSG_COMBAT_SELF_HITS" then
		if strfind(msg, "^You hit") or strfind(msg, "^You crit") then
			isHit = true
		end
	elseif event == "CHAT_MSG_COMBAT_SELF_MISSES" then
		if strfind(msg, "^You miss") or
		   strfind(msg, "^Your attack was") then
			isHit = true
		end
	elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
		if strfind(msg, "Your Heroic Strike") then
			isHit = true
			isSpecial = true
			ATW.Swing.queued = nil
		elseif strfind(msg, "Your Cleave") then
			isHit = true
			isSpecial = true
			ATW.Swing.queued = nil
		end
	end

	if isHit then
		ATW.OnMeleeSwing(isMainHand, isSpecial)
	end
end

---------------------------------------
-- SuperWoW UNIT_CASTEVENT handler
-- This is the reliable method for swing detection
-- arg1: casterGUID, arg2: targetGUID, arg3: event type, arg4: spellID, arg5: duration
-- Event types: "MAINHAND", "OFFHAND", "START", "CAST", "FAIL", "CHANNEL"
---------------------------------------
function ATW.OnUnitCastEvent(casterGUID, targetGUID, eventType, spellID, duration)
	-- Only process player events
	if not casterGUID then return end

	-- Get player GUID
	local playerGUID = nil
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local ok, guid = pcall(function()
			local _, g = UnitExists("player")
			return g
		end)
		if ok then playerGUID = guid end
	end

	-- Not player's event
	if not playerGUID or casterGUID ~= playerGUID then return end

	local swing = ATW.Swing
	local now = GetTime()

	if eventType == "MAINHAND" then
		-- Main hand swing landed
		swing.lastMH = now
		swing.usingCastEvent = true  -- Mark that we're using this method

		-- Check if HS/Cleave was queued (it replaces the swing)
		local wasSpecial = (swing.queued ~= nil)
		if wasSpecial then
			swing.queued = nil
			swing.queuedTime = 0
		end

		-- Update weapon speeds from stats
		swing.MHSpeed = ATW.Stats.MainHandSpeed or 2.6
		swing.OHSpeed = ATW.Stats.OffHandSpeed or 2.6
		swing.lastCombatAction = now

		if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
			ATW.Debug("MH swing" .. (wasSpecial and " (HS/Cleave)" or ""))
		end

	elseif eventType == "OFFHAND" then
		-- Off-hand swing landed
		swing.lastOH = now
		swing.usingCastEvent = true

		-- Update weapon speeds from stats
		swing.OHSpeed = ATW.Stats.OffHandSpeed or 2.6
		swing.lastCombatAction = now

		if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
			ATW.Debug("OH swing")
		end

	elseif eventType == "CAST" then
		---------------------------------------
		-- SPELL CAST COMPLETED
		-- SuperWoW tells us when our spells complete
		-- Use this for ROBUST Rend tracking (no arbitrary timeouts!)
		---------------------------------------
		local spellName = nil
		if spellID then
			-- Get spell name from ID
			local ok, name = pcall(function()
				return SpellInfo(spellID)
			end)
			if ok then spellName = name end
		end

		-- Check if this is Rend
		if spellName and spellName == "Rend" and targetGUID then
			-- ROBUST CONFIRMATION: SuperWoW tells us Rend cast completed
			-- This is instant (no 3s tick wait) and reliable (cast definitely happened)
			if ATW.RendTracker and ATW.RendTracker.ConfirmRend then
				-- Get target name for logging
				local targetName = nil
				local okName, name = pcall(function() return UnitName(targetGUID) end)
				if okName then targetName = name end

				-- Confirm immediately - cast completed successfully
				ATW.RendTracker.ConfirmRend(targetGUID, targetName)

				if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
					ATW.Debug("Rend CONFIRMED via UNIT_CASTEVENT on " .. (targetName or "?"))
				end
			end
		end
	end
end

---------------------------------------
-- Cancel queued HS/Cleave ability
-- WARNING: Canceling resets swing timer!
-- Uses SpellStopCasting() which works in TurtleWoW
-- Returns: wasQueued (true if something was canceled)
---------------------------------------
function ATW.CancelSwingAbility()
	local swing = ATW.Swing

	if not swing.queued then
		return false  -- Nothing to cancel
	end

	local canceledAbility = swing.queued

	-- SpellStopCasting() cancels the queued HS/Cleave
	-- This is the TurtleWoW/Vanilla API for canceling next-melee attacks
	SpellStopCasting()

	-- Clear our tracking
	swing.queued = nil
	swing.queuedTime = 0

	-- IMPORTANT: Swing timer resets when HS/Cleave is canceled
	-- This is a known behavior - the MH swing restarts from 0
	swing.lastMH = GetTime()

	if AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.Debug then
		ATW.Print("Canceled " .. canceledAbility .. " (swing reset)")
	end

	return true
end

---------------------------------------
-- Check if we should cancel HS/Cleave for rage pooling
-- This is a complex decision weighing:
-- 1. HS/Cleave expected damage
-- 2. Swing timer reset penalty (lost auto + delayed rage)
-- 3. Value of pooled rage (for Execute, BT, WW)
-- Returns: shouldCancel, reason
---------------------------------------
function ATW.ShouldCancelSwingAbility()
	local swing = ATW.Swing

	-- No queued ability to cancel
	if not swing.queued then
		return false, "nothing queued"
	end

	local rage = UnitMana("player")
	local mhRemaining = ATW.GetMHSwingRemaining()

	-- If swing is imminent (< 0.3s), don't cancel - too late
	if mhRemaining < 0.3 then
		return false, "swing imminent"
	end

	-- Check if main abilities are ready and we're rage starved
	local btReady = ATW.Talents and ATW.Talents.HasBT and ATW.Ready and ATW.Ready("Bloodthirst")
	local wwReady = ATW.Ready and ATW.Ready("Whirlwind")
	local execReady = false

	-- Check for execute target
	if ATW.GetHealthPercent then
		local thp = ATW.GetHealthPercent("target")
		if thp and thp < 20 then
			execReady = true
		end
	end

	-- Calculate what we need to cast the main ability
	local neededRage = 0
	local neededAbility = nil

	if execReady then
		neededRage = ATW.Talents and ATW.Talents.ExecCost or 15
		neededAbility = "Execute"
	elseif btReady then
		neededRage = 30
		neededAbility = "Bloodthirst"
	elseif wwReady then
		neededRage = 25
		neededAbility = "Whirlwind"
	end

	-- If no main ability is waiting, don't cancel
	if not neededAbility then
		return false, "no priority ability waiting"
	end

	-- If we have enough rage for both, don't cancel
	local hsCost = ATW.Talents and ATW.Talents.HSCost or 15
	if rage >= neededRage + hsCost then
		return false, "enough rage for both"
	end

	-- Calculate the penalty of canceling:
	-- We lose HS/Cleave damage AND reset swing timer
	-- Expected value of keeping HS = HS damage + (rage gen from swing * value)
	-- Value of canceling = rage refund for main ability now

	-- Simple heuristic: Cancel if:
	-- 1. We're below the rage threshold for main ability
	-- 2. Main ability is ready NOW
	-- 3. Swing is more than 1s away (time to benefit)

	if rage < neededRage and mhRemaining > 1.0 then
		-- Calculate refund (partial, since HS was already "cast")
		-- Actually HS/Cleave doesn't consume rage until swing lands
		-- So canceling gives us "back" the full cost

		-- But we also lose auto-attack damage and rage from the swing
		-- This is the tricky part...

		-- For Execute phase: ALWAYS prioritize Execute
		if neededAbility == "Execute" then
			return true, "execute priority"
		end

		-- For BT/WW: Only cancel if rage is critically low
		if rage < neededRage * 0.8 then
			return true, "rage starved for " .. neededAbility
		end
	end

	return false, "not worth canceling"
end

---------------------------------------
-- Intelligent HS/Cleave management
-- Called periodically to check if we should cancel
-- Returns action taken: nil, "canceled", "kept"
---------------------------------------
function ATW.ManageSwingQueue()
	local shouldCancel, reason = ATW.ShouldCancelSwingAbility()

	if shouldCancel then
		if ATW.CancelSwingAbility() then
			return "canceled", reason
		end
	end

	return "kept", reason
end

---------------------------------------
-- Debug: Print swing timer info
---------------------------------------
function ATW.PrintSwingTimer()
	local swing = ATW.Swing
	local mhRemaining = ATW.GetMHSwingRemaining()
	local ohRemaining = ATW.GetOHSwingRemaining()
	local priority = ATW.GetSwingQueuePriority()

	ATW.Print("--- Swing Timer ---")

	-- Show detection method
	local method = swing.usingCastEvent and "|cff00ff00UNIT_CASTEVENT|r" or "|cffff9900Combat Log|r"
	ATW.Print("Method: " .. method)

	-- Main hand
	local mhStatus = ""
	if swing.lastMH > 0 then
		mhStatus = string.format("%.2f", mhRemaining) .. "s / " .. string.format("%.2f", swing.MHSpeed) .. "s"
	else
		mhStatus = "|cffff9900No data|r"
	end
	ATW.Print("MH: " .. mhStatus)

	-- Off hand
	if ATW.Stats.HasOffHand then
		local ohStatus = ""
		if swing.lastOH > 0 then
			ohStatus = string.format("%.2f", ohRemaining) .. "s / " .. string.format("%.2f", swing.OHSpeed) .. "s"
		else
			ohStatus = "|cffff9900No data|r"
		end
		ATW.Print("OH: " .. ohStatus)
	end

	local queueStatus = swing.queued or "none"
	ATW.Print("Queued: " .. queueStatus .. " | Priority: " .. string.format("%.1f", priority))

	local shouldQueue, reason = ATW.ShouldQueueSwingAbility()
	ATW.Print("Should HS/Cleave: " .. (shouldQueue and "YES" or "NO") .. " (" .. reason .. ")")

	-- Cancel logic
	local shouldCancel, cancelReason = ATW.ShouldCancelSwingAbility()
	ATW.Print("Should Cancel: " .. (shouldCancel and "YES" or "NO") .. " (" .. cancelReason .. ")")
end
