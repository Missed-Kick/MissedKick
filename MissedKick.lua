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
local ADDON_BUILD = "2026-05-05-sync-channel-fix"

-------------------------------------------------------------------------------
-- Interrupt Spell Table
-- spellID -> { name, cd (base cooldown in seconds) }
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
    [93985]  = { name = "Skull Bash",        cd = 15 },  -- Druid variant
    [80964]  = { name = "Skull Bash",        cd = 15 },  -- Druid variant
    [80965]  = { name = "Skull Bash",        cd = 15 },  -- Druid variant
}

-- Some client builds report spec/form-specific spell IDs for the same interrupt.
-- Track those as the canonical spell so cooldowns/icons stay stable.
local SPELL_ALIASES = {
    [93985] = 106839, -- Skull Bash variants seen in Midnight
    [80964] = 106839,
    [80965] = 106839,
}

local CLASS_INTERRUPTS = {
    DEATHKNIGHT = { 47528 },
    DEMONHUNTER = { 183752 },
    DRUID = { 106839, 93985, 80964, 80965 },
    HUNTER = { 147362 },
    MAGE = { 2139 },
    MONK = { 116705 },
    PALADIN = { 96231 },
    PRIEST = { 15487 },
    ROGUE = { 1766 },
    SHAMAN = { 57994 },
    WARLOCK = { 19647 },
    WARRIOR = { 6552 },
}

-- Build a reverse lookup: spellID set for fast checking
local INTERRUPT_IDS = {}
for id in pairs(INTERRUPT_SPELLS) do
    INTERRUPT_IDS[id] = true
end
for aliasID, canonicalID in pairs(SPELL_ALIASES) do
    if INTERRUPT_SPELLS[canonicalID] then
        INTERRUPT_IDS[aliasID] = true
    end
end

local INTERRUPT_SPELLS_STR = {}
local SPELL_ALIASES_STR = {}
for id, data in pairs(INTERRUPT_SPELLS) do
    INTERRUPT_SPELLS_STR[tostring(id)] = data
end
for aliasID, canonicalID in pairs(SPELL_ALIASES) do
    SPELL_ALIASES_STR[tostring(aliasID)] = canonicalID
    if INTERRUPT_SPELLS[canonicalID] then
        INTERRUPT_SPELLS_STR[tostring(aliasID)] = INTERRUPT_SPELLS[canonicalID]
    end
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
    kickTrackerEnabled = true,
    nearbyCastsEnabled = true,
    onlyDungeons = false,
    frameLocked    = false,
    -- framePos is NOT listed here; nil keys are skipped by pairs() and
    -- we never want to accidentally overwrite a saved position.
}

-------------------------------------------------------------------------------
-- Runtime State
-------------------------------------------------------------------------------
local db                 -- reference to MissedKickDB after ADDON_LOADED
local myName             -- player's name (short, no realm)
local myGUID             -- player's GUID for combat-log fallback detection
local mySpellID          -- the player's known interrupt spellID, or nil
local mySpellCD          -- actual cooldown duration for the player's interrupt
local myKickCdEnd = 0    -- direct self cooldown state for UI reliability
local myKickCdDuration = nil

-- Party cooldown tracking:
-- partyKicks[name] = { spellID, cdEnd, cdDuration, hasAddon, class, isSelf }
--   spellID    = interrupt spell ID (nil if unknown)
--   cdEnd      = GetTime() at which CD expires (0 = ready)
--   cdDuration = last known full cooldown duration in seconds
--   hasAddon   = true if this player has sent us addon messages
--   class      = class token (e.g. "WARRIOR") for coloring
local partyKicks = {}

-- Nearby cast data (rebuilt every scan tick):
-- nearbyCasts[i] = { unit, enemyName, spellName, spellID, targetName, markerIndex, startTime, endTime, duration }
local nearbyCasts = {}
local NAMEPLATE_UNITS = {}
for i = 1, 40 do
    NAMEPLATE_UNITS[i] = "nameplate" .. i
end

-- Rate limiting for addon messages
local lastBroadcast = 0
local BROADCAST_THROTTLE = 0.5  -- seconds between broadcasts
local rosterRebuildScheduled = false
local testCastsUntil = 0
local debugEnabled = false
local lastDebugByKey = {}
local pendingNearbyCastEvents = {}
local PENDING_CAST_TTL = 2

local PARTY_CATEGORY_HOME = LE_PARTY_CATEGORY_HOME
local PARTY_CATEGORY_INSTANCE = LE_PARTY_CATEGORY_INSTANCE
if Enum and Enum.PartyCategory then
    PARTY_CATEGORY_HOME = PARTY_CATEGORY_HOME or Enum.PartyCategory.Home
    PARTY_CATEGORY_INSTANCE = PARTY_CATEGORY_INSTANCE or Enum.PartyCategory.Instance
end

-------------------------------------------------------------------------------
-- Public API (accessed by UI.lua)
-------------------------------------------------------------------------------
MissedKick = {
    BUILD               = ADDON_BUILD,
    INTERRUPT_SPELLS    = INTERRUPT_SPELLS,
    INTERRUPT_IDS       = INTERRUPT_IDS,
    SPELL_ALIASES       = SPELL_ALIASES,
    MARKER_NAMES        = MARKER_NAMES,
    MARKER_ICONS        = MARKER_ICONS,
    MARKER_NAME_FROM_INDEX = MARKER_NAME_FROM_INDEX,
    partyKicks          = partyKicks,
    nearbyCasts         = nearbyCasts,
}

function MissedKick.GetDB()       return db end
function MissedKick.GetMyName()   return myName end
function MissedKick.GetMySpellID() return mySpellID end
function MissedKick.GetMyKickCooldown()
    return myKickCdEnd or 0, myKickCdDuration, mySpellID
end

-------------------------------------------------------------------------------
-- Utility: chat print with addon prefix
-------------------------------------------------------------------------------
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff4444Missed|r|cffffcc00Kick|r: " .. msg)
end
MissedKick.Print = Print

local function DebugPrint(msg)
    if debugEnabled then
        Print("|cff8888ffDEBUG|r " .. msg)
    end
end
MissedKick.DebugPrint = DebugPrint
function MissedKick.IsDebugEnabled() return debugEnabled end

local function DebugPrintThrottled(key, msg, interval)
    if not debugEnabled then return end
    local now = GetTime()
    interval = interval or 1
    if (lastDebugByKey[key] or 0) + interval > now then return end
    lastDebugByKey[key] = now
    DebugPrint(msg)
end

