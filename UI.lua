-------------------------------------------------------------------------------
-- MissedKick - UI v1.0
--
-- Single movable frame with two sections:
--   1. Kick Cooldown Tracker — one row per party member
--   2. Nearby Casts — active enemy casts from nameplates
--
-- Frame is draggable (when unlocked), position saved across sessions.
-- OnUpdate handles cooldown countdown + nameplate scanning on throttled timers.
-------------------------------------------------------------------------------

local ADDON_NAME = "MissedKick"

-------------------------------------------------------------------------------
-- Layout Constants
-------------------------------------------------------------------------------
local FRAME_WIDTH       = 300
local MIN_FRAME_HEIGHT  = 120
local HEADER_HEIGHT     = 28
local ROW_HEIGHT        = 22
local SECTION_PAD       = 6
local ICON_SIZE         = 18
local CAST_SCAN_RATE    = 0.2   -- seconds between nameplate scans
local CD_UPDATE_RATE    = 0.1   -- seconds between cooldown display updates

-------------------------------------------------------------------------------
-- Color Palette
-------------------------------------------------------------------------------
local C_BG         = { 0.06, 0.06, 0.10, 0.88 }
local C_HEADER     = { 0.10, 0.08, 0.14, 1.0  }
local C_BORDER     = { 0.50, 0.25, 0.0,  0.6  }
local C_SECTION_BG = { 0.08, 0.08, 0.12, 0.6  }
local C_GREEN      = { 0.3,  1.0,  0.3  }
local C_RED        = { 1.0,  0.3,  0.3  }
local C_GRAY       = { 0.5,  0.5,  0.55 }
local C_WHITE      = { 1.0,  1.0,  1.0  }
local C_YELLOW     = { 1.0,  0.8,  0.2  }
local C_ORANGE     = { 1.0,  0.5,  0.1  }
local C_YOUR_KICK  = { 1.0,  0.15, 0.15 }

-------------------------------------------------------------------------------
-- Frame References
-------------------------------------------------------------------------------
local mainFrame     = nil
local kickRows      = {}   -- reusable row frames for party kicks
local castRows      = {}   -- reusable row frames for nearby casts
local markerButton  = nil  -- marker dropdown button
local lockButton    = nil  -- lock/unlock button
local sectionLabel  = nil  -- "Nearby Casts" label
local divider       = nil  -- divider line between sections

-- Throttle accumulators
local castTimer = 0
local cdTimer   = 0

-------------------------------------------------------------------------------
-- Helper: set a solid background on a frame
-------------------------------------------------------------------------------
local function SetBG(frame, r, g, b, a)
    if not frame._bg then
        frame._bg = frame:CreateTexture(nil, "BACKGROUND")
        frame._bg:SetAllPoints()
    end
    frame._bg:SetColorTexture(r, g, b, a or 1)
end

-------------------------------------------------------------------------------
-- Helper: create or reuse a kick row
-------------------------------------------------------------------------------
local function GetKickRow(parent, index)
    if kickRows[index] then return kickRows[index] end

    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)

    -- Spell icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("LEFT", 6, 0)

    -- Player name
    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.nameText:SetWidth(90)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    -- Status text (Ready / On CD / Unknown)
    row.statusText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.statusText:SetPoint("LEFT", row.nameText, "RIGHT", 4, 0)
    row.statusText:SetWidth(60)
    row.statusText:SetJustifyH("LEFT")

    -- Cooldown timer text
    row.cdText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.cdText:SetPoint("RIGHT", -8, 0)
    row.cdText:SetJustifyH("RIGHT")

    kickRows[index] = row
    return row
end

