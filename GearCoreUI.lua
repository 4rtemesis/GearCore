-- GearCore: Deletion confirmation UI
-- Lists items marked for deletion and provides a single button to destroy them.
-- Rare+ items will trigger WoW's native "type DELETE" confirmation dialog per item.

GearCoreUI = {}

local deleteFrame
local pendingItems = {}
local deleteQueue  = {}
local deleteIndex  = 0

-- On the modern WoW engine (post-Shadowlands, used by all Anniversary clients),
-- SetBackdrop is only available on frames that inherit BackdropTemplate.
-- On older engines it is a native Frame method. This covers both cases.
local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildFrame()
    local f = CreateFrame("Frame", "GearCoreDeletionFrame", UIParent, backdropTemplate)
    f:SetSize(330, 460)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
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

    -- Scroll area background
    local scrollBG = CreateFrame("Frame", nil, f, backdropTemplate)
    scrollBG:SetPoint("TOPLEFT",  f, "TOPLEFT",   16, -68)
    scrollBG:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 78)
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

    local warn = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warn:SetPoint("BOTTOM", f, "BOTTOM", 0, 52)
    warn:SetTextColor(1, 0.3, 0.3)
    warn:SetText("Rare+ items require you to type DELETE in the confirmation box.")

    local btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btn:SetSize(210, 30)
    btn:SetPoint("BOTTOM", f, "BOTTOM", 0, 16)
    btn:SetText("DELETE MARKED ITEMS")
    btn:SetScript("OnClick", GearCoreUI.ExecuteDeletion)
    f.deleteBtn = btn

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    f:Hide()
    return f
end

local function EnsureFrame()
    if not deleteFrame then deleteFrame = BuildFrame() end
    return deleteFrame
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

local function BagPickup(bag, slot)
    if C_Container then C_Container.PickupContainerItem(bag, slot)
    else PickupContainerItem(bag, slot) end
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

-- Shows the doom window. While dead the button is locked — deletion fires
-- automatically on resurrection via GearCore's PLAYER_ALIVE handler.
function GearCoreUI.ShowDeletionFrame(items)
    wipe(pendingItems)
    for _, item in ipairs(items) do pendingItems[#pendingItems+1] = item end
    PopulateList(pendingItems)
    local f = EnsureFrame()

    if UnitIsDeadOrGhost("player") then
        f.deleteBtn:SetText("Will be deleted on resurrection")
        f.deleteBtn:Disable()
    else
        f.deleteBtn:SetText("DELETE MARKED ITEMS")
        f.deleteBtn:Enable()
    end

    f:Show()
    f:Raise()
end

-- Called by the button (alive path) or by TriggerDeletion (auto-resurrection path).
function GearCoreUI.ExecuteDeletion()
    if UnitIsDeadOrGhost("player") then
        print("|cffff4444GearCore:|r You are dead. Items will be deleted automatically when you resurrect.")
        return
    end

    wipe(deleteQueue)
    for _, item in ipairs(pendingItems) do
        if GetInventoryItemLink("player", item.slot) then
            deleteQueue[#deleteQueue+1] = item.slot
        end
    end

    if #deleteQueue == 0 then
        print("|cffff4444GearCore:|r No items found in marked slots.")
        if deleteFrame then deleteFrame:Hide() end
        return
    end

    deleteIndex = 1
    GearCoreUI.ProcessNext()
end

-- Called by GearCore on PLAYER_ALIVE with the persisted pending-deletion list.
function GearCoreUI.TriggerDeletion(items)
    -- Repopulate and show the window so the player can see what's being deleted.
    GearCoreUI.ShowDeletionFrame(items)
    -- Small delay so the resurrection animation settles before we touch inventory.
    C_Timer.After(0.5, GearCoreUI.ExecuteDeletion)
end

-- ── Deletion sequence ─────────────────────────────────────────────────────────
-- Items are moved to a bag slot first, then deleted from the bag.
-- This is necessary because equipped items cannot be deleted directly on some clients.

function GearCoreUI.ProcessNext()
    -- Pause if WoW's "type DELETE to confirm" dialog is open (rare+ items).
    if StaticPopup_Visible and StaticPopup_Visible("DELETE_ITEM") then
        C_Timer.After(0.5, GearCoreUI.ProcessNext)
        return
    end

    if deleteIndex > #deleteQueue then
        GearCoreUI.VerifyAndFinish()
        return
    end

    local slotId = deleteQueue[deleteIndex]
    deleteIndex  = deleteIndex + 1

    ClearCursor()
    PickupInventoryItem(slotId)

    if not CursorHasItem() then
        C_Timer.After(0, GearCoreUI.ProcessNext)
        return
    end

    local bag, bagSlot = FindEmptyBagSlot()
    if not bag then
        ClearCursor()
        deleteIndex = deleteIndex - 1
        print("|cffff4444GearCore:|r Need at least 1 empty bag slot. Free up space and click Delete again.")
        if deleteFrame then
            deleteFrame.deleteBtn:SetText("DELETE MARKED ITEMS")
            deleteFrame.deleteBtn:Enable()
        end
        return
    end

    -- Move: equipped slot → bag slot
    BagPickup(bag, bagSlot)

    -- One tick for the client to register the move, then pick up from bag and delete.
    C_Timer.After(0.25, function()
        ClearCursor()
        BagPickup(bag, bagSlot)
        if CursorHasItem() then
            DeleteCursorItem()
        end
        C_Timer.After(0.25, GearCoreUI.ProcessNext)
    end)
end

function GearCoreUI.VerifyAndFinish()
    local failCount = 0
    for _, item in ipairs(pendingItems) do
        if GetInventoryItemLink("player", item.slot) then
            failCount = failCount + 1
        end
    end

    wipe(pendingItems)
    wipe(deleteQueue)

    if failCount > 0 then
        print("|cffff4444GearCore:|r Warning: " .. failCount .. " item(s) may not have been deleted — check your equipped slots.")
    else
        print("|cffff4444GearCore:|r Deletion complete — all marked items removed.")
    end

    if deleteFrame then deleteFrame:Hide() end
end
