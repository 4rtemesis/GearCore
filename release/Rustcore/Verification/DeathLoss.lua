-- Rustcore Verification: death-loss item deletion.
--
-- When a Rustcore character dies at Broken or above, the addon picks equipped
-- gear and marks it for deletion, and the frame RustcoreUI.lua puts on screen is
-- how the player carries that out. Nothing until now checked whether they did.
-- A player could close the window and keep wearing the item, and the
-- certification would never notice -- the central rule of the whole addon was
-- the one rule with no verification behind it.
--
-- Items that simply wear down to zero durability are not this file's business.
-- Those are already unusable, so keeping one costs the player nothing and gains
-- them nothing; the items that matter are the ones a death took, which are
-- perfectly good gear right up until they are destroyed.
--
-- What this does not do is punish the moment an item is marked. A death is a
-- terrible time to be quick with a mouse: the frame appears mid-corpse-run,
-- deletion needs a confirmation popup per item, and a client can crash between
-- the death and the last confirmation. So there are two clocks on every marked
-- item:
--
--   before GRACE     nothing is said at all. This is the small delay -- room to
--                    run back to a corpse, resurrect, and work through the list.
--   GRACE..DEADLINE  the run is not certified while the item is held, and the
--                    instant it is destroyed the objection disappears. This is a
--                    derived component like the tracking gap: it is recomputed
--                    from what the player is holding right now and nothing about
--                    it is written down, so deleting the item is genuinely all
--                    it takes to recover.
--   past DEADLINE    evidence. An hour of watched play still wearing gear a
--                    death was supposed to take is not a client crash, and at
--                    that point the verdict is written to the record and
--                    deleting the item afterwards does not lift it.
--
-- Both clocks run in tracked play seconds, not wall clock. A player who logs off
-- for a week has not spent that week ignoring the prompt, and burning the
-- deadline while nobody is playing would turn "delete this item" into "delete
-- this item or do not take a holiday".

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.DeathLoss = V.DeathLoss or {}
local D = V.DeathLoss

-- Tracked play seconds. Five minutes of room to react, an hour before it counts.
D.GRACE = 300
D.DEADLINE = 3600

local REASON = "death-marked item not destroyed: "

-- Every equipment slot, not just the ones that can take durability damage: the
-- death penalty marks whatever it marks, and the item has to be looked for
-- wherever the player might have moved it since.
local EQUIP_SLOTS = {
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
}

-- How often the sweep runs on its own. Events cover every ordinary way an item
-- leaves the player's hands; this is here for the ways they do not fire, and for
-- moving the two clocks along while somebody stands still.
local SWEEP_INTERVAL = 60

-- ── Small helpers ────────────────────────────────────────────────────────────

local function Append(eventType, payload)
    if V.Integrity and V.Integrity.Append then
        V.Integrity.Append(eventType, payload)
    end
end

local function BagSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        return C_Container.GetContainerNumSlots(bag)
    end
    return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

local function BagLink(bag, slot)
    if C_Container and C_Container.GetContainerItemLink then
        return C_Container.GetContainerItemLink(bag, slot)
    end
    return GetContainerItemLink and GetContainerItemLink(bag, slot) or nil
end

-- Stored as a string, the way the rest of the addon reads it, so every file
-- agrees about what a key looks like.
local function ItemID(link)
    if type(link) ~= "string" then return nil end
    return link:match("item:(%d+)")
end

local function ItemName(link)
    if type(link) ~= "string" then return "item" end
    return link:match("%[(.-)%]") or "item"
end

-- The clock. Tracked seconds since the record's anchor, which only advances
-- while Rustcore is running and the player is playing.
local function TrackedNow()
    local record = V.GetRecord()
    local state = record and record.time
    return (state and tonumber(state.trackedSinceAnchor)) or 0
end

