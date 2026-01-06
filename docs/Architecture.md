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
    -- Configuration Defaults
    DEFAULT = {},           -- Default settings

    -- Runtime State
    State = {},             -- Runtime state (combat, stance dancing, etc.)
    Talents = {},           -- Detected talent values
    Spells = {},            -- Detected spell ranks

    -- Subsystems
    TTD = {},               -- Time To Die tracking data
    RendTracker = {},       -- Per-GUID Rend tracking
    Engine = {},            -- Simulation engine

    -- Core functions
    Print(),                -- Chat output
    Debug(),                -- Debug output (when enabled)

    -- ... and many more
}
```

## Module Loading Order

The addon loads modules in a specific order defined in the `.toc` file:

```
1. Core/Init.lua           - Creates ATW table, defaults, state
2. Core/Helpers.lua        - Utility functions (buffs, debuffs, HP)

3. Player/Stats.lua        - Player statistics gathering
4. Player/TTD.lua          - Time To Die calculation
5. Player/Gear.lua         - Weapon detection
6. Player/Talents.lua      - Talent and spell detection

7. Combat/Stance.lua       - Stance detection and switching
8. Combat/Casting.lua      - Spell casting helpers
9. Combat/SwingTimer.lua   - Swing timer tracking
10. Combat/GUIDTargeting.lua - GUID-based casting

11. Detection/Distance.lua    - Range calculations (SuperWoW)
12. Detection/CreatureType.lua - Bleed immunity detection
13. Detection/AoE.lua         - Enemy counting, Rend tracking

14. Sim/Abilities.lua     - Ability definitions and data
15. Sim/RageModel.lua     - Rage generation formulas
16. Sim/Engine.lua        - Combat simulation engine
17. Sim/Simulator.lua     - Time-based simulation runner

18. Rotation/Rotation.lua  - Main rotation logic

19. UI/Display.lua         - Visual interface

20. Commands/SlashCommands.lua - Chat commands
21. Commands/Events.lua        - Event registration (loads last)
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
│   │ GetBestAction()  │ ← Full combat simulation             │
│   └──────┬───────────┘                                      │
│          ↓                                                   │
│   ┌──────────────────┐                                      │
│   │ Execute Ability  │ → Stance dance if needed             │
│   └──────────────────┘                                      │
└─────────────────────────────────────────────────────────────┘
```

## Simulation-Based Decision Flow

```
┌────────────────────┐     ┌─────────────────────┐     ┌────────────────┐
│ CaptureCurrentState│ →   │ GetValidActions()   │ →   │ GetBestAction()│
│ (full combat state)│     │ (hasSpell checks!)  │     │ (simulate 60s) │
└────────────────────┘     └─────────────────────┘     └────────────────┘
        ↑                          ↑                          ↑
        │                          │                          │
