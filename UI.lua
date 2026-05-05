-------------------------------------------------------------------------------
-- MissedKick - UI v2.1
-- Fixed: position persistence, frame lock, no close button on tracker
-------------------------------------------------------------------------------

local FRAME_WIDTH    = 220
local CAST_FRAME_WIDTH = 280
local BAR_HEIGHT     = 22
local HEADER_H       = 24
local ICON_SZ        = 18
local CAST_SCAN_RATE = 0.2
local CD_UPDATE_RATE = 0.1

local CLASS_COLORS = {
    WARRIOR={0.78,0.61,0.43}, PALADIN={0.96,0.55,0.73}, HUNTER={0.67,0.83,0.45},
    ROGUE={1.00,0.96,0.41}, PRIEST={1.00,1.00,1.00}, DEATHKNIGHT={0.77,0.12,0.23},
    SHAMAN={0.00,0.44,0.87}, MAGE={0.25,0.78,0.92}, WARLOCK={0.53,0.53,0.93},
    MONK={0.00,1.00,0.60}, DRUID={1.00,0.49,0.04}, DEMONHUNTER={0.64,0.19,0.79},
    EVOKER={0.20,0.58,0.50},
}

local function GetClassColor(class)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]; return c.r, c.g, c.b
    end
    local c = class and CLASS_COLORS[class]
    if c then return c[1], c[2], c[3] end
    return 0.5, 0.5, 0.5
end

local mainFrame, castFrame, settingsFrame
local kickRows, castRows = {}, {}
local cdTimer, castTimer = 0, 0
local BuildCastFrame
local nextOutlineDebug = 0

local function GetDB()
    if MissedKick and MissedKick.GetDB then
        local db = MissedKick.GetDB()
        if db then return db end
    end
    return MissedKickDB
end

local function PositionCastFrame(forceDefault)
    if not castFrame then return end

    local parentW = UIParent:GetWidth() or 0
    local parentH = UIParent:GetHeight() or 0
    local saved = MissedKickDB and MissedKickDB.castFramePos
    local x = saved and saved.x
    local y = saved and saved.y
    local maxX = math.max(0, parentW - CAST_FRAME_WIDTH)
    local minY = HEADER_H + 30
    local maxY = math.max(minY, parentH - 4)
    local useSaved = not forceDefault and x and y and x >= 0 and x <= maxX and y >= minY and y <= maxY

    castFrame:ClearAllPoints()
    if useSaved then
        castFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    elseif mainFrame then
        castFrame:SetPoint("TOPLEFT", mainFrame, "TOPRIGHT", 8, 0)
    else
        castFrame:SetPoint("CENTER", UIParent, "CENTER", 250, 100)
    end
end

local function IsFrameLocked()
    local db = GetDB()
    return db and db.frameLocked
end

local function SetFrameLocked(locked)
    local db = GetDB()
    if not db then
        MissedKickDB = MissedKickDB or {}
        db = MissedKickDB
    end
    db.frameLocked = locked and true or false
end

local function ApplyFrameLockState()
    if mainFrame then
        mainFrame:SetMovable(not IsFrameLocked())
    end
    if castFrame then
        castFrame:SetMovable(not IsFrameLocked())
    end
end

local function PositionMainFrame(forceCenter)
    if not mainFrame then return end

    local parentW = UIParent:GetWidth() or 0
    local parentH = UIParent:GetHeight() or 0
    local saved = MissedKickDB and MissedKickDB.framePos
    local x = saved and saved.x
    local y = saved and saved.y

    local maxX = math.max(0, parentW - FRAME_WIDTH)
    local minY = HEADER_H + 30
    local maxY = math.max(minY, parentH - 4)
    local useSaved = not forceCenter and x and y and x >= 0 and x <= maxX and y >= minY and y <= maxY

    mainFrame:ClearAllPoints()
    if useSaved then
        mainFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    else
        mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
        if MissedKickDB then
            C_Timer.After(0, function()
                local left = mainFrame and mainFrame:GetLeft()
                local top = mainFrame and mainFrame:GetTop()
                if MissedKickDB and left and top then
                    MissedKickDB.framePos = { x = left, y = top }
                end
            end)
        end
    end
end

local function RefreshLockMenuText(label)
    if label then
        label:SetText(IsFrameLocked() and "Unlock Frame" or "Lock Frame")
    end
end

-- Row helpers
local function SetRowFill(row, r, g, b, a, pct)
    pct = math.max(0, math.min(1, pct or 0))
    row.fill:ClearAllPoints()
    row.fill:SetPoint("TOPLEFT")
    row.fill:SetPoint("BOTTOMLEFT")
    row.fill:SetWidth(math.max(1, FRAME_WIDTH * pct))
    row.fill:SetColorTexture(r, g, b, a)
    if pct > 0 then row.fill:Show() else row.fill:Hide() end
end

local function GetCooldownDuration(entry)
    if entry.cdDuration and entry.cdDuration > 0 then
        return entry.cdDuration
    end
    if entry.spellID and MissedKick.INTERRUPT_SPELLS[entry.spellID] then
        return MissedKick.INTERRUPT_SPELLS[entry.spellID].cd
    end
    return nil
end

