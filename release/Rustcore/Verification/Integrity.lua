-- Rustcore Verification: rolling integrity chain and tamper evidence.
--
-- Each verification-relevant event is folded into a running hash:
--   head[n] = HASH(head[n-1] .. sequence .. type .. payload)
-- so removing or editing an event inside the retained window breaks the chain.
-- A separate seal covers the current authoritative values (statuses, tier caps,
-- playtime counters), so editing those in SavedVariables without replaying the
-- chain is also detectable.
--
-- This is tamper *evidence* against casual SavedVariables editing. It is not a
-- cryptographic guarantee: anyone editing Rustcore's own Lua can recompute it.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.Integrity = V.Integrity or {}
local I = V.Integrity

local format, floor, sort, concat = string.format, math.floor, table.sort, table.concat
local strbyte, gsub, tostring, type = string.byte, string.gsub, tostring, type

-- Two independent multiplicative hashes over different prime moduli, combined
-- into one 14-hex-digit signature (~51 bits).
--
-- WoW's Lua 5.1 stores every number as a double, so all arithmetic here is kept
-- below 2^53 to stay exact: the largest intermediate is
-- (67108859-1) * 131071 + 255 = 8.80e12, well inside the 9.01e15 limit.
-- Deliberately avoids the `bit` library so the result is identical on every
-- client build -- transfer strings in Phase 8 have to hash the same everywhere.
local MOD_A, MUL_A = 33554393, 8191    -- largest prime below 2^25, 2^13-1
local MOD_B, MUL_B = 67108859, 131071  -- largest prime below 2^26, 2^17-1

-- Bumped whenever the sealed field list changes, so an addon update that seals
-- different fields invalidates old seals instead of accusing the player.
I.SEAL_VERSION = 10

-- How many chain events are retained. Older entries roll off; the head still
-- carries their contribution.
I.MAX_EVENTS = 150

