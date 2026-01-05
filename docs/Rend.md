# Rend Tracking System

This document explains how Rend tracking works across multiple targets.

## The Challenge

In vanilla WoW (1.12), tracking debuffs on multiple enemies is difficult because:

1. `UnitDebuff("target")` only works on current target
2. Combat log only provides target NAME, not GUID
3. Multiple mobs can have the same name (e.g., "Defias Pillager")
4. No reliable way to know if Rend was resisted until combat log

## Solution Architecture

We use a **multi-layered approach**:

```
┌─────────────────────────────────────────────────────────────┐
│                    Rend Detection                            │
├─────────────────────────────────────────────────────────────┤
│ Priority 1: UnitDebuff(guid) - SuperWoW direct check        │
│ Priority 2: UnitDebuff("target") - Standard API             │
│ Priority 3: RendTracker - Combat log verified tracking      │
└─────────────────────────────────────────────────────────────┘
```

## RendTracker System

### File: `Detection/AoE.lua`

```lua
ATW.RendTracker = {
    targets = {},           -- [guid] = {appliedAt, expiresAt}
    REND_DURATION = 21,     -- Updated dynamically from spell rank
}
```

### Recording Rend Application

We DON'T immediately record Rend when cast because:
- The cast might be resisted
- The target might be immune
- We need combat log confirmation

Instead, we use a **"pending" system**:

```lua
-- In Rotation.lua, when casting Rend:
ATW.State.PendingRendGUID = targetGUID
ATW.State.PendingRendTime = GetTime()
ATW.State.PendingRendName = UnitName(targetGUID)
```

### Combat Log Confirmation

The first Rend tick (at 3 seconds) confirms the application:

```lua
function ATW.ParseRendCombatLog(msg)
    -- Pattern: "X suffers Y damage from your Rend."
    local _, _, targetName = string.find(
        msg, "^(.+) suffers %d+ damage from your Rend"
    )

    if targetName then
        -- Check if we have a pending cast
        if ATW.State.PendingRendGUID then
            local elapsed = GetTime() - ATW.State.PendingRendTime

            -- Only accept within 5 seconds (first tick + margin)
            if elapsed < 5 then
                -- Name must match for verification
                if ATW.State.PendingRendName == targetName then
                    -- CONFIRMED: Store the exact GUID
                    ATW.RendTracker.OnRendApplied(ATW.State.PendingRendGUID)

                    -- Clear pending
                    ATW.State.PendingRendGUID = nil
                    ATW.State.PendingRendTime = nil
                    ATW.State.PendingRendName = nil
                end
            end
        end
    end
end
```

### Handling Multiple Mobs with Same Name

The key insight is linking the **exact GUID at cast time** with the **name from combat log**:

```
Cast Rend on "Defias Pillager" (GUID: 0x12345678)
  → Store: PendingGUID=0x12345678, PendingName="Defias Pillager"

Combat log: "Defias Pillager suffers 21 damage from your Rend."
  → Check: PendingName == "Defias Pillager" ✓
  → Confirm: Track GUID 0x12345678 (NOT "Defias Pillager")
```

This ensures we track the specific mob, not just any mob with that name.

### Handling Resists and Immunity

```lua
-- Pattern: "Your Rend was resisted by X"
local _, _, resistedTarget = string.find(
    msg, "Your Rend was resisted by (.+)"
)

-- Pattern: "Your Rend failed. X is immune."
local _, _, immuneTarget = string.find(
    msg, "Your Rend failed%. (.+) is immune"
)

if resistedTarget or immuneTarget then
    local failedTarget = resistedTarget or immuneTarget

    -- Only clear if name matches (could have cast on different target)
    if ATW.State.PendingRendName == failedTarget then
        ATW.State.PendingRendGUID = nil
        ATW.State.PendingRendTime = nil
        ATW.State.PendingRendName = nil
    end
end
```

## Checking for Rend

### Unified HasRend Function

