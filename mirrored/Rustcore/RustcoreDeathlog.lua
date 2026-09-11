-- Rustcore: death log window listing other players' deaths (fed by RustcoreBroadcast).

RustcoreDeathlog = {}

local deathlogFrame
local initialized = false
local sessionTracker

local BODY_FONT_PATH = Rustcore.GetAssetPath("Font/BPpong.otf")
local DEFAULT_WIDTH, DEFAULT_HEIGHT = 340, 140
local MIN_WIDTH, MIN_HEIGHT = 160, 90
local MAX_WIDTH, MAX_HEIGHT = 560, 480
local BACKGROUND_ALPHA = 0.78
local BORDER_SIZE = 18
local TITLE_Y = -8
local HEADER_Y = -24
local HEADER_ROW_HEIGHT = 14
local LIST_TOP_Y = -38
local BASE_ROW_HEIGHT = 16
local DEFAULT_FONT_SIZE = 11
local MIN_FONT_SIZE = 9
local MAX_FONT_SIZE = 16
local ROW_ICON_SIZE = 13
local ROW_LEFT_PAD = 3
local ROW_RIGHT_PAD = 0
local COL_LEVEL_WIDTH = 20
local COL_COUNT_WIDTH = 26
local COL_LOST_WIDTH = 18
local COL_NAME_MIN_WIDTH = 22
local COL_SOURCE_MIN_WIDTH = 26
local COL_TEXT_HARD_MIN_WIDTH = 14
local COL_NAME_MAX_WIDTH = MAX_WIDTH
local COL_SOURCE_MAX_WIDTH = MAX_WIDTH
local COL_GAP = 3
local MAX_COL_GAP = 15
local MAX_ENTRIES = 50
local SESSION_TIMEOUT = 5 * 60
local RESIZE_TOOLTIP = "Left click and drag to adjust."

local function Clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function GetFontSize()
    return Clamp(tonumber(Rustcore.GetSetting("deathlogFontSize")) or DEFAULT_FONT_SIZE, MIN_FONT_SIZE, MAX_FONT_SIZE)
end

local function GetRowHeight()
    return math.max(BASE_ROW_HEIGHT, GetFontSize() + 5)
end

local function GetRowIconSize()
    return ROW_ICON_SIZE + math.max(0, GetFontSize() - 11)
end

local function GetCountColumnWidth()
    return COL_COUNT_WIDTH + (math.max(0, GetFontSize() - 13) * 2)
end

local function GetLostColumnWidth()
    return COL_LOST_WIDTH + (math.max(0, GetFontSize() - 13) * 2)
end

