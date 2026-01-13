# AutoTurtleWarrior Documentation

A comprehensive Fury Warrior rotation addon for TurtleWoW (1.12 vanilla client with custom extensions).

## Table of Contents

1. [Architecture Overview](Architecture.md) - Code structure and module organization
2. [Simulation Engine](Simulation.md) - 100% simulation-based decisions (stance switches, swing timers)
3. [Toggles](Toggles.md) - Cooldown toggles (Burst, Reckless, Sync) and AoE modes
4. [Interrupt System](Interrupt.md) - CastingTracker and auto-Pummel
5. [Detection Systems](Detection.md) - SuperWoW, UnitXP, creature types, bleed immunity
6. [Rend Tracking](Rend.md) - Multi-target Rend tracking via combat log and GUID
7. [Time To Die (TTD)](TTD.md) - Linear regression algorithm for death prediction
8. [Spell & Talent System](Spells.md) - Dynamic spell rank detection and spell verification
9. [AoE Detection](AoE.md) - Nameplate scanning and enemy counting
10. [Swing Timer](SwingTimer.md) - Main-hand/off-hand swing tracking
11. [Changelog](CHANGELOG.md) - Version history and recent changes

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

**Single-Layer Tactical Simulation:**
- Runs every frame (with caching): Decides immediate ability with 9s lookahead
- Cooldowns controlled via manual toggles (`/atw burst`, `/atw reckless`)
- Optional CD sync waits for Death Wish before using racials (`/atw sync`)

This approach automatically handles edge cases like:
- Charge availability (out of combat only)
- Slam swing timer reset (2H weapons)
- Execute target dying to DoTs
- Multi-target Rend optimization
- Dynamic HS/Cleave thresholds
- Cooldown synergy (Death Wish + racials stacking)
- 2H vs 1H weapon detection (dynamic normalization)
- Smart Battle Shout override (only cast if yours is better)

### Event-Driven Responsiveness

- **Instant cache invalidation** on relevant game events (SPELL_UPDATE_COOLDOWN, UNIT_POWER, UNIT_AURA)
- **<10ms response time** to cooldown completion, rage changes, or buff expiration
- **Real melee range validation** (<= 5 yards) prevents wasted keypresses after knockback
- **Smart swing timer tracking** - forces recalculation when MH swing is imminent (< 300ms)

### Intelligent Rotation

- Stance dancing with Tactical Mastery support
- Execute phase detection and targeting
- Heroic Strike/Cleave queue management
- Dynamic thresholds based on ability availability
- **2H weapon detection** with automatic normalization (3.3 for 2H, 2.4 for 1H)

### Multi-Target Support

- Nameplate-based enemy counting
- GUID-based Rend tracking across multiple targets
- Per-enemy Rend decisions via simulation
- Sweeping Strikes optimization

### Smart Buff Management

- **Battle Shout Override Protection**: Tooltip scanning + AP comparison prevents overriding superior buffs
  - Compares your Battle Shout AP (rank + talent) vs active buff AP
  - Only casts if yours is better (+5 AP threshold to avoid spam)
  - Example: Won't override another warrior's 290 AP buff with your 232 AP buff

### Combat Analysis

- Real-time TTD (Time To Die) calculation via linear regression
- HP percentage tracking for all nearby enemies
- Bleed immunity detection by creature type
- Distance tracking for Charge range

### Complete Talent Support

**Fury DPS:**
- All major talents implemented (Dual Wield Specialization, Improved Battle Shout, Cruelty, Unbridled Wrath, Flurry, Death Wish, Bloodthirst, Improved Whirlwind)
- Dual Wield Specialization: +25% offhand damage at 5 points (~5-10% total DPS increase)
- Improved Battle Shout: +25% Battle Shout AP at 5 points (232 AP → 290 AP)

**Arms DPS:**
- All major talents implemented (Two-Handed Weapon Specialization, Improved Battle Shout, Improved Rend, Tactical Mastery, Deep Wounds, Impale, Mortal Strike)
- Two-Handed Weapon Specialization: +5% damage with 2H weapons at 5 points
- Dynamic weapon normalization (3.3 for 2H, 2.4 for 1H) for Whirlwind and Mortal Strike
- Unbridled Wrath 2H bonus: +2 rage per proc with 2H (vs +1 with 1H)

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
│   ├── Strategic.lua     - Cooldown synergy planning
│   ├── Engine.lua        - Combat simulation engine (3400+ lines)
│   └── Simulator.lua     - Cooldown toggles, GetNextAbility wrapper
├── Rotation/
│   └── Rotation.lua      - Main rotation execution logic
├── UI/
│   └── Display.lua       - Visual display frame
├── Commands/
│   ├── SlashCommands.lua - Chat commands (/atw)
│   └── Events.lua        - Event registration and handling
└── Documentation/
    ├── README.md         - This file
    ├── CHANGELOG.md      - Version history and changes
    ├── Architecture.md   - Code structure overview
    ├── Simulation.md     - Simulation engine details
    ├── Toggles.md        - Cooldown & mode toggle system
    ├── Interrupt.md      - Auto-interrupt system
    ├── Rend.md           - Rend tracking system
    ├── TTD.md            - Time To Die algorithm
    ├── Spells.md         - Spell rank detection
    ├── AoE.md            - AoE detection & Sweeping Strikes
    ├── Detection.md      - SuperWoW/UnitXP detection
    └── SwingTimer.md     - Swing timer tracking
```

## How The Simulation Works

```
GetBestAction()
    ├── CacheValid?                    -- Skip if state unchanged (100ms min)
    │   └── Return cached result
    │
    └── Tactical Simulation
        ├── CaptureCurrentState()      -- Full combat snapshot
        ├── GetValidActions()          -- Only LEARNED spells + CD sync
        │   └── Racials wait for DW if SyncCooldowns enabled
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
