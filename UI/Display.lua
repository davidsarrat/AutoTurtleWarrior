--[[
	Auto Turtle Warrior - UI/Display
	Comprehensive visual display with detailed feedback

	Layout:
	+------------------------------------------+
	|  [ICON]  ABILITY NAME                    |
	|          Reason: why this ability        |
	|  [====== Swing Timer ======]             |
	|  [====== Rage Bar ========] 45/100       |
	|  Status: Execute | Pooling | AoE: 3      |
	|  Target: 75% HP | TTD: 25s | Beast       |
	|  Queue: BT > WW > HS                     |
	+------------------------------------------+
]]--

ATW.UI = {
	frame = nil,
	elements = {},
	updateInterval = 0.02,  -- 20ms for responsive feedback
	lastUpdate = 0,
	isLocked = true,

	-- Colors
	colors = {
		background = {0, 0, 0, 0.85},
		border = {0.4, 0.4, 0.4, 1},
		borderUnlocked = {0, 1, 0, 1},

		-- Ability colors
		normal = {1, 1, 1, 1},
		execute = {1, 0.2, 0.2, 1},
		pooling = {1, 0.6, 0, 1},
		stanceDance = {1, 0.8, 0, 1},
		cooldown = {0.5, 0.5, 0.5, 1},

		-- Bar colors
		rage = {0.8, 0.2, 0.2, 1},
		rageLow = {0.4, 0.1, 0.1, 1},
		rageHigh = {1, 0.3, 0.3, 1},
		swing = {0.3, 0.7, 0.3, 1},
		swingQueued = {0.2, 0.5, 0.8, 1},

		-- Status colors
		statusGood = {0.2, 1, 0.2, 1},
		statusBad = {1, 0.2, 0.2, 1},
		statusNeutral = {0.7, 0.7, 0.7, 1},
		statusWarning = {1, 0.6, 0, 1},

		-- Text colors
		textWhite = {1, 1, 1, 1},
		textGray = {0.6, 0.6, 0.6, 1},
		textGold = {1, 0.82, 0, 1},
	},

	-- Layout
	width = 220,
	height = 140,
	iconSize = 48,
	padding = 8,
	barHeight = 12,
}

---------------------------------------
-- Get spell icon texture
---------------------------------------
local function GetSpellIcon(spellName)
	if not spellName then return nil end
	local id = ATW.SpellID(spellName)
	if id then
		return GetSpellTexture(id, BOOKTYPE_SPELL)
	end
	return nil
end

---------------------------------------
-- Create a status bar
---------------------------------------
local function CreateStatusBar(parent, name, width, height)
	local bar = CreateFrame("Frame", name, parent)
	bar:SetWidth(width)
	bar:SetHeight(height)

	-- Background
	bar.bg = bar:CreateTexture(nil, "BACKGROUND")
	bar.bg:SetAllPoints(bar)
	bar.bg:SetTexture(0.1, 0.1, 0.1, 0.8)

	-- Fill
	bar.fill = bar:CreateTexture(nil, "ARTWORK")
	bar.fill:SetPoint("LEFT", bar, "LEFT", 0, 0)
	bar.fill:SetHeight(height)
	bar.fill:SetWidth(0)
	bar.fill:SetTexture(1, 1, 1, 1)

	-- Marker (optional threshold indicator)
	bar.marker = bar:CreateTexture(nil, "OVERLAY")
	bar.marker:SetWidth(2)
	bar.marker:SetHeight(height + 2)
	bar.marker:SetTexture(1, 1, 0, 0.8)
	bar.marker:Hide()

	-- Text
	bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	bar.text:SetPoint("RIGHT", bar, "RIGHT", -2, 0)
	bar.text:SetTextColor(1, 1, 1, 1)

	function bar:SetValue(current, max, color)
		if max <= 0 then max = 1 end
		local pct = current / max
		if pct > 1 then pct = 1 end
		if pct < 0 then pct = 0 end

		self.fill:SetWidth(self:GetWidth() * pct)
		if color then
			self.fill:SetTexture(color[1], color[2], color[3], color[4] or 1)
		end
	end

	function bar:SetMarker(pct)
		if pct and pct > 0 and pct < 1 then
			self.marker:SetPoint("LEFT", self, "LEFT", self:GetWidth() * pct, 0)
			self.marker:Show()
		else
			self.marker:Hide()
		end
	end

	return bar
end

