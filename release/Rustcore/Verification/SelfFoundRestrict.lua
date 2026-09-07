-- Rustcore Verification: Self-Found direct restrictions (plan sections 19 and 28).
--
-- Phase 5. Two jobs that must not be confused:
--
--   enforcement   stop the prohibited interaction from happening at all
--   detection     notice when one happened anyway, and fail the track
--
-- Enforcement follows the *setting*, because that is what the player switched
-- on and expects to be held to. Detection follows the *claim*, because that is
-- what a certification is worth. A character with Self-Found off is neither
-- enforced nor judged here.
--
-- Section 19 makes both of these direct violations rather than suspicions, so
-- section 47 maps them to FAILED and section 43 makes that permanent. What
-- counts as direct differs between the two, and each is watched where the
-- evidence is unambiguous:
--
--   trade    the items landing in the player's bags. Rustcore sampled them
--            before the window opened and after it closed, so a gain is
--            something it observed rather than inferred.
--   auction  the transaction call itself. A Classic auction is delivered by
--            mail, so bags say nothing here; mail is Phase 6's job. What is
--            unambiguous is that an auction function ran at all.
--
-- Everything in this file is deliberately narrow: it fires on an observed gain
-- or an executed transaction, never on an attempt, an open window, or a trade
-- the player only lost items in.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.SelfFoundRestrict = V.SelfFoundRestrict or {}
local R = V.SelfFoundRestrict

local function Setting(key)
    if Rustcore and Rustcore.GetSetting then return Rustcore.GetSetting(key) end
    return nil
end

-- Enforcement is on whenever the player has Self-Found switched on. It does not
-- ask whether the track is still certified: a player whose certification was
-- already lost still chose to play Self-Found, and silently unblocking their
-- trade window would be a strange way to tell them.
function R.IsEnforcing()
    return Setting("selfFound") and true or false
end

-- The conjured exception (Conjured.lua) narrows enforcement rather than lifting
-- it: the window is allowed to open, but only a window Rustcore has read and
-- found to contain nothing but conjured goods can be accepted. Everything below
-- this line -- the sampling, the settle check, the auction house -- is unchanged
-- by it, because the exception governs what may be attempted and those govern
-- what actually happened.
local function ExceptionActive()
    return (V.Conjured and V.Conjured.IsExceptionActive and V.Conjured.IsExceptionActive()) and true or false
end

-- Detection only matters while there is a live claim to lose. A track that is
-- already FAILED cannot fail again, and one that was never claimed has nothing
-- to judge.
-- Judged on the claim, not on the option.
--
-- Enforcement stops the moment Self-Found is switched off, but observation does
-- not: Rustcore is still loaded and can still see what arrives. That is what
-- lets a suspension be recoverable instead of fatal -- SelfFound.OnSettingChanged
-- explains the reasoning, and SF.Fail decides what a violation found during one
-- actually costs.
local function ShouldJudge()
    local track = V.GetTrack("selfFound")
    if not track or not track.claimed then return false end
    if track.status == V.STATUS.FAILED then return false end
    return true
end

-- Throttle the chat notice. Blizzard re-fires TRADE_SHOW when the player
-- retries, and one line per attempt is enough.
local lastNotice = 0
local function Notice(message)
    local now = GetTime and GetTime() or 0
    if now - lastNotice < 2 then return end
    lastNotice = now
    print("|cffff4444Rustcore:|r " .. message)
end

-- Inventory sampling ---------------------------------------------------------

-- Item id -> total count across the carried bags. Mirrors CaptureBagSnapshot in
-- Rustcore.lua and BagItemCounts in SelfFound.lua: C_Container is the current
-- API and the bare globals are the pre-10.0 spelling still present on the
-- Classic clients, so both are tried rather than assumed.
local function BagCounts()
    local counts = {}
    local maxBag = NUM_BAG_SLOTS or 4
    for bag = 0, maxBag do
        local slots = 0
        if C_Container and C_Container.GetContainerNumSlots then
            slots = C_Container.GetContainerNumSlots(bag) or 0
        elseif GetContainerNumSlots then
            slots = GetContainerNumSlots(bag) or 0
        end
        for slot = 1, slots do
            local link, count
            if C_Container and C_Container.GetContainerItemInfo then
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info then link, count = info.hyperlink, info.stackCount or 1 end
            elseif GetContainerItemInfo then
                local _, stack, _, _, _, _, hyperlink = GetContainerItemInfo(bag, slot)
                link, count = hyperlink, stack or 1
            end
            local id = link and link:match("item:(%d+)")
            if id then counts[id] = (counts[id] or 0) + (count or 1) end
        end
    end
    return counts
end

local function Money()
    return (GetMoney and GetMoney()) or 0
end