-------------------------------------------------------------------------------
-- Helper: create or reuse a nearby cast row
-------------------------------------------------------------------------------
local function GetCastRow(parent, index)
    if castRows[index] then return castRows[index] end

    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)

    -- Highlight background (for dangerous casts)
    row.highlight = row:CreateTexture(nil, "BACKGROUND")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(0, 0, 0, 0)

    -- Marker icon
    row.markerIcon = row:CreateTexture(nil, "ARTWORK")
    row.markerIcon:SetSize(ICON_SIZE, ICON_SIZE)
    row.markerIcon:SetPoint("LEFT", 6, 0)

    -- Cast text (enemy name → spell name)
    row.castText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.castText:SetPoint("LEFT", row.markerIcon, "RIGHT", 4, 0)
    row.castText:SetPoint("RIGHT", -8, 0)
    row.castText:SetJustifyH("LEFT")
    row.castText:SetWordWrap(false)

    castRows[index] = row
    return row
end

-------------------------------------------------------------------------------
-- Marker Dropdown: simple frame with marker buttons
-------------------------------------------------------------------------------
local markerDropdown = nil

local function ToggleMarkerDropdown()
    if not markerDropdown then
        markerDropdown = CreateFrame("Frame", "MissedKickMarkerDropdown", mainFrame, "BackdropTemplate")
        markerDropdown:SetSize(120, 210)
        markerDropdown:SetPoint("TOPRIGHT", markerButton, "BOTTOMRIGHT", 0, -2)
        markerDropdown:SetFrameStrata("DIALOG")
        markerDropdown:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        markerDropdown:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
        markerDropdown:SetBackdropBorderColor(0.5, 0.25, 0.0, 0.8)
        markerDropdown:EnableMouse(true)

        local markers = { "star", "circle", "diamond", "triangle", "moon", "square", "cross", "skull", "none" }
        for i, name in ipairs(markers) do
            local btn = CreateFrame("Button", nil, markerDropdown)
            btn:SetSize(110, 20)
            btn:SetPoint("TOPLEFT", 5, -5 - (i - 1) * 22)

            local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetAllPoints()
            label:SetJustifyH("LEFT")

            local idx = MissedKick.MARKER_NAMES[name]
            if idx and idx > 0 then
                local iconPath = MissedKick.MARKER_ICONS[idx]
                label:SetText("|T" .. iconPath .. ":14:14|t " .. name:sub(1,1):upper() .. name:sub(2))
            else
                label:SetText("  None")
            end

            local bg = btn:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, 0)

            btn:SetScript("OnEnter", function() bg:SetColorTexture(1, 1, 1, 0.1) end)
            btn:SetScript("OnLeave", function() bg:SetColorTexture(1, 1, 1, 0) end)
            btn:SetScript("OnClick", function()
                local db = MissedKick.GetDB()
                if db then db.myMarker = name end
                markerDropdown:Hide()
                RefreshMarkerButton()
                if name == "none" then
                    MissedKick.Print("Marker assignment |cff888888cleared|r.")
                else
                    MissedKick.Print("Marker set to |cffffcc00" .. name .. "|r.")
                end
            end)
        end
    end

    if markerDropdown:IsShown() then
        markerDropdown:Hide()
    else
        markerDropdown:Show()
    end
end

function RefreshMarkerButton()
    if not markerButton then return end
    local db = MissedKick.GetDB()
    if not db then return end
    local marker = db.myMarker or "none"
    local idx = MissedKick.MARKER_NAMES[marker]
    if idx and idx > 0 then
        local iconPath = MissedKick.MARKER_ICONS[idx]
        markerButton.text:SetText("|T" .. iconPath .. ":14:14|t")
    else
        markerButton.text:SetText("|cff888888●|r")
    end
end

