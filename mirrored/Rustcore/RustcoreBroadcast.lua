-- RustcoreBroadcast: Announces death penalties to other Rustcore players.
-- Message format: RCDEATH~name~class~level~zone~source~itemLink~ilvl~count~race~gender~timestamp
-- race/gender/timestamp are appended fields - Parse() tolerates senders on an
-- older build that don't send them.
--
-- Two independent transports:
--  1. Addon message on GUILD/PARTY/RAID (C_ChatInfo.SendAddonMessage). WoW
--     Classic (since patch 1.13.3) disallows addon messages with chat type
--     "CHANNEL", so this path only ever reaches guildmates/groupmates - it
--     cannot reach arbitrary strangers.
--  2. Plain chat text on a shared, self-joined, hidden custom channel
--     ("RustcoreDeaths"). Only the *addon-message* CHANNEL type is blocked;
--     SendChatMessage is hardware-event protected, so realm messages are
--     queued and released one at a time by the next mouse/key input. Because
--     the channel is technically joinable by anyone, received messages are
--     marker-prefixed, field-validated, sender-validated, and rate-limited
--     before being trusted (see Display()/OnEvent below).
-- Init() is called by Rustcore.lua on ADDON_LOADED.

RustcoreBroadcast = {}

local PREFIX = "RCDEATH"
local DELIM  = "~"

local CHANNEL_NAME = "RustcoreDeaths"
local CHANNEL_PASS = "rc"
local CHANNEL_MARKER = "RCD1~"
local MAX_CHANNEL_MESSAGE_BYTES = 255
local MAX_PENDING_REALM_MESSAGES = 10
local MAX_PENDING_CHAT_MESSAGES = 10

local REPLAY_WINDOW = 120       -- reject entries whose timestamp is older than this (seconds)
local CLOCK_SKEW_TOLERANCE = 30 -- allow the sender's clock to run this far ahead of ours
local ADDON_SENDER_MIN_INTERVAL = 2   -- seconds between accepted addon messages from one sender
local CHANNEL_SENDER_MIN_INTERVAL = 5 -- seconds between accepted channel messages from one sender