-- ── Counting copies ──────────────────────────────────────────────────────────
--
-- Item id and not item GUID, because the item is being looked for across bags
-- and equipment where a GUID is not always available. That makes two copies of
-- the same item indistinguishable, so the question asked is not "is this item
-- still here" but "does the player hold fewer of them than they did", which is
-- the same question when there is one copy and the right question when there
-- are two.
local function CountCopies(itemID)
    local count = 0

    for _, slot in ipairs(EQUIP_SLOTS) do
        local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
        if link and ItemID(link) == itemID then
            count = count + 1
        end
    end

    for bag = 0, 4 do
        for slot = 1, (BagSlots(bag) or 0) do
            local link = BagLink(bag, slot)
            if link and ItemID(link) == itemID then
                count = count + 1
            end
        end
    end

    return count
end

-- ── State ────────────────────────────────────────────────────────────────────

function D.GetState()
    local record = V.GetRecord()
    if not record then return nil end
    record.deathLoss = record.deathLoss or {}
    record.deathLoss.pending = record.deathLoss.pending or {}
    return record.deathLoss
end

-- Called from Rustcore.lua the moment the death penalty decides which items it
-- is taking, before the deletion frame is built. Deliberately upstream of that
-- frame: closing the window is a decision about the window, not about the item.
function D.Note(link, slot)
    local itemID = ItemID(link)
    if not itemID then return false end

    local state = D.GetState()
    if not state then return false end

    -- Already under objection. Left exactly as it was: the older clock is the
    -- stricter of the two, and re-noting would restart it. A second death
    -- marking the same item id is only possible because the first copy was
    -- never destroyed, which is the thing the existing entry already says.
    if state.pending[itemID] then return false end

    local held = CountCopies(itemID)

    state.pending[itemID] = {
        link = link,
        slot = slot,
        at = TrackedNow(),
        level = (V.GetPlayerLevel and V.GetPlayerLevel()) or 0,
        -- How many the player holds with the marked one still in place, and the
        -- fewest seen since. Deletion is proven when the second drops below the
        -- first, and because it only ever falls, looting a replacement later
        -- cannot un-prove it.
        count = held > 0 and held or 1,
        seen = held > 0 and held or 1,
    }

    Append("DEATHLOSS_NOTED", { item = itemID, name = ItemName(link) })
    if V.ComposeAll then V.ComposeAll() end
    return true
end

-- ── The verdict ──────────────────────────────────────────────────────────────

-- Registered with Core as a derived component, so it is asked fresh and never
-- stored. Difficulty only: destroying what a death took is a difficulty rule,
-- and Self-Found is about where items came from rather than where they went.
function D.ComponentStatus(trackName)
    if trackName and trackName ~= "difficulty" then return nil end

    local record = V.GetRecord()
    local state = record and record.deathLoss
    if not state or not state.pending then return nil end

    local now = TrackedNow()
    local worstAge, worstLink, lost

    for _, entry in pairs(state.pending) do
        local age = now - (tonumber(entry.at) or now)
        if age >= D.GRACE and (not worstAge or age > worstAge) then
            worstAge, worstLink = age, entry.link
        end
        if entry.recorded then lost = true end
    end

    if not worstAge then return nil end

    -- SUSPENDED while the item can still be destroyed, UNVERIFIED once one of
    -- them has run past the deadline. The distinction is the whole point of the
    -- second clock: up to that moment nothing has been decided and the player
    -- can undo it in a click, and a verdict that reads as final would be
    -- telling them the opposite of the truth.
    if lost then
        return V.STATUS.UNVERIFIED, REASON .. ItemName(worstLink)
    end
    return V.STATUS.SUSPENDED, REASON .. ItemName(worstLink)
end

