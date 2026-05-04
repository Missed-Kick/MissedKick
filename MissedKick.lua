-------------------------------------------------------------------------------
-- MissedKick - Core Logic v1.0
--
-- Interrupt cooldown tracker with silent party sync.
--
-- SYSTEM OVERVIEW:
--   1. Listens for UNIT_SPELLCAST_SUCCEEDED on "player" to detect when the
--      local player uses an interrupt ability.
--   2. Queries C_Spell.GetSpellCooldown(spellID) to get the real cooldown
--      duration (accounts for haste, talents, etc.).
--   3. Broadcasts the kick event + cooldown to party members via
--      C_ChatInfo.SendAddonMessage using the "MISSEDKICK" prefix.
--   4. Receives broadcasts from other addon users and updates their
--      cooldown state in the party tracker.
--   5. Members without the addon show as "Unknown" status.
--
-- NEARBY CAST SCANNING:
--   Scans nameplate1..nameplate40 on a throttled timer. For each hostile
--   unit currently casting or channeling, gathers: enemy name, spell name,
--   target name (best-effort), and raid marker index. This data feeds the
--   UI's "Nearby Casts" section.
-------------------------------------------------------------------------------

local ADDON_NAME = "MissedKick"
local ADDON_PREFIX = "MISSEDKICK"

-------------------------------------------------------------------------------
-- Interrupt Spell Table
-- spellID → { name, cd (base cooldown in seconds) }
-- Icons are resolved at runtime via C_Spell.GetSpellTexture for accuracy.
-------------------------------------------------------------------------------
local INTERRUPT_SPELLS = {
    [1766]   = { name = "Kick",              cd = 15 },  -- Rogue
    [6552]   = { name = "Pummel",            cd = 15 },  -- Warrior
    [2139]   = { name = "Counterspell",      cd = 24 },  -- Mage
    [57994]  = { name = "Wind Shear",        cd = 12 },  -- Shaman
    [183752] = { name = "Disrupt",           cd = 15 },  -- Demon Hunter
    [47528]  = { name = "Mind Freeze",       cd = 15 },  -- Death Knight
    [106839] = { name = "Skull Bash",        cd = 15 },  -- Druid
    [147362] = { name = "Counter Shot",      cd = 24 },  -- Hunter
    [116705] = { name = "Spear Hand Strike", cd = 15 },  -- Monk
    [96231]  = { name = "Rebuke",            cd = 15 },  -- Paladin
    [15487]  = { name = "Silence",           cd = 45 },  -- Priest
    [19647]  = { name = "Spell Lock",        cd = 24 },  -- Warlock
}

-- Build a reverse lookup: spellID set for fast checking
local INTERRUPT_IDS = {}
for id in pairs(INTERRUPT_SPELLS) do
    INTERRUPT_IDS[id] = true
end

-------------------------------------------------------------------------------
-- Raid Marker Constants
-------------------------------------------------------------------------------
local MARKER_NAMES = {
    star     = 1,
    circle   = 2,
    diamond  = 3,
    triangle = 4,
    moon     = 5,
    square   = 6,
    cross    = 7,
    skull    = 8,
    none     = 0,
}

-- Raid marker icon textures (used in UI display)
local MARKER_ICONS = {
    [1] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1",  -- Star
    [2] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_2",  -- Circle
    [3] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3",  -- Diamond
    [4] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4",  -- Triangle
    [5] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5",  -- Moon
    [6] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6",  -- Square
    [7] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7",  -- Cross
    [8] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",  -- Skull
}

local MARKER_NAME_FROM_INDEX = {}
for name, idx in pairs(MARKER_NAMES) do
    if idx > 0 then MARKER_NAME_FROM_INDEX[idx] = name end
end

-------------------------------------------------------------------------------
-- Defaults for SavedVariables
-------------------------------------------------------------------------------
local DEFAULTS = {
    myMarker       = "none",
    dangerousCasts = {},     -- { [spellID_number] = true, ["Spell Name"] = true }
    framePos       = nil,    -- { point, relPoint, x, y }
    frameLocked    = false,
}

