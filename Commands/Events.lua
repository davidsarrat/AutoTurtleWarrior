--[[
	Auto Turtle Warrior - Commands/Events
	Event handling and initialization
]]--

---------------------------------------
-- Event Frame
---------------------------------------
local EventFrame = CreateFrame("Frame")
local TTD_UPDATE_INTERVAL = 0.25  -- Update TTD every 0.25s
local lastTTDUpdate = 0

EventFrame:RegisterEvent("VARIABLES_LOADED")
EventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
EventFrame:RegisterEvent("PLAYER_ENTER_COMBAT")
EventFrame:RegisterEvent("PLAYER_LEAVE_COMBAT")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
EventFrame:RegisterEvent("PLAYER_LEVEL_UP")
EventFrame:RegisterEvent("SPELLS_CHANGED")
EventFrame:RegisterEvent("CHARACTER_POINTS_CHANGED")  -- Talent points spent/refunded
EventFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
EventFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
EventFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
EventFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE")
EventFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE")
-- Rend periodic damage detection
EventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
-- Rend failure detection (out of range, etc.)
EventFrame:RegisterEvent("UI_ERROR_MESSAGE")
EventFrame:RegisterEvent("CHAT_MSG_SPELL_FAILED_LOCALPLAYER")
-- Stats updates
EventFrame:RegisterEvent("UNIT_AURA")
EventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
EventFrame:RegisterEvent("UNIT_ATTACK_POWER")
-- TTD updates
EventFrame:RegisterEvent("UNIT_HEALTH")
-- SuperWoW swing timer (more reliable than combat log)
EventFrame:RegisterEvent("UNIT_CASTEVENT")