---------------------------------------
-- Create the main display frame
---------------------------------------
function ATW.CreateDisplay()
	if ATW.UI.frame then return end

	local cfg = AutoTurtleWarrior_Config
	local UI = ATW.UI
	local colors = UI.colors

	-- Main container
	local frame = CreateFrame("Frame", "ATWDisplay", UIParent)
	frame:SetWidth(UI.width)
	frame:SetHeight(UI.height)
	frame:SetPoint("CENTER", UIParent, "CENTER", cfg.DisplayX or 0, cfg.DisplayY or -150)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:SetClampedToScreen(true)
	frame:SetFrameStrata("MEDIUM")

	-- Background
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 2, right = 2, top = 2, bottom = 2 }
	})
	frame:SetBackdropColor(colors.background[1], colors.background[2], colors.background[3], colors.background[4])
	frame:SetBackdropBorderColor(colors.border[1], colors.border[2], colors.border[3], colors.border[4])

	-- Drag functionality
	frame:SetScript("OnMouseDown", function()
		if not UI.isLocked and arg1 == "LeftButton" then
			this:StartMoving()
		end
	end)
	frame:SetScript("OnMouseUp", function()
		this:StopMovingOrSizing()
		local _, _, _, x, y = this:GetPoint()
		AutoTurtleWarrior_Config.DisplayX = x
		AutoTurtleWarrior_Config.DisplayY = y
	end)

	local elements = {}
	local yPos = -UI.padding

	---------------------------------------
	-- Row 1: Main ability icon + name + reason
	---------------------------------------

	-- Icon frame
	local iconFrame = CreateFrame("Frame", "ATWMainIcon", frame)
	iconFrame:SetWidth(UI.iconSize)
	iconFrame:SetHeight(UI.iconSize)
	iconFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.padding, yPos)

	-- Icon texture
	iconFrame.icon = iconFrame:CreateTexture(nil, "ARTWORK")
	iconFrame.icon:SetAllPoints(iconFrame)
	iconFrame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	-- Icon border
	iconFrame.border = iconFrame:CreateTexture(nil, "OVERLAY")
	iconFrame.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	iconFrame.border:SetBlendMode("ADD")
	iconFrame.border:SetWidth(UI.iconSize * 1.4)
	iconFrame.border:SetHeight(UI.iconSize * 1.4)
	iconFrame.border:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)

	-- Cooldown overlay
	iconFrame.cooldown = iconFrame:CreateTexture(nil, "OVERLAY")
	iconFrame.cooldown:SetAllPoints(iconFrame)
	iconFrame.cooldown:SetTexture(0, 0, 0, 0.6)
	iconFrame.cooldown:Hide()

	-- GCD spark (shows when on GCD)
	iconFrame.gcdSpark = iconFrame:CreateTexture(nil, "OVERLAY")
	iconFrame.gcdSpark:SetTexture(1, 1, 1, 0.8)
	iconFrame.gcdSpark:SetWidth(UI.iconSize)
	iconFrame.gcdSpark:SetHeight(3)
	iconFrame.gcdSpark:SetPoint("BOTTOM", iconFrame, "BOTTOM", 0, 0)
	iconFrame.gcdSpark:Hide()

	elements.icon = iconFrame

	-- Ability name (big, bold)
	local abilityName = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	abilityName:SetPoint("TOPLEFT", iconFrame, "TOPRIGHT", 6, -2)
	abilityName:SetPoint("RIGHT", frame, "RIGHT", -UI.padding, 0)
	abilityName:SetJustifyH("LEFT")
	abilityName:SetTextColor(1, 1, 1, 1)
	abilityName:SetText("Waiting...")
	elements.abilityName = abilityName

	-- Reason text (smaller, below name)
	local reasonText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	reasonText:SetPoint("TOPLEFT", abilityName, "BOTTOMLEFT", 0, -2)
	reasonText:SetPoint("RIGHT", frame, "RIGHT", -UI.padding, 0)
	reasonText:SetJustifyH("LEFT")
	reasonText:SetTextColor(colors.textGray[1], colors.textGray[2], colors.textGray[3], 1)
	reasonText:SetText("")
	elements.reasonText = reasonText

	-- State badge (Execute/Pooling/etc)
	local stateBadge = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	stateBadge:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -UI.padding, -UI.padding)
	stateBadge:SetJustifyH("RIGHT")
	stateBadge:SetText("")
	elements.stateBadge = stateBadge

	yPos = yPos - UI.iconSize - 6

	---------------------------------------
	-- Row 2: Swing Timer Bar
	---------------------------------------
	local swingLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	swingLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.padding, yPos)
	swingLabel:SetText("Swing")
	swingLabel:SetTextColor(colors.textGray[1], colors.textGray[2], colors.textGray[3], 1)

	local swingBar = CreateStatusBar(frame, "ATWSwingBar", UI.width - UI.padding * 2 - 35, UI.barHeight)
	swingBar:SetPoint("LEFT", swingLabel, "RIGHT", 4, 0)
	swingBar.text:SetText("")
	elements.swingBar = swingBar
	elements.swingLabel = swingLabel

	yPos = yPos - UI.barHeight - 4

	---------------------------------------
	-- Row 3: Rage Bar
	---------------------------------------
	local rageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	rageLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.padding, yPos)
	rageLabel:SetText("Rage")
	rageLabel:SetTextColor(colors.textGray[1], colors.textGray[2], colors.textGray[3], 1)

	local rageBar = CreateStatusBar(frame, "ATWRageBar", UI.width - UI.padding * 2 - 35, UI.barHeight)
	rageBar:SetPoint("LEFT", rageLabel, "RIGHT", 4, 0)
	elements.rageBar = rageBar
	elements.rageLabel = rageLabel

	yPos = yPos - UI.barHeight - 6

	---------------------------------------
	-- Row 4: Status line (AoE count, Rend, etc)
	---------------------------------------
	local statusLine = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	statusLine:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.padding, yPos)
	statusLine:SetPoint("RIGHT", frame, "RIGHT", -UI.padding, 0)
	statusLine:SetJustifyH("LEFT")
	statusLine:SetText("")
	elements.statusLine = statusLine

	yPos = yPos - 14

	---------------------------------------
	-- Row 5: Target info line
	---------------------------------------
	local targetLine = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	targetLine:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.padding, yPos)
	targetLine:SetPoint("RIGHT", frame, "RIGHT", -UI.padding, 0)
	targetLine:SetJustifyH("LEFT")
	targetLine:SetTextColor(colors.textGray[1], colors.textGray[2], colors.textGray[3], 1)
	targetLine:SetText("")
	elements.targetLine = targetLine

	yPos = yPos - 14

	---------------------------------------
	-- Row 6: Ability queue
	---------------------------------------
	local queueLine = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	queueLine:SetPoint("TOPLEFT", frame, "TOPLEFT", UI.padding, yPos)
	queueLine:SetPoint("RIGHT", frame, "RIGHT", -UI.padding, 0)
	queueLine:SetJustifyH("LEFT")
	queueLine:SetTextColor(colors.textGold[1], colors.textGold[2], colors.textGold[3], 1)
	queueLine:SetText("")
	elements.queueLine = queueLine

	-- Adjust frame height
	frame:SetHeight(-yPos + UI.padding + 4)

	-- Store references
	UI.frame = frame
	UI.elements = elements

	-- Update script
	frame:SetScript("OnUpdate", function()
		local now = GetTime()
		if now - UI.lastUpdate >= UI.updateInterval then
			ATW.UpdateDisplay()
			UI.lastUpdate = now
		end
	end)

	-- Initial visibility
	if cfg.ShowDisplay == false then
		frame:Hide()
	else
		frame:Show()
	end
