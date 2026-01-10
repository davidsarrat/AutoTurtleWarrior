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
# Core
1. Core/Init.lua           - Creates ATW table, defaults, state
2. Core/Helpers.lua        - Utility functions (buffs, debuffs, HP)

# Player
3. Player/Stats.lua        - Player statistics gathering
4. Player/TTD.lua          - Time To Die calculation
5. Player/Gear.lua         - Weapon detection
6. Player/Talents.lua      - Talent and spell detection

# Combat
7. Combat/Stance.lua       - Stance detection and switching
8. Combat/Casting.lua      - Spell casting helpers
9. Combat/SwingTimer.lua   - Swing timer tracking
10. Combat/GUIDTargeting.lua - GUID-based casting
11. Combat/Interrupt.lua   - CastingTracker + auto-Pummel

# Detection
12. Detection/Distance.lua    - Range calculations (SuperWoW)
13. Detection/CreatureType.lua - Bleed immunity detection
14. Detection/AoE.lua         - Enemy counting, Rend tracking

# Simulation (load before Rotation)
15. Sim/Abilities.lua     - Ability definitions and damage formulas
16. Sim/RageModel.lua     - Rage generation formulas (Zebouski)
17. Sim/Strategic.lua     - Cooldown synergy planning
18. Sim/Engine.lua        - Combat simulation engine (3400+ lines)
19. Sim/Simulator.lua     - Cooldown toggles, GetNextAbility wrapper

# Rotation
20. Rotation/Rotation.lua  - Main rotation execution logic

# UI
21. UI/Display.lua         - Visual display frame

# Commands
22. Commands/SlashCommands.lua - Chat commands (/atw)
23. Commands/Events.lua        - Event registration (loads last)
```

## File Size Analysis

| File | Lines | Status |
|------|-------|--------|
| Sim/Engine.lua | ~3450 | Large - contains full simulation |
| Sim/Simulator.lua | ~1470 | Mixed - toggles + legacy code |
| Rotation/Rotation.lua | ~450 | Good |
| UI/Display.lua | ~400 | Good |
| Other files | <300 each | Good |

### Engine.lua Subsystems

The largest file contains these distinct subsystems:

```
Engine.lua (3450 lines):
├── Constants & Configuration (~100)
├── State Management
│   ├── CreateState (~155)
│   ├── InitPlayer (~135)
│   ├── InitTargets (~70)
│   ├── CaptureCurrentState (~310)
│   └── DeepCopyState (~25)
├── Combat Calculations
│   ├── GetDamageMod (~20)
│   ├── GetCritChance (~35)
│   ├── GetEffectiveAP (~25)
│   ├── GetHasteMod (~30)
│   ├── RollWeaponDamage (~25)
│   └── ProcessHit (~50)
├── Combat Processing
│   ├── ProcessAutoAttack (~90)
│   ├── ProcessDoTs (~35)
│   ├── ApplyDeepWounds (~20)
│   ├── ApplyRend (~25)
│   └── ProcessSweepingStrikes (~35)
├── Ability System
│   ├── CanUseAbility (~55)
│   ├── UseAbility (~170)
│   └── ChooseAbility (~35)
├── HS/Cleave Cancel Logic (~105)
├── Main Simulation Loop (~90)
├── Action System
│   ├── GetValidActions (~405)
│   ├── GetActionDamage (~280)
│   └── ApplyAction (~260)
├── Decision System
│   ├── CacheValid (~70)
│   ├── SimulateDecisionHorizon (~55)
│   ├── EstimateAutoAttackDamage (~100)
│   └── GetBestAction (~85)
└── Debug & Utilities (~200)
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
│   │ Execute Action   │ → Stance switch OR ability           │
│   └──────────────────┘                                      │
└─────────────────────────────────────────────────────────────┘
```

## Simulation-Based Decision Flow

```
┌────────────────────┐     ┌─────────────────────┐     ┌────────────────┐
│ CaptureCurrentState│ →   │ GetValidActions()   │ →   │ GetBestAction()│
│ (full combat state)│     │ (stance + abilities)│     │ (simulate 9s)  │
└────────────────────┘     └─────────────────────┘     └────────────────┘
        ↑                          ↑                          ↑
        │                          │                          │
┌───────┴────────────┐     ┌───────┴───────────┐      ┌───────┴──────┐
│ rage, stance, buffs│     │ STANCE SWITCHES:   │      │ Sim each act │
│ inCombat, distance │     │  BerserkerStance   │      │ 9s horizon   │
│ enemies[], TTD     │     │  BattleStance      │      │ Pick highest │
└────────────────────┘     │ ABILITIES:         │      │ (incl stance)│
                           │  Only in right     │      └──────────────┘
                           │  stance + learned  │
                           └───────────────────┘