local function GetKickRow(parent, i)
    if kickRows[i] then return kickRows[i] end
    local row = CreateFrame("Frame", nil, parent); row:SetHeight(BAR_HEIGHT)
    row.bar = row:CreateTexture(nil, "BACKGROUND"); row.bar:SetAllPoints(); row.bar:SetColorTexture(0.3,0.3,0.3,0.6)
    row.fill = row:CreateTexture(nil, "BORDER")
    row.overlay = row:CreateTexture(nil, "BORDER"); row.overlay:SetAllPoints(); row.overlay:SetColorTexture(0,0,0,0)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.name:SetPoint("LEFT", 6, 0); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false); row.name:SetWidth(FRAME_WIDTH-60)
    row.icon = row:CreateTexture(nil, "OVERLAY"); row.icon:SetSize(ICON_SZ, ICON_SZ); row.icon:SetPoint("RIGHT", -28, 0)
    row.cd = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); row.cd:SetPoint("RIGHT", -4, 0); row.cd:SetJustifyH("RIGHT"); row.cd:SetWidth(24)
    kickRows[i] = row; return row
end

local function GetCastRow(parent, i)
    if castRows[i] then return castRows[i] end
    local row = CreateFrame("Frame", nil, parent); row:SetHeight(BAR_HEIGHT)
    row.bg = row:CreateTexture(nil, "BACKGROUND"); row.bg:SetAllPoints(); row.bg:SetColorTexture(0.05,0.05,0.07,0.82)
    row.fill = CreateFrame("StatusBar", nil, row)
    row.fill:SetAllPoints()
    row.fill:SetMinMaxValues(0, 1)
    row.fill:SetValue(0)
    row.fill:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    if row.fill.SetOrientation then row.fill:SetOrientation("HORIZONTAL") end
    row.overlay = row.fill:CreateTexture(nil, "BORDER"); row.overlay:SetAllPoints(); row.overlay:SetColorTexture(0,0,0,0.18)
    row.textLayer = CreateFrame("Frame", nil, row)
    row.textLayer:SetAllPoints()
    row.textLayer:SetFrameLevel(row.fill:GetFrameLevel() + 2)
    row.marker = row.textLayer:CreateTexture(nil, "ARTWORK"); row.marker:SetSize(ICON_SZ,ICON_SZ); row.marker:SetPoint("RIGHT",-6,0); row.marker:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    row.text = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", row.marker, "RIGHT", 4, 0); row.text:SetPoint("RIGHT",-6,0); row.text:SetJustifyH("LEFT"); row.text:SetWordWrap(false)
    row.prefix = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.enemy = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.sep = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.spell = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.prefix:SetJustifyH("LEFT"); row.enemy:SetJustifyH("LEFT"); row.sep:SetJustifyH("CENTER"); row.spell:SetJustifyH("LEFT")
    row.prefix:SetWordWrap(false); row.enemy:SetWordWrap(false); row.sep:SetWordWrap(false); row.spell:SetWordWrap(false)
    row.borderTop = row.textLayer:CreateTexture(nil, "OVERLAY")
    row.borderBottom = row.textLayer:CreateTexture(nil, "OVERLAY")
    row.borderLeft = row.textLayer:CreateTexture(nil, "OVERLAY")
    row.borderRight = row.textLayer:CreateTexture(nil, "OVERLAY")
    row.borderTop:SetPoint("TOPLEFT"); row.borderTop:SetPoint("TOPRIGHT"); row.borderTop:SetHeight(2)
    row.borderBottom:SetPoint("BOTTOMLEFT"); row.borderBottom:SetPoint("BOTTOMRIGHT"); row.borderBottom:SetHeight(2)
    row.borderLeft:SetPoint("TOPLEFT"); row.borderLeft:SetPoint("BOTTOMLEFT"); row.borderLeft:SetWidth(2)
    row.borderRight:SetPoint("TOPRIGHT"); row.borderRight:SetPoint("BOTTOMRIGHT"); row.borderRight:SetWidth(2)
    row.borderTop:SetColorTexture(1, 0.05, 0.05, 1)
    row.borderBottom:SetColorTexture(1, 0.05, 0.05, 1)
    row.borderLeft:SetColorTexture(1, 0.05, 0.05, 1)
    row.borderRight:SetColorTexture(1, 0.05, 0.05, 1)
    row.borderTop:Hide(); row.borderBottom:Hide(); row.borderLeft:Hide(); row.borderRight:Hide()
    row.time = row.fill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.time:SetPoint("RIGHT", -6, 0); row.time:SetJustifyH("RIGHT"); row.time:SetWidth(34)
    castRows[i] = row; return row
end

local function SetFontTextSafe(fontString, value, fallback)
    local ok = false
    if value ~= nil then
        ok = pcall(fontString.SetText, fontString, value)
    end
    if not ok then
        fontString:SetText(fallback or "")
    end
end

local function SetCastText(row, c, prefixText, r, g, b)
    row.text:Hide()

    SetFontTextSafe(row.prefix, prefixText or "", "")
    SetFontTextSafe(row.enemy, c.enemyNameRaw or c.enemyName, c.enemyName or "Unknown Enemy")
    row.sep:SetText("-")
    SetFontTextSafe(row.spell, c.spellNameRaw or c.spellName, c.spellName or "Unknown Spell")

    row.prefix:SetTextColor(r, g, b)
    row.enemy:SetTextColor(r, g, b)
    row.sep:SetTextColor(0.68, 0.68, 0.68)
    row.spell:SetTextColor(r, g, b)

    row.prefix:Show()
    row.enemy:Show()
    row.sep:Show()
    row.spell:Show()
