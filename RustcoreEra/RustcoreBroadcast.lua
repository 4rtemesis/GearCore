-- RustcoreBroadcast: Announces death penalties to other Rustcore players via a shared channel.
-- Message format: RCDEATH~name~class~level~zone~source~itemLink~ilvl~count
-- Init() is called by Rustcore.lua on ADDON_LOADED; it defers the channel join to PLAYER_LOGIN.

RustcoreBroadcast = {}

local CHANNEL_NAME = "rustcorechannel"
local CHANNEL_PASS = "rcbc1"
local PREFIX       = "RCDEATH"
local DELIM        = "~"

local channelNum = nil
local seenKeys   = {}   -- dedup: "name~itemLink" -> expiry timestamp

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function RefreshChannelNum()
    local id = GetChannelName(CHANNEL_NAME)
    channelNum = (id and id > 0) and id or nil
end

local function JoinChannel()
    JoinChannelByName(CHANNEL_NAME, CHANNEL_PASS)
    C_Timer.After(3, RefreshChannelNum)
end

local function ClassColorCode(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return "|cffffffff" end
    return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

local function FindHighestIlvlItem(items)
    local best, bestIlvl = nil, 0
    for _, item in ipairs(items) do
        if item.link then
            local ilvl = select(4, GetItemInfo(item.link)) or 0
            if ilvl > bestIlvl then
                bestIlvl = ilvl
                best = item
            end
        end
    end
    return best, bestIlvl
end

-- ── Sending ───────────────────────────────────────────────────────────────────

local function Send(markedItems, deathSource)
    if not channelNum then return end

    local name  = UnitName("player")
    local _, cl = UnitClass("player")
    local level = UnitLevel("player")
    local zone  = GetZoneText() or "Unknown"
    local src   = (deathSource and deathSource ~= "") and deathSource or "Unknown"

    local bestItem, bestIlvl = FindHighestIlvlItem(markedItems)
    local link = bestItem and bestItem.link or ""

    local count = #markedItems
    local msg = table.concat({ name, cl, level, zone, src, link, bestIlvl, count }, DELIM)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, msg, "CHANNEL", channelNum)
    elseif SendAddonMessage then
        SendAddonMessage(PREFIX, msg, "CHANNEL", channelNum)
    end
end

function RustcoreBroadcast.Announce(markedItems, deathSource)
    if not Rustcore.GetSetting("broadcastDeaths") then return end
    RefreshChannelNum()
    if channelNum then
        Send(markedItems, deathSource)
        return
    end
    JoinChannel()
    C_Timer.After(4, function()
        RefreshChannelNum()
        if channelNum then Send(markedItems, deathSource) end
    end)
end

-- ── Receiving ─────────────────────────────────────────────────────────────────

local function Parse(msgStr)
    local parts = { strsplit(DELIM, msgStr) }
    if #parts < 8 then return nil end
    return {
        name   = parts[1],
        class  = parts[2],
        level  = tonumber(parts[3]),
        zone   = parts[4],
        source = parts[5],
        link   = parts[6],
        ilvl   = tonumber(parts[7]) or 0,
        count  = tonumber(parts[8]) or 1,
    }
end

local function Display(d)
    local key = d.name .. d.link
    local now = GetTime()
    if seenKeys[key] and seenKeys[key] > now then return end
    seenKeys[key] = now + 30

    local nameStr  = ClassColorCode(d.class) .. d.name .. "|r"
    local lvlCl    = "(lvl " .. (d.level or "?") .. " " .. (d.class or "") .. ")"
    local srcStr   = (d.source ~= "" and d.source ~= "Unknown") and d.source or "unknown"
    local itemStr  = (d.link and d.link ~= "") and d.link or "an item"
    local countStr = d.count .. (d.count == 1 and " item" or " items")

    local line = "|cffff4444[Rustcore]|r " .. nameStr .. " " .. lvlCl
        .. " died to " .. srcStr .. " in " .. d.zone
        .. ", losing " .. countStr .. ", including: " .. itemStr

    if Rustcore.GetSetting("showDeathPopup") then
        print(line)
    end

    if Rustcore.GetSetting("showDeathWarning") then
        local plain = d.name .. " just lost " .. countStr .. ", including: " .. itemStr .. "."
        RaidNotice_AddMessage(RaidWarningFrame, plain, ChatTypeInfo["RAID_WARNING"])
    end
end

-- ── Events ────────────────────────────────────────────────────────────────────

local f = CreateFrame("Frame")
f:RegisterEvent("CHANNEL_UI_UPDATE")
f:RegisterEvent("CHAT_MSG_ADDON")

f:SetScript("OnEvent", function(_, event, ...)
    if event == "CHANNEL_UI_UPDATE" then
        RefreshChannelNum()

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, channelType, sender = ...
        if prefix == PREFIX and channelType == "CHANNEL" then
            local d = Parse(msg)
            if d and sender ~= UnitName("player") and d.name ~= UnitName("player") then
                Display(d)
            end
        end
    end
end)

function RustcoreBroadcast.Init()
    local initFrame = CreateFrame("Frame")
    initFrame:RegisterEvent("PLAYER_LOGIN")
    initFrame:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(PREFIX)
        end
        JoinChannel()
    end)
end