-------------------------------------------------------------------------------
-- Runtime State
-------------------------------------------------------------------------------
local db                 -- reference to MissedKickDB after ADDON_LOADED
local myName             -- player's name (short, no realm)
local mySpellID          -- the player's known interrupt spellID, or nil
local mySpellCD          -- actual cooldown duration for the player's interrupt

-- Party cooldown tracking:
-- partyKicks[name] = { spellID, cdEnd, hasAddon }
--   spellID = interrupt spell ID (nil if unknown)
--   cdEnd   = GetTime() at which CD expires (0 = ready)
--   hasAddon = true if this player has sent us addon messages
local partyKicks = {}

-- Nearby cast data (rebuilt every scan tick):
-- nearbyCasts[i] = { unit, enemyName, spellName, spellID, targetName, markerIndex }
local nearbyCasts = {}

-- Rate limiting for addon messages
local lastBroadcast = 0
local BROADCAST_THROTTLE = 0.5  -- seconds between broadcasts

-------------------------------------------------------------------------------
-- Public API (accessed by UI.lua)
-------------------------------------------------------------------------------
MissedKick = {
    INTERRUPT_SPELLS    = INTERRUPT_SPELLS,
    INTERRUPT_IDS       = INTERRUPT_IDS,
    MARKER_NAMES        = MARKER_NAMES,
    MARKER_ICONS        = MARKER_ICONS,
    MARKER_NAME_FROM_INDEX = MARKER_NAME_FROM_INDEX,
    partyKicks          = partyKicks,
    nearbyCasts         = nearbyCasts,
}

function MissedKick.GetDB()       return db end
function MissedKick.GetMyName()   return myName end
function MissedKick.GetMySpellID() return mySpellID end

-------------------------------------------------------------------------------
-- Utility: chat print with addon prefix
-------------------------------------------------------------------------------
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff4444Missed|r|cffffcc00Kick|r: " .. msg)
end
MissedKick.Print = Print

-------------------------------------------------------------------------------
-- Spell Icon Resolution
-- Uses the runtime API first, falls back to a hardcoded default.
-------------------------------------------------------------------------------
local iconCache = {}

local function GetInterruptIcon(spellID)
    if not spellID then return nil end
    if iconCache[spellID] then return iconCache[spellID] end
    -- Try runtime API
    local ok, tex = pcall(function()
        return C_Spell.GetSpellTexture(spellID)
    end)
    if ok and tex then
        iconCache[spellID] = tex
        return tex
    end
    -- Fallback: generic interrupt icon
    iconCache[spellID] = "Interface\\Icons\\ability_kick"
    return iconCache[spellID]
end
MissedKick.GetInterruptIcon = GetInterruptIcon

-------------------------------------------------------------------------------
-- Find the player's interrupt spell
-- Checks the spellbook for each known interrupt. The first match wins.
-------------------------------------------------------------------------------
local function FindMyInterrupt()
    mySpellID = nil
    mySpellCD = nil
    for spellID, data in pairs(INTERRUPT_SPELLS) do
        local known = false
        -- Check player spellbook
        local ok1, result1 = pcall(C_SpellBook.IsSpellInSpellBook, spellID, Enum.SpellBookSpellBank.Player)
        if ok1 and result1 then known = true end
        -- Check pet spellbook (for Warlock Spell Lock)
        if not known then
            local ok2, result2 = pcall(C_SpellBook.IsSpellInSpellBook, spellID, Enum.SpellBookSpellBank.Pet)
            if ok2 and result2 then known = true end
        end
        -- Fallback: IsSpellKnown
        if not known then
            local ok3, result3 = pcall(IsSpellKnown, spellID)
            if ok3 and result3 then known = true end
        end
        if known then
            mySpellID = spellID
            -- Try to read the actual cooldown duration from the API
            local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
            if ok and info then
                local okD, dur = pcall(function() return info.duration end)
                if okD and dur and dur > 1.5 then
                    mySpellCD = dur
                end
            end
            -- Fallback to table value
            if not mySpellCD then
                mySpellCD = data.cd
            end
            break
        end
    end
end