-- Every item id whose count rose between two samples, with how many appeared.
-- Only gains are reported: section 26 is explicit that unexplained losses are
-- not a Self-Found concern, and a trade the player gave things away in must
-- never be mistaken for one they received in.
--
-- All of them rather than the first, because a permitted conjured gain may sit
-- in front of a prohibited one in an unordered table, and stopping at the first
-- gain would let the order of `pairs` decide whether the trade was caught.
local function Gains(before, after)
    local found = nil
    for id, count in pairs(after) do
        local had = before[id] or 0
        if count > had then
            found = found or {}
            found[id] = count - had
        end
    end
    return found
end

-- Violation ------------------------------------------------------------------

local function Fail(reason, detail)
    if V.SelfFound and V.SelfFound.Fail then
        V.SelfFound.Fail(reason, detail)
    end
end

-- Trade ----------------------------------------------------------------------
--
-- The window is closed on sight, so a completed trade should be unreachable.
-- The sampling below is the backstop for the cases where it is not: the client
-- refusing the close, another addon reopening it, a build where the timing
-- differs, or the conjured exception deliberately letting one through. That
-- last case is why the backstop matters more now than it did when it was only
-- ever insurance: it is the one path where a trade is *expected* to complete,
-- and the only thing that can tell an expected completion from an abused one is
-- a measurement taken afterwards.
--
-- It measures what actually landed in the bags rather than what the trade
-- window advertised, because that is the thing section 19 prohibits and the
-- only thing Rustcore can state it observed.

local trade = {}

local function TradeSample()
    trade.bags = BagCounts()

    -- Money the player has already moved into the trade window is still theirs
    -- until the exchange happens, but it is not necessarily still in GetMoney().
    -- A sample taken before the window opened and one taken with an offer
    -- sitting in it have to mean the same thing, or cancelling the trade gives
    -- the copper back and the addon reads the refund as a gain -- and fails the
    -- track over a trade that never happened.
    --
    -- Adding it back cannot create leniency in the other direction: what is
    -- offered and what is received are separate fields, so a real receipt is
    -- still a gain against this figure.
    trade.money = Money() + ((GetPlayerTradeMoney and GetPlayerTradeMoney()) or 0)
end

-- Compare against the sample taken while the trade was open. Runs a moment
-- after the window closes: the server applies the exchange after TRADE_CLOSED,
-- and BAG_UPDATE_DELAYED is not guaranteed to have arrived yet.
--
-- The sample is passed in rather than read from `trade` here, because a second
-- trade opening inside that delay would otherwise replace the very snapshot
-- this comparison depends on.
--
-- `allowance` is what the conjured exception cleared on the way through, and it
-- is subtracted from the observed gain rather than trusted in place of it. The
-- gate can only see what the window advertised; this sees what arrived. So a
-- conjured trade that somehow delivered something else still fails here, and
-- the exception cannot become a hole by being wrong about its own contents.
local function TradeSettle(before, beforeMoney, allowance)
    if not before then return end
    if not ShouldJudge() then return end

    local gains = Gains(before, BagCounts())
    if gains then
        for id, gained in pairs(gains) do
            local uncovered = gained
            if allowance and V.Conjured and V.Conjured.ConsumeAllowance then
                uncovered = V.Conjured.ConsumeAllowance(allowance, id, gained)
            end
            if uncovered > 0 then
                Fail("received an item in a player trade",
                    string.format("item %s x%d", tostring(id), uncovered))
                return
            end
        end
    end

    -- Money is never covered by an allowance: the exception blocks any amount on
    -- either side outright, so copper that arrived was never permitted.
    local now = Money()
    if now > (beforeMoney or 0) then
        Fail("received money in a player trade",
            string.format("%d copper", now - (beforeMoney or 0)))
    end
end

function R.OnTradeShow()
    -- Sampled whenever there is a claim to protect, even with the option off, so
    -- a suspension is watched rather than blind. Blocking below still only
    -- happens while the option is on.
    if ShouldJudge() then TradeSample() end
    if not R.IsEnforcing() then return end

    -- The exception hands the window to Conjured.lua instead of closing it. The
    -- sample above was still taken, so whatever the gate decides, the settle
    -- check below still judges what actually landed in the bags.
    if ExceptionActive() then
        if V.Conjured and V.Conjured.BeginTrade then V.Conjured.BeginTrade() end
        return
    end

    -- Deferred by one frame: the trade window is still being set up inside this
    -- event, and cancelling from underneath it is what the existing block in
    -- Rustcore.lua already does successfully.
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if CancelTrade then CancelTrade() end
            if CloseTrade then CloseTrade() end
        end)
    else
        if CancelTrade then CancelTrade() end
        if CloseTrade then CloseTrade() end
    end
    Notice("Trading blocked (Self-Found mode).")
end