-------------------------------------------------------------------------------
-- Build the Main Frame
-------------------------------------------------------------------------------
local function BuildFrame()
    mainFrame = CreateFrame("Frame", "MissedKickFrame", UIParent, "BackdropTemplate")
    mainFrame:SetSize(FRAME_WIDTH, MIN_FRAME_HEIGHT)
    mainFrame:SetPoint("CENTER", 0, 100)
    mainFrame:SetFrameStrata("MEDIUM")
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:SetClampedToScreen(true)
    mainFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    mainFrame:SetBackdropColor(unpack(C_BG))
    mainFrame:SetBackdropBorderColor(unpack(C_BORDER))
    table.insert(UISpecialFrames, "MissedKickFrame")

    -- Header (draggable area)
    local header = CreateFrame("Frame", nil, mainFrame)
    header:SetHeight(HEADER_HEIGHT)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    SetBG(header, unpack(C_HEADER))
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function()
        local db = MissedKick.GetDB()
        if db and db.frameLocked then return end
        mainFrame:StartMoving()
    end)
    header:SetScript("OnDragStop", function()
        mainFrame:StopMovingOrSizing()
        -- Save position
        local db = MissedKick.GetDB()
        if db then
            local point, _, relPoint, x, y = mainFrame:GetPoint()
            db.framePos = { point = point, relPoint = relPoint, x = x, y = y }
        end
    end)
    mainFrame.header = header

    -- Title text
    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", 10, 0)
    title:SetText("|cffff4444Missed|r |cffffcc00Kick|r")

    -- Lock/Unlock button
    lockButton = CreateFrame("Button", nil, header)
    lockButton:SetSize(20, 20)
    lockButton:SetPoint("RIGHT", -60, 0)
    lockButton.text = lockButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lockButton.text:SetAllPoints()
    local lockBg = lockButton:CreateTexture(nil, "BACKGROUND")
    lockBg:SetAllPoints()
    lockBg:SetColorTexture(1, 1, 1, 0)
    lockButton:SetScript("OnEnter", function() lockBg:SetColorTexture(1, 1, 1, 0.1) end)
    lockButton:SetScript("OnLeave", function() lockBg:SetColorTexture(1, 1, 1, 0) end)
    lockButton:SetScript("OnClick", function()
        local db = MissedKick.GetDB()
        if not db then return end
        db.frameLocked = not db.frameLocked
        UpdateLockButton()
        if db.frameLocked then
            MissedKick.Print("Frame |cff00ff00locked|r.")
        else
            MissedKick.Print("Frame |cffff8800unlocked|r.")
        end
    end)

    -- Marker button
    markerButton = CreateFrame("Button", nil, header)
    markerButton:SetSize(24, 24)
    markerButton:SetPoint("RIGHT", -32, 0)
    markerButton.text = markerButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    markerButton.text:SetAllPoints()
    local markerBg = markerButton:CreateTexture(nil, "BACKGROUND")
    markerBg:SetAllPoints()
    markerBg:SetColorTexture(1, 1, 1, 0)
    markerButton:SetScript("OnEnter", function() markerBg:SetColorTexture(1, 1, 1, 0.1) end)
    markerButton:SetScript("OnLeave", function() markerBg:SetColorTexture(1, 1, 1, 0) end)
    markerButton:SetScript("OnClick", ToggleMarkerDropdown)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, header)
    closeBtn:SetSize(HEADER_HEIGHT - 4, HEADER_HEIGHT - 4)
    closeBtn:SetPoint("RIGHT", -4, 0)
    local closeBg = closeBtn:CreateTexture(nil, "BACKGROUND")
    closeBg:SetAllPoints()
    closeBg:SetColorTexture(0.6, 0.1, 0.1, 0.5)
    local closeX = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    closeX:SetAllPoints()
    closeX:SetText("X")
    closeX:SetTextColor(1, 1, 1, 0.9)
    closeBtn:SetScript("OnClick", function() mainFrame:Hide() end)
    closeBtn:SetScript("OnEnter", function() closeBg:SetColorTexture(0.9, 0.1, 0.1, 0.8) end)
    closeBtn:SetScript("OnLeave", function() closeBg:SetColorTexture(0.6, 0.1, 0.1, 0.5) end)

    -- Content area anchor
    mainFrame.contentTop = HEADER_HEIGHT + 4

    -- Restore saved position
    local db = MissedKick.GetDB()
    if db and db.framePos then
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint(db.framePos.point, UIParent, db.framePos.relPoint, db.framePos.x, db.framePos.y)
    end

    -- OnUpdate: handles cooldown timers and nameplate scanning
    mainFrame:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then return end

        cdTimer = cdTimer + elapsed
        castTimer = castTimer + elapsed

        -- Update cooldown display
        if cdTimer >= CD_UPDATE_RATE then
            cdTimer = 0
            RefreshKickRows()
        end

        -- Scan nearby casts
        if castTimer >= CAST_SCAN_RATE then
            castTimer = 0
            MissedKick.ScanNearbyCasts()
            RefreshCastRows()
        end

        -- Resize frame to fit content
        ResizeFrame()
    end)

    UpdateLockButton()
    RefreshMarkerButton()
