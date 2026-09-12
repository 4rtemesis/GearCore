-- Rustcore: minimal item loss stats window

RustcoreStats = {}

local statsFrame
local eventFrame
local initialized = false
local scanning = false
local GetSlotStateKey

local GEAR_SLOTS = { 1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18 }
local BODY_FONT_PATH = Rustcore.GetAssetPath("Font/BPpong.otf")
-- Row height at scale 1, matching the durability HUD's own row so the two read
-- as the same widget. Width varies by variant and lives with each of them
-- below; the height is shared so both tile to the same grid.
local STAT_ROW_H = 38
local MIN_ROW_SCALE, MAX_ROW_SCALE = 0.55, 2.2
-- The scale a freshly sized window aims for. The rows are art, so 1 is their
-- native size and anything else is a compromise.
local DEFAULT_ROW_SCALE = 1

-- Row internals, lifted wholesale from the durability HUD so the two widgets
-- match pixel for pixel rather than merely in spirit.
local ICON_IMAGE_SIZE = 24
local ICON_CENTER_X = 16
local ICON_INSET = 0.08
local DIGIT_FONT_SIZE = 13
-- One character tall, so the roll animation is clipped to a single digit and
-- reads as a drum turning rather than a numeral flying across the row.
local DIGIT_SLOT_H = DIGIT_FONT_SIZE + 4

-- The two shapes a counter row can take.
--
-- ICON_ROW is the durability-HUD row: an item icon on the left with the counter
-- art wrapped around it. PLAIN_ROW is the counter the stats window used before
-- the icons arrived -- the same digits rolling the same way, just the
-- standalone counter graphic with nothing beside it.
--
-- Both are built for every counter and the setting only picks which is shown.
-- Building on demand would mean tearing widgets down and standing them back up
-- whenever the option was toggled, and the two would have to be kept in step by
-- hand; this way the only thing the setting touches is visibility.
--
-- Geometry is in row-local pixels measured from the row's LEFT edge, which is
-- what the digit slots anchor to. The plain variant's numbers come from the
-- pre-icon layout, which sized everything as fractions of the counter art's
-- 229x103; at a fixed width those fractions collapse to these constants.
local ICON_ROW = {
    width = 110,
    art = "UI/durability counter frame copy.tga",
    -- The art is far wider than it is tall; stretched to the full row height it
    -- squashes its icon cutout out of square, so it gets its own height and is
    -- centred in the row.
    artHeight = 32,
    digitCenterX = 0.62,
    digitSpacing = 0.148,
    -- Per-digit pixel nudge: { hundreds, tens, ones }.
    digitNudge = { -5, -2, 1 },
    slotWidth = 16,
    nameCenterX = 66,
    hasIcon = true,
}
local PLAIN_ROW = {
    -- The counter art is 229x103, so this is its natural width at row height.
    width = 85,
    art = "UI/DarkCounter copy.tga",
    artHeight = nil, -- fills the row
    digitCenterX = 0.5,
    digitSpacing = 0.235,
    digitNudge = { -3, 0, 2 },
    slotWidth = 15,
    nameCenterX = 42,
    hasIcon = false,
}

-- The best-item row puts a name where the others put three digits. The area is
-- the span the digit slots occupy, so the name sits in the same window the
-- counter art was drawn around -- which comes out at much the same width in
-- both variants, wide digits in a narrow counter versus the reverse.
local NAME_AREA_W = 56
local NAME_FONT_SIZE = 11
-- A plate behind the name, because an item name is far more glyphs than the
-- three numerals this window was drawn for and the counter art's own texture
-- shows through between them.
local NAME_BACKDROP_PAD = 3
local NAME_BACKDROP_COLOR = { 0, 0, 0, 0.62 }
-- Item names are far longer than the three characters this window was drawn
-- for, so the name shrinks to fit rather than being cut -- down to this size,
-- past which it would be unreadable anyway and the tail is clipped instead.
local NAME_MIN_FONT_SIZE = 7

