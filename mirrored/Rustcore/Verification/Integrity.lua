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

-- A coarse "this build seals differently" marker. No longer the mechanism that
-- protects players from update-time false positives -- SealFingerprint below
-- does that, and it cannot be forgotten the way a manual bump can. Kept because
-- it costs nothing and makes a deliberate break explicit.
I.SEAL_VERSION = 11

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

-- Sealed to whole seconds.
--
-- The playtime counters are floats accumulated from GetTime() deltas, and a
-- seal is only as stable as the least stable thing in it: whatever precision
-- SavedVariables keeps on the way to disk has to come back bit-identical, or
-- the record fails its own check having done nothing wrong. Sub-second
-- resolution is worth nothing to a tamper seal, so it is rounded away and the
-- question stops being asked.
local function Seconds(value)
    local number = tonumber(value)
    if not number then return "" end
    return floor(number + 0.5)
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
    -- Rounded for the same reason the playtime counters are: these come back
    -- through SavedVariables, and the seal has to render them identically on
    -- the other side. Copper and seconds are both whole-number quantities
    -- anyway, so nothing real is lost.
    return format("%s:%s:%s:%s:%s",
        tostring(Seconds(money.last)), tostring(Seconds(money.lastPlayed)),
        tostring(Seconds(money.unexplained)),
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
        sRestore    = Seconds(selfFound.restoreAtTracked),
        -- Phase 5. A Self-Found failure is permanent and its cause is the
        -- reason the buff is gone, so both are sealed against a quiet edit.
        sViol       = selfFound.violations or 0,
        sViolReason = selfFound.lastViolation or "",
        dWarn       = WarningsDigest(difficulty),
        sWarn       = WarningsDigest(selfFound),
        economy     = EconomyDigest(record),
        dPending    = difficulty.pendingCapTier or "",
        dFloor      = difficulty.deathFloorTier or "",
        anchor      = Seconds(timeState.anchorPlayed),
        lastPlayed  = Seconds(timeState.lastServerPlayed),
        tracked     = Seconds(timeState.trackedSinceAnchor),
        untracked   = Seconds(timeState.untrackedSeconds),
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
-- Folding the sealed shape into the seal removes the failure mode entirely: any
-- change to it invalidates old seals automatically, and an invalidated seal is
-- skipped rather than treated as evidence.
--
-- The fingerprint is taken over the *rendering* of a fixed synthetic record, not
-- over the list of key names. Key names were the first attempt and they were not
-- enough: the digests above each collapse a whole sub-table into one key, so
-- adding a field to DurabilityDigest or EconomyDigest changed what the seal
-- covered while leaving the key list identical. An update that did that produced
-- exactly the accusation this mechanism exists to prevent -- the player's record
-- had not changed, only Rustcore's idea of how to render it.
--
-- Running a fixed record through the real CriticalState catches all of it: a new
-- key, a dropped key, a changed separator, a field added to a digest, a format
-- string edited. If the output moves for any reason, so does the fingerprint.
local FINGERPRINT_RECORD = {
    schemaVersion = 1,
    origin = "fp",
    identity = { guid = "fp-guid" },
    difficulty = {
        evidenceStatus = 1, highestVerifiedTier = 2, permanentCapTier = 3,
        startedAtLevel = 4, pendingCapTier = 5, deathFloorTier = 6,
        warnings = { alpha = 1, beta = 2 },
    },
    selfFound = {
        evidenceStatus = 2, startedAtLevel = 7, claimed = true,
        qualifyFromLevel = 8, claimedAtLevel = 9, claimLapsed = true,
        suspended = true, restoreAtTracked = 10, violations = 11,
        lastViolation = "fp-violation", warnings = { gamma = 3 },
    },
    time = {
        anchorPlayed = 12, lastServerPlayed = 13,
        trackedSinceAnchor = 14, untrackedSeconds = 15,
    },
    chain = { sequence = 16 },
    economy = {
        money = { last = 17, lastPlayed = 18, unexplained = 19, anomalies = 20 },
        items = { anomalies = 21 },
    },
    durabilityState = {
        slots = { [1] = { id = 22, guid = "fp-item", cur = 23, max = 24 } },
    },
    deathLoss = {
        pending = { ["25"] = { at = 26, count = 27, seen = 28, recorded = true } },
    },
}

local sealFingerprint

local function SealFingerprint()
    if not sealFingerprint then
        sealFingerprint = I.Hash(I.Canonical(CriticalState(FINGERPRINT_RECORD)))
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
--
-- Returns true when everything reconciles, plus a reason string when it does
-- not. A third return marks the case where there was nothing to judge, because
-- the seal was written in a shape this build cannot reproduce -- callers use it
-- to tell "checked and clean" apart from "not checkable".
function I.Check(record)
    record = record or V.GetRecord()
    if not record then return true end

    local chain = record.chain
    if not chain or not chain.seal then
        -- Nothing sealed yet (a record created by an older build). Not evidence
        -- of anything; the next Seal() call adopts it.
        return true, nil, true
    end
    if chain.sealVersion ~= I.SEAL_VERSION or chain.sealFields ~= SealFingerprint() then
        -- Sealed by a build that protected a different field list -- either
        -- because the version was bumped deliberately, or because the shape
        -- changed and the fingerprint noticed on its own. Either way there is
        -- nothing to compare against, so it is not treated as tampering.
        return true, nil, true
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

-- Drop an integrity verdict this build can no longer stand behind.
--
-- Reached when the seal was written in a shape that no longer reproduces --
-- normally an addon update. The old verdict was a statement about a comparison
-- that cannot be made any more, so keeping it would mean holding a player to an
-- accusation nobody can now check. The record re-seals in the current shape and
-- is held to the check normally from the next login on.
function I.ReleaseStaleVerdict(record)
    if not record then return false end

    local released = false
    for _, trackName in ipairs({ "difficulty", "selfFound" }) do
        local track = record[trackName]
        if track and track.integrityHold then
            track.integrityHold = nil
            track.statusReason = nil
            -- Restore decides for itself whether the track is actually
            -- suspended, so there is no second guess to get wrong here.
            if V.Restore then
                V.Restore(trackName, "integrity verdict no longer applies")
            end
            released = true
        end
    end

    if record.tamperReason then
        record.tamperReason = nil
        record.tamperAt = nil
        released = true
    end
    return released
end

function I.Init()
    if I.initialized then return end
    I.initialized = true

    local record = V.GetRecord()
    if not record then return end

    local ok, reason, stale = I.Check(record)
    if ok and stale then
        -- Nothing to compare against. Clear anything a previous build concluded
        -- from a comparison this one cannot repeat, then adopt the record.
        if I.ReleaseStaleVerdict(record) then
            print("|cffff4444Rustcore:|r Verification restored: the previous integrity "
                .. "warning came from an older build's bookkeeping, not from your record.")
        end
        I.Seal(record)
        return
    end
    if not ok then
        -- Suspended, not ended.
        --
        -- A mismatch says Rustcore cannot vouch for the saved history. It does
        -- not say the player edited anything -- twice now it has been Rustcore's
        -- own bookkeeping -- and UNVERIFIED is terminal, so that verdict turned
        -- an addon bug into a permanently dead run with no way back.
        --
        -- SUSPENDED costs the certification just the same, and it comes back
        -- after a stretch of clean, observed play. Someone who really did edit
        -- their SavedVariables gains nothing by it and waits out the same
        -- half hour; someone Rustcore wronged recovers on their own.
        record.tamperReason = reason
        record.tamperAt = time and time() or 0

        local tracked = (record.time and record.time.trackedSinceAnchor) or 0
        local required = tracked + (V.INTEGRITY_RESTORE_TRACKED or 1800)
        for _, trackName in ipairs({ "difficulty", "selfFound" }) do
            local track = record[trackName]
            if track then
                if V.SetStatus(trackName, V.STATUS.SUSPENDED, "integrity: " .. reason) then
                    track.integrityHold = required
                end
            end
        end
        I.Seal(record)
    end
end