end

---------------------------------------
-- Get ability display info
---------------------------------------
local function GetAbilityInfo()
	-- Try to get recommendation from Engine
	if ATW.Engine and ATW.Engine.GetRecommendation then
		local ok, abilityName, isOffGCD, pooling, timeToExec, targetGUID, targetStance = pcall(ATW.Engine.GetRecommendation)
		if ok and abilityName then
			return {
				name = abilityName,
				isOffGCD = isOffGCD,
				pooling = pooling,
				timeToExec = timeToExec,
				targetGUID = targetGUID,
				targetStance = targetStance,
			}
		end
	end

	-- Fallback to simulator
	if ATW.GetNextAbility then
		local abilityName, isStanceSwitch, targetStance, targetGUID = ATW.GetNextAbility()
		if abilityName then
			return {
				name = abilityName,
				isStanceSwitch = isStanceSwitch,
				targetStance = targetStance,
				targetGUID = targetGUID,
			}
		end
	end

	return nil
end

---------------------------------------
-- Get reason text for ability
---------------------------------------
local function GetAbilityReason(info)
	if not info then return "" end

	local ability = ATW.Abilities and ATW.Abilities[info.name]
	local reasons = {}

	-- Pooling for execute
	if info.pooling and info.timeToExec and info.timeToExec > 0 then
		return "Pooling for Execute (" .. string.format("%.0f", info.timeToExec) .. "s)"
	end

	-- Stance switch action
	if info.isStanceSwitch and info.targetStance then
		local stanceNames = {[1] = "Battle", [2] = "Defensive", [3] = "Berserker"}
		local stanceName = stanceNames[info.targetStance] or "?"
		return "Switch to " .. stanceName .. " Stance"
	end

	-- Execute phase
	if info.name == "Execute" then
		return "Target below 20% HP"
	end

	-- Bloodthirst
	if info.name == "Bloodthirst" then
		return "Main damage ability (45% AP)"
	end

	-- Whirlwind
	if info.name == "Whirlwind" then
		local count = ATW.EnemyCount and ATW.EnemyCount(8) or 1
		if count > 1 then
			return "AoE damage (" .. count .. " targets)"
		end
		return "Filler ability"
	end

	-- Heroic Strike / Cleave
	if info.name == "HeroicStrike" then
		return "Rage dump (on next swing)"
	end
	if info.name == "Cleave" then
		local count = ATW.EnemyCount and ATW.EnemyCount(8) or 1
		return "AoE rage dump (" .. count .. " targets)"
	end

	-- Rend
	if info.name == "Rend" then
		if info.targetGUID then
			return "Spread to nameplate target"
		end
		return "DoT application (35% AP over 21s)"
	end

	-- Overpower
	if info.name == "Overpower" then
		return "Dodge proc! Use now"
	end

	-- Bloodrage
	if info.name == "Bloodrage" then
		return "Generate rage (+20)"
	end

	-- Default
	if ability and ability.rage then
		return "Cost: " .. ability.rage .. " rage"
	end

	return ""
end