-------------------------------------------------------------------------------
-- Read actual cooldown from API (called after each kick to get talent/haste-
-- adjusted value). Updates mySpellCD if successful.
-------------------------------------------------------------------------------
local function RefreshCooldownDuration()
    if not mySpellID then return end
    local ok, info = pcall(C_Spell.GetSpellCooldown, mySpellID)
    if ok and info then
        local okD, dur = pcall(function() return info.duration end)
        if okD and dur and dur > 1.5 then
            mySpellCD = dur
            return dur
        end
    end
    return mySpellCD or INTERRUPT_SPELLS[mySpellID].cd
end

-------------------------------------------------------------------------------
-- Party Roster Management
-- Rebuilds the party list, preserving existing cooldown data for members
-- who are still in the group.
-------------------------------------------------------------------------------
local function RebuildPartyRoster()
    local keepNames = {}

    -- Always include self
    keepNames[myName] = true
    if not partyKicks[myName] then
        partyKicks[myName] = { spellID = mySpellID, cdEnd = 0, hasAddon = true }
    else
        partyKicks[myName].spellID = mySpellID
        partyKicks[myName].hasAddon = true
    end

    -- Party/raid members
    local numGroup = GetNumGroupMembers()
    if numGroup > 0 then
        local prefix = IsInRaid() and "raid" or "party"
        local count = IsInRaid() and numGroup or (numGroup - 1)
        for i = 1, count do
            local unit = prefix .. i
            if UnitExists(unit) and UnitIsPlayer(unit) then
                local name = UnitName(unit)
                if name and name ~= myName then
                    keepNames[name] = true
                    if not partyKicks[name] then
                        partyKicks[name] = { spellID = nil, cdEnd = 0, hasAddon = false }
                    end
                end
            end
        end
    end

    -- Purge members who left
    for name in pairs(partyKicks) do
        if not keepNames[name] then
            partyKicks[name] = nil
        end
    end
end

-------------------------------------------------------------------------------
-- Addon Message Broadcasting
-- Sends kick data to party members who also have the addon.
--
-- Protocol: "KICK;spellID;cooldownDuration"
-- Channel: PARTY or INSTANCE_CHAT (whichever is appropriate)
-------------------------------------------------------------------------------
local function BroadcastKick(spellID, cd)
    local now = GetTime()
    if now - lastBroadcast < BROADCAST_THROTTLE then return end
    lastBroadcast = now

    local payload = "KICK;" .. spellID .. ";" .. string.format("%.1f", cd)

    local inInstance = IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    local inHome     = IsInGroup(LE_PARTY_CATEGORY_HOME)

    if inInstance then
        pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX, payload, "INSTANCE_CHAT")
    elseif inHome then
        pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX, payload, "PARTY")
    end
end

-------------------------------------------------------------------------------
-- Addon Message Receiving
-- Parses incoming MISSEDKICK messages and updates partyKicks.
-------------------------------------------------------------------------------
local function OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= ADDON_PREFIX then return end

    -- Strip realm from sender name
    local shortName = Ambiguate(sender, "short")
    if shortName == myName then return end  -- ignore self

    local parts = { strsplit(";", message) }
    local cmd = parts[1]

    if cmd == "KICK" then
        local spellID = tonumber(parts[2])
        local cd      = tonumber(parts[3])
        if spellID and cd and cd > 0 then
            local entry = partyKicks[shortName]
            if entry then
                entry.spellID  = spellID
                entry.cdEnd    = GetTime() + cd
                entry.hasAddon = true
            else
                -- Player not in our roster yet (race condition with GROUP_ROSTER_CHANGED)
                partyKicks[shortName] = {
                    spellID  = spellID,
                    cdEnd    = GetTime() + cd,
                    hasAddon = true,
                }
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Interrupt Detection via UNIT_SPELLCAST_SUCCEEDED
-- This fires for every successful spell cast by the player. We check if the
-- spell ID matches any known interrupt ability.
-------------------------------------------------------------------------------
local function OnSpellcastSucceeded(unit, castGUID, spellID)
    if unit ~= "player" then return end
    if not INTERRUPT_IDS[spellID] then return end

    -- Refresh cooldown from the API (talent/haste adjusted)
    local cd = RefreshCooldownDuration()

    -- Update own state
    local entry = partyKicks[myName]
    if entry then
        entry.spellID = spellID
        entry.cdEnd   = GetTime() + cd
    end

    -- Broadcast to party
    BroadcastKick(spellID, cd)
