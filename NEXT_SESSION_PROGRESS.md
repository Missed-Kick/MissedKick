# Missed Kick - Next Session Handoff

Date: 2026-05-05

## Project Paths

- Dev repo: `E:\Dev\Missed Kick`
- Live WoW addon: `C:\Blizzard\World of Warcraft\_retail_\Interface\AddOns\MissedKick`
- Main files: `MissedKick.lua`, `UI.lua`, `MissedKick.toc`

## Current Live Build

- Build string: `2026-05-05-marker-outline-fallback`
- Check in game with: `/mk version`
- Debug toggle: `/mk debug`

## What Is Working

- Main Missed Kick kick tracker window works.
- Right-click lock/unlock menu works for the tracker.
- Frame position persistence works after reload.
- Player kick tracking works for Skull Bash, including Midnight spell ID variants.
- Party kick sync works if other players have the addon.
- Nearby Casts is now a separate movable window.
- Nearby cast rows show enemy and spell names.
- Nearby cast progress/fill works.
- Raid marker icon displays at the far right of nearby cast rows.
- Live addon folder has been kept in sync with the dev repo after each change.

## Current Focus

We were working on this feature:

> If the player selects an assigned raid marker in `/mk menu`, then nearby casts from enemies with that raid marker should get a red outline around the entire cast bar.

The exact match is blocked by Midnight secret values so far.

Observed debug:

```text
marker lookup unit=nameplate2 raw=1 clean=nil
marker lookup unit=nameplate4 raw=2 clean=nil
outline assigned=circle markerShown=true markerSecret=true eval=false reason=evaluate-failed
```

Meaning:

- `GetRaidTargetIndex(nameplate#)` returns a marker like `raw=2`, but it is a secret value.
- The addon can pass that secret marker into `SetRaidTargetIconTexture()` to display the icon.
- The addon cannot safely compare, convert, use as a table key, do arithmetic on, or evaluate that marker value in Lua.
- Combat log registration is protected in Midnight/Retail and should not be used.

## Current Fallback Behavior

Since exact marker matching is blocked, current live behavior is:

- If any marker is selected in `/mk menu`, any nearby cast row that successfully displays a raid marker gets a red outline.
- This is intentionally broader than the desired final behavior, but it avoids protected-value errors.

## Important Failed Approaches

- Direct compare: `rawMarker == selectedMarker` caused secret-value comparison problems.
- `tonumber(rawMarker)` plus arithmetic caused errors like secret number arithmetic.
- Using texture coordinates as a cache/table key caused secret-key table errors.
- Combat-log `COMBAT_LOG_EVENT_UNFILTERED` registration caused protected `RegisterEvent()` errors.
- `C_CurveUtil` marker-number curve evaluation failed with `eval=false reason=evaluate-failed`.

## Validation Commands

Dev syntax check:

```powershell
& 'C:\Users\chanc\AppData\Local\Programs\Lua\bin\luac.exe' -p 'E:\Dev\Missed Kick\MissedKick.lua' 'E:\Dev\Missed Kick\UI.lua'
```

Copy to live:

```powershell
Copy-Item -LiteralPath 'E:\Dev\Missed Kick\MissedKick.lua' -Destination 'C:\Blizzard\World of Warcraft\_retail_\Interface\AddOns\MissedKick\MissedKick.lua' -Force
Copy-Item -LiteralPath 'E:\Dev\Missed Kick\UI.lua' -Destination 'C:\Blizzard\World of Warcraft\_retail_\Interface\AddOns\MissedKick\UI.lua' -Force
```

Live syntax check:

```powershell
& 'C:\Users\chanc\AppData\Local\Programs\Lua\bin\luac.exe' -p 'C:\Blizzard\World of Warcraft\_retail_\Interface\AddOns\MissedKick\MissedKick.lua' 'C:\Blizzard\World of Warcraft\_retail_\Interface\AddOns\MissedKick\UI.lua'
```

Hash check:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath 'E:\Dev\Missed Kick\MissedKick.lua','C:\Blizzard\World of Warcraft\_retail_\Interface\AddOns\MissedKick\MissedKick.lua','E:\Dev\Missed Kick\UI.lua','C:\Blizzard\World of Warcraft\_retail_\Interface\AddOns\MissedKick\UI.lua' | Format-Table -AutoSize
```

## Suggested Next Session Steps

1. Confirm `/mk version` shows `2026-05-05-marker-outline-fallback`.
2. Confirm the fallback outline appears on marked nearby cast bars.
3. Decide whether fallback is acceptable for now.
4. If exact marker matching is still required, investigate whether Blizzard exposes any allowed secret-aware predicate/API for raid target comparison. Avoid direct Lua compare, table keys, arithmetic, texture-coordinate reads, and combat log.
5. Clean up debug logs and build string once the chosen behavior is settled.