---------------------------------------
-- Update the display
---------------------------------------
function ATW.UpdateDisplay()
	local UI = ATW.UI
	if not UI.frame or not UI.frame:IsVisible() then return end

	local elements = UI.elements
	local colors = UI.colors

	-- Check for valid target
	local hasTarget = UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")

	-- Even without target, check for self-buffs (Battle Shout, Bloodrage, etc.)
	if not hasTarget then
		-- Check if Battle Shout is needed (doesn't require target!)
		local needsBattleShout = not ATW.Buff("player", "Ability_Warrior_BattleShout")
		local rage = UnitMana("player") or 0

		if needsBattleShout and rage >= 10 then
			-- Recommend Battle Shout
			local texture = nil
			local spellId = ATW.SpellID and ATW.SpellID("Battle Shout")
			if spellId then
				texture = GetSpellTexture(spellId, BOOKTYPE_SPELL)
			end
			elements.icon.icon:SetTexture(texture or "Interface\\Icons\\Ability_Warrior_BattleShout")
			elements.icon.icon:SetVertexColor(1, 1, 1, 1)
			elements.icon.border:SetVertexColor(1, 1, 1, 0.8)
			elements.icon.cooldown:Hide()
			elements.abilityName:SetText("Battle Shout")
			elements.abilityName:SetTextColor(1, 1, 1, 1)
			elements.reasonText:SetText("Buff missing (no target needed)")
			elements.stateBadge:SetText("")
			elements.statusLine:SetText("")
			elements.targetLine:SetText("")
			elements.queueLine:SetText("")
		else
			-- No target and no buffs needed
			elements.icon.icon:SetTexture("Interface\\Icons\\Ability_Warrior_BattleShout")
			elements.icon.icon:SetVertexColor(0.4, 0.4, 0.4, 1)
			elements.icon.border:SetVertexColor(0.4, 0.4, 0.4, 0.5)
			elements.icon.cooldown:Hide()
			elements.abilityName:SetText("No Target")
			elements.abilityName:SetTextColor(colors.textGray[1], colors.textGray[2], colors.textGray[3], 1)
			elements.reasonText:SetText("Select an enemy to attack")
			elements.stateBadge:SetText("")
			elements.statusLine:SetText("")
			elements.targetLine:SetText("")
			elements.queueLine:SetText("")
		end

		-- Update bars
		elements.swingBar:SetValue(0, 1, colors.swing)
		elements.swingBar.text:SetText("")
		elements.rageBar:SetValue(rage, 100, colors.rage)
		elements.rageBar.text:SetText(string.format("%d", rage))
		return
	end

	---------------------------------------
	-- Get current state
	---------------------------------------
	local rage = UnitMana("player") or 0
	local currentStance = ATW.Stance and ATW.Stance() or 3
	local inExecutePhase = ATW.InExecutePhase and ATW.InExecutePhase() or false
	local enemyCount = ATW.EnemyCount and ATW.EnemyCount(8) or 1

	-- Get recommended ability
	local abilityInfo = GetAbilityInfo()
	local abilityName = abilityInfo and abilityInfo.name or "Waiting"
	local ability = ATW.Abilities and ATW.Abilities[abilityName]
	local spellName = ability and ability.name or abilityName

	---------------------------------------
	-- Update main icon
	---------------------------------------
	local texture = GetSpellIcon(spellName)
	if texture then
		elements.icon.icon:SetTexture(texture)
		elements.icon.icon:SetVertexColor(1, 1, 1, 1)
	else
		elements.icon.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
		elements.icon.icon:SetVertexColor(0.6, 0.6, 0.6, 1)
	end

	-- Icon border color based on state
	if inExecutePhase then
		elements.icon.border:SetVertexColor(colors.execute[1], colors.execute[2], colors.execute[3], 1)
	elseif abilityInfo and abilityInfo.pooling then
		elements.icon.border:SetVertexColor(colors.pooling[1], colors.pooling[2], colors.pooling[3], 1)
	elseif abilityInfo and abilityInfo.isStanceSwitch then
		elements.icon.border:SetVertexColor(colors.stanceDance[1], colors.stanceDance[2], colors.stanceDance[3], 1)
	else
		elements.icon.border:SetVertexColor(1, 1, 1, 0.8)
	end

	-- Check cooldown
	local onCD = false
	local spellId = ATW.SpellID(spellName)
	if spellId then
		local start, duration = GetSpellCooldown(spellId, BOOKTYPE_SPELL)
		if start and start > 0 and duration and duration > 1.5 then
			onCD = true
			elements.icon.cooldown:Show()
		else
			elements.icon.cooldown:Hide()
		end
	else
		elements.icon.cooldown:Hide()
	end

	---------------------------------------
	-- Update ability name and reason
	---------------------------------------
	elements.abilityName:SetText(spellName)

	if inExecutePhase then
		elements.abilityName:SetTextColor(colors.execute[1], colors.execute[2], colors.execute[3], 1)
	elseif onCD then
		elements.abilityName:SetTextColor(colors.cooldown[1], colors.cooldown[2], colors.cooldown[3], 1)
	else
		elements.abilityName:SetTextColor(1, 1, 1, 1)
	end

	local reason = GetAbilityReason(abilityInfo)
	elements.reasonText:SetText(reason)

	---------------------------------------
	-- Update state badge
	---------------------------------------
	local badge = ""
	if inExecutePhase then
		badge = "|cffff3333EXECUTE|r"
	elseif abilityInfo and abilityInfo.pooling then
		badge = "|cffff9900POOLING|r"
	elseif abilityInfo and abilityInfo.isStanceSwitch then
		badge = "|cffffff00STANCE|r"
	end
	elements.stateBadge:SetText(badge)

	---------------------------------------
	-- Update swing timer bar
	---------------------------------------
	local swingRemaining, swingTotal = 0, 2.5
	if ATW.GetSwingTimeRemaining then
		swingRemaining = ATW.GetSwingTimeRemaining() or 0
		swingTotal = ATW.GetMainHandSpeed and ATW.GetMainHandSpeed() or 2.5
	end

	local swingPct = 1 - (swingRemaining / swingTotal)
	if swingPct < 0 then swingPct = 0 end
	if swingPct > 1 then swingPct = 1 end

	-- Check if HS/Cleave queued
	local hsQueued = ATW.State and ATW.State.HSQueued
	local swingColor = hsQueued and colors.swingQueued or colors.swing

	elements.swingBar:SetValue(swingPct, 1, swingColor)
	if swingRemaining > 0 then
		elements.swingBar.text:SetText(string.format("%.1f", swingRemaining))
	else
		elements.swingBar.text:SetText("")
	end

	---------------------------------------
	-- Update rage bar
	---------------------------------------
	local rageColor = colors.rage
	if rage >= 80 then
		rageColor = colors.rageHigh
	elseif rage < 30 then
		rageColor = colors.rageLow
	end

	elements.rageBar:SetValue(rage, 100, rageColor)
	elements.rageBar.text:SetText(string.format("%d", rage))

	-- Show threshold marker for next ability cost
	if ability and ability.rage then
		elements.rageBar:SetMarker(ability.rage / 100)
	else
		elements.rageBar:SetMarker(nil)
	end

	---------------------------------------
	-- Update status line
	---------------------------------------
	local statusParts = {}

	-- AoE count
	if enemyCount > 1 then
		table.insert(statusParts, "|cff00ff00AoE: " .. enemyCount .. "|r")
	end

	-- Rend status on target
	if ATW.HasRend and ATW.HasRend("target") then
		local remaining = 0
		if ATW.HasSuperWoW and ATW.HasSuperWoW() then
			local _, guid = UnitExists("target")
			if guid and ATW.GetRendRemaining then
				remaining = ATW.GetRendRemaining(guid)
			end
		end
		if remaining > 0 then
			table.insert(statusParts, "|cff00ff00Rend: " .. string.format("%.0f", remaining) .. "s|r")
		else
			table.insert(statusParts, "|cff00ff00Rend|r")
		end
	elseif ATW.IsBleedImmune and ATW.IsBleedImmune("target") then
		table.insert(statusParts, "|cffff0000No Bleed|r")
	end

	-- Overpower available
	if ATW.State and ATW.State.Overpower then
		table.insert(statusParts, "|cffffff00OP!|r")
	end

	-- HS/Cleave queued
	if hsQueued then
		table.insert(statusParts, "|cff3399ffHS/Clv|r")
	end

	elements.statusLine:SetText(table.concat(statusParts, "  "))

	---------------------------------------
	-- Update target line
	---------------------------------------
	local targetHP = ATW.GetHealthPercent and ATW.GetHealthPercent("target") or 100
	local targetTTD = ATW.GetTargetTTD and ATW.GetTargetTTD() or 999
	local creatureType = UnitCreatureType("target") or ""

	local targetParts = {}

	-- HP%
	local hpColor = "|cffffffff"
	if targetHP < 20 then
		hpColor = "|cffff3333"
	elseif targetHP < 50 then
		hpColor = "|cffffff00"
	end
	table.insert(targetParts, hpColor .. string.format("%.0f%%", targetHP) .. "|r HP")

	-- TTD
	if targetTTD < 999 then
		table.insert(targetParts, "TTD: " .. string.format("%.0f", targetTTD) .. "s")
	end

	-- Creature type (if notable)
	if creatureType ~= "" and creatureType ~= "Humanoid" and creatureType ~= "Beast" then
		table.insert(targetParts, creatureType)
	end

	elements.targetLine:SetText(table.concat(targetParts, " | "))

	---------------------------------------
	-- Update ability queue
	---------------------------------------
	local queueText = "Next: "
	local simResults = ATW.SimulateAhead and ATW.SimulateAhead(4) or {}

	local queueNames = {}
	for i = 2, 4 do
		local step = simResults[i]
		if step and step.ability then
			local shortName = step.ability
			-- Shorten names
			if shortName == "Bloodthirst" then shortName = "BT"
			elseif shortName == "Whirlwind" then shortName = "WW"
			elseif shortName == "HeroicStrike" then shortName = "HS"
			elseif shortName == "Execute" then shortName = "Exec"
			elseif shortName == "Overpower" then shortName = "OP"
			elseif shortName == "Bloodrage" then shortName = "BR"
			elseif shortName == "MortalStrike" then shortName = "MS"
			end
			table.insert(queueNames, shortName)
		end
	end

	if table.getn(queueNames) > 0 then
		elements.queueLine:SetText(queueText .. table.concat(queueNames, " > "))
	else
		elements.queueLine:SetText("")
	end
end

---------------------------------------
-- Toggle display visibility
---------------------------------------
function ATW.ToggleDisplay()
	if not ATW.UI.frame then
		ATW.CreateDisplay()
	end

	if ATW.UI.frame:IsVisible() then
		ATW.UI.frame:Hide()
		AutoTurtleWarrior_Config.ShowDisplay = false
		ATW.Print("Display: OFF")
	else
		ATW.UI.frame:Show()
		AutoTurtleWarrior_Config.ShowDisplay = true
		ATW.Print("Display: ON")
	end
end

---------------------------------------
-- Toggle frame lock
---------------------------------------
function ATW.ToggleLock()
	ATW.UI.isLocked = not ATW.UI.isLocked
	local colors = ATW.UI.colors

	if ATW.UI.isLocked then
		ATW.Print("Display: LOCKED")
		if ATW.UI.frame then
			ATW.UI.frame:SetBackdropBorderColor(colors.border[1], colors.border[2], colors.border[3], colors.border[4])
		end
	else
		ATW.Print("Display: UNLOCKED - Drag to move")
		if ATW.UI.frame then
			ATW.UI.frame:SetBackdropBorderColor(colors.borderUnlocked[1], colors.borderUnlocked[2], colors.borderUnlocked[3], colors.borderUnlocked[4])
		end
	end
end

---------------------------------------
-- Reset display position
---------------------------------------
function ATW.ResetDisplayPosition()
	if ATW.UI.frame then
		ATW.UI.frame:ClearAllPoints()
		ATW.UI.frame:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
		AutoTurtleWarrior_Config.DisplayX = 0
		AutoTurtleWarrior_Config.DisplayY = -150
		ATW.Print("Display position reset")
	end
end

---------------------------------------
-- Scale display
---------------------------------------
function ATW.SetDisplayScale(scale)
	scale = tonumber(scale) or 1
	if scale < 0.5 then scale = 0.5 end
	if scale > 2 then scale = 2 end

	if ATW.UI.frame then
		ATW.UI.frame:SetScale(scale)
		AutoTurtleWarrior_Config.DisplayScale = scale
		ATW.Print("Display scale: " .. string.format("%.1f", scale))
	end
end

---------------------------------------
-- Initialize display
---------------------------------------
function ATW.InitDisplay()
	ATW.CreateDisplay()

	local scale = AutoTurtleWarrior_Config.DisplayScale or 1
	if ATW.UI.frame then
		ATW.UI.frame:SetScale(scale)
	end
end

--[[
================================================================================
  TIMELINE UI - Visual timeline showing abilities and auto-attacks

  Layout:
  +------------------------------------------------------------------+
  |  [Ability icons positioned by time - clamped vertically]         |
  |  ═══════════════════════════════════════════════════════════════ |  <- Time axis
  |  [Auto-attack icons (MH/OH) below the line]                      |
  |  0s        2s        4s        6s        8s        10s           |
  +------------------------------------------------------------------+
================================================================================
]]--

ATW.Timeline = {
	frame = nil,
	abilityIcons = {},
	autoAttackIcons = {},
	maxAbilityIcons = 20,
	maxAutoIcons = 15,
	abilityIconSize = 28,
	autoIconSize = 20,
	updateInterval = 0.05,  -- 50ms for timeline (less critical than main icon)
	lastUpdate = 0,
	isVisible = false,

	-- Timeline dimensions
	width = 450,
	height = 100,
	timelineHorizon = 10000,  -- 10 seconds
	padding = 10,
	axisY = 50,  -- Y position of the time axis (from top)
}

---------------------------------------
-- Get spell icon texture by name
---------------------------------------
local function GetTimelineSpellIcon(spellName)
	if not spellName then return nil end

	-- Handle stance switches
	if spellName == "BattleStance" then
		return "Interface\\Icons\\Ability_Warrior_OffensiveStance"
	elseif spellName == "BerserkerStance" then
		return "Interface\\Icons\\Ability_Racial_Avatar"
	elseif spellName == "DefensiveStance" then
		return "Interface\\Icons\\Ability_Warrior_DefensiveStance"
	end

	-- Handle racials
	if spellName == "BloodFury" then
		return "Interface\\Icons\\Racial_Orc_BerserkerStrength"
	elseif spellName == "Berserking" then
		return "Interface\\Icons\\Racial_Troll_Berserk"
	elseif spellName == "Perception" then
		return "Interface\\Icons\\Spell_Nature_Sleep"
	end

	-- Handle auto-attacks
	if spellName == "AutoAttack" then
		return "Interface\\Icons\\INV_Sword_04"
	elseif spellName == "AutoAttackOH" then
		return "Interface\\Icons\\INV_Sword_04"
	end

	-- Try to get from spell book
	local id = ATW.SpellID and ATW.SpellID(spellName)
	if id then
		return GetSpellTexture(id, BOOKTYPE_SPELL)
	end

	-- Fallback for common abilities
	local fallbacks = {
		Bloodthirst = "Interface\\Icons\\Spell_Nature_BloodLust",
		Whirlwind = "Interface\\Icons\\Ability_Whirlwind",
		Execute = "Interface\\Icons\\INV_Sword_48",
		HeroicStrike = "Interface\\Icons\\Ability_Rogue_Ambush",
		Cleave = "Interface\\Icons\\Ability_Warrior_Cleave",
		Overpower = "Interface\\Icons\\Ability_MeleeDamage",
		Rend = "Interface\\Icons\\Ability_Gouge",
		Slam = "Interface\\Icons\\Ability_Warrior_DecisiveStrike",
		MortalStrike = "Interface\\Icons\\Ability_Warrior_SavageBlow",
		Charge = "Interface\\Icons\\Ability_Warrior_Charge",
		BattleShout = "Interface\\Icons\\Ability_Warrior_BattleShout",
		Bloodrage = "Interface\\Icons\\Ability_Racial_BloodRage",
		DeathWish = "Interface\\Icons\\Spell_Shadow_DeathPact",
		Recklessness = "Interface\\Icons\\Ability_CriticalStrike",
		SweepingStrikes = "Interface\\Icons\\Ability_Rogue_SliceDice",
		Pummel = "Interface\\Icons\\INV_Gauntlets_04",
		BerserkerRage = "Interface\\Icons\\Spell_Nature_AncestralGuardian",
	}

	return fallbacks[spellName]
end

---------------------------------------
-- Create a timeline icon (ability or auto-attack)
---------------------------------------
local function CreateTimelineIconFrame(parent, name, size, isAuto)
	local iconFrame = CreateFrame("Frame", name, parent)
	iconFrame:SetWidth(size)
	iconFrame:SetHeight(size)
	iconFrame:SetFrameLevel(parent:GetFrameLevel() + 2)

	-- Background
	iconFrame.bg = iconFrame:CreateTexture(nil, "BACKGROUND")
	iconFrame.bg:SetAllPoints(iconFrame)
	iconFrame.bg:SetTexture(0, 0, 0, 0.8)

	-- Icon texture
	iconFrame.icon = iconFrame:CreateTexture(nil, "ARTWORK")
	iconFrame.icon:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 2, -2)
	iconFrame.icon:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -2, 2)
	iconFrame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	-- Border
	iconFrame.border = iconFrame:CreateTexture(nil, "OVERLAY")
	iconFrame.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	iconFrame.border:SetBlendMode("ADD")
	iconFrame.border:SetWidth(size * 1.4)
	iconFrame.border:SetHeight(size * 1.4)
	iconFrame.border:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
	iconFrame.border:SetVertexColor(1, 1, 1, 0.5)

	-- Connector line to axis
	iconFrame.connector = iconFrame:CreateTexture(nil, "BACKGROUND")
	iconFrame.connector:SetTexture(0.5, 0.5, 0.5, 0.5)
	iconFrame.connector:SetWidth(1)
	iconFrame.connector:Hide()

	-- Off-GCD indicator (yellow dot)
	if not isAuto then
		iconFrame.offGCD = iconFrame:CreateTexture(nil, "OVERLAY")
		iconFrame.offGCD:SetTexture(1, 0.8, 0, 1)
		iconFrame.offGCD:SetWidth(6)
		iconFrame.offGCD:SetHeight(6)
		iconFrame.offGCD:SetPoint("TOPRIGHT", iconFrame, "TOPRIGHT", 0, 0)
		iconFrame.offGCD:Hide()
	end

	-- OH indicator for off-hand auto-attacks
	if isAuto then
		iconFrame.ohLabel = iconFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		iconFrame.ohLabel:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
		iconFrame.ohLabel:SetText("OH")
		iconFrame.ohLabel:SetTextColor(1, 0.5, 0, 1)
		iconFrame.ohLabel:Hide()
	end

	iconFrame:Hide()
	return iconFrame