end

-------------------------------------------------------------------------------
-- Nearby Cast Scanning
-- Called on a throttled timer from the UI's OnUpdate. Scans all visible
-- enemy nameplates and collects casting/channeling information.
--
-- API NOTES:
--   UnitCastingInfo / UnitChannelInfo may return nil for enemies whose
--   nameplates are not visible or whose cast data is restricted by the API.
--   We fail gracefully by skipping those units.
--   Target info via UnitName(unit.."target") is best-effort — the API may
--   not always expose enemy target data.
-------------------------------------------------------------------------------
local function ScanNearbyCasts()
    -- Wipe and rebuild (reuses the same table to avoid allocations)
    for i = #nearbyCasts, 1, -1 do
        nearbyCasts[i] = nil
    end

    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitCanAttack("player", unit) then
            -- Check for casting
            local castName, _, _, castStartTime, castEndTime, _, _, castNotInterruptible, castSpellID
            local channelName, _, _, channelStartTime, channelEndTime, _, channelNotInterruptible, channelSpellID
            local isCasting = false
            local isChanneling = false

            -- Try UnitCastingInfo first
            local ok1, c1, c2, c3, c4, c5, c6, c7, c8, c9 = pcall(UnitCastingInfo, unit)
            if ok1 and c1 then
                castName = c1
                castSpellID = c9
                isCasting = true
            end

            -- If not casting, try UnitChannelInfo
            if not isCasting then
                local ok2, ch1, ch2, ch3, ch4, ch5, ch6, ch7, ch8 = pcall(UnitChannelInfo, unit)
                if ok2 and ch1 then
                    channelName = ch1
                    channelSpellID = ch8
                    isChanneling = true
                end
            end

            if isCasting or isChanneling then
                local spellName = isCasting and castName or channelName
                local spellID   = isCasting and castSpellID or channelSpellID

                -- Enemy name
                local enemyName = UnitName(unit) or "Unknown"

                -- Target name (best-effort)
                local targetName = nil
                local okT, tName = pcall(UnitName, unit .. "target")
                if okT and tName then
                    targetName = tName
                end

                -- Raid marker
                local markerIndex = nil
                local okM, mIdx = pcall(GetRaidTargetIndex, unit)
                if okM and mIdx then
                    markerIndex = mIdx
                end

                nearbyCasts[#nearbyCasts + 1] = {
                    unit        = unit,
                    enemyName   = enemyName,
                    spellName   = spellName or "Unknown Spell",
                    spellID     = spellID,
                    targetName  = targetName,
                    markerIndex = markerIndex,
                }
            end
        end
    end
end
MissedKick.ScanNearbyCasts = ScanNearbyCasts

-------------------------------------------------------------------------------
-- Dangerous Cast Checking
-- Returns: isDangerous, isYourKick
-------------------------------------------------------------------------------
function MissedKick.IsDangerousCast(spellID, spellName, markerIndex)
    if not db then return false, false end
    local isDangerous = false

    -- Check by spell ID first (preferred)
    if spellID and db.dangerousCasts[spellID] then
        isDangerous = true
    end

    -- Check by spell name as fallback
    if not isDangerous and spellName and db.dangerousCasts[spellName] then
        isDangerous = true
    end

    -- Check if this is YOUR KICK (dangerous + matching marker)
    local isYourKick = false
    if isDangerous and db.myMarker ~= "none" then
        local myMarkerIdx = MARKER_NAMES[db.myMarker]
        if myMarkerIdx and myMarkerIdx > 0 and markerIndex == myMarkerIdx then
            isYourKick = true
        end
    end

    return isDangerous, isYourKick
end

