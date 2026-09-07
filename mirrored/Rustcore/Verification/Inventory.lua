-- Rustcore Verification: Self-Found item monitoring
-- (plan sections 26 and 27).
--
-- Section 26 narrows this sharply: unexplained *losses* are not a Self-Found
-- concern, only unexplained acquisitions. So the diff below reports gains and
-- discards everything else.
--
-- Bags and equipped slots are counted together on purpose. Counted separately,
-- unequipping a sword would read as a bag gain of one sword, and every gear
-- change would be an anomaly.
--
-- Section 27 asks for the judgement to be one scoring function rather than
-- conditions scattered about, and for it to use intrinsic game information
-- rather than market prices -- which Rustcore cannot see and which would be
-- unreliable even if it could. Everything the score consults comes from
-- GetItemInfo.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.Inventory = V.Inventory or {}
local Inv = V.Inventory

local function E()
    return V.Economy
end

local EQUIPMENT_SLOTS = 19

-- Counting ---------------------------------------------------------------------

-- Mirrors the readers in SelfFound.lua and SelfFoundRestrict.lua: C_Container is
-- the current API, the bare globals are the older spelling still present on the
-- Classic clients, and both are tried rather than assumed.
local function BagCounts(counts)
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
end

local function EquippedCounts(counts)
    for slot = 1, EQUIPMENT_SLOTS do
        local id = GetInventoryItemID and GetInventoryItemID("player", slot)
        if id then
            local key = tostring(id)
            counts[key] = (counts[key] or 0) + 1
        end
    end
end

-- Item id -> count across bags and the paper doll together.
function Inv.Snapshot()
    local counts = {}
    BagCounts(counts)
    EquippedCounts(counts)
    return counts
end

-- Suspicion scoring (plan section 27) ------------------------------------------

-- Quality indices are Blizzard's: 0 poor, 1 common, 2 uncommon, 3 rare,
-- 4 epic, 5 legendary.
local QUALITY_SCORE = { [0] = 0, [1] = 0, [2] = 10, [3] = 25, [4] = 45, [5] = 60 }

-- Bands. A starting calibration, as section 27 expects: low is ignored, medium
-- warns, high is the failure band -- which Economy.ALLOW_ECONOMY_FAILURE still
-- holds back to a warning for now.
Inv.SCORE_WARN = 35
Inv.SCORE_FAIL = 70

