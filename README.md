# Missed Kick

Missed Kick is a lightweight World of Warcraft Retail addon for interrupt tracking and nearby cast awareness.

## Features

- Tracks your interrupt cooldown immediately after you cast it.
- Syncs interrupt cooldowns with party members who also have Missed Kick installed.
- Shows a separate Nearby Casts window for visible enemy nameplate casts and channels.
- Shows raid markers on Nearby Casts rows when Blizzard exposes the marker.
- Outlines Nearby Casts rows that match your assigned raid marker.
- Colors Nearby Casts bars red when a cast appears to target you and grey otherwise.
- Uses Blizzard's protected important-spell flag, when available, to tint important cast text gold.
- Supports a global load mode: everywhere or dungeons only.

## Installation

Copy the addon folder to:

```text
World of Warcraft/_retail_/Interface/AddOns/MissedKick
```

Then restart WoW or run `/reload`.

## Commands

| Command | Description |
| --- | --- |
| `/mk help` | Show the command list. |
| `/mk menu` | Open the settings menu. |
| `/mk center` | Move the tracker windows back near the center. |
| `/mk test` | Populate test kick and cast data. |
| `/mk reset` | Clear tracked cooldown data. |
| `/mk debug` | Toggle debug logging in chat. |
| `/mk fakeparty` | Simulate a party member kick. |
| `/mk version` | Show the loaded build string. |

## Settings

Open `/mk menu` to configure:

- Load mode: everywhere or dungeons only.
- Kick Tracker enabled or disabled.
- Nearby Casts enabled or disabled.
- Your assigned raid marker for cast-row outlining.

The tracker windows can be moved by dragging their headers. Right-click a window header and use the Lock Frame or Unlock Frame button to lock or unlock movement.

## Party Sync

Missed Kick can always track your own interrupt cooldown locally. To see another party member's cooldown reliably, that player also needs Missed Kick installed. The addon syncs cooldown messages through Blizzard's addon messaging system.

## Nearby Casts

Nearby Casts scans visible enemy nameplates, so nameplates need to be enabled in WoW for best results. The addon reads cast and channel information from nameplate unit APIs and combat-log metadata when available.

World of Warcraft Midnight protects some spell data as secret values. Because of that, Missed Kick does not maintain a custom imported dangerous-spell list. Custom spell-ID comparison is not reliable when Blizzard hides the ID or name from addon code. Instead, the addon uses Blizzard's own important-spell flag when available.

## Testing

- `/mk test` creates local sample rows for the kick tracker and nearby casts window.
- `/mk fakeparty` simulates a synced kick from another party member.
- `/mk debug` prints cast, marker, and sync diagnostics to the chat frame.

## Requirements

- World of Warcraft Retail / Midnight-era API.
- Party members need the addon for party kick sync.
