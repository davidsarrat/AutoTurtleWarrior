--[[
	Auto Turtle Warrior - Player/TTD
	Time To Die calculation using HP sampling
	Tracks multiple units via GUID (nameplates + target)
]]--

ATW.TTD = {
	units = {},             -- [guid] = { samples = {}, lastSample = 0 }
	maxSamples = 30,        -- Keep last 30 samples per unit (7.5s of data)
	sampleInterval = 0.25,  -- Sample every 0.25s (4/second)
	minSamples = 8,         -- Minimum 8 samples (2 seconds) for reliable TTD
	maxUnits = 20,          -- Max units to track
	cleanupInterval = 5,    -- Cleanup dead/old units every 5s
	lastCleanup = 0,
}

---------------------------------------
-- Get or create unit data by GUID
---------------------------------------
local function GetUnitData(guid)
	if not guid or guid == "" then return nil end

	if not ATW.TTD.units[guid] then
		-- Check if we're at max units
		local count = 0
		for _ in pairs(ATW.TTD.units) do
			count = count + 1
		end

		if count >= ATW.TTD.maxUnits then
			-- Remove oldest unit
			local oldestGUID, oldestTime = nil, GetTime()
			for g, data in pairs(ATW.TTD.units) do
				if data.lastSample < oldestTime then
					oldestTime = data.lastSample
					oldestGUID = g
				end
			end
			if oldestGUID then
				ATW.TTD.units[oldestGUID] = nil
			end
		end

		ATW.TTD.units[guid] = {
			samples = {},
			lastSample = 0,
		}
	end

	return ATW.TTD.units[guid]
end

---------------------------------------
-- Reset TTD for a specific unit
---------------------------------------
function ATW.ResetUnitTTD(guid)
	if guid then
		ATW.TTD.units[guid] = nil
	end
end

---------------------------------------
-- Reset all TTD tracking
---------------------------------------
function ATW.ResetTTD()
	ATW.TTD.units = {}
	ATW.TTD.lastCleanup = 0
end

---------------------------------------
-- Sample a unit's HP by GUID
---------------------------------------
local function SampleUnit(guid, hp, maxHp)
	if not guid or guid == "" then return end
	if not hp or hp <= 0 then return end
	if not maxHp or maxHp <= 0 then return end

	local now = GetTime()
	local data = GetUnitData(guid)
	if not data then return end

	-- Sample interval check
	if now - data.lastSample < ATW.TTD.sampleInterval then
		return
	end

	-- Add sample
	table.insert(data.samples, {
		time = now,
		hp = hp,
		maxHp = maxHp,
	})

	-- Trim old samples (keep most recent)
	while table.getn(data.samples) > ATW.TTD.maxSamples do
		table.remove(data.samples, 1)
	end

	data.lastSample = now
end

---------------------------------------
-- Update TTD for current target
---------------------------------------
function ATW.UpdateTargetTTD()
	if not UnitExists("target") or UnitIsDead("target") then
		return
	end

	if not UnitCanAttack("player", "target") then
		return
	end

	-- Get GUID and HP using SuperWoW for consistency
	local guid = nil
	local hp, maxHp = nil, nil

	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local _, g = UnitExists("target")
		guid = g

		if guid then
			-- Use GUID-based functions for consistent values
			local okHp, valHp = pcall(function() return UnitHealth(guid) end)
			local okMax, valMax = pcall(function() return UnitHealthMax(guid) end)
			if okHp and valHp and okMax and valMax then
				hp = valHp
				maxHp = valMax
			end
		end
	end

	-- Fallback for non-SuperWoW
	if not guid then
		guid = UnitName("target") .. ":" .. UnitLevel("target")
	end

	if not hp or not maxHp then
		hp = UnitHealth("target")
		maxHp = UnitHealthMax("target")
		-- In vanilla, these return 0-100 for non-player, so treat as percentage
		if maxHp == 100 then
			-- hp is already percentage, convert to "fake" real values
			maxHp = 10000
			hp = hp * 100
		end
	end

	SampleUnit(guid, hp, maxHp)
end