-------------------------------------------------------------------------------
-- Test Mode: populate fake data for UI testing
-------------------------------------------------------------------------------
local function PopulateTestData()
    -- Ensure player entry exists
    if myName then
        partyKicks[myName] = {
            spellID  = mySpellID or 1766,
            cdEnd    = GetTime() + 8,
            hasAddon = true,
        }
    end

    -- Fake party members
    local fakeMembers = {
        { name = "Stabsworth",  spellID = 1766,   cd = 12  },
        { name = "Smashface",   spellID = 6552,   cd = 0   },
        { name = "Frostweaver", spellID = 2139,   cd = 20  },
        { name = "Stormcaller", spellID = 57994,  cd = 5   },
        { name = "Shadowbane",  spellID = nil,     cd = 0   },  -- Unknown
    }
    for _, m in ipairs(fakeMembers) do
        partyKicks[m.name] = {
            spellID  = m.spellID,
            cdEnd    = m.cd > 0 and (GetTime() + m.cd) or 0,
            hasAddon = m.spellID ~= nil,
        }
    end

    -- Fake nearby casts
    for i = #nearbyCasts, 1, -1 do nearbyCasts[i] = nil end
    nearbyCasts[1] = {
        unit = "nameplate1", enemyName = "Vile Caster",
        spellName = "Shadow Bolt", spellID = 686,
        targetName = "Smashface", markerIndex = 8,
    }
    nearbyCasts[2] = {
        unit = "nameplate2", enemyName = "Fel Channeler",
        spellName = "Drain Life", spellID = 234153,
        targetName = nil, markerIndex = 2,
    }
    nearbyCasts[3] = {
        unit = "nameplate3", enemyName = "Dark Ritualist",
        spellName = "Fear", spellID = 5782,
        targetName = myName, markerIndex = nil,
    }

    Print("|cff00ff00Test data populated.|r Use |cff88ccff/mk reset|r to clear.")
end

-------------------------------------------------------------------------------
-- Reset: clear all tracked cooldowns
-------------------------------------------------------------------------------
local function ResetData()
    for name in pairs(partyKicks) do
        partyKicks[name] = nil
    end
    for i = #nearbyCasts, 1, -1 do
        nearbyCasts[i] = nil
    end
    -- Re-add self
    FindMyInterrupt()
    RebuildPartyRoster()
    Print("|cff00ff00Cooldown data reset.|r")
end

