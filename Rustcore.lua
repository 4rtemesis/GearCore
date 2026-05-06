-- Rustcore: Hardcore gear-loss addon for WoW Classic
-- Records equipped items at combat entry to prevent unequip-before-death cheating.
-- On death, marks a subset of items for deletion based on difficulty setting.

RustcoreDB = RustcoreDB or {}

Rustcore = {}

local function GetCurrentCharacterKey()
    local guid = UnitGUID and UnitGUID("player")
    if guid and guid ~= "" then return guid end
    local name, realm = UnitFullName and UnitFullName("player")
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return UnitName("player")
end

local defaults = {
    difficulty      = 2,     -- 1=Lite, 2=Normal, 3=Hard, 4=Brutal, 5=Extreme
    selfFound       = false, -- block mailbox / AH / trade
    allowRepair     = false, -- if false (default), repair is blocked
    keepMainWeapon  = false, -- spare main weapon slot from deletion
    showMinimapButton = true, -- show the minimap launcher button
    broadcastDeaths = true,  -- broadcast death to Rustcore channel
    showDeathPopup  = true,  -- show popup notification for other players' deaths
    showDeathWarning= false, -- show center-screen warning for other players' deaths
}

-- Gear slots tracked (shirt=4, tabard=19 excluded)
local GEAR_SLOTS = { 1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18 }

-- Classes whose ranged slot (18) is a wand, not a bow/gun
local WAND_CLASSES = { PRIEST=true, MAGE=true, WARLOCK=true }

local combatSnapshot  = {}   -- items recorded on combat entry
local markedItems     = {}   -- items selected for deletion after death
local isDead          = false
local lastDeathSource = nil  -- last attacker/environment that hit the player
local minimapButton
local UpdateMinimapButtonPosition
local minimapShapes = {
    ["ROUND"] = {true, true, true, true},
    ["SQUARE"] = {false, false, false, false},
    ["CORNER-TOPLEFT"] = {false, false, false, true},
    ["CORNER-TOPRIGHT"] = {false, false, true, false},
    ["CORNER-BOTTOMLEFT"] = {false, true, false, false},
    ["CORNER-BOTTOMRIGHT"] = {true, false, false, false},
    ["SIDE-LEFT"] = {false, true, false, true},
    ["SIDE-RIGHT"] = {true, false, true, false},
    ["SIDE-TOP"] = {false, false, true, true},
    ["SIDE-BOTTOM"] = {true, true, false, false},
    ["TRICORNER-TOPLEFT"] = {false, true, true, true},
    ["TRICORNER-TOPRIGHT"] = {true, false, true, true},
    ["TRICORNER-BOTTOMLEFT"] = {true, true, false, true},
    ["TRICORNER-BOTTOMRIGHT"] = {true, true, true, false},
}

local function GetMinimapAngleFromCursor()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    return math.deg(math.atan2(cy - my, cx - mx)) % 360
end

local function ApplyMinimapButtonVisibility()
    if not minimapButton then return end
    if Rustcore.GetSetting("showMinimapButton") then
        minimapButton:Show()
        UpdateMinimapButtonPosition()
    else
        minimapButton:Hide()
    end
end

-- ── Settings ──────────────────────────────────────────────────────────────────

function Rustcore.GetSetting(key)
    if RustcoreDB[key] == nil then
        RustcoreDB[key] = defaults[key]
    end
    return RustcoreDB[key]
end

function Rustcore.SettingsLocked()
    return InCombatLockdown and InCombatLockdown()
end

function Rustcore.GetCharacterKey()
    return GetCurrentCharacterKey()
end

function Rustcore.GetAssetPath(filename)
    local folder = Rustcore.assetFolder or "Rustcore"
    return "Interface\\AddOns\\" .. folder .. "\\" .. filename
end

function Rustcore.SetSetting(key, value)
    if Rustcore.SettingsLocked() then
        print("|cffff4444Rustcore:|r Settings cannot be changed while in combat.")
        return false
    end
    RustcoreDB[key] = value
    if key == "showMinimapButton" then
        ApplyMinimapButtonVisibility()
    end
    return true
end

local function InitSettings()
    for k, v in pairs(defaults) do
        if RustcoreDB[k] == nil then
            RustcoreDB[k] = v
        end
    end
    -- Migrate old blockRepair key to allowRepair
    if RustcoreDB.blockRepair ~= nil and RustcoreDB.allowRepair == nil then
        RustcoreDB.allowRepair = not RustcoreDB.blockRepair
        RustcoreDB.blockRepair = nil
    end
end

-- ── Weapon-slot detection ─────────────────────────────────────────────────────

local function GetMainWeaponSlot()
    local _, class = UnitClass("player")
    if class == "HUNTER" then
        return 18  -- ranged weapon
    elseif WAND_CLASSES[class] then
        if GetInventoryItemLink("player", 18) then
            return 18
        end
        return 16
    else
        return 16
    end