end

local function LayoutCastText(row, leftOffset, prefixWidth)
    row.prefix:ClearAllPoints()
    row.enemy:ClearAllPoints()
    row.sep:ClearAllPoints()
    row.spell:ClearAllPoints()

    prefixWidth = prefixWidth or 0
    row.prefix:SetPoint("LEFT", leftOffset, 0)
    row.prefix:SetWidth(prefixWidth)
    row.enemy:SetPoint("LEFT", row.prefix, "RIGHT", 0, 0)
    row.enemy:SetWidth(108)
    row.sep:SetPoint("LEFT", row.enemy, "RIGHT", 2, 0)
    row.sep:SetWidth(12)
    row.spell:SetPoint("LEFT", row.sep, "RIGHT", 2, 0)
    row.spell:SetPoint("RIGHT", -28, 0)
end

local function SetCastFillColor(row, r, g, b, a)
    if row.fill.SetStatusBarColor then
        row.fill:SetStatusBarColor(r, g, b, a)
    end
end

local function SetCastFill(row, c, pct)
    row.fill:Show()
    if c.durationObject and row.fill.SetTimerDuration then
        local timerSpell = c.cleanSpellID or c.spellID or c.spellName
        if row._timerUnit ~= c.unit or row._timerSpell ~= timerSpell or row._isChannel ~= c.isChannel then
            row._timerUnit = c.unit
            row._timerSpell = timerSpell
            row._isChannel = c.isChannel
            row.fill:SetTimerDuration(c.durationObject, Enum.StatusBarInterpolation.None, c.isChannel and 1 or 0)
        end
        return
    end

    row._timerUnit = nil
    row._timerSpell = nil
    row._isChannel = nil
    pct = math.max(0, math.min(1, pct or 0))
    row.fill:SetMinMaxValues(0, 1)
    row.fill:SetValue(pct)
end

local function SetCastOutline(row, show)
    if show then
        row.borderTop:SetAlpha(1)
        row.borderBottom:SetAlpha(1)
        row.borderLeft:SetAlpha(1)
        row.borderRight:SetAlpha(1)
        row.borderTop:Show()
        row.borderBottom:Show()
        row.borderLeft:Show()
        row.borderRight:Show()
    else
        row.borderTop:Hide()
        row.borderBottom:Hide()
        row.borderLeft:Hide()
        row.borderRight:Hide()
    end
end

local function SetCastOutlineAlpha(row, alpha)
    row.borderTop:Show()
    row.borderBottom:Show()
    row.borderLeft:Show()
    row.borderRight:Show()
    row.borderTop:SetAlpha(alpha)
    row.borderBottom:SetAlpha(alpha)
    row.borderLeft:SetAlpha(alpha)
    row.borderRight:SetAlpha(alpha)
end

local function SetCastMarker(row, unit, markerIndex)
    if unit and GetRaidTargetIndex then
        local okUnitMarker, unitMarker = pcall(GetRaidTargetIndex, unit)
        if okUnitMarker then
            pcall(function()
                if unitMarker ~= nil then
                    markerIndex = unitMarker
                end
            end)
        end
    end

    local isNil = false
    local okNil = pcall(function()
        if markerIndex == nil then
            isNil = true
        end
    end)
    if okNil and isNil then
        row.marker:Hide()
        return false
    end

    local ok = false
    if SetRaidTargetIconTexture then
        row.marker:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
        ok = pcall(SetRaidTargetIconTexture, row.marker, markerIndex)
    end
    if ok then
        row.marker:Show()
        return true
    end

    row.marker:Hide()
    return false
end

local function GetAssignedMarkerIndex()
    local db = GetDB()
    if not (db and db.myMarker and db.myMarker ~= "none") then return nil end
    local assignedIndex = MissedKick.MARKER_NAMES and MissedKick.MARKER_NAMES[db.myMarker]
    if assignedIndex and assignedIndex > 0 then
        return assignedIndex
    end

    return nil
end

