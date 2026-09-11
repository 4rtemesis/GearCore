RustcoreRusted = RustcoreRusted or {}

local rustedFrame        = nil
local pendingRustedItems = {}
local dismissedThisSession = {}  -- items dismissed this session; resets on relog/reload

local TITLE_FONT_PATH = Rustcore.GetAssetPath("Font/RUSTED PERSONAL USE.ttf")
local BODY_FONT_PATH  = Rustcore.GetAssetPath("Font/BPpong.otf")
local TITLE_COLOR     = { 0.7, 0.3, 0.28 }

local ICON_SIZE                = 38
local COMPACT_CELL_GAP         = 6
local ICON_IMAGE_SIZE          = 32
local ICON_TEX_INSET           = 0.10
local ICON_BORDER_SIZE         = 60   -- normal border (UI-Quickslot2)
local RUSTED_OVERLAY_SIZE      = 40   -- rustedframe overlay (slightly smaller)
local COMPACT_ICON_BG_SIZE     = ICON_IMAGE_SIZE - 2
local MAX_ROWS_PER_COLUMN      = 9
local COMPACT_FRAME_MIN_HEIGHT = 300
local COMPACT_FRAME_MIN_WIDTH  = 280
local ICON_ROW_OFFSET_Y        = -125

local DURABLE_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 15, 16, 17, 18 }

-- ── Compat bag helpers ────────────────────────────────────────────────────────

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
        C_Container.PickupContainerItem(bag, slot)
    else
        PickupContainerItem(bag, slot)
    end
end

-- ── Item ID helpers ───────────────────────────────────────────────────────────

local function GetItemID(link)
    if not link then return nil end
    return link:match("item:(%d+)")
end

local function IsDismissed(itemID)
    return itemID and dismissedThisSession[itemID] == true
end

local function MarkDismissed(itemID)
    if not itemID then return end
    dismissedThisSession[itemID] = true
end

local function IsAlreadyPending(itemID)
    for _, item in ipairs(pendingRustedItems) do
        if GetItemID(item.link) == itemID then return true end
    end
    return false
end

-- ── Find + pick up item by ID ─────────────────────────────────────────────────

local function FindAndPickupItem(link)
    local targetID = GetItemID(link)
    if not targetID then return false end

    for _, slot in ipairs(DURABLE_SLOTS) do
        local eLink = GetInventoryItemLink("player", slot)
        if eLink and GetItemID(eLink) == targetID then
            ClearCursor()
            PickupInventoryItem(slot)
            if CursorHasItem() then return true end
        end
    end

    for bag = 0, 4 do
        for slot = 1, BagGetNumSlots(bag) do
            local bLink = BagGetItemLink(bag, slot)
            if bLink and GetItemID(bLink) == targetID then
                ClearCursor()
                BagPickupItem(bag, slot)
                if CursorHasItem() then return true end
            end
        end
    end

    return false
end

local function UpdateSubLabel(f, count)
    if not f or not f.subLabel then return end
    if count and count > 1 then
        f.subLabel:SetText("These items are no longer usable, do you want to delete them?")
    else
        f.subLabel:SetText("This item is no longer usable, do you want to delete it?")
    end
end

-- ── Icon grid ─────────────────────────────────────────────────────────────────

local function ClearRustedIcons()
    if not rustedFrame then return end
    for _, cell in ipairs(rustedFrame.compactIcons or {}) do
        if cell.wipeTimer  then cell.wipeTimer:Cancel();  cell.wipeTimer  = nil end
        if cell.wipeTicker then cell.wipeTicker:Cancel(); cell.wipeTicker = nil end
        cell:Hide()
        cell:SetParent(nil)
    end
    wipe(rustedFrame.compactIcons)
end

