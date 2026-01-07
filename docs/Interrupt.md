# Auto-Interrupt System

The addon includes an automatic interrupt system using Pummel, detecting enemy casts via SuperWoW's UNIT_CASTEVENT.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│  UNIT_CASTEVENT (SuperWoW)                                 │
│  ─────────────────────────────────────────────────────────  │
│                                                             │
│  eventType:                                                │
│  - "START"   → Enemy starts casting → Track                │
│  - "CHANNEL" → Enemy starts channel → Track                │
│  - "CAST"    → Cast completed → Stop tracking              │
│  - "FAIL"    → Cast interrupted → Stop tracking            │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  ATW.CastingTracker                                        │
│  ─────────────────────────────────────────────────────────  │
│  casts = {                                                  │
│      [guid1] = {spellID, spellName, startTime, endTime},   │
│      [guid2] = { ... },                                    │
│  }                                                          │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  ATW.GetInterruptTarget()                                  │
│  ─────────────────────────────────────────────────────────  │
│  1. Check current target first (priority)                   │
│  2. Find closest casting enemy in melee range (5yd)         │
│  3. Return: guid, spellName, remainingTime, distance        │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Engine.GetBestAction()                                    │
│  ─────────────────────────────────────────────────────────  │
│  - Captures shouldInterrupt + interruptTargetGUID          │
│  - Adds Pummel as highest priority action if:              │
│    ✓ PummelEnabled                                         │
│    ✓ Enemy is casting                                      │
│    ✓ Pummel off cooldown                                   │
│    ✓ Enough rage (10)                                      │
│    ✓ Correct stance (Battle/Berserker)                     │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

```lua
AutoTurtleWarrior_Config = {
    PummelEnabled = true,   -- Enable/disable auto-interrupt
}
```

## Slash Commands

```
/atw pummel         - Toggle auto-interrupt
/atw pummel on      - Enable auto-interrupt
/atw pummel off     - Disable auto-interrupt

/atw casts          - Show currently tracked enemy casts
/atw casting        - Alias for /atw casts
```

## File: Combat/Interrupt.lua

### CastingTracker Structure

```lua
ATW.CastingTracker = {
    casts = {},             -- Active casts by GUID
    CAST_TIMEOUT = 10,      -- Max tracking time (cleanup)
    INTERRUPT_RANGE = 5,    -- Pummel range (melee)
}
```

### Key Functions

#### `ATW.CastingTracker.OnCastStart(casterGUID, spellID, duration)`

Called when UNIT_CASTEVENT fires with "START" or "CHANNEL":

```lua
-- Records cast info
ATW.CastingTracker.casts[casterGUID] = {
    spellID = spellID,
    spellName = spellName,      -- From SpellInfo()
    casterName = casterName,    -- From UnitName(guid)
    startTime = GetTime(),
    duration = duration / 1000,
    endTime = startTime + duration,
}
```

#### `ATW.CastingTracker.OnCastEnd(casterGUID)`

Called when cast completes ("CAST") or fails ("FAIL"):

```lua
ATW.CastingTracker.casts[casterGUID] = nil
```

#### `ATW.GetInterruptTarget()`

Finds the best target to interrupt:

1. **Priority**: Current target (if casting and in range)
2. **Fallback**: Closest casting enemy in melee range

Returns: `guid, spellName, remainingTime, distance` or `nil`

#### `ATW.ShouldInterrupt()`

Checks all conditions for using Pummel:

```lua
-- Conditions checked:
✓ PummelEnabled = true
✓ ATW.Has.Pummel exists
✓ Pummel off cooldown
✓ Rage >= 10
✓ Stance = Battle (1) or Berserker (3)
✓ Target casting with >= 0.3s remaining
```

Returns: `shouldInterrupt, targetGUID, spellName`

#### `ATW.ExecuteInterrupt(targetGUID)`

Executes the interrupt:

1. Store current target
2. Target the caster via GUID
3. Cast Pummel
4. Mark cast as ended in tracker
5. Return to previous target

## Integration with Engine

### State Capture (Engine.lua)

```lua
-- In CaptureCurrentState():
if AutoTurtleWarrior_Config.PummelEnabled and ATW.ShouldInterrupt then
    local shouldInt, targetGUID, spellName = ATW.ShouldInterrupt()
    state.shouldInterrupt = shouldInt
    state.interruptTargetGUID = targetGUID
end
```

### Action Generation (Engine.lua)

```lua
-- In GetAvailableActions():
if AutoTurtleWarrior_Config.PummelEnabled and hasSpell("Pummel") and state.shouldInterrupt then
    table.insert(actions, {
        name = "Pummel",
        isInterrupt = true,
        targetGUID = state.interruptTargetGUID,
        rage = 10,
        needsDance = false,
        offGCD = false,
    })
end
```

### Rotation Execution (Rotation.lua)

```lua
elseif abilityName == "Pummel" then
    if targetGUID and ATW.ExecuteInterrupt then
        local success = ATW.ExecuteInterrupt(targetGUID)
        if success then
            ATW.CastingTracker.OnCastEnd(targetGUID)
        end
    else
        ATW.Cast(ability.name, true)
    end
```

## Event Flow (SwingTimer.lua)

UNIT_CASTEVENT is routed in SwingTimer.lua:

```lua
function ATW.OnUnitCastEvent(casterGUID, targetGUID, eventType, spellID, duration)
    -- Check if this is an enemy cast (not player)
    if casterGUID ~= playerGUID then
        -- Verify hostile
        local isHostile = UnitCanAttack("player", casterGUID) == 1

        if isHostile and ATW.CastingTracker then
            if eventType == "START" or eventType == "CHANNEL" then
                ATW.CastingTracker.OnCastStart(casterGUID, spellID, duration)
            elseif eventType == "CAST" or eventType == "FAIL" then
                ATW.CastingTracker.OnCastEnd(casterGUID)
            end
        end
        return
    end

    -- ... player cast handling ...
end
```

## Pummel Notes (TurtleWoW)

- **Stances**: Pummel works in both Battle and Berserker stance
- **Rage Cost**: 10 rage
- **Cooldown**: 10 seconds
- **Range**: 5 yards (melee)
- **School Lockout**: Interrupts and locks the spell school

## Debug Output

With `/atw debug` enabled:

```
Cast START: Defias Mage -> Fireball (2.5s)
Cast END: Defias Mage
INTERRUPT: Fireball
```

With `/atw casts`:

```
=== Casting Enemies ===
Auto-Interrupt: ON
  Defias Mage: Fireball
    3.2yd | 1.8s left
Pummel: READY
```

## Exclusion from Normal Rotation

Pummel is **NOT** included in the normal ability simulation (abilityOrder in Simulator.lua). It's handled separately via the interrupt system to ensure:

1. Interrupts are reactive, not proactive
2. No DPS simulation needed for utility spell
3. Immediate priority when enemy is casting