-- Refresh kick bars
local function RefreshKicks()
    if not mainFrame then return end
    local kicks = MissedKick.partyKicks
    local now = GetTime(); local me = MissedKick.GetMyName()
    if MissedKick.GetMyKickCooldown then
        local selfCdEnd, selfCdDuration, selfSpellID = MissedKick.GetMyKickCooldown()
        local selfName = me or UnitName("player")
        if selfName then
            local selfEntry = kicks[selfName]
            if not selfEntry then
                local _, myClass = UnitClass("player")
                selfEntry = { spellID = selfSpellID, cdEnd = 0, cdDuration = selfCdDuration, hasAddon = true, class = myClass, isSelf = true }
                kicks[selfName] = selfEntry
            end
            selfEntry.isSelf = true
            selfEntry.hasAddon = true
            if selfSpellID then selfEntry.spellID = selfSpellID end
            if selfCdDuration then selfEntry.cdDuration = selfCdDuration end
            if selfCdEnd and selfCdEnd > 0 then selfEntry.cdEnd = selfCdEnd end
        end
    end
    local names = {}; for n in pairs(kicks) do names[#names+1] = n end
    table.sort(names, function(a,b)
        if kicks[a].isSelf then return true end; if kicks[b].isSelf then return false end
        if a==me then return true end; if b==me then return false end
        local ak,bk = kicks[a].hasAddon, kicks[b].hasAddon
        if ak~=bk then return ak end; return a<b
    end)
    local y = HEADER_H + 2
    for i,n in ipairs(names) do
        local row = GetKickRow(mainFrame, i); local e = kicks[n]
        row:SetPoint("TOPLEFT", 0, -y); row:SetPoint("RIGHT"); row:Show()
        if (e.isSelf or n == me) and MissedKick.GetMyKickCooldown then
            local selfCdEnd, selfCdDuration, selfSpellID = MissedKick.GetMyKickCooldown()
            if selfCdEnd and selfCdEnd > (e.cdEnd or 0) then
                e.cdEnd = selfCdEnd
                e.cdDuration = selfCdDuration or e.cdDuration
            end
            if selfSpellID then e.spellID = selfSpellID end
            e.hasAddon = true
        end
        local cr,cg,cb = GetClassColor(e.class)
        if not e.hasAddon then
            row.bar:SetColorTexture(0.2,0.2,0.2,0.5); row.overlay:SetColorTexture(0,0,0,0)
            SetRowFill(row, cr,cg,cb,0, 0)
            row.name:SetText(n); row.name:SetTextColor(0.5,0.5,0.5)
            row.cd:SetText("?"); row.cd:SetTextColor(0.5,0.5,0.5); row.icon:Hide()
        elseif e.cdEnd > now then
            local rem = e.cdEnd-now
            local total = GetCooldownDuration(e) or rem
            local progress = 1 - (rem / total)
            row.bar:SetColorTexture(0.08,0.08,0.1,0.78); row.overlay:SetColorTexture(0,0,0,0.25)
            SetRowFill(row, cr,cg,cb,0.55, progress)
            row.name:SetText(n); row.name:SetTextColor(0.7,0.7,0.7)
            row.cd:SetText(string.format("%.0f",rem)); row.cd:SetTextColor(1,0.3,0.3)
            if e.spellID then local tex=MissedKick.GetInterruptIcon(e.spellID); if tex then row.icon:SetTexture(tex); row.icon:SetDesaturated(true); row.icon:Show() else row.icon:Hide() end else row.icon:Hide() end
        else
            row.bar:SetColorTexture(0.08,0.08,0.1,0.65); row.overlay:SetColorTexture(0,0,0,0)
            SetRowFill(row, cr,cg,cb,0.65, 1)
            row.name:SetText(n); row.name:SetTextColor(1,1,1); row.cd:SetText("")
            if e.spellID then local tex=MissedKick.GetInterruptIcon(e.spellID); if tex then row.icon:SetTexture(tex); row.icon:SetDesaturated(false); row.icon:Show() else row.icon:Hide() end else row.icon:Hide() end
        end
        y = y + BAR_HEIGHT + 1
    end
    for i=#names+1,#kickRows do if kickRows[i] then kickRows[i]:Hide() end end
    mainFrame._castTop = y
    mainFrame:SetHeight(math.max(y+4, HEADER_H+30))
end

-- Refresh cast rows
local function RefreshCasts()
    if not castFrame and BuildCastFrame then BuildCastFrame() end
    if not castFrame then return end
    local casts = MissedKick.nearbyCasts
    local now = GetTime()
    if #casts == 0 then
        castFrame:Hide()
        for i=1,#castRows do if castRows[i] then castRows[i]._timerUnit=nil; castRows[i]._timerSpell=nil; castRows[i]:Hide() end end
        return
    end
    castFrame:Show()
    castFrame:Raise()
    local y = HEADER_H + 2
    for i,c in ipairs(casts) do
        local row = GetCastRow(castFrame,i); row:SetPoint("TOPLEFT",0,-y); row:SetPoint("RIGHT"); row:Show()
        local textLeft = 6
        if c.unit and MissedKick.GetRaidMarkerForUnit then
            c.markerIndexRaw, c.markerIndex = MissedKick.GetRaidMarkerForUnit(c.unit)
        end
        local markerForRow = c.markerIndexRaw
        pcall(function()
            if markerForRow == nil then
                markerForRow = c.markerIndex
            end
        end)
        local markerShown = SetCastMarker(row, c.unit, markerForRow)
        if markerShown then
            row.text:ClearAllPoints(); row.text:SetPoint("LEFT", 6, 0); row.text:SetPoint("RIGHT",-28,0)
        else
            row.text:ClearAllPoints(); row.text:SetPoint("LEFT", 6, 0); row.text:SetPoint("RIGHT",-6,0)
        end
        local pct = 0
        if c.endTime and c.duration then
            local rem = math.max(0, c.endTime - now)
            local dur = math.max(0.1, c.duration)
            pct = 1 - (rem / dur)
        end
        SetCastFillColor(row, 0.78,0.46,0.06,0.86)
        SetCastFill(row, c, pct)
        local assignedMarker = GetAssignedMarkerIndex()
        local outlineAlpha = (assignedMarker and markerShown) and 1 or 0
        if MissedKick and MissedKick.IsDebugEnabled and MissedKick.IsDebugEnabled()
            and MissedKick.DebugPrint and now >= nextOutlineDebug then
            nextOutlineDebug = now + 1.5
            local db = GetDB()
            local assigned = db and db.myMarker or "none"
            local markerSecret = false
            if hasanysecretvalues then
                local okSecret, isSecret = pcall(hasanysecretvalues, markerForRow)
                markerSecret = okSecret and isSecret or false
            end
            MissedKick.DebugPrint("outline assigned=" .. tostring(assigned)
                .. " markerShown=" .. tostring(markerShown)
                .. " markerSecret=" .. tostring(markerSecret)
                .. " mode=marked-fallback")
        end
        SetCastOutlineAlpha(row, outlineAlpha)
        local dng, yours = false, false
        if MissedKick.IsDangerousCast then
            local okDanger, isDangerous, isYours = pcall(MissedKick.IsDangerousCast, c.spellID, c.spellName, nil)
            if okDanger then
                dng, yours = isDangerous, isYours
            end
        end
        local prefixWidth = yours and 18 or (dng and 12 or 0)
        LayoutCastText(row, textLeft, prefixWidth)
        if yours then row.bg:SetColorTexture(0.18,0.02,0.02,0.9); SetCastFillColor(row, 0.9,0.08,0.06,0.88); SetCastText(row, c, "!!", 1,0.2,0.2)
        elseif dng then row.bg:SetColorTexture(0.12,0.07,0.01,0.9); SetCastFillColor(row, 0.88,0.47,0.02,0.88); SetCastText(row, c, "!", 1,0.65,0.15)
        else row.bg:SetColorTexture(0.08,0.08,0.1,0.72); SetCastText(row, c, "", 0.9,0.9,0.9) end
        row.time:SetText("")
        y=y+BAR_HEIGHT
    end
    for i=#casts+1,#castRows do if castRows[i] then castRows[i]._timerUnit=nil; castRows[i]._timerSpell=nil; castRows[i].text:Hide(); castRows[i].prefix:Hide(); castRows[i].enemy:Hide(); castRows[i].sep:Hide(); castRows[i].spell:Hide(); SetCastOutlineAlpha(castRows[i], 0); castRows[i]:Hide() end end
    castFrame:SetHeight(math.max(y+4, HEADER_H+30))
end

BuildCastFrame = function()
    castFrame = CreateFrame("Frame","MissedKickCastFrame",UIParent,"BackdropTemplate")
    castFrame:SetSize(CAST_FRAME_WIDTH, HEADER_H+30)
    castFrame:SetFrameStrata("MEDIUM")
    castFrame:SetMovable(true); castFrame:EnableMouse(true); castFrame:SetClampedToScreen(true)
    castFrame:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
    castFrame:SetBackdropColor(0.05,0.05,0.08,0.92); castFrame:SetBackdropBorderColor(0.15,0.15,0.2,0.8)
    castFrame:Hide()
    castFrame._refreshTimer = 0
    castFrame:SetScript("OnUpdate", function(self, elapsed)
        self._refreshTimer = (self._refreshTimer or 0) + elapsed
        if self._refreshTimer >= 0.05 then
            self._refreshTimer = 0
            RefreshCasts()
        end
    end)

    PositionCastFrame(false)

    local header = CreateFrame("Button", nil, castFrame)
    header:SetHeight(HEADER_H)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:RegisterForClicks("RightButtonUp")

    local hdrTex = header:CreateTexture(nil,"ARTWORK")
    hdrTex:SetAllPoints()
    hdrTex:SetColorTexture(0.08,0.06,0.12,1)
    local title = header:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    title:SetPoint("TOPLEFT",8,-6); title:SetText("|cffff4444Nearby |cffffcc00Casts|r")

    header:SetScript("OnDragStart", function()
        if IsFrameLocked() then
            castFrame:StopMovingOrSizing()
            return
        end
        castFrame:SetMovable(true)
        castFrame:StartMoving()
    end)
    header:SetScript("OnDragStop", function()
        local left = castFrame:GetLeft()
        local top  = castFrame:GetTop()
        castFrame:StopMovingOrSizing()
        if MissedKickDB and left and top then
            MissedKickDB.castFramePos = { x = left, y = top }
        end
        ApplyFrameLockState()
    end)

    local lm = CreateFrame("Button", "MKCastLockMenu", UIParent, "BackdropTemplate")
    lm:SetSize(140, 26)
    lm:SetFrameStrata("TOOLTIP")
    lm:SetToplevel(true)
    lm:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8", edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=1})
    lm:SetBackdropColor(0.06, 0.06, 0.1, 0.97)
    lm:SetBackdropBorderColor(0.4, 0.2, 0.0, 1)
    lm:Hide()
    lm:EnableMouse(true)
    lm:RegisterForClicks("AnyDown")
    local lmLbl = lm:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lmLbl:SetPoint("LEFT", 10, 0)
    local lmHl = lm:CreateTexture(nil, "HIGHLIGHT")
    lmHl:SetAllPoints()
    lmHl:SetColorTexture(1, 1, 1, 0.08)
    lm:SetScript("OnMouseDown", function(_, btn)
        if btn ~= "LeftButton" then return end
        local locked = not IsFrameLocked()
        SetFrameLocked(locked)
        ApplyFrameLockState()
        RefreshLockMenuText(lmLbl)
        if locked then
            MissedKick.Print("|cff00ff00Frame locked.|r Right-click to unlock.")
        else
            MissedKick.Print("|cffff8800Frame unlocked.|r Drag to reposition.")
        end
        lm:Hide()
    end)
    header:SetScript("OnClick", function(_, btn)
        if btn ~= "RightButton" then return end
        if lm:IsShown() then
            lm:Hide()
        else
            RefreshLockMenuText(lmLbl)
            lm:ClearAllPoints()
            lm:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
            lm:SetFrameLevel(castFrame:GetFrameLevel() + 100)
            lm:Show()
        end
    end)
    castFrame:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then lm:Hide() end
    end)
    ApplyFrameLockState()
