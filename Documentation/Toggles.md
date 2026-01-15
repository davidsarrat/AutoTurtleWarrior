# Toggle System

The addon uses toggles for cooldown management, AoE behavior, and utility features.

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

┌─────────────────────────────────────────────────────────────┐
│  AOE MODES                                                  │
│  ─────────────────────────────────────────────────────────  │
│                                                             │
│  AUTO AOE (AoEEnabled = true):                              │
│  └── WW/Cleave based on enemy count (default)              │
│                                                             │
│  SINGLE TARGET (AoEEnabled = false):                        │
│  └── Funnel mode - no Rend spread, ST priority             │
│                                                             │
│  REND SPREAD (RendSpread = true):                          │
│  └── Apply Rend to multiple targets (auto-disabled if      │
│      AoEEnabled = false)                                   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  CD SYNC (SyncCooldowns = true)                            │
│  ─────────────────────────────────────────────────────────  │
│                                                             │
│  When enabled: Racials wait up to 10s for Death Wish       │
│  When disabled: All CDs used independently on cooldown     │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

```lua
AutoTurtleWarrior_Config = {
    -- Cooldowns
    BurstEnabled = true,     -- Death Wish + Racials
    RecklessEnabled = false, -- Recklessness
    SyncCooldowns = true,    -- Racials wait for Death Wish

    -- AoE
    AoEEnabled = true,       -- Auto AoE based on enemy count
    RendSpread = true,       -- Spread Rend to multiple targets

    -- Bloodrage
    BloodrageBurstMode = true,   -- Soft-sync with Death Wish
    BloodrageCombatOnly = true,  -- Only use in combat

    -- Utility
    PummelEnabled = true,    -- Auto-interrupt (see Interrupt.md)
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

### Cooldown Toggles

```
/atw burst          - Toggle BurstEnabled
/atw burst on       - Enable burst mode
/atw burst off      - Disable burst mode

/atw reckless       - Toggle RecklessEnabled
/atw reckless on    - Enable reckless mode
/atw reckless off   - Disable reckless mode

/atw sustain        - Disable all cooldowns (both OFF)

/atw sync           - Toggle SyncCooldowns
/atw sync on        - Enable CD sync (racials wait for DW)
/atw sync off       - Disable CD sync (use independently)

/atw cd             - Show current cooldown status and toggles
```

### AoE Toggles

```
/atw aoemode        - Toggle AoEEnabled (auto/single target)
/atw aoemode on     - Enable auto AoE mode
/atw aoemode off    - Enable single target mode

/atw rendspread     - Toggle RendSpread
/atw rendspread on  - Enable Rend spreading
/atw rendspread off - Disable Rend spreading (main target only)
```

### Bloodrage Toggles

```
/atw bloodragecd    - Toggle BloodrageBurstMode (soft-sync with DW)
/atw bloodragecd on - Enable burst mode (wait for DW if rage > 40)
/atw bloodragecd off - Disable burst mode (use on CD)

/atw brcombat       - Toggle BloodrageCombatOnly
/atw brcombat on    - Only use Bloodrage in combat (default)
/atw brcombat off   - Allow Bloodrage out of combat (pre-pull rage)
```

**BloodrageBurstMode** (default: ON):
- Soft-syncs Bloodrage with Death Wish
- If rage > 40 and DW coming in < 15s, waits for DW
- Emergency override: Always uses if rage < 30
- Respects BurstEnabled toggle (off in sustain mode)

**BloodrageCombatOnly** (default: ON):
- Prevents Bloodrage use out of combat
- Avoids wasting the short buff duration pre-pull
- Turn OFF if you want pre-pull rage generation

### Utility Toggles

```
/atw pummel         - Toggle auto-interrupt
/atw pummel on      - Enable auto-interrupt
/atw pummel off     - Disable auto-interrupt
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
2. **Engine.lua - shouldWaitForDWSync()**: Handles CD sync for racials
3. **Engine.lua - CaptureCurrentState()**: Skips enemy list if AoE disabled
4. **Simulator.lua - SimulateTimeWindow()**: Excludes disabled CDs from time simulation

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

With manual toggles, you control when to pop Recklessness:
- Keep RecklessEnabled OFF during boss normal phase
- Enable it when entering execute phase for 100% crit Executes
- Combine with `/atw burst on` for maximum damage

```
/atw burst on
/atw reckless on
/atw
```

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