local function ResolveInterruptSpell(spellID, spellName)
    if spellName == "Skull Bash" and (not spellID or not INTERRUPT_IDS[spellID]) then
        spellID = 106839
    end

    if spellID then
        local okDirect, data = pcall(function() return INTERRUPT_SPELLS[spellID] end)
        if okDirect and data then
            return spellID, data
        end

        local okAlias, canonicalID = pcall(function() return SPELL_ALIASES[spellID] end)
        if okAlias and canonicalID and INTERRUPT_SPELLS[canonicalID] then
            return canonicalID, INTERRUPT_SPELLS[canonicalID]
        end

        local okString, spellIDString = pcall(tostring, spellID)
        if okString and spellIDString then
            local canonicalFromString = SPELL_ALIASES_STR[spellIDString]
            if canonicalFromString and INTERRUPT_SPELLS[canonicalFromString] then
                return canonicalFromString, INTERRUPT_SPELLS[canonicalFromString]
            end

            local stringData = INTERRUPT_SPELLS_STR[spellIDString]
            if stringData then
                return tonumber(spellIDString) or spellID, stringData
            end
        end

        if C_Spell and C_Spell.GetBaseSpell then
            local okBase, baseID = pcall(C_Spell.GetBaseSpell, spellID)
            if okBase and baseID then
                local canonicalBase = SPELL_ALIASES[baseID] or baseID
                local baseData = INTERRUPT_SPELLS[canonicalBase]
                if baseData then
                    return canonicalBase, baseData
                end
            end
        end
    end

    if spellName == "Skull Bash" then
        return 106839, INTERRUPT_SPELLS[106839]
    end

    return nil, nil
end

-------------------------------------------------------------------------------
-- Spell Icon Resolution
-- Uses the runtime API first, falls back to a hardcoded default.
-------------------------------------------------------------------------------
local iconCache = {}

local function GetInterruptIcon(spellID)
    if not spellID then return nil end
    spellID = SPELL_ALIASES[spellID] or spellID
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

local function GetSpellNameByID(spellID)
    if not spellID then return nil end
    local data = INTERRUPT_SPELLS[spellID]
    if data and data.name then return data.name end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and info then
            if type(info) == "table" then return info.name end
            return info
        end
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, spellID)
        if ok then return name end
    end
    return nil
end

local cleanNumberSlider = CreateFrame("Slider", nil, UIParent)
cleanNumberSlider:SetMinMaxValues(0, 999999999)
cleanNumberSlider:SetSize(1, 1)
cleanNumberSlider:Hide()

local cleanNumberValue
cleanNumberSlider:SetScript("OnValueChanged", function(_, value)
    cleanNumberValue = value
end)

local function IsCleanNumber(value)
    local okType, valueType = pcall(type, value)
    if not okType or valueType ~= "number" then return false end

    if hasanysecretvalues then
        local okSecret, isSecret = pcall(hasanysecretvalues, value)
        if okSecret and isSecret then return false end
    end

    local okIndex = pcall(function()
        local probe = { [value] = true }
        return probe[value]
    end)
    return okIndex
end

local function CleanNumber(value)
    if value == nil then return nil end

    if IsCleanNumber(value) then return value end

    local okDirect, direct = pcall(tonumber, value)
    if okDirect and direct and IsCleanNumber(direct) then
        return direct
    end

    local okFormat, formatted = pcall(string.format, "%.0f", value)
    if okFormat and formatted then
        local okClean, clean = pcall(tonumber, formatted)
        if okClean and clean and IsCleanNumber(clean) then return clean end
    end

    local okString, stringValue = pcall(tostring, value)
    if okString and stringValue then
        local okClean, clean = pcall(tonumber, stringValue)
        if okClean and clean and IsCleanNumber(clean) then return clean end
    end

    cleanNumberValue = nil
    pcall(cleanNumberSlider.SetValue, cleanNumberSlider, 0)
    cleanNumberValue = nil
    local sliderOk = pcall(cleanNumberSlider.SetValue, cleanNumberSlider, value)
    if sliderOk and cleanNumberValue ~= nil then
        local okClean, clean = pcall(tonumber, cleanNumberValue)
        if okClean and clean and IsCleanNumber(clean) then return clean end
    end

    return nil
end

local function CleanBoolean(value)
    if value == nil then return nil end

    local okType, valueType = pcall(type, value)
    if okType and valueType == "boolean" then
        local okValue, cleanValue = pcall(function()
            if value then return true end
            return false
        end)
        if okValue then return cleanValue end
    end

    return nil
end

-------------------------------------------------------------------------------
-- Find the player's interrupt spell
-- Checks the spellbook for each known interrupt. The first match wins.
-- Safely caches enum values to avoid errors if APIs aren't ready.
-------------------------------------------------------------------------------
local SPELLBANK_PLAYER = nil
local SPELLBANK_PET = nil

local function SafeInitEnums()
    if SPELLBANK_PLAYER ~= nil then return end
    local ok = pcall(function()
        SPELLBANK_PLAYER = Enum.SpellBookSpellBank.Player
        SPELLBANK_PET = Enum.SpellBookSpellBank.Pet
    end)
    if not ok then
        SPELLBANK_PLAYER = 0
        SPELLBANK_PET = 1
    end
end

local function IsInterruptKnown(spellID, checkPet)
    -- Check player spellbook
    if C_SpellBook and C_SpellBook.IsSpellInSpellBook then
        local ok1, result1 = pcall(C_SpellBook.IsSpellInSpellBook, spellID, SPELLBANK_PLAYER)
        if ok1 and result1 then return true end
        if checkPet then
            local ok2, result2 = pcall(C_SpellBook.IsSpellInSpellBook, spellID, SPELLBANK_PET)
            if ok2 and result2 then return true end
        end
    end

    -- Fallback: IsSpellKnown
    if IsSpellKnown then
        local ok3, result3 = pcall(IsSpellKnown, spellID)
        if ok3 and result3 then return true end
    end

    return false
end

local function SetMyInterrupt(spellID)
    local data = INTERRUPT_SPELLS[spellID]
    if not data then return end

    mySpellID = spellID
    -- Try to read the actual cooldown duration from the API
    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
        if ok and info then
            local okD, dur = pcall(function() return info.duration end)
            if okD and dur and dur > 1.5 then
                mySpellCD = dur
            end
        end
    end
    -- Fallback to table value
    if not mySpellCD then
        mySpellCD = data.cd
    end
end

local function FindMyInterrupt()
    mySpellID = nil
    mySpellCD = nil
    SafeInitEnums()

    local _, classToken = UnitClass("player")
    local classInterrupts = classToken and CLASS_INTERRUPTS[classToken]
    if classInterrupts then
        for _, spellID in ipairs(classInterrupts) do
            if IsInterruptKnown(spellID, classToken == "WARLOCK") then
                SetMyInterrupt(spellID)
                return
            end
        end
    end

    -- Last-resort fallback for future classes/specs or API changes.
    for spellID, data in pairs(INTERRUPT_SPELLS) do
        if IsInterruptKnown(spellID, true) then
            SetMyInterrupt(spellID)
            return
        end
    end
end

local function RefreshCooldownFromSpell(spellID, fallbackCd)
    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
        if ok and info then
            local okD, dur = pcall(function() return info.duration end)
            if okD and dur and dur > 1.5 then
                mySpellCD = dur
                return dur
            end
        end
    end

    return fallbackCd
end

