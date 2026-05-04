-- Rustcore: Deletion confirmation UI
-- Shows a wheel-of-fortune spin animation for each item marked for deletion.
-- Core deletion logic (ExecuteDeletion, monitors, etc.) is preserved unchanged.

RustcoreUI = {}

-- Keep GearCoreUI as alias so GearCore.lua broadcast calls still resolve
-- (GearCore.lua references RustcoreUI directly after rename, but just in case)
GearCoreUI = RustcoreUI

local deleteFrame
local pendingItems = {}
local awaitingConfirmation = false
local cursorArmed = false
local processingTicker
local statusUpdateTicker
local savedBtnX, savedBtnY
local GetDeletePopupFrame
local FinishQueue
local ShowActiveFrame
local GetTrackedItemState
local RemoveFirstPendingItem
local RefreshButtonState
local ResolveProcessingState
local PopulateSpinUI
local ClearSpinRows

local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil

-- ── Slot → texture lookup ─────────────────────────────────────────────────────

local SLOT_NAMES = {
    [1]="HeadSlot",[2]="NeckSlot",[3]="ShoulderSlot",[5]="ChestSlot",
    [6]="WaistSlot",[7]="LegsSlot",[8]="FeetSlot",[9]="Wrist​Slot",
    [10]="HandsSlot",[11]="Finger0Slot",[12]="Finger1Slot",
    [13]="Trinket0Slot",[14]="Trinket1Slot",[15]="BackSlot",
    [16]="MainHandSlot",[17]="SecondaryHandSlot",[18]="RangedSlot",
}
local ALL_SLOTS = { 1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18 }

local ICON_SIZE   = 40
local ICON_GAP    = 4
local STRIP_W     = 400   -- visible strip width
local STRIP_H     = ICON_SIZE
local ARROW_H     = 18
local ROW_SPACING = 10    -- vertical gap between rows
local FADE_W      = 60    -- width of each fade gradient on edges

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

-- ── Spin row construction ─────────────────────────────────────────────────────

-- Each pending item gets one spin row. The row contains:
--   • a clip frame (masks the strip to STRIP_W wide)
--   • inside: many icon textures arranged left-to-right
--   • an arrow pointing at the center
--   • edge fade overlays