---------------------------------------
-- Event Handler
---------------------------------------
EventFrame:SetScript("OnEvent", function()
	local state = ATW.State

	if event == "VARIABLES_LOADED" then
		-- Dependency check
		if not ATW.HasUnitXP() then
			ATW.Print("|cffff0000ERROR:|r UnitXP not found! Install UnitXP_SP3.")
			return
		end
		if not ATW.HasSuperWoW() then
			ATW.Print("|cffff0000ERROR:|r SuperWoW not found! Install SuperWoW.")
			return
		end

		-- Load config defaults
		for k, v in pairs(ATW.DEFAULT) do
			if AutoTurtleWarrior_Config[k] == nil then
				AutoTurtleWarrior_Config[k] = v
			end
		end

		-- Initialize
		ATW.LoadTalents()
		ATW.LoadSpells()  -- Detect spell ranks (Rend duration, etc.)
		ATW.LoadRacials()  -- Detect racial abilities (Blood Fury, Berserking, etc.)
		ATW.LoadAvailableAbilities()  -- Cache all available abilities
		ATW.AutoDetectPrimaryStance()
		ATW.UpdateStats()
		ATW.RegisterCommands()

		-- Initialize rage model
		if ATW.InitRageModel then
			ATW.InitRageModel()
		end

		-- Initialize UI
		ATW.InitDisplay()

		-- Show loaded message with stance info
		local stanceName = ATW.StanceNames[AutoTurtleWarrior_Config.PrimaryStance] or "None"
		ATW.Print("Loaded | Primary: " .. stanceName)

	elseif event == "PLAYER_TARGET_CHANGED" then
		state.Overpower = nil
		state.Interrupt = nil
		ATW.ResetTTD()
		ATW.LoadTalents()
		-- Learn creature type for bleed immunity detection
		if ATW.LearnTargetCreatureType then
			ATW.LearnTargetCreatureType()
		end

	elseif event == "PLAYER_ENTER_COMBAT" then
		state.Attacking = true

	elseif event == "PLAYER_LEAVE_COMBAT" then
		state.Attacking = nil

	elseif event == "PLAYER_REGEN_ENABLED" then
		state.Dancing = nil
		state.OldStance = nil

	elseif event == "PLAYER_LEVEL_UP" or event == "SPELLS_CHANGED" or event == "CHARACTER_POINTS_CHANGED" then
		-- Re-detect stances, talents, and spells when:
		-- - Leveling up (new spell ranks, more talent points)
		-- - Learning new spells
		-- - Spending/refunding talent points
		ATW.LoadTalents()
		ATW.LoadSpells()  -- Re-detect spell ranks (new Rend rank, etc.) + cache Rend values
		ATW.LoadRacials()  -- Re-detect racials (Blood Fury AP scales with level)
		ATW.LoadAvailableAbilities()  -- Re-cache all available abilities
		ATW.DetectStances()

	elseif event == "CHAT_MSG_COMBAT_SELF_HITS" then
		-- Track swing timer
		ATW.ParseCombatLogForSwing(arg1, event)

	elseif event == "CHAT_MSG_COMBAT_SELF_MISSES" then
		-- Detect dodge for Overpower
		-- In vanilla, ANY dodge enables Overpower on ANY target (global proc)
		if arg1 and strfind(arg1, "dodges") then
			state.Overpower = GetTime()
			-- Optional: track mob name for debug/advanced use
			if ATW.SetOverpowerProc then
				local _, _, name = strfind(arg1, "^(.+) dodges")
				ATW.SetOverpowerProc(name)
			end
		end
		-- Track swing timer
		ATW.ParseCombatLogForSwing(arg1, event)

	elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
		if arg1 then
			if strfind(arg1, "was dodged") then
				-- Ability was dodged - enables Overpower
				state.Overpower = GetTime()
				-- Optional: track mob name
				if ATW.SetOverpowerProc then
					local _, _, name = strfind(arg1, "was dodged by (.+)%.$")
					ATW.SetOverpowerProc(name)
				end
			elseif strfind(arg1, "Your Overpower") and strfind(arg1, "hits") then
				-- Overpower HIT - clear the proc and iteration state
				if ATW.OnOverpowerSuccess then
					ATW.OnOverpowerSuccess()
				else
					state.Overpower = nil
				end
			end
		end
		-- Track swing timer (for HS/Cleave)
		ATW.ParseCombatLogForSwing(arg1, event)

	elseif event == "CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE" or
	       event == "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE" then
		-- Detect enemy casting for interrupt
		if arg1 and strfind(arg1, "begins to cast") then
			for mob in string.gfind(arg1, "(.+) begins to cast") do
				if mob == UnitName("target") and UnitCanAttack("player", "target") then
					state.Interrupt = GetTime()
				end
				break
			end
		end

	elseif event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" then
		-- Detect Rend ticks to CONFIRM tracking
		if arg1 and ATW.ParseRendCombatLog then
			ATW.ParseRendCombatLog(arg1)
		end

	elseif event == "UI_ERROR_MESSAGE" then
		-- Detect cast failures (out of range, etc.) to cancel pending Rends
		if arg1 and ATW.ParseRendFailure then
			ATW.ParseRendFailure(arg1)
		end

	elseif event == "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" then
		-- Detect "You failed to cast X" messages
		if arg1 and ATW.ParseRendFailure then
			ATW.ParseRendFailure(arg1)
		end

	-- Stats updates
	elseif event == "UNIT_AURA" or event == "UNIT_ATTACK_POWER" then
		if arg1 == "player" then
			ATW.UpdateStats()
		end

	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		ATW.UpdateStats()

	-- TTD updates (target only via event)
	elseif event == "UNIT_HEALTH" then
		if arg1 == "target" then
			ATW.UpdateTargetTTD()
		end

	-- SuperWoW swing timer event (more reliable than combat log)
	-- arg1: casterGUID, arg2: targetGUID, arg3: eventType, arg4: spellID, arg5: duration
	-- eventType: "MAINHAND", "OFFHAND", "START", "CAST", "FAIL", "CHANNEL"
	elseif event == "UNIT_CASTEVENT" then
		if ATW.OnUnitCastEvent then
			ATW.OnUnitCastEvent(arg1, arg2, arg3, arg4, arg5)
		end
	end
end)

---------------------------------------
-- OnUpdate for TTD nameplate tracking
---------------------------------------
EventFrame:SetScript("OnUpdate", function()
	local now = GetTime()
	if now - lastTTDUpdate >= TTD_UPDATE_INTERVAL then
		ATW.UpdateAllTTD()
		lastTTDUpdate = now
	end
end)
