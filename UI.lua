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

local CAST_TARGET_R, CAST_TARGET_G, CAST_TARGET_B, CAST_TARGET_A = 0.58, 0.17, 0.12, 0.9
local CAST_OTHER_R,  CAST_OTHER_G,  CAST_OTHER_B,  CAST_OTHER_A  = 0.58, 0.58, 0.62, 0.86
local CAST_OUTLINE_INSET = 2
local CAST_TEXT_NORMAL_R,    CAST_TEXT_NORMAL_G,    CAST_TEXT_NORMAL_B    = 0.92, 0.92, 0.92
local CAST_TEXT_IMPORTANT_R, CAST_TEXT_IMPORTANT_G, CAST_TEXT_IMPORTANT_B = 1.00, 0.84, 0.32
local CAST_SEP_NORMAL_R,     CAST_SEP_NORMAL_G,     CAST_SEP_NORMAL_B     = 0.68, 0.68, 0.68
local CAST_SEP_IMPORTANT_R,  CAST_SEP_IMPORTANT_G,  CAST_SEP_IMPORTANT_B  = 1.00, 0.72, 0.20

local MARKER_OUTLINE_TEXTURES = {
    [1] = "Interface\\AddOns\\MissedKick\\Textures\\MarkerOutline_1.png",
    [2] = "Interface\\AddOns\\MissedKick\\Textures\\MarkerOutline_2.png",
    [3] = "Interface\\AddOns\\MissedKick\\Textures\\MarkerOutline_3.png",
    [4] = "Interface\\AddOns\\MissedKick\\Textures\\MarkerOutline_4.png",
    [5] = "Interface\\AddOns\\MissedKick\\Textures\\MarkerOutline_5.png",
    [6] = "Interface\\AddOns\\MissedKick\\Textures\\MarkerOutline_6.png",
    [7] = "Interface\\AddOns\\MissedKick\\Textures\\MarkerOutline_7.png",
    [8] = "Interface\\AddOns\\MissedKick\\Textures\\MarkerOutline_8.png",
}

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

local function IsKickTrackerEnabled()
    local db = GetDB()
    return not db or db.kickTrackerEnabled ~= false
end

local function IsNearbyCastsEnabled()
    local db = GetDB()
    return not db or db.nearbyCastsEnabled ~= false
end

local function SetKickTrackerEnabled(enabled)
    local db = GetDB() or MissedKickDB or {}
    MissedKickDB = db
    db.kickTrackerEnabled = enabled and true or false
end

local function SetNearbyCastsEnabled(enabled)
    local db = GetDB() or MissedKickDB or {}
    MissedKickDB = db
    db.nearbyCastsEnabled = enabled and true or false
end

local function IsDungeonLoadMode()
    local db = GetDB()
    return db and db.onlyDungeons == true or false
end

local function SetDungeonLoadMode(enabled)
    local db = GetDB() or MissedKickDB or {}
    MissedKickDB = db
    db.onlyDungeons = enabled and true or false
end

local function IsInDungeonInstance()
    if IsInInstance then
        local ok, inInstance, instanceType = pcall(IsInInstance)
        return ok and inInstance and instanceType == "party" or false
    end
    return false
end

local function PassesLoadMode()
    if IsDungeonLoadMode() then
        return IsInDungeonInstance()
    end
    return true
end

local function IsKickTrackerVisibleByRules()
    return IsKickTrackerEnabled() and PassesLoadMode()
end

local function IsNearbyCastsVisibleByRules()
    return IsNearbyCastsEnabled() and PassesLoadMode()
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

local function SetCastFillBounds(row, inset)
    row.fill:ClearAllPoints()
    if inset and inset > 0 then
        row.fill:SetPoint("TOPLEFT", row, "TOPLEFT", inset, -inset)
        row.fill:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -inset, inset)
    else
        row.fill:SetAllPoints(row)
    end
end

