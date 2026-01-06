# Rend Tracking System

This document explains how Rend tracking works across multiple targets.

## The Challenge

In vanilla WoW (1.12), tracking debuffs on multiple enemies is difficult because:

1. `UnitDebuff("target")` only works on current target
2. Combat log only provides target NAME, not GUID
3. Multiple mobs can have the same name (e.g., "Defias Pillager")
4. **UnitDebuff can't distinguish YOUR Rend from another warrior's Rend**

## Solution Architecture

We use **RendTracker as the primary source** because it only tracks YOUR Rends:

```
┌─────────────────────────────────────────────────────────────┐
│                    Rend Detection                           │
├─────────────────────────────────────────────────────────────┤
│ PRIMARY: RendTracker - Only YOUR Rends (combat log verified)│
│ FALLBACK: UnitDebuff - Only if GUID unavailable (rare)      │
└─────────────────────────────────────────────────────────────┘
```

**Why not UnitDebuff first?**
- `UnitDebuff` sees ANY Rend on the target, including other warriors'
- If another warrior has Rend on your target, UnitDebuff returns true
- This would prevent you from applying YOUR Rend, losing DPS

## RendTracker System

### File: `Detection/AoE.lua`

```lua
ATW.RendTracker = {
    targets = {},           -- [guid] = {appliedAt, expiresAt, name}
    pending = {},           -- [guid] = {time, name}
    REND_DURATION = 22,     -- Updated by LoadSpells() with cached value
}
```

### Rend Confirmation via UNIT_CASTEVENT (SuperWoW)

The primary method uses SuperWoW's `UNIT_CASTEVENT` which fires immediately when a spell cast completes:

```lua
-- In Combat/SwingTimer.lua
function ATW.OnUnitCastEvent(casterGUID, targetGUID, eventType, spellID, duration)
    -- Only process player's casts
    if casterGUID ~= playerGUID then return end

    if eventType == "CAST" then
        local spellName = SpellInfo(spellID)

        if spellName == "Rend" and targetGUID then
            -- Immediate confirmation - no 3s wait!
            ATW.RendTracker.ConfirmRend(targetGUID, UnitName(targetGUID))
        end
    end
end
```

### Fallback: Combat Log Confirmation

If UNIT_CASTEVENT isn't available, the combat log confirms at first tick (3s):

```lua
function ATW.ParseRendCombatLog(msg)
    -- Pattern: "X suffers Y damage from your Rend."
    -- The word "your" ensures we only track OUR Rends!
    local _, _, targetName = string.find(
        msg, "^(.+) suffers %d+ damage from your Rend"
    )

    if targetName then
        local pendingGUID = ATW.RendTracker.FindPendingByName(targetName)
        if pendingGUID then
            ATW.RendTracker.ConfirmRend(pendingGUID, targetName)
        end
    end
end
```

## Checking for YOUR Rend

### HasRend Function (Core/Helpers.lua)

```lua
function ATW.HasRend(unitOrGUID)
    if not unitOrGUID then return false end

    local guid = nil

    -- Convert unit ID to GUID if needed
    if unitOrGUID == "target" or unitOrGUID == "focus" then
        if ATW.HasSuperWoW() then
            guid = UnitGUID(unitOrGUID)
        end
    else
        guid = unitOrGUID  -- Already a GUID
    end

    -- PRIMARY: RendTracker (ONLY tracks YOUR Rends)
    if guid and ATW.RendTracker then
        if ATW.RendTracker.HasRend(guid) then
            return true
        end
    end

    -- FALLBACK: UnitDebuff only if no GUID (can't distinguish ownership!)
    if not guid then
        return ATW.Debuff(unitOrGUID, "Ability_Gouge") or false
    end

    return false
end
```

## Cached Rend Values

To prevent fallback values from being used mid-combat, all Rend values are cached on load:

### Set by LoadSpells() in Player/Talents.lua:

```lua
-- Cached values (use these instead of calling functions)
ATW.RendDuration = 22      -- Duration in seconds (from spell rank)
ATW.RendTicks = 7          -- Number of ticks (duration / 3)
ATW.RendBaseDamage = 147   -- Base damage (before Improved Rend)

-- Also updates tracker
ATW.RendTracker.REND_DURATION = ATW.RendDuration
```

### Usage:

```lua
-- CORRECT: Use cached value
local duration = (ATW.RendDuration and ATW.RendDuration > 0) and ATW.RendDuration or 22

-- AVOID: Calling function (may fail if ATW.Spells not loaded)
local duration = ATW.GetRendDuration()  -- Only use for backwards compatibility
```

## Rend Duration by Rank (TurtleWoW)

| Rank | Level | Duration | Ticks |
|------|-------|----------|-------|
| 1 | 4 | 10s | 3 |
| 2 | 10 | 13s | 4 |
| 3 | 20 | 16s | 5 |
| 4 | 30 | 19s | 6 |
| 5 | 40 | 22s | 7 |
| 6 | 50 | 22s | 7 |
| 7 | 60 | 22s | 7 |

**Note**: TurtleWoW uses different values than vanilla retail (which has 9/12/15/18/21/21/21).

## Event Registration

```lua
-- Commands/Events.lua
EventFrame:RegisterEvent("SPELLS_CHANGED")
EventFrame:RegisterEvent("CHARACTER_POINTS_CHANGED")  -- Talent changes
EventFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")

-- Handlers:
-- SPELLS_CHANGED / CHARACTER_POINTS_CHANGED -> LoadSpells() (re-cache values)
-- CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE -> ParseRendCombatLog() (confirm ticks)
```

## Rend Spreading Decision

### When to Spread Rend

The simulation engine generates Rend actions for each valid target and picks the best:

```lua
-- In Engine.GetValidActions()
for _, enemy in ipairs(state.enemies) do
    if not enemy.bleedImmune and not enemy.inExecute then
        -- Only refresh if less than GCD remaining (prevents wasted GCDs)
        if not enemy.hasRend or enemy.rendRemaining < Engine.GCD then
            if enemy.hpPercent >= 30 and enemy.ttd >= 9000 then
                table.insert(actions, {
                    name = "Rend",
                    targetGUID = enemy.guid,
                    -- ...
                })
            end
        end
    end
end
```

### HP-Based Rule

- **>= 30% HP**: Worth applying Rend (enough time for ticks)
- **< 30% HP**: Skip Rend (mob will die before ticks are worth it)

## Debug Commands

```
/atw rend      - Show Rend decision and tracker status
/atw rendtest  - Debug all Rend detection methods
/atw aoe       - Show all enemies with Rend status
```

### Example: /atw rend

```
=== Rend Tracker ===
  CONFIRMED 0x12345678... (Defias Pillager): 18.5s
  CONFIRMED 0x87654321... (Defias Bandit): 12.3s
Total: 2 confirmed, 0 pending
```