-------------------------------------------------------------------------------
-- Slash Command Handler
-------------------------------------------------------------------------------
local function HandleSlash(msg)
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = (cmd or ""):lower()
    arg = (arg or ""):lower()

    if cmd == "" or cmd == "help" then
        Print("|cffffffccCommands:|r")
        Print("  /mk show — Show tracker")
        Print("  /mk hide — Hide tracker")
        Print("  /mk lock — Lock frame position")
        Print("  /mk unlock — Unlock frame (draggable)")
        Print("  /mk test — Populate test data")
        Print("  /mk reset — Clear all cooldowns")
        Print("  /mk marker <name> — Set your raid marker (star/circle/diamond/triangle/moon/square/cross/skull/none)")
        Print("  /mk dangerous add <spellID or name> — Add dangerous cast")
        Print("  /mk dangerous remove <spellID or name> — Remove dangerous cast")
        Print("  /mk dangerous list — List dangerous casts")

    elseif cmd == "show" then
        if MissedKick_ShowFrame then MissedKick_ShowFrame() end

    elseif cmd == "hide" then
        if MissedKick_HideFrame then MissedKick_HideFrame() end

    elseif cmd == "lock" then
        if db then db.frameLocked = true end
        Print("Frame |cff00ff00locked|r.")
        if MissedKick_UpdateLock then MissedKick_UpdateLock() end

    elseif cmd == "unlock" then
        if db then db.frameLocked = false end
        Print("Frame |cffff8800unlocked|r — drag the header to move.")
        if MissedKick_UpdateLock then MissedKick_UpdateLock() end

    elseif cmd == "test" then
        PopulateTestData()
        if MissedKick_ShowFrame then MissedKick_ShowFrame() end

    elseif cmd == "reset" then
        ResetData()

    elseif cmd == "marker" then
        if arg == "" then
            local current = db and db.myMarker or "none"
            Print("Current marker: |cffffcc00" .. current .. "|r")
            Print("Usage: /mk marker <star|circle|diamond|triangle|moon|square|cross|skull|none>")
            return
        end
        if MARKER_NAMES[arg] ~= nil then
            db.myMarker = arg
            if arg == "none" then
                Print("Marker assignment |cff888888cleared|r.")
            else
                Print("Marker set to |cffffcc00" .. arg .. "|r. Dangerous casts on this target will show as YOUR KICK.")
            end
            if MissedKick_RefreshUI then MissedKick_RefreshUI() end
        else
            Print("|cffff0000Unknown marker:|r " .. arg)
            Print("Valid: star, circle, diamond, triangle, moon, square, cross, skull, none")
        end

    elseif cmd == "dangerous" then
        local subcmd, subarg = arg:match("^(%S+)%s*(.*)$")
        subcmd = (subcmd or ""):lower()

        if subcmd == "add" and subarg and subarg ~= "" then
            local numID = tonumber(subarg)
            if numID then
                db.dangerousCasts[numID] = true
                Print("Added dangerous cast: spell ID |cffffcc00" .. numID .. "|r")
            else
                -- Store by name (original case from user input)
                local originalArg = msg:match("^%S+%s+%S+%s+(.+)$") or subarg
                db.dangerousCasts[originalArg] = true
                Print("Added dangerous cast: |cffffcc00" .. originalArg .. "|r")
            end

        elseif subcmd == "remove" and subarg and subarg ~= "" then
            local numID = tonumber(subarg)
            if numID then
                db.dangerousCasts[numID] = nil
                Print("Removed dangerous cast: spell ID |cffffcc00" .. numID .. "|r")
            else
                local originalArg = msg:match("^%S+%s+%S+%s+(.+)$") or subarg
                db.dangerousCasts[originalArg] = nil
                Print("Removed dangerous cast: |cffffcc00" .. originalArg .. "|r")
            end

        elseif subcmd == "list" then
            local count = 0
            for key, _ in pairs(db.dangerousCasts) do
                if type(key) == "number" then
                    Print("  Spell ID: |cffffcc00" .. key .. "|r")
                else
                    Print("  Spell Name: |cffffcc00" .. key .. "|r")
                end
                count = count + 1
            end
            if count == 0 then
                Print("|cff888888No dangerous casts configured.|r Use /mk dangerous add <spellID or name>")
            else
                Print(count .. " dangerous cast(s) configured.")
            end

        else
            Print("Usage: /mk dangerous <add|remove|list> [spellID or name]")
        end

    else
        Print("|cffff0000Unknown command:|r " .. cmd .. ". Type |cff88ccff/mk help|r for options.")
    end
end

-------------------------------------------------------------------------------
-- Event Frame: all game event handling lives here
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("GROUP_ROSTER_CHANGED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName ~= ADDON_NAME then return end

        -- Initialize SavedVariables
        MissedKickDB = MissedKickDB or {}
        for k, v in pairs(DEFAULTS) do
            if MissedKickDB[k] == nil then
                if type(v) == "table" then
                    MissedKickDB[k] = {}
                else
                    MissedKickDB[k] = v
                end
            end
        end
        db = MissedKickDB

        -- Register addon message prefix
        C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)

        -- Get player info
        myName = UnitName("player")
        MissedKick.myName = myName

        -- Find our interrupt
        FindMyInterrupt()
        RebuildPartyRoster()

        -- Register slash commands
        SLASH_MISSEDKICK1 = "/mk"
        SLASH_MISSEDKICK2 = "/missedkick"
        SlashCmdList["MISSEDKICK"] = HandleSlash

        Print("|cff00ff00Loaded!|r Type |cff88ccff/mk help|r for commands.")
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_ENTERING_WORLD" then
        myName = UnitName("player")
        MissedKick.myName = myName
        FindMyInterrupt()
        RebuildPartyRoster()

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        OnSpellcastSucceeded(...)

    elseif event == "GROUP_ROSTER_CHANGED" then
        RebuildPartyRoster()

    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Re-detect interrupt when player changes spec
        FindMyInterrupt()
        RebuildPartyRoster()
    end
end)
