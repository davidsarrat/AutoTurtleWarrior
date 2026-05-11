--[[
	Auto Turtle Warrior - Commands/SlashCommands
	Slash command handling
]]--

local function InvalidateCommandCaches()
	if ATW.InvalidateDecisionCaches then
		ATW.InvalidateDecisionCaches()
	elseif ATW.InvalidateCooldownCache then
		ATW.InvalidateCooldownCache()
	end
end

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
		-- Show ALL detected spell ranks (what simulator can use)
		ATW.Print("--- Spells for Simulator ---")
		if ATW.Spells then
			local function showSpell(name, rankKey, learnedText)
				local rank = ATW.Spells[rankKey] or 0
				local status = rank > 0 and ("|cFF00FF00R" .. rank .. "|r") or "|cFFFF0000NOT LEARNED|r"
				ATW.Print("  " .. name .. ": " .. status .. (learnedText or ""))
			end

			ATW.Print("|cFFFFFF00Combat Abilities:|r")
			showSpell("Execute", "ExecuteRank")
			showSpell("Heroic Strike", "HeroicStrikeRank")
			showSpell("Cleave", "CleaveRank")
			showSpell("Overpower", "OverpowerRank")
			showSpell("Rend", "RendRank")
			showSpell("Whirlwind", "WhirlwindRank")
			showSpell("Slam", "SlamRank")

			ATW.Print("|cFFFFFF00Talent Abilities:|r")
			showSpell("Bloodthirst", "BloodthirstRank")
			showSpell("Mortal Strike", "MortalStrikeRank")
			showSpell("Sweeping Strikes", "SweepingStrikesRank")
			showSpell("Death Wish", "DeathWishRank")

			ATW.Print("|cFFFFFF00Utility:|r")
			showSpell("Battle Shout", "BattleShoutRank")
			showSpell("Charge", "ChargeRank")
			showSpell("Bloodrage", "BloodrageRank")
			showSpell("Berserker Rage", "BerserkerRageRank")
			showSpell("Pummel", "PummelRank")
			showSpell("Recklessness", "RecklessnessRank")

			ATW.Print("|cFFAAAAAASim will ONLY use learned spells!|r")
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

	elseif cmd == "trinkets" or cmd == "trinket" then
		-- Show trinket slots, on-use info, and shared internal CD
		if ATW.Trinkets and ATW.Trinkets.PrintState then
			ATW.Trinkets.PrintState()
		else
			ATW.Print("Trinkets module not loaded")
		end

	elseif cmd == "consumables" or cmd == "consum" then
		-- Show bag consumables (potions, healthstone, engineering items) and CDs
		if ATW.Consumables and ATW.Consumables.PrintState then
			ATW.Consumables.PrintState()
		else
			ATW.Print("Consumables module not loaded")
		end

	elseif cmd == "anticc" or cmd == "cc" then
		-- Show player debuffs and Berserker Rage readiness for fear breaking
		if ATW.AntiCC and ATW.AntiCC.PrintState then
			ATW.AntiCC.PrintState()
		else
			ATW.Print("AntiCC module not loaded")
		end

	elseif cmd == "rend" then
		-- Show Rend status via decision simulator
		if ATW.Engine and ATW.Engine.PrintDecisionDebug then
			ATW.Engine.PrintDecisionDebug()
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
		-- Show current CD status
		ATW.PrintCooldownStatus()

	elseif cmd == "sustain" then
		-- Set sustain mode (all CDs off)
		ATW.SetSustain()

	elseif cmd == "burst" then
		-- Toggle burst
		ATW.ToggleBurst()

	elseif strfind(cmd, "^burst%s+") then
		-- /atw burst on|off
		local _, _, arg = strfind(cmd, "^burst%s+(.+)")
		arg = strlower(arg or "")
		if arg == "on" then
			ATW.SetBurst(true)
		elseif arg == "off" then
			ATW.SetBurst(false)
		else
			ATW.Print("Usage: /atw burst [on|off]")
		end

	elseif cmd == "reckless" or cmd == "reck" then
		-- Toggle reckless
		ATW.ToggleReckless()

	elseif strfind(cmd, "^reckless%s+") or strfind(cmd, "^reck%s+") then
		-- /atw reckless on|off
		local _, _, arg = strfind(cmd, "^%S+%s+(.+)")
		arg = strlower(arg or "")
		if arg == "on" then
			ATW.SetReckless(true)
		elseif arg == "off" then
			ATW.SetReckless(false)
		else
			ATW.Print("Usage: /atw reckless [on|off]")
		end

	elseif cmd == "pummel" or cmd == "int" or cmd == "interrupt" then
		-- Toggle auto-interrupt
		ATW.TogglePummel()

	elseif strfind(cmd, "^pummel%s+") or strfind(cmd, "^int%s+") then
		-- /atw pummel on|off
		local _, _, arg = strfind(cmd, "^%S+%s+(.+)")
		arg = strlower(arg or "")
		if arg == "on" then
			ATW.SetPummel(true)
		elseif arg == "off" then
			ATW.SetPummel(false)
		else
			ATW.Print("Usage: /atw pummel [on|off]")
		end

	elseif cmd == "sync" or cmd == "cdsync" then
		-- Toggle CD sync (racials wait for Death Wish)
		if AutoTurtleWarrior_Config.SyncCooldowns == nil then
			AutoTurtleWarrior_Config.SyncCooldowns = ATW.DEFAULT.SyncCooldowns
		end
		AutoTurtleWarrior_Config.SyncCooldowns = not AutoTurtleWarrior_Config.SyncCooldowns
		if AutoTurtleWarrior_Config.SyncCooldowns then
			ATW.Print("CD Sync: |cff00ff00ON|r (racials wait for Death Wish)")
		else
			ATW.Print("CD Sync: |cffff9900OFF|r (use cooldowns independently)")
		end
		InvalidateCommandCaches()

	elseif strfind(cmd, "^sync%s+") or strfind(cmd, "^cdsync%s+") then
		-- /atw sync on|off
		local _, _, arg = strfind(cmd, "^%S+%s+(.+)")
		arg = strlower(arg or "")
		if arg == "on" then
			AutoTurtleWarrior_Config.SyncCooldowns = true
			ATW.Print("CD Sync: |cff00ff00ON|r (racials wait for Death Wish)")
		elseif arg == "off" then
			AutoTurtleWarrior_Config.SyncCooldowns = false
			ATW.Print("CD Sync: |cffff9900OFF|r (use cooldowns independently)")
		else
			ATW.Print("Usage: /atw sync [on|off]")
		end
		InvalidateCommandCaches()

	elseif cmd == "bloodragecd" or cmd == "brcd" then
		-- Toggle Bloodrage CD mode (treat as burst cooldown)
		if AutoTurtleWarrior_Config.BloodrageBurstMode == nil then
			AutoTurtleWarrior_Config.BloodrageBurstMode = ATW.DEFAULT.BloodrageBurstMode
		end
		AutoTurtleWarrior_Config.BloodrageBurstMode = not AutoTurtleWarrior_Config.BloodrageBurstMode
		if AutoTurtleWarrior_Config.BloodrageBurstMode then
			ATW.Print("Bloodrage CD: |cff00ff00ON|r (soft-sync with DW, rage economy priority)")
		else
			ATW.Print("Bloodrage CD: |cffff9900OFF|r (use on CD for rage)")
		end
		InvalidateCommandCaches()

	elseif strfind(cmd, "^bloodragecd%s+") or strfind(cmd, "^brcd%s+") then
		-- /atw bloodragecd on|off
		local _, _, arg = strfind(cmd, "^%S+%s+(.+)")
		arg = strlower(arg or "")
		if arg == "on" then
			AutoTurtleWarrior_Config.BloodrageBurstMode = true
			ATW.Print("Bloodrage CD: |cff00ff00ON|r (soft-sync with DW, rage economy priority)")
		elseif arg == "off" then
			AutoTurtleWarrior_Config.BloodrageBurstMode = false
			ATW.Print("Bloodrage CD: |cffff9900OFF|r (use on CD for rage)")
		else
			ATW.Print("Usage: /atw bloodragecd [on|off]")
		end
		InvalidateCommandCaches()

	elseif cmd == "brcombat" or cmd == "bloodragecombat" then
		-- Toggle Bloodrage combat-only mode
		if AutoTurtleWarrior_Config.BloodrageCombatOnly == nil then
			AutoTurtleWarrior_Config.BloodrageCombatOnly = ATW.DEFAULT.BloodrageCombatOnly
		end
		AutoTurtleWarrior_Config.BloodrageCombatOnly = not AutoTurtleWarrior_Config.BloodrageCombatOnly
		if AutoTurtleWarrior_Config.BloodrageCombatOnly then
			ATW.Print("Bloodrage Combat: |cff00ff00ON|r (only in combat)")
		else
			ATW.Print("Bloodrage Combat: |cffff9900OFF|r (can use out of combat)")
		end
		InvalidateCommandCaches()

	elseif strfind(cmd, "^brcombat%s+") or strfind(cmd, "^bloodragecombat%s+") then
		-- /atw brcombat on|off
		local _, _, arg = strfind(cmd, "^%S+%s+(.+)")
		arg = strlower(arg or "")
		if arg == "on" then
			AutoTurtleWarrior_Config.BloodrageCombatOnly = true
			ATW.Print("Bloodrage Combat: |cff00ff00ON|r (only in combat)")
		elseif arg == "off" then
			AutoTurtleWarrior_Config.BloodrageCombatOnly = false
			ATW.Print("Bloodrage Combat: |cffff9900OFF|r (can use out of combat)")
		else
			ATW.Print("Usage: /atw brcombat [on|off]")
		end
		InvalidateCommandCaches()

	elseif cmd == "aoemode" or cmd == "aoetoggle" then
		-- Toggle AoE mode (auto vs single target)
		if AutoTurtleWarrior_Config.AoEEnabled == nil then
			AutoTurtleWarrior_Config.AoEEnabled = ATW.DEFAULT.AoEEnabled
		end
		AutoTurtleWarrior_Config.AoEEnabled = not AutoTurtleWarrior_Config.AoEEnabled
		if AutoTurtleWarrior_Config.AoEEnabled then
			ATW.Print("AoE Mode: |cff00ff00AUTO|r (WW/Cleave based on enemy count)")
		else
			ATW.Print("AoE Mode: |cffff9900SINGLE TARGET|r (funnel mode)")
		end
		InvalidateCommandCaches()

	elseif strfind(cmd, "^aoemode%s+") or strfind(cmd, "^aoetoggle%s+") then
		-- /atw aoemode on|off
		local _, _, arg = strfind(cmd, "^%S+%s+(.+)")
		arg = strlower(arg or "")
		if arg == "on" or arg == "auto" then
			AutoTurtleWarrior_Config.AoEEnabled = true
			ATW.Print("AoE Mode: |cff00ff00AUTO|r (WW/Cleave based on enemy count)")
		elseif arg == "off" or arg == "st" or arg == "single" then
			AutoTurtleWarrior_Config.AoEEnabled = false
			ATW.Print("AoE Mode: |cffff9900SINGLE TARGET|r (funnel mode)")
		else
			ATW.Print("Usage: /atw aoemode [on|off|auto|st]")
		end
		InvalidateCommandCaches()

	elseif cmd == "rendspread" or cmd == "spread" then
		-- Toggle Rend spreading
		if AutoTurtleWarrior_Config.RendSpread == nil then
			AutoTurtleWarrior_Config.RendSpread = ATW.DEFAULT.RendSpread
		end
		AutoTurtleWarrior_Config.RendSpread = not AutoTurtleWarrior_Config.RendSpread
		if AutoTurtleWarrior_Config.RendSpread then
			ATW.Print("Rend Spread: |cff00ff00ON|r (spread to multiple targets)")
		else
			ATW.Print("Rend Spread: |cffff9900OFF|r (main target only)")
		end
		InvalidateCommandCaches()

	elseif strfind(cmd, "^rendspread%s+") or strfind(cmd, "^spread%s+") then
		-- /atw rendspread on|off
		local _, _, arg = strfind(cmd, "^%S+%s+(.+)")
		arg = strlower(arg or "")
		if arg == "on" then
			AutoTurtleWarrior_Config.RendSpread = true
			ATW.Print("Rend Spread: |cff00ff00ON|r (spread to multiple targets)")
		elseif arg == "off" then
			AutoTurtleWarrior_Config.RendSpread = false
			ATW.Print("Rend Spread: |cffff9900OFF|r (main target only)")
		else
			ATW.Print("Usage: /atw rendspread [on|off]")
		end
		InvalidateCommandCaches()

	elseif cmd == "casts" or cmd == "casting" then
		-- Show casting enemies (debug)
		ATW.PrintCastingEnemies()

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

	elseif cmd == "timeline" or cmd == "tl" then
		-- Toggle timeline display
		ATW.ToggleTimeline()

	elseif cmd == "tlreset" then
		-- Reset timeline position
		ATW.ResetTimelinePosition()

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

	elseif cmd == "op" or cmd == "overpower" then
		-- Debug Overpower status
		ATW.Print("--- Overpower Debug ---")

		local state = ATW.State or {}

		if state.Overpower then
			local windowRemaining = 4 - (GetTime() - state.Overpower)
			if windowRemaining > 0 then
				ATW.Print("Status: |cff00ff00AVAILABLE|r")
				ATW.Print("Window: " .. string.format("%.1f", windowRemaining) .. "s remaining")
			else
				ATW.Print("Status: |cffff0000EXPIRED|r")
			end
		else
			ATW.Print("Status: |cffff9900NOT ACTIVE|r (no dodge detected)")
		end

		-- Show tracked mob info (optional advanced tracking)
		if state.OverpowerTarget then
			ATW.Print("Last dodge from: " .. state.OverpowerTarget)
			if state.OverpowerGUID then
				ATW.Print("GUID: " .. string.sub(state.OverpowerGUID, 1, 16))
			end
		end

		-- Current stance
		local stance = ATW.Stance and ATW.Stance() or 0
		local stanceName = ATW.StanceNames and ATW.StanceNames[stance] or "Unknown"
		local inBattle = (stance == 1)
		ATW.Print("Stance: " .. stanceName .. (inBattle and " |cff00ff00(can OP)|r" or " |cffff9900(need dance)|r"))

		-- Rage check
		local rage = UnitMana("player") or 0
		local opCost = 5
		local danceRage = AutoTurtleWarrior_Config and AutoTurtleWarrior_Config.DanceRage or 10
		local totalNeeded = inBattle and opCost or (opCost + danceRage)
		local canUse = rage >= totalNeeded
		ATW.Print("Rage: " .. rage .. "/" .. totalNeeded .. (canUse and " |cff00ff00OK|r" or " |cffff0000LOW|r"))

		-- Note about mechanics
		ATW.Print("")
		ATW.Print("|cff888888Note: In vanilla, Overpower works on|r")
		ATW.Print("|cff888888ANY target after a dodge (global proc)|r")

	elseif cmd == "decision" or cmd == "dec" then
		-- Debug decision simulator
		if ATW.Engine and ATW.Engine.PrintDecisionDebug then
			ATW.Engine.PrintDecisionDebug()
		else
			ATW.Print("Decision simulator not loaded")
		end

	elseif cmd == "racial" or cmd == "race" then
		-- Show racial info
		ATW.Print("--- Racial Abilities ---")
		if not ATW.Racials then
			ATW.Print("|cffff0000Racials not loaded (use /reload)|r")
		else
			local _, race = UnitRace("player")
			ATW.Print("Race: |cff00ff00" .. (race or "Unknown") .. "|r")

			-- Blood Fury (Orc)
			if ATW.Racials.HasBloodFury then
				local apBonus = ATW.GetBloodFuryAP and ATW.GetBloodFuryAP() or 0
				local ready = ATW.IsRacialReady and ATW.IsRacialReady("Blood Fury")
				local status = ready and "|cff00ff00READY|r" or "|cffff0000ON CD|r"
				ATW.Print("Blood Fury: " .. status .. " (+|cffff8800" .. apBonus .. " AP|r for 15s)")
			end

			-- Berserking (Troll)
			if ATW.Racials.HasBerserking then
				local haste = ATW.GetBerserkingHaste and ATW.GetBerserkingHaste() or 10
				local ready = ATW.IsRacialReady and ATW.IsRacialReady("Berserking")
				local status = ready and "|cff00ff00READY|r" or "|cffff0000ON CD|r"
				ATW.Print("Berserking: " .. status .. " (|cff00ffff" .. haste .. "% haste|r for 10s, 5 rage)")
			end

			-- Perception (Human)
			if ATW.Racials.HasPerception then
				local ready = ATW.IsRacialReady and ATW.IsRacialReady("Perception")
				local status = ready and "|cff00ff00READY|r" or "|cffff0000ON CD|r"
				ATW.Print("Perception: " .. status .. " (|cffffcc00+2% crit|r for 20s)")
			end

			-- Weapon skill bonus
			if ATW.Racials.WeaponSkillBonus and ATW.Racials.WeaponSkillBonus > 0 then
				local weapons = {}
				if ATW.Racials.HasSwordSpec then table.insert(weapons, "Swords") end
				if ATW.Racials.HasMaceSpec then table.insert(weapons, "Maces") end
				if ATW.Racials.HasAxeSpec then table.insert(weapons, "Axes") end
				ATW.Print("Weapon Skill: |cff00ff00+" .. ATW.Racials.WeaponSkillBonus .. "|r (" .. table.concat(weapons, ", ") .. ")")
			end

			-- No combat racials
			if not ATW.Racials.HasBloodFury and not ATW.Racials.HasBerserking and not ATW.Racials.HasPerception then
				ATW.Print("|cff888888No combat racials for " .. (race or "this race") .. "|r")
			end
		end

	elseif strfind(cmd, "^spellid%s+") or strfind(cmd, "^spell%s+") then
		-- Debug: show spell ID and cooldown info for a spell
		local _, _, spellName = strfind(cmd, "^spell[id]*%s+(.+)")
		if spellName then
			ATW.Print("=== Spell Debug: " .. spellName .. " ===")

			-- Find all spells with this name in spellbook
			local foundCount = 0
			local id = 1
			for t = 1, GetNumSpellTabs() do
				local tabName, _, _, n = GetSpellTabInfo(t)
				for s = 1, n do
					local name, rank = GetSpellName(id, BOOKTYPE_SPELL)
					if name == spellName then
						foundCount = foundCount + 1
						local start, dur, enabled = GetSpellCooldown(id, 0)
						local cdRemaining = 0
						if start and start > 0 and dur and dur > 0 then
							cdRemaining = (start + dur) - GetTime()
						end
						ATW.Print("  [" .. foundCount .. "] Tab: " .. tabName .. ", ID: " .. id)
						ATW.Print("      Rank: " .. (rank or "none"))
						ATW.Print("      CD: start=" .. (start or "nil") .. ", dur=" .. (dur or "nil"))
						ATW.Print("      Remaining: " .. string.format("%.1f", cdRemaining) .. "s")
					end
					id = id + 1
				end
			end

			if foundCount == 0 then
				ATW.Print("|cffff0000Spell not found in spellbook|r")
			end

			-- Show what our functions return
			local ourID = ATW.SpellID and ATW.SpellID(spellName)
			local ourReady = ATW.Ready and ATW.Ready(spellName)
			local ourCD = ATW.GetCooldownRemaining and ATW.GetCooldownRemaining(spellName)
			ATW.Print("  ATW.SpellID: " .. (ourID or "nil"))
			ATW.Print("  ATW.Ready: " .. tostring(ourReady))
			ATW.Print("  ATW.GetCooldownRemaining: " .. (ourCD or "nil") .. "ms")
		end

	elseif cmd == "cache" then
		-- Show cache statistics
		if ATW.Engine and ATW.Engine.Cache then
			local cache = ATW.Engine.Cache
			ATW.Print("=== Engine Cache Stats ===")
			ATW.Print("Cache hits: |cff00ff00" .. (cache.hits or 0) .. "|r")
			ATW.Print("Cache misses: |cffff8800" .. (cache.misses or 0) .. "|r")
			local total = (cache.hits or 0) + (cache.misses or 0)
			if total > 0 then
				local hitRate = (cache.hits or 0) / total * 100
				ATW.Print("Hit rate: |cff00ffff" .. string.format("%.1f%%", hitRate) .. "|r")
			end
			ATW.Print("Min interval: " .. (cache.MIN_UPDATE_INTERVAL or 0) .. "ms")
			if cache.lastUpdateTime and cache.lastUpdateTime > 0 then
				local age = (GetTime() * 1000) - cache.lastUpdateTime
				ATW.Print("Last update: " .. string.format("%.0f", age) .. "ms ago")
			end
		else
			ATW.Print("Engine cache not available")
		end

	elseif cmd == "resetcache" then
		-- Reset cache statistics
		if ATW.Engine and ATW.Engine.Cache then
			ATW.Engine.Cache.hits = 0
			ATW.Engine.Cache.misses = 0
			ATW.Engine.Cache.lastState = nil
			ATW.Engine.Cache.lastResult = nil
			ATW.Print("Cache reset")
		end

	elseif cmd == "has" or cmd == "abilities" then
		-- Show cached available abilities
		if not ATW.Has then
			ATW.Print("|cffff0000Abilities not cached (use /reload)|r")
		else
			ATW.Print("=== Available Abilities (Cached) ===")

			-- Talents
			local talents = {}
			if ATW.Has.Bloodthirst then table.insert(talents, "BT") end
			if ATW.Has.MortalStrike then table.insert(talents, "MS") end
			if ATW.Has.DeathWish then table.insert(talents, "DW") end
			if ATW.Has.SweepingStrikes then table.insert(talents, "SS") end
			ATW.Print("Talents: " .. (table.getn(talents) > 0 and table.concat(talents, ", ") or "|cff888888none|r"))

			-- Core abilities
			local core = {}
			if ATW.Has.Execute then table.insert(core, "Exec") end
			if ATW.Has.Whirlwind then table.insert(core, "WW") end
			if ATW.Has.Overpower then table.insert(core, "OP") end
			if ATW.Has.Rend then table.insert(core, "Rend") end
			if ATW.Has.Slam then table.insert(core, "Slam") end
			ATW.Print("Core: " .. table.concat(core, ", "))

			-- Utility
			local util = {}
			if ATW.Has.Charge then table.insert(util, "Charge") end
			if ATW.Has.Bloodrage then table.insert(util, "BR") end
			if ATW.Has.BerserkerRage then table.insert(util, "BsR") end
			if ATW.Has.Recklessness then table.insert(util, "Reck") end
			if ATW.Has.Pummel then table.insert(util, "Pummel") end
			ATW.Print("Utility: " .. (table.getn(util) > 0 and table.concat(util, ", ") or "|cff888888none|r"))

			-- Racials
			local racials = {}
			if ATW.Has.BloodFury then table.insert(racials, "|cffff0000Blood Fury|r") end
			if ATW.Has.Berserking then table.insert(racials, "|cff00ff00Berserking|r") end
			if ATW.Has.Perception then table.insert(racials, "|cff0088ffPerception|r") end
			ATW.Print("Racials: " .. (table.getn(racials) > 0 and table.concat(racials, ", ") or "|cff888888none|r"))
		end

	elseif cmd == "horizon" then
		-- Show current horizon
		local horizon = ATW.Engine and ATW.Engine.GetHorizon() or 30000
		ATW.Print("Decision horizon: |cff00ff00" .. (horizon / 1000) .. "s|r (" .. math.floor(horizon / 1500) .. " GCDs)")
		ATW.Print("Usage: /atw horizon <seconds>")

	elseif strfind(cmd, "^horizon%s+") then
		-- Set horizon: /atw horizon 30
		local _, _, seconds = strfind(cmd, "^horizon%s+([%d%.]+)")
		if seconds then
			seconds = tonumber(seconds)
			if seconds and seconds >= 3 and seconds <= 120 then
				local horizonMs = seconds * 1000
				AutoTurtleWarrior_Config.DecisionHorizon = horizonMs
				-- Reset cache to use new horizon
				if ATW.Engine and ATW.Engine.Cache then
					ATW.Engine.Cache.lastState = nil
					ATW.Engine.Cache.lastResult = nil
				end
				InvalidateCommandCaches()
				ATW.Print("Decision horizon set to |cff00ff00" .. seconds .. "s|r (" .. math.floor(seconds / 1.5) .. " GCDs)")
			else
				ATW.Print("|cffff0000Invalid horizon. Range: 3-120 seconds|r")
			end
		else
			ATW.Print("Usage: /atw horizon <seconds>")
		end

	else
		-- Help
		ATW.Print("Commands:")
		ATW.Print("  /atw - Run rotation")
		ATW.Print("--- Toggles ---")
		ATW.Print("  /atw cd - Show cooldown status")
		ATW.Print("  /atw burst [on|off] - Toggle DW + Racials")
		ATW.Print("  /atw reck [on|off] - Toggle Recklessness")
		ATW.Print("  /atw sustain - Disable all CDs")
		ATW.Print("  /atw sync [on|off] - Racials wait for DW")
		ATW.Print("  /atw bloodragecd [on|off] - Bloodrage as burst CD")
		ATW.Print("  /atw brcombat [on|off] - Bloodrage in combat only")
		ATW.Print("  /atw pummel [on|off] - Auto-interrupt")
		ATW.Print("  /atw aoemode [on|off] - AoE/single target")
		ATW.Print("  /atw rendspread [on|off] - Rend spreading")
		ATW.Print("--- Simulation ---")
		ATW.Print("  /atw decision - Debug tactical decisions")
		ATW.Print("  /atw horizon [sec] - Set decision window (3-120s)")
		ATW.Print("  /atw cache - Show cache statistics")
		ATW.Print("  /atw sim - Simulate next 5 abilities")
		ATW.Print("  /atw engine - Full combat simulation")
		ATW.Print("--- Debug ---")
		ATW.Print("  /atw aoe - AoE/Rend strategy analysis")
		ATW.Print("  /atw rend - Rend decision debug")
		ATW.Print("  /atw racial - Racial abilities")
		ATW.Print("  /atw spells | gear | mob | has")
		ATW.Print("  /atw stance | stats | ttd | swing | op")
	end
end

function ATW.RegisterCommands()
	SLASH_ATW1 = "/atw"
	SlashCmdList["ATW"] = ATW.HandleCommand
end
