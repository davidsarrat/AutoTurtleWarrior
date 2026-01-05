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
3. **Simulate Each** - For each action, simulate 6 seconds (4 GCDs) of combat
4. **Compare Damage** - Pick the action that yields highest total damage

This approach automatically handles edge cases like:
- Charge availability (out of combat only)
- Slam swing timer reset (2H weapons)
- Execute target dying to DoTs
- Multi-target Rend optimization
- Dynamic HS/Cleave thresholds

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
│   ├── Init.lua          - Addon initialization, defaults
│   └── Helpers.lua       - Utility functions (buffs, debuffs)
├── Player/
│   ├── Talents.lua       - Talent & spell detection
│   ├── Stats.lua         - Player statistics
│   ├── Gear.lua          - Weapon detection
│   └── TTD.lua           - Time To Die tracking
├── Detection/
│   ├── AoE.lua           - Enemy counting & Rend tracking
│   ├── Distance.lua      - Range calculations
│   └── CreatureType.lua  - Bleed immunity detection
├── Combat/
│   ├── Stance.lua        - Stance management
│   ├── Casting.lua       - Spell casting helpers
│   ├── SwingTimer.lua    - Swing timer tracking
│   └── GUIDTargeting.lua - GUID-based spell casting
├── Sim/
│   ├── Engine.lua        - Combat simulation engine
│   ├── Abilities.lua     - Ability definitions
│   ├── RageModel.lua     - Rage formulas
│   └── Simulator.lua     - Time-based simulation
├── Rotation/
│   └── Rotation.lua      - Main rotation logic
├── Commands/
│   ├── SlashCommands.lua - Chat commands
│   └── Events.lua        - Event handling
├── UI/
│   └── Display.lua       - Visual display
└── docs/                 - This documentation
```

## How The Simulation Works

```
GetBestAction()
    └── CaptureCurrentState()      -- Get full combat snapshot
            └── GetValidActions()  -- List valid actions (hasSpell checks!)
                    └── For each action:
                            SimulateDecisionHorizon()  -- Simulate 6s
                                    └── Compare total damage
                                            └── Return highest
```

The simulation handles complex mechanics automatically:
- **Charge**: Only valid if `not inCombat` and target at 8-25 yards
- **Slam**: Resets swing timer (penalty factored in)
- **Bloodrage**: Sets `inCombat = true` (blocks Charge if used first)
- **Battle Shout**: Does NOT trigger combat (can cast before Charge)
- **HS/Cleave**: Dynamic threshold - drops when main abilities on cooldown

## Contributing

This addon is designed with modularity in mind. Each system is documented in detail to help understand and extend the codebase.

## Version History

- **Current**: Full simulation engine, hasSpell verification, Charge/Slam mechanics, multi-target Rend tracking
