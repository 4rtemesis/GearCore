-- GearCore: Death broadcast system
-- Sends a death notification to the GearCore addon channel on death.
-- Other addon users see a popup and/or a center-screen warning.

GearCoreBroadcast = {}

local ADDON_PREFIX    = "GEARCORE"
local CHANNEL_NAME    = "GearCore"
local POPUP_MAX       = 4
local POPUP_DURATION  = 10   -- seconds before a popup fades
local DEDUP_EXPIRY    = 5    -- seconds to ignore duplicate messages

local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil

local activePopups   = {}   -- list of live popup frames (oldest first)
local recentSenders  = {}   -- [key] = GetTime() for deduplication
local prefixRegistered = false

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function GetChannelNumber()
    local num = GetChannelName(CHANNEL_NAME)
    return (num and num > 0) and num or nil
end

local function GetHighestIlvlItem(items)
    local best, bestLevel = nil, -1
    for _, item in ipairs(items) do
        local _, _, _, ilvl = GetItemInfo(item.link or "")
        ilvl = ilvl or 0
        if ilvl > bestLevel then
            best      = item
            bestLevel = ilvl
        end
    end
    return best
end

local function ExtractItemName(link)
    return link and (link:match("%[(.-)%]") or link) or "Unknown Item"
end

local function ShortName(sender)
    return sender and (sender:match("^([^%-]+)") or sender) or "Unknown"
end

-- ── Center-screen warning ─────────────────────────────────────────────────────

local function ShowCenterWarning(charName, level, itemLink)
    local itemName = ExtractItemName(itemLink)
    local text = "|cffff4444[GearCore] " .. charName .. " (lvl " .. level .. ")|r lost |cffffd700" .. itemName .. "|r"
    if RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, text, { r=1, g=0.3, b=0.3 }, 5)
    elseif UIErrorsFrame then
        UIErrorsFrame:AddMessage(text, 1, 0.3, 0.3, 5)
    end
end

-- ── Popup notification ────────────────────────────────────────────────────────

local POPUP_WIDTH   = 320
local POPUP_HEIGHT  = 70
local POPUP_PADDING = 6

local function RepositionPopups()
    local yBase = -120
    for i, p in ipairs(activePopups) do
        p:ClearAllPoints()
        p:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20,
            yBase - (i - 1) * (POPUP_HEIGHT + POPUP_PADDING))
    end
end

local function RemovePopup(popup)
    for i, p in ipairs(activePopups) do
        if p == popup then
            table.remove(activePopups, i)
            break
        end
    end
    popup:Hide()
    RepositionPopups()
end

local function CreateDeathPopup(charName, level, itemLink)
    -- Evict oldest if at max
    if #activePopups >= POPUP_MAX then
        RemovePopup(activePopups[1])
    end

    local f = CreateFrame("Frame", nil, UIParent, backdropTemplate)
    f:SetSize(POPUP_WIDTH, POPUP_HEIGHT)
    f:SetFrameStrata("HIGH")

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left=8, right=8, top=8, bottom=8 },
    })
    f:SetBackdropColor(0.05, 0.02, 0.02, 0.95)
    f:SetBackdropBorderColor(0.8, 0.1, 0.1, 1)

    -- Skull icon
    local skull = f:CreateTexture(nil, "ARTWORK")
    skull:SetSize(32, 32)
    skull:SetPoint("LEFT", f, "LEFT", 10, 0)
    skull:SetTexture("Interface\\Icons\\Spell_Shadow_SoulLeech_3")

    -- Character + level line
    local nameText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("TOPLEFT", f, "TOPLEFT", 50, -10)
    nameText:SetWidth(POPUP_WIDTH - 58)
    nameText:SetJustifyH("LEFT")
    nameText:SetTextColor(1, 0.3, 0.3)
    nameText:SetText(charName .. "  |cffaaaaaa(Level " .. level .. ")|r  died")

    -- Item link line (clickable via SetHyperlink tooltip)
    local itemLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    itemLabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 50, 10)
    itemLabel:SetWidth(POPUP_WIDTH - 58)
    itemLabel:SetJustifyH("LEFT")
    itemLabel:SetText("Lost: " .. (itemLink or "Unknown Item"))

    -- Invisible hover region for item tooltip
    if itemLink then
        local tipRegion = CreateFrame("Frame", nil, f)
        tipRegion:SetSize(POPUP_WIDTH - 58, 20)
        tipRegion:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 50, 8)
        tipRegion:EnableMouse(true)
        tipRegion:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetHyperlink(itemLink)
            GameTooltip:Show()
        end)
        tipRegion:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        UIFrameFadeOut(f, 0.3, 1, 0)
        C_Timer.After(0.35, function() RemovePopup(f) end)
    end)

    activePopups[#activePopups + 1] = f
    RepositionPopups()
    f:Show()

    -- Auto-dismiss after POPUP_DURATION seconds
    C_Timer.After(POPUP_DURATION, function()
        for _, p in ipairs(activePopups) do
            if p == f then
                UIFrameFadeOut(f, 1.5, 1, 0)
                C_Timer.After(1.6, function() RemovePopup(f) end)
                return
            end
        end
    end)
end

-- ── Incoming message handler ──────────────────────────────────────────────────

function GearCoreBroadcast.OnAddonMessage(prefix, message, distribution, sender)
    if prefix ~= ADDON_PREFIX then return end

    local level, itemLink = message:match("^(%d+);(.+)$")
    if not level then return end

    local charName = ShortName(sender)
    -- Skip messages from the local player (we already know we're dead)
    if charName:lower() == (UnitName("player") or ""):lower() then return end

    -- Deduplicate: ignore the same sender within DEDUP_EXPIRY seconds
    local key = charName .. ":" .. level
    local last = recentSenders[key]
    if last and (GetTime() - last) < DEDUP_EXPIRY then return end
    recentSenders[key] = GetTime()

    if GearCore.GetSetting("showDeathPopup") then
        CreateDeathPopup(charName, level, itemLink)
    end
    if GearCore.GetSetting("showDeathWarning") then
        ShowCenterWarning(charName, level, itemLink)
    end
end

-- ── Outgoing broadcast ────────────────────────────────────────────────────────

function GearCoreBroadcast.BroadcastDeath(items)
    if not GearCore.GetSetting("broadcastDeaths") then return end
    if not items or #items == 0 then return end

    local best = GetHighestIlvlItem(items)
    if not best then return end

    local level   = UnitLevel("player") or 0
    local message = level .. ";" .. best.link

    local sent = false
    local chanNum = GetChannelNumber()
    if chanNum then
        SendAddonMessage(ADDON_PREFIX, message, "CHANNEL", chanNum)
        sent = true
    end
    if not sent then
        if IsInRaid() then
            SendAddonMessage(ADDON_PREFIX, message, "RAID")
            sent = true
        elseif IsInGroup() then
            SendAddonMessage(ADDON_PREFIX, message, "PARTY")
            sent = true
        end
    end
    if not sent then
        -- No channel and not in a group — whisper to self as a last resort so
        -- the local player's own popup/warning still fires via CHAT_MSG_ADDON.
        -- (Actually, loopback on self isn't guaranteed, so just skip.)
    end
end

-- ── Initialization ────────────────────────────────────────────────────────────

function GearCoreBroadcast.Init()
    if not prefixRegistered then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(ADDON_PREFIX)
        end
        prefixRegistered = true
    end

    -- Join the broadcast channel after a short delay so the player is fully in-world
    C_Timer.After(5, function()
        local num = GetChannelNumber()
        if not num then
            JoinChannelByName(CHANNEL_NAME)
        end
    end)
end