end

-- Build main frame
local function BuildMain()
    mainFrame = CreateFrame("Frame","MissedKickFrame",UIParent,"BackdropTemplate")
    mainFrame:SetSize(FRAME_WIDTH, 100)
    mainFrame:SetFrameStrata("MEDIUM")
    mainFrame:SetMovable(true); mainFrame:EnableMouse(true); mainFrame:SetClampedToScreen(true)
    mainFrame:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
    mainFrame:SetBackdropColor(0.05,0.05,0.08,0.92); mainFrame:SetBackdropBorderColor(0.15,0.15,0.2,0.8)
    table.insert(UISpecialFrames,"MissedKickFrame")

    -- Position: restore from saved or default to center
    PositionMainFrame(false)

    -- Header: draggable area and right-click lock menu target.
    local header = CreateFrame("Button", nil, mainFrame)
    header:SetHeight(HEADER_H)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:RegisterForClicks("RightButtonUp")

    local hdrTex = header:CreateTexture(nil,"ARTWORK")
    hdrTex:SetAllPoints()
    hdrTex:SetColorTexture(0.08,0.06,0.12,1)
    local title = header:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    title:SetPoint("TOPLEFT",8,-6); title:SetText("|cffff4444Missed |cffffcc00Kick|r")

    header:SetScript("OnDragStart", function()
        if IsFrameLocked() then
            mainFrame:StopMovingOrSizing()
            return
        end
        mainFrame:SetMovable(true)
        mainFrame:StartMoving()
    end)
    header:SetScript("OnDragStop", function()
        -- Read position BEFORE StopMovingOrSizing (BliZzi-proven pattern)
        local left = mainFrame:GetLeft()
        local top  = mainFrame:GetTop()
        mainFrame:StopMovingOrSizing()
        if MissedKickDB and left and top then
            MissedKickDB.framePos = { x = left, y = top }
        end
        ApplyFrameLockState()
    end)

    -- Right-click lock context menu.
    -- Built as a single Button (no child frames) to avoid OnLeave race conditions
    -- where the menu hides before the click registers.
    local lm = CreateFrame("Button", "MKLockMenu", UIParent, "BackdropTemplate")
    lm:SetSize(140, 26)
    lm:SetFrameStrata("TOOLTIP")
    lm:SetToplevel(true)
    lm:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8", edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=1})
    lm:SetBackdropColor(0.06, 0.06, 0.1, 0.97)
    lm:SetBackdropBorderColor(0.4, 0.2, 0.0, 1)
    lm:Hide()
    lm:EnableMouse(true)
    lm:RegisterForClicks("AnyDown")
    local lmLbl = lm:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lmLbl:SetPoint("LEFT", 10, 0)
    local lmHl = lm:CreateTexture(nil, "HIGHLIGHT")
    lmHl:SetAllPoints()
    lmHl:SetColorTexture(1, 1, 1, 0.08)
    lm:SetScript("OnMouseDown", function(_, btn)
        if btn ~= "LeftButton" then return end
        local locked = not IsFrameLocked()
        SetFrameLocked(locked)
        ApplyFrameLockState()
        RefreshLockMenuText(lmLbl)
        if locked then
            MissedKick.Print("|cff00ff00Frame locked.|r Right-click to unlock.")
        else
            MissedKick.Print("|cffff8800Frame unlocked.|r Drag to reposition.")
        end
        lm:Hide()
    end)
    header:SetScript("OnClick", function(_, btn)
        if btn ~= "RightButton" then return end
        if lm:IsShown() then
            lm:Hide()
        else
            RefreshLockMenuText(lmLbl)
            lm:ClearAllPoints()
            lm:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
            lm:SetFrameLevel(mainFrame:GetFrameLevel() + 100)
            lm:Show()
        end
    end)
    mainFrame:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then lm:Hide() end
    end)

    mainFrame:SetScript("OnUpdate",function(self,dt)
        if not self:IsShown() then return end
        cdTimer=cdTimer+dt
        if cdTimer>=CD_UPDATE_RATE then cdTimer=0; RefreshKicks() end
    end)
    ApplyFrameLockState()