-- Past the deadline the derived objection stops being enough, because a derived
-- objection is by design erasable and this one should not be. Written once per
-- item -- the flag is what stops an hour-old item re-reporting itself every
-- sweep for the rest of the run.
local function Enforce(state)
    local now = TrackedNow()
    local recorded = false

    for itemID, entry in pairs(state.pending) do
        local age = now - (tonumber(entry.at) or now)
        if age >= D.DEADLINE and not entry.recorded then
            entry.recorded = true
            recorded = true

            local detail = ItemName(entry.link)
            V.AddWarning("difficulty", "deathLossItem", detail)
            Append("DEATHLOSS_VIOLATION", { item = itemID, name = detail })
            -- UNVERIFIED and not FAILED. Rustcore watched an item stay in the
            -- player's possession, which is a good deal weaker than watching
            -- them break a rule: the frame can be missed, an item can be in a
            -- bank Rustcore cannot see, and two copies of the same item read as
            -- one. FAILED is for what was actually observed happening.
            V.SetStatus("difficulty", V.STATUS.UNVERIFIED, REASON .. detail)
        end
    end

    return recorded
end

-- ── Sweep ────────────────────────────────────────────────────────────────────

function D.Sweep()
    local state = D.GetState()
    if not state then return end

    local changed = false
    for itemID, entry in pairs(state.pending) do
        local held = CountCopies(itemID)
        if held < (tonumber(entry.seen) or 0) then
            entry.seen = held
            changed = true
        end

        if (tonumber(entry.seen) or 0) < (tonumber(entry.count) or 1) then
            state.pending[itemID] = nil
            changed = true
            Append("DEATHLOSS_DESTROYED", { item = itemID, name = ItemName(entry.link) })
        end
    end

    if Enforce(state) then changed = true end

    -- Recomposed whenever anything is still outstanding, not only when this
    -- sweep moved something. An item crossing the grace mark changes the
    -- verdict while the record stays exactly as it was -- a clock passing a
    -- number raises no event -- and composing is cheap and idempotent. Sealing
    -- is the expensive half and there is genuinely nothing new to seal, so that
    -- one stays behind the flag.
    if changed or next(state.pending) ~= nil then
        if V.ComposeAll then V.ComposeAll() end
    end

    if changed then
        if V.Integrity and V.Integrity.Seal then V.Integrity.Seal(V.GetRecord()) end
    end
end

-- How long, in tracked seconds, until the oldest held item stops being
-- recoverable. The panel uses it to say what is at stake; nil means nothing is.
function D.GetTimeRemaining()
    local record = V.GetRecord()
    local state = record and record.deathLoss
    if not state or not state.pending then return nil end

    local now = TrackedNow()
    local soonest
    for _, entry in pairs(state.pending) do
        if not entry.recorded then
            local left = D.DEADLINE - (now - (tonumber(entry.at) or now))
            if left < 0 then left = 0 end
            if not soonest or left < soonest then soonest = left end
        end
    end
    return soonest
end

-- The items still waiting to be destroyed, as { link, name, age, recorded } rows.
function D.GetPending()
    local record = V.GetRecord()
    local state = record and record.deathLoss
    if not state or not state.pending then return {} end

    local now = TrackedNow()
    local rows = {}
    for _, entry in pairs(state.pending) do
        rows[#rows + 1] = {
            link = entry.link,
            name = ItemName(entry.link),
            age = now - (tonumber(entry.at) or now),
            recorded = entry.recorded and true or false,
        }
    end
    return rows
end

-- ── Init ─────────────────────────────────────────────────────────────────────

function D.Init()
    if D.initialized then return end
    D.initialized = true

    if V.RegisterComponent then
        V.RegisterComponent("deathLoss", function(trackName)
            return D.ComponentStatus(trackName)
        end)
    end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("BAG_UPDATE_DELAYED")
    frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    frame:SetScript("OnEvent", function()
        -- A fault in verification must never break the game session.
        local ok, err = pcall(D.Sweep)
        if not ok then
            print("|cffff4444Rustcore ERROR:|r death-loss verification: " .. tostring(err))
        end
    end)
    D.frame = frame

    if C_Timer and C_Timer.NewTicker then
        D.ticker = C_Timer.NewTicker(SWEEP_INTERVAL, function()
            pcall(D.Sweep)
        end)
    end
end
