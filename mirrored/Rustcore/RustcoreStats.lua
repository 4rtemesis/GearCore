-- Rustcore: minimal item loss stats window

RustcoreStats = {}

local statsFrame
local eventFrame
local initialized = false
local scanning = false
local GetSlotStateKey

local GEAR_SLOTS = { 1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18 }
local BODY_FONT_PATH = Rustcore.GetAssetPath("Font/BPpong.otf")
local DEFAULT_WIDTH, DEFAULT_HEIGHT = 300, 130
local MIN_WIDTH, MIN_HEIGHT = 160, 95
local MIN_HEIGHT_HORIZONTAL = 54
local MAX_WIDTH, MAX_HEIGHT = 680, 300
local BACKGROUND_ALPHA = 0.78
local STATS_BORDER_SIZE = 18
local STATS_CONTENT_EDGE_PAD = 22
local TEXT_PAD = 10
-- Margin used when the panel background is off and there is no border to
-- clear. Not zero: text still needs to breathe away from the window edge.
local BARE_TEXT_PAD = 4
-- Horizontal layout packs graphics much closer to the window's left/right
-- edges than the two-row layout does, so it gets its own, roomier side
-- margin instead of sharing TEXT_PAD.
local HORIZONTAL_SIDE_PAD = 20
local BEST_ITEM_SIDE_PAD = 16
local COLUMN_GAP = 4
local ROW_GAP = 2
-- Pulls the second row up in the two-row layout. Kept separate from ROW_GAP
-- because ROW_GAP also feeds the row-height split -- changing that resizes the
-- graphics, whereas the gap being closed here is just the slack left over when
-- the counter art does not fill its share of the height.
local ROW_TIGHTEN = 6
local BEST_CELL_RATIO = 1.8
local COUNTER_REF_WIDTH, COUNTER_REF_HEIGHT = 229, 103
local COUNTER_DIGIT_SPACING = 0.235
local COUNTER_LEFT_DIGIT_NUDGE = -3
local COUNTER_MIDDLE_DIGIT_NUDGE = 0
local COUNTER_RIGHT_DIGIT_OFFSET = 0.012
local COUNTER_RIGHT_DIGIT_NUDGE = 1
local COUNTER_DIGIT_Y = -0.01
local COUNTER_ROLL_DURATION = 0.20
local ITEM_FRAME_REF_WIDTH, ITEM_FRAME_REF_HEIGHT = 846, 190
local ITEM_LINK_WIDTH_RATIO = 0.80
local LABEL_COLOR = { 1, 0.82, 0 }
local VALUE_COLOR = { 1, 1, 1 }
local COUNTER_VALUE_COLOR = { 0.91, 0.88, 0.8 }
local RESIZE_TOOLTIP = "Left click and drag to adjust. Right click to auto adjust."

local function Clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function FormatCounterValue(value)
    value = math.floor(Clamp(tonumber(value) or 0, 0, 999))
    return string.format("%03d", value)
end

local function SetCounterDigit(slot, value, color)
    -- Applied to both texts every time rather than only on change: the rolling
    -- animation swaps which of the pair is visible, so tinting just one would
    -- leave the other showing the previous colour when the mode is toggled.
    local r, g, b = color[1], color[2], color[3]
    slot.oldText:SetTextColor(r, g, b)
    slot.newText:SetTextColor(r, g, b)

    if slot.currentValue == nil then
        slot.currentValue = value
        slot.oldText:SetText(value)
        slot.oldText:Show()
        slot.newText:Hide()
        return
    end
    if slot.currentValue == value then return end

    slot:SetScript("OnUpdate", nil)
    slot.oldText:SetText(slot.currentValue)
    slot.currentValue = value
    slot.elapsed = 0
    slot.oldText:ClearAllPoints()
    slot.oldText:SetPoint("CENTER", slot, "CENTER", 0, 0)
    slot.newText:SetText(value)
    slot.newText:ClearAllPoints()
    slot.newText:SetPoint("CENTER", slot, "CENTER", 0, slot:GetHeight())
    slot.oldText:Show()
    slot.newText:Show()
    slot:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        local progress = Clamp(self.elapsed / COUNTER_ROLL_DURATION, 0, 1)
        local eased = progress * progress * (3 - (2 * progress))
        local travel = self:GetHeight()

        self.oldText:ClearAllPoints()
        self.oldText:SetPoint("CENTER", self, "CENTER", 0, -travel * eased)
        self.newText:ClearAllPoints()
        self.newText:SetPoint("CENTER", self, "CENTER", 0, travel * (1 - eased))

        if progress >= 1 then
            self.oldText:SetText(self.currentValue)
            self.oldText:ClearAllPoints()
            self.oldText:SetPoint("CENTER", self, "CENTER", 0, 0)
            self.oldText:Show()
            self.newText:Hide()
            self:SetScript("OnUpdate", nil)
        end
    end)
end

