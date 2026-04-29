-- GearCore: Hardcore gear-loss addon for WoW Classic
-- Records equipped items at combat entry to prevent unequip-before-death cheating.
-- On death, marks a subset of items for deletion based on difficulty setting.

GearCoreDB = GearCoreDB or {}

GearCore = {}

local defaults = {
    difficulty    = 2,     -- 1=Lite, 2=Difficult, 3=Extreme
    selfFound     = false, -- block mailbox / AH / trade
    blockRepair   = false, -- disable merchant repair buttons
    keepMainWeapon = false, -- spare main weapon slot from deletion
}

-- Gear slots tracked (shirt=4, tabard=19 excluded)
local GEAR_SLOTS = { 1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18 }

-- Classes whose ranged slot (18) is a wand, not a bow/gun
local WAND_CLASSES = { PRIEST=true, MAGE=true, WARLOCK=true }

local combatSnapshot = {}  -- items recorded on combat entry
local markedItems    = {}  -- items selected for deletion after death
local isDead         = false

-- ── Settings ──────────────────────────────────────────────────────────────────

function GearCore.GetSetting(key)
    if GearCoreDB[key] == nil then
        GearCoreDB[key] = defaults[key]
    end
    return GearCoreDB[key]
end

function GearCore.SetSetting(key, value)
    GearCoreDB[key] = value
end

local function InitSettings()
    for k, v in pairs(defaults) do
        if GearCoreDB[k] == nil then
            GearCoreDB[k] = v
        end
    end
end

-- ── Weapon-slot detection ─────────────────────────────────────────────────────

local function GetMainWeaponSlot()
    local _, class = UnitClass("player")
    if class == "HUNTER" then
        return 18  -- ranged weapon
    elseif WAND_CLASSES[class] then
        -- Use wand if equipped, otherwise mainhand
        if GetInventoryItemLink("player", 18) then
            return 18
        end
        return 16
    else
        return 16  -- mainhand for all melee classes
    end
end

-- ── Combat snapshot ───────────────────────────────────────────────────────────