local function BuildSpinRow(parent, yOffset, targetSlot, targetTex, allIcons, chosenIndex)
    local step = ICON_SIZE + ICON_GAP

    -- Container for the whole row (arrow + strip)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(STRIP_W, STRIP_H + ARROW_H + 6)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)

    -- Arrow pointing down at center
    local arrow = row:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(ARROW_H, ARROW_H)
    arrow:SetPoint("TOP", row, "TOP", 0, 0)
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")

    -- Clip frame (hides icons outside the strip)
    local clip = CreateFrame("Frame", nil, row)
    clip:SetSize(STRIP_W, STRIP_H)
    clip:SetPoint("TOP", row, "TOP", 0, -(ARROW_H + 6))
    clip:SetClipsChildren(true)

    -- Left/right fade overlays (drawn on top of icons)
    local fadeL = clip:CreateTexture(nil, "OVERLAY")
    fadeL:SetSize(FADE_W, STRIP_H)
    fadeL:SetPoint("LEFT", clip, "LEFT", 0, 0)
    fadeL:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    fadeL:SetGradientAlpha("HORIZONTAL", 0,0,0,0.85, 0,0,0,0)

    local fadeR = clip:CreateTexture(nil, "OVERLAY")
    fadeR:SetSize(FADE_W, STRIP_H)
    fadeR:SetPoint("RIGHT", clip, "RIGHT", 0, 0)
    fadeR:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    fadeR:SetGradientAlpha("HORIZONTAL", 0,0,0,0, 0,0,0,0.85)

    -- Build icon pool inside clip: enough to wrap seamlessly
    local totalIcons = #allIcons
    -- We render 2× the strip width in icons so we can scroll without gaps
    local visCount = math.ceil(STRIP_W / step) + 6
    local iconFrames = {}
    for i = 1, visCount do
        local ic = clip:CreateTexture(nil, "ARTWORK")
        ic:SetSize(ICON_SIZE, ICON_SIZE)
        local src = allIcons[((i-1) % totalIcons) + 1]
        ic:SetTexture(src.tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic:SetPoint("LEFT", clip, "LEFT", (i-1)*step, (STRIP_H - ICON_SIZE)/2)
        iconFrames[i] = { tex = ic, srcIdx = ((i-1) % totalIcons) + 1 }
    end

    row.clip        = clip
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
    row.chosenIndex = chosenIndex  -- index in allIcons[] of the chosen item

    return row
end

-- Reposition all icon frames given current row.offset
local function UpdateRowPositions(row)
    local step = row.step
    local off  = row.offset % (row.totalIcons * step)
    for i, ic in ipairs(row.iconFrames) do
        local x = (i-1)*step - off
        -- Wrap icons that scroll off the left edge to the right
        if x < -step then
            x = x + row.totalIcons * step
        end
        ic.tex:SetPoint("LEFT", row.clip, "LEFT", x, (STRIP_H - ICON_SIZE)/2)

        -- Update texture based on new position's logical index
        local logIdx = (math.floor((off + (i-1)*step) / step) % row.totalIcons) + 1
        local src = row.allIcons[logIdx]
        ic.tex:SetTexture(src and src.tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        ic.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic.tex:SetVertexColor(1, 1, 1, 1)
    end
end

-- Mark the center icon red (the chosen one) once spinning stops
local function MarkCenterIcon(row)
    local step   = row.step
    local centerX = STRIP_W / 2 - ICON_SIZE / 2
    -- Find the icon frame closest to center
    local bestFrame, bestDist = nil, math.huge
    for _, ic in ipairs(row.iconFrames) do
        local x = ic.tex:GetPoint() -- returns point, relativeTo, relativePoint, xOfs, yOfs
        -- GetPoint returns 5 values; xOfs is 4th
        local _, _, _, xOfs = ic.tex:GetPoint()
        if xOfs then
            local dist = math.abs(xOfs - centerX)
            if dist < bestDist then
                bestDist = dist
                bestFrame = ic
            end
        end
    end
    if bestFrame then
        bestFrame.tex:SetVertexColor(1, 0.15, 0.15, 1)
    end
end

-- ── Animation driver ──────────────────────────────────────────────────────────

-- spinRows: list of row objects
-- onAllDone: callback when every row has settled
local function StartSpinAnimations(spinRows, onAllDone)
    if #spinRows == 0 then
        if onAllDone then onAllDone() end
        return
    end

    local step = (ICON_SIZE + ICON_GAP)
    local totalIcons = spinRows[1].totalIcons

    -- Each row gets a random spin distance so they settle at different times
    -- and on different icons. They all start fast and decelerate.

    for idx, row in ipairs(spinRows) do
        -- The chosen item should land at center. Center pixel = STRIP_W/2 - ICON_SIZE/2.
        -- Work out offset so chosenIndex icon is centered, then add full laps.
        local centerTarget = STRIP_W / 2 - ICON_SIZE / 2
        -- The chosen icon's natural x at offset=0 is (chosenIndex-1)*step
        -- We want: (chosenIndex-1)*step - finalOffset = centerTarget
        -- => finalOffset = (chosenIndex-1)*step - centerTarget
        local baseOffset = (row.chosenIndex - 1) * step - centerTarget
        -- Add 3..6 full laps so it actually spins
        local laps = 3 + idx  -- stagger completion
        local finalOffset = baseOffset + laps * totalIcons * step

        row.targetOffset = finalOffset
        row.startOffset  = 0
        row.startTime    = GetTime() + (idx - 1) * 0.3  -- stagger start slightly
        row.duration     = 3.0 + idx * 0.4              -- each row takes a bit longer
        row.spinning     = true
        row.done         = false
    end

    local doneCount = 0

    local ticker = C_Timer.NewTicker(0.016, function()  -- ~60fps
        local now = GetTime()
        for _, row in ipairs(spinRows) do
            if row.spinning and not row.done then
                local elapsed = now - row.startTime
                if elapsed < 0 then
                    -- Not started yet
                elseif elapsed >= row.duration then
                    -- Snap to final
                    row.offset  = row.targetOffset
                    row.done    = true
                    row.spinning = false
                    UpdateRowPositions(row)
                    MarkCenterIcon(row)
                    doneCount = doneCount + 1
                    if doneCount >= #spinRows and onAllDone then
                        onAllDone()
                    end
                else
                    -- Ease-out cubic: t goes 0→1, speed starts fast and decelerates
                    local t = elapsed / row.duration
                    -- ease out cubic: progress = 1 - (1-t)^3
                    local progress = 1 - (1 - t)^3
                    row.offset = row.startOffset + progress * (row.targetOffset - row.startOffset)
                    UpdateRowPositions(row)
                end
            end
        end
    end)

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

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left=11, right=12, top=12, bottom=11 },
    })

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("|cffff4444Rustcore|r — Death Penalty")
    f.title = title

    local subLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    subLabel:SetPoint("TOP", title, "BOTTOM", 0, -6)
    subLabel:SetText("")
    f.subLabel = subLabel

    -- Container for spin rows, anchored below subLabel
    local rowContainer = CreateFrame("Frame", nil, f)
    rowContainer:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -70)
    rowContainer:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -70)
    f.rowContainer = rowContainer

    -- Status message shown while dead
    local statusMsg = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusMsg:SetTextColor(1, 0.8, 0)
    statusMsg:SetText("Resurrect to begin deleting items")
    f.statusMsg = statusMsg

    -- Delete button
    local btn = CreateFrame("Button", "RustcoreDeletionButton", f, "UIPanelButtonTemplate")
    btn:SetSize(180, 36)
    btn:SetScript("OnClick", RustcoreUI.ExecuteDeletion)
    f.deleteBtn = btn
    btn:Hide()

    f.spinRows   = {}
    f.spinTicker = nil

    f:Hide()
    return f