-- Optional heading above each row. The band is reserved in the row's own
-- coordinates so it scales with everything else, and costs nothing at all when
-- the headings are switched off.
local TITLE_FONT_SIZE = 11
local TITLE_BAND_H = 14
local TITLE_COLOR = { 1, 0.82, 0 }
-- Matches the difficulty title's shadow rather than the one-pixel drop the
-- counter digits use: these sit over the panel art rather than over a counter
-- graphic, and a single pixel of black was not enough to lift them off it.
local TITLE_SHADOW_OFFSET = 2

-- The cracked frame the deletion wheel puts on doomed gear, at the ratio it
-- uses there (36 around a 32px icon).
local BROKEN_OVERLAY_SIZE = 27
-- Default shade laid over an icon so it reads as sitting inside the frame
-- rather than pasted on top. Counters can override it either way.
local ICON_SHADE_ALPHA = 0.20

-- Four rows in a column at native scale, plus the panel margins.
local DEFAULT_WIDTH, DEFAULT_HEIGHT = 146, 178
-- A single column of fixed-width rows needs far less room than the old
-- label-and-panel layout did, and that layout's floor was what stopped the
-- window being pulled in narrow beside the rest of the UI.
local MIN_WIDTH, MIN_HEIGHT = 66, 40
local MAX_WIDTH, MAX_HEIGHT = 680, 420
local BACKGROUND_ALPHA = 0.78
local STATS_BORDER_SIZE = 18
-- Content starts exactly where the border art ends. The rivet panel draws its
-- frame in the outer STATS_BORDER_SIZE pixels and the centre panel begins at
-- that line, so this is as tight as the rows can sit without riding up onto the
-- frame. The extra few pixels it used to carry read as slack rather than margin.
local STATS_CONTENT_EDGE_PAD = STATS_BORDER_SIZE
local TEXT_PAD = 10
-- Margin used when the panel background is off and there is no border to
-- clear. Not zero: content still needs to breathe away from the window edge.
local BARE_TEXT_PAD = 1
-- The horizontal layout packs rows much closer to the window's left and right
-- edges than a single column does, so it gets its own, roomier side margin
-- instead of sharing TEXT_PAD.
local HORIZONTAL_SIDE_PAD = 20
local COLUMN_GAP = 4
local ROW_GAP = 2
local COUNTER_VALUE_COLOR = { 0.91, 0.88, 0.8 }
local COUNTER_ROLL_DURATION = 0.20
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

-- An item's quality colour, read out of the link's own colour escape rather
-- than from GetItemInfo. The link carries it whether or not the client has the
-- item cached, which matters here: the best item lost is usually something the
-- character last saw a long time ago, so the cache is routinely cold on login.
local function ItemRarityColor(link)
    if link then
        local hex = link:match("|c(%x%x%x%x%x%x%x%x)")
        if hex then
            return {
                tonumber(hex:sub(3, 4), 16) / 255,
                tonumber(hex:sub(5, 6), 16) / 255,
                tonumber(hex:sub(7, 8), 16) / 255,
            }
        end
        local quality = select(3, GetItemInfo(link))
        if quality and GetItemQualityColor then
            local r, g, b = GetItemQualityColor(quality)
            return { r, g, b }
        end
    end
    return COUNTER_VALUE_COLOR
end

-- Likewise the name: taken from the bracketed part of the link when the cache
-- has nothing to give.
local function ItemDisplayName(link)
    if not link then return nil end
    return (GetItemInfo(link)) or link:match("|h%[(.-)%]|h")
end

