-- Rustcore Verification: the conjured-item trade exception.
--
-- Self-Found normally closes the trade window on sight (SelfFoundRestrict.lua).
-- With "selfFoundAllowConjured" switched on the window is allowed to stay open,
-- but only for goods that cost the mode nothing: a conjured item is something
-- the other player made out of nothing and could make again, so receiving one is
-- not an acquisition in the sense section 19 prohibits.
--
-- The exception is deliberately narrow, and narrow here means *proven* rather
-- than assumed. Three rules follow from that:
--
--   both sides    the rule reads the whole window, not just the half arriving.
--                 An exception that only ever carries conjured goods is one
--                 sentence to explain; one that also lets real items out is two,
--                 and the second sentence is the one people argue about.
--   no money      copper is never conjured, so any amount on either side ends it.
--   proof, not    an item whose tooltip has not arrived yet is *unknown*, and
--   optimism      unknown is treated exactly like prohibited. The Accept button
--                 stays down until every slot has actually been read.
--
-- Holding the button down is enforcement, and enforcement is not evidence. The
-- backstop stays where it was: SelfFoundRestrict still samples the bags around
-- the trade and still fails the track for anything that lands in them, minus the
-- allowance this file hands it for the items it actually cleared.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.Conjured = V.Conjured or {}
local C = V.Conjured

local function Setting(key)
    if Rustcore and Rustcore.GetSetting then return Rustcore.GetSetting(key) end
    return nil
end

-- Slot 7 is the enchant/"will not be traded" slot. It never changes hands, so
-- reading it would block trades over an item nobody is giving away.
local function TradeSlotCount()
    return MAX_TRADABLE_ITEMS or 6
end

function C.IsExceptionActive()
    return (Setting("selfFound") and Setting("selfFoundAllowConjured")) and true or false
end

-- Reading "Conjured Item" -----------------------------------------------------
--
-- There is no API that answers this. GetItemInfo exposes quality, type and
-- price but not the conjured flag, so the tooltip is the only place the client
-- states it -- which is also where the player reads it, so the addon and the
-- player are looking at exactly the same line.

local SCAN_NAME = "RustcoreConjuredScanTooltip"
local CONJURED_LABEL = _G.ITEM_CONJURED or "Conjured Item"
local RETRIEVING_LABEL = _G.RETRIEVING_ITEM_INFO or "Retrieving item information"

local scanTooltip

local function EnsureScanTooltip()
    if scanTooltip then return scanTooltip end
    if not CreateFrame then return nil end
    local ok, tip = pcall(CreateFrame, "GameTooltip", SCAN_NAME, nil, "GameTooltipTemplate")
    if not ok then return nil end
    scanTooltip = tip
    return scanTooltip
end

-- true / false / nil, where nil means "the client has not told us yet".
local function ReadLines(getText, count)
    if not count or count == 0 then return nil end
    for i = 1, count do
        local text = getText(i)
        if text and text ~= "" then
            -- Checked before the conjured line, because a tooltip still waiting
            -- on the server carries this placeholder *instead of* its real body:
            -- treating that as "no conjured line found" would read an unresolved
            -- item as a prohibited one and, worse, could go the other way round
            -- on a client that orders its lines differently.
            if text:find(RETRIEVING_LABEL, 1, true) then return nil end
            if text:find(CONJURED_LABEL, 1, true) then return true end
        end
    end
    return false
end

-- Classic path: a hidden tooltip filled from the trade slot itself, so it works
-- from the trade data the client already has rather than re-querying by link.
local function ScanClassic(setterName, index)
    local tip = EnsureScanTooltip()
    if not tip or not tip[setterName] then return nil end

    tip:SetOwner(UIParent, "ANCHOR_NONE")
    tip:ClearLines()
    if not pcall(tip[setterName], tip, index) then return nil end

    return ReadLines(function(i)
        local fs = _G[SCAN_NAME .. "TextLeft" .. i]
        return fs and fs:GetText()
    end, tip:NumLines() or 0)
end