end

---------------------------------------
-- Create the timeline frame
---------------------------------------
function ATW.CreateTimeline()
	if ATW.Timeline.frame then return end

	local TL = ATW.Timeline
	local cfg = AutoTurtleWarrior_Config

	-- Main container
	local frame = CreateFrame("Frame", "ATWTimeline", UIParent)
	frame:SetWidth(TL.width)
	frame:SetHeight(TL.height)
	frame:SetPoint("CENTER", UIParent, "CENTER", cfg.TimelineX or 0, cfg.TimelineY or -250)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:SetClampedToScreen(true)
	frame:SetFrameStrata("MEDIUM")

	-- Background
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 2, right = 2, top = 2, bottom = 2 }
	})
	frame:SetBackdropColor(0, 0, 0, 0.9)
	frame:SetBackdropBorderColor(0.3, 0.3, 0.5, 1)

	-- Drag functionality
	frame:SetScript("OnMouseDown", function()
		if arg1 == "LeftButton" then
			this:StartMoving()
		end
	end)
	frame:SetScript("OnMouseUp", function()
		this:StopMovingOrSizing()
		local _, _, _, x, y = this:GetPoint()
		AutoTurtleWarrior_Config.TimelineX = x
		AutoTurtleWarrior_Config.TimelineY = y
	end)

	-- Time axis line
	frame.axis = frame:CreateTexture(nil, "ARTWORK")
	frame.axis:SetTexture(0.6, 0.6, 0.6, 1)
	frame.axis:SetHeight(2)
	frame.axis:SetPoint("LEFT", frame, "LEFT", TL.padding, 0)
	frame.axis:SetPoint("RIGHT", frame, "RIGHT", -TL.padding, 0)
	frame.axis:SetPoint("TOP", frame, "TOP", 0, -TL.axisY)

	-- Time markers (0s, 2s, 4s, etc.)
	frame.timeMarkers = {}
	local usableWidth = TL.width - (TL.padding * 2)
	for i = 0, 5 do
		local marker = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		local xPos = TL.padding + (i / 5) * usableWidth
		marker:SetPoint("TOP", frame, "TOPLEFT", xPos, -TL.axisY - 5)
		marker:SetText(string.format("%ds", i * 2))
		marker:SetTextColor(0.6, 0.6, 0.6, 1)
		frame.timeMarkers[i] = marker

		-- Tick mark
		local tick = frame:CreateTexture(nil, "ARTWORK")
		tick:SetTexture(0.6, 0.6, 0.6, 1)
		tick:SetWidth(1)
		tick:SetHeight(6)
		tick:SetPoint("TOP", frame, "TOPLEFT", xPos, -TL.axisY + 3)
	end

	-- Labels
	frame.abilityLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.abilityLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -5)
	frame.abilityLabel:SetText("Abilities")
	frame.abilityLabel:SetTextColor(0.7, 0.9, 0.7, 1)

	frame.autoLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.autoLabel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 5, 5)
	frame.autoLabel:SetText("Auto")
	frame.autoLabel:SetTextColor(0.7, 0.7, 0.9, 1)

	-- Create ability icon pool
	TL.abilityIcons = {}
	for i = 1, TL.maxAbilityIcons do
		TL.abilityIcons[i] = CreateTimelineIconFrame(frame, "ATWTLAbility" .. i, TL.abilityIconSize, false)
	end

	-- Create auto-attack icon pool
	TL.autoAttackIcons = {}
	for i = 1, TL.maxAutoIcons do
		TL.autoAttackIcons[i] = CreateTimelineIconFrame(frame, "ATWTLAuto" .. i, TL.autoIconSize, true)
	end

	-- Update script
	frame:SetScript("OnUpdate", function()
		local now = GetTime()
		if now - TL.lastUpdate >= TL.updateInterval then
			ATW.UpdateTimeline()
			TL.lastUpdate = now
		end
	end)

	TL.frame = frame

	-- Initial visibility
	if cfg.ShowTimeline then
		frame:Show()
		TL.isVisible = true
	else
		frame:Hide()
		TL.isVisible = false
	end