-------------------------------------------------------------------------------
-- Party Roster Management
-- Rebuilds the party list, preserving existing cooldown data for members
-- who are still in the group.
-------------------------------------------------------------------------------
local function RebuildPartyRoster()
    if not myName then
        myName = UnitName("player")
        MissedKick.myName = myName
    end
    if not myName then return end

    local keepNames = {}

    -- Always include self
    keepNames[myName] = true
    local _, myClass = UnitClass("player")
    if not partyKicks[myName] then
        partyKicks[myName] = { spellID = mySpellID, cdEnd = 0, cdDuration = mySpellCD, hasAddon = true, class = myClass, isSelf = true }
    else
        partyKicks[myName].spellID = mySpellID
        partyKicks[myName].cdDuration = mySpellCD or partyKicks[myName].cdDuration
        partyKicks[myName].hasAddon = true
        partyKicks[myName].class = myClass
        partyKicks[myName].isSelf = true
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
                local _, classToken = UnitClass(unit)
                if name and name ~= myName then
                    keepNames[name] = true
                    if not partyKicks[name] then
                        partyKicks[name] = { spellID = nil, cdEnd = 0, hasAddon = false, class = classToken, isSelf = false }
                    else
                        partyKicks[name].class = classToken
                        partyKicks[name].isSelf = false
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

    if MissedKick_RefreshUI then MissedKick_RefreshUI() end
end

local function ScheduleRosterRebuild()
    if rosterRebuildScheduled then return end
    rosterRebuildScheduled = true
    RebuildPartyRoster()
    C_Timer.After(0.5, function() pcall(RebuildPartyRoster) end)
    C_Timer.After(1.5, function() pcall(RebuildPartyRoster) end)
    C_Timer.After(3.0, function()
        rosterRebuildScheduled = false
        pcall(RebuildPartyRoster)
    end)
end

-------------------------------------------------------------------------------
-- Addon Message Broadcasting
-- Sends kick data to party members who also have the addon.
--
-- Protocol: "KICK;spellID;cooldownDuration"
-- Channel: PARTY or INSTANCE_CHAT (whichever is appropriate)
-------------------------------------------------------------------------------
local function IsInGroupCategory(category)
    if category ~= nil and IsInGroup then
        local ok, inGroup = pcall(IsInGroup, category)
        if ok then return inGroup end
    end
    return false
end