---------------------------------------
-- Update TTD for all visible nameplates
-- Call this on OnUpdate (throttled)
---------------------------------------
function ATW.UpdateAllTTD()
	local now = GetTime()

	-- Update target
	ATW.UpdateTargetTTD()

	-- Update nameplates (requires SuperWoW)
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local numChildren = WorldFrame:GetNumChildren()
		if numChildren and numChildren > 0 then
			local children = { WorldFrame:GetChildren() }
			for i = 1, numChildren do
				local frame = children[i]
				-- Nameplates are visible frames without names
				if frame and frame:IsVisible() and not frame:GetName() then
					local guid = ATW.GetNameplateGUID and ATW.GetNameplateGUID(frame)
					if guid then
						-- Get HP using SuperWoW's UnitHealth(guid)
						local okHp, hp = pcall(function() return UnitHealth(guid) end)
						local okMax, maxHp = pcall(function() return UnitHealthMax(guid) end)
						if okHp and hp and okMax and maxHp and hp > 0 and maxHp > 0 then
							SampleUnit(guid, hp, maxHp)
						end
					end
				end
			end
		end
	end

	-- Periodic cleanup
	if now - ATW.TTD.lastCleanup > ATW.TTD.cleanupInterval then
		ATW.CleanupTTD()
		ATW.TTD.lastCleanup = now
	end
end

---------------------------------------
-- Cleanup dead/stale units
---------------------------------------
function ATW.CleanupTTD()
	local now = GetTime()
	local staleThreshold = 10  -- Remove if no update for 10s

	for guid, data in pairs(ATW.TTD.units) do
		if now - data.lastSample > staleThreshold then
			ATW.TTD.units[guid] = nil
		end
	end
end

---------------------------------------
-- Calculate TTD for a specific GUID using LINEAR REGRESSION
-- This is the industry-standard method used by HeroLib, MaxDps, etc.
-- Fits a line hp = a + b*time, then solves for when hp = 0
-- Returns seconds until unit dies, or 999 if unknown
---------------------------------------
function ATW.GetUnitTTD(guid)
	if not guid then return 999 end

	local data = ATW.TTD.units[guid]
	if not data then return 999 end

	local samples = data.samples
	local n = table.getn(samples)

	-- Not enough data - need sufficient samples for regression
	if n < ATW.TTD.minSamples then
		return 999
	end

	-- Convert to HP percentage for stability
	local lastSample = samples[n]
	local maxHP = lastSample.maxHp
	if not maxHP or maxHP <= 0 then
		return 999
	end

	-- Linear regression: fit hp% = a + b*time
	-- Using least squares method (same as HeroLib/MaxDps)
	-- Solve: (Ex² Ex)(a) = (Exy)
	--        (Ex  n )(b)   (Ey )
	local Ex2, Ex, Exy, Ey = 0, 0, 0, 0

	for i = 1, n do
		local sample = samples[i]
		local x = sample.time
		local y = (sample.hp / maxHP) * 100  -- HP as percentage

		Ex2 = Ex2 + x * x
		Ex = Ex + x
		Exy = Exy + x * y
		Ey = Ey + y
	end

	-- Calculate denominator (check for division by zero)
	local denominator = Ex2 * n - Ex * Ex
	if denominator == 0 or math.abs(denominator) < 0.0001 then
		return 999
	end

	local invariant = 1 / denominator

	-- Calculate coefficients: a (intercept), b (slope)
	local a = (-Ex * Exy * invariant) + (Ex2 * Ey * invariant)
	local b = (n * Exy * invariant) - (Ex * Ey * invariant)

	-- b is the slope (HP% change per second)
	-- If b >= 0, HP is not decreasing (healing or no damage)
	if b >= 0 then
		return 999
	end

	-- Calculate time when HP reaches 0%
	-- 0 = a + b*time  =>  time = -a/b
	-- But we need time FROM NOW, not absolute time
	local currentTime = GetTime()
	local timeAtZero = -a / b
	local ttd = timeAtZero - currentTime

	-- Sanity checks
	if ttd < 0 then
		-- Already should be dead according to regression
		-- Return small value but not 0
		return 1
	end

	if ttd > 300 then
		return 300  -- Cap at 5 minutes
	end

	return ttd
end