local function TakeSnapshot()
    wipe(combatSnapshot)
    local skipSlot = GearCore.GetSetting("keepMainWeapon") and GetMainWeaponSlot() or nil
    for _, slotId in ipairs(GEAR_SLOTS) do
        if slotId ~= skipSlot then
            local link = GetInventoryItemLink("player", slotId)
            if link then
                local name = GetItemInfo(link)
                combatSnapshot[#combatSnapshot + 1] = {
                    slot = slotId,
                    link = link,
                    name = name or ("Slot " .. slotId),
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

    local difficulty = GearCore.GetSetting("difficulty")

    if difficulty == 1 then
        -- Lite: lose 1 random item
        markedItems[1] = source[math.random(#source)]

    elseif difficulty == 2 then
        -- Difficult: keep 2 random items, lose the rest
        if #source <= 2 then return end
        local pool = {}
        for _, item in ipairs(source) do pool[#pool+1] = item end
        ShuffleInPlace(pool)
        for i = 3, #pool do
            markedItems[#markedItems+1] = pool[i]
        end

    elseif difficulty == 3 then
        -- Extreme: lose everything
        for _, item in ipairs(source) do
            markedItems[#markedItems+1] = item
        end
    end
end

local function OnPlayerDead()
    local source = (#combatSnapshot > 0) and combatSnapshot or nil
    if not source then
        TakeSnapshot()
        source = combatSnapshot
    end

    BuildMarkedItems(source)

    if #markedItems > 0 then
        -- Persist to SavedVariables so a logout-while-dead can't dodge the penalty.
        GearCoreDB.pendingDeletion = {}
        for _, item in ipairs(markedItems) do
            GearCoreDB.pendingDeletion[#GearCoreDB.pendingDeletion+1] = {
                slot = item.slot, link = item.link, name = item.name,
            }
        end
        GearCoreUI.ShowDeletionFrame(markedItems)
    else
        print("|cffff4444GearCore:|r No items marked for deletion.")
    end
end

-- ── Merchant repair blocking ──────────────────────────────────────────────────

local function ApplyRepairBlock()
    if GearCore.GetSetting("blockRepair") then
        if MerchantRepairAllButton  then MerchantRepairAllButton:Disable();  MerchantRepairAllButton:SetAlpha(0.35)  end
        if MerchantRepairItemButton then MerchantRepairItemButton:Disable(); MerchantRepairItemButton:SetAlpha(0.35) end
    end
end

local function ResetRepairButtons()
    if MerchantRepairAllButton  then MerchantRepairAllButton:Enable();  MerchantRepairAllButton:SetAlpha(1) end
    if MerchantRepairItemButton then MerchantRepairItemButton:Enable(); MerchantRepairItemButton:SetAlpha(1) end
end

-- ── Event handling ────────────────────────────────────────────────────────────

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("TRADE_SHOW")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")
eventFrame:RegisterEvent("PLAYER_UNGHOST")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if (...) == "GearCore" then
            InitSettings()
            print("|cffff4444GearCore|r loaded. |cffffd700/gearcore|r for options.")

            -- Handle pending deletions from a previous session (player logged out while dead).
            if GearCoreDB.pendingDeletion and #GearCoreDB.pendingDeletion > 0 then
                if UnitIsDeadOrGhost("player") then
                    -- Still dead/ghost: show the window, wait for PLAYER_UNGHOST to fire.
                    GearCoreUI.ShowDeletionFrame(GearCoreDB.pendingDeletion)
                else
                    -- Logged in alive (soulstone, rez'd before logout, etc.).
                    print("|cffff4444GearCore:|r Pending death penalty detected — open the GearCore window and click to process each item.")
                    C_Timer.After(1, function()
                        GearCoreUI.ShowDeletionFrame(GearCoreDB.pendingDeletion)
                    end)
                end
            end
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        TakeSnapshot()

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Clear snapshot when leaving combat alive so stale data isn't used later
        if not isDead then
            wipe(combatSnapshot)
        end

    elseif event == "PLAYER_DEAD" then
        isDead = true
        OnPlayerDead()

    elseif event == "PLAYER_ALIVE" then
        -- Fires on release-spirit (player is still a ghost) AND on battle-rez (fully alive).
        -- Only trigger deletion here for the battle-rez case; spirit-healer uses PLAYER_UNGHOST.
        isDead = false
        wipe(combatSnapshot)
        wipe(markedItems)

        if not UnitIsDeadOrGhost("player") then
            if GearCoreDB.pendingDeletion and #GearCoreDB.pendingDeletion > 0 then
                print("|cffff4444GearCore:|r Resurrection detected — click the GearCore button to process your pending deletions.")
                C_Timer.After(1, function()
                    GearCoreUI.ShowDeletionFrame(GearCoreDB.pendingDeletion)
                end)
            end
        end

    elseif event == "PLAYER_UNGHOST" then
        -- Fires when the player fully resurrects from ghost state (spirit healer or corpse run).
        if GearCoreDB.pendingDeletion and #GearCoreDB.pendingDeletion > 0 then
            print("|cffff4444GearCore:|r Resurrection detected — click the GearCore button to process your pending deletions.")
            C_Timer.After(1, function()
                GearCoreUI.ShowDeletionFrame(GearCoreDB.pendingDeletion)
            end)
        end

    elseif event == "MAIL_SHOW" then
        if GearCore.GetSetting("selfFound") then
            C_Timer.After(0, function() HideUIPanel(MailFrame) end)
            print("|cffff4444GearCore:|r Mailbox blocked (Self-Found mode).")
        end

    elseif event == "AUCTION_HOUSE_SHOW" then
        if GearCore.GetSetting("selfFound") then
            C_Timer.After(0, function() HideUIPanel(AuctionFrame) end)
            print("|cffff4444GearCore:|r Auction House blocked (Self-Found mode).")
        end

    elseif event == "TRADE_SHOW" then
        if GearCore.GetSetting("selfFound") then
            C_Timer.After(0, function() CloseTrade() end)
            print("|cffff4444GearCore:|r Trading blocked (Self-Found mode).")
        end

    elseif event == "MERCHANT_SHOW" then
        ApplyRepairBlock()

    elseif event == "MERCHANT_CLOSED" then
        ResetRepairButtons()
    end
end)

-- ── Block auto-repair from other addons ──────────────────────────────────────
-- Disabling the UI buttons only stops clicks; other addons call RepairAllItems()
-- directly. Wrapping the global function intercepts all callers.
do
    local _orig = RepairAllItems
    RepairAllItems = function(guildBank)
        if GearCore.GetSetting("blockRepair") then
            print("|cffff4444GearCore:|r Repair blocked.")
            return
        end
        return _orig(guildBank)
    end
end

-- ── Slash commands ────────────────────────────────────────────────────────────

SLASH_GEARCORE1 = "/gearcore"
SLASH_GEARCORE2 = "/gc"
SlashCmdList["GEARCORE"] = function()
    GearCoreOptions.Toggle()
end
