--[[
	Auto Turtle Warrior - Commands/SlashCommands
	Slash command handling
]]--

function ATW.HandleCommand(msg)
	local cmd = strlower(msg or "")

	if cmd == "" then
		-- Default: run rotation
		ATW.Rotation()

	elseif cmd == "aoe" then
		-- Show AoE analysis
		local wwRange = ATW.EnemyCount(8)
		local meleeRange = ATW.MeleeEnemyCount and ATW.MeleeEnemyCount() or 0

		ATW.Print("--- AoE Analysis ---")
		ATW.Print("WW range (8yd): " .. wwRange .. " enemies")
		ATW.Print("Melee range (5yd): " .. meleeRange .. " enemies")

		-- Show Rend spreading analysis
		if ATW.ShouldSpreadRend then
			local shouldSpread, targetCount, totalDmg = ATW.ShouldSpreadRend()
			if shouldSpread then
				ATW.Print("|cff00ff00REND SPREAD:|r " .. targetCount .. " targets")
				ATW.Print("  Total Rend dmg: " .. string.format("%.0f", totalDmg))
			else
				ATW.Print("Rend spread: |cffff0000NO|r (not worth it)")
			end
		end

		-- Show enemies with TTD and Rend status
		if ATW.GetEnemiesWithTTD then
			local enemies = ATW.GetEnemiesWithTTD(8)
			if table.getn(enemies) > 0 then
				ATW.Print("")
				ATW.Print("Enemies (with Rend tracking):")
				for i, e in ipairs(enemies) do
					if i <= 6 then
						-- Format HP%
						local hpStr = "?"
						if e.hp and e.maxHp and e.maxHp > 0 then
							hpStr = string.format("%.0f%%", (e.hp / e.maxHp) * 100)
						end

						-- Rend status
						local rendStr = ""
						if e.hasRend then
							rendStr = " |cff00ff00[REND " .. string.format("%.0f", e.rendRemaining) .. "s]|r"
						end

						-- Creature type / Bleed immune
						local typeStr = ""
						if e.creatureType and e.creatureType ~= "Unknown" then
							if e.bleedImmune then
								typeStr = " |cffff0000[" .. e.creatureType .. "]|r"
							else
								typeStr = " [" .. e.creatureType .. "]"
							end
						elseif e.bleedImmune then
							typeStr = " |cffff0000[IMMUNE]|r"
						end

						ATW.Print("  " .. string.format("%.1f", e.distance) .. "yd | HP: " .. hpStr ..
							" | TTD: " .. string.format("%.0f", e.ttd) .. "s" .. rendStr .. typeStr)
					end
				end
			end
		end

	elseif cmd == "debug" then
		-- Toggle debug mode
		AutoTurtleWarrior_Config.Debug = not AutoTurtleWarrior_Config.Debug
		ATW.Print("Debug: " .. (AutoTurtleWarrior_Config.Debug and "ON" or "OFF"))

	elseif cmd == "status" then
		-- Show addon status
		local uxp = ATW.HasUnitXP() and "|cff00ff00OK|r" or "|cffff0000NO|r"
		local swow = ATW.HasSuperWoW() and "|cff00ff00OK|r" or "|cffff0000NO|r"
		ATW.Print("UnitXP: " .. uxp .. " | SuperWoW: " .. swow)

	elseif cmd == "stats" then
		-- Show player stats
		ATW.PrintStats()

	elseif cmd == "spells" then
		-- Show detected spell ranks
		ATW.Print("--- Spell Ranks ---")
		if ATW.Spells then
			-- Rend (with detailed info)
			if ATW.Spells.HasRend then
				local rendDmg = ATW.GetRendDamage and ATW.GetRendDamage() or 0
				local rendDur = ATW.GetRendDuration and ATW.GetRendDuration() or 0
				local rendTicks = ATW.GetRendTicks and ATW.GetRendTicks() or 0
				local impRend = ATW.Talents and ATW.Talents.ImpRend or 0
				ATW.Print("Rend: Rank " .. ATW.Spells.RendRank ..
					" | " .. string.format("%.0f", rendDmg) .. " dmg / " .. rendDur .. "s (" .. rendTicks .. " ticks)")
				if impRend > 0 then
					ATW.Print("  Improved Rend: +" .. (impRend * 10) .. "% damage")
				end
			else
				ATW.Print("Rend: |cffff0000NOT LEARNED|r")
			end

			-- Other spells
			ATW.Print("Execute: Rank " .. (ATW.Spells.ExecuteRank or 0))
			ATW.Print("Whirlwind: Rank " .. (ATW.Spells.WhirlwindRank or 0))
			ATW.Print("Heroic Strike: Rank " .. (ATW.Spells.HeroicStrikeRank or 0))
			ATW.Print("Battle Shout: Rank " .. (ATW.Spells.BattleShoutRank or 0))
			if ATW.Spells.BloodthirstRank > 0 then
				ATW.Print("Bloodthirst: Rank " .. ATW.Spells.BloodthirstRank)
			end
			if ATW.Spells.MortalStrikeRank > 0 then
				ATW.Print("Mortal Strike: Rank " .. ATW.Spells.MortalStrikeRank)
			end
		else
			ATW.Print("Spells not loaded (use /reload)")
		end

	elseif cmd == "ttd" then
		-- Show TTD info
		ATW.PrintTTD()

	elseif cmd == "swing" then
		-- Show swing timer info
		ATW.PrintSwingTimer()

	elseif cmd == "prio" or cmd == "priority" then
		-- Show priority list
		ATW.PrintPriority()

	elseif cmd == "sim" then
		-- Show simulation
		ATW.PrintSim()

	elseif cmd == "rage" then
		-- Show rage model info
		if ATW.PrintRageModel then
			ATW.PrintRageModel()
		else
			ATW.Print("RageModel not loaded")
		end

	elseif cmd == "strat" or cmd == "strategy" then
		-- Compare strategies (normal vs rend spread)
		if ATW.PrintStrategyComparison then
			ATW.PrintStrategyComparison()
		else
			ATW.Print("Strategy comparison not loaded")
		end

	elseif cmd == "engine" or cmd == "fullsim" then
		-- Run full combat simulation
		if ATW.Engine and ATW.Engine.PrintSimulation then
			ATW.Engine.PrintSimulation(20)
		else
			ATW.Print("Engine not loaded")
		end

	elseif cmd == "gear" then
		-- Show gear info (sets, trinkets, enchants)
		if ATW.PrintGear then
			ATW.PrintGear()
		else
			ATW.Print("Gear module not loaded")
		end

	elseif cmd == "rend" then
		-- Show Rend decision (rule-based, not simulation)
		if ATW.Engine and ATW.Engine.PrintRendDecision then
			ATW.Engine.PrintRendDecision()
		else
			ATW.Print("Engine not loaded")
		end

		-- Also show tracker status
		if ATW.PrintRendTracker then
			ATW.Print("")
			ATW.PrintRendTracker()
		end

	elseif cmd == "rendtest" then
		-- Debug Rend detection on current target
		ATW.Print("--- Rend Detection Debug ---")

		if not UnitExists("target") then
			ATW.Print("No target")
		else
			local name = UnitName("target")
			ATW.Print("Target: " .. (name or "nil"))

			local hasSW = ATW.HasSuperWoW and ATW.HasSuperWoW()
			ATW.Print("SuperWoW: " .. (hasSW and "YES" or "NO"))

			-- Get GUID
			local guid = nil
			if hasSW then
				local _, g = UnitExists("target")
				guid = g
				ATW.Print("GUID: " .. (guid and string.sub(guid, 1, 16) .. "..." or "nil"))
			end

			-- Test 1: Standard UnitDebuff("target")
			ATW.Print("---")
			ATW.Print("Method 1: UnitDebuff('target')")
			local i = 1
			local foundStandard = false
			while UnitDebuff("target", i) do
				local tex = UnitDebuff("target", i)
				if strfind(tex, "Ability_Gouge") then
					ATW.Print("  -> |cff00ff00FOUND|r at index " .. i .. ": " .. tex)
					foundStandard = true
				end
				i = i + 1
			end
			if not foundStandard then
				ATW.Print("  -> |cffff0000NOT FOUND|r (checked " .. (i-1) .. " debuffs)")
			end

			-- Test 2: UnitDebuff(guid) - SuperWoW
			if guid then
				ATW.Print("---")
				ATW.Print("Method 2: UnitDebuff(guid)")
				local ok, result = pcall(function()
					local j = 1
					local found = false
					while true do
						local tex = UnitDebuff(guid, j)
						if not tex then break end
						if strfind(tex, "Ability_Gouge") then
							ATW.Print("  -> |cff00ff00FOUND|r at index " .. j .. ": " .. tex)
							found = true
						end
						j = j + 1
					end
					return found, j - 1
				end)
				if ok then
					if not result then
						ATW.Print("  -> |cffff0000NOT FOUND|r")
					end
				else
					ATW.Print("  -> |cffff0000ERROR|r: " .. tostring(result))
				end
			end

			-- Test 3: RendTracker
			ATW.Print("---")
			ATW.Print("Method 3: RendTracker")
			if ATW.RendTracker then
				if guid then
					local hasTrack = ATW.RendTracker.HasRend(guid)
					local remaining = ATW.RendTracker.GetRendRemaining(guid)
					if hasTrack then
						ATW.Print("  -> |cff00ff00TRACKED|r (" .. string.format("%.1f", remaining) .. "s)")
					else
						ATW.Print("  -> |cffff0000NOT TRACKED|r")
					end
				else
					ATW.Print("  -> No GUID available")
				end
			else
				ATW.Print("  -> RendTracker not loaded")
			end

			-- Test 4: Combined ATW.HasRend
			ATW.Print("---")
			ATW.Print("Combined: ATW.HasRend")
			local hasRendTarget = ATW.HasRend and ATW.HasRend("target")
			ATW.Print("  HasRend('target') = " .. (hasRendTarget and "|cff00ff00TRUE|r" or "|cffff0000FALSE|r"))
			if guid then
				local hasRendGUID = ATW.HasRend and ATW.HasRend(guid)
				ATW.Print("  HasRend(guid) = " .. (hasRendGUID and "|cff00ff00TRUE|r" or "|cffff0000FALSE|r"))
			end

			-- Pending state
			ATW.Print("---")
			ATW.Print("Pending Rend:")
			if ATW.State and ATW.State.PendingRendGUID then
				local elapsed = GetTime() - (ATW.State.PendingRendTime or 0)
				ATW.Print("  GUID: " .. string.sub(ATW.State.PendingRendGUID, 1, 12) .. "...")
				ATW.Print("  Name: " .. (ATW.State.PendingRendName or "nil"))
				ATW.Print("  Elapsed: " .. string.format("%.1f", elapsed) .. "s")
			else
				ATW.Print("  (none)")
			end
		end

	elseif cmd == "cd" or cmd == "cooldowns" then
		-- Toggle cooldowns mode
		ATW.ToggleCooldowns()

	elseif cmd == "stance" then
		-- Show stance info
		ATW.DetectStances()
		ATW.Print("--- Stances ---")
		local current = ATW.Stance()
		local primary = AutoTurtleWarrior_Config.PrimaryStance
		local optimal = ATW.GetOptimalStance()

		for i = 1, 3 do
			local name = ATW.StanceNames[i]
			local available = ATW.AvailableStances[i] and "|cff00ff00YES|r" or "|cffff0000NO|r"
			local marker = ""
			if i == current then marker = marker .. " [CURRENT]" end
			if i == primary then marker = marker .. " [PRIMARY]" end
			if i == optimal then marker = marker .. " [OPTIMAL]" end
			ATW.Print(name .. ": " .. available .. marker)
		end

	elseif cmd == "show" or cmd == "hide" or cmd == "toggle" then
		-- Toggle display
		ATW.ToggleDisplay()

	elseif cmd == "lock" then
		-- Toggle frame lock
		ATW.ToggleLock()

	elseif cmd == "reset" then
		-- Reset display position
		ATW.ResetDisplayPosition()

	elseif strfind(cmd, "^scale") then
		-- Set scale: /atw scale 1.5
		local _, _, scale = strfind(cmd, "scale%s+([%d%.]+)")
		ATW.SetDisplayScale(scale)

	elseif cmd == "hp" or cmd == "health" then
		-- Debug HP detection
		ATW.Print("--- HP Debug ---")

		if not UnitExists("target") then
			ATW.Print("No target")
		else
			local name = UnitName("target")
			ATW.Print("Target: " .. (name or "nil"))

			-- Raw vanilla API
			local rawHP = UnitHealth("target")
			local rawMax = UnitHealthMax("target")
			ATW.Print("UnitHealth('target') = " .. tostring(rawHP))
			ATW.Print("UnitHealthMax('target') = " .. tostring(rawMax))

			if rawHP and rawMax and rawMax > 0 then
				ATW.Print("Calc: " .. rawHP .. "/" .. rawMax .. "*100 = " .. string.format("%.1f", (rawHP/rawMax)*100))
			end

			-- What GetHealthPercent returns
			ATW.Print("---")
			if ATW.GetHealthPercent then
				local result = ATW.GetHealthPercent("target")
				ATW.Print("GetHealthPercent('target') = " .. string.format("%.1f", result))

				-- Step through the logic manually
				if rawMax == 100 then
					ATW.Print("  -> max=100, returning hp directly: " .. tostring(rawHP))
				else
					ATW.Print("  -> max~=100, calculating: " .. string.format("%.1f", (rawHP/rawMax)*100))
				end
			end

			-- SuperWoW check
			ATW.Print("---")
			local hasSW = ATW.HasSuperWoW and ATW.HasSuperWoW()
			ATW.Print("SuperWoW: " .. (hasSW and "YES" or "NO"))

			if hasSW then
				local _, guid = UnitExists("target")
				ATW.Print("GUID: " .. (guid and string.sub(guid, 1, 20) or "nil"))
			end
		end

	elseif cmd == "mob" or cmd == "creature" then
		-- Show creature type detection for current target
		ATW.Print("--- Creature Detection ---")

		if not UnitExists("target") then
			ATW.Print("No target")
		else
			local name = UnitName("target")
			local creatureType = UnitCreatureType("target") or "Unknown"
			local classification = UnitClassification("target") or "normal"

			ATW.Print("Target: " .. name)
			ATW.Print("Type: " .. creatureType)
			ATW.Print("Class: " .. classification)

			-- Check bleed immunity
			if ATW.IsBleedImmune then
				local immune, _ = ATW.IsBleedImmune("target")
				if immune then
					ATW.Print("Bleed: |cffff0000IMMUNE|r")
				else
					ATW.Print("Bleed: |cff00ff00Can bleed|r")
				end
			end

			-- Show GUID if SuperWoW
			if ATW.HasSuperWoW and ATW.HasSuperWoW() then
				local _, guid = UnitExists("target")
				if guid then
					ATW.Print("GUID: " .. string.sub(guid, 1, 16) .. "...")
				end
			end
		end

		-- Show cache status
		ATW.Print("")
		if ATW.PrintCreatureTypeCache then
			ATW.PrintCreatureTypeCache()
		end

	else
		-- Help
		ATW.Print("Commands:")
		ATW.Print("  /atw - Run rotation")
		ATW.Print("  /atw toggle - Show/hide display")
		ATW.Print("  /atw lock - Lock/unlock for moving")
		ATW.Print("  /atw scale 1.5 - Set display scale")
		ATW.Print("  /atw cd - Toggle cooldowns")
		ATW.Print("  /atw prio - Show DPR priority list")
		ATW.Print("  /atw sim - Simulate next 5 abilities")
		ATW.Print("  /atw engine - Full combat simulation (20s)")
		ATW.Print("  /atw strat - Compare strategies")
		ATW.Print("  /atw rage - Show rage economy model")
		ATW.Print("  /atw rend - Show Rend decision (HP-based)")
		ATW.Print("  /atw rendtest - Debug Rend detection")
		ATW.Print("  /atw aoe - Show AoE analysis")
		ATW.Print("  /atw mob - Show creature type detection")
		ATW.Print("  /atw gear - Show set bonuses/trinkets")
		ATW.Print("  /atw spells - Show spell ranks")
		ATW.Print("  /atw stance | stats | ttd | swing")
	end
end

function ATW.RegisterCommands()
	SLASH_ATW1 = "/atw"
	SlashCmdList["ATW"] = ATW.HandleCommand
end