end

-- Settings frame
local listEntries = {}

function RefreshDangerousList()
    for _,e in ipairs(listEntries) do e:Hide() end
    if not (settingsFrame and settingsFrame._dp and MissedKickDB) then return end
    local idx = 0
    for key in pairs(MissedKickDB.dangerousCasts) do
        idx=idx+1
        local row = listEntries[idx]
        if not row then
            row=CreateFrame("Frame",nil,settingsFrame._dp); row:SetHeight(20)
            row.text=row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); row.text:SetPoint("LEFT",4,0); row.text:SetJustifyH("LEFT")
            row.del=CreateFrame("Button",nil,row); row.del:SetSize(16,16); row.del:SetPoint("RIGHT",-4,0)
            local dx=row.del:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); dx:SetAllPoints(); dx:SetText("|cffff4444X|r")
            listEntries[idx]=row
        end
        row:SetPoint("TOPLEFT",0,-(idx-1)*22); row:SetPoint("RIGHT")
        row.text:SetText(type(key)=="number" and ("ID: "..key) or key); row.text:SetTextColor(0.9,0.7,0.2)
        local k=key
        row.del:SetScript("OnClick",function() if MissedKickDB then MissedKickDB.dangerousCasts[k]=nil end; RefreshDangerousList() end)
        row:Show()
    end