end

local function EnsureFrame()
    if not deleteFrame then deleteFrame = BuildFrame() end
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
end

PopulateSpinUI = function(items)
    local f = EnsureFrame()
    ClearSpinRows()

    local allIcons = GetEquippedIconList()
    if #allIcons == 0 then return end  -- no equipped items (shouldn't happen)

    local rowH    = STRIP_H + ARROW_H + 6
    local totalH  = #items * (rowH + ROW_SPACING) - ROW_SPACING

    -- Resize frame to fit all rows plus header/button space
    local frameH = math.max(220, totalH + 140)
    f:SetSize(STRIP_W + 60, frameH)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

    f.rowContainer:SetHeight(totalH)

    local spinRows = {}
    for i, item in ipairs(items) do
        -- Find which icon in allIcons corresponds to item.slot
        local chosenIdx = 1
        for j, ic in ipairs(allIcons) do
            if ic.slot == item.slot then
                chosenIdx = j
                break
            end
        end
        -- If slot not found (item already unequipped), pick random
        if chosenIdx == 1 and (not allIcons[1] or allIcons[1].slot ~= item.slot) then
            chosenIdx = math.random(#allIcons)
        end

        local yOff = -((i-1) * (rowH + ROW_SPACING))
        local tex  = GetInventoryItemTexture("player", item.slot)
        local row  = BuildSpinRow(f.rowContainer, yOff, item.slot, tex, allIcons, chosenIdx)
        row:Show()
        f.spinRows[i] = row
        spinRows[i]   = row
    end

    -- Position status + button below the row container
    local btnY = -(totalH + 20)
    f.rowContainer:SetHeight(totalH)
    f.statusMsg:ClearAllPoints()
    f.statusMsg:SetPoint("TOP", f.rowContainer, "BOTTOM", 0, -14)
    f.deleteBtn:ClearAllPoints()
    f.deleteBtn:SetPoint("TOP", f.rowContainer, "BOTTOM", 0, -38)

    -- Start animations
    f.spinTicker = StartSpinAnimations(spinRows, function()
        -- All rows settled — update button state
        RefreshButtonState()
    end)
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

    if UnitIsDeadOrGhost("player") then
        if f.statusMsg then
            f.statusMsg:Show()
            f.statusMsg:SetText("Resurrect to delete")
        end
        if f.deleteBtn then
            f.deleteBtn:SetText("Resurrect to delete")
            f.deleteBtn:GetNormalTexture() -- ensure template rendered
            f.deleteBtn:Disable()
            -- Grey out visually
            if f.deleteBtn.SetDisabledTexture then end
            f.deleteBtn:Show()
        end
        return
    end

    if f.statusMsg then f.statusMsg:Hide() end

    if #pendingItems == 0 then
        f.deleteBtn:Hide()
        return
    end

    if processingTicker or CursorHasItem() or GetDeletePopupFrame() then
        return
    end

    f.deleteBtn:SetText("Delete next item")
    f.deleteBtn:Enable()
    -- Red tint
    f.deleteBtn:GetNormalTexture()
    f.deleteBtn:Show()
end

local function StartStatusUpdateTicker()
    StopStatusUpdateTicker()
    statusUpdateTicker = C_Timer.NewTicker(0.5, RefreshButtonState)
end

local function SyncPendingDeletionDB()
    if #pendingItems > 0 then
        RustcoreDB.pendingDeletion = {}
        for i, item in ipairs(pendingItems) do
            RustcoreDB.pendingDeletion[i] = { slot=item.slot, link=item.link, name=item.name }
        end
    else
        RustcoreDB.pendingDeletion = nil
    end
end

local function RestoreFrameVisualState()
    local f = EnsureFrame()
    if RustcoreOptions and RustcoreOptions.Hide then RustcoreOptions.Hide() end

    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetParent(UIParent)
    f:SetAlpha(1)
    f:SetScale(1)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:Show()
    f:Raise()

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

local function FindEmptyBagSlot()
    for bag = 0, 4 do
        for slot = 1, BagGetNumSlots(bag) do
            if not BagGetItemLink(bag, slot) then return bag, slot end
        end
    end
    return nil, nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

function RustcoreUI.ShowDeletionFrame(items)
    wipe(pendingItems)
    for _, item in ipairs(items) do pendingItems[#pendingItems+1] = item end
    awaitingConfirmation = false
    cursorArmed = false
    SyncPendingDeletionDB()

    local f = EnsureFrame()
    if f.subLabel then
        local src = RustcoreDB and RustcoreDB.lastDeathSource
        f.subLabel:SetText(src and ("Killed by: " .. src) or "")
    end

    PopulateSpinUI(pendingItems)
    RestoreFrameVisualState()
    RefreshButtonState()
end

local function GetItemIdFromLink(link)
    return link and link:match("item:(%d+)")
end

local function FindItemInBagsByLink(link)
    if not link then return nil, nil end
    local targetId = GetItemIdFromLink(link)
    if not targetId then return nil, nil end

    for bag = 0, 4 do
        for slot = 1, BagGetNumSlots(bag) do
            local bagLink = BagGetItemLink(bag, slot)
            if bagLink and GetItemIdFromLink(bagLink) == targetId then
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
        print("|cffff4444Rustcore:|r Deletion complete — all marked items processed.")
        ClearSpinRows()
        if deleteFrame then
            deleteFrame.deleteBtn:Hide()
            deleteFrame:Hide()
        end
        return
    end

    PopulateSpinUI(pendingItems)
    local f = RestoreFrameVisualState()
    RefreshButtonState()
end

RemoveFirstPendingItem = function()
    table.remove(pendingItems, 1)
    SyncPendingDeletionDB()
    awaitingConfirmation = false
    cursorArmed = false
    StopProcessingTicker()
    StopStatusUpdateTicker()

    if #pendingItems == 0 then
        print("|cffff4444Rustcore:|r Deletion complete — all marked items processed.")
        ClearSpinRows()
        if deleteFrame then
            deleteFrame.deleteBtn:Hide()
            deleteFrame:Hide()
        end
        return
    end

    PopulateSpinUI(pendingItems)
    local f = EnsureFrame()
    f:Show()
    StartStatusUpdateTicker()
end

GetTrackedItemState = function(item)
    local equippedLink = GetInventoryItemLink("player", item.slot)
    if equippedLink and GetItemIdFromLink(equippedLink) ~= GetItemIdFromLink(item.link) then
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
        deleteFrame.deleteBtn:Hide()
    end
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
        RemoveFirstPendingItem()
        return
    end

    ShowActiveFrame()

    local function CheckDeleteRetry(remaining)
        if not pendingItems[1] or pendingItems[1] ~= item then return end
        local equippedRetry, bagRetry = GetTrackedItemState(item)
        if not equippedRetry and not bagRetry then
            cursorArmed = false
            awaitingConfirmation = false
            RemoveFirstPendingItem()
            return
        end
        if remaining > 0 then
            C_Timer.After(0.15, function() CheckDeleteRetry(remaining - 1) end)
            return
        end
        cursorArmed = false
        awaitingConfirmation = false
        RefreshButtonState()
        print("|cffff4444Rustcore:|r Item was not deleted. Click again to retry.")
    end

    C_Timer.After(0.15, function() CheckDeleteRetry(3) end)
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
    processingTicker = C_Timer.NewTicker(0.1, function()
        local equippedLink, bag = GetTrackedItemState(item)

        if CursorHasItem() then
            StopProcessingTicker()
            cursorArmed = false
            awaitingConfirmation = false
            DeleteCursorItem()
            awaitingConfirmation = GetDeletePopupFrame() and true or false
            if awaitingConfirmation then PositionDeletePopup() end
            BeginProcessingMonitor()
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
    if UnitIsDeadOrGhost("player") then
        print("|cffff4444Rustcore:|r You must resurrect before deleting queued items.")
        return
    end

    if #pendingItems == 0 then
        print("|cffff4444Rustcore:|r No pending items to process.")
        RefreshButtonState()
        return
    end

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
            RemoveFirstPendingItem()
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
            print("|cffff4444Rustcore:|r Could not pick up the equipped item. Try clicking again.")
            RefreshButtonState()
            return
        end
        cursorArmed = false
        awaitingConfirmation = false
        DeleteCursorItem()
        awaitingConfirmation = GetDeletePopupFrame() and true or false
        if awaitingConfirmation then PositionDeletePopup() end
        BeginProcessingMonitor()
        return
    end

    ClearCursor()
    BeginArmMonitor()
    PickupContainerItem(bag, bagSlot)
end

function RustcoreUI.GetPendingCount()
    if RustcoreDB.pendingDeletion and #RustcoreDB.pendingDeletion > 0 then
        return #RustcoreDB.pendingDeletion
    end
    return #pendingItems
end

function RustcoreUI.ReopenDeletionFrame()
    local source = (RustcoreDB.pendingDeletion and #RustcoreDB.pendingDeletion > 0)
                   and RustcoreDB.pendingDeletion or pendingItems
    if #source == 0 then
        print("|cffff4444Rustcore:|r No pending death penalty items.")
        return
    end
    RustcoreUI.ShowDeletionFrame(source)
end

do
    if StaticPopupDialogs and StaticPopupDialogs["DELETE_ITEM"] and StaticPopupDialogs["DELETE_GOOD_ITEM"] then
        StaticPopupDialogs["DELETE_GOOD_ITEM"] = StaticPopupDialogs["DELETE_ITEM"]
    end
end