function I.Hash(str)
    str = tostring(str or "")
    local a, b = 5381 % MOD_A, 5381 % MOD_B
    for i = 1, #str do
        local c = strbyte(str, i)
        a = (a * MUL_A + c) % MOD_A
        b = (b * MUL_B + c) % MOD_B
    end
    -- Fold in the length so appended padding cannot be silently ignored.
    a = (a * MUL_A + (#str % 251)) % MOD_A
    b = (b * MUL_B + (#str % 251)) % MOD_B
    return format("%07x%07x", floor(a), floor(b))
end

-- Field separators must never appear inside a value, or two different payloads
-- could serialize to the same string.
local function Escape(value)
    return (gsub(tostring(value), "[|;=]", "_"))
end

local function EncodeValue(value)
    local valueType = type(value)
    if valueType == "number" then
        if floor(value) == value then
            return format("%d", value)
        end
        return format("%.6f", value)
    elseif valueType == "boolean" then
        return value and "1" or "0"
    elseif value == nil then
        return ""
    end
    return Escape(value)
end

-- Deterministic "k=v;k=v" rendering with keys sorted, so the same logical
-- payload always hashes identically regardless of table iteration order.
function I.Canonical(payload)
    if type(payload) ~= "table" then return EncodeValue(payload) end
    local keys = {}
    for key in pairs(payload) do
        if type(key) == "string" then
            keys[#keys + 1] = key
        end
    end
    sort(keys)

    local parts = {}
    for index = 1, #keys do
        local key = keys[index]
        parts[index] = Escape(key) .. "=" .. EncodeValue(payload[key])
    end
    return concat(parts, ";")
end

local function GetChain(record)
    record.chain = record.chain or {}
    local chain = record.chain
    chain.events = chain.events or {}
    chain.sequence = chain.sequence or 0
    chain.head = chain.head or ""
    return chain
end

-- The durability snapshot is what an unexplained-repair finding is measured
-- against (plan section 14), so editing it away would hide a repair. It is
-- folded in as a digest rather than field by field: it changes on every scan,
-- and only its integrity matters here, not its contents.
local function DurabilityDigest(record)
    local state = record.durabilityState
    if type(state) ~= "table" or type(state.slots) ~= "table" then return "" end
    local parts = {}
    for slot, entry in pairs(state.slots) do
        if type(entry) == "table" then
            parts[#parts + 1] = format("%s:%s:%s:%s:%s", tostring(slot),
                tostring(entry.id or ""), tostring(entry.guid or ""),
                tostring(entry.cur or ""), tostring(entry.max or ""))
        end
    end
    sort(parts)
    return I.Hash(concat(parts, ";"))
end

-- Typed warning counts for one track, rendered deterministically.
--
-- Warnings are worth protecting in their own right: a single unexplained repair
-- is one away from a failure (section 14), and any warning at all blocks a late
-- start from ever being promoted (section 5). Deleting one from SavedVariables
-- would be the cheapest way to undo both, so the counts are sealed.
local function WarningsDigest(track)
    local warnings = type(track) == "table" and track.warnings or nil
    if type(warnings) ~= "table" then return "" end
    local parts = {}
    for kind, count in pairs(warnings) do
        parts[#parts + 1] = tostring(kind) .. ":" .. tostring(count or 0)
    end
    sort(parts)
    return concat(parts, ";")
end

-- Phase 7 economy counters.
--
-- `last` is the figure the next money change is measured against, so raising it
-- by hand would make the gain it is hiding look like a loss and skip the check
-- entirely. The anomaly tallies are sealed alongside it so a finding cannot be
-- quietly erased after the fact.
local function EconomyDigest(record)
    local economy = record.economy
    if type(economy) ~= "table" then return "" end
    local money = type(economy.money) == "table" and economy.money or {}
    local items = type(economy.items) == "table" and economy.items or {}
    -- lastPlayed is sealed alongside lastGold because the two are read as a
    -- pair: the cross-session check measures the gap as (current /played minus
    -- lastPlayed), so moving it forward by hand shrinks the gap to nothing and
    -- the gold that arrived during it stops being examined.
    return format("%s:%s:%s:%s:%s",
        tostring(money.last or ""), tostring(money.lastPlayed or ""),
        tostring(money.unexplained or 0),
        tostring(money.anomalies or 0), tostring(items.anomalies or 0))
end

-- Death-marked gear that was never destroyed, as one short string.
--
-- The list itself is the thing worth protecting. Every other consequence in this
-- file is a verdict that has already been written down; this one is still a live
-- question, and the answer is a table of item ids sitting in SavedVariables that
-- a player could empty in a text editor to make the objection go away. The
-- tracked timestamp goes in with the id because moving it forward is the quieter
-- version of the same edit -- it buys back the deadline instead of skipping it.
local function DeathLossDigest(record)
    local pending = record and record.deathLoss and record.deathLoss.pending
    if type(pending) ~= "table" then return "" end

    local parts = {}
    for itemID, entry in pairs(pending) do
        if type(entry) == "table" then
            parts[#parts + 1] = string.format("%s:%s:%s:%s:%s",
                tostring(itemID),
                tostring(entry.at or ""),
                tostring(entry.count or ""),
                tostring(entry.seen or ""),
                entry.recorded and "1" or "0")
        end
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

-- The authoritative values the seal protects. Anything a tamperer would want to
-- edit directly -- a status, a tier cap, the playtime counters -- belongs here.
local function CriticalState(record)
    local difficulty = record.difficulty or {}
    local selfFound = record.selfFound or {}
    local timeState = record.time or {}
    local chain = record.chain or {}
    -- Every key is given a value even when the underlying field is nil, using ""
    -- as the placeholder. A nil in a Lua table constructor means the key simply
    -- does not exist, so without this the *set* of sealed keys quietly changed
    -- as fields were filled in during play -- which made the sealed shape
    -- impossible to enumerate, and so impossible to fingerprint below. "" and 0
    -- still encode differently, so nothing is lost by the substitution.
    return {
        schema      = record.schemaVersion or "",
        origin      = record.origin or "",
        guid        = record.identity and record.identity.guid or "",
        -- The sticky half of the status, not the composed one. The composed
        -- value moves when a derived component changes its mind -- which a
        -- level-up alone is enough to do -- and sealing that would have the
        -- record fail its own checksum for the crime of the player dinging.
        -- What a tamperer would want to edit is the evidence, and that is what
        -- is covered here.
        dStatus     = difficulty.evidenceStatus or difficulty.status or "",
        dTier       = difficulty.highestVerifiedTier or "",
        dCap        = difficulty.permanentCapTier or "",
        dLevel      = difficulty.startedAtLevel or "",
        sStatus     = selfFound.evidenceStatus or selfFound.status or "",
        sLevel      = selfFound.startedAtLevel or "",
        -- Phase 4 fields. The claim level decides whether a late Self-Found
        -- start may ever be promoted, the lapse flag decides whether a claim
        -- that was switched off may come back, and the pending cap limits what
        -- a difficulty promotion is allowed to certify -- all three would be
        -- worth editing in SavedVariables if they were not covered.
        sClaim      = selfFound.claimed and 1 or 0,
        sClaimLevel = selfFound.qualifyFromLevel or selfFound.claimedAtLevel or "",
        sLapsed     = selfFound.claimLapsed and 1 or 0,
        sSusp       = selfFound.suspended and 1 or 0,
        sRestore    = selfFound.restoreAtTracked or "",
        -- Phase 5. A Self-Found failure is permanent and its cause is the
        -- reason the buff is gone, so both are sealed against a quiet edit.
        sViol       = selfFound.violations or 0,
        sViolReason = selfFound.lastViolation or "",
        dWarn       = WarningsDigest(difficulty),
        sWarn       = WarningsDigest(selfFound),
        economy     = EconomyDigest(record),
        dPending    = difficulty.pendingCapTier or "",
        dFloor      = difficulty.deathFloorTier or "",
        anchor      = timeState.anchorPlayed or "",
        lastPlayed  = timeState.lastServerPlayed or "",
        tracked     = timeState.trackedSinceAnchor or "",
        untracked   = timeState.untrackedSeconds or "",
        sequence    = chain.sequence or "",
        durability  = DurabilityDigest(record),
        deathLoss   = DeathLossDigest(record),
    }
end

-- A fingerprint of *which* fields are sealed, as opposed to what they contain.
--
-- The reason this exists: changing the sealed field list without also bumping
-- SEAL_VERSION makes every existing record fail its own check on the next
-- login, and Rustcore then tells the player their saved record looks tampered
-- with. That is a developer mistake being reported as an accusation against
-- someone who did nothing, and relying on remembering a manual bump had already
-- failed more than once.
--
-- Folding the field names into the seal removes the failure mode entirely: any
-- change to the sealed shape invalidates old seals automatically, and an
-- invalidated seal is skipped rather than treated as evidence.
local sealFingerprint

local function SealFingerprint()
    if not sealFingerprint then
        local keys = {}
        for key in pairs(CriticalState({})) do keys[#keys + 1] = key end
        sort(keys)
        sealFingerprint = I.Hash(concat(keys, ","))
    end
    return sealFingerprint
end

I.SealFingerprint = SealFingerprint

local function ComputeSeal(record)
    local chain = record.chain or {}
    return I.Hash((chain.head or "") .. "|" .. I.SEAL_VERSION .. "|" .. SealFingerprint()
        .. "|" .. I.Canonical(CriticalState(record)))
end

-- Re-stamp the seal over the current state. Called after every mutation, so
-- whatever SavedVariables ends up persisting is always internally consistent
-- (including after a crash or Alt-F4, which simply keeps the previous
-- already-sealed snapshot).
function I.Seal(record)
    record = record or V.GetRecord()
    if not record then return end
    record.chain = record.chain or {}
    record.chain.sealVersion = I.SEAL_VERSION
    record.chain.sealFields = SealFingerprint()
    record.chain.seal = ComputeSeal(record)
end

-- Fold one event into the chain and retain it in the rolling window.
function I.Append(eventType, payload)
    local record = V.GetRecord()
    if not record then return nil end

    local chain = GetChain(record)
    chain.sequence = chain.sequence + 1

    local played = 0
    if V.Time and V.Time.GetLastServerPlayed then
        played = V.Time.GetLastServerPlayed() or 0
    end

    local body = I.Canonical(payload)
    local head = I.Hash(chain.head .. "|" .. chain.sequence .. "|" .. Escape(eventType) .. "|" .. played .. "|" .. body)
    chain.head = head

    local events = chain.events
    events[#events + 1] = {
        s = chain.sequence,
        t = eventType,
        p = played,
        d = body,
        h = head,
    }
    -- Roll the oldest entries off. The head keeps their contribution, so the
    -- window can shrink without the chain losing continuity.
    while #events > I.MAX_EVENTS do
        table.remove(events, 1)
    end

    I.Seal(record)
    return head
end

-- Recompute the retained window and the seal.
-- Returns true when everything reconciles, plus a reason string when it does not.
function I.Check(record)
    record = record or V.GetRecord()
    if not record then return true end

    local chain = record.chain
    if not chain or not chain.seal then
        -- Nothing sealed yet (a record created by an older build). Not evidence
        -- of anything; the next Seal() call adopts it.
        return true
    end
    if chain.sealVersion ~= I.SEAL_VERSION or chain.sealFields ~= SealFingerprint() then
        -- Sealed by a build that protected a different field list -- either
        -- because the version was bumped deliberately, or because the shape
        -- changed and the fingerprint noticed on its own. Either way there is
        -- nothing to compare against, so it is not treated as tampering.
        return true
    end

    local events = chain.events or {}
    for index = 2, #events do
        local previous, current = events[index - 1], events[index]
        if current.s ~= previous.s + 1 then
            return false, "sequence gap"
        end
        local expected = I.Hash(previous.h .. "|" .. current.s .. "|" .. Escape(current.t) .. "|" .. (current.p or 0) .. "|" .. (current.d or ""))
        if expected ~= current.h then
            return false, "event hash mismatch"
        end
    end

    if #events > 0 and events[#events].h ~= chain.head then
        return false, "chain head mismatch"
    end
    if ComputeSeal(record) ~= chain.seal then
        return false, "state seal mismatch"
    end
    return true
end

-- Start the chain for a freshly created record.
function I.Genesis(record, originLabel)
    local chain = GetChain(record)
    chain.head = I.Hash("RUSTCORE|" .. I.SEAL_VERSION .. "|" .. I.Canonical({
        guid = record.identity and record.identity.guid or "",
        name = record.identity and record.identity.name or "",
        realm = record.identity and record.identity.realm or "",
        origin = originLabel or "",
        created = record.createdAt or 0,
    }))
    chain.sequence = 0
    chain.events = {}
    I.Seal(record)
    return chain.head
end

function I.Init()
    if I.initialized then return end
    I.initialized = true

    local record = V.GetRecord()
    if not record then return end

    local ok, reason = I.Check(record)
    if not ok then
        -- Bias toward reasonable doubt: a broken chain means Rustcore can no
        -- longer vouch for the history, not that the player definitely cheated.
        -- Both tracks drop to UNVERIFIED rather than FAILED.
        record.tamperReason = reason
        V.SetStatus("difficulty", V.STATUS.UNVERIFIED, "integrity: " .. reason)
        V.SetStatus("selfFound", V.STATUS.UNVERIFIED, "integrity: " .. reason)
        I.Seal(record)
    end
end