end

-------------------------------------------------------------------------------
-- Update lock button appearance
-------------------------------------------------------------------------------
function UpdateLockButton()
    if not lockButton then return end
    local db = MissedKick.GetDB()
    if not db then return end
    if db.frameLocked then
        lockButton.text:SetText("|cff00ff00L|r")  -- Locked indicator
    else
        lockButton.text:SetText("|cffff8800U|r")  -- Unlocked indicator
    end
end

-------------------------------------------------------------------------------
-- Refresh Kick Cooldown Rows
-- Rebuilds row data from MissedKick.partyKicks.
-------------------------------------------------------------------------------
function RefreshKickRows()
    if not mainFrame then return end
    local kicks = MissedKick.partyKicks
    local now = GetTime()
    local myName = MissedKick.GetMyName()

    -- Collect names for sorted display (player first, then alphabetical)
    local names = {}
    for name in pairs(kicks) do
        if name == myName then
            table.insert(names, 1, name)  -- player always first
        else
            names[#names + 1] = name
        end
    end

    -- Sort non-player names alphabetically
    if #names > 1 then
        table.sort(names, function(a, b)
            if a == myName then return true end
            if b == myName then return false end
            return a < b
        end)
    end

    local yOffset = mainFrame.contentTop

    for i, name in ipairs(names) do
        local row = GetKickRow(mainFrame, i)
        local entry = kicks[name]
        row:SetPoint("TOPLEFT", 0, -yOffset)
        row:SetPoint("RIGHT", 0, 0)
        row:Show()

        -- Player name
        local displayName = name
        if name == myName then displayName = name .. " |cff888888(you)|r" end
        row.nameText:SetText(displayName)

        -- Spell icon
        if entry.spellID then
            local tex = MissedKick.GetInterruptIcon(entry.spellID)
            if tex then
                row.icon:SetTexture(tex)
                row.icon:Show()
            else
                row.icon:Hide()
            end
        else
            row.icon:Hide()
        end

        -- Status + cooldown
        if not entry.hasAddon then
            row.statusText:SetText("|cff808080Unknown|r")
            row.statusText:SetTextColor(unpack(C_GRAY))
            row.cdText:SetText("")
            row.nameText:SetTextColor(unpack(C_GRAY))
        elseif entry.cdEnd > now then
            local remaining = entry.cdEnd - now
            row.statusText:SetText("|cffff4444On CD|r")
            row.cdText:SetText("|cffff4444" .. string.format("%.1fs", remaining) .. "|r")
            row.nameText:SetTextColor(unpack(C_RED))
        else
            row.statusText:SetText("|cff00ff00Ready|r")
            row.cdText:SetText("")
            row.nameText:SetTextColor(unpack(C_GREEN))
        end

        yOffset = yOffset + ROW_HEIGHT
    end

    -- Hide unused rows
    for i = #names + 1, #kickRows do
        if kickRows[i] then kickRows[i]:Hide() end
    end

    mainFrame._kickBottomY = yOffset
end

-------------------------------------------------------------------------------
-- Refresh Nearby Cast Rows
-- Rebuilds row data from MissedKick.nearbyCasts.
-------------------------------------------------------------------------------
function RefreshCastRows()
    if not mainFrame then return end
    local casts = MissedKick.nearbyCasts
    local db = MissedKick.GetDB()
    local yOffset = (mainFrame._kickBottomY or mainFrame.contentTop) + SECTION_PAD

    -- Section header
    if not sectionLabel then
        sectionLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sectionLabel:SetTextColor(0.7, 0.7, 0.75, 1)
    end

    if not divider then
        divider = mainFrame:CreateTexture(nil, "ARTWORK")
        divider:SetHeight(1)
        divider:SetColorTexture(0.4, 0.25, 0.0, 0.4)
    end

    if #casts > 0 then
        divider:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 8, -yOffset)
        divider:SetPoint("RIGHT", mainFrame, "RIGHT", -8, 0)
        divider:Show()
        yOffset = yOffset + 4

        sectionLabel:SetPoint("TOPLEFT", 8, -yOffset)
        sectionLabel:SetText("Nearby Casts")
        sectionLabel:Show()
        yOffset = yOffset + 16
    else
        sectionLabel:Hide()
        divider:Hide()
    end

    for i, cast in ipairs(casts) do
        local row = GetCastRow(mainFrame, i)
        row:SetPoint("TOPLEFT", 0, -yOffset)
        row:SetPoint("RIGHT", 0, 0)
        row:Show()

        -- Raid marker icon
        if cast.markerIndex and MissedKick.MARKER_ICONS[cast.markerIndex] then
            row.markerIcon:SetTexture(MissedKick.MARKER_ICONS[cast.markerIndex])
            row.markerIcon:Show()
        else
            row.markerIcon:SetTexture(nil)
            row.markerIcon:Hide()
        end

        -- Build cast text
        local text = cast.enemyName .. " |cff888888→|r " .. cast.spellName
        if cast.targetName then
            text = text .. " |cff888888on|r " .. cast.targetName
        end

        -- Check dangerous status
        local isDangerous, isYourKick = MissedKick.IsDangerousCast(cast.spellID, cast.spellName, cast.markerIndex)

        if isYourKick then
            -- YOUR KICK: strong red highlight
            row.highlight:SetColorTexture(1.0, 0.1, 0.1, 0.25)
            row.castText:SetText("|cffff2222⚠ YOUR KICK|r  " .. text)
            row.castText:SetTextColor(unpack(C_YOUR_KICK))
        elseif isDangerous then
            -- Dangerous: orange/yellow highlight
            row.highlight:SetColorTexture(1.0, 0.5, 0.0, 0.15)
            row.castText:SetText("|cffffaa00⚠|r " .. text)
            row.castText:SetTextColor(unpack(C_ORANGE))
        else
            -- Normal cast
            row.highlight:SetColorTexture(0, 0, 0, 0)
            row.castText:SetText(text)
            row.castText:SetTextColor(unpack(C_WHITE))
        end

        yOffset = yOffset + ROW_HEIGHT
    end

    -- Hide unused cast rows
    for i = #casts + 1, #castRows do
        if castRows[i] then castRows[i]:Hide() end
    end

    mainFrame._totalHeight = yOffset + 6