local function GetCastRow(parent, i)
    if castRows[i] then return castRows[i] end
    local row = CreateFrame("Frame", nil, parent); row:SetHeight(BAR_HEIGHT)
    row.bg = row:CreateTexture(nil, "BACKGROUND"); row.bg:SetAllPoints(); row.bg:SetColorTexture(0.05,0.05,0.07,0.82)
    row.fill = CreateFrame("StatusBar", nil, row)
    SetCastFillBounds(row, 0)
    row.fill:SetMinMaxValues(0, 1)
    row.fill:SetValue(0)
    row.fill:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    if row.fill.SetOrientation then row.fill:SetOrientation("HORIZONTAL") end
    row.overlay = row.fill:CreateTexture(nil, "BORDER"); row.overlay:SetAllPoints(); row.overlay:SetColorTexture(0,0,0,0.18)
    row.textLayer = CreateFrame("Frame", nil, row)
    row.textLayer:SetAllPoints()
    row.textLayer:SetFrameLevel(row.fill:GetFrameLevel() + 2)
    row.marker = row.textLayer:CreateTexture(nil, "ARTWORK"); row.marker:SetSize(ICON_SZ,ICON_SZ); row.marker:SetPoint("RIGHT",-6,0); row.marker:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    row.prefix = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.enemy = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.sep = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.spell = row.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.prefix:SetJustifyH("LEFT"); row.enemy:SetJustifyH("LEFT"); row.sep:SetJustifyH("CENTER"); row.spell:SetJustifyH("LEFT")
    row.prefix:SetWordWrap(false); row.enemy:SetWordWrap(false); row.sep:SetWordWrap(false); row.spell:SetWordWrap(false)
    for _, fs in ipairs({ row.prefix, row.enemy, row.sep, row.spell }) do
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
    end
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
    row.outlineAtlas = row.textLayer:CreateTexture(nil, "OVERLAY")
    row.outlineAtlas:SetAllPoints(row)
    row.outlineAtlas:Hide()
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

local function SecretSafeIsNil(value)
    return not value
end