-- Both sides accepting is the last moment before an exchange, so the sample is
-- refreshed here even if TRADE_SHOW was somehow missed.
function R.OnTradeAcceptUpdate(playerAccepted, targetAccepted)
    if (playerAccepted or 0) == 0 and (targetAccepted or 0) == 0 then return end
    if not trade.bags and ShouldJudge() then TradeSample() end
    if not R.IsEnforcing() then return end

    -- A cleared conjured window is allowed to reach this point -- that is the
    -- whole exception. Anything short of a cleared verdict, including one still
    -- being read, is cancelled exactly as before.
    --
    -- Re-read rather than trusting the last verdict: both files handle
    -- TRADE_ACCEPT_UPDATE and the order between two frames on one event is not
    -- defined, so the verdict standing when this runs may predate the change
    -- that is being accepted.
    if ExceptionActive() and V.Conjured then
        if V.Conjured.Refresh then V.Conjured.Refresh() end
        if V.Conjured.GetVerdict and V.Conjured.GetVerdict() == "ok" then return end
    end

    if CancelTrade then CancelTrade() end
end

function R.OnTradeClosed()
    -- Detach the sample now, so a repeat TRADE_CLOSED or a fresh trade opening
    -- during the delay cannot disturb this comparison.
    local before, beforeMoney = trade.bags, trade.money
    trade.bags, trade.money = nil, nil

    -- Taken here rather than from an event of its own: two frames handling
    -- TRADE_CLOSED have no defined order, and this allowance has to be detached
    -- before the comparison it belongs to runs.
    local allowance
    if V.Conjured and V.Conjured.EndTrade then allowance = V.Conjured.EndTrade() end

    if not before then return end

    if C_Timer and C_Timer.After then
        C_Timer.After(1, function() TradeSettle(before, beforeMoney, allowance) end)
    else
        TradeSettle(before, beforeMoney, allowance)
    end
end

-- Auction house --------------------------------------------------------------
--
-- CloseAuctionHouse() is the documented way to shut the window and exists on
-- both Classic Era and the Burning Crusade Anniversary client. The frame is
-- hidden as well because the API call ends the interaction with the auctioneer
-- and can leave the panel on screen; whichever frame this client actually uses
-- is the one that gets hidden.
local function CloseAuctionUI()
    if CloseAuctionHouse then CloseAuctionHouse() end
    local frame = _G.AuctionFrame or _G.AuctionHouseFrame
    if frame and frame.IsShown and frame:IsShown() and HideUIPanel then
        HideUIPanel(frame)
    end
end

function R.OnAuctionShow()
    if not R.IsEnforcing() then return end

    if C_Timer and C_Timer.After then
        C_Timer.After(0, CloseAuctionUI)
    else
        CloseAuctionUI()
    end
    Notice("Auction House blocked (Self-Found mode).")
end

-- Detecting an auction transaction.
--
-- Deliberately *not* done by comparing bags across the auction window. In
-- Classic a purchase is delivered by mail rather than into the bags, so that
-- comparison would seldom see the thing it was watching for -- and what it did
-- see could just as easily be loot, a quest reward or a trade that happened
-- while the window was open. Section 51 calls that circumstantial, and mail is
-- where those goods actually surface, which is Phase 6's job.
--
-- The transaction functions themselves are the direct observation: nothing but
-- the player (or something acting for them) calls these, and each one requires
-- a hardware event, so a call means an auction action was really executed
-- despite the window being closed. Section 19 makes that a failure.
local function HookAuctionTransactions()
    local function violation(label)
        return function()
            if not ShouldJudge() then return end
            Fail("used the auction house", label)
            -- Whatever reopened the window should not stay open.
            CloseAuctionUI()
        end
    end

    -- Feature-detected: hooksecurefunc errors on a name that does not exist,
    -- and which of these a client has depends on its auction house generation.
    if _G.PlaceAuctionBid then
        hooksecurefunc("PlaceAuctionBid", violation("bid or buyout placed"))
    end
    if _G.StartAuction then
        hooksecurefunc("StartAuction", violation("auction posted"))
    end
    if _G.PostAuction then
        hooksecurefunc("PostAuction", violation("auction posted"))
    end
end

-- Events ---------------------------------------------------------------------

function R.OnEvent(event, ...)
    if event == "TRADE_SHOW" then
        R.OnTradeShow()
    elseif event == "TRADE_ACCEPT_UPDATE" then
        R.OnTradeAcceptUpdate(...)
    elseif event == "TRADE_CLOSED" then
        R.OnTradeClosed()
    elseif event == "AUCTION_HOUSE_SHOW" then
        R.OnAuctionShow()
    end
end

function R.Init()
    if R.initialized then return end
    R.initialized = true

    HookAuctionTransactions()

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("TRADE_SHOW")
    frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
    frame:RegisterEvent("TRADE_CLOSED")
    frame:RegisterEvent("AUCTION_HOUSE_SHOW")
    frame:SetScript("OnEvent", function(_, event, ...)
        -- A fault in verification must never break the game session.
        local ok, err = pcall(R.OnEvent, event, ...)
        if not ok then
            print("|cffff4444Rustcore ERROR:|r self-found restrictions: " .. tostring(err))
        end
    end)
    R.frame = frame
end