end

local function BuildSettings()
    settingsFrame=CreateFrame("Frame","MissedKickSettings",UIParent,"BackdropTemplate")
    settingsFrame:SetSize(360,400); settingsFrame:SetPoint("CENTER")
    settingsFrame:SetFrameStrata("DIALOG"); settingsFrame:SetMovable(true); settingsFrame:EnableMouse(true); settingsFrame:SetClampedToScreen(true)
    settingsFrame:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=2})
    settingsFrame:SetBackdropColor(0.06,0.06,0.1,0.95); settingsFrame:SetBackdropBorderColor(0.4,0.2,0.0,0.8)
    table.insert(UISpecialFrames,"MissedKickSettings")
    local sh=CreateFrame("Frame",nil,settingsFrame); sh:SetHeight(30); sh:SetPoint("TOPLEFT"); sh:SetPoint("TOPRIGHT")
    local shbg=sh:CreateTexture(nil,"BACKGROUND"); shbg:SetAllPoints(); shbg:SetColorTexture(0.1,0.08,0.14,1)
    sh:EnableMouse(true); sh:RegisterForDrag("LeftButton")
    sh:SetScript("OnDragStart",function() settingsFrame:StartMoving() end)
    sh:SetScript("OnDragStop",function() settingsFrame:StopMovingOrSizing() end)
    local stitle=sh:CreateFontString(nil,"OVERLAY","GameFontNormal"); stitle:SetPoint("LEFT",12,0)
    stitle:SetText("|cffff4444Missed|r |cffffcc00Kick|r |cff888888Settings|r")
    local scls=CreateFrame("Button",nil,sh); scls:SetSize(24,24); scls:SetPoint("RIGHT",-6,0)
    local scx=scls:CreateFontString(nil,"OVERLAY","GameFontNormal"); scx:SetAllPoints(); scx:SetText("|cffaa3333X|r")
    scls:SetScript("OnClick",function() settingsFrame:Hide() end)
    local tabs,panels={},{}
    local function SetTab(idx)
        for i,t in ipairs(tabs) do
            local s=(i==idx); t._bg:SetColorTexture(s and 0.2 or 0.1,s and 0.15 or 0.1,s and 0.3 or 0.15,1)
            t._lbl:SetTextColor(s and 1 or 0.6,s and 0.8 or 0.6,s and 0.2 or 0.6)
            if s then panels[i]:Show() else panels[i]:Hide() end
        end
    end
    for i,tn in ipairs({"General","Dangerous Casts"}) do
        local tab=CreateFrame("Button",nil,settingsFrame); tab:SetSize(120,24); tab:SetPoint("TOPLEFT",(i-1)*122+8,-34)
        tab._bg=tab:CreateTexture(nil,"BACKGROUND"); tab._bg:SetAllPoints()
        tab._lbl=tab:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); tab._lbl:SetAllPoints(); tab._lbl:SetText(tn)
        tab:SetScript("OnClick",function() SetTab(i) end); tabs[i]=tab
        local p=CreateFrame("Frame",nil,settingsFrame); p:SetPoint("TOPLEFT",8,-62); p:SetPoint("BOTTOMRIGHT",-8,8); p:Hide(); panels[i]=p
    end
    -- General tab
    local gp=panels[1]
    local ml=gp:CreateFontString(nil,"OVERLAY","GameFontNormal"); ml:SetPoint("TOPLEFT",0,0); ml:SetText("Your Raid Marker"); ml:SetTextColor(1,0.8,0.2)
    local md=gp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); md:SetPoint("TOPLEFT",0,-18)
    md:SetText("Dangerous casts on enemies with your marker\nwill be labeled YOUR KICK."); md:SetTextColor(0.6,0.6,0.6)
    local mklist={"none","star","circle","diamond","triangle","moon","square","cross","skull"}
    local mkbtns={}
    for i,mk in ipairs(mklist) do
        local btn=CreateFrame("Button",nil,gp); btn:SetSize(36,36)
        btn:SetPoint("TOPLEFT",((i-1)%5)*40,-52-math.floor((i-1)/5)*40)
        btn._bg=btn:CreateTexture(nil,"BACKGROUND"); btn._bg:SetAllPoints(); btn._bg:SetColorTexture(0.15,0.15,0.2,0.8)
        btn._mk=mk
        local midx=MissedKick.MARKER_NAMES[mk]
        if midx and midx>0 and MissedKick.MARKER_ICONS[midx] then
            local ic=btn:CreateTexture(nil,"ARTWORK"); ic:SetSize(24,24); ic:SetPoint("CENTER"); ic:SetTexture(MissedKick.MARKER_ICONS[midx])
        else local nl=btn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); nl:SetAllPoints(); nl:SetText("None"); nl:SetTextColor(0.5,0.5,0.5) end
        btn:SetScript("OnClick",function()
            if MissedKickDB then MissedKickDB.myMarker=mk end
            for _,b in ipairs(mkbtns) do b._bg:SetColorTexture(0.15,0.15,0.2,0.8) end
            btn._bg:SetColorTexture(0.3,0.5,0.3,0.8)
            MissedKick.Print("Marker set to |cffffcc00"..mk.."|r.")
        end)
        mkbtns[i]=btn
    end
    -- Dangerous casts tab
    local dp=CreateFrame("Frame",nil,panels[2]); dp:SetAllPoints(); settingsFrame._dp=dp
    local dl=dp:CreateFontString(nil,"OVERLAY","GameFontNormal"); dl:SetPoint("TOPLEFT",0,0); dl:SetText("Dangerous Cast List"); dl:SetTextColor(1,0.8,0.2)
    local dd=dp:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); dd:SetPoint("TOPLEFT",0,-18); dd:SetText("Enter a spell ID or name, then click Add."); dd:SetTextColor(0.6,0.6,0.6)
    local inp=CreateFrame("EditBox","MKDangerousInput",dp,"InputBoxTemplate"); inp:SetSize(200,22); inp:SetPoint("TOPLEFT",0,-38); inp:SetAutoFocus(false); inp:SetFontObject("GameFontNormalSmall")
    local ab=CreateFrame("Button",nil,dp); ab:SetSize(50,22); ab:SetPoint("LEFT",inp,"RIGHT",6,0)
    local abbg=ab:CreateTexture(nil,"BACKGROUND"); abbg:SetAllPoints(); abbg:SetColorTexture(0.2,0.4,0.2,0.8)
    local abl=ab:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); abl:SetAllPoints(); abl:SetText("Add")
    ab:SetScript("OnEnter",function() abbg:SetColorTexture(0.3,0.6,0.3,0.8) end)
    ab:SetScript("OnLeave",function() abbg:SetColorTexture(0.2,0.4,0.2,0.8) end)
    ab:SetScript("OnClick",function()
        local v=inp:GetText(); if not v or v=="" or not MissedKickDB then return end
        local num=tonumber(v)
        if num then MissedKickDB.dangerousCasts[num]=true; MissedKick.Print("Added ID |cffffcc00"..num.."|r")
        else MissedKickDB.dangerousCasts[v]=true; MissedKick.Print("Added |cffffcc00"..v.."|r") end
        inp:SetText(""); RefreshDangerousList()
    end)
    inp:SetScript("OnEnterPressed",function() ab:Click() end)
    settingsFrame:SetScript("OnShow",function()
        local cur=MissedKickDB and MissedKickDB.myMarker or "none"
        for _,b in ipairs(mkbtns) do b._bg:SetColorTexture(b._mk==cur and 0.3 or 0.15,b._mk==cur and 0.5 or 0.15,b._mk==cur and 0.3 or 0.2,0.8) end
        RefreshDangerousList()
    end)
    SetTab(1)