```

### Stance as First-Class Actions

The simulator treats stance switches as **explicit actions** with their own DPS value:

1. **BerserkerStance**: +3% crit on all attacks (valued by future damage)
2. **BattleStance**: Enables Overpower, Charge, Rend, Sweeping Strikes

(DefensiveStance is never recommended for DPS rotations)

When the simulator calculates the best action:
- It simulates 9 seconds ahead for each possible action
- Uses **real swing timers** (mhTimer/ohTimer) for precise auto-attack damage calculations
- Stance switches do 0 direct damage but enable high-value abilities
- The Berserker +3% crit bonus is captured in future ability damage
- HS/Cleave damage is properly valued based on when the next swing will land

This means the simulator **decides** when to switch stance based on DPS, not hardcoded rules.

## State Management

### Persistent State (SavedVariables)

```lua
AutoTurtleWarrior_Config = {
    Enabled = true,
    Debug = false,
    PrimaryStance = 0,      -- 0=auto, 3=Berserker
    DanceRage = 10,         -- Min rage to stance dance
    MaxRage = 60,           -- Rage cap consideration

    -- AoE System (see Toggles.md)
    AoEEnabled = true,      -- Auto AoE based on enemy count (false = single target)
    RendSpread = true,      -- Spread Rend to multiple targets (false = main target only)

    -- Cooldown Toggle System (see Toggles.md)
    BurstEnabled = true,    -- Death Wish + Racials (Blood Fury, Berserking, Perception)
    RecklessEnabled = false, -- Recklessness (save for execute or manual)
    SyncCooldowns = true,   -- Racials wait for Death Wish (up to 10s)

    -- Auto-Interrupt System (see Interrupt.md)
    PummelEnabled = true,   -- Auto-interrupt with Pummel via CastingTracker
}
```

### Runtime State

```lua
ATW.State = {
    -- Stance State
    LastStance = 0,         -- Time of last stance change

    -- Combat Windows
    Overpower = nil,        -- Overpower window active (timestamp)
    Interrupt = nil,        -- Legacy interrupt flag (deprecated, use CastingTracker)

    -- Attack State
    Attacking = nil,        -- Currently auto-attacking
    NeedsAARestore = nil,   -- GUID to restore AA to after nameplate cast
}
```

### Simulation-Based Stance System

The simulator now handles stance switches as **first-class actions**:

```lua
-- In GetValidActions(), stance switches are generated like any other action:
if stanceCdReady and stance ~= 3 then
    table.insert(actions, {
        name = "BerserkerStance",
        targetStance = 3,
        isStanceSwitch = true,
        rage = 0,
        rageLoss = math.max(0, rage - tm),  -- TM cap
    })
end
```

**Key Design:**
- Stance switches are explicit actions the simulator can choose
- Abilities are ONLY available when already in the correct stance
- The simulator naturally values Berserker stance due to +3% crit on all attacks
- No "pending ability" system needed - each keypress does ONE thing

**Execution Flow:**
```
Keypress 1: Simulator says "BerserkerStance" → CastShapeshiftForm(3)
Keypress 2: Simulator says "Bloodthirst" → CastSpellByName("Bloodthirst")
```

This is the most **simulation-based** approach possible:
- The simulator decides EVERYTHING based on DPS calculations
- No hardcoded "if wrong stance, switch" logic
- Battle stance is valued for enabling Overpower, Charge, Rend
- Berserker stance is valued for +3% crit bonus

### CastingTracker System (Combat/Interrupt.lua)

The addon tracks enemy casts via SuperWoW's UNIT_CASTEVENT:

```lua
ATW.CastingTracker = {
    casts = {},             -- {[guid] = {spellID, startTime, duration}}
}

-- Key functions:
ATW.CastingTracker.OnCastStart(guid, spellID, duration)  -- Track new cast
ATW.CastingTracker.OnCastEnd(guid)                       -- Clear completed cast
ATW.GetInterruptTarget()                                  -- Find closest casting enemy
ATW.ShouldInterrupt()                                     -- Check if Pummel ready + target
ATW.ExecuteInterrupt(guid)                                -- Target, Pummel, restore target
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

    -- Swing Timers (REAL values from game state, in ms)
    mhTimer = 1200,             -- Time until next MH swing
    ohTimer = 800,              -- Time until next OH swing (if dual-wield)

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
