# Architecture Overview

This document describes the overall architecture and code organization of AutoTurtleWarrior.

## Design Philosophy

The addon follows a **modular architecture** where each system is self-contained but can interact with others through the global `ATW` namespace. This allows:

- Easy debugging of individual systems
- Clear separation of concerns
- Incremental feature development
- Simple testing via slash commands

## Global Namespace

All addon functions and data are stored under the global `ATW` table:

```lua
ATW = {
    -- Configuration
    DEFAULT = {},           -- Default settings

    -- State
    State = {},             -- Runtime state (combat, dancing, etc.)
    Talents = {},           -- Detected talents
    Spells = {},            -- Detected spell ranks
    TTD = {},               -- Time To Die tracking data
    RendTracker = {},       -- Per-GUID Rend tracking

    -- Core functions
    Print(),                -- Chat output
    Debug(),                -- Debug output (when enabled)

    -- ... and many more
}
```

## Module Loading Order

The addon loads modules in a specific order defined in the `.toc` file:

```
1. Core/Init.lua          - Creates ATW table, basic setup
2. Core/Config.lua        - Default configuration values
3. Core/Helpers.lua       - Utility functions (buffs, debuffs, HP)
4. Player/Talents.lua     - Talent and spell detection
5. Player/Stats.lua       - Player statistics gathering
6. Player/TTD.lua         - Time To Die calculation
7. Detection/Distance.lua - Range calculations
8. Detection/CreatureType.lua - Creature type caching
9. Detection/AoE.lua      - Enemy counting, Rend tracking
10. Rotation/Stances.lua  - Stance detection and switching
11. Combat/SwingTimer.lua - Swing timer tracking
12. Combat/GUIDTargeting.lua - GUID-based casting
13. Sim/Abilities.lua     - Ability definitions
14. Sim/Engine.lua        - Simulation engine
15. Sim/Simulator.lua     - Time-based simulation
16. Rotation/Rotation.lua - Main rotation logic
17. Commands/SlashCommands.lua - Chat commands
18. Commands/Events.lua   - Event registration (loads last)
19. UI/Display.lua        - Visual interface
```

## Event Flow

```
┌─────────────────────────────────────────────────────────────┐
│                     VARIABLES_LOADED                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ LoadTalents │→ │ LoadSpells  │→ │ AutoDetectStance    │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                      COMBAT LOOP                             │
│                                                              │
│   OnUpdate (0.25s)        Combat Log Events                  │
│   ┌──────────────┐       ┌────────────────────────────┐     │
│   │ UpdateAllTTD │       │ CHAT_MSG_COMBAT_SELF_HITS  │     │
│   │ (nameplates) │       │ → ParseCombatLogForSwing   │     │
│   └──────────────┘       │                            │     │
│                          │ CHAT_MSG_SPELL_PERIODIC_*  │     │
│   UNIT_HEALTH            │ → ParseRendCombatLog       │     │
│   ┌──────────────┐       │                            │     │
│   │ UpdateTarget │       │ CHAT_MSG_COMBAT_SELF_MISSES│     │
│   │ TTD          │       │ → Detect Overpower window  │     │
│   └──────────────┘       └────────────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────┐
│                    ROTATION EXECUTION                        │
│                                                              │
│   /atw (keybind)                                            │
│   ┌──────────────┐                                          │
│   │ ATW.Rotation │                                          │
│   └──────┬───────┘                                          │
│          ↓                                                   │
│   ┌──────────────────┐                                      │
│   │ GetNextAbility   │ ← Uses Engine simulation             │
│   └──────┬───────────┘                                      │
│          ↓                                                   │
│   ┌──────────────────┐                                      │
│   │ Execute Ability  │ → Stance dance if needed             │
│   └──────────────────┘                                      │
└─────────────────────────────────────────────────────────────┘
```

## Data Flow for Rend Decision

```
┌────────────────┐     ┌─────────────────┐     ┌──────────────┐
│ GetEnemiesWith │ →   │ ShouldApplyRend │ →   │ GetNextAbility│
│ TTD()          │     │ ToGUID()        │     │ returns Rend │
└────────────────┘     └─────────────────┘     └──────────────┘
        ↑                      ↑                       ↑
        │                      │                       │
┌───────┴────────┐     ┌───────┴───────┐      ┌───────┴──────┐
│ Nameplate scan │     │ HP% check     │      │ DPR priority │
│ GUID extraction│     │ Bleed immune  │      │ Rage check   │
│ Distance calc  │     │ HasRend check │      │ Stance check │
└────────────────┘     └───────────────┘      └──────────────┘
```

## State Management

### Persistent State (SavedVariables)
```lua
AutoTurtleWarrior_Config = {
    Enabled = true,
    Debug = false,
    PrimaryStance = 3,      -- Berserker
    UseCooldowns = false,
    HSRage = 50,
    WWRange = 8,
    -- ... etc
}
```

### Runtime State
```lua
ATW.State = {
    Attacking = nil,        -- Currently auto-attacking
    Dancing = nil,          -- Mid-stance dance
    OldStance = nil,        -- Stance before dance
    LastStance = 0,         -- Time of last stance change
    Overpower = nil,        -- Overpower window active
    Interrupt = nil,        -- Enemy casting (pummel)

    -- Rend tracking
    PendingRendGUID = nil,  -- GUID of target we cast Rend on
    PendingRendTime = nil,  -- When we cast it
    PendingRendName = nil,  -- Target name for verification
}
```

## Error Handling

The addon uses `pcall()` extensively when calling SuperWoW functions that might not exist or might fail:

```lua
local ok, result = pcall(function()
    return UnitHealth(guid)
end)
if ok and result then
    -- Use result
end
```

This ensures the addon doesn't break if:
- SuperWoW is not installed
- A function doesn't support the expected parameters
- The game state is unexpected

## Debugging

Enable debug mode with `/atw debug`. This activates:

1. **Verbose output** - All decisions logged to chat
2. **Talent/spell loading info** - Shows detected values
3. **Rend tracking details** - GUID stored/checked messages
4. **TTD sample counts** - Per-unit tracking info

Individual systems also have debug commands:
- `/atw rendtest` - Rend detection debugging
- `/atw hp` - HP detection debugging
- `/atw ttd` - TTD tracking debugging