end

-- Public API
function MissedKick_ShowFrame()
    if not mainFrame then BuildMain() end
    if not castFrame then BuildCastFrame() end
    PositionMainFrame(false)
    mainFrame:Show(); mainFrame:Raise(); RefreshKicks(); MissedKick.ScanNearbyCasts(); RefreshCasts()
end
function MissedKick_HideFrame() if mainFrame then mainFrame:Hide() end end
function MissedKick_CenterFrame()
    if not mainFrame then BuildMain() end
    if not castFrame then BuildCastFrame() end
    PositionMainFrame(true)
    PositionCastFrame(true)
    mainFrame:Show(); mainFrame:Raise(); RefreshKicks(); RefreshCasts()
    if MissedKick and MissedKick.Print then MissedKick.Print("Tracker moved to center.") end
end
function MissedKick_UpdateLock() end
function MissedKick_RefreshCasts() RefreshCasts() end
function MissedKick_RefreshUI() if mainFrame and mainFrame:IsShown() then RefreshKicks() end; RefreshCasts() end
function MissedKick_ToggleSettings()
    if not settingsFrame then BuildSettings() end
    if settingsFrame:IsShown() then settingsFrame:Hide() else settingsFrame:Show() end
end

-- Auto-show on login
local _i=CreateFrame("Frame"); _i:RegisterEvent("PLAYER_ENTERING_WORLD")
_i:SetScript("OnEvent",function(self) self:UnregisterEvent("PLAYER_ENTERING_WORLD"); C_Timer.After(1,MissedKick_ShowFrame) end)
