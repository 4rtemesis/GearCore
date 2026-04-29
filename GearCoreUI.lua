-- GearCore: Deletion confirmation UI
-- Lists items marked for deletion and provides a single button to destroy them.
-- Rare+ items will trigger WoW's native "type DELETE" confirmation dialog per item.

GearCoreUI = {}

local deleteFrame
local pendingItems = {}
local awaitingConfirmation = false
local processingTicker
local lastDeleteButtonCenterX
local lastDeleteButtonCenterY

-- On the modern WoW engine (post-Shadowlands, used by all Anniversary clients),
-- SetBackdrop is only available on frames that inherit BackdropTemplate.
-- On older engines it is a native Frame method. This covers both cases.
local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildFrame()
    local f = CreateFrame("Frame", "GearCoreDeletionFrame", UIParent, backdropTemplate)
    f:SetSize(330, 460)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
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

    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetSize(210, 30)
    btn:SetPoint("TOP", sub, "BOTTOM", 0, -10)
    btn:SetText("DELETE MARKED ITEMS")
    btn:SetScript("OnClick", GearCoreUI.ExecuteDeletion)
    f.deleteBtn = btn

    local warn = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warn:SetPoint("TOP", btn, "BOTTOM", 0, -8)
    warn:SetTextColor(1, 0.3, 0.3)
    warn:SetText("The window will step aside while each item is being processed.")

    -- Scroll area background
    local scrollBG = CreateFrame("Frame", nil, f, backdropTemplate)
    scrollBG:SetPoint("TOPLEFT",  f, "TOPLEFT",   16, -128)
    scrollBG:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 16)
    scrollBG:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        tile = true, tileSize = 16,
    })
    scrollBG:SetBackdropColor(0, 0, 0, 0.45)

    local sf = CreateFrame("ScrollFrame", "GearCoreDeletionScroll", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     scrollBG, "TOPLEFT",     2, -2)
    sf:SetPoint("BOTTOMRIGHT", scrollBG, "BOTTOMRIGHT", -2, 2)

    local sc = CreateFrame("Frame", nil, sf)
    sc:SetWidth(264)
    sc:SetHeight(1)
    sf:SetScrollChild(sc)
    f.scrollChild = sc
    f.itemRows    = {}

    -- No close button — the deletion window must not be dismissable.
    -- Use the recovery button in /gearcore options if the window needs to be reopened.

    f:Hide()
    return f
end

local function EnsureFrame()
    if not deleteFrame then deleteFrame = BuildFrame() end
    return deleteFrame
end

local function RestoreFrameVisualState()
    local f = EnsureFrame()
    if GearCoreOptions and GearCoreOptions.Hide then
        GearCoreOptions.Hide()
    end

    f:ClearAllPoints()
    f:SetPoint("CENTER")
    f:SetParent(UIParent)
    f:SetAlpha(1)
    f:SetScale(1)
    f:SetFrameStrata("DIALOG")
    f:Show()
    f:Raise()

    C_Timer.After(0, function()
        if deleteFrame then
            deleteFrame:ClearAllPoints()
            deleteFrame:SetPoint("CENTER")
            deleteFrame:SetParent(UIParent)
            deleteFrame:SetAlpha(1)
            deleteFrame:SetScale(1)
            deleteFrame:SetFrameStrata("DIALOG")
            deleteFrame:Show()
            deleteFrame:Raise()
        end
    end)

    return f
end

local function StopProcessingTicker()
    if processingTicker then
        processingTicker:Cancel()
        processingTicker = nil
    end
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