local function ClassColorCode(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return "|cffffffff" end
    return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

local function ClassDisplayName(class, gender)
    if not class then return nil end
    local names = (gender == "Female") and LOCALIZED_CLASS_NAMES_FEMALE or LOCALIZED_CLASS_NAMES_MALE
    return (names and names[class]) or class
end

local function EnsureDB()
    RustcoreDB.deathlog = RustcoreDB.deathlog or {}
    return RustcoreDB.deathlog
end

local function TouchSession()
    if time then RustcoreDB.deathlogLastActive = time() end
end

local function StartSession()
    local now = time and time() or 0
    local lastActive = tonumber(RustcoreDB.deathlogLastActive)
    if not lastActive or now <= 0 or (now - lastActive) > SESSION_TIMEOUT then
        RustcoreDB.deathlog = {}
    end
    RustcoreDB.deathlogLastActive = now
end

function RustcoreDeathlog.AddEntry(d)
    if not d or not d.name then return end
    local entries = EnsureDB()
    table.insert(entries, 1, {
        name = d.name,
        class = d.class,
        level = d.level,
        source = d.source,
        zone = d.zone,
        race = d.race,
        gender = d.gender,
        link = (d.link and d.link ~= "") and d.link or nil,
        count = tonumber(d.count) or 0,
    })
    while #entries > MAX_ENTRIES do
        table.remove(entries)
    end
    RustcoreDeathlog.RefreshRows()
end

local function SavePosition(frame)
    local point, _, relativePoint, x, y = frame:GetPoint()
    Rustcore.SetProfileValue("deathlogWindowPoint", {
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y,
    })
end

local function ApplySavedPosition(frame)
    frame:ClearAllPoints()
    local pos = Rustcore.GetProfileValue("deathlogWindowPoint")
    if pos and pos.point and pos.relativePoint and pos.x and pos.y then
        frame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
    end
end

local function SaveSize(frame)
    local width, height = frame:GetSize()
    Rustcore.SetProfileValue("deathlogWindowSize", {
        width = width,
        height = height,
    })
end

local function ApplySavedSize(frame)
    local size = Rustcore.GetProfileValue("deathlogWindowSize")
    local width = size and tonumber(size.width) or DEFAULT_WIDTH
    local height = size and tonumber(size.height) or DEFAULT_HEIGHT
    frame:SetSize(
        Clamp(width, MIN_WIDTH, MAX_WIDTH),
        Clamp(height, MIN_HEIGHT, MAX_HEIGHT)
    )
end

local function ApplyBodyFont(fontString, size)
    if fontString then
        fontString:SetFont(BODY_FONT_PATH, size or 11, "")
    end
end

local function GetVisibleEntries()
    local entries = EnsureDB()
    local minLevel = tonumber(Rustcore.GetSetting("deathlogMinLevel")) or 0
    local minQuality = tonumber(Rustcore.GetSetting("deathlogMinQuality")) or 0
    if minLevel <= 0 and minQuality <= 0 then return entries end
    local filtered = {}
    for _, entry in ipairs(entries) do
        if (entry.level or 0) >= minLevel
            and Rustcore.DeathPassesQualityFilter(entry) then
            table.insert(filtered, entry)
        end
    end
    return filtered
end

-- Headers and rows use the same calculated column map, so optional fields
-- collapse without leaving gaps and resizing keeps every column aligned.
local function CreateColumnText(parent, isHeader)
    local text = parent:CreateFontString(nil, "OVERLAY")
    text:SetJustifyH("LEFT")
    text:SetJustifyV("MIDDLE")
    text:SetWordWrap(false)
    text:SetShadowColor(0, 0, 0, 1)
    text:SetShadowOffset(1, -1)
    ApplyBodyFont(text, isHeader and math.max(9, GetFontSize() - 2) or GetFontSize())
    return text
end

local function MeasureText(text, isHeader)
    local measureField = deathlogFrame and (isHeader and deathlogFrame.headerMeasureText or deathlogFrame.measureText)
    if not measureField then
        return #(tostring(text or "")) * 6
    end
    measureField:SetText(tostring(text or ""))
    return measureField:GetStringWidth() or 0
end

local function SplitCharacters(text)
    local chars = {}
    local index = 1
    while index <= #text do
        local first = text:byte(index)
        local length = 1
        if first and first >= 240 then
            length = 4
        elseif first and first >= 224 then
            length = 3
        elseif first and first >= 192 then
            length = 2
        end
        chars[#chars + 1] = text:sub(index, index + length - 1)
        index = index + length
    end
    return chars
end

local function FitText(text, maxWidth)
    text = tostring(text or "")
    if MeasureText(text) <= maxWidth then return text, false end

    local chars = SplitCharacters(text)
    local low, high = 0, #chars
    while low < high do
        local middle = math.ceil((low + high) / 2)
        local candidate = table.concat(chars, "", 1, middle) .. "..."
        if MeasureText(candidate) <= maxWidth then
            low = middle
        else
            high = middle - 1
        end
    end
    return table.concat(chars, "", 1, low) .. "...", true
end

local function CreateTextTooltipHitbox(parent)
    local hitbox = CreateFrame("Button", nil, parent)
    hitbox:SetFrameLevel(parent:GetFrameLevel() + 20)
    hitbox:EnableMouse(true)
    hitbox:SetScript("OnEnter", function(self)
        if not self.tooltipTitle then return end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR", 0, -24)
        GameTooltip:SetText(self.tooltipTitle, 1, 1, 1, 1, true)
        if self.tooltipLine then
            GameTooltip:AddLine(self.tooltipLine, 0.75, 0.75, 0.75, true)
        end
        GameTooltip:Show()
    end)
    hitbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return hitbox
end

local function BuildColumnLayout(width, entries)
    local visible = {
        level = Rustcore.GetSetting("showDeathlogLevel"),
        name = true,
        source = Rustcore.GetSetting("showDeathlogSource"),
        count = Rustcore.GetSetting("showDeathlogCount"),
        lost = Rustcore.GetSetting("showDeathlogItem"),
    }
    local order = {}
    for _, key in ipairs({ "level", "name", "source", "count", "lost" }) do
        if visible[key] then order[#order + 1] = key end
    end

    local nameWidth = MeasureText("Name") + 5
    local sourceWidth = MeasureText("Source") + 5
    for _, entry in ipairs(entries) do
        nameWidth = math.max(nameWidth, MeasureText(entry.name or "") + 5)
        local source = (entry.source and entry.source ~= "") and entry.source or "Unknown"
        sourceWidth = math.max(sourceWidth, MeasureText(source) + 5)
    end
    nameWidth = Clamp(nameWidth, COL_NAME_MIN_WIDTH, COL_NAME_MAX_WIDTH)
    sourceWidth = Clamp(sourceWidth, COL_SOURCE_MIN_WIDTH, COL_SOURCE_MAX_WIDTH)

    local widths = {
        level = COL_LEVEL_WIDTH,
        name = nameWidth,
        source = sourceWidth,
        count = GetCountColumnWidth(),
        lost = GetLostColumnWidth(),
    }
    local fixedWidth = 0
    for _, key in ipairs(order) do
        if key ~= "name" and key ~= "source" then fixedWidth = fixedWidth + widths[key] end
    end
    local flexibleKeys = { "name" }
    if visible.source then flexibleKeys[#flexibleKeys + 1] = "source" end
    local gapCount = math.max(0, #order - 1)
    local available = math.max(0, width - ROW_LEFT_PAD - ROW_RIGHT_PAD - (gapCount * COL_GAP) - fixedWidth)
    local flexibleTotal = 0
    for _, key in ipairs(flexibleKeys) do flexibleTotal = flexibleTotal + widths[key] end

    local excess = math.max(0, flexibleTotal - available)
    local function ShrinkToMinimum(minimums)
        while excess > 0 do
            local widest
            for _, key in ipairs(flexibleKeys) do
                if widths[key] > minimums[key] and (not widest or widths[key] > widths[widest]) then
                    widest = key
                end
            end
            if not widest then return end
            widths[widest] = widths[widest] - 1
            excess = excess - 1
        end
    end
    -- Never shrink a column below its own header label's rendered width
    -- unless the hard-minimum tier below is truly unavoidable - a compressed
    -- header reads worse than a slightly wider column.
    local nameHeaderMin = math.max(COL_NAME_MIN_WIDTH, MeasureText("Name", true) + 6)
    local sourceHeaderMin = math.max(COL_SOURCE_MIN_WIDTH, MeasureText("Source", true) + 6)
    ShrinkToMinimum({ name = nameHeaderMin, source = sourceHeaderMin })
    ShrinkToMinimum({ name = COL_TEXT_HARD_MIN_WIDTH, source = COL_TEXT_HARD_MIN_WIDTH })

    local resizedFlexibleTotal = 0
    for _, key in ipairs(flexibleKeys) do resizedFlexibleTotal = resizedFlexibleTotal + widths[key] end
    local remaining = math.max(0, available - resizedFlexibleTotal)
    local gap = COL_GAP
    if remaining > 0 and gapCount > 0 then
        local gapIncrease = math.min(MAX_COL_GAP - COL_GAP, remaining / gapCount)
        gap = gap + gapIncrease
        remaining = remaining - (gapIncrease * gapCount)
    end
    if remaining > 0 then
        local widthIncrease = remaining / #flexibleKeys
        for _, key in ipairs(flexibleKeys) do widths[key] = widths[key] + widthIncrease end
    end

    local layout = {}
    local x = ROW_LEFT_PAD
    for _, key in ipairs(order) do
        layout[key] = { x = x, width = widths[key] }
        x = x + widths[key] + gap
    end
    return layout
end

local function PositionRegion(region, parent, column)
    region:ClearAllPoints()
    region:SetPoint("LEFT", parent, "LEFT", column.x, 0)
    region:SetWidth(column.width)
end

local function SetTextCell(textRegion, hitbox, parent, column, fullText, colorCode)
    PositionRegion(textRegion, parent, column)
    local displayText = FitText(fullText, math.max(1, column.width - 2))
    textRegion:SetText(colorCode and (colorCode .. displayText .. "|r") or displayText)
    textRegion:Show()

    if hitbox then
        hitbox:ClearAllPoints()
        hitbox:SetPoint("LEFT", parent, "LEFT", column.x, 0)
        hitbox:SetSize(column.width, GetRowHeight())
        hitbox:Show()
    end
end

local function ApplyHeaderLayout(headerRow, layout)
    for key, text in pairs(headerRow.columns) do
        local column = layout[key]
        if column then
            PositionRegion(text, headerRow, column)
            text:Show()
        else
            text:Hide()
        end
    end
end

local function PopulateRow(row, entry, layout, rowIndex)
    if layout.level then
        SetTextCell(row.levelText, nil, row, layout.level, tostring(entry.level or "?"))
    else
        row.levelText:Hide()
    end

    SetTextCell(row.nameText, row.nameHitbox, row, layout.name, entry.name or "Unknown", ClassColorCode(entry.class))
    do
        local descBits = {}
        if entry.race and entry.race ~= "" then descBits[#descBits + 1] = entry.race end
        local classText = ClassDisplayName(entry.class, entry.gender)
        if classText then descBits[#descBits + 1] = classText end
        row.nameHitbox.tooltipTitle = entry.name or "Unknown"
        row.nameHitbox.tooltipLine = (#descBits > 0) and table.concat(descBits, " ") or nil
    end

    if layout.source then
        local source = (entry.source and entry.source ~= "" and entry.source ~= "Unknown") and entry.source or "Unknown"
        SetTextCell(row.sourceText, row.sourceHitbox, row, layout.source, source)
        row.sourceHitbox.tooltipTitle = source
        row.sourceHitbox.tooltipLine = (entry.zone and entry.zone ~= "") and entry.zone or nil
    else
        row.sourceText:Hide()
        row.sourceHitbox:Hide()
    end

    if layout.count then
        SetTextCell(row.countText, nil, row, layout.count, tostring(tonumber(entry.count) or 0))
    else
        row.countText:Hide()
    end

    if layout.lost and entry.link then
        local iconSize = GetRowIconSize()
        row.icon:ClearAllPoints()
        row.icon:SetSize(iconSize, iconSize)
        row.icon:SetPoint("LEFT", row, "LEFT", layout.lost.x, 0)
        row.icon:SetTexture(GetItemIcon(entry.link))
        row.icon:Show()
        row.itemHitbox:Show()
        row.itemHitbox.link = entry.link
    else
        row.icon:Hide()
        row.itemHitbox:Hide()
        row.itemHitbox.link = nil
    end

    if rowIndex % 2 == 0 then row.stripe:Show() else row.stripe:Hide() end
    row:Show()
end

local function ReflowRows(content, width, entries, layout)
    content.rows = content.rows or {}
    local rows = content.rows
    local rowHeight = GetRowHeight()

    for i, entry in ipairs(entries) do
        local row = rows[i]
        if not row then
            row = CreateFrame("Frame", nil, content)

            row.stripe = row:CreateTexture(nil, "BACKGROUND")
            row.stripe:SetAllPoints(row)
            row.stripe:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
            row.stripe:SetVertexColor(0.65, 0.65, 0.65, 0.07)

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(ROW_ICON_SIZE, ROW_ICON_SIZE)
            row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

            row.itemHitbox = CreateFrame("Frame", nil, row)
            row.itemHitbox:SetAllPoints(row.icon)
            row.itemHitbox:SetFrameLevel(row:GetFrameLevel() + 5)
            row.itemHitbox:EnableMouse(true)
            row.itemHitbox:SetScript("OnEnter", function(self)
                if not self.link then return end
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR", 0, -32)
                GameTooltip:SetHyperlink(self.link)
                GameTooltip:Show()
            end)
            row.itemHitbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

            row.levelText = CreateColumnText(row, false)
            row.nameText = CreateColumnText(row, false)
            row.sourceText = CreateColumnText(row, false)
            row.countText = CreateColumnText(row, false)
            row.nameHitbox = CreateTextTooltipHitbox(row)
            row.sourceHitbox = CreateTextTooltipHitbox(row)

            rows[i] = row
        end

        row:SetHeight(rowHeight)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * rowHeight)
        row:SetWidth(width)
        PopulateRow(row, entry, layout, i)
    end

    for i = #entries + 1, #rows do
        rows[i]:Hide()
    end

    content:SetHeight(math.max(1, #entries * rowHeight))
end

function RustcoreDeathlog.RefreshRows()
    if not deathlogFrame then return end
    local content = deathlogFrame.scrollContent
    local width = deathlogFrame.scrollFrame:GetWidth()
    if not width or width <= 0 then return end
    content:SetWidth(width)
    local entries = GetVisibleEntries()
    local layout = BuildColumnLayout(width, entries)
    ApplyHeaderLayout(deathlogFrame.headerRow, layout)
    ReflowRows(content, width, entries, layout)
end

local function BuildDeathlogFrame()
    local f = CreateFrame("Frame", "RustcoreDeathlogFrame", UIParent)
    ApplySavedSize(f)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    if f.SetResizable then f:SetResizable(true) end
    f:EnableMouse(true)
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
    elseif f.SetMinResize and f.SetMaxResize then
        f:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
        f:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
    end

    local opacity = Rustcore.GetSetting("deathlogBackgroundOpacity") or BACKGROUND_ALPHA
    local shadowOpacity = Rustcore.GetSetting("deathlogBackgroundShadow") or BACKGROUND_ALPHA
    local panelArt = RustcoreTheme.CreateRivetPanelArt(f, opacity, shadowOpacity, BORDER_SIZE)
    f.background = panelArt.center
    f.backgroundPieces = panelArt.pieces
    f.backgroundShadowPieces = panelArt.shadowPieces
    f.shade = panelArt.shade

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            RustcoreOptions.Toggle()
        end
    end)

    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetPoint("TOP", f, "TOP", 0, TITLE_Y)
    title:SetJustifyH("CENTER")
    title:SetTextColor(1, 0.82, 0)
    title:SetShadowColor(0, 0, 0, 1)
    title:SetShadowOffset(1, -1)
    title:SetFont(BODY_FONT_PATH, 13, "")
    title:SetText("Deathlog")
    f.title = title

    local measureText = f:CreateFontString(nil, "OVERLAY")
    measureText:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -100)
    measureText:SetAlpha(0)
    measureText:SetWordWrap(false)
    ApplyBodyFont(measureText, GetFontSize())
    f.measureText = measureText

    local headerMeasureText = f:CreateFontString(nil, "OVERLAY")
    headerMeasureText:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -120)
    headerMeasureText:SetAlpha(0)
    headerMeasureText:SetWordWrap(false)
    ApplyBodyFont(headerMeasureText, math.max(9, GetFontSize() - 2))
    f.headerMeasureText = headerMeasureText

    local headerRow = CreateFrame("Frame", nil, f)
    headerRow:SetPoint("TOPLEFT", f, "TOPLEFT", BORDER_SIZE, HEADER_Y)
    headerRow:SetPoint("TOPRIGHT", f, "TOPRIGHT", -BORDER_SIZE, HEADER_Y)
    headerRow:SetHeight(HEADER_ROW_HEIGHT)
    local hLevel = CreateColumnText(headerRow, true)
    local hName = CreateColumnText(headerRow, true)
    local hSource = CreateColumnText(headerRow, true)
    local hCount = CreateColumnText(headerRow, true)
    local hItem = CreateColumnText(headerRow, true)
    hLevel:SetText("Lvl")
    hName:SetText("Name")
    hSource:SetText("Source")
    hCount:SetText("Items")
    hItem:SetText("Lost")
    hLevel:SetTextColor(0.75, 0.75, 0.75)
    hName:SetTextColor(0.75, 0.75, 0.75)
    hSource:SetTextColor(0.75, 0.75, 0.75)
    hCount:SetTextColor(0.75, 0.75, 0.75)
    hItem:SetTextColor(0.75, 0.75, 0.75)
    headerRow.columns = {
        level = hLevel,
        name = hName,
        source = hSource,
        count = hCount,
        lost = hItem,
    }

    f.headerRow = headerRow

    local scrollFrame = CreateFrame("ScrollFrame", "RustcoreDeathlogScrollFrame", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", BORDER_SIZE, LIST_TOP_Y)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -BORDER_SIZE, BORDER_SIZE)
    f.scrollFrame = scrollFrame

    local scrollBar = scrollFrame.ScrollBar or _G["RustcoreDeathlogScrollFrameScrollBar"]
    if scrollBar then
        scrollBar:Hide()
        scrollBar:EnableMouse(false)
        scrollBar:HookScript("OnShow", function(self) self:Hide() end)
    end

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 1)
    scrollFrame:SetScrollChild(content)
    f.scrollContent = content

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local newValue = Clamp(self:GetVerticalScroll() - (delta * GetRowHeight() * 2), 0, math.max(0, content:GetHeight() - self:GetHeight()))
        self:SetVerticalScroll(newValue)
    end)

    f:SetScript("OnSizeChanged", function()
        RustcoreDeathlog.RefreshRows()
    end)

    local resizeGrip = CreateFrame("Button", nil, f)
    resizeGrip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetFrameLevel(f:GetFrameLevel() + 4)
    resizeGrip:RegisterForClicks("LeftButtonDown", "RightButtonUp")
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeGrip:Hide()
    resizeGrip:SetScript("OnEnter", function(self)
        self:Show()
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR", 0, -32)
        GameTooltip:SetText(RESIZE_TOOLTIP, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    resizeGrip:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self.resizing = true
        self:Show()
        f:StartSizing("BOTTOMRIGHT")
    end)
    resizeGrip:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        self.resizing = false
        f:StopMovingOrSizing()
        SaveSize(f)
        RustcoreDeathlog.RefreshRows()
        if not self.IsMouseOver or not self:IsMouseOver() then self:Hide() end
    end)
    resizeGrip:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if not self.resizing then self:Hide() end
    end)

    local resizeHotspot = CreateFrame("Frame", nil, f)
    resizeHotspot:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    resizeHotspot:SetSize(24, 24)
    resizeHotspot:SetFrameLevel(f:GetFrameLevel() + 3)
    resizeHotspot:EnableMouse(true)
    resizeHotspot:SetScript("OnEnter", function(self)
        resizeGrip:Show()
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR", 0, -32)
        GameTooltip:SetText(RESIZE_TOOLTIP, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    resizeHotspot:SetScript("OnLeave", function()
        GameTooltip:Hide()
        C_Timer.After(0, function()
            if not resizeGrip.resizing and (not resizeGrip.IsMouseOver or not resizeGrip:IsMouseOver()) then
                resizeGrip:Hide()
            end
        end)
    end)
    resizeHotspot:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        resizeGrip.resizing = true
        resizeGrip:Show()
        f:StartSizing("BOTTOMRIGHT")
    end)
    resizeHotspot:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        resizeGrip.resizing = false
        f:StopMovingOrSizing()
        SaveSize(f)
        RustcoreDeathlog.RefreshRows()
        if not resizeGrip.IsMouseOver or not resizeGrip:IsMouseOver() then resizeGrip:Hide() end
    end)

    ApplySavedPosition(f)
    f:Hide()
    return f
end

local function EnsureFrame()
    if not deathlogFrame then
        deathlogFrame = BuildDeathlogFrame()
    end
    return deathlogFrame
end

function RustcoreDeathlog.ApplyVisibility()
    local frame = EnsureFrame()
    if Rustcore.GetSetting("showDeathlogWindow") then
        frame:Show()
        RustcoreDeathlog.RefreshRows()
    else
        frame:Hide()
    end
end

function RustcoreDeathlog.RefreshPosition()
    if not deathlogFrame then return end
    ApplySavedPosition(deathlogFrame)
    ApplySavedSize(deathlogFrame)
    RustcoreDeathlog.RefreshRows()
end

function RustcoreDeathlog.RefreshBackgroundOpacity()
    if not deathlogFrame then return end
    local opacity = Rustcore.GetSetting("deathlogBackgroundOpacity") or BACKGROUND_ALPHA
    for _, piece in pairs(deathlogFrame.backgroundPieces or {}) do
        piece:SetAlpha(opacity)
    end
    if deathlogFrame.shade then
        deathlogFrame.shade:SetVertexColor(0, 0, 0, 0.10 * opacity)
    end
end

function RustcoreDeathlog.RefreshBackgroundShadow()
    if not deathlogFrame then return end
    local opacity = Rustcore.GetSetting("deathlogBackgroundShadow") or BACKGROUND_ALPHA
    for _, piece in pairs(deathlogFrame.backgroundShadowPieces or {}) do
        piece:SetAlpha(opacity)
    end
end

function RustcoreDeathlog.RefreshFontSize()
    if not deathlogFrame then return end
    local fontSize = GetFontSize()
    ApplyBodyFont(deathlogFrame.measureText, fontSize)
    ApplyBodyFont(deathlogFrame.headerMeasureText, math.max(9, fontSize - 2))
    for _, text in pairs(deathlogFrame.headerRow.columns or {}) do
        ApplyBodyFont(text, math.max(9, fontSize - 2))
    end
    for _, row in ipairs(deathlogFrame.scrollContent.rows or {}) do
        ApplyBodyFont(row.levelText, fontSize)
        ApplyBodyFont(row.nameText, fontSize)
        ApplyBodyFont(row.sourceText, fontSize)
        ApplyBodyFont(row.countText, fontSize)
    end
    RustcoreDeathlog.RefreshRows()
end

function RustcoreDeathlog.Init()
    if initialized then return end
    initialized = true
    StartSession()
    EnsureDB()

    sessionTracker = CreateFrame("Frame")
    sessionTracker:RegisterEvent("PLAYER_LOGOUT")
    sessionTracker:SetScript("OnEvent", TouchSession)
    sessionTracker.elapsed = 0
    sessionTracker:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed >= 60 then
            self.elapsed = 0
            TouchSession()
        end
    end)

    C_Timer.After(1, function()
        RustcoreDeathlog.ApplyVisibility()
    end)
end
