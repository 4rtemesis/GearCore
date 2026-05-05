-- Rustcore: Hardcore gear-loss addon for WoW Classic
-- Records equipped items at combat entry to prevent unequip-before-death cheating.
-- On death, marks a subset of items for deletion based on difficulty setting.

RustcoreDB = RustcoreDB or {}

Rustcore = {}

local defaults = {
    difficulty      = 2,     -- 1=Lite, 2=Normal, 3=Hard, 4=Brutal, 5=Extreme
    selfFound       = false, -- block mailbox / AH / trade
    allowRepair     = false, -- if false (default), repair is blocked
    keepMainWeapon  = false, -- spare main weapon slot from deletion
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

function Rustcore.SetSetting(key, value)
    if Rustcore.SettingsLocked() then
        print("|cffff4444Rustcore:|r Settings cannot be changed while in combat.")
        return false
    end
    RustcoreDB[key] = value
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
    print("|cffff4444Rustcore DEBUG:|r OnPlayerDead called.")
    local ok, err = pcall(function()
        local source = (#combatSnapshot > 0) and combatSnapshot or nil
        print("|cffff4444Rustcore DEBUG:|r snapshot=" .. #combatSnapshot)
        if not source then
            TakeSnapshot()
            source = combatSnapshot
            print("|cffff4444Rustcore DEBUG:|r fallback snapshot=" .. #source)
        end

        BuildMarkedItems(source)
        print("|cffff4444Rustcore DEBUG:|r marked=" .. #markedItems)

        if #markedItems > 0 then
            RustcoreDB.pendingDeletion = {}
            RustcoreDB.pendingDeletionSnapshot = {}
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

-- ── Event handling ────────────────────────────────────────────────────────────

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_UNGHOST")
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("TRADE_SHOW")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if (...) == "GearCore" or (...) == "Rustcore" then
            InitSettings()
            RustcoreBroadcast.Init()
            print("|cffff4444Rustcore|r loaded. |cffffd700/rustcore|r for options.")

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
        print("|cffff4444Rustcore DEBUG:|r PLAYER_DEAD event received.")
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
SlashCmdList["RUSTCORE"] = function(msg)
    if msg == "test" then
        print("|cffff4444Rustcore:|r Simulating death...")
        wipe(combatSnapshot)
        OnPlayerDead()
    elseif msg == "broadcast" then
        print("|cffff4444Rustcore:|r Simulating incoming death broadcast...")
        RustcoreBroadcast.SimulateDeath()
    else
        RustcoreOptions.Toggle()
    end
end