local function GetAddonMessageChannels()
    local channels = {}
    local inHome = IsInGroupCategory(PARTY_CATEGORY_HOME)
    local inInstance = IsInGroupCategory(PARTY_CATEGORY_INSTANCE)
    local inAnyGroup = false

    if IsInGroup then
        local ok, grouped = pcall(IsInGroup)
        inAnyGroup = ok and grouped or false
    end

    if inInstance then
        channels[#channels + 1] = "INSTANCE_CHAT"
    end

    if inHome then
        channels[#channels + 1] = (IsInRaid and IsInRaid()) and "RAID" or "PARTY"
    end

    if #channels == 0 and inAnyGroup then
        channels[#channels + 1] = (IsInRaid and IsInRaid()) and "RAID" or "PARTY"
    end

    return channels
end

local function BroadcastKick(spellID, cd)
    local now = GetTime()
    if now - lastBroadcast < BROADCAST_THROTTLE then return end
    lastBroadcast = now

    local payload = "KICK;" .. spellID .. ";" .. string.format("%.1f", cd)
    local channels = GetAddonMessageChannels()
    local sent = false

    for _, channel in ipairs(channels) do
        local ok, result = pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX, payload, channel)
        if ok and result ~= false then
            sent = true
        end
        DebugPrint("sent kick channel=" .. tostring(channel) .. " ok=" .. tostring(ok) .. " result=" .. tostring(result))
    end

    if not sent then
        DebugPrint("kick sync not sent; no usable group addon channel")
    end
end

-------------------------------------------------------------------------------
-- Addon Message Receiving
-- Parses incoming MISSEDKICK messages and updates partyKicks.
-------------------------------------------------------------------------------
local function OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= ADDON_PREFIX then return end
    DebugPrint("addon msg channel=" .. tostring(channel) .. " sender=" .. tostring(sender) .. " msg=" .. tostring(message))

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
                entry.cdDuration = cd
                entry.hasAddon = true
            else
                -- Player not in our roster yet (race condition with GROUP_ROSTER_CHANGED)
                partyKicks[shortName] = {
                    spellID  = spellID,
                    cdEnd    = GetTime() + cd,
                    cdDuration = cd,
                    hasAddon = true,
                }
            end
            DebugPrint("received party kick sender=" .. tostring(shortName) .. " spellID=" .. tostring(spellID) .. " cd=" .. tostring(cd))
            if MissedKick_RefreshUI then MissedKick_RefreshUI() end
        end
    end
end

local function SimulatePartyKick()
    local senderName
    local spellID = 6552
    local cd = 15

    for name, kick in pairs(partyKicks) do
        if name ~= myName and not kick.isSelf then
            senderName = name
            if kick.spellID and INTERRUPT_SPELLS[kick.spellID] then
                spellID = kick.spellID
                cd = INTERRUPT_SPELLS[kick.spellID].cd
            end
            break
        end
    end

    if not senderName then
        senderName = "PartyTester"
        partyKicks[senderName] = {
            spellID = spellID,
            cdEnd = 0,
            cdDuration = cd,
            hasAddon = false,
            class = "WARRIOR",
            isSelf = false,
        }
    end

    OnAddonMessage(ADDON_PREFIX, "KICK;" .. spellID .. ";" .. string.format("%.1f", cd), "PARTY", senderName)
    Print("Simulated addon kick from |cffffcc00" .. senderName .. "|r.")
end

-------------------------------------------------------------------------------
-- Interrupt Detection
-------------------------------------------------------------------------------
local function TrackKickUsed(spellID, spellName, source)
    local rawSpellID = spellID
    local data
    spellID, data = ResolveInterruptSpell(spellID, spellName)
    if debugEnabled then
        DebugPrint((source or "kick") .. " spellID=" .. tostring(rawSpellID) .. " resolved=" .. tostring(spellID) .. " name=" .. tostring(spellName) .. " tracked=" .. tostring(data and true or false))
    end
    if not spellID or not data then return end
    local cd = data.cd or 15
    local cdEnd = GetTime() + cd
    mySpellID = spellID
    mySpellCD = cd
    myKickCdEnd = cdEnd
    myKickCdDuration = cd
    DebugPrint("cooldown state primed cd=" .. tostring(cd) .. " remaining=" .. string.format("%.1f", cdEnd - GetTime()))

    if mySpellID ~= spellID then
        SetMyInterrupt(spellID)
    end
    if not myName then
        myName = UnitName("player")
        MissedKick.myName = myName
    end

    -- Refresh cooldown from the API (talent/haste adjusted)
    local actualCd = RefreshCooldownFromSpell(spellID, cd)
    if actualCd and actualCd > 0 then
        cd = actualCd
        cdEnd = GetTime() + cd
        myKickCdEnd = cdEnd
        myKickCdDuration = cd
    end

    -- Update own state
    local entry = myName and partyKicks[myName] or nil
    if not entry and myName then
        local _, myClass = UnitClass("player")
        partyKicks[myName] = { spellID = spellID, cdEnd = 0, cdDuration = cd, hasAddon = true, class = myClass, isSelf = true }
        entry = partyKicks[myName]
    end
    local updated = 0
    for name, kick in pairs(partyKicks) do
        if kick.isSelf or name == myName then
            kick.spellID = spellID
            kick.cdEnd = cdEnd
            kick.cdDuration = cd
            kick.hasAddon = true
            kick.isSelf = true
            updated = updated + 1
        end
    end

    -- Broadcast to party
    BroadcastKick(spellID, cd)
    DebugPrint("cooldown set cd=" .. tostring(cd) .. " remaining=" .. string.format("%.1f", cdEnd - GetTime()) .. " selfRows=" .. tostring(updated))
    if MissedKick_RefreshUI then MissedKick_RefreshUI() end
    C_Timer.After(0.05, function() if MissedKick_RefreshUI then MissedKick_RefreshUI() end end)
end

local function OnSpellcastSucceeded(unit, castGUID, spellID)
    if unit ~= "player" and unit ~= "pet" then return end
    local _, data = ResolveInterruptSpell(spellID)
    local spellName = data and data.name or nil
    TrackKickUsed(spellID, spellName, "UNIT_SPELLCAST_SUCCEEDED")
end

-------------------------------------------------------------------------------
-- Nearby Cast Tracking
-- Mirrors TargetedSpells' reliable pattern: react to nameplate spellcast events,
-- wait briefly, then read live cast data from the nameplate unit.
-------------------------------------------------------------------------------
local function ClearNearbyCast(unit)
    local removed = false
    for i = #nearbyCasts, 1, -1 do
        if nearbyCasts[i].unit == unit then
            table.remove(nearbyCasts, i)
            removed = true
        end
    end
    if removed and MissedKick_RefreshCasts then MissedKick_RefreshCasts() end
end

local function IsNameplateUnit(unit)
    return type(unit) == "string" and unit:match("^nameplate%d+$") ~= nil
end

local function UnitIsRelevantCaster(unit)
    if not unit or not UnitExists(unit) then return false, "missing" end
    if not IsNameplateUnit(unit) then return false, "not-nameplate" end
    if unit == "player" or unit == "pet" then return false end
    if unit:match("^party%d+") or unit:match("^raid%d+") then return false end

    local okFriend, isFriendly = pcall(function()
        if UnitIsFriend(unit, "player") then return true end
        return false
    end)
    if okFriend and isFriendly then return false, "friendly" end

    local okAttack, canAttack = pcall(function()
        if UnitCanAttack("player", unit) then return true end
        return false
    end)
    if okAttack and canAttack then return true end

    -- Nameplate spellcast events can arrive before attackability data settles.
    return true
end

local function NormalizeSpellID(spellID)
    local cleanSpellID = CleanNumber(spellID)
    if cleanSpellID then
        return math.floor(cleanSpellID + 0.5)
    end

    if spellID and C_Spell and C_Spell.GetBaseSpell then
        local okBase, baseSpellID = pcall(C_Spell.GetBaseSpell, spellID)
        cleanSpellID = okBase and CleanNumber(baseSpellID)
        if cleanSpellID then
            return math.floor(cleanSpellID + 0.5)
        end
    end

    if spellID and C_Spell and C_Spell.GetSpellInfo then
        local okInfo, info = pcall(C_Spell.GetSpellInfo, spellID)
        if okInfo and info then
            if type(info) == "table" then
                cleanSpellID = CleanNumber(info.spellID or info.spellId or info.id)
            else
                cleanSpellID = CleanNumber(info)
            end
            if cleanSpellID then
                return math.floor(cleanSpellID + 0.5)
            end
        end
    end

    return nil
end

local function SafeText(value)
    if value == nil then return nil end

    local okFormat, clean = pcall(string.format, "%s", value)
    if okFormat and clean then
        local okType, cleanType = pcall(type, clean)
        if okType and cleanType == "string" then
            local okKey = pcall(rawset, {}, clean, true)
            if okKey then return clean end
        end
    end

    local okType, valueType = pcall(type, value)
    if okType and valueType == "string" then
        local okKey = pcall(rawset, {}, value, true)
        if okKey then return value end
    end

    return nil
end

local function IsPresentValue(value)
    if value then return true end
    return false
end

local function FirstPresentValue(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if IsPresentValue(value) then return value end
    end
    return nil
end

local spellNameCache = {}

local function GetRawPublicSpellName(spellID)
    if not IsPresentValue(spellID) then return nil end

    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok then return name end
    end

    local cleanSpellID = NormalizeSpellID(spellID)
    if cleanSpellID then
        return GetSpellNameByID(cleanSpellID)
    end

    return nil
end

local function GetRawPublicSpellTexture(spellID)
    if not IsPresentValue(spellID) or not (C_Spell and C_Spell.GetSpellTexture) then return nil end

    local ok, texture = pcall(C_Spell.GetSpellTexture, spellID)
    if ok then return texture end
    return nil
end

local function GetPublicSpellName(spellID)
    if not IsPresentValue(spellID) then return nil end

    local rawName = SafeText(GetRawPublicSpellName(spellID))
    if rawName then
        local cleanRawID = NormalizeSpellID(spellID)
        if cleanRawID then spellNameCache[cleanRawID] = rawName end
        return rawName
    end

    local cleanSpellID = NormalizeSpellID(spellID)
    if not cleanSpellID then return nil end
    if spellNameCache[cleanSpellID] then return spellNameCache[cleanSpellID] end

    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, cleanSpellID)
        name = SafeText(ok and name)
        if name then
            spellNameCache[cleanSpellID] = name
            return name
        end
    end

    local name = SafeText(GetSpellNameByID(cleanSpellID))
    if name then spellNameCache[cleanSpellID] = name end
    return name
end

local function GetNameplateVisualName(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end

    local okPlate, namePlate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if not okPlate or not namePlate then return nil end

    local okName, foundName = pcall(function()
        local frames = {
            namePlate.UnitFrame,
            namePlate.unitFrame,
            namePlate,
        }

        for _, frame in ipairs(frames) do
            if frame then
                local fields = {
                    frame.name,
                    frame.Name,
                    frame.NameText,
                    frame.nameText,
                    frame.healthBar and frame.healthBar.name,
                    frame.HealthBarsContainer and frame.HealthBarsContainer.name,
                }

                for _, textRegion in ipairs(fields) do
                    if textRegion and textRegion.GetText then
                        local okText, text = pcall(textRegion.GetText, textRegion)
                        text = SafeText(okText and text)
                        if text then return text end
                    end
                end
            end
        end

        return nil
    end)

    if okName then
        return foundName
    end

    return nil
end

local function GetTooltipUnitName(unit)
    if not (C_TooltipInfo and C_TooltipInfo.GetUnit) then return nil end

    local okTooltip, tooltipData = pcall(C_TooltipInfo.GetUnit, unit)
    if not okTooltip or not tooltipData or not tooltipData.lines then return nil end

    local okName, name = pcall(function()
        local firstLine = tooltipData.lines[1]
        if firstLine and firstLine.leftText then
            return SafeText(firstLine.leftText)
        end
        return nil
    end)

    if okName then return name end
    return nil
end

local function GetRawTooltipUnitName(unit)
    if not (C_TooltipInfo and C_TooltipInfo.GetUnit) then return nil end

    local okTooltip, tooltipData = pcall(C_TooltipInfo.GetUnit, unit)
    if not okTooltip or not tooltipData or not tooltipData.lines then return nil end

    local okName, name = pcall(function()
        local firstLine = tooltipData.lines[1]
        return firstLine and firstLine.leftText or nil
    end)

    if okName then return name end
    return nil
end

local function GetRawUnitName(unit)
    local tooltipName = GetRawTooltipUnitName(unit)
    if tooltipName then return tooltipName end

    local ok, name = pcall(UnitName, unit)
    if ok and name then return name end
    return nil
end

local function GetUnitNameSafe(unit, fallback)
    local tooltipName = GetTooltipUnitName(unit)
    if tooltipName then return tooltipName end

    local visualName = GetNameplateVisualName(unit)
    if visualName then return visualName end

    if UnitFullName then
        local okFull, name, realm = pcall(UnitFullName, unit)
        name = SafeText(okFull and name)
        realm = SafeText(okFull and realm)
        if name then
            if realm and realm ~= "" then return name .. "-" .. realm end
            return name
        end
    end

    local ok, name = pcall(UnitName, unit)
    name = SafeText(ok and name)
    if name then return name end

    return SafeText(fallback) or "Unknown Enemy"
end

local function GetCastTargetName(unit)
    if UnitSpellTargetName then
        local ok, targetName = pcall(UnitSpellTargetName, unit)
        targetName = SafeText(ok and targetName)
        if targetName then return targetName end
    end

    local ok, targetName = pcall(UnitName, unit .. "target")
    return SafeText(ok and targetName)
end

local function IsPlaceholderEnemyName(name, unit)
    return not name or name == "" or name == unit or name == "Unknown" or name == "Unknown Enemy"
end

local function IsPlaceholderSpellName(name)
    return not name or name == "" or name == "Unknown Spell" or name == "Spell unknown"
end

local function PreserveCastMetadata(entry, existing)
    if not (entry and existing) then return end

    if IsPlaceholderEnemyName(entry.enemyName, entry.unit) and not IsPlaceholderEnemyName(existing.enemyName, entry.unit) then
        entry.enemyName = existing.enemyName
    end

    if IsPlaceholderSpellName(entry.spellName) and not IsPlaceholderSpellName(existing.spellName) then
        entry.spellName = existing.spellName
    end

    if not entry.cleanSpellID and existing.cleanSpellID then
        entry.cleanSpellID = existing.cleanSpellID
        entry.spellID = existing.spellID or existing.cleanSpellID
    end

    if not entry.eventSpellID and existing.eventSpellID then
        entry.eventSpellID = existing.eventSpellID
    end

    if not entry.rawEventSpellID and existing.rawEventSpellID then
        entry.rawEventSpellID = existing.rawEventSpellID
    end

    if not entry.rawUnitSpellID and existing.rawUnitSpellID then
        entry.rawUnitSpellID = existing.rawUnitSpellID
    end

    if not entry.targetName and existing.targetName then
        entry.targetName = existing.targetName
    end

    if not entry.enemyNameRaw and existing.enemyNameRaw then
        entry.enemyNameRaw = existing.enemyNameRaw
    end

    entry.spellNameRaw = FirstPresentValue(entry.spellNameRaw, existing.spellNameRaw)
    entry.rawSpellName = FirstPresentValue(entry.rawSpellName, existing.rawSpellName)
    entry.rawSpellTexture = FirstPresentValue(entry.rawSpellTexture, existing.rawSpellTexture)

    if not entry.cleanSpellTexture and existing.cleanSpellTexture then
        entry.cleanSpellTexture = existing.cleanSpellTexture
    end
end

local function GetRaidMarkerSafe(unit)
    local ok, marker = pcall(GetRaidTargetIndex, unit)
    if ok then
        return CleanNumber(marker)
    end
    return nil
end

local function GetRaidMarkerRaw(unit)
    local ok, marker = pcall(GetRaidTargetIndex, unit)
    if ok then return marker end
    return nil
end

local function MarkerPresenceChanged(oldMarker, newMarker)
    local okOldNil, oldNil = pcall(function() return oldMarker == nil end)
    local okNewNil, newNil = pcall(function() return newMarker == nil end)
    if okOldNil and okNewNil then
        local okChanged, changed = pcall(function()
            if oldNil ~= newNil then return true end
            return false
        end)
        return okChanged and changed or false
    end
    return false
end

local function RefreshNearbyCastMarkers()
    local changed = false

    for _, cast in ipairs(nearbyCasts) do
        if cast.unit and UnitExists(cast.unit) then
            local markerRaw = GetRaidMarkerRaw(cast.unit)
            local markerIndex = GetRaidMarkerSafe(cast.unit)
            local rawPresenceChanged = MarkerPresenceChanged(cast.markerIndexRaw, markerRaw)
            if cast.markerIndex ~= markerIndex or rawPresenceChanged then
                cast.markerIndexRaw = markerRaw
                cast.markerIndex = markerIndex
                changed = true
            else
                cast.markerIndexRaw = markerRaw
            end
        end
    end

    if changed and MissedKick_RefreshCasts then
        MissedKick_RefreshCasts()
    end
end

function MissedKick.GetRaidMarkerForUnit(unit)
    local raw = GetRaidMarkerRaw(unit)
    local clean = GetRaidMarkerSafe(unit)
    return raw, clean
end

local function GetDurationObject(unit, isChannel)
    local ok, duration = pcall(function()
        if isChannel and UnitChannelDuration then
            return UnitChannelDuration(unit)
        end
        if UnitCastingDuration then
            return UnitCastingDuration(unit)
        end
        return nil
    end)

    if ok and duration then return duration end
    return nil
end

local function StorePendingNearbyCastEvent(unit, spellID, castID, isChannel)
    if not unit then return end

    pendingNearbyCastEvents[unit] = {
        spellID = spellID,
        castID = castID,
        isChannel = isChannel and true or false,
        startTime = GetTime(),
    }
end

local function GetPendingNearbyCastEvent(unit)
    local pending = unit and pendingNearbyCastEvents[unit]
    if not pending then return nil end

    if (GetTime() - (pending.startTime or 0)) > PENDING_CAST_TTL then
        pendingNearbyCastEvents[unit] = nil
        return nil
    end

    return pending
end

local function UpsertFallbackCast(unit, eventSpellID, reason)
    if not unit or not eventSpellID then return false end
    if not IsNameplateUnit(unit) then return false end

    local now = GetTime()
    local cleanSpellID = NormalizeSpellID(eventSpellID)
    local rawSpellName = GetRawPublicSpellName(eventSpellID)
    local rawSpellTexture = GetRawPublicSpellTexture(eventSpellID)
    local cleanSpellTexture = CleanNumber(rawSpellTexture)
    local spellName = GetPublicSpellName(eventSpellID) or ("Spell " .. tostring(cleanSpellID or "unknown"))
    local entry = {
        unit        = unit,
        enemyName   = GetUnitNameSafe(unit),
        enemyNameRaw = GetRawUnitName(unit),
        spellName   = spellName,
        spellNameRaw = rawSpellName,
        rawSpellName = rawSpellName,
        rawSpellTexture = rawSpellTexture,
        cleanSpellTexture = cleanSpellTexture,
        spellID     = cleanSpellID,
        cleanSpellID = cleanSpellID,
        eventSpellID = cleanSpellID,
        rawEventSpellID = eventSpellID,
        targetName  = nil,
        markerIndexRaw = GetRaidMarkerRaw(unit),
        markerIndex = GetRaidMarkerSafe(unit),
        startTime   = now,
        endTime     = now + 4,
        duration    = 4,
        fallback    = true,
    }
    for i, existing in ipairs(nearbyCasts) do
        if existing.unit == unit then
            PreserveCastMetadata(entry, existing)

            if existing.durationObject
                and not existing.fallback
                and cleanSpellID
                and existing.cleanSpellID == cleanSpellID then
                existing.enemyName = entry.enemyName
                existing.spellName = entry.spellName
                existing.spellID = entry.spellID
                existing.cleanSpellID = cleanSpellID
                existing.markerIndexRaw = entry.markerIndexRaw
                existing.markerIndex = entry.markerIndex
                DebugPrintThrottled("cast-fallback-" .. tostring(unit), "cast fallback metadata kept unit=" .. tostring(unit) .. " spell=" .. tostring(existing.spellName) .. " reason=" .. tostring(reason), 1.5)
                if MissedKick_RefreshCasts then MissedKick_RefreshCasts() end
                return true
            end

            if existing.fallback and (existing.endTime or 0) > now and existing.cleanSpellID == cleanSpellID then
                existing.enemyName = entry.enemyName
                existing.spellName = entry.spellName
                existing.spellID = entry.spellID
                existing.cleanSpellID = cleanSpellID
                existing.markerIndexRaw = entry.markerIndexRaw
                existing.markerIndex = entry.markerIndex
                DebugPrintThrottled("cast-fallback-" .. tostring(unit), "cast fallback kept unit=" .. tostring(unit) .. " spell=" .. tostring(spellName) .. " reason=" .. tostring(reason), 1.5)
                if MissedKick_RefreshCasts then MissedKick_RefreshCasts() end
                return true
            end
            nearbyCasts[i] = entry
            DebugPrintThrottled("cast-fallback-" .. tostring(unit), "cast fallback updated unit=" .. tostring(unit) .. " spell=" .. tostring(spellName) .. " reason=" .. tostring(reason), 1.5)
            if MissedKick_RefreshCasts then MissedKick_RefreshCasts() end
            return true
        end
    end

    nearbyCasts[#nearbyCasts + 1] = entry
    DebugPrintThrottled("cast-fallback-" .. tostring(unit), "cast fallback added unit=" .. tostring(unit) .. " spell=" .. tostring(spellName) .. " reason=" .. tostring(reason), 1.5)
    if MissedKick_RefreshCasts then MissedKick_RefreshCasts() end
    return true
end

local function UpsertNearbyCast(unit, eventSpellID)
    local relevant, reason = UnitIsRelevantCaster(unit)
    if not relevant then
        if UpsertFallbackCast(unit, eventSpellID, reason) then return end
        if unit and UnitExists(unit) then
            DebugPrint("cast ignored unit=" .. tostring(unit) .. " reason=" .. tostring(reason))
        end
        ClearNearbyCast(unit)
        return
    end

    local pending = GetPendingNearbyCastEvent(unit)
    local effectiveEventSpellID = eventSpellID or (pending and pending.spellID)

    local castName, castSpellID, castID, castNotInterruptible, castTexture
    local channelName, channelSpellID, channelCastID, channelNotInterruptible, channelTexture
    local isCasting = false
    local isChanneling = false

    local ok1, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10 = pcall(UnitCastingInfo, unit)
    if ok1 and c1 then
        castName = c1
        castTexture = c3
        castNotInterruptible = c8
        castSpellID = c9
        castID = c10
        isCasting = true
    end

    if not isCasting then
        local ok2, ch1, ch2, ch3, ch4, ch5, ch6, ch7, ch8, ch9, ch10, ch11 = pcall(UnitChannelInfo, unit)
        if ok2 and ch1 then
            channelName = ch1
            channelTexture = ch3
            channelNotInterruptible = ch7
            channelSpellID = ch8
            channelCastID = ch11
            isChanneling = true
        end
    end

    if not (isCasting or isChanneling) then
        if effectiveEventSpellID then
            UpsertFallbackCast(unit, effectiveEventSpellID, "event-only")
            return
        end
        ClearNearbyCast(unit)
        return
    end

    local durationObject = GetDurationObject(unit, isChanneling)
    if not durationObject then
        if effectiveEventSpellID then
            UpsertFallbackCast(unit, effectiveEventSpellID, "no-duration")
        end
        return
    end

    local spellName = isCasting and castName or channelName
    local unitSpellID = isCasting and castSpellID or channelSpellID
    local eventCleanSpellID = NormalizeSpellID(effectiveEventSpellID)
    local cleanSpellID = eventCleanSpellID or NormalizeSpellID(unitSpellID)
    if not cleanSpellID then
        for _, existing in ipairs(nearbyCasts) do
            if existing.unit == unit and existing.cleanSpellID then
                cleanSpellID = existing.cleanSpellID
                break
            end
        end
    end
    local rawSpellName = FirstPresentValue(
        spellName,
        GetRawPublicSpellName(effectiveEventSpellID),
        GetRawPublicSpellName(unitSpellID),
        GetRawPublicSpellName(eventCleanSpellID)
    )
    local rawSpellTexture = FirstPresentValue(
        isCasting and castTexture or channelTexture,
        GetRawPublicSpellTexture(effectiveEventSpellID),
        GetRawPublicSpellTexture(unitSpellID),
        GetRawPublicSpellTexture(eventCleanSpellID)
    )
    local cleanSpellTexture = CleanNumber(rawSpellTexture)
    spellName = SafeText(spellName) or GetPublicSpellName(effectiveEventSpellID) or GetPublicSpellName(eventCleanSpellID) or GetPublicSpellName(unitSpellID) or GetPublicSpellName(cleanSpellID) or "Unknown Spell"
    local notInterruptibleRaw
    if isCasting then
        notInterruptibleRaw = castNotInterruptible
    else
        notInterruptibleRaw = channelNotInterruptible
    end
    local notInterruptible = CleanBoolean(notInterruptibleRaw)
    local entryCastID = (isCasting and castID or channelCastID) or (pending and pending.castID)
    local entryStartTime = (pending and pending.startTime) or GetTime()

    local entry = {
        unit        = unit,
        enemyName   = GetUnitNameSafe(unit),
        enemyNameRaw = GetRawUnitName(unit),
        spellName   = spellName,
        spellNameRaw = rawSpellName,
        rawSpellName = rawSpellName,
        rawSpellTexture = rawSpellTexture,
        cleanSpellTexture = cleanSpellTexture,
        spellID     = cleanSpellID,
        cleanSpellID = cleanSpellID,
        eventSpellID = eventCleanSpellID,
        rawEventSpellID = effectiveEventSpellID,
        rawUnitSpellID = unitSpellID,
        targetName  = GetCastTargetName(unit),
        markerIndexRaw = GetRaidMarkerRaw(unit),
        markerIndex = GetRaidMarkerSafe(unit),
        startTime   = entryStartTime,
        durationObject = durationObject,
        isChannel   = isChanneling,
        castID      = entryCastID,
        notInterruptible = notInterruptible,
    }
    for i, existing in ipairs(nearbyCasts) do
        if existing.unit == unit then
            PreserveCastMetadata(entry, existing)

            if existing.durationObject
                and not existing.fallback
                and ((existing.cleanSpellID and entry.cleanSpellID and existing.cleanSpellID == entry.cleanSpellID)
                    or (existing.spellName and entry.spellName and existing.spellName == entry.spellName)) then
                entry.durationObject = existing.durationObject
                entry.startTime = existing.startTime
                entry.castID = existing.castID
            end
            nearbyCasts[i] = entry
            DebugPrintThrottled("cast-live-" .. tostring(unit), "cast live unit=" .. tostring(unit)
                .. " spell=" .. tostring(entry.spellName)
                .. " cleanID=" .. tostring(entry.cleanSpellID)
                .. " texture=" .. tostring(entry.cleanSpellTexture), 1.5)
            if MissedKick_RefreshCasts then MissedKick_RefreshCasts() end
            return
        end
    end

    nearbyCasts[#nearbyCasts + 1] = entry
    DebugPrintThrottled("cast-live-" .. tostring(unit), "cast live unit=" .. tostring(unit)
        .. " spell=" .. tostring(entry.spellName)
        .. " cleanID=" .. tostring(entry.cleanSpellID)
        .. " texture=" .. tostring(entry.cleanSpellTexture), 1.5)
    if MissedKick_RefreshCasts then MissedKick_RefreshCasts() end
end

local function SafeUpsertNearbyCast(unit, spellID)
    local ok, err = pcall(UpsertNearbyCast, unit, spellID)
    if not ok then
        DebugPrint("cast upsert error unit=" .. tostring(unit) .. " spellID=" .. tostring(spellID) .. " err=" .. tostring(err))
        pcall(UpsertFallbackCast, unit, spellID, "error")
    end
end

local function IsDungeonInstanceActive()
    if IsInInstance then
        local ok, inInstance, instanceType = pcall(IsInInstance)
        return ok and inInstance and instanceType == "party" or false
    end
    return false
end

local function ShouldScanNearbyCasts()
    local activeDB = db or MissedKickDB
    if activeDB and activeDB.nearbyCastsEnabled == false then return false end
    if activeDB and activeDB.onlyDungeons == true and not IsDungeonInstanceActive() then return false end
    return true
end

local function ScheduleNearbyCastUpdate(unit, spellID, castID, isChannel, fromSpellcastEvent)
    if not ShouldScanNearbyCasts() then return end
    if not unit then return end
    if fromSpellcastEvent then
        StorePendingNearbyCastEvent(unit, spellID, castID, isChannel)
    end
    DebugPrintThrottled("cast-event-" .. tostring(unit), "cast event unit=" .. tostring(unit) .. " spellID=" .. tostring(spellID), 1.5)
    if spellID then
        pcall(UpsertFallbackCast, unit, spellID, "event")
    else
        SafeUpsertNearbyCast(unit, spellID)
    end
    C_Timer.After(0.20, function() SafeUpsertNearbyCast(unit, spellID) end)
end

local function HasTrackedNearbyCast(unit)
    for _, cast in ipairs(nearbyCasts) do
        if cast.unit == unit then return true end
    end
    return false
end

local function UnitHasLiveCast(unit)
    if not unit or not UnitExists(unit) then return false end

    local hasCast = false
    pcall(function()
        if UnitCastingInfo(unit) then
            hasCast = true
        end
    end)
    if hasCast then return true end

    pcall(function()
        if UnitChannelInfo(unit) then
            hasCast = true
        end
    end)
    return hasCast
end

local function ScanNearbyCasts()
    if testCastsUntil > GetTime() then return end
    if not ShouldScanNearbyCasts() then return end

    local now = GetTime()
    local markerChanged = false
    for _, unit in ipairs(NAMEPLATE_UNITS) do
        if UnitHasLiveCast(unit) and not HasTrackedNearbyCast(unit) then
            SafeUpsertNearbyCast(unit)
        end
    end

    for i = #nearbyCasts, 1, -1 do
        if nearbyCasts[i].fallback and (nearbyCasts[i].endTime or 0) <= now then
            table.remove(nearbyCasts, i)
            markerChanged = true
        elseif nearbyCasts[i].unit and UnitExists(nearbyCasts[i].unit) then
            if not nearbyCasts[i].fallback and not UnitHasLiveCast(nearbyCasts[i].unit) then
                table.remove(nearbyCasts, i)
                markerChanged = true
            else
                local markerRaw = GetRaidMarkerRaw(nearbyCasts[i].unit)
                local markerIndex = GetRaidMarkerSafe(nearbyCasts[i].unit)
                local targetName = GetCastTargetName(nearbyCasts[i].unit)
                local rawPresenceChanged = MarkerPresenceChanged(nearbyCasts[i].markerIndexRaw, markerRaw)
                if nearbyCasts[i].markerIndex ~= markerIndex or rawPresenceChanged then
                    nearbyCasts[i].markerIndexRaw = markerRaw
                    nearbyCasts[i].markerIndex = markerIndex
                    markerChanged = true
                else
                    nearbyCasts[i].markerIndexRaw = markerRaw
                end
                if nearbyCasts[i].targetName ~= targetName then
                    nearbyCasts[i].targetName = targetName
                    markerChanged = true
                end
            end
        elseif not nearbyCasts[i].fallback then
            table.remove(nearbyCasts, i)
            markerChanged = true
        end
    end

    if markerChanged and MissedKick_RefreshCasts then
        MissedKick_RefreshCasts()
    end
end
MissedKick.ScanNearbyCasts = ScanNearbyCasts

-------------------------------------------------------------------------------
-- Test Mode: populate fake data for UI testing
-------------------------------------------------------------------------------
local function PopulateTestData()
    if myName then
        local _, myClass = UnitClass("player")
        partyKicks[myName] = {
            spellID  = mySpellID or 1766,
            cdEnd    = GetTime() + 8,
            cdDuration = 15,
            hasAddon = true,
            class    = myClass or "ROGUE",
            isSelf   = true,
        }
    end

    local fakeMembers = {
        { name = "Stabsworth",  spellID = 1766,   cd = 12, class = "ROGUE"        },
        { name = "Smashface",   spellID = 6552,   cd = 0,  class = "WARRIOR"      },
        { name = "Frostweaver", spellID = 2139,   cd = 20, class = "MAGE"         },
        { name = "Stormcaller", spellID = 57994,  cd = 5,  class = "SHAMAN"       },
        { name = "Shadowbane",  spellID = nil,     cd = 0,  class = "DEMONHUNTER"  },
    }
    for _, m in ipairs(fakeMembers) do
        partyKicks[m.name] = {
            spellID  = m.spellID,
            cdEnd    = m.cd > 0 and (GetTime() + m.cd) or 0,
            cdDuration = m.spellID and (INTERRUPT_SPELLS[m.spellID] and INTERRUPT_SPELLS[m.spellID].cd or m.cd) or nil,
            hasAddon = m.spellID ~= nil,
            class    = m.class,
            isSelf   = false,
        }
    end

    for i = #nearbyCasts, 1, -1 do nearbyCasts[i] = nil end
    nearbyCasts[1] = {
        unit = "nameplate1", enemyName = "Vile Caster",
        spellName = "Repel", spellID = 1255377, cleanSpellID = 1255377,
        targetName = "Smashface", markerIndex = 8,
        startTime = GetTime(), endTime = GetTime() + 5, duration = 5,
    }
    nearbyCasts[2] = {
        unit = "nameplate2", enemyName = "Fel Channeler",
        spellName = "Drain Life", spellID = 234153,
        targetName = nil, markerIndex = 2,
        startTime = GetTime(), endTime = GetTime() + 8, duration = 8,
    }
    nearbyCasts[3] = {
        unit = "nameplate3", enemyName = "Dark Ritualist",
        spellName = "Fear", spellID = 5782,
        targetName = myName, markerIndex = nil,
        startTime = GetTime(), endTime = GetTime() + 3, duration = 3,
    }
    testCastsUntil = GetTime() + 30

    Print("|cff00ff00Test data populated.|r Nearby cast test rows will stay visible for 30 seconds. Use |cff88ccff/mk reset|r to clear.")
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
    testCastsUntil = 0
    -- Re-add self
    myKickCdEnd = 0
    myKickCdDuration = nil
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

    if cmd == "help" then
        Print("|cffffffccCommands:|r")
        Print("  /mk help - Show this command list")
        Print("  /mk menu - Open settings menu")
        Print("  /mk center - Move tracker to screen center")
        Print("  /mk test - Populate test data")
        Print("  /mk reset - Clear all cooldowns")
        Print("  /mk debug - Toggle debug logging")
        Print("  /mk fakeparty - Simulate a party member kick")
        Print("  /mk version - Show loaded build")

    elseif cmd == "menu" then
        if MissedKick_ToggleSettings then MissedKick_ToggleSettings() end

    elseif cmd == "center" then
        if MissedKick_CenterFrame then MissedKick_CenterFrame() end

    elseif cmd == "test" then
        PopulateTestData()
        if MissedKick_ShowFrame then MissedKick_ShowFrame() end

    elseif cmd == "reset" then
        ResetData()

    elseif cmd == "debug" then
        debugEnabled = not debugEnabled
        Print("Debug logging " .. (debugEnabled and "|cff00ff00enabled|r." or "|cffff8800disabled|r."))

    elseif cmd == "version" then
        Print("Build |cffffcc00" .. ADDON_BUILD .. "|r")

    elseif cmd == "fakeparty" then
        SimulatePartyKick()

    else
        Print("|cffff0000Unknown command.|r Type |cff88ccff/mk help|r for options.")
    end
end

-------------------------------------------------------------------------------
-- Register slash commands at FILE LOAD time so they always work even if
-- ADDON_LOADED encounters an error.
-------------------------------------------------------------------------------
SLASH_MISSEDKICK1 = "/mk"
SLASH_MISSEDKICK2 = "/missedkick"
SlashCmdList["MISSEDKICK"] = HandleSlash

-------------------------------------------------------------------------------
-- Event Frame: all game event handling lives here
-------------------------------------------------------------------------------
local ownCastFrame = CreateFrame("Frame")
ownCastFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
ownCastFrame:SetScript("OnEvent", function(_, _, unit, castGUID, spellID)
    OnSpellcastSucceeded(unit, castGUID, spellID)
end)

local eventFrame = CreateFrame("Frame")
local castScanTimer = 0

local function RegisterNameplateUnitEvent(frame, eventName)
    if unpack then
        frame:RegisterUnitEvent(eventName, unpack(NAMEPLATE_UNITS))
    else
        frame:RegisterUnitEvent(eventName, table.unpack(NAMEPLATE_UNITS))
    end
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
RegisterNameplateUnitEvent(eventFrame, "UNIT_TARGET")
RegisterNameplateUnitEvent(eventFrame, "UNIT_SPELLCAST_START")
RegisterNameplateUnitEvent(eventFrame, "UNIT_SPELLCAST_CHANNEL_START")
RegisterNameplateUnitEvent(eventFrame, "UNIT_SPELLCAST_EMPOWER_START")
RegisterNameplateUnitEvent(eventFrame, "UNIT_SPELLCAST_INTERRUPTIBLE")
RegisterNameplateUnitEvent(eventFrame, "UNIT_SPELLCAST_NOT_INTERRUPTIBLE")
RegisterNameplateUnitEvent(eventFrame, "UNIT_SPELLCAST_STOP")
RegisterNameplateUnitEvent(eventFrame, "UNIT_SPELLCAST_CHANNEL_STOP")
RegisterNameplateUnitEvent(eventFrame, "UNIT_SPELLCAST_EMPOWER_STOP")
RegisterNameplateUnitEvent(eventFrame, "UNIT_SPELLCAST_INTERRUPTED")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
eventFrame:RegisterEvent("RAID_TARGET_UPDATE")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if testCastsUntil > GetTime() then return end
    if not ShouldScanNearbyCasts() then
        castScanTimer = 0
        return
    end
    castScanTimer = castScanTimer + elapsed
    if castScanTimer >= 0.2 then
        castScanTimer = 0
        ScanNearbyCasts()
    end
end)

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName ~= ADDON_NAME then return end

        -- Wrap init in pcall so we get error reporting
        local initOk, initErr = pcall(function()
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
            myGUID = UnitGUID("player")
            MissedKick.myName = myName

            -- Find our interrupt (may fail if APIs aren't ready)
            FindMyInterrupt()
            RebuildPartyRoster()
        end)

        if not initOk then
            Print("|cffff0000Init error:|r " .. tostring(initErr))
        else
            Print("|cff00ff00Loaded!|r Build |cffffcc00" .. ADDON_BUILD .. "|r. Type |cff88ccff/mk help|r for commands.")
        end
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Re-init on world entry (APIs are more reliable here)
        local ok, err = pcall(function()
            myName = UnitName("player")
            myGUID = UnitGUID("player")
            MissedKick.myName = myName

            -- Init SavedVariables if ADDON_LOADED failed
            if not db then
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
            end

            FindMyInterrupt()
            RebuildPartyRoster()
        end)
        if not ok then
            Print("|cffff0000World entry error:|r " .. tostring(err))
        end
        if MissedKick_RefreshUI then MissedKick_RefreshUI() end

    elseif event == "UNIT_SPELLCAST_START"
        or event == "UNIT_SPELLCAST_CHANNEL_START"
        or event == "UNIT_SPELLCAST_EMPOWER_START" then
        local unit, castGUID, spellID, castID = ...
        local isChannel = event == "UNIT_SPELLCAST_CHANNEL_START"
        if event == "UNIT_SPELLCAST_EMPOWER_START" then
            spellID, castID = select(3, ...)
        end
        ScheduleNearbyCastUpdate(unit, spellID, castID, isChannel, true)

    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE"
        or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        local unit = ...
        ScheduleNearbyCastUpdate(unit)

    elseif event == "UNIT_TARGET"
        or event == "NAME_PLATE_UNIT_ADDED" then
        local unit = ...
        ScheduleNearbyCastUpdate(unit)

    elseif event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_EMPOWER_STOP"
        or event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "NAME_PLATE_UNIT_REMOVED" then
        ClearNearbyCast(...)

    elseif event == "RAID_TARGET_UPDATE" then
        RefreshNearbyCastMarkers()

    elseif event == "GROUP_ROSTER_UPDATE" then
        ScheduleRosterRebuild()
        if MissedKick_RefreshUI then MissedKick_RefreshUI() end

    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        pcall(FindMyInterrupt)
        pcall(RebuildPartyRoster)
        if MissedKick_RefreshUI then MissedKick_RefreshUI() end

    elseif event == "PLAYER_REGEN_DISABLED"
        or event == "PLAYER_REGEN_ENABLED"
        or event == "ZONE_CHANGED_NEW_AREA" then
        if MissedKick_RefreshUI then MissedKick_RefreshUI() end
    end
end)
