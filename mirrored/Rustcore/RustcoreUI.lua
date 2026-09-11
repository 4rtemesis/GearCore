-- Rustcore: Deletion confirmation UI
-- Shows a wheel-of-fortune spin animation for each item marked for deletion.
-- Core deletion logic (ExecuteDeletion, monitors, etc.) is preserved unchanged.

RustcoreUI = {}


local deleteFrame
local pendingItems = {}
local awaitingConfirmation = false
local cursorArmed = false
local processingTicker
local statusUpdateTicker
local savedBtnX, savedBtnY
local frameBottomAnchorX, frameBottomAnchorY
local minimizedDeleteBtnAnchorX, minimizedDeleteBtnAnchorY
local activeSpinIcons
local GetDeletePopupFrame
local FinishQueue
local ShowActiveFrame
local GetTrackedItemState
local RemoveFirstPendingItem
local RefreshButtonState
local ResolveProcessingState
local BeginProcessingMonitor
local ResolveDeletionWithRetry
local PopulateSpinUI
local ClearSpinRows
local LinksMatch
local spinCompleteCallback

local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil
local TITLE_FONT_PATH = Rustcore.GetAssetPath("Font/RUSTED PERSONAL USE.ttf")
local BODY_FONT_PATH = Rustcore.GetAssetPath("Font/BPpong.otf")
local TITLE_COLOR = { 0.76, 0.19, 0.17 }
local ICON_TEX_INSET = 0.10
local ICON_IMAGE_SIZE = 32
local ICON_BORDER_SIZE = 60
local COMPACT_ICON_BG_SIZE = ICON_IMAGE_SIZE - 2
local ICON_Y_OFFSET = 0
local COMPACT_CELL_GAP = 6
local COMPACT_FRAME_MIN_WIDTH = 280
local COMPACT_FRAME_MIN_HEIGHT = 250
local BROKEN_BORDER_SIZE = 36

local function ApplyBodyFont(fontString, size)
    if not fontString then return end
    fontString:SetFont(BODY_FONT_PATH, math.max(10, (size or 18) - 2), "")
end

local function SetTexGradientAlpha(tex, orient, r1,g1,b1,a1, r2,g2,b2,a2)
    if tex.SetGradientAlpha then
        tex:SetGradientAlpha(orient, r1,g1,b1,a1, r2,g2,b2,a2)
    elseif tex.SetGradient and CreateColor then
        tex:SetGradient(orient, CreateColor(r1,g1,b1,a1), CreateColor(r2,g2,b2,a2))
    end
end

-- ── Slot → texture lookup ─────────────────────────────────────────────────────

local SLOT_NAMES = {
    [1]="HeadSlot",[2]="NeckSlot",[3]="ShoulderSlot",[5]="ChestSlot",
    [6]="WaistSlot",[7]="LegsSlot",[8]="FeetSlot",[9]="Wrist​Slot",
    [10]="HandsSlot",[11]="Finger0Slot",[12]="Finger1Slot",
    [13]="Trinket0Slot",[14]="Trinket1Slot",[15]="BackSlot",
    [16]="MainHandSlot",[17]="SecondaryHandSlot",[18]="RangedSlot",
}
local ALL_SLOTS = { 1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18 }

local ICON_SIZE   = 38
local ICON_GAP    = 5
local WHEEL_FRAME_STRIP_W = (40 * 9) + (ICON_GAP * 8) - 8
local STRIP_W     = (ICON_SIZE * 9) + (ICON_GAP * 8)   -- visible strip width
local STRIP_H     = ICON_SIZE
local ROW_SPACING = 10    -- vertical gap between rows
local FADE_W      = 88    -- width of each fade gradient on edges
local MAX_ROWS_PER_COLUMN = 9
local COLUMN_SPACING = 20
local CENTER_ICON_OFFSET_X = 0
local WHEEL_FRAME_TEXTURE = "Wheel frame5 copy.tga"
local function RoundPixel(value) return math.floor(value + 0.5) end
local WHEEL_FRAME_SOURCE_W = 1899
local WHEEL_FRAME_SOURCE_H = 330
local WHEEL_FRAME_SOURCE_PAD_LEFT = 45
local WHEEL_FRAME_SOURCE_PAD_RIGHT = 45
local WHEEL_FRAME_PAD_TOP = 104
local WHEEL_FRAME_SCALE = WHEEL_FRAME_STRIP_W / (WHEEL_FRAME_SOURCE_W - WHEEL_FRAME_SOURCE_PAD_LEFT - WHEEL_FRAME_SOURCE_PAD_RIGHT)
local WHEEL_FRAME_W = RoundPixel(WHEEL_FRAME_SOURCE_W * WHEEL_FRAME_SCALE)
local WHEEL_FRAME_H = RoundPixel(WHEEL_FRAME_SOURCE_H * WHEEL_FRAME_SCALE)
local WHEEL_FRAME_ICON_X = RoundPixel((WHEEL_FRAME_SOURCE_PAD_LEFT * WHEEL_FRAME_SCALE) + ((WHEEL_FRAME_STRIP_W - STRIP_W) / 2))
local WHEEL_FRAME_ICON_Y = RoundPixel(WHEEL_FRAME_PAD_TOP * WHEEL_FRAME_SCALE) + 2
local WHEEL_FRAME_TOP_OFFSET = -108

local function RunSpinCompleteCallback(delay)
    if not spinCompleteCallback then return end
    local callback = spinCompleteCallback
    spinCompleteCallback = nil
    if delay and delay > 0 then
        C_Timer.After(delay, callback)
    else
        callback()
    end
end