end

-- ── Combat snapshot ───────────────────────────────────────────────────────────

local function TakeSnapshot()
    wipe(combatSnapshot)
    local skipSlot = Rustcore.GetSetting("keepMainWeapon") and GetMainWeaponSlot() or nil
    for _, slotId in ipairs(GEAR_SLOTS) do
        if slotId ~= skipSlot then
            local link = GetInventoryItemLink("player", slotId)
            if link then
                local name = GetItemInfo(link)
                local tex = GetInventoryItemTexture("player", slotId) or GetItemIcon(link)
                combatSnapshot[#combatSnapshot + 1] = {
                    slot = slotId,
                    link = link,
                    name = name or ("Slot " .. slotId),
                    tex = tex,
                }
            end
        end
    end
end

-- ── Death logic ───────────────────────────────────────────────────────────────

local function ShuffleInPlace(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end

local function BuildMarkedItems(source)
    wipe(markedItems)
    if #source == 0 then return end

    local difficulty = Rustcore.GetSetting("difficulty")

    if difficulty == 1 then
        -- Lite: repair is blocked, no items lost
        return

    elseif difficulty == 2 then
        -- Normal: lose 1 random item
        markedItems[1] = source[math.random(#source)]

    elseif difficulty == 3 then
        -- Hard: lose 25% rounded up
        local pool = {}
        for _, item in ipairs(source) do pool[#pool+1] = item end
        ShuffleInPlace(pool)
        local loseCount = math.ceil(#pool * 0.25)
        for i = 1, loseCount do
            markedItems[#markedItems+1] = pool[i]
        end

    elseif difficulty == 4 then
        -- Brutal: lose 50% rounded up
        local pool = {}
        for _, item in ipairs(source) do pool[#pool+1] = item end
        ShuffleInPlace(pool)
        local loseCount = math.ceil(#pool * 0.50)
        for i = 1, loseCount do
            markedItems[#markedItems+1] = pool[i]
        end

    elseif difficulty == 5 then
        -- Extreme: lose everything
        for _, item in ipairs(source) do
            markedItems[#markedItems+1] = item
        end
    end
end

local function OnPlayerDead()
    local ok, err = pcall(function()
        local source = (#combatSnapshot > 0) and combatSnapshot or nil
        if not source then
            TakeSnapshot()
            source = combatSnapshot
        end

        BuildMarkedItems(source)

        if #markedItems > 0 then
            RustcoreDB.pendingDeletion = {}
            RustcoreDB.pendingDeletionSnapshot = {}
            RustcoreDB.pendingDeletionOwner = GetCurrentCharacterKey()
            for _, item in ipairs(markedItems) do
                RustcoreDB.pendingDeletion[#RustcoreDB.pendingDeletion+1] = {
                    slot = item.slot, link = item.link, name = item.name, tex = item.tex,
                }
            end
            for _, item in ipairs(source) do
                RustcoreDB.pendingDeletionSnapshot[#RustcoreDB.pendingDeletionSnapshot+1] = {
                    slot = item.slot, link = item.link, name = item.name, tex = item.tex,
                }
            end
            RustcoreDB.lastDeathSource = lastDeathSource
            RustcoreBroadcast.Announce(markedItems, lastDeathSource)
            RustcoreUI.ShowDeletionFrame(markedItems, source)
        else
            if Rustcore.GetSetting("difficulty") == 1 then
                print("|cffff4444Rustcore:|r Lite mode — no items lost.")
            else
                print("|cffff4444Rustcore:|r No items marked for deletion.")
            end
        end
    end)
    if not ok then
        print("|cffff4444Rustcore ERROR:|r " .. tostring(err))
    end
end

-- ── Merchant repair blocking ──────────────────────────────────────────────────

local function ApplyRepairBlock()
    if not Rustcore.GetSetting("allowRepair") then
        if MerchantRepairAllButton  then MerchantRepairAllButton:Disable();  MerchantRepairAllButton:SetAlpha(0.35)  end
        if MerchantRepairItemButton then MerchantRepairItemButton:Disable(); MerchantRepairItemButton:SetAlpha(0.35) end
    end
end

local function ResetRepairButtons()
    if MerchantRepairAllButton  then MerchantRepairAllButton:Enable();  MerchantRepairAllButton:SetAlpha(1) end
    if MerchantRepairItemButton then MerchantRepairItemButton:Enable(); MerchantRepairItemButton:SetAlpha(1) end
end

local function ClearPendingDeletionData()
    RustcoreDB.pendingDeletion = nil
    RustcoreDB.pendingDeletionSnapshot = nil
    RustcoreDB.pendingDeletionOwner = nil
    RustcoreDB.lastDeathSource = nil
end

local function PendingDeletionBelongsToCurrentCharacter()
    return RustcoreDB.pendingDeletionOwner == nil or RustcoreDB.pendingDeletionOwner == GetCurrentCharacterKey()
end

-- ── Event handling ────────────────────────────────────────────────────────────

UpdateMinimapButtonPosition = function()
    if not minimapButton then return end
    local angle = math.rad(RustcoreDB.minimapAngle or 220)
    local x, y = math.cos(angle), math.sin(angle)
    local quadrant = 1
    if x < 0 then quadrant = quadrant + 1 end
    if y > 0 then quadrant = quadrant + 2 end
    local minimapShape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local quadTable = minimapShapes[minimapShape] or minimapShapes["ROUND"]
    local radius = 5
    local width = (Minimap:GetWidth() / 2) + radius
    local height = (Minimap:GetHeight() / 2) + radius
    if quadTable[quadrant] then
        x, y = x * width, y * height
    else
        local diagWidth = math.sqrt(2 * (width ^ 2)) - 10
        local diagHeight = math.sqrt(2 * (height ^ 2)) - 10
        x = math.max(-width, math.min(x * diagWidth, width))
        y = math.max(-height, math.min(y * diagHeight, height))
    end
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    if minimapButton or not Minimap then return end

    local btn = CreateFrame("Button", "RustcoreMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForDrag("LeftButton")
    btn:RegisterForClicks("AnyUp")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -5)
    bg:SetVertexColor(0.15, 0.15, 0.15)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(Rustcore.GetAssetPath("RCicon.png"))
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -6)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon
    btn.iconBaseSize = 17

    if btn.CreateMaskTexture and icon.AddMaskTexture then
        local mask = btn:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetPoint("CENTER", icon, "CENTER", 0, 0)
        mask:SetSize(17, 17)
        icon:AddMaskTexture(mask)
        btn.iconMask = mask
    end

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    local highlight = btn:GetHighlightTexture()
    highlight:SetBlendMode("ADD")
    highlight:SetSize(53, 53)
    highlight:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    local clickAnim = icon:CreateAnimationGroup()
    local shrink = clickAnim:CreateAnimation("Scale")
    shrink:SetOrder(1)
    shrink:SetDuration(0.06)
    shrink:SetScale(0.88, 0.88)
    shrink:SetOrigin("CENTER", 0, 0)

    local grow = clickAnim:CreateAnimation("Scale")
    grow:SetOrder(2)
    grow:SetDuration(0.08)
    grow:SetScale(1.1363636, 1.1363636)
    grow:SetOrigin("CENTER", 0, 0)

    clickAnim:SetScript("OnPlay", function()
        if btn.icon then
            btn.icon:SetSize(btn.iconBaseSize, btn.iconBaseSize)
        end
    end)
    clickAnim:SetScript("OnFinished", function()
        if btn.icon then
            btn.icon:SetSize(btn.iconBaseSize, btn.iconBaseSize)
        end
    end)
    btn.clickAnim = clickAnim

    btn:SetScript("OnEnter", function(self)
        if self:GetHighlightTexture() then
            self:GetHighlightTexture():Show()
        end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Rustcore")
        GameTooltip:AddLine("Left-click: Open options", 1, 1, 1)
        GameTooltip:AddLine("Right-click: Show pending deletions", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        if self:GetHighlightTexture() then
            self:GetHighlightTexture():Hide()
        end
        GameTooltip:Hide()
    end)
    btn:SetScript("OnClick", function(_, button)
        if btn.clickAnim then
            btn.clickAnim:Stop()
            btn.clickAnim:Play()
        end
        if button == "RightButton" then
            RustcoreUI.ReopenDeletionFrame()
        else
            RustcoreOptions.Toggle()
        end
    end)
    btn:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        self.dragging = true
        self:SetScript("OnUpdate", function()
            RustcoreDB.minimapAngle = GetMinimapAngleFromCursor()
            UpdateMinimapButtonPosition()
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:UnlockHighlight()
        self.dragging = nil
        self:SetScript("OnUpdate", nil)
        RustcoreDB.minimapAngle = GetMinimapAngleFromCursor()
        UpdateMinimapButtonPosition()
    end)

    minimapButton = btn
    ApplyMinimapButtonVisibility()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_UNGHOST")
eventFrame:RegisterEvent("UI_SCALE_CHANGED")
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("TRADE_SHOW")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if (...) == "Rustcore" then
            Rustcore.assetFolder = (...)
            InitSettings()
            RustcoreBroadcast.Init()
            CreateMinimapButton()
            print("|cffff4444Rustcore|r loaded. |cffffd700/rustcore|r for options.")

            if RustcoreDB.pendingDeletion and not PendingDeletionBelongsToCurrentCharacter() then
                ClearPendingDeletionData()
            end

            if RustcoreDB.pendingDeletion and #RustcoreDB.pendingDeletion > 0 then
                if UnitIsDeadOrGhost("player") then
                    RustcoreUI.ShowDeletionFrame(RustcoreDB.pendingDeletion, RustcoreDB.pendingDeletionSnapshot)
                else
                    print("|cffff4444Rustcore:|r Pending death penalty detected — open the Rustcore window and click to process each item.")
                    C_Timer.After(1, function()
                        RustcoreUI.ShowDeletionFrame(RustcoreDB.pendingDeletion, RustcoreDB.pendingDeletionSnapshot)
                    end)
                end
            end
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        TakeSnapshot()

    elseif event == "PLAYER_REGEN_ENABLED" then
        if not isDead then
            wipe(combatSnapshot)
            lastDeathSource = nil
        end

    elseif event == "PLAYER_DEAD" then
        isDead = true
        OnPlayerDead()

    elseif event == "PLAYER_ALIVE" then
        isDead = false
        wipe(combatSnapshot)
        wipe(markedItems)
        lastDeathSource = nil

        if not UnitIsDeadOrGhost("player") then
            if RustcoreDB.pendingDeletion and #RustcoreDB.pendingDeletion > 0 then
                print("|cffff4444Rustcore:|r Resurrection detected — click the Rustcore button to process your pending deletions.")
                C_Timer.After(1, function()
                    RustcoreUI.OnResurrect(RustcoreDB.pendingDeletion, RustcoreDB.pendingDeletionSnapshot)
                end)
            end
        end

    elseif event == "PLAYER_UNGHOST" then
        if UnitIsDeadOrGhost("player") then return end
        if RustcoreDB.pendingDeletion and #RustcoreDB.pendingDeletion > 0 then
            print("|cffff4444Rustcore:|r Resurrection detected — click the Rustcore button to process your pending deletions.")
            C_Timer.After(1, function()
                RustcoreUI.OnResurrect(RustcoreDB.pendingDeletion, RustcoreDB.pendingDeletionSnapshot)
            end)
        end

    elseif event == "PLAYER_ENTERING_WORLD" or event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        UpdateMinimapButtonPosition()

    elseif event == "MAIL_SHOW" then
        if Rustcore.GetSetting("selfFound") then
            C_Timer.After(0, function() HideUIPanel(MailFrame) end)
            print("|cffff4444Rustcore:|r Mailbox blocked (Self-Found mode).")
        end

    elseif event == "AUCTION_HOUSE_SHOW" then
        if Rustcore.GetSetting("selfFound") then
            C_Timer.After(0, function() HideUIPanel(AuctionFrame) end)
            print("|cffff4444Rustcore:|r Auction House blocked (Self-Found mode).")
        end

    elseif event == "TRADE_SHOW" then
        if Rustcore.GetSetting("selfFound") then
            C_Timer.After(0, function() CloseTrade() end)
            print("|cffff4444Rustcore:|r Trading blocked (Self-Found mode).")
        end

    elseif event == "MERCHANT_SHOW" then
        ApplyRepairBlock()

    elseif event == "MERCHANT_CLOSED" then
        ResetRepairButtons()

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender = ...
        RustcoreBroadcast.OnAddonMessage(prefix, message, distribution, sender)
    end
end)

-- ── Combat log ────────────────────────────────────────────────────────────────
do
    local playerGUID
    local clFrame = CreateFrame("Frame")
    clFrame:RegisterEvent("PLAYER_LOGIN")
    clFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    clFrame:SetScript("OnEvent", function(_, ev, ...)
        if ev == "PLAYER_LOGIN" then
            playerGUID = UnitGUID("player")
            return
        end
        local _, subEv, _, _, srcName, _, _, dstGUID = CombatLogGetCurrentEventInfo()
        if not subEv or dstGUID ~= playerGUID then return end
        if subEv == "ENVIRONMENTAL_DAMAGE" then
            lastDeathSource = select(12, CombatLogGetCurrentEventInfo())
        elseif subEv:find("DAMAGE", 1, true) and srcName and srcName ~= "" then
            lastDeathSource = srcName
        end
    end)
end

-- ── Block auto-repair from other addons ──────────────────────────────────────
do
    local _orig = RepairAllItems
    RepairAllItems = function(guildBank)
        if not Rustcore.GetSetting("allowRepair") then
            print("|cffff4444Rustcore:|r Repair blocked.")
            return
        end
        return _orig(guildBank)
    end
end

-- ── Slash commands ────────────────────────────────────────────────────────────

SLASH_RUSTCORE1 = "/rustcore"
SLASH_RUSTCORE2 = "/rc"
SlashCmdList["RUSTCORE"] = function()
    RustcoreOptions.Toggle()
end