┌───────┴────────────┐     ┌───────┴───────────┐      ┌───────┴──────┐
│ rage, stance, buffs│     │ Only LEARNED spells│      │ Sim each act │
│ inCombat, distance │     │ Charge if OOC      │      │ 60s horizon  │
│ enemies[], TTD     │     │ Slam if 2H only    │      │ Pick highest │
└────────────────────┘     └───────────────────┘      └──────────────┘
```

## State Management

### Persistent State (SavedVariables)

```lua
AutoTurtleWarrior_Config = {
    Enabled = true,
    Debug = false,
    PrimaryStance = 0,      -- 0=auto, 3=Berserker
    DanceRage = 10,         -- Min rage to stance dance
    MaxRage = 60,           -- Rage cap consideration
    -- Note: HSRage removed - simulation decides optimal HS/Cleave usage
    AoE = "auto",           -- "on", "off", "auto"
    AoECount = 3,           -- Enemies for auto AoE
    WWRange = 8,            -- Whirlwind range
    UseCooldowns = true,    -- Use Death Wish, Recklessness
}
```

### Runtime State

```lua
ATW.State = {
    -- Stance Dancing
    Dancing = nil,          -- Mid-stance dance
    OldStance = nil,        -- Stance before dance
    LastStance = 0,         -- Time of last stance change

    -- Combat Windows
    Overpower = nil,        -- Overpower window active (timestamp)
    Interrupt = nil,        -- Enemy casting (pummel window)

    -- Attack State
    Attacking = nil,        -- Currently auto-attacking
    NeedsAARestore = nil,   -- GUID to restore AA to after nameplate cast

    -- Rend Tracking (pending verification)
    PendingRendGUID = nil,  -- GUID of target we cast Rend on
    PendingRendTime = nil,  -- When we cast it
    PendingRendName = nil,  -- Target name for verification
}
```

### AA Target Restore System

When casting spells on nameplates via GUID (Rend spread, Execute on low HP mob, Overpower on mob that dodged), SuperWoW changes the auto-attack target to that nameplate. To prevent this:

1. After a GUID cast to a different target, we set `State.NeedsAARestore = mainTargetGUID`
2. On the next rotation frame, we detect this flag and call `AttackTarget()` once
3. This restores AA to the main target without interfering with the spell cast

This is done on the **next frame** rather than immediately after the cast to avoid potential conflicts with the game's internal state updates.

### Overpower Multi-Target Iteration

When a mob dodges, the combat log only says "X dodges" but doesn't tell us WHICH mob dodged if there are multiple in melee range. The addon uses an **iteration system** to try Overpower on each potential target:

```lua
ATW.OverpowerIteration = {
    targets = {},       -- Array of GUIDs to try
    index = 0,          -- Current position in array
    lastBuild = 0,      -- Timestamp of last list build
}
```

**Flow:**
1. Dodge detected → `State.Overpower = GetTime()` (5 second window)
2. Target list built: main target first, then all nameplates in 5yd
3. Each keypress advances `index` and tries `CastSpellByName("Overpower", guid)`
4. If Overpower fails (wrong mob), next keypress tries next GUID
5. When Overpower lands → `OnOverpowerSuccess()` clears everything
6. If all targets exhausted → proc cleared, rotación normal

**Interaction with AA Restore:**
- These systems are **independent**: iteration tracks GUIDs, AA restore tracks attack target
- While iterating, AA is restored to main target between attempts
- This is desirable: we auto-attack the main target while searching for the dodging mob

```
Keypress 1: Try OP on mob A → fails → set NeedsAARestore
Keypress 2: Restore AA → Try OP on mob B → fails → set NeedsAARestore
Keypress 3: Restore AA → Try OP on mob C → SUCCESS → clear all state
```

### Simulation State (captured fresh each decision)

The simulation engine captures complete combat state each time a decision is needed:

```lua
-- Engine.CaptureCurrentState() returns:
state = {
    -- Resources
    rage = 50,
    stance = 3,                 -- 1=Battle, 2=Def, 3=Berserker

    -- Combat State (critical for Charge)
    inCombat = true,            -- From UnitAffectingCombat()
    targetDistance = 15,        -- From ATW.GetDistance()

    -- Player Stats
    ap = 1500,
    crit = 25,
    mhDmgMin = 100,
    mhDmgMax = 200,
    mhSpeed = 2600,
    hasOH = false,              -- Off-hand equipped?
    tacticalMastery = 25,

    -- Buff Tracking
    hasBattleShout = true,
    hasDeathWish = false,
    hasRecklessness = false,
    hasBerserkerRage = false,
    hasSweepingStrikes = false,
    hasBloodrageActive = false,
    hasEnrage = false,

    -- Combat Windows
    overpowerReady = true,
    shouldInterrupt = false,

    -- Swing Queue
    swingQueued = nil,          -- nil, "hs", "cleave"

    -- Current Target
    targetGUID = "0x...",
    targetHPPercent = 85,
    targetTTD = 25000,
    targetBleedImmune = false,
    rendOnTarget = false,
    rendRemaining = 0,

    -- Multi-Target (ALL enemies from nameplates)
    enemies = { ... },
    enemyCount = 3,
    enemyCountMelee = 2,        -- Within 5yd
    enemyCountWW = 3,           -- Within 8yd

    -- Cooldowns (ms remaining)
    cooldowns = { ... },
}
```

## Talent & Spell Detection

### ATW.Talents (talent point values)

```lua
ATW.Talents = {
    -- Arms
    TM = 25,            -- Tactical Mastery (0/5/10/15/20/25)
    HSCost = 12,        -- Heroic Strike cost after Imp HS
    ImpRend = 2,        -- Improved Rend points
    ChargeRage = 15,    -- Rage from Charge (9 + Imp Charge bonus)
    OPCrit = 50,        -- Overpower crit bonus
    DeepWounds = 3,     -- Deep Wounds points
    Impale = 2,         -- Impale points
    HasSS = true,       -- Has Sweeping Strikes
    HasMS = false,      -- Has Mortal Strike

    -- Fury
    Cruelty = 5,        -- Cruelty crit bonus
    UnbridledWrath = 40, -- UW proc chance
    ExecCost = 10,      -- Execute cost after Imp Execute
    Flurry = 5,         -- Flurry points
    HasDW = true,       -- Has Death Wish
    HasIBR = true,      -- Has Improved Berserker Rage
    HasBT = true,       -- Has Bloodthirst
}
```

### ATW.Spells (spell ranks learned)

```lua
ATW.Spells = {
    -- Core abilities (rank 0 = not learned)
    ExecuteRank = 3,
    RendRank = 7,
    HeroicStrikeRank = 9,
    CleaveRank = 5,
    OverpowerRank = 4,
    WhirlwindRank = 1,
    SlamRank = 4,
    HamstringRank = 3,
    BattleShoutRank = 7,

    -- Talent abilities
    BloodthirstRank = 1,
    MortalStrikeRank = 0,   -- Not learned if 0

    -- Utility abilities
    ChargeRank = 3,
    BloodrageRank = 1,
    BerserkerRageRank = 1,
    PummelRank = 1,
    DeathWishRank = 1,
    RecklessnessRank = 1,
    SweepingStrikesRank = 1,

    -- Convenience flag
    HasRend = true,         -- RendRank > 0
}
```

## Error Handling

The addon uses `pcall()` extensively when calling SuperWoW functions that might not exist:

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
- `/atw spells` - Show detected spell ranks
- `/atw talents` - Show detected talent values
- `/atw decision` - Show current simulation comparison
- `/atw rendtest` - Rend detection debugging
- `/atw hp` - HP detection debugging
- `/atw ttd` - TTD tracking debugging
- `/atw aoe` - AoE enemy analysis