local function RefreshButtonState()
    local f = EnsureFrame()

    if UnitIsDeadOrGhost("player") then
        f.deleteBtn:SetText("Will unlock after resurrection")
        f.deleteBtn:Disable()
        return
    end

    if #pendingItems == 0 then
        f.deleteBtn:SetText("No pending items")
        f.deleteBtn:Disable()
        return
    end

    if awaitingConfirmation then
        f.deleteBtn:SetText("Continue After DELETE Prompt")
    else
        f.deleteBtn:SetText("DELETE NEXT ITEM (" .. #pendingItems .. " LEFT)")
    end
    f.deleteBtn:Enable()
end

local function GetDeletePopupFrame()
    if StaticPopup_Visible then
        local popup = StaticPopup_Visible("DELETE_ITEM") or StaticPopup_Visible("DELETE_GOOD_ITEM")
        if type(popup) == "string" then
            return _G[popup]
        end
        return popup
    end
    return nil
end

local function PositionDeletePopup()
    local popup = GetDeletePopupFrame()
    local f = deleteFrame
    if not popup or not f or not f.deleteBtn then
        return
    end

    local btn = f.deleteBtn
    local targetX = lastDeleteButtonCenterX
    local targetY = lastDeleteButtonCenterY
    if not targetX or not targetY then
        targetX, targetY = btn:GetCenter()
    end

    if not targetX or not targetY then
        popup:ClearAllPoints()
        popup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        return
    end

    local popupCenterX, popupCenterY = popup:GetCenter()
    local confirmCenterX, confirmCenterY
    if popup.button1 then
        confirmCenterX, confirmCenterY = popup.button1:GetCenter()
    end
    if not popupCenterX or not popupCenterY or not confirmCenterX or not confirmCenterY then
        popup:ClearAllPoints()
        popup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        return
    end

    local offsetX = confirmCenterX - popupCenterX
    local offsetY = confirmCenterY - popupCenterY
    local desiredCenterX = targetX - offsetX
    local desiredCenterY = targetY - offsetY

    popup:ClearAllPoints()
    popup:SetPoint("CENTER", UIParent, "BOTTOMLEFT", desiredCenterX, desiredCenterY)
end

-- ── Item list population ──────────────────────────────────────────────────────

local function PopulateList(items)
    local f = EnsureFrame()
    for _, row in ipairs(f.itemRows) do row:Hide() end
    wipe(f.itemRows)

    local sc = f.scrollChild
    local y  = 4

    for i, item in ipairs(items) do
        local row = CreateFrame("Frame", nil, sc)
        row:SetSize(264, 30)
        row:SetPoint("TOPLEFT", sc, "TOPLEFT", 4, -y)

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(24, 24)
        icon:SetPoint("LEFT", row, "LEFT", 0, 0)
        local tex = GetInventoryItemTexture("player", item.slot)
        icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")

        local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
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
    SyncPendingDeletionDB()
    PopulateList(pendingItems)
    local f = RestoreFrameVisualState()
    RefreshButtonState()
end

local function FindItemInBagsByLink(link)
    if not link then
        return nil, nil
    end

    for bag = 0, 4 do
        for slot = 1, BagGetNumSlots(bag) do
            if BagGetItemLink(bag, slot) == link then
                return bag, slot
            end
        end
    end

    return nil, nil
end

local function RemoveFirstPendingItem()
    table.remove(pendingItems, 1)
    SyncPendingDeletionDB()
    PopulateList(pendingItems)
    RefreshButtonState()
end

local function FinishQueue()
    awaitingConfirmation = false
    StopProcessingTicker()
    SyncPendingDeletionDB()
    PopulateList(pendingItems)

    if #pendingItems == 0 then
        print("|cffff4444GearCore:|r Deletion complete — all marked items processed.")
        if deleteFrame then
            deleteFrame:Hide()
        end
        return
    end

    local f = RestoreFrameVisualState()
    RefreshButtonState()
end

local function GetTrackedItemState(item)
    local equippedLink = GetInventoryItemLink("player", item.slot)
    if equippedLink ~= item.link then
        equippedLink = nil
    end
    local bag, bagSlot = FindItemInBagsByLink(item.link)
    return equippedLink, bag, bagSlot
end

local function ShowActiveFrame()
    local f = RestoreFrameVisualState()
    RefreshButtonState()
end

local function HideProcessingFrame()
    if deleteFrame and deleteFrame.deleteBtn then
        lastDeleteButtonCenterX, lastDeleteButtonCenterY = deleteFrame.deleteBtn:GetCenter()
        deleteFrame:ClearAllPoints()
        deleteFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -2000, -2000)
        deleteFrame:SetAlpha(1)
        deleteFrame:Show()
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

    processingTicker = C_Timer.NewTicker(0.1, function()
        local popup = GetDeletePopupFrame()
        if popup then
            awaitingConfirmation = true
            PositionDeletePopup()
            return
        end

        local equippedLink, bag = GetTrackedItemState(item)
        if CursorHasItem() then
            return
        end

        if not equippedLink and not bag then
            awaitingConfirmation = false
            RemoveFirstPendingItem()
            FinishQueue()
            return
        end

        awaitingConfirmation = false
        StopProcessingTicker()
        ShowActiveFrame()
        print("|cffff4444GearCore:|r That item is still present. Click again to retry this one.")
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
            RemoveFirstPendingItem()
            FinishQueue()
        else
            print("|cffff4444GearCore:|r That item is still present. Confirm the popup, then click again if needed.")
        end
        return
    end

    local equippedLink, bag, bagSlot = GetTrackedItemState(item)

    if not equippedLink and not bag then
        print("|cffff4444GearCore:|r Skipping missing item: " .. (item.link or item.name or "unknown item"))
        RemoveFirstPendingItem()
        FinishQueue()
        return
    end

    HideNow()

    if equippedLink then
        bag, bagSlot = FindEmptyBagSlot()
        if not bag then
            RestoreNow()
            print("|cffff4444GearCore:|r Need at least 1 empty bag slot to process the next equipped item.")
            RefreshButtonState()
            return
        end

        ClearCursor()
        PickupInventoryItem(item.slot)
        if not CursorHasItem() then
            RestoreNow()
            print("|cffff4444GearCore:|r Could not pick up the equipped item. Try clicking again.")
            RefreshButtonState()
            return
        end

        PickupContainerItem(bag, bagSlot)
        if CursorHasItem() then
            ClearCursor()
            RestoreNow()
            print("|cffff4444GearCore:|r Could not move the equipped item into your bags.")
            RefreshButtonState()
            return
        end
    end

    ClearCursor()
    PickupContainerItem(bag, bagSlot)
    if not CursorHasItem() then
        RestoreNow()
        print("|cffff4444GearCore:|r Could not pick up the item from your bag for deletion.")
        RefreshButtonState()
        return
    end

    DeleteCursorItem()

    if GetDeletePopupFrame() or CursorHasItem() then
        awaitingConfirmation = GetDeletePopupFrame() and true or false
        if awaitingConfirmation then
            PositionDeletePopup()
        end
        BeginProcessingMonitor()
        return
    end

    local equippedStillThere, bagStillThere = GetTrackedItemState(item)
    if bagStillThere or equippedStillThere then
        RestoreNow()
        print("|cffff4444GearCore:|r The item was not deleted. Try clicking the button again.")
        RefreshButtonState()
        return
    end

    RemoveFirstPendingItem()
    FinishQueue()
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
