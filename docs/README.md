# AutoTurtleWarrior Documentation

A comprehensive Fury Warrior rotation addon for TurtleWoW (1.12 vanilla client with custom extensions).

## Table of Contents

1. [Architecture Overview](Architecture.md) - Code structure and module organization
2. [Detection Systems](Detection.md) - SuperWoW, UnitXP, creature types, bleed immunity
3. [Simulation Engine](Simulation.md) - DPR-based priority system and combat simulation
4. [Rend Tracking](Rend.md) - Multi-target Rend tracking via combat log and GUID
5. [Time To Die (TTD)](TTD.md) - Linear regression algorithm for death prediction
6. [Spell & Talent System](Spells.md) - Dynamic spell rank detection and talent loading
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

### Intelligent Rotation
- DPR (Damage Per Rage) based ability prioritization
- Stance dancing with Tactical Mastery support
- Execute phase detection and targeting
- Heroic Strike/Cleave queue management

### Multi-Target Support
- Nameplate-based enemy counting
- GUID-based Rend tracking across multiple targets
- Intelligent Rend spreading decisions
- Sweeping Strikes optimization

### Combat Analysis
- Real-time TTD (Time To Die) calculation
- HP percentage tracking for all nearby enemies
- Bleed immunity detection by creature type
- Combat simulation for strategy comparison

## Debug Commands

| Command | Description |
|---------|-------------|
| `/atw rendtest` | Debug Rend detection methods |
| `/atw spells` | Show detected spell ranks |
| `/atw ttd` | Show TTD tracking info |
| `/atw hp` | Debug HP detection |
| `/atw mob` | Show creature type detection |
| `/atw aoe` | Show AoE analysis |
| `/atw sim` | Run damage simulation |
| `/atw engine` | Full 20s combat simulation |

## File Structure

```
AutoTurtleWarrior/
├── Core/
│   ├── Init.lua          - Addon initialization
│   ├── Config.lua        - Default configuration
│   └── Helpers.lua       - Utility functions
├── Player/
│   ├── Talents.lua       - Talent & spell detection
│   ├── Stats.lua         - Player statistics
│   └── TTD.lua           - Time To Die tracking
├── Detection/
│   ├── AoE.lua           - Enemy counting & Rend tracking
│   ├── Distance.lua      - Range calculations
│   └── CreatureType.lua  - Bleed immunity detection
├── Rotation/
│   ├── Rotation.lua      - Main rotation logic
│   └── Stances.lua       - Stance management
├── Combat/
│   ├── SwingTimer.lua    - Swing timer tracking
│   └── GUIDTargeting.lua - GUID-based spell casting
├── Sim/
│   ├── Engine.lua        - Combat simulation engine
│   ├── Abilities.lua     - Ability definitions
│   └── Simulator.lua     - Time-based simulation
├── Commands/
│   ├── SlashCommands.lua - Chat commands
│   └── Events.lua        - Event handling
├── UI/
│   └── Display.lua       - Visual display
└── docs/                 - This documentation
```

## Contributing

This addon is designed with modularity in mind. Each system is documented in detail to help understand and extend the codebase.

## Version History

- **Current**: Full simulation engine, multi-target Rend tracking, dynamic spell ranks