-- Score one acquisition. Returns the score and a short reason, or nil when the
-- item is not cached yet and nothing can be said about it.
--
-- Every term answers a different question about whether this item plausibly
-- belongs to this character at this point in the game.
function Inv.Score(itemID, quantity)
    -- Snapshots key by the digits an item link yields, so the id arrives here as
    -- a string. GetItemInfo treats a bare string as an item *name*, which would
    -- silently never match, so it is converted back to a number first.
    local query = tonumber(itemID) or itemID
    local name, _, quality, itemLevel, minLevel, _, _, _, _, _, sellPrice =
        GetItemInfo(query)
    if not name then return nil end

    quantity = quantity or 1
    local level = V.GetPlayerLevel() or 1
    local score, reasons = 0, {}

    local function add(points, why)
        if points <= 0 then return end
        score = score + points
        reasons[#reasons + 1] = why
    end

    -- Rarity. The single strongest signal that something was handed over: a
    -- level 10 character does not find epics.
    add(QUALITY_SCORE[quality or 1] or 0, "quality " .. tostring(quality or 0))

    -- Item level well above the character's own level.
    if type(itemLevel) == "number" and itemLevel > 0 then
        local gap = itemLevel - level
        if gap > 10 then add(25, "ilvl +" .. gap)
        elseif gap > 5 then add(15, "ilvl +" .. gap)
        elseif gap > 0 then add(5, "ilvl +" .. gap) end
    end

    -- Progression mismatch: an item the character cannot even use yet is a
    -- classic sign of a handout rather than a drop.
    if type(minLevel) == "number" and minLevel > level then
        add(30, "requires level " .. minLevel)
    end

    -- Quantity. Bulk arriving at once is not how looting works.
    if quantity >= 20 then add(10, "x" .. quantity)
    elseif quantity >= 5 then add(5, "x" .. quantity) end

    -- Intrinsic value. The vendor price is part of the item's own definition,
    -- so it is available offline and cannot be manipulated -- unlike an auction
    -- price, which section 27 rules out.
    local value = (tonumber(sellPrice) or 0) * quantity
    if value > 0 then
        local economy = E()
        if value >= economy.GetGoldFailureThreshold(level) then
            add(40, "value " .. economy.FormatMoney(value))
        elseif value >= economy.GetGoldWarningThreshold(level) then
            add(20, "value " .. economy.FormatMoney(value))
        end
    end

    return score, name .. " (" .. table.concat(reasons, ", ") .. ")"
end

-- State -------------------------------------------------------------------------

local snapshot
local pending = {}   -- itemID -> quantity, awaiting GetItemInfo

-- Set once the world is loaded. Bag contents are not reliably readable before
-- then, and diffing a real inventory against an empty early snapshot would read
-- as the player acquiring everything they are carrying.
local ready = false

local function GetState()
    local economy = E() and E().GetState()
    if not economy then return nil end
    economy.items = economy.items or {}
    if economy.items.anomalies == nil then economy.items.anomalies = 0 end
    return economy.items
end

Inv.GetState = GetState

-- Record and escalate one scored acquisition. The single place a score turns
-- into a verification outcome, so the immediate path and the delayed
-- cache-arrival path cannot diverge.
local function Emit(score, detail)
    if not score or score < Inv.SCORE_WARN then return end

    local state = GetState()
    if state then
        state.anomalies = (state.anomalies or 0) + 1
        state.lastScore = score
        state.lastDetail = detail
        state.lastAt = time and time() or 0
    end

    E().Escalate(score >= Inv.SCORE_FAIL and "fail" or "warn",
        "itemDiscrepancy", string.format("score %d: %s", score, detail or "?"))

    if V.Integrity and V.Integrity.Seal then V.Integrity.Seal() end
end

-- Expected acquisitions ------------------------------------------------------
--
-- Mirrors E.ExpectMoney / E.ConsumeExpectedMoney in Economy.lua: something else
-- in Rustcore already knows where these items came from, so the scorer should
-- not be asked to guess. The conjured trade exception is the caller -- a stack
-- of high-rank conjured water carries a required level above a low-level
-- recipient, which is most of a warning on its own, and warning a player about
-- the trade the addon just cleared for them would be nonsense.
--
-- Two properties keep this from becoming a blanket excuse. It is *quantitative*:
-- an expectation of 20 covers 20 and the twenty-first is scored normally. And it
-- expires, because the expectation is registered when a trade window closes and
-- a cancelled trade delivers nothing -- without the deadline, an unspent
-- expectation would sit there waiting to absorb an unrelated acquisition hours
-- later.
local EXPECT_TTL = 30

local expected = {}

local function Now()
    return (GetTime and GetTime()) or 0
end

function Inv.ExpectItem(itemID, quantity)
    quantity = tonumber(quantity) or 0
    if quantity <= 0 then return end

    local key = tostring(itemID)
    local entry = expected[key]
    if not entry or Now() >= entry.expires then
        entry = { count = 0 }
        expected[key] = entry
    end
    entry.count = entry.count + quantity
    entry.expires = Now() + EXPECT_TTL
end

-- How much of `quantity` is still unaccounted for.
function Inv.ConsumeExpected(itemID, quantity)
    local key = tostring(itemID)
    local entry = expected[key]
    if not entry then return quantity end
    if Now() >= entry.expires then
        expected[key] = nil
        return quantity
    end

    local used = entry.count < quantity and entry.count or quantity
    entry.count = entry.count - used
    if entry.count <= 0 then expected[key] = nil end
    return quantity - used
end

local function Report(itemID, quantity)
    quantity = Inv.ConsumeExpected(itemID, quantity)
    if quantity <= 0 then return end

    local score, detail = Inv.Score(itemID, quantity)
    if not score then
        -- Not cached. GetItemInfo has queried the server; the answer arrives on
        -- GET_ITEM_INFO_RECEIVED and the item is scored then.
        pending[itemID] = (pending[itemID] or 0) + quantity
        return
    end
    Emit(score, detail)
end

-- Diffing -------------------------------------------------------------------------

function Inv.Evaluate()
    local current = Inv.Snapshot()
    local previous = snapshot
    snapshot = current

    if not previous or not ready then return end
    if not E().ShouldJudge() then return end

    -- The player was plainly in the middle of something that produces items.
    -- Section 25: the context is enough, no ledger required.
    if E().IsExplained() then return end

    for id, count in pairs(current) do
        local had = previous[id] or 0
        if count > had then
            Report(id, count - had)
        end
    end
end

-- Adopt the current contents without judging them.
function Inv.Rebase()
    snapshot = Inv.Snapshot()
end

-- Events ---------------------------------------------------------------------------

function Inv.OnEvent(event, ...)
    if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" then
        Inv.Evaluate()

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        local itemID, success = ...
        local key = itemID and tostring(itemID)
        -- Snapshots key by the string form the item link yields, so both are
        -- checked rather than assuming which one the pending entry used.
        local quantity = key and (pending[key] or pending[itemID])
        if quantity then
            pending[key] = nil
            pending[itemID] = nil
            if success ~= false then
                Emit(Inv.Score(itemID, quantity))
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Bag contents are not reliably readable the instant this fires, and a
        -- login is not a moment Rustcore can reason about: it did not watch
        -- whatever happened between sessions. Judging only begins once this
        -- settled snapshot has been taken.
        if C_Timer and C_Timer.After then
            C_Timer.After(2, function()
                pcall(Inv.Rebase)
                ready = true
            end)
        else
            Inv.Rebase()
            ready = true
        end
    end
end

function Inv.Init()
    if Inv.initialized then return end
    Inv.initialized = true

    Inv.Rebase()

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("BAG_UPDATE_DELAYED")
    frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:SetScript("OnEvent", function(_, event, ...)
        -- A fault in verification must never break the game session.
        local ok, err = pcall(Inv.OnEvent, event, ...)
        if not ok then
            print("|cffff4444Rustcore ERROR:|r inventory verification: " .. tostring(err))
        end
    end)
    Inv.frame = frame
end
