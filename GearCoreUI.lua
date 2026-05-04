-- GearCore: Deletion confirmation UI
-- Lists items marked for deletion and provides a single button to destroy them.
-- Rare+ items will trigger WoW's native "type DELETE" confirmation dialog per item.

GearCoreUI = {}

local deleteFrame
local pendingItems = {}
local awaitingConfirmation = false
local cursorArmed = false
local processingTicker
local statusUpdateTicker
local savedBtnX, savedBtnY   -- button screen coords saved before hiding
local GetDeletePopupFrame
-- Forward declarations so functions defined later are upvalues, not nil global lookups
local FinishQueue
local ShowActiveFrame
local GetTrackedItemState
local RemoveFirstPendingItem

-- On the modern WoW engine (post-Shadowlands, used by all Anniversary clients),
-- SetBackdrop is only available on frames that inherit BackdropTemplate.
-- On older engines it is a native Frame method. This covers both cases.
local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildFrame()
    -- Item list frame (compact, no button)
    local f = CreateFrame("Frame", "GearCoreDeletionFrame", UIParent, backdropTemplate)
    f:SetSize(350, 300)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
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
    title:SetText("|cffff4444GearCore|r — Death Penalty")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -6)
    sub:SetText("Items marked for deletion:")
    f.subLabel = sub

    -- Scroll area background
    local scrollBG = CreateFrame("Frame", nil, f, backdropTemplate)
    scrollBG:SetPoint("TOPLEFT",  f, "TOPLEFT",   16, -50)
    scrollBG:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 16)
    scrollBG:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        tile = true, tileSize = 16,
    })
    scrollBG:SetBackdropColor(0, 0, 0, 0.45)

    local sf = CreateFrame("ScrollFrame", "GearCoreDeletionScroll", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     scrollBG, "TOPLEFT",     2, -2)
    sf:SetPoint("BOTTOMRIGHT", scrollBG, "BOTTOMRIGHT", -22, 2)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(264)
    sc:SetHeight(1)
    sf:SetScrollChild(sc)
    f.scrollChild = sc
    f.itemRows    = {}

    -- Status message (shown when dead)
    local statusMsg = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusMsg:SetPoint("TOP", f, "BOTTOM", 0, 8)
    statusMsg:SetTextColor(1, 0.8, 0)
    statusMsg:SetText("Resurrect to begin deleting items")
    f.statusMsg = statusMsg

    -- Delete button anchored directly below the list frame
    local btn = CreateFrame("Button", "GearCoreDeletionButton", f, "UIPanelButtonTemplate")
    btn:SetSize(160, 32)
    btn:SetPoint("TOP", f, "BOTTOM", 0, -6)
    btn:SetText("DELETE NEXT")
    btn:SetScript("OnClick", GearCoreUI.ExecuteDeletion)
    f.deleteBtn = btn
    btn:Hide()

    -- No close button — the deletion window must not be dismissable.
    -- Use the recovery button in /gearcore options if the window needs to be reopened.

    f:Hide()
    return f
end

local function EnsureFrame()
    if not deleteFrame then deleteFrame = BuildFrame() end
    return deleteFrame
end


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

local function RefreshButtonState()
    local f = EnsureFrame()

    if UnitIsDeadOrGhost("player") then
        if f.statusMsg then
            f.statusMsg:Show()
            f.statusMsg:SetText("Resurrect to begin deleting items")
        end
        f.deleteBtn:Hide()
        return
    end

    if f.statusMsg then f.statusMsg:Hide() end

    if #pendingItems == 0 then
        f.deleteBtn:Hide()
        return
    end

    -- Keep button hidden during any active processing step.
    if processingTicker or CursorHasItem() or GetDeletePopupFrame() then
        return
    end

    f.deleteBtn:SetText("DELETE NEXT")
    f.deleteBtn:Enable()
    f.deleteBtn:Show()
end

local function StartStatusUpdateTicker()
    StopStatusUpdateTicker()
    statusUpdateTicker = C_Timer.NewTicker(0.5, function()
        RefreshButtonState()
    end)