end

-------------------------------------------------------------------------------
-- Resize frame to fit content dynamically
-------------------------------------------------------------------------------
function ResizeFrame()
    if not mainFrame then return end
    local h = mainFrame._totalHeight or MIN_FRAME_HEIGHT
    mainFrame:SetHeight(math.max(h, MIN_FRAME_HEIGHT))
end

-------------------------------------------------------------------------------
-- Public UI Functions (called from MissedKick.lua slash commands)
-------------------------------------------------------------------------------
function MissedKick_ShowFrame()
    if not mainFrame then BuildFrame() end
    mainFrame:Show()
    -- Force an immediate refresh
    RefreshKickRows()
    MissedKick.ScanNearbyCasts()
    RefreshCastRows()
    ResizeFrame()
end

function MissedKick_HideFrame()
    if mainFrame then mainFrame:Hide() end
    if markerDropdown then markerDropdown:Hide() end
end

function MissedKick_UpdateLock()
    UpdateLockButton()
end

function MissedKick_RefreshUI()
    RefreshMarkerButton()
    if mainFrame and mainFrame:IsShown() then
        RefreshKickRows()
        RefreshCastRows()
        ResizeFrame()
    end
end

-------------------------------------------------------------------------------
-- Auto-show frame on load (deferred to let Core init first)
-------------------------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    -- Auto-show the frame after a short delay
    C_Timer.After(1, function()
        MissedKick_ShowFrame()
    end)
end)