local function FirstPresentValue(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if not SecretSafeIsNil(value) then
            return value
        end
    end
    return nil
end

local function SetSpellTextFromRawID(fontString, spellID)
    if SecretSafeIsNil(spellID) or not (C_Spell and C_Spell.GetSpellName) then
        return false
    end

    return pcall(function()
        local spellName = C_Spell.GetSpellName(spellID)
        if spellName == nil then error("missing spell name") end
        fontString:SetText(spellName)
    end)
end

local function SetCastText(row, c, prefixText, r, g, b, sepR, sepG, sepB)
    SetFontTextSafe(row.prefix, prefixText or "", "")
    SetFontTextSafe(row.enemy, FirstPresentValue(c.enemyNameRaw, c.enemyName), c.enemyName or "Unknown Enemy")
    row.sep:SetText("-")
    if not (SetSpellTextFromRawID(row.spell, c.rawUnitSpellID) or SetSpellTextFromRawID(row.spell, c.rawEventSpellID)) then
        SetFontTextSafe(row.spell, FirstPresentValue(c.rawSpellName, c.spellNameRaw, c.spellName), c.spellName or "Unknown Spell")
    end

    row.prefix:SetTextColor(r, g, b)
    row.enemy:SetTextColor(r, g, b)
    row.sep:SetTextColor(sepR or CAST_SEP_NORMAL_R, sepG or CAST_SEP_NORMAL_G, sepB or CAST_SEP_NORMAL_B)
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

local function IsCastTargetingPlayerByName(c)
    if not (c and c.targetName) then return false end

    local myName = MissedKick and MissedKick.GetMyName and MissedKick.GetMyName() or UnitName("player")
    if not myName then return false end

    local ok, matches = pcall(function()
        if c.targetName == myName then return true end
        if Ambiguate then
            return Ambiguate(c.targetName, "none") == Ambiguate(myName, "none")
        end
        return false
    end)

    return ok and matches or false
end

local function IsCastTargetingPlayerByUnit(c)
    if not (c and c.unit and UnitIsUnit) then return false end

    local targetsPlayer = false
    local ok = pcall(function()
        if UnitIsUnit(c.unit .. "target", "player") then
            targetsPlayer = true
        end
    end)

    return ok and targetsPlayer or false
end

local function SetCastFillColorForTarget(row, c)
    if IsCastTargetingPlayerByName(c) or IsCastTargetingPlayerByUnit(c) then
        SetCastFillColor(row, CAST_TARGET_R, CAST_TARGET_G, CAST_TARGET_B, CAST_TARGET_A)
        return
    end

    if c and c.unit and PlayerIsSpellTarget and C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean then
        local okState, targetsPlayer = pcall(PlayerIsSpellTarget, c.unit, "player")
        if okState then
            local okColor = pcall(function()
                row.fill:SetStatusBarColor(
                    C_CurveUtil.EvaluateColorValueFromBoolean(targetsPlayer, CAST_TARGET_R, CAST_OTHER_R),
                    C_CurveUtil.EvaluateColorValueFromBoolean(targetsPlayer, CAST_TARGET_G, CAST_OTHER_G),
                    C_CurveUtil.EvaluateColorValueFromBoolean(targetsPlayer, CAST_TARGET_B, CAST_OTHER_B),
                    C_CurveUtil.EvaluateColorValueFromBoolean(targetsPlayer, CAST_TARGET_A, CAST_OTHER_A)
                )
            end)
            if okColor then return end
        end
    end

    SetCastFillColor(row, CAST_OTHER_R, CAST_OTHER_G, CAST_OTHER_B, CAST_OTHER_A)
end

local function IsSecretValue(value)
    if hasanysecretvalues then
        local okSecret, isSecret = pcall(hasanysecretvalues, value)
        return okSecret and isSecret or false
    end
    return false
end

local function CleanLocalNumber(value)
    if value == nil then return nil end
    if IsSecretValue(value) then return nil end

    local okType, valueType = pcall(type, value)
    if okType and valueType == "number" then
        local okIndex = pcall(function()
            local probe = { [value] = true }
            return probe[value]
        end)
        if okIndex then return value end
    end

    local okText, text = pcall(tostring, value)
    if okText and text and not IsSecretValue(text) then
        local okNumber, clean = pcall(tonumber, text)
        if okNumber and clean then return clean end
    end

    return nil
end

local function CleanLocalText(value)
    if value == nil then return nil end
    if IsSecretValue(value) then return nil end

    local okText, text = pcall(tostring, value)
    if not okText or not text or IsSecretValue(text) then return nil end

    local okTrim, cleanText = pcall(function()
        return text:gsub("^%s+", ""):gsub("%s+$", "")
    end)
    if not okTrim or not cleanText or IsSecretValue(cleanText) then return nil end

    text = cleanText
    if text == "" then return nil end
    return text
end

local function GetDisplayedSpellNameCandidate(row)
    if not (row and row.spell and row.spell.GetText) then return nil end

    local okText, text = pcall(row.spell.GetText, row.spell)
    if okText then return text end
    return nil
end

local function ApplySecretImportantPredicate(predicate, textR, textG, textB, sepR, sepG, sepB)
    if not (C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean) then
        return false, textR, textG, textB, sepR, sepG, sepB
    end

    local okColor, nextTextR, nextTextG, nextTextB, nextSepR, nextSepG, nextSepB = pcall(function()
        local importantSpell = predicate()
        return
            C_CurveUtil.EvaluateColorValueFromBoolean(importantSpell, CAST_TEXT_IMPORTANT_R, textR),
            C_CurveUtil.EvaluateColorValueFromBoolean(importantSpell, CAST_TEXT_IMPORTANT_G, textG),
            C_CurveUtil.EvaluateColorValueFromBoolean(importantSpell, CAST_TEXT_IMPORTANT_B, textB),
            C_CurveUtil.EvaluateColorValueFromBoolean(importantSpell, CAST_SEP_IMPORTANT_R, sepR),
            C_CurveUtil.EvaluateColorValueFromBoolean(importantSpell, CAST_SEP_IMPORTANT_G, sepG),
            C_CurveUtil.EvaluateColorValueFromBoolean(importantSpell, CAST_SEP_IMPORTANT_B, sepB)
    end)

    if okColor then
        return true, nextTextR, nextTextG, nextTextB, nextSepR, nextSepG, nextSepB
    end

    return false, textR, textG, textB, sepR, sepG, sepB
end

local function ApplyImportantSpellTextColor(row, c)
    if not (C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean) then
        return false, false
    end

    local textR, textG, textB = CAST_TEXT_NORMAL_R, CAST_TEXT_NORMAL_G, CAST_TEXT_NORMAL_B
    local sepR, sepG, sepB = CAST_SEP_NORMAL_R, CAST_SEP_NORMAL_G, CAST_SEP_NORMAL_B
    local attempted = false
    local importantAttempted = false
    local rawFields = { "rawEventSpellID", "rawUnitSpellID" }

    if C_Spell and C_Spell.IsSpellImportant then
        for _, field in ipairs(rawFields) do
            local rawSpellID = c[field]
            local okColor, nextTextR, nextTextG, nextTextB, nextSepR, nextSepG, nextSepB =
                ApplySecretImportantPredicate(function() return C_Spell.IsSpellImportant(rawSpellID) end, textR, textG, textB, sepR, sepG, sepB)
            if okColor then
                textR, textG, textB = nextTextR, nextTextG, nextTextB
                sepR, sepG, sepB = nextSepR, nextSepG, nextSepB
                attempted = true
                importantAttempted = true
            end
        end
    end

    if attempted then
        pcall(row.prefix.SetTextColor, row.prefix, textR, textG, textB)
        pcall(row.enemy.SetTextColor, row.enemy, textR, textG, textB)
        pcall(row.sep.SetTextColor, row.sep, sepR, sepG, sepB)
        pcall(row.spell.SetTextColor, row.spell, textR, textG, textB)
    end

    return attempted, importantAttempted
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

local function ClearCastOutline(row)
    SetCastOutlineAlpha(row, 0)
    if row.outlineAtlas then
        row.outlineAtlas:Hide()
    end
end

local function SetCastOutlineForMarker(row, assignedMarker, markerForRow, markerShown)
    ClearCastOutline(row)

    if not (assignedMarker and markerShown and row.outlineAtlas and SetRaidTargetIconTexture) then
        return false
    end

    local texturePath = MARKER_OUTLINE_TEXTURES[assignedMarker]
    if not texturePath then return false end

    row.outlineAtlas:SetTexture(texturePath)
    local ok = pcall(SetRaidTargetIconTexture, row.outlineAtlas, markerForRow)
    if not ok and row.outlineAtlas.SetSpriteSheetCell then
        ok = pcall(row.outlineAtlas.SetSpriteSheetCell, row.outlineAtlas, markerForRow,
            RAID_TARGET_TEXTURE_ROWS or 4, RAID_TARGET_TEXTURE_COLUMNS or 4)
    end

    if ok then
        row.outlineAtlas:Show()
        return true
    end

    row.outlineAtlas:Hide()
    return false
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
    if not IsNearbyCastsVisibleByRules() then
        if castFrame then
            castFrame:Hide()
            for i=1,#castRows do
                if castRows[i] then
                    castRows[i]._timerUnit=nil; castRows[i]._timerSpell=nil; castRows[i]:Hide()
                end
            end
        end
        return
    end
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
        local pct = 0
        if c.endTime and c.duration then
            local rem = math.max(0, c.endTime - now)
            local dur = math.max(0.1, c.duration)
            pct = 1 - (rem / dur)
        end
        local assignedMarker = GetAssignedMarkerIndex()
        local outlineAtlasApplied = SetCastOutlineForMarker(row, assignedMarker, markerForRow, markerShown)
        SetCastFillBounds(row, outlineAtlasApplied and CAST_OUTLINE_INSET or 0)
        SetCastFill(row, c, pct)
        local isImportant, importantReason = false, "blizzard-important"
        local prefixWidth = 0
        LayoutCastText(row, textLeft, prefixWidth)
        local textR, textG, textB = CAST_TEXT_NORMAL_R, CAST_TEXT_NORMAL_G, CAST_TEXT_NORMAL_B
        local sepR, sepG, sepB = CAST_SEP_NORMAL_R, CAST_SEP_NORMAL_G, CAST_SEP_NORMAL_B
        row.bg:SetColorTexture(0.08,0.08,0.1,0.72)
        SetCastText(row, c, "", textR, textG, textB, sepR, sepG, sepB)
        local secretImportantAttempted = false
        local importantFallbackAttempted = false
        secretImportantAttempted, importantFallbackAttempted = ApplyImportantSpellTextColor(row, c)
        isImportant = importantFallbackAttempted
        if MissedKick and MissedKick.IsDebugEnabled and MissedKick.IsDebugEnabled()
            and MissedKick.DebugPrint and now >= nextOutlineDebug then
            nextOutlineDebug = now + 1.5
            local db = GetDB()
            local assigned = db and db.myMarker or "none"
            local markerSecret = false
            local rawEventSecret = false
            local rawUnitSecret = false
            local rawNameSecret = false
            if hasanysecretvalues then
                local okSecret, isSecret = pcall(hasanysecretvalues, markerForRow)
                markerSecret = okSecret and isSecret or false
                local okRawEvent, isRawEventSecret = pcall(hasanysecretvalues, c.rawEventSpellID)
                rawEventSecret = okRawEvent and isRawEventSecret or false
                local okRawUnit, isRawUnitSecret = pcall(hasanysecretvalues, c.rawUnitSpellID)
                rawUnitSecret = okRawUnit and isRawUnitSecret or false
                local okRawName, isRawNameSecret = pcall(hasanysecretvalues, c.rawSpellName)
                rawNameSecret = okRawName and isRawNameSecret or false
            end
            local displayedSpellName = CleanLocalText(GetDisplayedSpellNameCandidate(row)) or CleanLocalText(c.spellName) or CleanLocalText(c.spellNameRaw)
            local cleanTextureDebug = CleanLocalNumber(c.cleanSpellTexture) or CleanLocalNumber(c.rawSpellTexture)
            MissedKick.DebugPrint("outline assigned=" .. tostring(assigned)
                .. " markerShown=" .. tostring(markerShown)
                .. " markerSecret=" .. tostring(markerSecret)
                .. " atlasApplied=" .. tostring(outlineAtlasApplied)
                .. " important=" .. tostring(isImportant)
                .. " reason=" .. tostring(importantReason)
                .. " secretAttempt=" .. tostring(secretImportantAttempted)
                .. " importantAttempt=" .. tostring(importantFallbackAttempted)
                .. " spellName=" .. tostring(displayedSpellName)
                .. " spellID=" .. tostring(c.cleanSpellID or c.spellID)
                .. " eventSpellID=" .. tostring(c.eventSpellID)
                .. " combatLogSpellID=" .. tostring(c.combatLogSpellID)
                .. " texture=" .. tostring(cleanTextureDebug)
                .. " rawEventSecret=" .. tostring(rawEventSecret)
                .. " rawUnitSecret=" .. tostring(rawUnitSecret)
                .. " rawNameSecret=" .. tostring(rawNameSecret)
                .. " mode=raw-spell-match")
        end
        SetCastFillColorForTarget(row, c)
        row.time:SetText("")
        y=y+BAR_HEIGHT
    end
    for i=#casts+1,#castRows do if castRows[i] then castRows[i]._timerUnit=nil; castRows[i]._timerSpell=nil; castRows[i].prefix:Hide(); castRows[i].enemy:Hide(); castRows[i].sep:Hide(); castRows[i].spell:Hide(); ClearCastOutline(castRows[i]); castRows[i]:Hide() end end
    castFrame:SetHeight(math.max(y+4, HEADER_H+30))
end

local function ApplyFeatureVisibility()
    if mainFrame then
        if IsKickTrackerVisibleByRules() then
            mainFrame:Show()
            mainFrame:Raise()
            RefreshKicks()
        else
            mainFrame:Hide()
        end
    end

    if IsNearbyCastsVisibleByRules() then
        if MissedKick and MissedKick.ScanNearbyCasts then
            MissedKick.ScanNearbyCasts()
        end
        RefreshCasts()
    elseif castFrame then
        castFrame:Hide()
    end
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
        if not self:IsShown() then
            self._refreshTimer = 0
            return
        end
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
local function BuildSettings()
    settingsFrame=CreateFrame("Frame","MissedKickSettings",UIParent,"BackdropTemplate")
    settingsFrame:SetSize(440,320); settingsFrame:SetPoint("CENTER")
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

    local content=CreateFrame("Frame",nil,settingsFrame)
    content:SetPoint("TOPLEFT",12,-44); content:SetPoint("BOTTOMRIGHT",-12,12)
    settingsFrame._dp=content

    local function CreateDivider(parent, y)
        local line=parent:CreateTexture(nil,"BACKGROUND")
        line:SetPoint("TOPLEFT",0,y); line:SetPoint("TOPRIGHT",0,y); line:SetHeight(1)
        line:SetColorTexture(0.22,0.18,0.10,0.85)
        return line
    end

    local toggles = {}
    local function TrackToggle(btn)
        toggles[#toggles + 1] = btn
        return btn
    end

    local function CreateFeatureToggle(parent, getValue, setValue, width, onText, offText)
        local btn=CreateFrame("Button",nil,parent,"BackdropTemplate")
        btn:SetSize(width or 78,24)
        btn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
        btn:SetBackdropBorderColor(0.25,0.25,0.32,1)
        local label=btn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        label:SetAllPoints()
        btn.Refresh=function(self)
            local on=getValue()
            self:SetBackdropColor(on and 0.12 or 0.14,on and 0.34 or 0.10,on and 0.16 or 0.10,0.9)
            label:SetText(on and (onText or "On") or (offText or "Off"))
            label:SetTextColor(on and 0.7 or 0.85,on and 1 or 0.35,on and 0.7 or 0.35)
        end
        btn:SetScript("OnClick",function(self)
            setValue(not getValue())
            self:Refresh()
            ApplyFeatureVisibility()
        end)
        btn:SetScript("OnEnter",function(self) self:SetBackdropBorderColor(0.7,0.55,0.2,1) end)
        btn:SetScript("OnLeave",function(self) self:SetBackdropBorderColor(0.25,0.25,0.32,1) end)
        btn:Refresh()
        return TrackToggle(btn)
    end

    local function CreateText(parent, text, x, y, template, r, g, b)
        local fs=parent:CreateFontString(nil,"OVERLAY",template or "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT",x,y)
        fs:SetText(text)
        if r then fs:SetTextColor(r,g,b) end
        return fs
    end

    CreateText(content,"|cffffcc00Load Mode|r",0,0,"GameFontNormal")
    local loadModeToggle=CreateFeatureToggle(content,IsDungeonLoadMode,SetDungeonLoadMode,118,"Dungeons","Everywhere")
    loadModeToggle:SetPoint("TOPRIGHT",0,4)

    CreateDivider(content,-46)

    local kickTitle=content:CreateFontString(nil,"OVERLAY","GameFontNormal")
    kickTitle:SetPoint("TOPLEFT",0,-68); kickTitle:SetText("|cffffcc00Kick Tracker|r")
    local kickToggle=CreateFeatureToggle(content,IsKickTrackerEnabled,SetKickTrackerEnabled)
    kickToggle:SetPoint("TOPRIGHT",0,-64)

    local markerLabel=content:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    markerLabel:SetPoint("TOPLEFT",0,-96); markerLabel:SetText("Assigned Raid Marker"); markerLabel:SetTextColor(0.8,0.8,0.8)
    local mklist={"none","star","circle","diamond","triangle","moon","square","cross","skull"}
    local mkbtns={}
    for i,mk in ipairs(mklist) do
        local btn=CreateFrame("Button",nil,content); btn:SetSize(34,34)
        btn:SetPoint("TOPLEFT",((i-1)%9)*40,-118)
        btn._bg=btn:CreateTexture(nil,"BACKGROUND"); btn._bg:SetAllPoints(); btn._bg:SetColorTexture(0.15,0.15,0.2,0.8)
        btn._mk=mk
        local midx=MissedKick.MARKER_NAMES[mk]
        if midx and midx>0 and MissedKick.MARKER_ICONS[midx] then
            local ic=btn:CreateTexture(nil,"ARTWORK"); ic:SetSize(23,23); ic:SetPoint("CENTER"); ic:SetTexture(MissedKick.MARKER_ICONS[midx])
        else
            local nl=btn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); nl:SetAllPoints(); nl:SetText("None"); nl:SetTextColor(0.5,0.5,0.5)
        end
        btn:SetScript("OnClick",function()
            if MissedKickDB then MissedKickDB.myMarker=mk end
            for _,b in ipairs(mkbtns) do b._bg:SetColorTexture(0.15,0.15,0.2,0.8) end
            btn._bg:SetColorTexture(0.3,0.5,0.3,0.8)
            MissedKick.Print("Marker set to |cffffcc00"..mk.."|r.")
            if MissedKick_RefreshUI then MissedKick_RefreshUI() end
        end)
        mkbtns[i]=btn
    end

    CreateDivider(content,-168)

    local nearbyTitle=content:CreateFontString(nil,"OVERLAY","GameFontNormal")
    nearbyTitle:SetPoint("TOPLEFT",0,-190); nearbyTitle:SetText("|cffffcc00Nearby Casts|r")
    local nearbyToggle=CreateFeatureToggle(content,IsNearbyCastsEnabled,SetNearbyCastsEnabled)
    nearbyToggle:SetPoint("TOPRIGHT",0,-186)

    settingsFrame:SetScript("OnShow",function()
        local cur=MissedKickDB and MissedKickDB.myMarker or "none"
        for _,b in ipairs(mkbtns) do b._bg:SetColorTexture(b._mk==cur and 0.3 or 0.15,b._mk==cur and 0.5 or 0.15,b._mk==cur and 0.3 or 0.2,0.8) end
        for _,toggle in ipairs(toggles) do
            if toggle.Refresh then toggle:Refresh() end
        end
    end)
    settingsFrame:Hide()
end

-- Public API
function MissedKick_ShowFrame()
    if not mainFrame then BuildMain() end
    if not castFrame then BuildCastFrame() end
    PositionMainFrame(false)
    if IsKickTrackerVisibleByRules() then
        mainFrame:Show(); mainFrame:Raise(); RefreshKicks()
    else
        mainFrame:Hide()
    end
    MissedKick.ScanNearbyCasts(); RefreshCasts()
end
function MissedKick_HideFrame() if mainFrame then mainFrame:Hide() end; if castFrame then castFrame:Hide() end end
function MissedKick_CenterFrame()
    if not mainFrame then BuildMain() end
    if not castFrame then BuildCastFrame() end
    PositionMainFrame(true)
    PositionCastFrame(true)
    if IsKickTrackerVisibleByRules() then mainFrame:Show(); mainFrame:Raise(); RefreshKicks() else mainFrame:Hide() end
    RefreshCasts()
    if MissedKick and MissedKick.Print then MissedKick.Print("Tracker moved to center.") end
end
function MissedKick_UpdateLock() end
function MissedKick_RefreshCasts() RefreshCasts() end
function MissedKick_RefreshUI() ApplyFeatureVisibility() end
function MissedKick_ToggleSettings()
    if not settingsFrame then
        BuildSettings()
        settingsFrame:Show()
        return
    end
    if settingsFrame:IsShown() then settingsFrame:Hide() else settingsFrame:Show() end
end

-- Auto-show on login
local _i=CreateFrame("Frame"); _i:RegisterEvent("PLAYER_ENTERING_WORLD")
_i:SetScript("OnEvent",function(self) self:UnregisterEvent("PLAYER_ENTERING_WORLD"); C_Timer.After(1,MissedKick_ShowFrame) end)
