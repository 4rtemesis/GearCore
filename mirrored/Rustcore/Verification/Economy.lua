-- Rustcore Verification: shared economy context and thresholds
-- (plan sections 23, 24, 25 and 27).
--
-- Money.lua and Inventory.lua both have to answer the same question before they
-- can call anything suspicious: was the player doing something that legitimately
-- moves money or items just now? That question, and the level-scaled numbers
-- both modules judge magnitude against, live here so the two cannot drift apart.
--
-- Section 25 is explicit that perfect provenance is not required. This is not an
-- accounting ledger; it is a filter that keeps ordinary play from ever reaching
-- the anomaly path. Being generous about what counts as explained is deliberate:
-- section 51 would rather miss a leak than punish a player who was questing.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.Economy = V.Economy or {}
local E = V.Economy

local function Now()
    return (GetTime and GetTime()) or (time and time()) or 0
end

-- Failure gate ---------------------------------------------------------------

-- Phase 7 of the plan says, in as many words: "Start conservatively. Log
-- anomalies internally during testing before enabling failures."
--
-- So the scoring, the thresholds and the escalation are all live, but the top
-- band records a warning instead of failing the track. Everything needed to turn
-- failures on is in place; flipping this to true is the whole change, and it
-- should not happen until the numbers below have been calibrated against real
-- play. Direct violations are unaffected -- trade, auction and mail still fail
-- immediately in Phases 5 and 6, because those are observations rather than
-- inferences.
E.ALLOW_ECONOMY_FAILURE = false

-- Activity context (plan section 25) -------------------------------------------

-- How long after a window closes its explanation still applies. The server
-- applies loot, vendor and mail transfers a moment after the UI event, and
-- BAG_UPDATE_DELAYED can lag further behind again.
E.GRACE = 5

local active, recent = {}, {}

function E.Begin(name)
    active[name] = true
    recent[name] = nil
end

function E.End(name)
    if active[name] then active[name] = nil end
    recent[name] = Now()
end

-- A momentary activity with no closing event of its own (a spell that finished,
-- a quest that was handed in).
function E.Touch(name)
    recent[name] = Now()
end

-- True when anything could legitimately explain a change right now.
function E.IsExplained()
    for _ in pairs(active) do return true end
    local now = Now()
    for name, at in pairs(recent) do
        if now - at <= E.GRACE then return true end
        recent[name] = nil
    end
    return false
end