-- Collect all currently equipped item textures (for the icon strip)
local function GetEquippedIconList()
    local icons = {}
    for _, slotId in ipairs(ALL_SLOTS) do
        local tex = GetInventoryItemTexture("player", slotId)
        if tex then
            icons[#icons+1] = { tex = tex, slot = slotId }
        end
    end
    -- Need at least enough icons to fill the strip; duplicate the list if short
    local step = ICON_SIZE + ICON_GAP
    local needed = math.ceil(STRIP_W / step) + 4
    while #icons < needed do
        for _, v in ipairs(icons) do
            icons[#icons+1] = v
            if #icons >= needed then break end
        end
        if #icons == 0 then break end
    end
    return icons
end

local function GetDisplayTexture(item)
    if not item then return "Interface\\Icons\\INV_Misc_QuestionMark" end
    return item.tex or (item.link and GetItemIcon(item.link)) or GetInventoryItemTexture("player", item.slot) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function BuildIconListFromItems(items)
    local icons = {}
    for _, item in ipairs(items or {}) do
        local tex = GetDisplayTexture(item)
        if tex then
            icons[#icons + 1] = {
                tex = tex,
                slot = item.slot,
                link = item.link,
                name = item.name,
            }
        end
    end

    local step = ICON_SIZE + ICON_GAP
    local needed = math.ceil(STRIP_W / step) + 4
    while #icons > 0 and #icons < needed do
        local baseCount = #icons
        for i = 1, baseCount do
            icons[#icons + 1] = icons[i]
            if #icons >= needed then break end
        end
    end

    return icons
end

local function GetItemKeyFromLink(link)
    if not link then return nil end
    return link:match("|Hitem:([^|]+)|h") or link:match("item:([^|%]]+)") or link
end

LinksMatch = function(linkA, linkB)
    local keyA = GetItemKeyFromLink(linkA)
    local keyB = GetItemKeyFromLink(linkB)
    return keyA ~= nil and keyA == keyB
end

-- ── Spin row construction ─────────────────────────────────────────────────────

-- Each pending item gets one spin row. The row contains:
--   • a wheel frame texture behind the animation
--   • a clip frame (masks the strip to STRIP_W wide)
--   • inside: many icon textures arranged left-to-right

local function BuildSpinRow(parent, xOffset, yOffset, targetSlot, targetTex, targetLink, allIcons, chosenIndex)
    local step = ICON_SIZE + ICON_GAP

    -- Container for the whole row (wheel frame + strip)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(WHEEL_FRAME_W, WHEEL_FRAME_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, yOffset)

    local wheelFrame = row:CreateTexture(nil, "BACKGROUND")
    wheelFrame:SetAllPoints(row)
    wheelFrame:SetTexture(Rustcore.GetAssetPath("UI/" .. WHEEL_FRAME_TEXTURE))
    wheelFrame:SetTexCoord(0, 1, 0, 1)

    -- Clip frame (hides icons outside the strip)
    local clip = CreateFrame("Frame", nil, row)
    clip:SetSize(STRIP_W, STRIP_H)
    clip:SetPoint("TOPLEFT", row, "TOPLEFT", WHEEL_FRAME_ICON_X, -WHEEL_FRAME_ICON_Y)
    clip:SetClipsChildren(true)

    local clipBg = clip:CreateTexture(nil, "BACKGROUND")
    clipBg:SetAllPoints(clip)
    clipBg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    clipBg:SetVertexColor(0, 0, 0, 0)

    local selectedOverlay = clip:CreateTexture(nil, "OVERLAY")
    selectedOverlay:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
    selectedOverlay:SetPoint("CENTER", clip, "CENTER", CENTER_ICON_OFFSET_X, 0)
    selectedOverlay:SetTexCoord(ICON_TEX_INSET, 1 - ICON_TEX_INSET, ICON_TEX_INSET, 1 - ICON_TEX_INSET)
    selectedOverlay:SetVertexColor(1, 0.15, 0.15, 1)
    selectedOverlay:Hide()

    local selectedOverlayBorder = CreateFrame("Frame", nil, clip)
    selectedOverlayBorder:SetSize(BROKEN_BORDER_SIZE, BROKEN_BORDER_SIZE)
    selectedOverlayBorder:SetPoint("CENTER", selectedOverlay, "CENTER", 0, 0)
    selectedOverlayBorder:SetFrameLevel(clip:GetFrameLevel() + 8)
    selectedOverlayBorder.tex = selectedOverlayBorder:CreateTexture(nil, "OVERLAY")
    selectedOverlayBorder.tex:SetAllPoints(selectedOverlayBorder)
    selectedOverlayBorder.tex:SetTexture(Rustcore.GetAssetPath("UI/Brokenframe copy.tga"))
    selectedOverlayBorder:Hide()
    selectedOverlayBorder:EnableMouse(true)
    selectedOverlayBorder:SetScript("OnEnter", function(self)
        if self:IsShown() and targetLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(targetLink)
            GameTooltip:Show()
        end
    end)
    selectedOverlayBorder:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Build icon pool inside clip: enough to wrap seamlessly
    local totalIcons = #allIcons
    -- Ensure every icon has at least one frame, plus overflow for smooth wrap
    local visCount = math.max(math.ceil(STRIP_W / step) + 6, totalIcons + 2)
    local iconFrames = {}
    for i = 1, visCount do
        local ic = clip:CreateTexture(nil, "ARTWORK")
        ic:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
        local src = allIcons[((i-1) % totalIcons) + 1]
        ic:SetTexture(src.tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        ic:SetTexCoord(ICON_TEX_INSET, 1 - ICON_TEX_INSET, ICON_TEX_INSET, 1 - ICON_TEX_INSET)
        ic:SetPoint("LEFT", clip, "LEFT", (i-1)*step + ((ICON_SIZE - ICON_IMAGE_SIZE) / 2), ICON_Y_OFFSET)
        local border = clip:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        border:SetSize(ICON_BORDER_SIZE, ICON_BORDER_SIZE)
        border:SetPoint("CENTER", ic, "CENTER", 0, 0)
        iconFrames[i] = { tex = ic, border = border, srcIdx = ((i-1) % totalIcons) + 1 }
    end

    -- Edge shadows are created after icons/borders so they sit above both layers.
    local fadeL = clip:CreateTexture(nil, "OVERLAY")
    if fadeL.SetDrawLayer then fadeL:SetDrawLayer("OVERLAY", 7) end
    fadeL:SetSize(FADE_W, STRIP_H)
    fadeL:SetPoint("LEFT", clip, "LEFT", 0, 0)
    fadeL:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    SetTexGradientAlpha(fadeL, "HORIZONTAL", 0,0,0,0.98, 0,0,0,0)

    local fadeR = clip:CreateTexture(nil, "OVERLAY")
    if fadeR.SetDrawLayer then fadeR:SetDrawLayer("OVERLAY", 7) end
    fadeR:SetSize(FADE_W, STRIP_H)
    fadeR:SetPoint("RIGHT", clip, "RIGHT", 0, 0)
    fadeR:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    SetTexGradientAlpha(fadeR, "HORIZONTAL", 0,0,0,0, 0,0,0,0.98)

    row.clip        = clip
    row.selectedOverlay = selectedOverlay
    row.selectedOverlayBorder = selectedOverlayBorder
    row.iconFrames  = iconFrames
    row.allIcons    = allIcons
    row.totalIcons  = totalIcons
    row.step        = step
    row.visCount    = visCount
    row.offset      = 0      -- current scroll offset in pixels
    row.spinning    = false
    row.done        = false
    row.targetSlot  = targetSlot
    row.targetTex   = targetTex
    row.targetLink  = targetLink
    row.chosenIndex = chosenIndex  -- index in allIcons[] of the chosen item

    return row
end

local function QueueCenterHighlight(row, playSound)
    C_Timer.After(0, function()
        if not row or not row.selectedOverlay then return end
        if row.selectedOverlayBorder then row.selectedOverlayBorder:Show() end
        if playSound then
            PlaySoundFile(Rustcore.GetAssetPath("Audio/cracksound.wav"), "Master")
        end
        if row.isFirst and row.targetTex then
            row.selectedOverlay:SetTexture(row.targetTex)
            row.selectedOverlay:Show()
        else
            row.selectedOverlay:Hide()
        end
    end)
end

-- Reposition all icon frames given current row.offset
local function UpdateRowPositions(row)
    local step = row.step
    local off  = row.offset % (row.totalIcons * step)
    for i, ic in ipairs(row.iconFrames) do
        local x = (i-1)*step - off
        if x < -step then
            x = x + row.totalIcons * step
        end
        local texX = x + ((ICON_SIZE - ICON_IMAGE_SIZE) / 2)
        ic.tex:SetPoint("LEFT", row.clip, "LEFT", texX, ICON_Y_OFFSET)
        if ic.border then
            ic.border:SetPoint("CENTER", ic.tex, "CENTER", 0, 0)
        end

        local logIdx = ((i - 1) % row.totalIcons) + 1
        local src = row.allIcons[logIdx]
        ic.tex:SetTexture(src and src.tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        ic.tex:SetTexCoord(ICON_TEX_INSET, 1 - ICON_TEX_INSET, ICON_TEX_INSET, 1 - ICON_TEX_INSET)
        ic.tex:SetVertexColor(1, 1, 1, 1)
        if ic.border then
            ic.border:SetAlpha(1)
        end
    end
    if row.selectedOverlay then
        row.selectedOverlay:Hide()
    end
    if row.selectedOverlayBorder then
        row.selectedOverlayBorder:Hide()
    end
end

-- Mark the center icon red (the chosen one) once spinning stops.
-- Recomputes positions with the same math as UpdateRowPositions so the result
-- is never stale from a previous SetPoint call.
local function MarkCenterIcon(row)
    if row.selectedOverlayBorder then row.selectedOverlayBorder:Show() end
    if row.selectedOverlay then
        if row.isFirst and row.targetTex then
            row.selectedOverlay:SetTexture(row.targetTex)
            row.selectedOverlay:Show()
        else
            row.selectedOverlay:Hide()
        end
    end
end

-- ── Animation driver ──────────────────────────────────────────────────────────

local function easeInOutCubic(t)
    if t < 0.5 then
        return 4 * t * t * t
    else
        local f = -2 * t + 2
        return 1 - f * f * f / 2
    end
end

-- spinRows: list of row objects
-- onAllDone: callback when every row has settled
local function StartSpinAnimations(spinRows, onAllDone)
    if #spinRows == 0 then
        if onAllDone then onAllDone() end
        return
    end

    local step = (ICON_SIZE + ICON_GAP)
    local totalIcons = spinRows[1].totalIcons

    for idx, row in ipairs(spinRows) do
        local centerTarget = STRIP_W / 2 - ICON_SIZE / 2 - CENTER_ICON_OFFSET_X
        local baseOffset = (row.chosenIndex - 1) * step - centerTarget
        local laps = 3 + idx
        local finalOffset = baseOffset + laps * totalIcons * step

        row.targetOffset = finalOffset
        row.startOffset  = 0
        row.startTime    = GetTime() + 0.2 + (idx - 1) * 0.35
        row.duration     = 4.0
        row.spinning     = true
        row.done         = false
        row.isFirst      = (idx == 1)
        row.soundPlayed  = false
    end

    local doneCount = 0
    local ticker

    local function tickFunc()
        local now = GetTime()
        for _, row in ipairs(spinRows) do
            if row.spinning and not row.soundPlayed and now >= (row.startTime + 0.5) then
                row.soundPlayed = true
                PlaySoundFile(Rustcore.GetAssetPath("Audio/Spinsound.wav"), "Master")
            end
            if row.spinning and not row.done then
                local elapsed = now - row.startTime
                if elapsed < 0 then
                    -- not started yet
                elseif elapsed >= row.duration then
                    row.offset   = row.targetOffset
                    row.done     = true
                    row.spinning = false
                    UpdateRowPositions(row)
                    MarkCenterIcon(row)
                    QueueCenterHighlight(row, true)
                    doneCount = doneCount + 1
                    if doneCount >= #spinRows then
                        ticker:Cancel()
                        if onAllDone then onAllDone() end
                        return
                    end
                else
                    local t        = elapsed / row.duration
                    local progress = easeInOutCubic(t)
                    row.offset = row.startOffset + progress * (row.targetOffset - row.startOffset)
                    UpdateRowPositions(row)
                end
            end
        end
    end

    ticker = C_Timer.NewTicker(0.016, tickFunc)
    return ticker
end

-- ── Main frame construction ───────────────────────────────────────────────────

local function BuildFrame()
    local f = CreateFrame("Frame", "RustcoreDeletionFrame", UIParent, backdropTemplate)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    RustcoreTheme.ApplyFrameSkin(f)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -26)
    title:SetFont(TITLE_FONT_PATH, 30, "")
    title:SetTextColor(unpack(TITLE_COLOR))
    title:SetShadowColor(0, 0, 0, 0.6)
    title:SetShadowOffset(1, -1)
    title:SetText("Broken")
    f.title = title

    local bgShade = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    bgShade:SetAllPoints(f.rustcoreThemeBackground)
    bgShade:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    bgShade:SetVertexColor(0, 0, 0, 0.62)

    local subLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    subLabel:SetPoint("TOP", title, "BOTTOM", 0, -10)
    subLabel:SetWidth(240)
    subLabel:SetJustifyH("CENTER")
    subLabel:SetWordWrap(true)
    subLabel:SetText("")
    ApplyBodyFont(subLabel, 18)
    f.subLabel = subLabel

    -- Container for spin rows, anchored below subLabel
    local rowContainer = CreateFrame("Frame", nil, f)
    rowContainer:SetPoint("TOPLEFT", f, "TOPLEFT", 28, -82)
    rowContainer:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -82)
    f.rowContainer = rowContainer

    local minimizeBtn = CreateFrame("Button", nil, f)
    minimizeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -6)
    minimizeBtn:SetFrameLevel(f:GetFrameLevel() + 10)
    minimizeBtn:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        if parent.deleteBtn then
            minimizedDeleteBtnAnchorX, minimizedDeleteBtnAnchorY = parent.deleteBtn:GetCenter()
        end
        parent.isMinimized = not parent.isMinimized
        if #pendingItems > 0 then
            PopulateSpinUI(pendingItems, true)
            RefreshButtonState()
        end
    end)
    RustcoreTheme.SkinMinimizeButton(minimizeBtn)
    f.minimizeBtn = minimizeBtn

    -- Status message shown while dead
    local statusMsg = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusMsg:SetTextColor(1, 0.8, 0)
    statusMsg:SetText("Resurrect to begin deleting items")
    ApplyBodyFont(statusMsg, 16)
    f.statusMsg = statusMsg

    -- Delete button (plain frame — no UIPanelButtonTemplate so its built-in textures don't bleed through)
    local btn = CreateFrame("Button", "RustcoreDeletionButton", f)
    btn:SetSize(150, 56)
    local btnLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btnLabel:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn:SetFontString(btnLabel)
    btn:SetScript("OnClick", RustcoreUI.ExecuteDeletion)
    RustcoreTheme.SkinDeleteButton(btn)
    f.deleteBtn = btn
    btn:Hide()

    f.spinRows   = {}
    f.compactIcons = {}
    f.spinTicker = nil
    f.isMinimized = false

    f:Hide()
    return f
end

local function EnsureFrame()
    if not deleteFrame then deleteFrame = BuildFrame() end
    return deleteFrame
end

function RustcoreUI.GetDeleteFrame()
    return deleteFrame
end

-- ── Spin UI population ────────────────────────────────────────────────────────

ClearSpinRows = function()
    local f = EnsureFrame()
    if f.spinTicker then
        f.spinTicker:Cancel()
        f.spinTicker = nil
    end
    for _, row in ipairs(f.spinRows) do
        row:Hide()
        row:SetParent(nil)
    end
    wipe(f.spinRows)
    for _, iconFrame in ipairs(f.compactIcons or {}) do
        if iconFrame.fallTimer  then iconFrame.fallTimer:Cancel();  iconFrame.fallTimer  = nil end
        if iconFrame.fallTicker then iconFrame.fallTicker:Cancel(); iconFrame.fallTicker = nil end
        iconFrame:Hide()
        iconFrame:SetParent(nil)
    end
    wipe(f.compactIcons)
end

local function SnapRowToFinal(row, isFirstRow)
    local centerTarget = STRIP_W / 2 - ICON_SIZE / 2 - CENTER_ICON_OFFSET_X
    row.offset = (row.chosenIndex - 1) * row.step - centerTarget
    row.isFirst = isFirstRow
    UpdateRowPositions(row)
    MarkCenterIcon(row)
    QueueCenterHighlight(row)
end

PopulateSpinUI = function(items, skipAnim)
    local f = EnsureFrame()
    ClearSpinRows()

    if f.isMinimized then
        local itemCount = #items
        local columns = math.max(1, math.ceil(itemCount / MAX_ROWS_PER_COLUMN))
        local rowsPerColumn = math.ceil(itemCount / columns)
        local rowsInTallestColumn = math.min(itemCount, rowsPerColumn)
        local totalW = columns * ICON_SIZE + (columns - 1) * COMPACT_CELL_GAP
        local totalH = rowsInTallestColumn * ICON_SIZE + math.max(0, rowsInTallestColumn - 1) * COMPACT_CELL_GAP
        local frameW = math.max(totalW + 86, COMPACT_FRAME_MIN_WIDTH)
        local frameH = math.max(totalH + 250, COMPACT_FRAME_MIN_HEIGHT)

        f:SetSize(frameW, frameH)
        f:ClearAllPoints()
        if minimizedDeleteBtnAnchorX and minimizedDeleteBtnAnchorY then
            local _, buttonH = f.deleteBtn:GetSize()
            f:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", minimizedDeleteBtnAnchorX, minimizedDeleteBtnAnchorY - 36 - (buttonH / 2))
        elseif frameBottomAnchorX then
            f:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", frameBottomAnchorX, frameBottomAnchorY)
        else
            f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end

        f.rowContainer:ClearAllPoints()
        f.rowContainer:SetPoint("TOP", f.subLabel or f, "BOTTOM", 0, -14)
        f.rowContainer:SetWidth(totalW)
        f.rowContainer:SetHeight(totalH)

        for i, item in ipairs(items) do
            local columnIndex = math.floor((i - 1) / rowsPerColumn)
            local rowIndex = (i - 1) % rowsPerColumn
            local xOff = columnIndex * (ICON_SIZE + COMPACT_CELL_GAP)
            local yOff = -(rowIndex * (ICON_SIZE + COMPACT_CELL_GAP))

            local cell = CreateFrame("Frame", nil, f.rowContainer)
            cell:SetSize(ICON_SIZE, ICON_SIZE)
            cell:SetPoint("TOPLEFT", f.rowContainer, "TOPLEFT", xOff, yOff)
            cell._fallX    = xOff
            cell._fallY    = yOff
            cell._itemLink = item.link

            cell:EnableMouse(true)
            cell:SetScript("OnEnter", function(self)
                if self._itemLink and self._brokenBorder and self._brokenBorder:IsShown() then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetHyperlink(self._itemLink)
                    GameTooltip:Show()
                end
            end)
            cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

            local bg = cell:CreateTexture(nil, "BACKGROUND")
            bg:SetSize(COMPACT_ICON_BG_SIZE, COMPACT_ICON_BG_SIZE)
            bg:SetPoint("CENTER", cell, "CENTER", 0, 0)
            bg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
            bg:SetVertexColor(0, 0, 0, 1)

            local icon = cell:CreateTexture(nil, "ARTWORK")
            icon:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
            icon:SetPoint("CENTER", cell, "CENTER", 0, 0)
            icon:SetTexture(GetDisplayTexture(item))
            icon:SetTexCoord(ICON_TEX_INSET, 1 - ICON_TEX_INSET, ICON_TEX_INSET, 1 - ICON_TEX_INSET)

            local redOverlay = cell:CreateTexture(nil, "OVERLAY")
            redOverlay:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
            redOverlay:SetPoint("CENTER", cell, "CENTER", 0, 0)
            redOverlay:SetTexture(GetDisplayTexture(item))
            redOverlay:SetTexCoord(ICON_TEX_INSET, 1 - ICON_TEX_INSET, ICON_TEX_INSET, 1 - ICON_TEX_INSET)
            redOverlay:SetVertexColor(1, 0.15, 0.15, 1)
            redOverlay:SetShown(i == 1)

            local brokenBorder = CreateFrame("Frame", nil, cell)
            brokenBorder:SetSize(BROKEN_BORDER_SIZE, BROKEN_BORDER_SIZE)
            brokenBorder:SetPoint("CENTER", cell, "CENTER", 0, 0)
            brokenBorder:SetFrameLevel(cell:GetFrameLevel() + 4)
            brokenBorder.tex = brokenBorder:CreateTexture(nil, "OVERLAY")
            brokenBorder.tex:SetAllPoints(brokenBorder)
            brokenBorder.tex:SetTexture(Rustcore.GetAssetPath("UI/Brokenframe copy.tga"))
            brokenBorder:Hide()
            cell._brokenBorder = brokenBorder

            local border = CreateFrame("Frame", nil, cell)
            border:SetSize(ICON_BORDER_SIZE, ICON_BORDER_SIZE)
            border:SetPoint("CENTER", cell, "CENTER", 0, 0)
            border:SetFrameLevel(cell:GetFrameLevel() + 5)
            border.tex = border:CreateTexture(nil, "OVERLAY")
            border.tex:SetAllPoints(border)
            border.tex:SetTexture("Interface\\Buttons\\UI-Quickslot2")

            cell:Show()
            f.compactIcons[#f.compactIcons + 1] = cell
        end

        if not skipAnim then
            -- shuffle fall order so each icon lands at a random time
            local fallOrder = {}
            for i = 1, itemCount do fallOrder[i] = i end
            for i = itemCount, 2, -1 do
                local j = math.random(1, i)
                fallOrder[i], fallOrder[j] = fallOrder[j], fallOrder[i]
            end

            local FALL_HEIGHT    = 110
            local FALL_DURATION  = 0.22
            local SOUND_LEAD_IN  = 0.1  -- play crash sound this many seconds before landing

            for pos, idx in ipairs(fallOrder) do
                local cell  = f.compactIcons[idx]
                local cxOff = cell._fallX
                local cyOff = cell._fallY
                local startY = cyOff + FALL_HEIGHT

                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", f.rowContainer, "TOPLEFT", cxOff, startY)
                cell:SetAlpha(0)

                local delay = math.max((pos - 1) * 0.3, 0.016)
                cell.fallTimer = C_Timer.NewTicker(delay, function(self)
                    self:Cancel()
                    cell.fallTimer = nil
                    if not cell:GetParent() then return end
                    cell:SetAlpha(1)
                    local t0 = GetTime()
                    local soundPlayed = false
                    cell.fallTicker = C_Timer.NewTicker(0.016, function(ticker)
                        if not cell:GetParent() then ticker:Cancel(); return end
                        local elapsed = GetTime() - t0
                        if not soundPlayed and elapsed >= FALL_DURATION - SOUND_LEAD_IN then
                            soundPlayed = true
                            PlaySoundFile(Rustcore.GetAssetPath("Audio/crash" .. math.random(1, 5) .. ".wav"), "Master")
                        end
                        if elapsed >= FALL_DURATION then
                            ticker:Cancel()
                            cell.fallTicker = nil
                            cell:ClearAllPoints()
                            cell:SetPoint("TOPLEFT", f.rowContainer, "TOPLEFT", cxOff, cyOff)
                            if cell._brokenBorder then cell._brokenBorder:Show() end
                            return
                        end
                        local t = elapsed / FALL_DURATION
                        cell:ClearAllPoints()
                        cell:SetPoint("TOPLEFT", f.rowContainer, "TOPLEFT", cxOff, startY + (cyOff - startY) * (t * t))
                    end)
                end, 1)
            end
        end

        if skipAnim then
            for _, c in ipairs(f.compactIcons) do
                if c._brokenBorder then c._brokenBorder:Show() end
            end
        end

        f.deleteBtn:ClearAllPoints()
        f.deleteBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 36)
        RefreshButtonState()
        RunSpinCompleteCallback(4)
        return
    end

    local allIcons = activeSpinIcons or GetEquippedIconList()
    if #allIcons == 0 then return end

    local rowH   = WHEEL_FRAME_H
    local itemCount = #items
    local columnCount = math.max(1, math.ceil(itemCount / MAX_ROWS_PER_COLUMN))
    local rowsPerColumn = math.ceil(itemCount / columnCount)
    local rowsInTallestColumn = math.min(itemCount, rowsPerColumn)
    local totalH = rowsInTallestColumn * (rowH + ROW_SPACING) - ROW_SPACING
    local totalW = columnCount * WHEEL_FRAME_W + (columnCount - 1) * COLUMN_SPACING
    local frameH = totalH + 230

    f:SetSize(totalW + 60, frameH)
    f:ClearAllPoints()
    if minimizedDeleteBtnAnchorX and minimizedDeleteBtnAnchorY then
        local _, buttonH = f.deleteBtn:GetSize()
        f:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", minimizedDeleteBtnAnchorX, minimizedDeleteBtnAnchorY - 36 - (buttonH / 2))
    elseif frameBottomAnchorX then
        f:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", frameBottomAnchorX, frameBottomAnchorY)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    f.rowContainer:ClearAllPoints()
    f.rowContainer:SetPoint("TOPLEFT", f, "TOPLEFT", 28, WHEEL_FRAME_TOP_OFFSET)
    f.rowContainer:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, WHEEL_FRAME_TOP_OFFSET)
    f.rowContainer:SetWidth(totalW)
    f.rowContainer:SetHeight(totalH)

    local spinRows = {}
    for i, item in ipairs(items) do
        local chosenIdx = 1
        local found = false
        for j, ic in ipairs(allIcons) do
            if (ic.link and item.link and LinksMatch(ic.link, item.link)) or ic.slot == item.slot then
                chosenIdx = j
                found = true
                break
            end
        end
        if not found then
            chosenIdx = math.random(#allIcons)
        end

        local columnIndex = math.floor((i - 1) / rowsPerColumn)
        local rowIndex = (i - 1) % rowsPerColumn
        local xOff = columnIndex * (WHEEL_FRAME_W + COLUMN_SPACING)
        local yOff = -(rowIndex * (rowH + ROW_SPACING))
        local tex  = GetDisplayTexture(item)
        local row  = BuildSpinRow(f.rowContainer, xOff, yOff, item.slot, tex, item.link, allIcons, chosenIdx)
        row.isFirst = (i == 1)
        row:Show()
        f.spinRows[i] = row
        spinRows[i]   = row
    end

    f.rowContainer:SetHeight(totalH)
    f.deleteBtn:ClearAllPoints()
    f.deleteBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 36)

    if skipAnim then
        for i, row in ipairs(spinRows) do
            SnapRowToFinal(row, i == 1)
        end
        RefreshButtonState()
    else
        f.spinTicker = StartSpinAnimations(spinRows, function()
            RefreshButtonState()
            RunSpinCompleteCallback()
        end)
    end
end

-- ── Status ticker / button state ──────────────────────────────────────────────

local function StopProcessingTicker()
    if processingTicker then
        processingTicker:Cancel()
        processingTicker = nil
    end
end

local function StopStatusUpdateTicker()
    if statusUpdateTicker then
        statusUpdateTicker:Cancel()
        statusUpdateTicker = nil
    end
end

RefreshButtonState = function()
    local f = EnsureFrame()

    if f.statusMsg then f.statusMsg:Hide() end

    if #pendingItems == 0 then
        f.deleteBtn:Hide()
        return
    end

    if processingTicker or CursorHasItem() or GetDeletePopupFrame() then
        f.deleteBtn:Enable()
        f.deleteBtn:Show()
        return
    end

    f.deleteBtn:SetText("DELETE")
    f.deleteBtn:Enable()
    f.deleteBtn:Show()
end

local function StartStatusUpdateTicker()
    StopStatusUpdateTicker()
    statusUpdateTicker = C_Timer.NewTicker(0.5, RefreshButtonState)
end

local function SyncPendingDeletionDB()
    if #pendingItems > 0 then
        RustcoreDB.pendingDeletion = {}
        RustcoreDB.pendingDeletionOwner = Rustcore.GetCharacterKey and Rustcore.GetCharacterKey() or RustcoreDB.pendingDeletionOwner
        for i, item in ipairs(pendingItems) do
            RustcoreDB.pendingDeletion[i] = { slot=item.slot, link=item.link, name=item.name, tex=item.tex, ilvl=item.ilvl }
        end
    else
        RustcoreDB.pendingDeletion = nil
        RustcoreDB.pendingDeletionOwner = nil
    end
end

local function RestoreFrameVisualState()
    local f = EnsureFrame()
    if RustcoreOptions and RustcoreOptions.Hide then RustcoreOptions.Hide() end

    f:SetParent(UIParent)
    f:SetAlpha(1)
    f:SetScale(1)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:Show()
    f:Raise()

    -- Capture bottom anchor on first show so resizes after deletions stay grounded
    if not frameBottomAnchorX then
        frameBottomAnchorX = f:GetCenter()
        frameBottomAnchorY = f:GetBottom()
    end

    -- Arrange side-by-side with the rusted window if both are open at once
    if RustcoreRusted and RustcoreRusted.LayoutFrames then
        RustcoreRusted.LayoutFrames()
    end

    StartStatusUpdateTicker()
    return f
end

-- ── Popup helper ──────────────────────────────────────────────────────────────

GetDeletePopupFrame = function()
    if StaticPopup_Visible then
        local popup = StaticPopup_Visible("DELETE_ITEM") or StaticPopup_Visible("DELETE_GOOD_ITEM")
        if type(popup) == "string" then return _G[popup] end
        return popup
    end
    return nil
end

local function PositionDeletePopup()
    local popup = GetDeletePopupFrame()
    if not popup then return end

    if not popup.__rustcoreHooked then
        popup.__rustcoreHooked = true
        popup:HookScript("OnHide", function()
            popup.__rustcorePositioned = false
            C_Timer.After(0, ResolveProcessingState)
        end)
    end
    if popup.__rustcorePositioned then return end
    popup.__rustcorePositioned = true

    local bx, by = savedBtnX, savedBtnY
    if not bx or not by then return end

    popup:ClearAllPoints()
    popup:SetPoint("CENTER", UIParent, "BOTTOMLEFT", bx, by)

    C_Timer.After(0, function()
        if not popup:IsShown() then return end
        local btn1 = popup.button1 or _G[(popup:GetName() or "") .. "Button1"]
        if not btn1 then return end
        local b1x, b1y = btn1:GetCenter()
        if not b1x then return end
        popup:ClearAllPoints()
        popup:SetPoint("CENTER", UIParent, "BOTTOMLEFT", 2*bx - b1x, 2*by - b1y)
    end)
end

-- ── Container API wrappers ────────────────────────────────────────────────────

local function BagGetNumSlots(bag)
    if C_Container then return C_Container.GetContainerNumSlots(bag) end
    return GetContainerNumSlots(bag)
end

local function BagGetItemLink(bag, slot)
    if C_Container then return C_Container.GetContainerItemLink(bag, slot) end
    return GetContainerItemLink(bag, slot)
end

local function BagPickupItem(bag, slot)
    if C_Container then
        return C_Container.PickupContainerItem(bag, slot)
    end
    return PickupContainerItem(bag, slot)
end

local function FindEmptyBagSlot()
    for bag = 0, 4 do
        for slot = 1, BagGetNumSlots(bag) do
            if not BagGetItemLink(bag, slot) then return bag, slot end
        end
    end
    return nil, nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

function RustcoreUI.ShowDeletionFrame(items, snapshotItems, skipAnim)
    local sourceItems = {}
    local reuseSpinIcons = (items == pendingItems and activeSpinIcons and #activeSpinIcons > 0)
    for _, item in ipairs(items) do
        sourceItems[#sourceItems + 1] = item
    end

    frameBottomAnchorX, frameBottomAnchorY = nil, nil  -- fresh death: re-center
    minimizedDeleteBtnAnchorX, minimizedDeleteBtnAnchorY = nil, nil
    wipe(pendingItems)
    activeSpinIcons = reuseSpinIcons and activeSpinIcons or BuildIconListFromItems(snapshotItems or sourceItems)
    if #activeSpinIcons == 0 then
        activeSpinIcons = GetEquippedIconList()
    end
    for _, item in ipairs(sourceItems) do
        pendingItems[#pendingItems+1] = {
            slot = item.slot,
            link = item.link,
            name = item.name,
            tex  = GetDisplayTexture(item),
            ilvl = item.ilvl,
        }
    end
    awaitingConfirmation = false
    cursorArmed = false
    SyncPendingDeletionDB()

    local f = EnsureFrame()
    if Rustcore.GetSetting("difficulty") == 5 then
        f.isMinimized = true
    end
    RustcoreTheme.SetDifficultyBackground(f, Rustcore.GetSetting("difficulty"))
    if f.subLabel then
        local src = (RustcoreDB and RustcoreDB.lastDeathSource ~= "") and RustcoreDB.lastDeathSource or "Unknown"
        local count = #pendingItems
        local verb = count == 1 and "item was" or "items were"
        f.subLabel:SetText(count .. " " .. verb .. " broken by " .. src .. ".")
    end

    PopulateSpinUI(pendingItems, skipAnim)
    PlaySoundFile(Rustcore.GetAssetPath("Audio/Metalsound.wav"), "Master")
    RestoreFrameVisualState()
    RefreshButtonState()
end

function RustcoreUI.SetSpinCompleteCallback(callback)
    spinCompleteCallback = callback
end

local function FindItemInBagsByLink(link)
    if not link then return nil, nil end

    for bag = 0, 4 do
        for slot = 1, BagGetNumSlots(bag) do
            local bagLink = BagGetItemLink(bag, slot)
            if bagLink and LinksMatch(bagLink, link) then
                return bag, slot
            end
        end
    end
    return nil, nil
end

FinishQueue = function()
    awaitingConfirmation = false
    cursorArmed = false
    StopProcessingTicker()
    StopStatusUpdateTicker()
    SyncPendingDeletionDB()

    if #pendingItems == 0 then
        activeSpinIcons = nil
        RustcoreDB.pendingDeletionSnapshot = nil
        RustcoreDB.pendingDeletionOwner = nil
        print("|cffff4444Rustcore:|r Deletion complete — all marked items processed.")
        ClearSpinRows()
        if deleteFrame then
            deleteFrame.deleteBtn:Hide()
            deleteFrame:Hide()
        end
        return
    end

    if deleteFrame then
        frameBottomAnchorX = deleteFrame:GetCenter()
        frameBottomAnchorY = deleteFrame:GetBottom()
    end
    PopulateSpinUI(pendingItems, true)
    local f = RestoreFrameVisualState()
    RefreshButtonState()
end

local function CountDestroyedItem(item)
    if RustcoreStats and RustcoreStats.RegisterDestroyedItem then
        RustcoreStats.RegisterDestroyedItem(item)
    end
end

RemoveFirstPendingItem = function(countDestroyed)
    if countDestroyed then
        CountDestroyedItem(pendingItems[1])
    end
    table.remove(pendingItems, 1)
    SyncPendingDeletionDB()
    awaitingConfirmation = false
    cursorArmed = false
    StopProcessingTicker()
    StopStatusUpdateTicker()

    -- Slightly delayed: the deletion has to land on the server and clear the
    -- slot before a sweep counting copies of the item can tell one has gone.
    if RustcoreVerification and RustcoreVerification.DeathLoss
        and RustcoreVerification.DeathLoss.Sweep and C_Timer then
        C_Timer.After(0.5, RustcoreVerification.DeathLoss.Sweep)
    end

    if #pendingItems == 0 then
        activeSpinIcons = nil
        RustcoreDB.pendingDeletionSnapshot = nil
        RustcoreDB.pendingDeletionOwner = nil
        print("|cffff4444Rustcore:|r Deletion complete — all marked items processed.")
        ClearSpinRows()
        if deleteFrame then
            deleteFrame.deleteBtn:Hide()
            deleteFrame:Hide()
        end
        return
    end

    -- Capture current bottom before resize so the delete button stays put
    if deleteFrame then
        frameBottomAnchorX = deleteFrame:GetCenter()
        frameBottomAnchorY = deleteFrame:GetBottom()
    end
    PopulateSpinUI(pendingItems, true)
    local f = EnsureFrame()
    f:Show()
    StartStatusUpdateTicker()
end

GetTrackedItemState = function(item)
    local equippedLink = GetInventoryItemLink("player", item.slot)
    if equippedLink and not LinksMatch(equippedLink, item.link) then
        equippedLink = nil
    end
    local bag, bagSlot = FindItemInBagsByLink(item.link)
    return equippedLink, bag, bagSlot
end

ShowActiveFrame = function()
    local f = RestoreFrameVisualState()
    RefreshButtonState()
end

local function HideProcessingFrame()
    if deleteFrame and deleteFrame.deleteBtn then
        savedBtnX, savedBtnY = deleteFrame.deleteBtn:GetCenter()
        deleteFrame.deleteBtn:Enable()
        deleteFrame.deleteBtn:Show()
    end
end

local function TriggerCursorDeletion(item)
    cursorArmed = false
    awaitingConfirmation = false
    DeleteCursorItem()
    awaitingConfirmation = GetDeletePopupFrame() and true or false
    if awaitingConfirmation then
        PositionDeletePopup()
        BeginProcessingMonitor()
        return
    end
    StopProcessingTicker()
    ResolveDeletionWithRetry(item, 10, 0.1)
end

ResolveDeletionWithRetry = function(item, remaining, delay)
    C_Timer.After(delay or 0.2, function()
        if not pendingItems[1] or pendingItems[1] ~= item then return end
        local equippedRetry, bagRetry = GetTrackedItemState(item)
        if not equippedRetry and not bagRetry then
            cursorArmed = false
            awaitingConfirmation = false
            if CursorHasItem() then
                ClearCursor()
            end
            RemoveFirstPendingItem(true)
            return
        end
        if (remaining or 0) > 0 then
            ResolveDeletionWithRetry(item, remaining - 1, delay)
            return
        end
        cursorArmed = false
        awaitingConfirmation = false
        RefreshButtonState()
        print("|cffff4444Rustcore:|r Item was not deleted. Click again to retry.")
    end)
end

-- ── Processing state machine (unchanged logic) ────────────────────────────────

ResolveProcessingState = function()
    local item = pendingItems[1]
    if not item then FinishQueue(); return end

    if GetDeletePopupFrame() or CursorHasItem() then return end

    StopProcessingTicker()

    local equippedLink, bag = GetTrackedItemState(item)
    if not equippedLink and not bag then
        cursorArmed = false
        awaitingConfirmation = false
        RemoveFirstPendingItem(true)
        return
    end

    ShowActiveFrame()
    ResolveDeletionWithRetry(item, 7, 0.2)
end

local function BeginProcessingMonitor()
    local item = pendingItems[1]
    if not item then FinishQueue(); return end

    StopProcessingTicker()
    HideProcessingFrame()

    local popupWasSeen = false
    processingTicker = C_Timer.NewTicker(0.1, function()
        local popup = GetDeletePopupFrame()
        if popup then
            awaitingConfirmation = true
            if not popupWasSeen then
                popupWasSeen = true
                PositionDeletePopup()
            end
            return
        end
        popupWasSeen = false
        if CursorHasItem() then return end
        ResolveProcessingState()
    end)
end

local function BeginCursorMonitor()
    local item = pendingItems[1]
    if not item then FinishQueue(); return end

    StopProcessingTicker()
    processingTicker = C_Timer.NewTicker(0.1, function()
        if CursorHasItem() then return end
        StopProcessingTicker()
        ShowActiveFrame()

        local equippedLink, bag = GetTrackedItemState(item)
        if not equippedLink and not bag then
            cursorArmed = false
            awaitingConfirmation = false
            RemoveFirstPendingItem()
            return
        end
        cursorArmed = false
        awaitingConfirmation = false
        RefreshButtonState()
        print("|cffff4444Rustcore:|r Held item was returned. Click again to retry.")
    end)
end

local function BeginArmMonitor()
    local item = pendingItems[1]
    if not item then FinishQueue(); return end

    StopProcessingTicker()
    local retriesLeft = 4
    processingTicker = C_Timer.NewTicker(0.1, function()
        local equippedLink, bag, bagSlot = GetTrackedItemState(item)

        if CursorHasItem() then
            StopProcessingTicker()
            TriggerCursorDeletion(item)
            return
        end

        if not equippedLink and not bag then
            StopProcessingTicker()
            cursorArmed = false
            awaitingConfirmation = false
            ShowActiveFrame()
            RemoveFirstPendingItem()
            return
        end

        if bag and bagSlot and retriesLeft > 0 then
            retriesLeft = retriesLeft - 1
            ClearCursor()
            BagPickupItem(bag, bagSlot)
            return
        end

        StopProcessingTicker()
        cursorArmed = false
        awaitingConfirmation = false
        ShowActiveFrame()
        RefreshButtonState()
        print("|cffff4444Rustcore:|r Item was not held on the cursor. Click again to retry.")
    end)
end

local function BeginMoveMonitor()
    local item = pendingItems[1]
    if not item then FinishQueue(); return end

    StopProcessingTicker()
    processingTicker = C_Timer.NewTicker(0.1, function()
        if CursorHasItem() then return end

        local equippedLink, bag = GetTrackedItemState(item)
        StopProcessingTicker()

        if bag then
            awaitingConfirmation = false
            cursorArmed = false
            ShowActiveFrame()
            return
        end

        ShowActiveFrame()

        local function CheckMoveRetry(remaining)
            if not pendingItems[1] or pendingItems[1] ~= item then return end
            local equippedRetry, bagRetry = GetTrackedItemState(item)
            if bagRetry then
                awaitingConfirmation = false
                cursorArmed = false
                ShowActiveFrame()
                return
            end
            if remaining > 0 then
                C_Timer.After(0.15, function() CheckMoveRetry(remaining - 1) end)
                return
            end
            awaitingConfirmation = false
            cursorArmed = false
            RefreshButtonState()
            if equippedRetry then
                print("|cffff4444Rustcore:|r Item was returned to its equipment slot. Click again to retry.")
            else
                print("|cffff4444Rustcore:|r Item could not be prepared for deletion. Click again to retry.")
            end
        end

        C_Timer.After(0.15, function() CheckMoveRetry(3) end)
    end)
end

function RustcoreUI.ExecuteDeletion()
    if processingTicker then return end

    if #pendingItems == 0 then
        print("|cffff4444Rustcore:|r No pending items to process.")
        RefreshButtonState()
        return
    end

    PlaySoundFile(Rustcore.GetAssetPath("Audio/Breaksound.flac"), "Master")

    local item = pendingItems[1]
    local frameHiddenForProcessing = false

    local function HideNow()
        if not frameHiddenForProcessing then
            HideProcessingFrame()
            frameHiddenForProcessing = true
        end
    end

    local function RestoreNow()
        if frameHiddenForProcessing then
            ShowActiveFrame()
            frameHiddenForProcessing = false
        end
    end

    if CursorHasItem() and not awaitingConfirmation then
        HideNow()
        TriggerCursorDeletion(item)
        return
    end

    if awaitingConfirmation then
        if GetDeletePopupFrame() then
            PositionDeletePopup()
            print("|cffff4444Rustcore:|r Confirm the current item deletion first.")
            return
        end
        local equippedLink, bag = GetTrackedItemState(item)
        if not equippedLink and not bag then
            awaitingConfirmation = false
            cursorArmed = false
            RemoveFirstPendingItem(true)
        else
            print("|cffff4444Rustcore:|r That item is still present. Confirm the popup, then click again if needed.")
        end
        return
    end

    local equippedLink, bag, bagSlot = GetTrackedItemState(item)
    if not equippedLink and not bag then
        print("|cffff4444Rustcore:|r Skipping missing item: " .. (item.link or item.name or "unknown item"))
        RemoveFirstPendingItem()
        return
    end

    HideNow()

    if equippedLink then
        ClearCursor()
        PickupInventoryItem(item.slot)
        if not CursorHasItem() then
            RestoreNow()
            local itemDisplay = item.link or item.name or "this item"
            local deadMsg = UnitIsDeadOrGhost("player") and " Resurrect and try again for this item." or " Try clicking again."
            print("|cffff4444Rustcore:|r Could not pick up " .. itemDisplay .. "." .. deadMsg)
            if UnitIsDeadOrGhost("player") then
                table.remove(pendingItems, 1)
                table.insert(pendingItems, item)
                SyncPendingDeletionDB()
                if deleteFrame then
                    frameBottomAnchorX = deleteFrame:GetCenter()
                    frameBottomAnchorY = deleteFrame:GetBottom()
                end
                PopulateSpinUI(pendingItems, true)
                local f = EnsureFrame()
                f:Show()
                StartStatusUpdateTicker()
            else
                RefreshButtonState()
            end
            return
        end
        TriggerCursorDeletion(item)
        return
    end

    ClearCursor()
    BagPickupItem(bag, bagSlot)
    if CursorHasItem() then
        TriggerCursorDeletion(item)
        return
    end

    BeginArmMonitor()
    C_Timer.After(0.05, function()
        if pendingItems[1] ~= item then return end
        if CursorHasItem() then
            StopProcessingTicker()
            TriggerCursorDeletion(item)
        end
    end)
end

function RustcoreUI.GetPendingCount()
    if RustcoreDB.pendingDeletion and #RustcoreDB.pendingDeletion > 0 then
        return #RustcoreDB.pendingDeletion
    end
    return #pendingItems
end

-- Called on resurrection: re-enable the button without replaying the spin
function RustcoreUI.OnResurrect(source, snapshotItems)
    if not source or #source == 0 then return end
    if deleteFrame and deleteFrame:IsShown() and #deleteFrame.spinRows > 0 then
        RestoreFrameVisualState()
        RefreshButtonState()
    else
        RustcoreUI.ShowDeletionFrame(source, snapshotItems, true)
    end
end

function RustcoreUI.ReopenDeletionFrame()
    local source = (RustcoreDB.pendingDeletion and #RustcoreDB.pendingDeletion > 0)
                   and RustcoreDB.pendingDeletion or pendingItems
    if #source == 0 then
        print("|cffff4444Rustcore:|r No pending death penalty items.")
        return
    end
    RustcoreUI.ShowDeletionFrame(source, RustcoreDB.pendingDeletionSnapshot, true)
end

do
    if StaticPopupDialogs and StaticPopupDialogs["DELETE_ITEM"] and StaticPopupDialogs["DELETE_GOOD_ITEM"] then
        StaticPopupDialogs["DELETE_GOOD_ITEM"] = StaticPopupDialogs["DELETE_ITEM"]
    end
end