end

local function SyncPendingDeletionDB()
    if #pendingItems > 0 then
        GearCoreDB.pendingDeletion = {}
        for i, item in ipairs(pendingItems) do
            GearCoreDB.pendingDeletion[i] = {
                slot = item.slot,
                link = item.link,
                name = item.name,
            }
        end
    else
        GearCoreDB.pendingDeletion = nil
    end
end

local function RestoreFrameVisualState()
    local f = EnsureFrame()
    if GearCoreOptions and GearCoreOptions.Hide then
        GearCoreOptions.Hide()
    end

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

local function ShowTransitionNotification()
    local f = EnsureFrame()
    if not f.transitionLabel then
        f.transitionLabel = f:CreateFontString(nil, "OVERLAY", "GameFontGreenSmall")
        f.transitionLabel:SetPoint("TOP", f.deleteBtn, "BOTTOM", 0, -4)
    end
    
    f.transitionLabel:SetText("✓ Next item selected...")
    f.transitionLabel:Show()
    
    if f.transitionTicker then
        f.transitionTicker:Cancel()
    end
    f.transitionTicker = C_Timer.NewTicker(0.1, function()
        f.transitionLabel:SetAlpha((f.transitionLabel:GetAlpha() or 1) - 0.15)
        if f.transitionLabel:GetAlpha() <= 0 then
            f.transitionLabel:Hide()
            f.transitionTicker:Cancel()
            f.transitionTicker = nil
        end
    end, 7)
end

GetDeletePopupFrame = function()
    if StaticPopup_Visible then
        local popup = StaticPopup_Visible("DELETE_ITEM") or StaticPopup_Visible("DELETE_GOOD_ITEM")
        if type(popup) == "string" then
            return _G[popup]
        end
        return popup
    end
    return nil
end

local function ResolveProcessingState()
    local item = pendingItems[1]
    if not item then
        FinishQueue()
        return
    end

    if GetDeletePopupFrame() or CursorHasItem() then
        return
    end

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
        if not pendingItems[1] or pendingItems[1] ~= item then
            return
        end

        local equippedRetry, bagRetry = GetTrackedItemState(item)

        if not equippedRetry and not bagRetry then
            cursorArmed = false
            awaitingConfirmation = false
            RemoveFirstPendingItem()
            return
        end

        if remaining > 0 then
            C_Timer.After(0.15, function()
                CheckDeleteRetry(remaining - 1)
            end)
            return
        end

        cursorArmed = false
        awaitingConfirmation = false
        RefreshButtonState()
        print("|cffff4444GearCore:|r Item was not deleted. Click again to retry.")
    end

    C_Timer.After(0.15, function()
        CheckDeleteRetry(3)
    end)
end

local function PositionDeletePopup()
    local popup = GetDeletePopupFrame()
    if not popup then return end

    if not popup.__gearcoreHooked then
        popup.__gearcoreHooked = true
        popup:HookScript("OnHide", function()
            popup.__gearcorePositioned = false
            C_Timer.After(0, ResolveProcessingState)
        end)
    end
    if popup.__gearcorePositioned then return end
    popup.__gearcorePositioned = true

    -- Use the coords saved when the button was hidden.
    local bx, by = savedBtnX, savedBtnY
    if not bx or not by then return end

    -- Step 1: place popup centred at saved position so btn1 offset is measurable.
    popup:ClearAllPoints()
    popup:SetPoint("CENTER", UIParent, "BOTTOMLEFT", bx, by)

    -- Step 2: next frame, shift so popup.button1 lands exactly on saved position.
    C_Timer.After(0, function()
        if not popup:IsShown() then return end
        local btn1 = popup.button1 or _G[(popup:GetName() or "") .. "Button1"]
        if not btn1 then return end
        local b1x, b1y = btn1:GetCenter()
        if not b1x then return end
        popup:ClearAllPoints()
        popup:SetPoint("CENTER", UIParent, "BOTTOMLEFT", 2 * bx - b1x, 2 * by - b1y)
    end)
end

-- ── Item list population ──────────────────────────────────────────────────────