end

---------------------------------------
-- Convert time to X position on timeline
---------------------------------------
local function TimeToX(timeMs, TL)
	local usableWidth = TL.width - (TL.padding * 2)
	local fraction = timeMs / TL.timelineHorizon
	if fraction > 1 then fraction = 1 end
	if fraction < 0 then fraction = 0 end
	return TL.padding + (fraction * usableWidth)
end

---------------------------------------
-- Update the timeline display
---------------------------------------
function ATW.UpdateTimeline()
	local TL = ATW.Timeline
	if not TL.frame or not TL.frame:IsVisible() then return end

	-- Hide all icons first
	for i = 1, TL.maxAbilityIcons do
		TL.abilityIcons[i]:Hide()
	end
	for i = 1, TL.maxAutoIcons do
		TL.autoAttackIcons[i]:Hide()
	end

	-- Get timeline data from Engine
	local timeline = nil
	if ATW.Engine and ATW.Engine.GetSimulationTimeline then
		local ok, result = pcall(ATW.Engine.GetSimulationTimeline, 20, TL.timelineHorizon)
		if ok and result then
			timeline = result
		end
	end

	if not timeline or table.getn(timeline) == 0 then
		return
	end

	-- Separate abilities and auto-attacks
	local abilities = {}
	local autoAttacks = {}

	for _, entry in ipairs(timeline) do
		if entry.isAutoAttack then
			table.insert(autoAttacks, entry)
		else
			table.insert(abilities, entry)
		end
	end

	-- Position abilities ABOVE the axis with vertical clamping
	local abilitySlots = {}  -- Track occupied X ranges per Y level
	local abilityIdx = 1
	local baseY = TL.axisY - TL.abilityIconSize - 5  -- Base position above axis

	for _, entry in ipairs(abilities) do
		if abilityIdx > TL.maxAbilityIcons then break end

		local iconFrame = TL.abilityIcons[abilityIdx]
		local xPos = TimeToX(entry.time or 0, TL)

		-- Find Y level that doesn't overlap
		local yLevel = 0
		local iconHalfWidth = TL.abilityIconSize / 2
		local xMin = xPos - iconHalfWidth
		local xMax = xPos + iconHalfWidth

		-- Check each Y level for overlap
		local foundSlot = false
		while not foundSlot and yLevel < 3 do  -- Max 3 levels
			local levelSlots = abilitySlots[yLevel] or {}
			local overlaps = false

			for _, slot in ipairs(levelSlots) do
				if not (xMax < slot.xMin or xMin > slot.xMax) then
					overlaps = true
					break
				end
			end

			if not overlaps then
				foundSlot = true
				if not abilitySlots[yLevel] then
					abilitySlots[yLevel] = {}
				end
				table.insert(abilitySlots[yLevel], {xMin = xMin, xMax = xMax})
			else
				yLevel = yLevel + 1
			end
		end

		local yPos = baseY - (yLevel * (TL.abilityIconSize + 2))

		-- Position icon
		iconFrame:ClearAllPoints()
		iconFrame:SetPoint("CENTER", TL.frame, "TOPLEFT", xPos, -TL.axisY + (TL.axisY - yPos - TL.abilityIconSize/2))

		-- Set icon texture
		local texture = GetTimelineSpellIcon(entry.name)
		if texture then
			iconFrame.icon:SetTexture(texture)
			iconFrame.icon:SetVertexColor(1, 1, 1, 1)
		else
			iconFrame.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
		end

		-- First ability gets green border
		if abilityIdx == 1 then
			iconFrame.border:SetVertexColor(0, 1, 0, 0.9)
		else
			iconFrame.border:SetVertexColor(1, 1, 1, 0.4)
		end

		-- Off-GCD indicator
		if entry.isOffGCD and iconFrame.offGCD then
			iconFrame.offGCD:Show()
		elseif iconFrame.offGCD then
			iconFrame.offGCD:Hide()
		end

		-- Draw connector line to axis
		iconFrame.connector:ClearAllPoints()
		iconFrame.connector:SetPoint("TOP", iconFrame, "BOTTOM", 0, 0)
		iconFrame.connector:SetHeight(yPos + TL.abilityIconSize/2 - TL.axisY + TL.axisY)
		iconFrame.connector:Show()

		iconFrame:Show()
		abilityIdx = abilityIdx + 1
	end

	-- Position auto-attacks BELOW the axis with vertical clamping
	local autoSlots = {}
	local autoIdx = 1
	local autoBaseY = TL.axisY + 5  -- Base position below axis

	for _, entry in ipairs(autoAttacks) do
		if autoIdx > TL.maxAutoIcons then break end

		local iconFrame = TL.autoAttackIcons[autoIdx]
		local xPos = TimeToX(entry.time or 0, TL)

		-- Find Y level that doesn't overlap
		local yLevel = 0
		local iconHalfWidth = TL.autoIconSize / 2
		local xMin = xPos - iconHalfWidth
		local xMax = xPos + iconHalfWidth

		local foundSlot = false
		while not foundSlot and yLevel < 2 do  -- Max 2 levels for autos
			local levelSlots = autoSlots[yLevel] or {}
			local overlaps = false

			for _, slot in ipairs(levelSlots) do
				if not (xMax < slot.xMin or xMin > slot.xMax) then
					overlaps = true
					break
				end
			end

			if not overlaps then
				foundSlot = true
				if not autoSlots[yLevel] then
					autoSlots[yLevel] = {}
				end
				table.insert(autoSlots[yLevel], {xMin = xMin, xMax = xMax})
			else
				yLevel = yLevel + 1
			end
		end

		local yPos = autoBaseY + (yLevel * (TL.autoIconSize + 2))

		-- Position icon
		iconFrame:ClearAllPoints()
		iconFrame:SetPoint("CENTER", TL.frame, "TOPLEFT", xPos, -yPos - TL.autoIconSize/2)

		-- Set icon texture
		local texture = GetTimelineSpellIcon(entry.name)
		if texture then
			iconFrame.icon:SetTexture(texture)
			-- MH = normal color, OH = tinted orange
			if entry.isOH then
				iconFrame.icon:SetVertexColor(1, 0.6, 0.3, 1)
				if iconFrame.ohLabel then iconFrame.ohLabel:Show() end
			else
				iconFrame.icon:SetVertexColor(0.8, 0.8, 1, 1)
				if iconFrame.ohLabel then iconFrame.ohLabel:Hide() end
			end
		end

		iconFrame.border:SetVertexColor(0.5, 0.5, 0.7, 0.4)

		-- Draw connector line to axis
		iconFrame.connector:ClearAllPoints()
		iconFrame.connector:SetPoint("BOTTOM", iconFrame, "TOP", 0, 0)
		iconFrame.connector:SetHeight(yPos - TL.axisY)
		iconFrame.connector:Show()

		iconFrame:Show()
		autoIdx = autoIdx + 1
	end