-- Fit a name into the counter window by shrinking the font until it does. One
-- measure-and-scale pass is enough: string width tracks font size closely
-- enough that a second would move it by less than a pixel.
local function SetCounterName(row, text, color)
    local fontString = row and row.name
    if not fontString then return end
    fontString:SetFont(BODY_FONT_PATH, NAME_FONT_SIZE, "")
    fontString:SetText(text or "")
    fontString:SetTextColor(color[1], color[2], color[3])

    local width = fontString:GetStringWidth() or 0
    if width > NAME_AREA_W and width > 0 then
        local fitted = math.floor(NAME_FONT_SIZE * (NAME_AREA_W / width))
        fontString:SetFont(BODY_FONT_PATH, math.max(NAME_MIN_FONT_SIZE, fitted), "")
        width = fontString:GetStringWidth() or width
    end

    -- The plate is sized to the text, not to the window, so a short name gets a
    -- small plate rather than a black bar with a word floating in it.
    if row.nameBg then
        row.nameBg:SetWidth(math.min(NAME_AREA_W, math.max(1, width) + (NAME_BACKDROP_PAD * 2)))
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
--
-- Each entry is now one durability-style row: an icon and a counter, no text
-- label. The icon is what says which stat it is, so it has to read at a glance
-- -- dust for gear worn away to nothing, a sundered shield for gear destroyed
-- outright, a bloodied skull for deaths. What each row counts is spelled out in
-- its tooltip.
--
-- The best-item row is the same widget with two differences: it borrows the icon
-- of whatever item the character actually lost, and the number it shows is that
-- item's level rather than a tally.
local ALL_COUNTERS = {
    {
        key = "rusted", setting = "statShowRusted", colorTier = 1,
        icon = "Interface\\Icons\\INV_Enchant_DustStrange",
        -- Strange dust is a pale, glittery icon that read as a bright patch
        -- against the rest of the column. Shaded harder than the default rather
        -- than lifted, so it settles back into the panel.
        iconShade = 0.4,
        title = "Rusted",
        tooltip = "Items worn down to zero durability.",
        value = function(stats) return stats.rustedItems or 0 end,
    },
    {
        key = "broken", setting = "statShowBroken", colorTier = 3,
        icon = "Interface\\Icons\\Ability_Warrior_Sunder",
        -- Warmed towards the Shattered orange its counter uses, so the icon and
        -- the number beside it read as the same idea.
        iconColor = { 1, 0.72, 0.42 },
        title = "Broken",
        tooltip = "Items destroyed on death.",
        value = function(stats) return stats.destroyedItems or 0 end,
    },
    {
        key = "deaths", setting = "statShowDeaths", colorTier = 4,
        icon = "Interface\\Icons\\INV_Misc_Bone_Skull_02",
        iconColor = { 0.95, 0.28, 0.24 },
        title = "Deaths",
        tooltip = "Times this character has died.",
        value = function(stats) return stats.deaths or 0 end,
    },
    {
        key = "best", setting = "statShowBestItem", colorTier = 3,
        isBestItem = true,
        -- Wears the item's own icon, the cracked frame the deletion wheel puts
        -- on doomed gear, and the item's name where the other rows have digits.
        broken = true,
        showsName = true,
        icon = "Interface\\Icons\\INV_Misc_QuestionMark",
        title = "Best item lost",
        tooltip = "The highest item level this character has lost.",
        value = function(stats) return stats.bestItemLostIlvl or 0 end,
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

-- Whether the rows carry item icons. Default on: the icons are what the panel
-- looks like now, and the plain counters are the opt-out.
local function IconsShown()
    return Rustcore.GetSetting("statsShowIcons") ~= false
end

local function ActiveVariant()
    return IconsShown() and ICON_ROW or PLAIN_ROW
end

-- Both builds of one counter's row, so callers that update content can write to
-- each and callers that lay out can pick between them.
local function RowPair(counter)
    return statsFrame and statsFrame.rows and statsFrame.rows[counter.key]
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
-- The best-item panel is a row like any other now, so VisibleCounters above is
-- the whole answer and there is no second visibility helper to keep in step
-- with it.

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

-- Write one counter's current value into one built row.
--
-- Runs for both variants of every counter, not just the one on screen. The
-- hidden variant costs a few SetText calls it will not display, and in return
-- toggling the icons is a visibility change with nothing to catch up on.
local function FillRow(counter, row, stats)
    if not row then return end
    -- The best-item row reports one item rather than a tally, so it wears that
    -- item's icon and writes its name where the other rows put digits. The name
    -- is coloured by quality, which is the fastest way to read how big a loss it
    -- was.
    if counter.isBestItem then
        local link = stats.bestItemLostLink
        if row.icon then
            row.icon:SetTexture((link and GetItemIcon(link)) or counter.icon)
        end
        row.itemLink = link
        if row.broken then row.broken:SetShown(link and true or false) end
        SetCounterName(row, ItemDisplayName(link) or "--", ItemRarityColor(link))
    else
        SetCounterDigits(row.digits, counter.value(stats), CounterColor(counter))
    end
end

local function RefreshText()
    if not statsFrame then return end
    local stats = EnsureStatsDB()
    for _, counter in ipairs(ALL_COUNTERS) do
        local pair = RowPair(counter)
        if pair then
            FillRow(counter, pair.icon, stats)
            FillRow(counter, pair.plain, stats)
        end
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

-- Side margins, likewise following the panel.
--
-- These two used to be floors that applied whatever the background was doing --
-- twenty pixels down each side in the horizontal layout, sixteen around the best
-- item -- which were sized to keep graphics off the border art. With no border
-- there is nothing to keep them off, and those floors were the whole reason a
-- panel-less window still sat inside a visible margin.
local function ContentSidePad(horizontal)
    local edge = ContentEdgePad()
    if edge == 0 then return BARE_TEXT_PAD end
    return math.max(horizontal and HORIZONTAL_SIDE_PAD or TEXT_PAD, edge)
end

local function TitlesShown()
    return Rustcore.GetSetting("statsShowTitles") and true or false
end

-- Height of one tile: the row art, plus the band its heading sits in when
-- headings are on. Everything that measures or places a row goes through this,
-- so turning headings on cannot leave one part of the layout using the old
-- height and another the new one.
local function TileHeight()
    return STAT_ROW_H + (TitlesShown() and TITLE_BAND_H or 0)
end

-- Natural size of one tile at scale 1, and the extent the visible rows occupy.
-- Both layouts are the same arithmetic with the axes swapped.
local function NaturalExtent()
    local count = math.max(1, #VisibleCounters())
    local tileH = TileHeight()
    local rowW = ActiveVariant().width
    if Rustcore.GetSetting("statsHorizontalLayout") then
        return (count * rowW) + ((count - 1) * COLUMN_GAP), tileH
    end
    return rowW, (count * tileH) + ((count - 1) * ROW_GAP)
end

-- The rows are fixed art, so instead of re-deriving a size for every element the
-- whole strip is scaled to fit -- one number, and the icon, counter frame and
-- digits all keep their proportions to each other.
local function LayoutScale(width, height)
    local pad = ContentTextPad()
    local sidePad = ContentSidePad(Rustcore.GetSetting("statsHorizontalLayout"))
    local naturalW, naturalH = NaturalExtent()
    local availW = math.max(1, width - (sidePad * 2))
    local availH = math.max(1, height - (pad * 2))
    return Clamp(math.min(availW / naturalW, availH / naturalH),
        MIN_ROW_SCALE, MAX_ROW_SCALE)
end

-- Both floors are the smallest legible row multiplied out along whichever axis
-- the rows are stacked on, plus the margins in force. Derived rather than fixed
-- because the margins move with the panel background and the extent moves with
-- how many counters are switched on: a constant sized for one combination would
-- either clip the rows or refuse to let the window get as narrow as it can.
local function GetMinHeight()
    local _, naturalH = NaturalExtent()
    return math.max(MIN_HEIGHT,
        math.ceil((naturalH * MIN_ROW_SCALE) + (ContentTextPad() * 2)))
end

local function GetMinWidth()
    local naturalW = NaturalExtent()
    local sidePad = ContentSidePad(Rustcore.GetSetting("statsHorizontalLayout"))
    return math.max(MIN_WIDTH,
        math.ceil((naturalW * MIN_ROW_SCALE) + (sidePad * 2)))
end

local function ApplyResizeBounds()
    if not statsFrame then return end
    local minW, minH = GetMinWidth(), GetMinHeight()
    if statsFrame.SetResizeBounds then
        statsFrame:SetResizeBounds(minW, minH, MAX_WIDTH, MAX_HEIGHT)
    elseif statsFrame.SetMinResize and statsFrame.SetMaxResize then
        statsFrame:SetMinResize(minW, minH)
        statsFrame:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
    end
    -- SetResizeBounds only constrains future drags; if the layout mode just
    -- switched to one with a taller minimum, pull an already-too-short frame
    -- back in bounds instead of leaving it stuck below the new floor.
    local w, h = statsFrame:GetSize()
    local clampedW, clampedH = Clamp(w, minW, MAX_WIDTH), Clamp(h, minH, MAX_HEIGHT)
    if clampedW ~= w or clampedH ~= h then
        statsFrame:SetSize(clampedW, clampedH)
    end
end

local function ApplySavedSize(frame)
    local size = Rustcore.GetProfileValue("statsWindowSize")
    local width = size and tonumber(size.width) or DEFAULT_WIDTH
    local height = size and tonumber(size.height) or DEFAULT_HEIGHT
    frame:SetSize(
        Clamp(width, GetMinWidth(), MAX_WIDTH),
        Clamp(height, GetMinHeight(), MAX_HEIGHT)
    )
end

function RustcoreStats.RefreshPosition()
    if not statsFrame then return end
    ApplySavedPosition(statsFrame)
    ApplySavedSize(statsFrame)
    RustcoreStats.RefreshLayout()
end

-- Resize the window to the natural size of whatever rows are showing, at a
-- comfortable scale. Called when the layout or the visible set changes, so the
-- window is never left shaped for a set of rows it no longer has.
function RustcoreStats.ApplyLayoutModeChange()
    if not statsFrame then return end
    local naturalW, naturalH = NaturalExtent()
    local pad = ContentTextPad()
    local sidePad = ContentSidePad(Rustcore.GetSetting("statsHorizontalLayout"))
    local targetW = Clamp(math.ceil((naturalW * DEFAULT_ROW_SCALE) + (sidePad * 2)), GetMinWidth(), MAX_WIDTH)
    local targetH = Clamp(math.ceil((naturalH * DEFAULT_ROW_SCALE) + (pad * 2)), GetMinHeight(), MAX_HEIGHT)
    statsFrame:SetSize(targetW, targetH)
    SaveSize(statsFrame)
    RustcoreStats.RefreshLayout()
end

function RustcoreStats.RefreshLayout()
    if not statsFrame then return end
    ApplyResizeBounds()

    local width, height = statsFrame:GetSize()
    local horizontal = Rustcore.GetSetting("statsHorizontalLayout")
    local pad = ContentTextPad()
    local sidePad = ContentSidePad(horizontal)
    local visible = VisibleCounters()
    local scale = LayoutScale(width, height)

    -- Rows are laid out at scale 1 and then scaled as a group, so every offset
    -- below is in unscaled units and the strip keeps its proportions.
    local titles = TitlesShown()
    local band = titles and TITLE_BAND_H or 0
    local variant = ActiveVariant()
    local rowW, tileH = variant.width, TileHeight()
    local stepX = horizontal and (rowW + COLUMN_GAP) or 0
    local stepY = horizontal and 0 or (tileH + ROW_GAP)
    local count = #visible
    local stripW = horizontal and ((count * rowW) + ((count - 1) * COLUMN_GAP)) or rowW
    local stripH = horizontal and tileH or ((count * tileH) + ((count - 1) * ROW_GAP))

    -- Centred in whatever room is left, so extra window size becomes margin
    -- rather than stretching the art.
    local originX = sidePad + math.max(0, ((width - (sidePad * 2)) - (stripW * scale)) * 0.5)
    local originY = pad + math.max(0, ((height - (pad * 2)) - (stripH * scale)) * 0.5)

    local shownIndex = 0
    for _, counter in ipairs(ALL_COUNTERS) do
        local pair = RowPair(counter)
        if pair then
            local show = false
            for _, entry in ipairs(visible) do
                if entry.key == counter.key then show = true; break end
            end

            -- Only one variant is ever on screen; the other is parked hidden
            -- with its content already up to date.
            local row = (variant == ICON_ROW) and pair.icon or pair.plain
            local other = (variant == ICON_ROW) and pair.plain or pair.icon
            if other then other:Hide() end

            if show then
                row:SetScale(scale)
                row:ClearAllPoints()
                -- Offsets are divided by the scale because SetPoint on a scaled
                -- frame measures in that frame's own units, not the parent's.
                -- The band is added in row units for the same reason: it is
                -- already part of the tile the strip was measured from.
                row:SetPoint("TOPLEFT", statsFrame, "TOPLEFT",
                    (originX + (shownIndex * stepX * scale)) / scale,
                    -((originY + (shownIndex * stepY * scale)) / scale) - band)
                shownIndex = shownIndex + 1
            end
            row:SetShown(show)
            if row.title then row.title:SetShown(show and titles) end
        end
    end
end

local function GetAutoFitWidth()
    if not statsFrame then return DEFAULT_WIDTH end
    local naturalW = NaturalExtent()
    local sidePad = ContentSidePad(Rustcore.GetSetting("statsHorizontalLayout"))
    -- Measured at the scale the window is already using, so auto-fitting the
    -- width does not silently resize the rows as well.
    local _, height = statsFrame:GetSize()
    local scale = LayoutScale(statsFrame:GetWidth(), height)
    return Clamp(math.ceil((naturalW * scale) + (sidePad * 2)), GetMinWidth(), MAX_WIDTH)
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
        f:SetResizeBounds(GetMinWidth(), GetMinHeight(), MAX_WIDTH, MAX_HEIGHT)
    elseif f.SetMinResize and f.SetMaxResize then
        f:SetMinResize(GetMinWidth(), GetMinHeight())
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

    -- Rows are children of this layer so they draw above the panel art. Unlike
    -- the old fixed grid, each row is positioned and scaled individually by
    -- RefreshLayout; this frame exists only to own them and set their level.
    local textLayer = CreateFrame("Frame", nil, f)
    textLayer:SetAllPoints(f)
    textLayer:SetFrameLevel(f:GetFrameLevel() + 3)

    local function BuildDigitSlot(parent, variant, idx)
        -- idx 1 = hundreds, 2 = tens, 3 = ones. Centre measured from the row's
        -- LEFT edge, so the digits track the counter art however the row scales.
        local centerX = math.floor((variant.width * variant.digitCenterX)
            + ((idx - 2) * variant.width * variant.digitSpacing) + 0.5)
            + variant.digitNudge[idx]

        local slot = CreateFrame("Frame", nil, parent)
        -- Explicit level keeps the digits above the counter frame overlay.
        slot:SetFrameLevel(parent:GetFrameLevel() + 5)
        slot:SetSize(variant.slotWidth, DIGIT_SLOT_H)
        slot:SetPoint("CENTER", parent, "LEFT", centerX, 0)
        if slot.SetClipsChildren then slot:SetClipsChildren(true) end
        -- Mouse off so hovering a digit still hits the row behind it.
        slot:EnableMouse(false)

        local function MakeText()
            local fs = slot:CreateFontString(nil, "OVERLAY")
            fs:SetFont(BODY_FONT_PATH, DIGIT_FONT_SIZE, "")
            fs:SetShadowColor(0, 0, 0, 1)
            fs:SetShadowOffset(1, -1)
            fs:SetJustifyH("CENTER")
            fs:SetJustifyV("MIDDLE")
            fs:SetSize(variant.slotWidth, DIGIT_SLOT_H)
            fs:SetPoint("CENTER", slot, "CENTER", 0, 0)
            return fs
        end

        slot.oldText = MakeText()
        slot.newText = MakeText()
        slot.newText:Hide()
        slot.currentValue = nil
        return slot
    end

    -- One stat row in one of its two shapes. The iconic variant puts an item
    -- icon at the left with the counter art wrapped around it; the plain one is
    -- the counter graphic on its own. Everything else -- the digits, the roll,
    -- the tooltip, the heading -- is common to both.
    local function BuildStatRow(counter, variant)
        local row = CreateFrame("Frame", nil, textLayer)
        row:SetSize(variant.width, STAT_ROW_H)

        local icon, brokenHost
        if variant.hasIcon then
            local iconBg = row:CreateTexture(nil, "BACKGROUND")
            iconBg:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
            iconBg:SetPoint("CENTER", row, "LEFT", ICON_CENTER_X, 0)
            iconBg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
            iconBg:SetVertexColor(0, 0, 0, 1)

            icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
            icon:SetPoint("CENTER", row, "LEFT", ICON_CENTER_X, 0)
            -- Cropped slightly to drop the icon's own border artifact, matching
            -- the durability HUD.
            icon:SetTexCoord(ICON_INSET, 1 - ICON_INSET, ICON_INSET, 1 - ICON_INSET)
            icon:SetTexture(counter.icon)
            -- Broken is warmed towards the orange its counter uses; deaths is
            -- pushed red, the game having no red skull of its own at icon size.
            if counter.iconColor then
                icon:SetVertexColor(counter.iconColor[1], counter.iconColor[2], counter.iconColor[3])
            end

            -- A touch of shade so the icon reads as sitting inside the frame
            -- rather than pasted on top of it. A row can ask for more when its
            -- art is brighter than the column around it, or none when it is
            -- already dark enough.
            local shade = counter.iconShade or ICON_SHADE_ALPHA
            if shade > 0 then
                local shadow = row:CreateTexture(nil, "OVERLAY")
                shadow:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
                shadow:SetPoint("CENTER", row, "LEFT", ICON_CENTER_X, 0)
                shadow:SetColorTexture(0, 0, 0, shade)
            end

            -- The cracked frame doomed gear wears on the deletion wheel. Level
            -- +3, below the counter art, so the art still frames it -- the same
            -- arrangement the durability HUD uses for its rust overlay.
            if counter.broken then
                brokenHost = CreateFrame("Frame", nil, row)
                brokenHost:SetSize(BROKEN_OVERLAY_SIZE, BROKEN_OVERLAY_SIZE)
                brokenHost:SetPoint("CENTER", row, "LEFT", ICON_CENTER_X, 0)
                brokenHost:SetFrameLevel(row:GetFrameLevel() + 3)
                brokenHost:EnableMouse(false)
                local brokenTex = brokenHost:CreateTexture(nil, "OVERLAY")
                brokenTex:SetAllPoints(brokenHost)
                brokenTex:SetTexture(Rustcore.GetAssetPath("UI/Brokenframe copy.tga"))
                brokenHost:Hide()
            end
        end

        -- The counter art gets its own frame because the iconic variant's art
        -- has a cutout window over the icon, so it has to draw above the icon
        -- itself and not merely above the row background. The plain variant has
        -- nothing to draw over, but shares the arrangement rather than growing
        -- a second code path for the sake of one texture.
        local overlayHost = CreateFrame("Frame", nil, row)
        overlayHost:SetSize(variant.width, variant.artHeight or STAT_ROW_H)
        overlayHost:SetPoint("CENTER", row, "CENTER", 0, 0)
        overlayHost:SetFrameLevel(row:GetFrameLevel() + 4)
        overlayHost:EnableMouse(false)
        local overlayTex = overlayHost:CreateTexture(nil, "OVERLAY")
        overlayTex:SetAllPoints(overlayHost)
        overlayTex:SetTexture(Rustcore.GetAssetPath(variant.art))

        -- A row shows either three rolling digits or one name, never both.
        local digits, name, nameBg
        if counter.showsName then
            local nameHost = CreateFrame("Frame", nil, row)
            nameHost:SetSize(NAME_AREA_W, DIGIT_SLOT_H + 2)
            nameHost:SetPoint("CENTER", row, "LEFT", variant.nameCenterX, 0)
            nameHost:SetFrameLevel(row:GetFrameLevel() + 5)
            -- Clips whatever is left after the shrink-to-fit pass gives up.
            if nameHost.SetClipsChildren then nameHost:SetClipsChildren(true) end
            nameHost:EnableMouse(false)

            -- Sized to the text by SetCounterName, so a short name gets a small
            -- plate rather than a black bar with a word floating in it.
            nameBg = nameHost:CreateTexture(nil, "BACKGROUND")
            nameBg:SetHeight(DIGIT_SLOT_H)
            nameBg:SetPoint("CENTER", nameHost, "CENTER", 0, 0)
            nameBg:SetColorTexture(NAME_BACKDROP_COLOR[1], NAME_BACKDROP_COLOR[2],
                NAME_BACKDROP_COLOR[3], NAME_BACKDROP_COLOR[4])

            name = nameHost:CreateFontString(nil, "OVERLAY")
            name:SetFont(BODY_FONT_PATH, NAME_FONT_SIZE, "")
            name:SetShadowColor(0, 0, 0, 1)
            name:SetShadowOffset(1, -1)
            name:SetJustifyH("CENTER")
            name:SetJustifyV("MIDDLE")
            name:SetWordWrap(false)
            name:SetPoint("CENTER", nameHost, "CENTER", 0, 0)
        else
            digits = {}
            for i = 1, 3 do
                digits[i] = BuildDigitSlot(row, variant, i)
            end
        end

        -- Rows cover nearly the whole window, so they have to forward dragging
        -- and the right-click to the panel or there would be nowhere left to
        -- grab it by.
        row:EnableMouse(true)
        row:RegisterForDrag("LeftButton")
        row:SetScript("OnDragStart", function() f:StartMoving() end)
        row:SetScript("OnDragStop", function()
            f:StopMovingOrSizing()
            SavePosition(f)
        end)
        row:SetScript("OnMouseUp", function(_, button)
            if button == "RightButton" then
                RustcoreOptions.Toggle()
            end
        end)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR", 0, -32)
            -- The best-item row shows the item itself when it has one: the row
            -- is already naming that item, so the item is the answer to "what
            -- am I looking at?".
            if self.itemLink then
                GameTooltip:SetHyperlink(self.itemLink)
            else
                GameTooltip:AddLine(counter.title, 1, 0.82, 0)
                GameTooltip:AddLine(counter.tooltip, 0.8, 0.8, 0.8, true)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Sits in the band RefreshLayout reserved above the row. A child of the
        -- row rather than of the panel, so it scales, moves and hides with it.
        local title = row:CreateFontString(nil, "OVERLAY")
        title:SetFont(BODY_FONT_PATH, TITLE_FONT_SIZE, "")
        title:SetShadowColor(0, 0, 0, 1)
        title:SetShadowOffset(TITLE_SHADOW_OFFSET, -TITLE_SHADOW_OFFSET)
        title:SetJustifyH("CENTER")
        title:SetWordWrap(false)
        title:SetTextColor(TITLE_COLOR[1], TITLE_COLOR[2], TITLE_COLOR[3])
        title:SetText(counter.title)
        title:SetPoint("BOTTOM", row, "TOP", 0, 1)
        title:Hide()

        row.icon = icon
        row.digits = digits
        row.name = name
        row.nameBg = nameBg
        row.broken = brokenHost
        row.title = title
        -- RefreshLayout decides which variant is on screen; until then neither
        -- is, so a row that is never shown cannot flash on the first frame.
        row:Hide()
        return row
    end

    f.rows = {}
    for _, counter in ipairs(ALL_COUNTERS) do
        f.rows[counter.key] = {
            icon = BuildStatRow(counter, ICON_ROW),
            plain = BuildStatRow(counter, PLAIN_ROW),
        }
    end

    local resizeGrip = CreateFrame("Button", nil, f)
    resizeGrip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    resizeGrip:SetSize(16, 16)
    -- Clear of the rows and everything inside them: a column of rows covers the
    -- bottom-right corner, and at a tied frame level the grip would lose the
    -- click to whichever row happened to be under the cursor.
    resizeGrip:SetFrameLevel(f:GetFrameLevel() + 11)
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
    resizeHotspot:SetFrameLevel(f:GetFrameLevel() + 10)
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