local function PopulateRustedIcons(items, skipAnim)
    local f = rustedFrame
    if not f then return end
    ClearRustedIcons()

    local itemCount = #items
    if itemCount == 0 then
        f:Hide()
        return
    end

    local columns       = math.max(1, math.ceil(itemCount / MAX_ROWS_PER_COLUMN))
    local rowsPerColumn = math.ceil(itemCount / columns)
    local rowsInTallest = math.min(itemCount, rowsPerColumn)
    local totalW        = columns * ICON_SIZE + (columns - 1) * COMPACT_CELL_GAP
    local totalH        = rowsInTallest * ICON_SIZE + math.max(0, rowsInTallest - 1) * COMPACT_CELL_GAP
    local frameW        = math.max(totalW + 86, COMPACT_FRAME_MIN_WIDTH)
    local frameH        = math.max(totalH + 260, COMPACT_FRAME_MIN_HEIGHT)

    f:SetSize(frameW, frameH)
    UpdateSubLabel(f, itemCount)

    f.rowContainer:ClearAllPoints()
    f.rowContainer:SetPoint("TOP", f, "TOP", 0, ICON_ROW_OFFSET_Y)
    f.rowContainer:SetWidth(totalW)
    f.rowContainer:SetHeight(totalH)

    local rustedInset = (ICON_BORDER_SIZE - RUSTED_OVERLAY_SIZE) / 2

    for i, item in ipairs(items) do
        local col  = math.floor((i - 1) / rowsPerColumn)
        local row  = (i - 1) % rowsPerColumn
        local xOff = col * (ICON_SIZE + COMPACT_CELL_GAP)
        local yOff = -(row * (ICON_SIZE + COMPACT_CELL_GAP))

        local cell = CreateFrame("Frame", nil, f.rowContainer)
        cell:SetSize(ICON_SIZE, ICON_SIZE)
        cell:SetPoint("TOPLEFT", f.rowContainer, "TOPLEFT", xOff, yOff)
        cell._fallX    = xOff
        cell._fallY    = yOff
        cell._itemLink = item.link

        cell:EnableMouse(true)
        cell:SetScript("OnEnter", function(self)
            if self._itemLink then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self._itemLink)
                GameTooltip:Show()
            end
        end)
        cell:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        local bg = cell:CreateTexture(nil, "BACKGROUND")
        bg:SetSize(COMPACT_ICON_BG_SIZE, COMPACT_ICON_BG_SIZE)
        bg:SetPoint("CENTER", cell, "CENTER", 0, 0)
        bg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
        bg:SetVertexColor(0, 0, 0, 1)

        local icon = cell:CreateTexture(nil, "ARTWORK")
        icon:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
        icon:SetPoint("CENTER", cell, "CENTER", 0, 0)
        icon:SetTexture(item.tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        icon:SetTexCoord(ICON_TEX_INSET, 1 - ICON_TEX_INSET, ICON_TEX_INSET, 1 - ICON_TEX_INSET)

        local sepiaOverlay = cell:CreateTexture(nil, "OVERLAY")
        sepiaOverlay:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
        sepiaOverlay:SetPoint("CENTER", cell, "CENTER", 0, 0)
        sepiaOverlay:SetTexture(item.tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        sepiaOverlay:SetTexCoord(ICON_TEX_INSET, 1 - ICON_TEX_INSET, ICON_TEX_INSET, 1 - ICON_TEX_INSET)
        sepiaOverlay:SetDesaturation(1)
        -- Matches RustcoreDurability's muted sepia tint for the same effect.
        sepiaOverlay:SetVertexColor(0.62, 0.55, 0.48, 1)
        sepiaOverlay:SetShown(i == 1)

        local border = CreateFrame("Frame", nil, cell)
        border:SetSize(ICON_BORDER_SIZE, ICON_BORDER_SIZE)
        border:SetPoint("CENTER", cell, "CENTER", 0, 0)
        border:SetFrameLevel(cell:GetFrameLevel() + 5)  -- normal border on top

        -- Rusted overlay wipes in below the normal border
        local rustedOverlay = CreateFrame("Frame", nil, cell)
        rustedOverlay:SetSize(ICON_BORDER_SIZE, ICON_BORDER_SIZE)
        rustedOverlay:SetPoint("CENTER", cell, "CENTER", 0, 0)
        rustedOverlay:SetFrameLevel(cell:GetFrameLevel() + 4)

        local normalBorderTex = border:CreateTexture(nil, "OVERLAY")
        normalBorderTex:SetAllPoints(border)
        normalBorderTex:SetTexture("Interface\\Buttons\\UI-Quickslot2")

        local rustedBorderTex = rustedOverlay:CreateTexture(nil, "OVERLAY")
        rustedBorderTex:SetPoint("TOPLEFT", rustedOverlay, "TOPLEFT", rustedInset, -rustedInset)
        rustedBorderTex:SetWidth(RUSTED_OVERLAY_SIZE)
        rustedBorderTex:SetHeight(0)
        rustedBorderTex:SetTexture(Rustcore.GetAssetPath("UI/rustedframe.tga"))
        rustedBorderTex:SetTexCoord(0, 1, 0, 0)

        cell._rustedBorderTex = rustedBorderTex

        cell:Show()
        f.compactIcons[#f.compactIcons + 1] = cell
    end

    if not skipAnim then
        local WIPE_DURATION = 0.5

        local playOrder = {}
        for i = 1, itemCount do playOrder[i] = i end
        for i = itemCount, 2, -1 do
            local j = math.random(i)
            playOrder[i], playOrder[j] = playOrder[j], playOrder[i]
        end

        for rank = 1, itemCount do
            local cell  = f.compactIcons[playOrder[rank]]
            local delay = math.max((rank - 1) * 0.3, 0.016)

            cell.wipeTimer = C_Timer.NewTicker(delay, function(self)
                self:Cancel()
                cell.wipeTimer = nil
                if not cell:GetParent() then return end

                PlaySoundFile(Rustcore.GetAssetPath("Audio/rustedsound.wav"), "Master")

                local t0 = GetTime()
                cell.wipeTicker = C_Timer.NewTicker(0.016, function(ticker)
                    if not cell:GetParent() then ticker:Cancel(); return end
                    local elapsed = GetTime() - t0
                    if elapsed >= WIPE_DURATION then
                        ticker:Cancel()
                        cell.wipeTicker = nil
                        if cell._rustedBorderTex then
                            cell._rustedBorderTex:SetHeight(RUSTED_OVERLAY_SIZE)
                            cell._rustedBorderTex:SetTexCoord(0, 1, 0, 1)
                        end
                        return
                    end
                    local t = elapsed / WIPE_DURATION
                    if cell._rustedBorderTex then
                        cell._rustedBorderTex:SetHeight(RUSTED_OVERLAY_SIZE * t)
                        cell._rustedBorderTex:SetTexCoord(0, 1, 0, t)
                    end
                end)
            end, 1)
        end
    else
        for _, cell in ipairs(f.compactIcons) do
            if cell._rustedBorderTex then
                cell._rustedBorderTex:SetHeight(RUSTED_OVERLAY_SIZE)
                cell._rustedBorderTex:SetTexCoord(0, 1, 0, 1)
            end
        end
    end
end

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildRustedFrame()
    if rustedFrame then return rustedFrame end

    local f = CreateFrame("Frame", "RustcoreRustedFrame", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetSize(COMPACT_FRAME_MIN_WIDTH, COMPACT_FRAME_MIN_HEIGHT)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    RustcoreTheme.ApplyFrameSkin(f)

    -- Match the options window: background art below a fixed dark overlay.
    local bgShade = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    bgShade:SetAllPoints(f.rustcoreThemeBackground)
    bgShade:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    bgShade:SetVertexColor(0, 0, 0, 0.62)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -26)
    title:SetFont(TITLE_FONT_PATH, 30, "")
    title:SetTextColor(unpack(TITLE_COLOR))
    title:SetShadowColor(0, 0, 0, 0.6)
    title:SetShadowOffset(1, -1)
    title:SetText("Rusted")

    local subLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    subLabel:SetPoint("TOP", title, "BOTTOM", 0, -10)
    subLabel:SetWidth(220)
    subLabel:SetJustifyH("CENTER")
    subLabel:SetWordWrap(true)
    subLabel:SetFont(BODY_FONT_PATH, 16, "")
    subLabel:SetText("This item is no longer usable, do you want to delete it?")
    f.subLabel = subLabel

    local rowContainer = CreateFrame("Frame", nil, f)
    rowContainer:SetSize(ICON_SIZE, ICON_SIZE)
    f.rowContainer = rowContainer

    local exitBtn = CreateFrame("Button", nil, f)
    exitBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -6)
    exitBtn:SetFrameLevel(f:GetFrameLevel() + 10)
    exitBtn:SetScript("OnClick", function()
        for _, item in ipairs(pendingRustedItems) do
            MarkDismissed(GetItemID(item.link))
        end
        wipe(pendingRustedItems)
        ClearRustedIcons()
        f:Hide()
    end)
    RustcoreTheme.SkinExitButton(exitBtn)

    local btn = CreateFrame("Button", "RustcoreRustedDeleteButton", f)
    btn:SetSize(150, 56)
    local btnLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btnLabel:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn:SetFontString(btnLabel)
    btn:SetText("DELETE")
    btn:SetPoint("BOTTOM", f, "BOTTOM", 0, 36)
    btn:SetScript("OnClick", function() RustcoreRusted.ExecuteDeletion() end)
    RustcoreTheme.SkinDeleteButton(btn)
    f.deleteBtn = btn

    f.compactIcons = {}
    f:Hide()

    rustedFrame = f
    return f
end

-- ── Public API ────────────────────────────────────────────────────────────────

function RustcoreRusted.GetRustedFrame()
    return rustedFrame
end

local FRAME_GAP = 20

local function LayoutBothFrames()
    local df = RustcoreUI and RustcoreUI.GetDeleteFrame and RustcoreUI.GetDeleteFrame()
    if not df or not df:IsShown() or not rustedFrame or not rustedFrame:IsShown() then return end
    local dfW = df:GetWidth()
    local rfW = rustedFrame:GetWidth()
    df:ClearAllPoints()
    df:SetPoint("CENTER", UIParent, "CENTER", -(rfW / 2 + FRAME_GAP / 2), 0)
    rustedFrame:ClearAllPoints()
    rustedFrame:SetPoint("CENTER", UIParent, "CENTER",  dfW / 2 + FRAME_GAP / 2, 0)
end

RustcoreRusted.LayoutFrames = LayoutBothFrames

function RustcoreRusted.ExecuteDeletion()
    if #pendingRustedItems == 0 then return end
    local item = pendingRustedItems[1]

    ClearCursor()
    FindAndPickupItem(item.link)
    if CursorHasItem() then
        DeleteCursorItem()
        PlaySoundFile(Rustcore.GetAssetPath("Audio/Breaksound.flac"), "Master")
    end

    MarkDismissed(GetItemID(item.link))
    table.remove(pendingRustedItems, 1)

    if #pendingRustedItems == 0 then
        ClearRustedIcons()
        if rustedFrame then rustedFrame:Hide() end
    else
        PopulateRustedIcons(pendingRustedItems, true)
    end
end

-- ── Durability scan ───────────────────────────────────────────────────────────

local function ScanAndQueue()
    for _, slot in ipairs(DURABLE_SLOTS) do
        local link   = GetInventoryItemLink("player", slot)
        local itemID = link and GetItemID(link)
        if itemID then
            local current, max = GetInventoryItemDurability(slot)
            if current ~= nil and max and max > 0 and current == 0 then
                if not IsDismissed(itemID) and not IsAlreadyPending(itemID) then
                    pendingRustedItems[#pendingRustedItems + 1] = {
                        link = link,
                        tex  = GetInventoryItemTexture("player", slot),
                    }
                end
            end
        end
    end
end

local function TryShowRustedFrame(hasNewItems)
    if #pendingRustedItems == 0 then return end
    if UnitAffectingCombat("player") or InCombatLockdown() then return end

    local f = BuildRustedFrame()
    RustcoreTheme.SetDifficultyBackground(f, Rustcore.GetSetting("difficulty"))
    local alreadyShown = f:IsShown()

    -- If the frame is already visible and no new items were added, leave the
    -- running wipe animation and sound alone — don't repopulate and cancel them.
    if alreadyShown and not hasNewItems then return end

    -- Play animation only when opening fresh; skip it if adding items to an open frame.
    PopulateRustedIcons(pendingRustedItems, alreadyShown)
    if not alreadyShown then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", 60, 60)
    end
    f:Show()
    LayoutBothFrames()
end

local function ScanBrokenItems()
    local countBefore = #pendingRustedItems
    ScanAndQueue()
    TryShowRustedFrame(#pendingRustedItems > countBefore)
end

-- ── Events ────────────────────────────────────────────────────────────────────

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_ALIVE" then
        -- Spirit healer applies penalty at unpredictable time; scan twice to catch it
        C_Timer.After(0.5, ScanBrokenItems)
        C_Timer.After(2.5, ScanBrokenItems)
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended — rescan in case items rusted during combat
        ScanBrokenItems()
    else
        ScanBrokenItems()
    end
end)