local function PopulateList(items)
    local f = EnsureFrame()
    for _, row in ipairs(f.itemRows) do row:Hide() end
    wipe(f.itemRows)

    local sc = f.scrollChild
    local y  = 4

    for i, item in ipairs(items) do
        local row = CreateFrame("Frame", nil, sc, backdropTemplate)
        row:SetSize(264, 30)
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 4, -y)

        if i == 1 then
            row:SetBackdrop({ bgFile = "Interface\\ChatFrame\\ChatFrameBackground", tile = true, tileSize = 16 })
            row:SetBackdropColor(0.9, 0.8, 0.1, 0.35)
        end

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(24, 24)
        icon:SetPoint("LEFT", row, "LEFT", 0, 0)
        local tex = GetInventoryItemTexture("player", item.slot)
        icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")

        local lbl = row:CreateFontString(nil, "OVERLAY", i == 1 and "GameFontNormal" or "GameFontDisable")
        lbl:SetPoint("LEFT",  icon, "RIGHT", 6, 0)
        lbl:SetPoint("RIGHT", row,  "RIGHT", 0, 0)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(item.link or item.name)

        row:EnableMouse(true)
        row:SetScript("OnEnter", function()
            if item.link then
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(item.link)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        f.itemRows[i] = row
        y = y + 32
    end

    sc:SetHeight(math.max(y + 4, 1))
end

-- ── Container API wrappers ────────────────────────────────────────────────────
-- PickupContainerItem and friends were moved to C_Container on the modern engine.
-- The old globals still exist as aliases on most clients, but C_Container is safer.

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
            if not BagGetItemLink(bag, slot) then
                return bag, slot
            end
        end
    end
    return nil, nil
end


-- ── Public API ────────────────────────────────────────────────────────────────

-- Shows the doom window. While dead the button stays locked until resurrection.
function GearCoreUI.ShowDeletionFrame(items)
    wipe(pendingItems)
    for _, item in ipairs(items) do pendingItems[#pendingItems+1] = item end
    awaitingConfirmation = false
    cursorArmed = false
    SyncPendingDeletionDB()
    PopulateList(pendingItems)
    local f = RestoreFrameVisualState()
    if f.subLabel then
        local src = GearCoreDB and GearCoreDB.lastDeathSource
        f.subLabel:SetText(src and ("Killed by: " .. src .. "\nItems marked for deletion:") or "Items marked for deletion:")
    end
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
    PopulateList(pendingItems)

    if #pendingItems == 0 then
        print("|cffff4444GearCore:|r Deletion complete — all marked items processed.")
        if deleteFrame then
            deleteFrame.deleteBtn:Hide()
            deleteFrame:Hide()
        end
        return
    end

    local f = RestoreFrameVisualState()
    RefreshButtonState()
end

RemoveFirstPendingItem = function()
    table.remove(pendingItems, 1)
    SyncPendingDeletionDB()
    PopulateList(pendingItems)
    awaitingConfirmation = false
    cursorArmed = false
    StopProcessingTicker()
    StopStatusUpdateTicker()

    if #pendingItems == 0 then
        print("|cffff4444GearCore:|r Deletion complete — all marked items processed.")
        if deleteFrame then
            deleteFrame.deleteBtn:Hide()
            deleteFrame:Hide()
        end
        return
    end

    local f = EnsureFrame()
    f:Show()
    if f.deleteBtn then
        f.deleteBtn:SetText("DELETE NEXT")
        f.deleteBtn:Enable()
        f.deleteBtn:Show()
    end
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

local function BeginProcessingMonitor()
    local item = pendingItems[1]
    if not item then
        FinishQueue()
        return
    end

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
    if not item then
        FinishQueue()
        return
    end

    StopProcessingTicker()

    processingTicker = C_Timer.NewTicker(0.1, function()
        if CursorHasItem() then
            return
        end

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
        print("|cffff4444GearCore:|r Held item was returned. Click again to retry.")
    end)
end

local function BeginArmMonitor()
    local item = pendingItems[1]
    if not item then
        FinishQueue()
        return
    end

    StopProcessingTicker()

    processingTicker = C_Timer.NewTicker(0.1, function()
        local equippedLink, bag = GetTrackedItemState(item)

        if CursorHasItem() then
            StopProcessingTicker()
            cursorArmed = false
            awaitingConfirmation = false
            DeleteCursorItem()
            awaitingConfirmation = GetDeletePopupFrame() and true or false
            if awaitingConfirmation then
                PositionDeletePopup()
            end
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
        print("|cffff4444GearCore:|r Item was not held on the cursor. Click again to retry.")
    end)
end

local function BeginMoveMonitor()
    local item = pendingItems[1]
    if not item then
        FinishQueue()
        return
    end

    StopProcessingTicker()

    processingTicker = C_Timer.NewTicker(0.1, function()
        if CursorHasItem() then
            return
        end

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
            if not pendingItems[1] or pendingItems[1] ~= item then
                return
            end

            local equippedRetry, bagRetry = GetTrackedItemState(item)

            if bagRetry then
                awaitingConfirmation = false
                cursorArmed = false
                ShowActiveFrame()
                return
            end

            if remaining > 0 then
                C_Timer.After(0.15, function()
                    CheckMoveRetry(remaining - 1)
                end)
                return
            end

            awaitingConfirmation = false
            cursorArmed = false
            RefreshButtonState()
            if equippedRetry then
                print("|cffff4444GearCore:|r Item was returned to its equipment slot. Click again to retry.")
            else
                print("|cffff4444GearCore:|r Item could not be prepared for deletion. Click again to retry.")
            end
        end

        C_Timer.After(0.15, function()
            CheckMoveRetry(3)
        end)
    end)
end

function GearCoreUI.ExecuteDeletion()
    if UnitIsDeadOrGhost("player") then
        print("|cffff4444GearCore:|r You must resurrect before deleting queued items.")
        return
    end

    if #pendingItems == 0 then
        print("|cffff4444GearCore:|r No pending items to process.")
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
            print("|cffff4444GearCore:|r Confirm the current item deletion first.")
            return
        end

        local equippedLink, bag = GetTrackedItemState(item)
        if not equippedLink and not bag then
            awaitingConfirmation = false
            cursorArmed = false
            RemoveFirstPendingItem()
        else
            print("|cffff4444GearCore:|r That item is still present. Confirm the popup, then click again if needed.")
        end
        return
    end

    local equippedLink, bag, bagSlot = GetTrackedItemState(item)

    if not equippedLink and not bag then
        print("|cffff4444GearCore:|r Skipping missing item: " .. (item.link or item.name or "unknown item"))
        RemoveFirstPendingItem()
        return
    end

    HideNow()

    if equippedLink then
        ClearCursor()
        PickupInventoryItem(item.slot)
        if not CursorHasItem() then
            RestoreNow()
            print("|cffff4444GearCore:|r Could not pick up the equipped item. Try clicking again.")
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

-- Returns how many items are currently queued (DB + in-memory).
function GearCoreUI.GetPendingCount()
    if GearCoreDB.pendingDeletion and #GearCoreDB.pendingDeletion > 0 then
        return #GearCoreDB.pendingDeletion
    end
    return #pendingItems
end

-- Called from the options panel recovery button. Re-shows the deletion window
-- using whichever source has data (DB takes priority; falls back to in-memory).
function GearCoreUI.ReopenDeletionFrame()
    local source = (GearCoreDB.pendingDeletion and #GearCoreDB.pendingDeletion > 0)
                   and GearCoreDB.pendingDeletion or pendingItems
    if #source == 0 then
        print("|cffff4444GearCore:|r No pending death penalty items.")
        return
    end
    GearCoreUI.ShowDeletionFrame(source)
end

do
    if StaticPopupDialogs and StaticPopupDialogs["DELETE_ITEM"] and StaticPopupDialogs["DELETE_GOOD_ITEM"] then
        StaticPopupDialogs["DELETE_GOOD_ITEM"] = StaticPopupDialogs["DELETE_ITEM"]
    end
end