local seenKeys = {}   -- dedup: "name~itemLink" -> expiry timestamp
local lastMsgFrom = { addon = {}, channel = {} } -- transport -> sender -> last accepted message time
local pendingRealmMessages = {}
local pendingChatMessages = {}
local inputFrame
local inputHooksInstalled = false
local realmSendInProgress = false
local initialized = false

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function GetActiveChatTypes()
    local types = {}
    if IsInGuild() then types[#types + 1] = "GUILD" end
    if IsInRaid() then
        types[#types + 1] = "RAID"
    elseif IsInGroup() then
        types[#types + 1] = "PARTY"
    end
    return types
end

-- Shared by any Rustcore module that needs to broadcast an addon message
-- (e.g. RustcoreSelfFoundComm) - sends on every chat type we currently have
-- a real audience for. Returns true if it was sent on at least one.
function RustcoreBroadcast.SendAddonMessage(prefix, msg)
    local types = GetActiveChatTypes()
    for _, chatType in ipairs(types) do
        if C_ChatInfo and C_ChatInfo.SendAddonMessage then
            C_ChatInfo.SendAddonMessage(prefix, msg, chatType)
        elseif SendAddonMessage then
            SendAddonMessage(prefix, msg, chatType)
        end
    end
    return #types > 0
end

local function ClassColorCode(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return "|cffffffff" end
    return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

local function IsValidClass(class)
    return RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] ~= nil
end

-- Never cache the result - the channel's numeric index can shift across
-- reloads/relogs, so resolve it fresh every time we send or receive.
local function GetChannelIndex()
    local channelIndex = GetChannelName(CHANNEL_NAME)
    return channelIndex
end

-- ChatFrame_RemoveChannel only hides the channel from that chat window's
-- display; CHAT_MSG_CHANNEL events for it still fire normally either way.
local function HideChannelFromChatFrames()
    for i = 1, (NUM_CHAT_WINDOWS or 0) do
        local frame = _G["ChatFrame" .. i]
        if frame then
            ChatFrame_RemoveChannel(frame, CHANNEL_NAME)
        end
    end
end

local function NormalizeName(name)
    if type(name) ~= "string" then return "" end
    if Ambiguate then name = Ambiguate(name, "short") end
    return name:match("^[^-]+") or name
end

-- Strips characters that could break the "~"-delimited wire format or, for
-- data received from the untrusted realm channel, inject chat color codes
-- ("|c"), textures ("|T"), or fake hyperlinks ("|H") into displayed text.
-- Applied both when we build outgoing fields and when we parse incoming ones.
local function SanitizeField(value, maxBytes)
    local text = tostring(value or "")
    text = text:gsub("[\r\n~|]", " ")
    if maxBytes and #text > maxBytes then
        text = text:sub(1, maxBytes)
    end
    return text
end

-- Only a real WoW item hyperlink is accepted; anything else (including a
-- crafted string designed to look like one but escape its structure) is
-- dropped rather than displayed or shown in the deathlog.
local function IsValidItemLink(link)
    if type(link) ~= "string" or link == "" then return true end
    return link:match("^|c%x%x%x%x%x%x%x%x|Hitem:%d+:[%d:%-]*|h%[.-%]|h|r$") ~= nil
end

local function EnsureRealmChannel()
    local channelIndex = tonumber(GetChannelIndex())
    if channelIndex and channelIndex > 0 then
        HideChannelFromChatFrames()
        return channelIndex
    end

    if JoinChannelByName then
        JoinChannelByName(CHANNEL_NAME, CHANNEL_PASS)
    end
    return nil
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

local function BuildDeathData(markedItems, deathSource)
    local name  = UnitName("player")
    local _, cl = UnitClass("player")
    local level = UnitLevel("player")
    local zone  = GetZoneText() or "Unknown"
    local src   = (deathSource and deathSource ~= "") and deathSource or "Unknown"
    local race  = UnitRace and UnitRace("player") or nil
    local sexId = UnitSex and UnitSex("player") or nil
    local gender = (sexId == 3) and "Female" or (sexId == 2) and "Male" or "Unknown"

    local bestItem, bestIlvl = FindHighestIlvlItem(markedItems)
    local link = bestItem and bestItem.link or ""

    return {
        name = name,
        class = cl,
        level = level,
        zone = zone,
        source = src,
        link = link,
        ilvl = bestIlvl,
        count = #markedItems,
        race = race,
        gender = gender,
        timestamp = time and time() or 0,
    }
end

local function SerializeDeathData(d)
    local fields = {
        SanitizeField(d.name),
        SanitizeField(d.class),
        SanitizeField(d.level),
        SanitizeField(d.zone),
        SanitizeField(d.source),
        d.link or "",
        SanitizeField(d.ilvl),
        SanitizeField(d.count),
        SanitizeField(d.race),
        SanitizeField(d.gender),
        SanitizeField(d.timestamp),
    }
    local msg = table.concat(fields, DELIM)

    -- Both addon and custom-channel messages are limited to 255 bytes. Keep
    -- the death itself if a long item hyperlink would push the payload over.
    if #msg > (MAX_CHANNEL_MESSAGE_BYTES - #CHANNEL_MARKER) then
        fields[4] = SanitizeField(d.zone, 40)
        fields[5] = SanitizeField(d.source, 60)
        fields[6] = ""
        msg = table.concat(fields, DELIM)
    end
    return msg
end

local function QueueRealmMessage(msg)
    local payload = CHANNEL_MARKER .. msg
    if pendingRealmMessages[#pendingRealmMessages] == payload then return end

    pendingRealmMessages[#pendingRealmMessages + 1] = payload
    if #pendingRealmMessages > MAX_PENDING_REALM_MESSAGES then
        table.remove(pendingRealmMessages, 1)
    end
end

local function FlushOneRealmMessage()
    if realmSendInProgress or #pendingRealmMessages == 0 then return false end
    if not Rustcore.GetSetting("broadcastDeathsRealmWide") then
        wipe(pendingRealmMessages)
        return false
    end

    local channelIndex = EnsureRealmChannel()
    if not channelIndex or not SendChatMessage then return false end

    realmSendInProgress = true
    local ok = pcall(SendChatMessage, pendingRealmMessages[1], "CHANNEL", nil, channelIndex)
    realmSendInProgress = false
    if ok then
        table.remove(pendingRealmMessages, 1)
    end
    return ok
end

-- Normal chat messages are protected by the same hardware-input rule as the
-- realm channel. Other Rustcore modules can use this for visible chat notices
-- that are prepared by events or animation callbacks.
function RustcoreBroadcast.QueueChatMessage(message, chatType, target)
    if type(message) ~= "string" or message == "" or type(chatType) ~= "string" then
        return false
    end

    pendingChatMessages[#pendingChatMessages + 1] = {
        message = message,
        chatType = chatType,
        target = target,
    }
    if #pendingChatMessages > MAX_PENDING_CHAT_MESSAGES then
        table.remove(pendingChatMessages, 1)
    end
    return true
end

local function FlushOneQueuedChatMessage()
    if realmSendInProgress then return false end

    local entry = pendingChatMessages[1]
    if entry then
        if not SendChatMessage then
            table.remove(pendingChatMessages, 1)
            return false
        end

        realmSendInProgress = true
        local ok = pcall(SendChatMessage, entry.message, entry.chatType, nil, entry.target)
        realmSendInProgress = false
        table.remove(pendingChatMessages, 1)
        return ok
    end

    return FlushOneRealmMessage()
end

local function InstallInputHooks()
    if inputHooksInstalled then return end
    inputHooksInstalled = true

    if WorldFrame and WorldFrame.HookScript then
        WorldFrame:HookScript("OnMouseDown", FlushOneQueuedChatMessage)
    end

    inputFrame = CreateFrame("Frame", "RustcoreBroadcastInputFrame", UIParent)
    if inputFrame.EnableKeyboard then inputFrame:EnableKeyboard(true) end
    if inputFrame.SetPropagateKeyboardInput then
        inputFrame:SetPropagateKeyboardInput(true)
    end
    inputFrame:SetScript("OnKeyDown", FlushOneQueuedChatMessage)
end

local function Send(d)
    local msg = SerializeDeathData(d)
    RustcoreBroadcast.SendAddonMessage(PREFIX, msg)

    if Rustcore.GetSetting("broadcastDeathsRealmWide") then
        QueueRealmMessage(msg)
        EnsureRealmChannel()
    end
end

-- The local player's own death is always recorded to the deathlog, regardless
-- of the broadcastDeaths setting (which only controls whether other players
-- are told about it).
function RustcoreBroadcast.Announce(markedItems, deathSource)
    local d = BuildDeathData(markedItems, deathSource)

    if RustcoreDeathlog and RustcoreDeathlog.AddEntry then
        RustcoreDeathlog.AddEntry(d)
    end

    if not Rustcore.GetSetting("broadcastDeaths") then return end
    Send(d)
end

-- ── Receiving ─────────────────────────────────────────────────────────────────

-- Every string field is re-sanitized here (not just at send time) because
-- the realm channel is joinable by anyone - a hand-crafted packet never
-- passes through our own SerializeDeathData/SanitizeField at all.
local function Parse(msgStr)
    local parts = { strsplit(DELIM, msgStr) }
    if #parts < 8 then return nil end

    local link = parts[6]
    if not IsValidItemLink(link) then link = "" end

    return {
        name   = SanitizeField(parts[1], 40),
        class  = SanitizeField(parts[2], 20),
        level  = tonumber(parts[3]),
        zone   = SanitizeField(parts[4], 60),
        source = SanitizeField(parts[5], 80),
        link   = link,
        ilvl   = tonumber(parts[7]) or 0,
        count  = tonumber(parts[8]) or 1,
        race   = parts[9] and SanitizeField(parts[9], 24) or nil,
        gender = parts[10] and SanitizeField(parts[10], 10) or nil,
        timestamp = tonumber(parts[11]),
    }
end

-- Old clients that predate the timestamp field send nothing for it - treat
-- that as always fresh rather than rejecting otherwise-valid entries.
local function IsFresh(d)
    if not d.timestamp or d.timestamp <= 0 then return true end
    local now = time and time() or 0
    if now <= 0 then return true end
    local age = now - d.timestamp
    return age >= -CLOCK_SKEW_TOLERANCE and age <= REPLAY_WINDOW
end

-- Channel messages can come from anyone who's manually joined the channel,
-- not just Rustcore users - reject anything that doesn't parse into a
-- plausible, sufficiently-recent death entry before it ever reaches
-- Display()/the deathlog.
local function IsValidEntry(d)
    return d ~= nil
        and d.level and d.level >= 1 and d.level <= 70
        and IsValidClass(d.class)
        and IsFresh(d)
end

-- Shared by both transports - caps how often a single sender's messages are
-- even considered, so one bad actor can't flood the log with a stream of
-- distinct fake names. Kept separate from the 30s name+link dedup in
-- Display(), which only catches identical repeats.
local function SenderAllowed(transport, sender, minInterval)
    local tracker = lastMsgFrom[transport]
    local now = GetTime()
    local last = tracker[sender]
    if last and (now - last) < minInterval then return false end
    tracker[sender] = now
    return true
end

local function Display(d)
    local key = d.name .. d.link
    local now = GetTime()
    if seenKeys[key] and seenKeys[key] > now then return end
    seenKeys[key] = now + 30

    local nameStr  = ClassColorCode(d.class) .. d.name .. "|r"
    local lvlCl    = "(lvl " .. (d.level or "?") .. ")"
    local srcStr   = (d.source ~= "" and d.source ~= "Unknown") and d.source or "unknown"
    local hasLoss  = d.count and d.count > 0

    local line = "|cffff4444[Rustcore]|r " .. nameStr .. " " .. lvlCl
        .. " died to " .. srcStr .. " in " .. d.zone

    if hasLoss then
        local itemStr  = (d.link and d.link ~= "") and d.link or "an item"
        local countStr = d.count .. (d.count == 1 and " item" or " items")
        line = line .. ", losing " .. countStr .. ", including: " .. itemStr
    end

    local minLevel = tonumber(Rustcore.GetSetting("deathlogMinLevel")) or 0
    local meetsMinLevel = not d.level or d.level >= minLevel
    -- The same predicate the death log filters its rows with, so all three
    -- surfaces agree about which deaths are worth a player's attention rather
    -- than each holding its own opinion.
    local meetsRarity = Rustcore.DeathPassesQualityFilter(d)

    if Rustcore.GetSetting("showDeathPopup") and meetsMinLevel and meetsRarity then
        print(line)
    end

    if Rustcore.GetSetting("showDeathWarning") and meetsMinLevel and meetsRarity and RustcoreDeathNotification and RustcoreDeathNotification.Show then
        RustcoreDeathNotification.Show(d)
    end

    -- Stored unfiltered on purpose. The log applies both filters when it draws
    -- (GetVisibleEntries), so moving a slider re-reveals deaths already
    -- collected instead of only affecting ones that happen from now on.
    if RustcoreDeathlog and RustcoreDeathlog.AddEntry then RustcoreDeathlog.AddEntry(d) end
end

-- ── Events ────────────────────────────────────────────────────────────────────

local f = CreateFrame("Frame")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("CHAT_MSG_CHANNEL")
f:RegisterEvent("CHANNEL_UI_UPDATE")
f:RegisterEvent("PLAYER_ENTERING_WORLD")

f:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, _, sender = ...
        if prefix == PREFIX then
            local d = Parse(msg)
            local shortSender = NormalizeName(sender)
            local playerName = NormalizeName(UnitName("player"))
            if d and IsValidEntry(d) and shortSender ~= playerName
                and NormalizeName(d.name) == shortSender
                and SenderAllowed("addon", shortSender, ADDON_SENDER_MIN_INTERVAL) then
                Display(d)
            end
        end

    elseif event == "CHAT_MSG_CHANNEL" then
        local text, sender, _, _, _, _, _, channelNumber, channelBaseName = ...
        local activeChannel = tonumber(GetChannelIndex())
        local isRealmChannel = channelBaseName == CHANNEL_NAME
            or (activeChannel and tonumber(channelNumber) == activeChannel)
        if isRealmChannel and type(text) == "string"
            and text:sub(1, #CHANNEL_MARKER) == CHANNEL_MARKER then
            local shortSender = NormalizeName(sender)
            local playerName = NormalizeName(UnitName("player"))
            if shortSender ~= playerName then
                local d = Parse(text:sub(#CHANNEL_MARKER + 1))
                if d and IsValidEntry(d) and NormalizeName(d.name) == shortSender
                    and SenderAllowed("channel", shortSender, CHANNEL_SENDER_MIN_INTERVAL) then
                    Display(d)
                end
            end
        end

    elseif event == "CHANNEL_UI_UPDATE" then
        HideChannelFromChatFrames()

    elseif event == "PLAYER_ENTERING_WORLD" then
        EnsureRealmChannel()
        HideChannelFromChatFrames()
    end
end)

function RustcoreBroadcast.Init()
    if initialized then return end
    initialized = true
    InstallInputHooks()

    local initFrame = CreateFrame("Frame")
    initFrame:RegisterEvent("PLAYER_LOGIN")
    initFrame:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(PREFIX)
        end

        EnsureRealmChannel()
        if C_Timer and C_Timer.After then
            C_Timer.After(1, function()
                EnsureRealmChannel()
                HideChannelFromChatFrames()
            end)
        end
    end)
end