-- Newer clients expose the same lines as data. Only consulted when the classic
-- scan came back with no lines at all, which is what a client that has retired
-- tooltip scanning looks like from here.
local function ScanTooltipInfo(getter)
    if not getter then return nil end
    local ok, data = pcall(getter)
    if not ok or type(data) ~= "table" then return nil end

    local surface = TooltipUtil and TooltipUtil.SurfaceArgs
    if surface then pcall(surface, data) end
    local lines = data.lines
    if type(lines) ~= "table" then return nil end

    return ReadLines(function(i)
        local line = lines[i]
        if not line then return nil end
        if surface then pcall(surface, line) end
        return line.leftText
    end, #lines)
end

-- Conjured-ness belongs to the item, not to the trade, so one answer is kept
-- for the session. Only definite answers are stored: caching "unknown" would
-- make the very first look at an uncached item permanent.
local conjuredCache = {}

local function IsConjured(side, index, itemKey)
    if itemKey and conjuredCache[itemKey] ~= nil then return conjuredCache[itemKey] end

    local result = ScanClassic(side.setter, index)
    if result == nil then
        result = ScanTooltipInfo(side.TooltipData and function() return side.TooltipData(index) end)
    end

    if result ~= nil and itemKey then conjuredCache[itemKey] = result end
    return result
end

-- The two halves of the window ------------------------------------------------

local SIDES = {
    {
        name = "target",
        setter = "SetTradeTargetItem",
        Link = function(i) return GetTradeTargetItemLink and GetTradeTargetItemLink(i) end,
        Info = function(i) return GetTradeTargetItemInfo and GetTradeTargetItemInfo(i) end,
        TooltipData = function(i)
            if C_TooltipInfo and C_TooltipInfo.GetTradeTargetItem then
                return C_TooltipInfo.GetTradeTargetItem(i)
            end
        end,
    },
    {
        name = "player",
        setter = "SetTradePlayerItem",
        Link = function(i) return GetTradePlayerItemLink and GetTradePlayerItemLink(i) end,
        Info = function(i) return GetTradePlayerItemInfo and GetTradePlayerItemInfo(i) end,
        TooltipData = function(i)
            if C_TooltipInfo and C_TooltipInfo.GetTradePlayerItem then
                return C_TooltipInfo.GetTradePlayerItem(i)
            end
        end,
    },
}

-- Item ids are kept as the string an item link yields, because that is how
-- SelfFoundRestrict's and Inventory's bag snapshots key their counts and the
-- allowance is spent against those.
local function LinkItemKey(link)
    return link and link:match("item:(%d+)") or nil
end

-- Verdict ---------------------------------------------------------------------

local trade = {
    active = false,
    verdict = "pending",   -- "ok" | "blocked" | "pending"
    detail = nil,
    allowance = nil,       -- item key -> quantity, from the last "ok" reading
    held = false,          -- true while we are the reason Accept is disabled
}

-- Returns verdict, detail, allowance.
local function Evaluate()
    local playerMoney = (GetPlayerTradeMoney and GetPlayerTradeMoney()) or 0
    local targetMoney = (GetTargetTradeMoney and GetTargetTradeMoney()) or 0
    if playerMoney > 0 or targetMoney > 0 then
        return "blocked", "money is in the window"
    end

    local slots = TradeSlotCount()
    local allowance = {}
    local pending = false

    for _, side in ipairs(SIDES) do
        for index = 1, slots do
            local link = side.Link(index)
            if link then
                local key = LinkItemKey(link)
                local conjured = IsConjured(side, index, key)
                if conjured == nil then
                    -- Keep walking the rest of the window: a definite block
                    -- found further along is a better message than "checking".
                    pending = true
                elseif not conjured then
                    local name = side.Info(index)
                    return "blocked", (name or link) .. " is not conjured"
                elseif side.name == "target" and key then
                    local _, _, quantity = side.Info(index)
                    allowance[key] = (allowance[key] or 0) + (tonumber(quantity) or 1)
                end
            end
        end
    end

    if pending then return "pending" end
    return "ok", nil, allowance
end

-- The Accept button -----------------------------------------------------------
--
-- Only ever held *down*. Blizzard's own TradeFrame code enables and disables
-- this button for its own reasons, and second-guessing those would mean
-- deciding when a trade is otherwise ready -- which is not something this file
-- knows. So the lock subtracts permission and never grants it, and the release
-- below only undoes a disable this file is responsible for.

local function AcceptButton()
    return _G.TradeFrameTradeButton
end

local function HoldAcceptButton()
    local button = AcceptButton()
    if not button or not button.Disable then return end
    -- Already down. Marking it held anyway would mean releasing something this
    -- file never pressed, which is exactly the direction the lock must not go.
    if button.IsEnabled and not button:IsEnabled() then return end
    button:Disable()
    trade.held = true
end

local function ReleaseAcceptButton()
    if not trade.held then return end
    trade.held = false
    local button = AcceptButton()
    if button and button.Enable then button:Enable() end
end

-- Notices ---------------------------------------------------------------------

local lastNotice = 0
local function Notice(message)
    local now = (GetTime and GetTime()) or 0
    if now - lastNotice < 2 then return end
    lastNotice = now
    print("|cffff4444Rustcore:|r " .. message)
end

-- Lifecycle -------------------------------------------------------------------

-- Re-read the window and re-apply the lock. Cheap enough to call from every
-- trade event and from the OnUpdate self-heal.
function C.Refresh()
    if not trade.active then return end

    if not C.IsExceptionActive() then
        -- The setting went away underneath an open window. Stop enforcing here;
        -- the bag sampling in SelfFoundRestrict still judges the outcome.
        trade.verdict = "pending"
        trade.allowance = nil
        ReleaseAcceptButton()
        return
    end

    local previous = trade.verdict
    local verdict, detail, allowance = Evaluate()
    trade.verdict, trade.detail = verdict, detail

    if verdict == "ok" then
        trade.allowance = allowance
        ReleaseAcceptButton()
    else
        trade.allowance = nil
        HoldAcceptButton()
        -- Announced on the way in only, so adjusting a rejected window does not
        -- reprint the same line on every keystroke.
        if verdict == "blocked" and previous ~= "blocked" then
            Notice("Trade blocked: " .. tostring(detail or "only conjured items may be traded") .. ".")
        end
    end
end

-- "ok" only while a live window has been read and cleared in full.
function C.GetVerdict()
    if not trade.active then return "pending" end
    return trade.verdict
end

function C.BeginTrade()
    if trade.active then return end
    trade.active = true
    trade.verdict = "pending"
    trade.detail = nil
    trade.allowance = nil
    -- Held before the first reading, so the button is never briefly clickable
    -- on a window whose contents have not been looked at yet.
    HoldAcceptButton()
    C.Refresh()
end

-- What the last cleared reading permitted, handed over once and then forgotten.
-- Called from SelfFoundRestrict's TRADE_CLOSED rather than from an event here,
-- because two frames handling the same event have no defined order and this one
-- has to run before the sample it belongs to is compared.
function C.EndTrade()
    local allowance = trade.allowance
    trade.active = false
    trade.verdict = "pending"
    trade.detail = nil
    trade.allowance = nil
    ReleaseAcceptButton()

    -- A cleared trade's items are also an expected acquisition, or Inventory's
    -- scorer would flag them: high-rank conjured water carries a required level
    -- above a low-level recipient, which on a stack is already most of a
    -- warning. The expectation carries a short life of its own, since
    -- TRADE_CLOSED also fires on a cancel and nothing would arrive to spend it.
    if allowance and V.Inventory and V.Inventory.ExpectItem then
        for key, quantity in pairs(allowance) do
            V.Inventory.ExpectItem(key, quantity)
        end
    end

    return allowance
end

-- How much of an observed gain the trade had already cleared. Mutates the
-- allowance so the same permission cannot be spent twice.
function C.ConsumeAllowance(allowance, itemKey, count)
    count = count or 0
    if type(allowance) ~= "table" or count <= 0 then return count end

    local key = tostring(itemKey)
    local available = allowance[key] or 0
    if available <= 0 then return count end

    local used = available < count and available or count
    allowance[key] = available - used
    return count - used
end

-- Events ----------------------------------------------------------------------

function C.OnEvent(event)
    if event == "TRADE_SHOW" then
        if C.IsExceptionActive() then C.BeginTrade() end
        return
    end
    if event == "GET_ITEM_INFO_RECEIVED" then
        -- A pending slot may have just become readable.
        if trade.active and trade.verdict == "pending" then C.Refresh() end
        return
    end
    C.Refresh()
end

function C.Init()
    if C.initialized then return end
    C.initialized = true

    -- Parented, because an OnUpdate only runs on a frame that is visible and a
    -- frame with no parent is not.
    local frame = CreateFrame("Frame", nil, UIParent)
    -- Registered here as well as delegated to from SelfFoundRestrict.OnTradeShow.
    -- The lock is the only thing standing between a prohibited window and an
    -- accepted one, so it must not depend on another file's handler running.
    frame:RegisterEvent("TRADE_SHOW")
    frame:RegisterEvent("TRADE_UPDATE")
    frame:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
    frame:RegisterEvent("TRADE_TARGET_ITEM_CHANGED")
    frame:RegisterEvent("TRADE_MONEY_CHANGED")
    frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
    frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    frame:SetScript("OnEvent", function(_, event)
        -- A fault in verification must never break the game session.
        local ok, err = pcall(C.OnEvent, event)
        if not ok then
            print("|cffff4444Rustcore ERROR:|r conjured trade check: " .. tostring(err))
        end
    end)

    -- Blizzard's TradeFrame re-enables the Accept button from its own update
    -- passes, so a one-time Disable does not stay put -- the same reassert idiom
    -- RustcoreDragon and RustcoreSelfFoundBuff already use against Blizzard
    -- reasserting frame state.
    --
    -- Deliberately every frame rather than on a throttle. A throttle leaves the
    -- button live for the gap between Blizzard's enable and the next tick, and a
    -- button that is live for a tenth of a second is a button that can be
    -- clicked -- which is how a window holding a copper coin got accepted. The
    -- check costs an IsEnabled call, and only while a trade window is open.
    --
    -- It also reads the window rather than this file's own state. If the verdict
    -- were the only thing consulted, any path that left `active` false -- a
    -- missed TRADE_SHOW, an error inside a handler -- would fail open, and
    -- failing open here means an unverified trade goes through. So a shown
    -- window with the exception on and no evaluation behind it starts one.
    frame:SetScript("OnUpdate", function()
        local shown = TradeFrame and TradeFrame.IsShown and TradeFrame:IsShown()
        if not shown then
            -- Released here rather than on TRADE_CLOSED: that event belongs to
            -- SelfFoundRestrict, which has to read the allowance out of this
            -- file, and two handlers on one event have no defined order.
            if trade.held then ReleaseAcceptButton() end
            trade.active = false
            return
        end
        if not C.IsExceptionActive() then return end
        if not trade.active then
            C.BeginTrade()
            return
        end
        if trade.verdict ~= "ok" then HoldAcceptButton() end
    end)

    C.frame = frame
end