local function SetCounterDigits(digits, value, color)
    local text = FormatCounterValue(value)
    color = color or COUNTER_VALUE_COLOR
    for i = 1, 3 do
        SetCounterDigit(digits[i], text:sub(i, i), color)
    end
end

local function EnsureStatsDB()
    RustcoreDB.characterStats = RustcoreDB.characterStats or {}
    local key = Rustcore.GetCharacterKey and Rustcore.GetCharacterKey() or UnitName("player") or "player"
    RustcoreDB.characterStats[key] = RustcoreDB.characterStats[key] or {}
    local stats = RustcoreDB.characterStats[key]
    stats.destroyedItems = stats.destroyedItems or 0
    stats.rustedItems = stats.rustedItems or 0
    stats.deaths = stats.deaths or 0
    stats.bestItemLostLink = stats.bestItemLostLink or nil
    stats.bestItemLostIlvl = stats.bestItemLostIlvl or 0
    stats.zeroDurabilitySlots = stats.zeroDurabilitySlots or {}
    stats.rustedItemKeys = stats.rustedItemKeys or {}
    return stats
end

-- Every counter the panel can show, in the left-to-right order they appear.
-- Adding one is a matter of appending a row here plus a matching setting: the
-- layout below sizes and places whatever is switched on rather than assuming a
-- fixed pair.
-- `colorTier` indexes Rustcore.DIFFICULTY_COLORS. The mapping is by how severe
-- each counter reads rather than by matching names: rusting is the mildest thing
-- that happens to your gear so it takes the Rusted green, an item destroyed
-- outright is a step past that and takes Shattered's orange, and a death takes
-- Crumbling's red. Note that the Broken counter is deliberately *not* the Broken
-- tier colour, which would be too close to the green beside it to tell apart.
local ALL_COUNTERS = {
    {
        key = "rusted", setting = "statShowRusted", label = "Rusted", colorTier = 1,
        labelKey = "rustedLabel", counterKey = "rustedCounter", digitsKey = "rustedDigits",
        value = function(stats) return stats.rustedItems or 0 end,
    },
    {
        key = "broken", setting = "statShowBroken", label = "Broken", colorTier = 3,
        labelKey = "destroyedLabel", counterKey = "destroyedCounter", digitsKey = "destroyedDigits",
        value = function(stats) return stats.destroyedItems or 0 end,
    },
    {
        key = "deaths", setting = "statShowDeaths", label = "Deaths", colorTier = 4,
        labelKey = "deathsLabel", counterKey = "deathsCounter", digitsKey = "deathsDigits",
        value = function(stats) return stats.deaths or 0 end,
    },
}

-- The tint a counter's digits should use right now: its difficulty colour while
-- coloured numbers are on, otherwise the plain parchment tone they all shared
-- before.
local function CounterColor(counter)
    if Rustcore.GetSetting("statsColoredNumbers") == false then
        return COUNTER_VALUE_COLOR
    end
    -- The vivid palette, not the one the difficulty title uses: same hues, but
    -- these numerals are small and sit on dark art, where the earthy originals
    -- were hard to read.
    local palette = Rustcore.DIFFICULTY_COLORS_VIVID or Rustcore.DIFFICULTY_COLORS
    return (palette and palette[counter.colorTier]) or COUNTER_VALUE_COLOR
end