---------------------------------------
-- Get TTD for current target
---------------------------------------
function ATW.GetTTD()
	if not UnitExists("target") then return 999 end

	local guid = nil
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local _, g = UnitExists("target")
		guid = g
	else
		guid = UnitName("target") .. ":" .. UnitLevel("target")
	end

	return ATW.GetUnitTTD(guid)
end

-- Alias for GetTTD (Engine.lua compatibility)
ATW.GetTargetTTD = ATW.GetTTD

---------------------------------------
-- Get TTD for unit by nameplate index
---------------------------------------
function ATW.GetNameplateTTD(index)
	if not ATW.HasSuperWoW or not ATW.HasSuperWoW() then
		return 999
	end

	local nameplate = _G["NamePlate" .. index]
	if not nameplate or not nameplate:IsVisible() then
		return 999
	end

	local guid = nameplate:GetName(1)
	return ATW.GetUnitTTD(guid)
end

---------------------------------------
-- Convenience functions
---------------------------------------

-- Check if target will die within X seconds
function ATW.WillDieSoon(seconds)
	return ATW.GetTTD() <= seconds
end

-- Check if unit (by GUID) will die within X seconds
function ATW.UnitWillDieSoon(guid, seconds)
	return ATW.GetUnitTTD(guid) <= seconds
end

-- Check if target is in execute range (<20% HP)
function ATW.InExecutePhase()
	if not UnitExists("target") then return false end
	-- Use the unified GetHealthPercent which handles SuperWoW correctly
	return ATW.GetHealthPercent("target") < 20
end

-- Get target HP percentage
function ATW.GetTargetHPPercent()
	if not UnitExists("target") then return 100 end
	-- Use the unified GetHealthPercent which handles SuperWoW correctly
	return ATW.GetHealthPercent("target")
end

-- Estimate if target will reach execute phase within X seconds
function ATW.WillReachExecute(seconds)
	local guid = nil
	if ATW.HasSuperWoW and ATW.HasSuperWoW() then
		local _, g = UnitExists("target")
		guid = g
	else
		guid = UnitName("target") .. ":" .. UnitLevel("target")
	end

	local data = ATW.TTD.units[guid]
	if not data then return false end

	local numSamples = table.getn(data.samples)
	if numSamples < ATW.TTD.minSamples then return false end

	-- Already in execute
	if ATW.InExecutePhase() then return true end

	local ttd = ATW.GetTTD()
	if ttd >= 999 then return false end

	-- Time to reach 20% HP
	local currentPercent = ATW.GetTargetHPPercent()
	local percentToExecute = currentPercent - 20

	if percentToExecute <= 0 then return true end

	-- Estimate time: (currentPercent - 20) / (currentPercent / TTD)
	local timeToExecute = (percentToExecute / currentPercent) * ttd

	return timeToExecute <= seconds
end

---------------------------------------
-- Get count of tracked units
---------------------------------------
function ATW.GetTrackedUnitCount()
	local count = 0
	for _ in pairs(ATW.TTD.units) do
		count = count + 1
	end
	return count
end

---------------------------------------
-- Debug: Print TTD info
---------------------------------------
function ATW.PrintTTD()
	local ttd = ATW.GetTTD()
	local hp = ATW.GetTargetHPPercent()
	local exec = ATW.InExecutePhase()
	local tracked = ATW.GetTrackedUnitCount()

	ATW.Print("--- TTD Info ---")
	if ttd >= 999 then
		ATW.Print("Target TTD: Unknown")
	else
		ATW.Print("Target TTD: " .. string.format("%.1f", ttd) .. "s | HP: " ..
			string.format("%.1f", hp) .. "% | Exec: " .. (exec and "YES" or "NO"))
	end
	ATW.Print("Tracking " .. tracked .. " units")

	-- Show all tracked units with TTD
	if AutoTurtleWarrior_Config.Debug then
		for guid, data in pairs(ATW.TTD.units) do
			local unitTTD = ATW.GetUnitTTD(guid)
			local samples = table.getn(data.samples)
			local shortGUID = string.sub(guid, 1, 8) .. "..."
			if unitTTD < 999 then
				ATW.Print("  " .. shortGUID .. ": " .. string.format("%.1f", unitTTD) .. "s (" .. samples .. " samples)")
			end
		end
	end
end