-- What is explaining it, for the diagnostic readout.
function E.Describe()
    local parts = {}
    for name in pairs(active) do parts[#parts + 1] = name end
    local now = Now()
    for name, at in pairs(recent) do
        if now - at <= E.GRACE then parts[#parts + 1] = name .. "~" end
    end
    if #parts == 0 then return "none" end
    table.sort(parts)
    return table.concat(parts, ",")
end

function E.Reset()
    active, recent = {}, {}
end

-- Exactly-known credits --------------------------------------------------------

-- Some events state the amount outright -- QUEST_TURNED_IN carries its money
-- reward in copper -- so that much of an observed gain is accounted for exactly
-- rather than merely excused by a context window.
local expectedMoney = 0

function E.ExpectMoney(amount)
    amount = tonumber(amount) or 0
    if amount > 0 then expectedMoney = expectedMoney + amount end
end

-- Spend the known credit against an observed gain and return what is left over.
function E.ConsumeExpectedMoney(gain)
    if expectedMoney <= 0 then return gain end
    local used = expectedMoney
    if used > gain then used = gain end
    expectedMoney = expectedMoney - used
    return gain - used
end

function E.GetExpectedMoney()
    return expectedMoney
end

-- Level-scaled thresholds (plan section 24) ------------------------------------

-- Copper. The level 10 and level 40 rows are the plan's stated figures; level 1
-- is its "very low", and the top two rows are its "higher thresholds appropriate
-- to Classic economy", extended to 70 for the Burning Crusade client. Section 24
-- asks for a scaling function rather than these points alone, so everything
-- between them is interpolated and everything outside is clamped.
--
-- These are a starting calibration. The plan says to tune them through testing,
-- and E.ALLOW_ECONOMY_FAILURE above stays false until that has happened.
E.GOLD_ANCHORS = {
    { level =  1, warn =    200, fail =   1000 },  --  2s /  10s
    { level = 10, warn =   1000, fail =   5000 },  -- 10s /  50s
    { level = 40, warn =  20000, fail = 100000 },  --  2g /  10g
    { level = 60, warn = 100000, fail = 500000 },  -- 10g /  50g
    { level = 70, warn = 250000, fail = 1000000 }, -- 25g / 100g
}

local function Interpolate(level, field)
    local anchors = E.GOLD_ANCHORS
    level = tonumber(level) or 1

    if level <= anchors[1].level then return anchors[1][field] end
    local last = anchors[#anchors]
    if level >= last.level then return last[field] end

    for i = 1, #anchors - 1 do
        local a, b = anchors[i], anchors[i + 1]
        if level >= a.level and level <= b.level then
            local span = b.level - a.level
            if span <= 0 then return a[field] end
            local t = (level - a.level) / span
            return a[field] + (b[field] - a[field]) * t
        end
    end
    return last[field]
end

function E.GetGoldWarningThreshold(level)
    return Interpolate(level or V.GetPlayerLevel() or 1, "warn")
end

function E.GetGoldFailureThreshold(level)
    return Interpolate(level or V.GetPlayerLevel() or 1, "fail")
end

-- Money formatting for the readouts.
function E.FormatMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local bronze = copper % 100
    if gold > 0 then return string.format("%dg %02ds %02dc", gold, silver, bronze) end
    if silver > 0 then return string.format("%ds %02dc", silver, bronze) end
    return string.format("%dc", bronze)
end

-- Shared record storage --------------------------------------------------------

function E.GetState()
    local record = V.GetRecord()
    if not record then return nil end
    record.economy = record.economy or {}
    return record.economy
end

-- Escalation (plan sections 27, 44 and 47) -------------------------------------

-- One place where an economy finding becomes a verification outcome, so the
-- money and item paths escalate identically.
--
-- `band` is "warn" or "fail". A fail band is still only recorded as a warning
-- while E.ALLOW_ECONOMY_FAILURE is false, which is the conservative start the
-- plan asks for; the warning type differs so the two are told apart later.
-- For findings that are inference rather than observation: the top band costs
-- the certification, but as UNVERIFIED. Nothing routed through here can ever
-- reach FAILED, whatever the numbers say, because no rule was watched being
-- broken -- there was simply more gold than the elapsed play explains.
function E.EscalateUnverifiable(band, warningType, detail)
    local track = V.GetTrack("selfFound")
    if not track or not track.claimed then return false end
    if track.status == V.STATUS.FAILED then return false end

    V.AddWarning("selfFound", warningType, detail or "")
    if V.Integrity and V.Integrity.Append then
        V.Integrity.Append("ECON", {
            kind   = warningType,
            band   = band or "warn",
            detail = detail or "",
            level  = V.GetPlayerLevel() or 0,
        })
    end

    if band == "fail" then
        V.SetStatus("selfFound", V.STATUS.UNVERIFIED, warningType .. ": " .. tostring(detail or ""))
    end

    if RustcoreSelfFoundBuff and RustcoreSelfFoundBuff.Refresh then
        RustcoreSelfFoundBuff.Refresh()
    end
    return true
end

function E.Escalate(band, warningType, detail)
    local track = V.GetTrack("selfFound")
    if not track or not track.claimed then return false end
    if track.status == V.STATUS.FAILED then return false end

    if band == "fail" and E.ALLOW_ECONOMY_FAILURE then
        if V.SelfFound and V.SelfFound.Fail then
            V.SelfFound.Fail("unexplained " .. tostring(warningType), detail)
            return true
        end
    end

    V.AddWarning("selfFound", warningType, detail or "")
    if V.Integrity and V.Integrity.Append then
        V.Integrity.Append("ECON", {
            kind   = warningType,
            band   = band or "warn",
            detail = detail or "",
            level  = V.GetPlayerLevel() or 0,
        })
    end
    if RustcoreSelfFoundBuff and RustcoreSelfFoundBuff.Refresh then
        RustcoreSelfFoundBuff.Refresh()
    end
    return true
end

-- Whether the economy layer should be judging at all. Mirrors the other
-- Self-Found modules: enforcement and judgement both require the claim.
-- Judged on the claim rather than on the option, matching SelfFoundRestrict:
-- observation continues while Self-Found is switched off so that a suspension
-- is watched instead of blind. SelfFound.OnSettingChanged explains why, and
-- SF.Fail decides what anything found during one costs.
function E.ShouldJudge()
    local track = V.GetTrack("selfFound")
    if not track or not track.claimed then return false end
    if track.status == V.STATUS.FAILED then return false end
    return true
end

-- Context wiring ---------------------------------------------------------------

-- Every window or action that legitimately moves money or items. Registered
-- through pcall because an unknown event name raises a Lua error, and which of
-- these a given client generation defines is not worth assuming.
local WINDOW_EVENTS = {
    MERCHANT_SHOW      = { "merchant", "begin" },
    MERCHANT_CLOSED    = { "merchant", "end"   },
    LOOT_OPENED        = { "loot",     "begin" },
    LOOT_CLOSED        = { "loot",     "end"   },
    BANKFRAME_OPENED   = { "bank",     "begin" },
    BANKFRAME_CLOSED   = { "bank",     "end"   },
    MAIL_SHOW          = { "mail",     "begin" },
    MAIL_CLOSED        = { "mail",     "end"   },
    TRADE_SKILL_SHOW   = { "craft",    "begin" },
    TRADE_SKILL_CLOSE  = { "craft",    "end"   },
    CRAFT_SHOW         = { "craft",    "begin" },
    CRAFT_CLOSE        = { "craft",    "end"   },
    QUEST_COMPLETE     = { "quest",    "touch" },
    QUEST_ACCEPTED     = { "quest",    "touch" },
    QUEST_LOOT_RECEIVED = { "quest",   "touch" },
    LOOT_READY         = { "loot",     "touch" },
}

function E.OnEvent(event, ...)
    if event == "QUEST_TURNED_IN" then
        -- Carries the money reward in copper, so this much of any gain that
        -- follows is accounted for exactly rather than merely excused.
        local _, _, moneyReward = ...
        E.ExpectMoney(moneyReward)
        E.Touch("quest")
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Conjuring, crafting, disenchanting, opening a container: all of them
        -- create items and all of them are a spell that just finished.
        E.Touch("spell")
        return
    end

    local rule = WINDOW_EVENTS[event]
    if not rule then return end
    local name, action = rule[1], rule[2]
    if action == "begin" then
        E.Begin(name)
    elseif action == "end" then
        E.End(name)
    else
        E.Touch(name)
    end
end

-- Diagnostic readout -----------------------------------------------------------

-- /rceco shows what the economy layer currently believes: what would explain a
-- change right now, the thresholds in force, and what has been flagged so far.
-- Read-only, and the way to calibrate the numbers above against real play
-- before E.ALLOW_ECONOMY_FAILURE is ever turned on.
SLASH_RCECO1 = "/rceco"
SlashCmdList["RCECO"] = function()
    local level = V.GetPlayerLevel() or 1
    print("|cffff4444Rustcore economy|r")
    print(string.format("  Judging: %s   failures: %s",
        E.ShouldJudge() and "yes" or "no",
        E.ALLOW_ECONOMY_FAILURE and "enabled" or "|cffffd700warn-only|r"))
    print(string.format("  Context now: %s   expected credit: %s",
        E.Describe(), E.FormatMoney(E.GetExpectedMoney())))
    print(string.format("  Gold at level %d: warn %s   fail %s", level,
        E.FormatMoney(E.GetGoldWarningThreshold(level)),
        E.FormatMoney(E.GetGoldFailureThreshold(level))))
    print(string.format("  Item score bands: warn %d   fail %d",
        V.Inventory and V.Inventory.SCORE_WARN or 0,
        V.Inventory and V.Inventory.SCORE_FAIL or 0))

    local state = E.GetState()
    if not state then
        print("  No verification record for this character yet.")
        return
    end
    local money = state.money or {}
    local items = state.items or {}
    print(string.format("  Money: held %s   unexplained %s over %d event(s)",
        E.FormatMoney(money.last or 0),
        E.FormatMoney(money.unexplained or 0), money.anomalies or 0))
    if items.lastDetail then
        print(string.format("  Last item flag: score %s -- %s",
            tostring(items.lastScore), tostring(items.lastDetail)))
    end
    print(string.format("  Item flags: %d", items.anomalies or 0))
end

function E.Init()
    if E.initialized then return end
    E.initialized = true

    local frame = CreateFrame("Frame")
    local function Register(name)
        pcall(frame.RegisterEvent, frame, name)
    end

    for event in pairs(WINDOW_EVENTS) do Register(event) end
    Register("QUEST_TURNED_IN")
    -- Player-only, so the constant stream of other units' casts never reaches us.
    pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_SUCCEEDED", "player")

    frame:SetScript("OnEvent", function(_, event, ...)
        -- A fault in verification must never break the game session.
        local ok, err = pcall(E.OnEvent, event, ...)
        if not ok then
            print("|cffff4444Rustcore ERROR:|r economy context: " .. tostring(err))
        end
    end)
    E.frame = frame
end