end

---------------------------------------
-- Toggle timeline visibility
---------------------------------------
function ATW.ToggleTimeline()
	if not ATW.Timeline.frame then
		ATW.CreateTimeline()
	end

	local TL = ATW.Timeline
	if TL.frame:IsVisible() then
		TL.frame:Hide()
		TL.isVisible = false
		AutoTurtleWarrior_Config.ShowTimeline = false
		ATW.Print("Timeline: OFF")
	else
		TL.frame:Show()
		TL.isVisible = true
		AutoTurtleWarrior_Config.ShowTimeline = true
		ATW.Print("Timeline: ON")
	end
end

---------------------------------------
-- Reset timeline position
---------------------------------------
function ATW.ResetTimelinePosition()
	if ATW.Timeline.frame then
		ATW.Timeline.frame:ClearAllPoints()
		ATW.Timeline.frame:SetPoint("CENTER", UIParent, "CENTER", 0, -250)
		AutoTurtleWarrior_Config.TimelineX = 0
		AutoTurtleWarrior_Config.TimelineY = -250
		ATW.Print("Timeline position reset")
	end
end

---------------------------------------
-- Initialize timeline (called after display init)
---------------------------------------
function ATW.InitTimeline()
	if AutoTurtleWarrior_Config.ShowTimeline then
		ATW.CreateTimeline()
	end
end