local function VisibleCounters()
    local visible = {}
    for _, counter in ipairs(ALL_COUNTERS) do
        -- Deaths is the only one defaulting off, so it needs the explicit
        -- comparison; the rest are on unless switched off.
        local on
        if counter.setting == "statShowDeaths" then
            on = Rustcore.GetSetting(counter.setting) == true
        else
            on = Rustcore.GetSetting(counter.setting) ~= false
        end
        if on then visible[#visible + 1] = counter end
    end
    return visible
end

-- Which counters are on. Each is now a plain setting the player controls, rather
-- than being inferred from difficulty and the repair option: a panel that
-- rearranged itself when an unrelated setting changed was surprising, and there
-- was no way to turn a counter off once it had a value.
local function GetCounterVisibility()
    local showRusted    = Rustcore.GetSetting("statShowRusted") ~= false
    local showDestroyed = Rustcore.GetSetting("statShowBroken") ~= false
    local showDeaths    = Rustcore.GetSetting("statShowDeaths") == true
    local showBest      = Rustcore.GetSetting("statShowBestItem") ~= false
    return showRusted, showDestroyed, showDeaths, showBest
end

local function GetItemIlvl(item)
    if not item or not item.link then return 0 end
    return item.ilvl or select(4, GetItemInfo(item.link)) or 0
end

local function UpdateBestItem(item)
    if not item or not item.link then return end
    local stats = EnsureStatsDB()
    local ilvl = GetItemIlvl(item)
    if ilvl >= (stats.bestItemLostIlvl or 0) then
        stats.bestItemLostIlvl = ilvl
        stats.bestItemLostLink = item.link
    end
end

local function RefreshText()
    if not statsFrame then return end
    local stats = EnsureStatsDB()
    for _, counter in ipairs(ALL_COUNTERS) do
        statsFrame[counter.labelKey]:SetText(counter.label)
        SetCounterDigits(statsFrame[counter.digitsKey], counter.value(stats),
            CounterColor(counter))
    end
    statsFrame.bestLabel:SetText("Best item lost")
    statsFrame.bestValue:SetText(stats.bestItemLostLink or "None")
    if stats.bestItemLostLink then
        statsFrame.bestHitbox:Show()
    else
        statsFrame.bestHitbox:Hide()
    end
    RustcoreStats.RefreshLayout()
end

local function SavePosition(frame)
    local point, _, relativePoint, x, y = frame:GetPoint()
    Rustcore.SetProfileValue("statsWindowPoint", {
        point = point,
        relativePoint = relativePoint,
        x = x,
        y = y,
    })
end

local function ApplySavedPosition(frame)
    frame:ClearAllPoints()
    local pos = Rustcore.GetProfileValue("statsWindowPoint")
    if pos and pos.point and pos.relativePoint and pos.x and pos.y then
        frame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    end
end

local function SaveSize(frame)
    local width, height = frame:GetSize()
    Rustcore.SetProfileValue("statsWindowSize", {
        width = width,
        height = height,
    })
end

-- The side margin exists only to hold content clear of the border art, so it
-- follows the background on and off rather than being a setting of its own.
-- With the panel hidden there is no border to clear, and the window can pull
-- its content back to the ordinary text margins.
local function ContentEdgePad()
    return Rustcore.GetSetting("statsBackground") and STATS_CONTENT_EDGE_PAD or 0
end

-- Same idea on the vertical axis. This one matters more than it looks: the
-- counters are capped at a multiple of the row height, not the column width,
-- so trimming only the sides leaves them exactly the size they already were.
-- Reclaiming the top and bottom margin is what actually makes them grow.
local function ContentTextPad()
    return Rustcore.GetSetting("statsBackground") and TEXT_PAD or BARE_TEXT_PAD
end

-- The horizontal layout packs everything into one row of graphics, so it
-- doesn't need the taller minimum the two-row layout requires to avoid
-- clipping; letting it go shorter is what makes a wide-but-short bar possible.
local function GetMinHeight()
    local base = Rustcore.GetSetting("statsHorizontalLayout") and MIN_HEIGHT_HORIZONTAL or MIN_HEIGHT
    -- Both floors were measured with the panel's margins in place. Without the
    -- background those margins are gone, so the same content fits in a shorter
    -- window; holding the old floor would re-impose the padding by another name.
    return base - (TEXT_PAD - ContentTextPad()) * 2
end

local function ApplyResizeBounds()
    if not statsFrame then return end
    local minH = GetMinHeight()
    if statsFrame.SetResizeBounds then
        statsFrame:SetResizeBounds(MIN_WIDTH, minH, MAX_WIDTH, MAX_HEIGHT)
    elseif statsFrame.SetMinResize and statsFrame.SetMaxResize then
        statsFrame:SetMinResize(MIN_WIDTH, minH)
        statsFrame:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
    end
    -- SetResizeBounds only constrains future drags; if the layout mode just
    -- switched to one with a taller minimum, pull an already-too-short frame
    -- back in bounds instead of leaving it stuck below the new floor.
    local w, h = statsFrame:GetSize()
    local clampedW, clampedH = Clamp(w, MIN_WIDTH, MAX_WIDTH), Clamp(h, minH, MAX_HEIGHT)
    if clampedW ~= w or clampedH ~= h then
        statsFrame:SetSize(clampedW, clampedH)
    end
end

local function ApplySavedSize(frame)
    local size = Rustcore.GetProfileValue("statsWindowSize")
    local width = size and tonumber(size.width) or DEFAULT_WIDTH
    local height = size and tonumber(size.height) or DEFAULT_HEIGHT
    frame:SetSize(
        Clamp(width, MIN_WIDTH, MAX_WIDTH),
        Clamp(height, GetMinHeight(), MAX_HEIGHT)
    )
end

local function ApplyBodyFont(fontString, size)
    if fontString then
        fontString:SetFont(BODY_FONT_PATH, size or 15, "")
    end
end

function RustcoreStats.RefreshPosition()
    if not statsFrame then return end
    ApplySavedPosition(statsFrame)
    ApplySavedSize(statsFrame)
    RustcoreStats.RefreshLayout()
end

-- Snaps the window height to whichever layout's natural size fits it best:
-- short for the single-row horizontal layout, the original default for the
-- taller two-row layout. Called whenever the horizontal toggle changes so
-- the background isn't left oversized (or undersized) for the new layout.
function RustcoreStats.ApplyLayoutModeChange()
    if not statsFrame then return end
    local horizontal = Rustcore.GetSetting("statsHorizontalLayout")
    local targetHeight = horizontal and MIN_HEIGHT_HORIZONTAL or DEFAULT_HEIGHT
    local _, currentHeight = statsFrame:GetSize()
    if currentHeight ~= targetHeight then
        statsFrame:SetHeight(targetHeight)
        SaveSize(statsFrame)
    end
    RustcoreStats.RefreshLayout()
end

function RustcoreStats.RefreshLayout()
    if not statsFrame then return end
    ApplyResizeBounds()
    local width, height = statsFrame:GetSize()
    local pad = ContentTextPad()
    local horizontal = Rustcore.GetSetting("statsHorizontalLayout")
    local sidePad = math.max(horizontal and HORIZONTAL_SIDE_PAD or pad, ContentEdgePad())
    local bestSidePad = math.max(BEST_ITEM_SIDE_PAD, ContentEdgePad())
    local contentWidth = math.max(1, width - (sidePad * 2))
    local bestContentWidth = math.max(1, width - (bestSidePad * 2))
    local contentHeight = math.max(1, height - (pad * 2))
    local rowHeight = horizontal and contentHeight or ((contentHeight - ROW_GAP) / 2)
    local visible = VisibleCounters()
    local visibleCounterCount = #visible
    local showBest = select(4, GetCounterVisibility())
    local elementGap = 2
    local counterCellWidth
    local bestCellWidth = bestContentWidth
    local labelSize
    local bestLabelSize
    local graphicHeight
    local horizontalRowWidth = 0
    if horizontal then
        -- Single row: every visible graphic (rusted/destroyed counters,
        -- best-item frame) shares one graphicHeight so they line up at the
        -- same height; only their widths differ, each scaled from that
        -- shared height by its own aspect ratio.
        labelSize = Clamp(math.floor(contentHeight * 0.16) + 1, 11, 16)
        bestLabelSize = labelSize
        local slotCount = visibleCounterCount + (showBest and 1 or 0)
        local gaps = math.max(0, slotCount - 1) * COLUMN_GAP
        local counterAspect = COUNTER_REF_WIDTH / COUNTER_REF_HEIGHT
        local itemAspect = ITEM_FRAME_REF_WIDTH / ITEM_FRAME_REF_HEIGHT
        local aspectSum = (visibleCounterCount * counterAspect) + (showBest and itemAspect or 0)
        local heightFromContent = math.max(1, contentHeight - labelSize - elementGap)
        local heightFromWidth = (contentWidth - gaps) / math.max(aspectSum, 0.001)
        graphicHeight = math.max(1, math.min(heightFromContent, heightFromWidth))

        counterCellWidth = graphicHeight * counterAspect
        bestCellWidth = graphicHeight * itemAspect
        horizontalRowWidth = (visibleCounterCount * counterCellWidth)
            + (showBest and bestCellWidth or 0) + gaps
    else
        labelSize = Clamp(math.floor(rowHeight * 0.17) + 1, 12, 18)
        bestLabelSize = Clamp(math.floor(rowHeight * 0.19), 11, 17)
        if visibleCounterCount > 1 then
            -- Counters share the row evenly, however many are on.
            counterCellWidth = (contentWidth - (COLUMN_GAP * (visibleCounterCount - 1)))
                / visibleCounterCount
        else
            counterCellWidth = contentWidth
        end
    end
    local counterWidth = horizontal and counterCellWidth or math.min(counterCellWidth, rowHeight * 1.33)
    local counterHeight = counterWidth * (COUNTER_REF_HEIGHT / COUNTER_REF_WIDTH)
    local counterTopOffset = labelSize + elementGap
    local digitSize = Clamp(math.floor(counterHeight * 0.34), 12, 25)
    local bestFrameMaxHeight = horizontal and graphicHeight or math.max(1, rowHeight - bestLabelSize - elementGap)
    local bestFrameWidth = horizontal and bestCellWidth or math.min(
        bestCellWidth,
        bestFrameMaxHeight * (ITEM_FRAME_REF_WIDTH / ITEM_FRAME_REF_HEIGHT)
    )
    local bestFrameHeight = bestFrameWidth * (ITEM_FRAME_REF_HEIGHT / ITEM_FRAME_REF_WIDTH)
    local bestValueSize = Clamp(math.floor(bestFrameHeight * 0.22) + 2, 12, 20)

    -- Driven off the counter table rather than named one by one, which is how
    -- the deaths label ended up at the default size while the other two were
    -- scaled: adding a counter meant remembering to add a line here too.
    for _, counter in ipairs(ALL_COUNTERS) do
        ApplyBodyFont(statsFrame[counter.labelKey], labelSize)
    end
    ApplyBodyFont(statsFrame.bestLabel, bestLabelSize)
    ApplyBodyFont(statsFrame.bestValue, bestValueSize)
    for _, counter in ipairs(ALL_COUNTERS) do
        local digits = statsFrame[counter.digitsKey]
        for i = 1, 3 do
            ApplyBodyFont(digits[i].oldText, digitSize)
            ApplyBodyFont(digits[i].newText, digitSize)
        end
    end

    local topY = -pad
    local bottomY = horizontal and topY or (-pad - rowHeight - ROW_GAP + ROW_TIGHTEN)
    local centerXByKey = {}
    local bestCenterX = width * 0.5
    if horizontal then
        -- Center the whole row within contentWidth instead of left-packing
        -- it, so extra window width becomes empty margin rather than forcing
        -- the graphics themselves to grow.
        local cursor = sidePad + math.max(0, (contentWidth - horizontalRowWidth) * 0.5)
        local function PlaceCell(w)
            local centerX = cursor + (w * 0.5)
            cursor = cursor + w + COLUMN_GAP
            return centerX
        end
        for _, counter in ipairs(visible) do
            centerXByKey[counter.key] = PlaceCell(counterCellWidth)
        end
        if showBest then bestCenterX = PlaceCell(bestCellWidth) end
    elseif visibleCounterCount == 1 then
        centerXByKey[visible[1].key] = width * 0.5
    elseif visibleCounterCount > 1 then
        -- Evenly spaced across the content area, in declaration order.
        local rowWidth = (counterCellWidth * visibleCounterCount)
            + (COLUMN_GAP * (visibleCounterCount - 1))
        local cursor = sidePad + math.max(0, (contentWidth - rowWidth) * 0.5)
        for _, counter in ipairs(visible) do
            centerXByKey[counter.key] = cursor + (counterCellWidth * 0.5)
            cursor = cursor + counterCellWidth + COLUMN_GAP
        end
    end

    for _, counter in ipairs(ALL_COUNTERS) do
        local label = statsFrame[counter.labelKey]
        local frame = statsFrame[counter.counterKey]
        local centerX = centerXByKey[counter.key]
        label:ClearAllPoints()
        label:SetPoint("TOP", statsFrame, "TOPLEFT", centerX or (width * 0.5), topY)
        label:SetWidth(counterCellWidth)
        label:SetShown(centerX ~= nil)
        frame:SetShown(centerX ~= nil)
    end

    local function PositionCounter(counter, digits, centerX)
        counter:SetSize(counterWidth, counterHeight)
        counter:ClearAllPoints()
        counter:SetPoint("TOP", statsFrame, "TOPLEFT", centerX, topY - counterTopOffset)
        counter.texture:SetAllPoints(counter)
        for i = 1, 3 do
            local slot = digits[i]
            local digitX = (i - 2) * counterWidth * COUNTER_DIGIT_SPACING
            if i == 1 then
                digitX = digitX + COUNTER_LEFT_DIGIT_NUDGE
            elseif i == 2 then
                digitX = digitX + COUNTER_MIDDLE_DIGIT_NUDGE
            elseif i == 3 then
                digitX = digitX + (counterWidth * COUNTER_RIGHT_DIGIT_OFFSET) + COUNTER_RIGHT_DIGIT_NUDGE
            end
            slot:ClearAllPoints()
            slot:SetPoint(
                "CENTER",
                counter,
                "CENTER",
                digitX,
                counterHeight * COUNTER_DIGIT_Y
            )
            slot:SetSize(counterWidth * 0.18, digitSize + 4)
            slot.oldText:SetSize(counterWidth * 0.18, digitSize + 4)
            slot.newText:SetSize(counterWidth * 0.18, digitSize + 4)
        end
    end

    for _, counter in ipairs(visible) do
        PositionCounter(statsFrame[counter.counterKey], statsFrame[counter.digitsKey],
            centerXByKey[counter.key])
    end

    statsFrame.bestLabel:SetShown(showBest)
    statsFrame.itemLostFrame:SetShown(showBest)
    statsFrame.bestValue:SetShown(showBest)
    if not showBest then statsFrame.bestHitbox:Hide() end

    statsFrame.bestLabel:ClearAllPoints()
    statsFrame.bestLabel:SetPoint("TOP", statsFrame, "TOPLEFT", bestCenterX, bottomY)
    statsFrame.bestLabel:SetWidth(bestCellWidth)

    statsFrame.itemLostFrame:SetSize(bestFrameWidth, bestFrameHeight)
    statsFrame.itemLostFrame:ClearAllPoints()
    statsFrame.itemLostFrame:SetPoint("TOP", statsFrame.bestLabel, "BOTTOM", 0, -elementGap)
    statsFrame.itemLostFrame.texture:SetAllPoints(statsFrame.itemLostFrame)

    statsFrame.bestValue:ClearAllPoints()
    statsFrame.bestValue:SetPoint("CENTER", statsFrame.itemLostFrame, "CENTER", 0, 0)
    statsFrame.bestValue:SetWidth(bestFrameWidth * ITEM_LINK_WIDTH_RATIO)

    statsFrame.bestHitbox:ClearAllPoints()
    statsFrame.bestHitbox:SetPoint("CENTER", statsFrame.bestValue, "CENTER", 0, 0)
    statsFrame.bestHitbox:SetSize(math.max(1, statsFrame.bestValue:GetStringWidth() or 0), bestValueSize + 8)

end

local function GetAutoFitWidth()
    if not statsFrame then return DEFAULT_WIDTH end
    RustcoreStats.RefreshLayout()

    local visible = VisibleCounters()
    local visibleCounterCount = #visible
    local showBest = select(4, GetCounterVisibility())

    local counterCellWidth = 68
    for _, counter in ipairs(visible) do
        local labelWidth = counter.label:GetStringWidth() or 0
        if labelWidth > counterCellWidth then counterCellWidth = labelWidth end
    end

    local bestLabelWidth = showBest and (statsFrame.bestLabel:GetStringWidth() or 0) or 0
    local bestValueWidth = showBest and (statsFrame.bestValue:GetStringWidth() or 0) or 0
    local bottomWidth = showBest
        and math.max(140, bestLabelWidth, bestValueWidth / ITEM_LINK_WIDTH_RATIO)
        or 0

    if Rustcore.GetSetting("statsHorizontalLayout") then
        local slotCount = visibleCounterCount + (showBest and 1 or 0)
        local totalWidth = (counterCellWidth * visibleCounterCount)
            + bottomWidth
            + (math.max(0, slotCount - 1) * COLUMN_GAP)
        return Clamp(math.ceil(totalWidth + (math.max(HORIZONTAL_SIDE_PAD, ContentEdgePad()) * 2)), MIN_WIDTH, MAX_WIDTH)
    end

    local topWidth = (counterCellWidth * visibleCounterCount)
        + (math.max(0, visibleCounterCount - 1) * COLUMN_GAP)
    local requiredTopWidth = topWidth + (math.max(ContentTextPad(), ContentEdgePad()) * 2)
    local requiredBottomWidth = bottomWidth + (math.max(BEST_ITEM_SIDE_PAD, ContentEdgePad()) * 2)
    return Clamp(math.ceil(math.max(requiredTopWidth, requiredBottomWidth)), MIN_WIDTH, MAX_WIDTH)
end

local function AutoFitWidth(frame)
    frame:SetWidth(GetAutoFitWidth())
    SaveSize(frame)
    RustcoreStats.RefreshLayout()
end

local function BuildStatsFrame()
    local f = CreateFrame("Frame", "RustcoreStatsFrame", UIParent)
    ApplySavedSize(f)
    -- Behind the action bars, griffins included. The panel is something the
    -- player glances at, not something they act on, so it has no business
    -- covering the bar they are actually using -- and the griffin end caps
    -- overhang far enough that a panel parked near them clips the artwork.
    -- BACKGROUND rather than LOW because the bar itself sits at LOW, and
    -- sharing a strata would settle it on frame level, which is not ours to
    -- decide. Mouse input is unaffected: nothing overlapping means nothing
    -- swallowing the click.
    f:SetFrameStrata("BACKGROUND")
    f:SetMovable(true)
    if f.SetResizable then f:SetResizable(true) end
    f:EnableMouse(true)
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_WIDTH, GetMinHeight(), MAX_WIDTH, MAX_HEIGHT)
    elseif f.SetMinResize and f.SetMaxResize then
        f:SetMinResize(MIN_WIDTH, GetMinHeight())
        f:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
    end

    local opacity = Rustcore.GetSetting("statsBackgroundOpacity") or BACKGROUND_ALPHA
    local shadowOpacity = Rustcore.GetSetting("statsBackgroundShadow") or BACKGROUND_ALPHA
    local panelArt = RustcoreTheme.CreateRivetPanelArt(f, opacity, shadowOpacity, STATS_BORDER_SIZE)

    f.borderPieces = panelArt.borderPieces
    f.backgroundShadowBorderPieces = panelArt.shadowBorderPieces

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    f:SetScript("OnSizeChanged", function()
        RustcoreStats.RefreshLayout()
    end)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            RustcoreOptions.Toggle()
        end
    end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR", 0, -32)
        GameTooltip:AddLine("Rustcore Stats", 1, 1, 1)
        GameTooltip:AddLine("Right-click to open options", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag from lower right corner to change size", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local textLayer = CreateFrame("Frame", nil, f)
    textLayer:SetAllPoints(f)
    textLayer:SetFrameLevel(f:GetFrameLevel() + 3)

    local function CreateStatsText(color, parent)
        local text = (parent or textLayer):CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetJustifyH("CENTER")
        text:SetJustifyV("MIDDLE")
        text:SetWordWrap(false)
        text:SetTextColor(unpack(color))
        text:SetAlpha(1)
        text:SetShadowColor(0, 0, 0, 1)
        text:SetShadowOffset(1, -1)
        ApplyBodyFont(text)
        return text
    end

    local destroyedLabel = CreateStatsText(LABEL_COLOR)
    local rustedLabel = CreateStatsText(LABEL_COLOR)
    local deathsLabel = CreateStatsText(LABEL_COLOR)
    local bestLabel = CreateStatsText(LABEL_COLOR)

    local function CreateArtFrame(texturePath)
        local frame = CreateFrame("Frame", nil, textLayer)
        frame.texture = frame:CreateTexture(nil, "ARTWORK")
        frame.texture:SetAllPoints(frame)
        frame.texture:SetTexture(Rustcore.GetAssetPath(texturePath))
        frame.texture:SetTexCoord(0, 1, 0, 1)
        return frame
    end

    local function CreateCounter()
        local counter = CreateArtFrame("UI/DarkCounter copy.tga")
        local digits = {}
        for i = 1, 3 do
            local slot = CreateFrame("Frame", nil, counter)
            if slot.SetClipsChildren then
                slot:SetClipsChildren(true)
            end
            slot.oldText = CreateStatsText(COUNTER_VALUE_COLOR, slot)
            slot.newText = CreateStatsText(COUNTER_VALUE_COLOR, slot)
            slot.oldText:SetDrawLayer("OVERLAY", 1)
            slot.newText:SetDrawLayer("OVERLAY", 1)
            slot.oldText:SetShadowColor(0, 0, 0, 0)
            slot.newText:SetShadowColor(0, 0, 0, 0)
            slot.oldText:SetShadowOffset(0, 0)
            slot.newText:SetShadowOffset(0, 0)
            slot.oldText:SetPoint("CENTER", slot, "CENTER", 0, 0)
            slot.newText:SetPoint("CENTER", slot, "CENTER", 0, 0)
            slot.newText:Hide()
            digits[i] = slot
        end
        return counter, digits
    end

    local rustedCounter, rustedDigits = CreateCounter()
    local destroyedCounter, destroyedDigits = CreateCounter()
    local deathsCounter, deathsDigits = CreateCounter()
    local itemLostFrame = CreateArtFrame("UI/Lostitemframe Dark copy.tga")
    local bestValue = CreateStatsText(VALUE_COLOR, itemLostFrame)

    local bestHitbox = CreateFrame("Frame", nil, itemLostFrame)
    bestHitbox:EnableMouse(true)
    bestHitbox:SetScript("OnEnter", function(self)
        local link = EnsureStatsDB().bestItemLostLink
        if not link then return end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR", 0, -32)
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    bestHitbox:SetScript("OnLeave", function()
        GameTooltip:Hide()
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
        if button == "RightButton" then
            AutoFitWidth(f)
            return
        end
        if button ~= "LeftButton" then return end
        self.resizing = false
        f:StopMovingOrSizing()
        SaveSize(f)
        RustcoreStats.RefreshLayout()
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
        if button == "RightButton" then
            AutoFitWidth(f)
            return
        end
        if button ~= "LeftButton" then return end
        resizeGrip.resizing = true
        resizeGrip:Show()
        f:StartSizing("BOTTOMRIGHT")
    end)
    resizeHotspot:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then return end
        if button ~= "LeftButton" then return end
        resizeGrip.resizing = false
        f:StopMovingOrSizing()
        SaveSize(f)
        RustcoreStats.RefreshLayout()
        if not resizeGrip.IsMouseOver or not resizeGrip:IsMouseOver() then resizeGrip:Hide() end
    end)

    f.destroyedLabel = destroyedLabel
    f.rustedLabel = rustedLabel
    f.destroyedCounter = destroyedCounter
    f.destroyedDigits = destroyedDigits
    f.rustedCounter = rustedCounter
    f.rustedDigits = rustedDigits
    f.deathsLabel = deathsLabel
    f.deathsCounter = deathsCounter
    f.deathsDigits = deathsDigits
    f.bestLabel = bestLabel
    f.bestValue = bestValue
    f.itemLostFrame = itemLostFrame
    f.bestHitbox = bestHitbox
    f.backgroundPieces = panelArt.pieces
    f.backgroundShadowPieces = panelArt.shadowPieces
    f.background = panelArt.center
    f.shade = panelArt.shade
    f.resizeGrip = resizeGrip
    ApplySavedPosition(f)
    statsFrame = f
    RustcoreStats.ApplyBackgroundVisibility()
    RustcoreStats.RefreshLayout()
    RefreshText()

    f:Hide()
    return f
end

local function EnsureFrame()
    if not statsFrame then
        statsFrame = BuildStatsFrame()
    end
    return statsFrame
end

function RustcoreStats.ApplyVisibility()
    local frame = EnsureFrame()
    RefreshText()
    if Rustcore.GetSetting("showStatsWindow") then
        RustcoreStats.RefreshStyle()
        frame:Show()
    else
        frame:Hide()
    end
end

-- Re-read every counter from the saved data and repaint. Used when something
-- outside this file changed what the numbers or their colours should be -- a
-- coloured-numbers toggle, or a verification import replacing the stats.
function RustcoreStats.Refresh()
    RefreshText()
end

function RustcoreStats.RefreshStyle()
    RustcoreStats.ApplyBackgroundVisibility()
    RustcoreStats.RefreshBackgroundOpacity()
end

-- The art is built once and toggled, rather than created and destroyed, so
-- flipping the setting can't leak textures across a session.
function RustcoreStats.ApplyBackgroundVisibility()
    if not statsFrame then return end
    local on = Rustcore.GetSetting("statsBackground") and true or false
    for _, piece in pairs(statsFrame.backgroundPieces or {}) do
        if on then piece:Show() else piece:Hide() end
    end
    for _, piece in pairs(statsFrame.backgroundShadowPieces or {}) do
        if on then piece:Show() else piece:Hide() end
    end
    if statsFrame.shade then
        if on then statsFrame.shade:Show() else statsFrame.shade:Hide() end
    end
end

-- Hiding the panel frees the margin that was reserved for its border, so the
-- layout has to re-run; the auto-fit width floor moves with it.
function RustcoreStats.HandleBackgroundChanged()
    RustcoreStats.ApplyBackgroundVisibility()
    RustcoreStats.RefreshLayout()
end

function RustcoreStats.RefreshBackgroundOpacity()
    if not statsFrame then return end
    local opacity = Rustcore.GetSetting("statsBackgroundOpacity") or BACKGROUND_ALPHA
    for _, piece in pairs(statsFrame.backgroundPieces or {}) do
        piece:SetAlpha(opacity)
    end
    if statsFrame.shade then
        statsFrame.shade:SetVertexColor(0, 0, 0, 0.10 * opacity)
    end
end

function RustcoreStats.RefreshBackgroundShadow()
    if not statsFrame then return end
    local opacity = Rustcore.GetSetting("statsBackgroundShadow") or BACKGROUND_ALPHA
    for _, piece in pairs(statsFrame.backgroundShadowPieces or {}) do
        piece:SetAlpha(opacity)
    end
end

-- Counts every death, including one an exception spared from its penalty: the
-- counter reports how often this character died, not how often it cost anything.
function RustcoreStats.RegisterDeath()
    local stats = EnsureStatsDB()
    stats.deaths = (stats.deaths or 0) + 1
    RefreshText()
end

function RustcoreStats.RegisterDestroyedItem(item)
    if not item then return end
    local stats = EnsureStatsDB()
    local slotKey, itemKey = GetSlotStateKey(item.slot, item.link)
    if itemKey and stats.rustedItemKeys and stats.rustedItemKeys[itemKey] then
        UpdateBestItem(item)
        RefreshText()
        return
    end
    stats.destroyedItems = (stats.destroyedItems or 0) + 1
    UpdateBestItem(item)
    RefreshText()
end

function RustcoreStats.RegisterRustedItem(item)
    if not item then return end
    local stats = EnsureStatsDB()
    local _, itemKey = GetSlotStateKey(item.slot, item.link)
    if itemKey then
        stats.rustedItemKeys[itemKey] = true
    end
    stats.rustedItems = (stats.rustedItems or 0) + 1
    UpdateBestItem(item)
    RefreshText()
end

GetSlotStateKey = function(slot, link)
    local owner = Rustcore.GetCharacterKey and Rustcore.GetCharacterKey() or UnitName("player") or "player"
    return owner .. ":" .. slot, owner .. ":" .. slot .. ":" .. (link or "")
end

local function ScanDurability(seedOnly)
    if scanning or not GetInventoryItemDurability then return end
    scanning = true
    local stats = EnsureStatsDB()
    for _, slot in ipairs(GEAR_SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        local current, maximum = GetInventoryItemDurability(slot)
        local slotKey, itemKey = GetSlotStateKey(slot, link)
        if link and current and maximum and maximum > 0 then
            if current <= 0 then
                if stats.zeroDurabilitySlots[slotKey] ~= itemKey then
                    if not seedOnly then
                        local name, _, _, ilvl = GetItemInfo(link)
                        RustcoreStats.RegisterRustedItem({
                            slot = slot,
                            link = link,
                            name = name,
                            ilvl = ilvl or 0,
                        })
                    end
                    stats.zeroDurabilitySlots[slotKey] = itemKey
                end
            else
                stats.zeroDurabilitySlots[slotKey] = nil
            end
        end
    end
    scanning = false
end

function RustcoreStats.Init()
    if initialized then return end
    initialized = true
    EnsureStatsDB()
    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
    eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:SetScript("OnEvent", function(_, event)
        if event == "UPDATE_INVENTORY_DURABILITY" then
            ScanDurability(false)
        else
            ScanDurability(true)
        end
    end)
    C_Timer.After(1, function()
        ScanDurability(true)
        RustcoreStats.ApplyVisibility()
    end)
end
