# Cooldown Toggle System

The addon uses a priority-based toggle system for cooldown management, allowing fine-grained control over which cooldowns are used.

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│  COOLDOWN MODES                                             │
│  ─────────────────────────────────────────────────────────  │
│                                                             │
│  SUSTAIN MODE (both OFF):                                   │
│  └── No cooldowns used - pure rotation                      │
│                                                             │
│  BURST MODE (BurstEnabled = true):                          │
│  └── Death Wish + Racials (Blood Fury, Berserking, etc.)   │
│                                                             │
│  RECKLESS MODE (RecklessEnabled = true):                    │
│  └── Adds Recklessness to the mix                          │
│                                                             │
│  Note: Toggles STACK - both ON = all cooldowns             │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

```lua
AutoTurtleWarrior_Config = {
    BurstEnabled = true,     -- Death Wish + Racials
    RecklessEnabled = false, -- Recklessness
    PummelEnabled = true,    -- Auto-interrupt (separate system)
}
```

## Cooldown Categories

### Burst Cooldowns (BurstEnabled)

| Cooldown | Effect | Duration | CD |
|----------|--------|----------|-----|
| Death Wish | +20% damage | 30s | 3 min |
| Blood Fury (Orc) | +120 AP | 15s | 2 min |
| Berserking (Troll) | +10-15% haste | 10s | 3 min |
| Perception (Human) | +2% crit | 20s | 3 min |

### Reckless Cooldowns (RecklessEnabled)

| Cooldown | Effect | Duration | CD |
|----------|--------|----------|-----|
| Recklessness | +100% crit | 15s | 30 min |

## Slash Commands

```
/atw burst          - Toggle BurstEnabled
/atw burst on       - Enable burst mode
/atw burst off      - Disable burst mode

/atw reckless       - Toggle RecklessEnabled
/atw reckless on    - Enable reckless mode
/atw reckless off   - Disable reckless mode

/atw sustain        - Disable all cooldowns (both OFF)

/atw mode           - Show current mode status
```

## Implementation

### Core Function: `ATW.IsCooldownAllowed(cdName)`

Located in `Sim/Simulator.lua`:

```lua
-- Cooldown categories
ATW.BURST_COOLDOWNS = {
    DeathWish = true,
    BloodFury = true,
    Berserking = true,
    Perception = true,
}

ATW.RECKLESS_COOLDOWNS = {
    Recklessness = true,
}

function ATW.IsCooldownAllowed(cdName)
    local cfg = AutoTurtleWarrior_Config

    -- Check burst cooldowns
    if ATW.BURST_COOLDOWNS[cdName] then
        return cfg.BurstEnabled == true
    end

    -- Check reckless cooldowns
    if ATW.RECKLESS_COOLDOWNS[cdName] then
        return cfg.RecklessEnabled == true
    end

    -- Other cooldowns always allowed
    return true
end
```

### Integration Points

The toggle system is checked at multiple points:

1. **Engine.lua - GetValidActions()**: Excludes disabled cooldowns from action list
2. **Strategic.lua - GetPriorityCooldown()**: Respects toggles for strategic planning
3. **Simulator.lua - SimulateTimeWindow()**: Excludes disabled CDs from time simulation
4. **Rotation.lua - LegacyRotation()**: Respects toggles in fallback rotation

### Cache Invalidation

When toggles change, the simulation cache is invalidated:

```lua
function ATW.SetBurst(enabled)
    AutoTurtleWarrior_Config.BurstEnabled = enabled
    -- Invalidate cache so next decision recalculates
    if ATW.Engine and ATW.Engine.InvalidateCache then
        ATW.Engine.InvalidateCache()
    end
end
```

## Usage Scenarios

### Sustained DPS (Farm/Trash)

```
/atw sustain
```
- Saves cooldowns for bosses
- Pure rotation: BT > WW > HS/Cleave

### Boss Pull (Standard)

```
/atw burst on
/atw reckless off
```
- Uses Death Wish + racials on CD
- Saves Recklessness for execute phase

### All-Out Burn

```
/atw burst on
/atw reckless on
```
- All cooldowns enabled
- Maximum burst damage
- Use for short fights or execute phase

### Execute Phase Burst

The Strategic layer automatically considers saving Recklessness for execute:
- If execute phase < 45s away, may hold Recklessness
- 100% crit Executes = massive damage

## Macro Examples

### Toggle Burst with Keybind

```lua
/atw burst
```

### Quick Sustain Mode

```lua
/atw sustain
/atw
```
Enters sustain mode and runs rotation.

### Boss Opener Macro

```lua
/atw burst on
/atw reckless on
/atw
```
Enables all CDs and starts rotation.
