# AutoTurtleWarrior Documentation

A comprehensive Fury Warrior rotation addon for TurtleWoW (1.12 vanilla client with custom extensions).

## Table of Contents

1. [Architecture Overview](Architecture.md) - Code structure and module organization
2. [Detection Systems](Detection.md) - SuperWoW, UnitXP, creature types, bleed immunity
3. [Simulation Engine](Simulation.md) - Pure simulation-based decision system (Zebouski-style)
4. [Rend Tracking](Rend.md) - Multi-target Rend tracking via combat log and GUID
5. [Time To Die (TTD)](TTD.md) - Linear regression algorithm for death prediction
6. [Spell & Talent System](Spells.md) - Dynamic spell rank detection and spell verification
7. [AoE Detection](AoE.md) - Nameplate scanning and enemy counting
8. [Swing Timer](SwingTimer.md) - Main-hand/off-hand swing tracking

## Requirements

- **TurtleWoW Client** - Modified 1.12 vanilla client
- **SuperWoW** - Required for GUID-based unit functions
- **UnitXP_SP3** - Required for extended unit information

## Quick Start

```
/atw          - Run rotation (bind to key)
/atw help     - Show all commands
/atw status   - Check addon dependencies
/atw debug    - Toggle debug mode
```

## Key Features

### Simulation-Based Decision System

The addon uses a **100% simulation-based approach** (Zebouski-style) with **no hardcoded priorities**:

1. **Capture State** - Snapshot full combat state (all enemies, buffs, cooldowns, combat state)
2. **Generate Actions** - List all valid actions using `hasSpell()` checks (only learned spells!)
3. **Simulate Each** - For each action, simulate **9 seconds** (6 GCDs) tactical horizon
4. **Compare Damage** - Pick the action that yields highest total damage

**Two-Layer Architecture:**
- **Strategic Layer** (every 2-5s): Plans cooldown usage, Rend spread vs Cleave strategy (30s lookahead)
- **Tactical Layer** (every frame): Decides immediate ability (9s lookahead)

This approach automatically handles edge cases like:
- Charge availability (out of combat only)
- Slam swing timer reset (2H weapons)
- Execute target dying to DoTs
- Multi-target Rend optimization
- Dynamic HS/Cleave thresholds
- Cooldown synergy (Death Wish + racials stacking)

### Intelligent Rotation

- Stance dancing with Tactical Mastery support
- Execute phase detection and targeting
- Heroic Strike/Cleave queue management
- Dynamic thresholds based on ability availability

### Multi-Target Support

- Nameplate-based enemy counting
- GUID-based Rend tracking across multiple targets
- Per-enemy Rend decisions via simulation
- Sweeping Strikes optimization

### Combat Analysis

- Real-time TTD (Time To Die) calculation via linear regression
- HP percentage tracking for all nearby enemies
- Bleed immunity detection by creature type
- Distance tracking for Charge range

## Debug Commands

| Command | Description |
|---------|-------------|
| `/atw spells` | Show detected spell ranks |
| `/atw talents` | Show detected talent values |
| `/atw decision` | Show simulation comparison for all actions |
| `/atw rendtest` | Debug Rend detection methods |
| `/atw ttd` | Show TTD tracking info |
| `/atw hp` | Debug HP detection |
| `/atw mob` | Show creature type detection |
| `/atw aoe` | Show AoE analysis |
| `/atw sim` | Run damage simulation |

## File Structure

```
AutoTurtleWarrior/
├── Core/
│   ├── Init.lua          - Addon initialization, defaults, config
│   └── Helpers.lua       - Utility functions (buffs, debuffs, cooldowns)
├── Player/
│   ├── Stats.lua         - Player statistics (AP, crit, etc.)
│   ├── TTD.lua           - Time To Die tracking (linear regression)
│   ├── Gear.lua          - Weapon detection (MH/OH speeds, damage)
│   └── Talents.lua       - Talent, spell rank, and racial detection
├── Combat/
│   ├── Stance.lua        - Stance detection and switching
│   ├── Casting.lua       - Spell casting helpers (Cast, CastSelf)
│   ├── SwingTimer.lua    - Swing timer + UNIT_CASTEVENT routing
│   ├── GUIDTargeting.lua - GUID-based spell casting (nameplates)
│   └── Interrupt.lua     - CastingTracker + auto-Pummel system
├── Detection/
│   ├── Distance.lua      - Range calculations (SuperWoW)
│   ├── CreatureType.lua  - Bleed immunity detection
│   └── AoE.lua           - Enemy counting, Rend tracking per GUID
├── Sim/
│   ├── Abilities.lua     - Ability definitions and damage formulas
│   ├── RageModel.lua     - Rage generation formulas (Zebouski)
│   ├── Strategic.lua     - Long-term cooldown planning (30s)
│   ├── Engine.lua        - Combat simulation engine (9s tactical)
│   └── Simulator.lua     - Time-window sim, cooldown toggles
├── Rotation/
│   └── Rotation.lua      - Main rotation execution logic
├── UI/
│   └── Display.lua       - Visual display frame
├── Commands/
│   ├── SlashCommands.lua - Chat commands (/atw)
│   └── Events.lua        - Event registration and handling
└── docs/
    ├── README.md         - This file
    ├── Architecture.md   - Code structure overview
    ├── Simulation.md     - Simulation engine details
    ├── Toggles.md        - Cooldown toggle system
    ├── Interrupt.md      - Auto-interrupt system
    ├── Rend.md           - Rend tracking system
    ├── TTD.md            - Time To Die algorithm
    ├── Spells.md         - Spell rank detection
    ├── AoE.md            - AoE detection
    ├── Detection.md      - SuperWoW/UnitXP detection
    └── SwingTimer.md     - Swing timer tracking
```

## How The Simulation Works

```
GetBestAction()
    ├── CacheValid?                    -- Skip if state unchanged (100ms min)
    │   └── Return cached result
    │
    ├── Strategic.GetPriorityCooldown() -- Check strategic layer
    │   └── High priority CD? → Use it (override tactical)
    │
    └── Tactical Simulation
        ├── CaptureCurrentState()      -- Full combat snapshot
        ├── GetValidActions()          -- Only LEARNED spells
        └── For each action:
                SimulateDecisionHorizon()  -- Simulate 9s (6 GCDs)
                        └── Greedy best action for remaining time
                                └── Sum total damage
                                        └── Return highest
```

The simulation handles complex mechanics automatically:
- **Charge**: Only valid if `not inCombat` and target at 8-25 yards
- **Slam**: Resets swing timer (penalty factored in)
- **Bloodrage**: Sets `inCombat = true` (blocks Charge if used first)
- **Battle Shout**: Does NOT trigger combat (can cast before Charge)
- **HS/Cleave**: Dynamic threshold - drops when main abilities on cooldown
- **Cooldowns**: Respects BurstEnabled/RecklessEnabled toggles
- **Interrupts**: Pummel prioritized when PummelEnabled and enemy casting

## Contributing

This addon is designed with modularity in mind. Each system is documented in detail to help understand and extend the codebase.

## Version History

- **Current**: Full simulation engine, hasSpell verification, Charge/Slam mechanics, multi-target Rend tracking
