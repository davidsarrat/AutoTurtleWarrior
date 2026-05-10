--[[
	Auto Turtle Warrior - Combat/Trinkets

	Press logic and cooldown tracking for on-use trinkets.

	Design notes:
	- Two trinket slots: 13 (top) and 14 (bottom).
	- Each on-use trinket has its own cooldown (e.g. 120s for Earthstrike).
	- A SHARED internal cooldown of 30s exists between the two slots: using
	  one locks the OTHER slot for 30s. Cooldowns are tracked per slot via
	  GetInventoryItemCooldown.
	- When the rotation picks a trinket use, it must be allowed by both:
	  (a) that slot's own cooldown
	  (b) the shared 30s internal CD (we track internally based on last-press)
]]--

ATW.Trinkets = ATW.Trinkets or {}

local TRINKET_SLOTS = { 13, 14 }
local SHARED_INTERNAL_CD = 30  -- seconds shared between trinket slots

ATW.Trinkets.lastPressTime = 0  -- GetTime() of most recent trinket press
ATW.Trinkets.lastPressSlot = nil

---------------------------------------
-- Get the on-use trinket equipped in a slot, or nil
---------------------------------------
function ATW.Trinkets.GetSlotTrinket(slot)
	if not ATW.Gear or not ATW.Gear.trinkets then return nil end
	for _, t in ipairs(ATW.Gear.trinkets) do
		if t.slot == slot and t.data and t.data.onuse then
			return t
		end
	end
	return nil
end

---------------------------------------
-- Returns: ready, secondsRemaining
-- Combines per-slot cooldown + shared internal CD.
---------------------------------------
function ATW.Trinkets.GetReady(slot)
	local start, duration = GetInventoryItemCooldown("player", slot)
	local now = GetTime()
	local ownRemaining = 0
	if start and start > 0 and duration and duration > 0 then
		ownRemaining = (start + duration) - now
		if ownRemaining < 0 then ownRemaining = 0 end
	end

	-- Shared internal CD applies if the OTHER slot was pressed recently
	local sharedRemaining = 0
	if ATW.Trinkets.lastPressSlot and ATW.Trinkets.lastPressSlot ~= slot then
		local elapsed = now - ATW.Trinkets.lastPressTime
		if elapsed < SHARED_INTERNAL_CD then
			sharedRemaining = SHARED_INTERNAL_CD - elapsed
		end
	end

	local remaining = math.max(ownRemaining, sharedRemaining)
	return remaining <= 0, remaining
end

---------------------------------------
-- Press the trinket in slot. Records timestamp for shared-CD tracking.
-- Returns true if attempted, false otherwise.
---------------------------------------
function ATW.Trinkets.Use(slot)
	local trinket = ATW.Trinkets.GetSlotTrinket(slot)
	if not trinket then return false end

	local ready = ATW.Trinkets.GetReady(slot)
	if not ready then return false end

	UseInventoryItem(slot)
	ATW.Trinkets.lastPressTime = GetTime()
	ATW.Trinkets.lastPressSlot = slot
	if ATW.Debug then
		ATW.Debug("Trinket -> slot " .. slot .. " (" .. trinket.name .. ")")
	end
	return true
end

---------------------------------------
-- Decide which slot to press (if any), respecting per-slot CDs and shared
-- internal CD. Returns: slot or nil.
---------------------------------------
function ATW.Trinkets.PickSlot()
	if not ATW.IsCooldownAllowed or not ATW.IsCooldownAllowed("Trinkets") then
		-- Falls back to allowing if toggle not configured (default on)
	end

	local best = nil
	local bestPriority = -1

	for _, slot in ipairs(TRINKET_SLOTS) do
		local trinket = ATW.Trinkets.GetSlotTrinket(slot)
		if trinket then
			local ready = ATW.Trinkets.GetReady(slot)
			if ready then
				local pri = trinket.data.priority or 0
				if pri > bestPriority then
					best = slot
					bestPriority = pri
				end
			end
		end
	end

	return best
end

---------------------------------------
-- Debug: print state of both trinket slots
---------------------------------------
function ATW.Trinkets.PrintState()
	if not ATW.Print then return end
	ATW.Print("=== Trinkets ===")
	for _, slot in ipairs(TRINKET_SLOTS) do
		local trinket = ATW.Trinkets.GetSlotTrinket(slot)
		if trinket then
			local ready, remaining = ATW.Trinkets.GetReady(slot)
			local status = ready and "|cff00ff00READY|r"
			              or string.format("|cffffaa00%.1fs|r", remaining)
			ATW.Print(string.format("  Slot %d: %s (%s, prio %d)",
				slot, trinket.name, status, trinket.data.priority or 0))
		else
			-- Either empty or trinket has no on-use effect
			local link = GetInventoryItemLink("player", slot)
			if link then
				local _, _, name = string.find(link, "%[(.+)%]")
				ATW.Print("  Slot " .. slot .. ": " .. (name or "?") .. " (no on-use)")
			else
				ATW.Print("  Slot " .. slot .. ": empty")
			end
		end
	end
	if ATW.Trinkets.lastPressSlot then
		local elapsed = GetTime() - ATW.Trinkets.lastPressTime
		local sharedRem = math.max(0, SHARED_INTERNAL_CD - elapsed)
		if sharedRem > 0 then
			ATW.Print(string.format("  Shared CD: %.1fs (last press slot %d)",
				sharedRem, ATW.Trinkets.lastPressSlot))
		end
	end
end