```lua
-- Core/Helpers.lua
function ATW.HasRend(unitOrGUID)
    if not unitOrGUID then return false end

    -- Standard unit IDs (target, focus, etc.)
    if unitOrGUID == "target" or unitOrGUID == "player" or
       unitOrGUID == "focus" or unitOrGUID == "mouseover" then
        -- Direct debuff check (most reliable)
        if ATW.Debuff(unitOrGUID, "Ability_Gouge") then
            return true
        end

        -- Fallback to tracker
        if unitOrGUID == "target" and ATW.HasSuperWoW() then
            local _, guid = UnitExists("target")
            if guid and ATW.RendTracker.HasRend(guid) then
                return true
            end
        end
        return false
    end

    -- GUID-based check
    -- Priority 1: SuperWoW UnitDebuff(guid)
    if ATW.HasSuperWoW() then
        if ATW.DebuffOnGUID(unitOrGUID, "Ability_Gouge") then
            return true
        end
    end

    -- Priority 2: RendTracker
    if ATW.RendTracker then
        return ATW.RendTracker.HasRend(unitOrGUID)
    end

    return false
end
```

### Direct GUID Debuff Check

```lua
function ATW.DebuffOnGUID(guid, texture)
    if not guid then return false end

    -- SuperWoW allows UnitDebuff with GUID
    if ATW.HasSuperWoW() then
        local ok, found = pcall(function()
            local i = 1
            while true do
                local debuffTexture = UnitDebuff(guid, i)
                if not debuffTexture then break end
                if strfind(debuffTexture, texture) then
                    return true
                end
                i = i + 1
            end
            return false
        end)
        if ok and found then
            return true
        end
    end

    return false
end
```

## Rend Duration by Rank

Duration varies by spell rank (learned at different levels):

| Rank | Level | Duration | Ticks |
|------|-------|----------|-------|
| 1 | 4 | 9s | 3 |
| 2 | 10 | 12s | 4 |
| 3 | 20 | 15s | 5 |
| 4 | 30 | 18s | 6 |
| 5 | 40 | 21s | 7 |
| 6 | 50 | 21s | 7 |
| 7 | 60 | 21s | 7 |

The RendTracker duration is updated dynamically:

```lua
function ATW.LoadSpells()
    ATW.Spells.RendRank = ATW.GetMaxSpellRank("Rend")

    -- Update tracker with actual duration
    if ATW.RendTracker and ATW.Spells.RendRank > 0 then
        ATW.RendTracker.REND_DURATION = ATW.GetRendDuration()
    end
end
```

## Rend Spreading Decision

### When to Spread Rend

```lua
function ATW.ShouldSpreadRend()
    local enemies = ATW.GetEnemiesWithTTD(5)  -- Melee range

    local worthyTargets = 0
    for _, enemy in ipairs(enemies) do
        -- Skip if already has Rend or immune
        if not enemy.hasRend and not enemy.bleedImmune then
            -- HP-based rule: >= 30% HP is worth Rending
            local hpPercent = (enemy.hp / enemy.maxHp) * 100
            if hpPercent >= 30 then
                worthyTargets = worthyTargets + 1
            end
        end
    end

    -- Use simulation to compare strategies
    if worthyTargets >= 1 and ATW.FindOptimalStrategy then
        local strategy, gain = ATW.FindOptimalStrategy()
        if strategy == "rend_spread" and gain > 0 then
            return true, worthyTargets, gain
        end
    end

    return false, worthyTargets, 0
end
```

### Multi-Target Rend in Engine

The Engine finds the best target for Rend:

```lua
function Engine.FindBestRendTarget(state)
    local enemies = ATW.GetEnemiesWithTTD(5)

    for _, enemy in ipairs(enemies) do
        local shouldRend = Engine.ShouldApplyRendToGUID(
            enemy.guid,
            enemy.hpPercent,
            enemy.ttd
        )
        if shouldRend then
            return enemy.guid
        end
    end

    return nil
end
```

## Debug Commands

```
/atw rend      - Show Rend decision and tracker status
/atw rendtest  - Debug all Rend detection methods
/atw aoe       - Show all enemies with Rend status
```

### Example Output: /atw rendtest

```
--- Rend Detection Debug ---
Target: Defias Pillager
SuperWoW: YES
GUID: 0x0000000012...
---
Method 1: UnitDebuff('target')
  -> FOUND at index 3: Interface\Icons\Ability_Gouge
---
Method 2: UnitDebuff(guid)
  -> FOUND at index 3: Interface\Icons\Ability_Gouge
---
Method 3: RendTracker
  -> TRACKED (18.5s)
---
Combined: ATW.HasRend
  HasRend('target') = TRUE
  HasRend(guid) = TRUE
---
Pending Rend:
  (none)
```

## Event Registration

```lua
-- Commands/Events.lua
EventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")

-- In event handler:
elseif event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" then
    if arg1 and ATW.ParseRendCombatLog then
        ATW.ParseRendCombatLog(arg1)
    end
```
