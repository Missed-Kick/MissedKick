# Missed Kick

A lightweight World of Warcraft addon that tracks interrupt cooldowns for your party and displays nearby enemy casts that need to be kicked.

## Features

### 🎯 Interrupt Cooldown Tracker
- Automatically detects when you use your interrupt ability
- Shows cooldown status for all party members running the addon
- Supports all 12 class interrupts (Kick, Pummel, Counterspell, Wind Shear, Disrupt, Mind Freeze, Skull Bash, Counter Shot, Spear Hand Strike, Rebuke, Silence, Spell Lock)

### 🔄 Silent Party Sync
- Automatically shares your interrupt cooldown with party members
- No visible chat messages — uses Blizzard's addon messaging system
- Party members without the addon show as "Unknown"

### 📡 Nearby Cast Tracker
- Scans visible enemy nameplates for active casts and channels
- Shows enemy name, spell name, and target (when available)
- Displays raid markers on enemies

### ⚠️ Dangerous Cast Alerts
- Mark specific spells as "dangerous" for visual highlighting
- Assign yourself a raid marker responsibility
- Casts from enemies with your assigned marker are labeled **YOUR KICK**

## Slash Commands

| Command | Description |
|---------|-------------|
| `/mk show` | Show the tracker frame |
| `/mk hide` | Hide the tracker frame |
| `/mk lock` | Lock the frame position |
| `/mk unlock` | Unlock the frame for repositioning |
| `/mk test` | Populate fake data for UI testing |
| `/mk reset` | Clear all tracked cooldowns |
| `/mk marker <name>` | Assign a raid marker (star/circle/diamond/triangle/moon/square/cross/skull/none) |
| `/mk dangerous add <id or name>` | Add a spell to the dangerous list |
| `/mk dangerous remove <id or name>` | Remove a spell from the dangerous list |
| `/mk dangerous list` | Show all configured dangerous casts |
| `/mk help` | Show command reference |

## Installation

### Manual
1. Download the latest release zip
2. Extract to `World of Warcraft/_retail_/Interface/AddOns/`
3. Ensure the folder is named `MissedKick`
4. Restart WoW or `/reload`

### WowUp
1. Add the GitHub repository URL as a custom addon source
2. WowUp will detect new releases automatically

## How It Works

### Kick Sync System
When you cast an interrupt ability, the addon:
1. Detects the cast via `UNIT_SPELLCAST_SUCCEEDED`
2. Reads the actual cooldown duration via `C_Spell.GetSpellCooldown`
3. Broadcasts `KICK;spellID;duration` to party members via `C_ChatInfo.SendAddonMessage`
4. Other addon users receive the message and update your cooldown display

This means cooldowns are tracked even if your interrupt doesn't successfully stop a cast (e.g., the enemy finishes casting before your kick lands).

### Nearby Cast Scanning
The addon scans `nameplate1` through `nameplate40` every 0.2 seconds. For each hostile unit that is currently casting or channeling, it collects:
- Enemy name and spell name
- Cast target (best-effort — the API may restrict this)
- Raid marker index

This data is displayed in the "Nearby Casts" section of the frame.

## Requirements
- World of Warcraft: The War Within (12.0+)
- Party members need the addon for kick sync to work

## License
MIT
