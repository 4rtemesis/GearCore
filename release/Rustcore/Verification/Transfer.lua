-- Rustcore Verification: character transfer between PCs
-- (plan sections 32 to 42).
--
-- Moving a character's verification to another machine is the one operation that
-- hands a player their whole certification as editable text, so most of this
-- file is about refusing to accept it.
--
-- What makes a transfer trustworthy is not the string; it is /played. The server
-- knows exactly how long the character has been played, an export records that
-- number, and an import compares it against the live one. That comparison stops
-- the two attacks worth caring about:
--
--   rollback    exporting at 50 hours, playing to 55, then importing the old
--               string to erase what happened between. The live /played is five
--               hours past the export, so it is refused.
--   fabrication a hand-written string cannot know a /played the server agrees
--               with, and the checksum has to reconcile as well.
--
-- The format is RC2: positional, numeric, and without a single English word in
-- it. Field *names* used to be repeated inside every payload, statuses were
-- spelled out as "LEGACY_MIGRATION", and item links carried their own display
-- text -- all of it describing a layout both ends already know from the schema
-- version. RC2 stores values in a fixed order and nothing else.
--
--   RC2:<checksum>:<v1~v2~v3~...>
--
-- There is no RC1 compatibility. The old format is gone rather than carried
-- along, because supporting both would mean two parsers and two sets of
-- validation rules to keep honest for a string that is regenerated in seconds.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.Transfer = V.Transfer or {}
local X = V.Transfer

local floor, concat = math.floor, table.concat

X.PREFIX = "RC2"
X.SCHEMA = 2

-- A transfer stays valid while the live /played is within ten minutes of the
-- exported one.
X.PLAYED_TOLERANCE = 600

-- How much of that difference may go unexplained by play this session tracked.
-- Covers the ordinary leak in a legitimate transfer: the seconds between
-- pressing Export and logging out, and accrual lag around a loading screen.
-- Kept tight, because this decides how long a window an old export could be used
-- to undo something in.
X.UNACCOUNTED_ALLOWANCE = 90

X.PLAYED_TIMEOUT = 10

-- Separators. Every leaf value is base36, decimal, or lowercase hex, so none of
-- these three can appear inside one. `~` rather than `-` at the top level
-- because a player GUID contains dashes.
local FIELD_SEP, GROUP_SEP, PAIR_SEP = "~", ".", ","

local function Hash(text)
    if V.Integrity and V.Integrity.Hash then return V.Integrity.Hash(text) end
    return "nohash"
end

-- Base36 ------------------------------------------------------------------------
--
-- Roughly a third off the long numbers -- /played in seconds, copper, item ids,
-- sequence counters -- for about fifteen lines and no dependency. Non-negative
-- only, which every value encoded this way is.

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

local function ToB36(value)
    local n = floor(tonumber(value) or 0)
    if n <= 0 then return "0" end
    local digits = {}
    while n > 0 do
        local d = n % 36
        digits[#digits + 1] = B36:sub(d + 1, d + 1)
        n = floor(n / 36)
    end
    -- Built least-significant first; reverse into place.
    local out = {}
    for i = #digits, 1, -1 do out[#out + 1] = digits[i] end
    return concat(out)
end

-- Returns nil for anything that is not a valid base36 string, which is what
-- makes the importer's validation strict rather than forgiving.
local function FromB36(text)
    if type(text) ~= "string" or text == "" then return nil end
    local n = 0
    for i = 1, #text do
        local d = B36:find(text:sub(i, i), 1, true)
        if not d then return nil end
        n = n * 36 + (d - 1)
    end
    return n
end

X.ToB36, X.FromB36 = ToB36, FromB36

-- Codes -------------------------------------------------------------------------
--
-- Every enumerated value travels as a small integer. Both ends resolve it
-- through these tables, so the payload never carries a word like "UNVERIFIED".

local STATUS_TO_CODE = {
    VERIFIED = 1, WARNING = 2, SUSPENDED = 3,
    UNCERTAIN = 4, UNVERIFIED = 5, FAILED = 6,
}
local CODE_TO_STATUS = {}
for name, code in pairs(STATUS_TO_CODE) do CODE_TO_STATUS[code] = name end

local ORIGIN_TO_CODE = { NEW_CHARACTER = 1, LEGACY_MIGRATION = 2, IMPORT = 3 }
local CODE_TO_ORIGIN = {}
for name, code in pairs(ORIGIN_TO_CODE) do CODE_TO_ORIGIN[code] = name end

local BAND_TO_CODE = { OK = 1, WARNING = 2, SEVERE = 3 }
local CODE_TO_BAND = {}
for name, code in pairs(BAND_TO_CODE) do CODE_TO_BAND[code] = name end

-- Warning kinds. Append only: an existing number must never be reused for a
-- different kind, or an older export would import as the wrong finding.
local WARN_TO_CODE = {
    unexplainedRepair = 1,
    untrackedPlay     = 2,
    goldDiscrepancy   = 3,
    itemDiscrepancy   = 4,
    mailAcquisition   = 5,
    deathLossItem     = 6,
}
local CODE_TO_WARN = {}
for name, code in pairs(WARN_TO_CODE) do CODE_TO_WARN[code] = name end

-- Self-Found violation reasons, likewise append-only. The text is rebuilt on
-- import so the record still reads sensibly; only the code travels.
local VIOLATION_TEXT = {
    [1] = "received an item in a player trade",
    [2] = "received money in a player trade",
    [3] = "used the auction house",
    [4] = "took a blocked mail attachment",
    [5] = "an unexplained acquisition",
}
local TEXT_TO_VIOLATION = {}
for code, text in pairs(VIOLATION_TEXT) do TEXT_TO_VIOLATION[text] = code end

-- Best-effort match for a reason string that was produced before codes existed,
-- or built by string concatenation elsewhere.
local function ViolationCode(reason)
    if type(reason) ~= "string" or reason == "" then return 0 end
    local exact = TEXT_TO_VIOLATION[reason]
    if exact then return exact end
    if reason:find("trade", 1, true) then
        return reason:find("money", 1, true) and 2 or 1
    end
    if reason:find("auction", 1, true) then return 3 end
    if reason:find("mail", 1, true) then return 4 end
    return 5
end

-- Self-Found booleans, packed into one field instead of three.
local SF_CLAIMED, SF_LAPSED, SF_SUSPENDED = 1, 2, 4

-- Group packing -------------------------------------------------------------------

-- Warnings as "code,count.code,count". Unknown kinds are dropped rather than
-- carried as text: a warning Rustcore cannot name is one it cannot act on.
local function PackWarnings(track)
    local warnings = type(track) == "table" and track.warnings or nil
    if type(warnings) ~= "table" then return "" end
    local parts = {}
    for kind, count in pairs(warnings) do
        local code = WARN_TO_CODE[kind]
        if code and (tonumber(count) or 0) > 0 then
            parts[#parts + 1] = code .. PAIR_SEP .. ToB36(count)
        end
    end
    table.sort(parts)
    return concat(parts, GROUP_SEP)
end

local function UnpackWarnings(text)
    local warnings = {}
    if type(text) ~= "string" or text == "" then return warnings end
    for entry in text:gmatch("[^%" .. GROUP_SEP .. "]+") do
        local code, count = entry:match("^(%d+)" .. PAIR_SEP .. "(%w+)$")
        local kind = code and CODE_TO_WARN[tonumber(code)]
        local n = count and FromB36(count)
        if not kind or not n then return nil end   -- malformed: reject the import
        warnings[kind] = n
    end
    return warnings
end

-- Durability, positionally by the known durable-slot order rather than storing a
-- slot id per entry. An absent slot is an empty group, so the order alone says
-- which slot each entry belongs to.
local DURABLE_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }

local function PackDurability(record)
    local state = record.durabilityState
    local slots = type(state) == "table" and state.slots or nil
    if type(slots) ~= "table" then return "" end

    local parts, any = {}, false
    for i, slot in ipairs(DURABLE_SLOTS) do
        local entry = slots[slot]
        if type(entry) == "table" and entry.cur and entry.max then
            parts[i] = ToB36(entry.cur) .. PAIR_SEP .. ToB36(entry.max)
                .. PAIR_SEP .. ToB36(entry.id or 0)
            any = true
        else
            parts[i] = ""
        end
    end
    if not any then return "" end
    return concat(parts, GROUP_SEP)
end

local function UnpackDurability(text)
    if type(text) ~= "string" or text == "" then return nil end

    local slots, index = {}, 0
    -- Split preserving empties, so position still identifies the slot.
    local cursor = 1
    while true do
        local nextSep = text:find(GROUP_SEP, cursor, true)
        local piece = nextSep and text:sub(cursor, nextSep - 1) or text:sub(cursor)
        index = index + 1
        if index > #DURABLE_SLOTS then return nil end   -- too many groups

        if piece ~= "" then
            local cur, maximum, id = piece:match("^(%w+)" .. PAIR_SEP .. "(%w+)" .. PAIR_SEP .. "(%w+)$")
            local c, m, i2 = FromB36(cur or ""), FromB36(maximum or ""), FromB36(id or "")
            if not c or not m or not i2 then return nil end
            slots[DURABLE_SLOTS[index]] = { cur = c, max = m, id = (i2 > 0) and i2 or nil }
        end

        if not nextSep then break end
        cursor = nextSep + 1
    end
    return slots
end

-- Best item lost, as id.suffix.unique -- never a hyperlink and never a name.
-- The suffix is signed (Classic random suffixes are negative) so it stays plain
-- decimal; the other two are base36.
local function PackBestItem(link)
    if type(link) ~= "string" then return "" end
    local itemString = link:match("|H(item[^|]*)|h") or link:match("^(item:[%d:%-]+)")
    if not itemString then return "" end

    local pieces, cursor = {}, 1
    while true do
        local nextSep = itemString:find(":", cursor, true)
        pieces[#pieces + 1] = nextSep and itemString:sub(cursor, nextSep - 1) or itemString:sub(cursor)
        if not nextSep then break end
        cursor = nextSep + 1
    end

    local id = tonumber(pieces[2])
    if not id or id <= 0 then return "" end
    local suffix = tonumber(pieces[8]) or 0
    local unique = tonumber(pieces[9]) or 0
    return ToB36(id) .. GROUP_SEP .. tostring(floor(suffix))
        .. GROUP_SEP .. ToB36(unique >= 0 and unique or 0)
end

-- Rebuild an item string the client can resolve. The display name and full link
-- come back from GetItemInfo rather than travelling in the payload.
local function UnpackBestItem(text)
    if type(text) ~= "string" or text == "" then return nil end
    local id, suffix, unique = text:match("^(%w+)%" .. GROUP_SEP .. "(%-?%d+)%" .. GROUP_SEP .. "(%w+)$")
    local itemID = FromB36(id or "")
    local uniqueID = FromB36(unique or "")
    if not itemID or itemID <= 0 or not uniqueID then return nil end
    return string.format("item:%d:0:0:0:0:0:%d:%d", itemID, tonumber(suffix) or 0, uniqueID)
end

-- Resolve `itemString` to a real link and store it. GetItemInfo answers nil for
-- an item the client has not cached, so the lookup is retried when the server
-- sends it.
local function ApplyBestItemLink(itemString, ilvl)
    if not itemString then return end

    local function store()
        local stats = X.GetStatsTable and X.GetStatsTable()
        if not stats then return false end
        local _, link = GetItemInfo(itemString)
        if not link then return false end
        stats.bestItemLostLink = link
        stats.bestItemLostIlvl = ilvl or stats.bestItemLostIlvl or 0
        if RustcoreStats and RustcoreStats.Refresh then RustcoreStats.Refresh() end
        return true
    end

    if store() then return end

    local waiter = CreateFrame("Frame")
    waiter:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    waiter:SetScript("OnEvent", function(self)
        if store() then
            self:UnregisterAllEvents()
            self:SetScript("OnEvent", nil)
        end
    end)
    -- Give up rather than listen forever for an item the server will not send.
    if C_Timer and C_Timer.After then
        C_Timer.After(30, function()
            waiter:UnregisterAllEvents()
            waiter:SetScript("OnEvent", nil)
        end)
    end
end

-- Identity -------------------------------------------------------------------------
--
-- The GUID is the whole of the identity now. Name, realm, class and race were
-- carried before and never consulted -- the import validated the GUID and then
-- rebuilt the identity block from the live character anyway -- so they were four
-- fields of pure weight. The "Player-" prefix every GUID starts with is dropped
-- and both sides compare the same stripped form, so nothing has to reconstruct it.

local function StripGuid(guid)
    if type(guid) ~= "string" or guid == "" then return nil end
    return (guid:gsub("^Player%-", ""))
end

local function CurrentGuid()
    return StripGuid(UnitGUID and UnitGUID("player") or nil)
end

-- Stats -----------------------------------------------------------------------------

function X.GetStatsTable()
    if not RustcoreDB then return nil end
    RustcoreDB.characterStats = RustcoreDB.characterStats or {}
    local key = Rustcore and Rustcore.GetCharacterKey and Rustcore.GetCharacterKey()
        or (UnitName and UnitName("player")) or "player"
    RustcoreDB.characterStats[key] = RustcoreDB.characterStats[key] or {}
    return RustcoreDB.characterStats[key]
end
local GetStatsTable = X.GetStatsTable

-- Field order ------------------------------------------------------------------------
--
-- The schema version owns this list. Positions are never reordered or reused;
-- a change here means a new X.SCHEMA and a new prefix.
X.FIELD_COUNT = 40

-- Export ------------------------------------------------------------------------------

function X.BuildString(freshPlayed)
    local record = V.GetRecord()
    if not record then return nil, "no verification record for this character" end

    local guid = CurrentGuid()
    if not guid then
        -- Without a GUID there is no identity to bind the transfer to, and an
        -- import could not tell whose it was.
        return nil, "your character ID is not available yet; try again in a moment"
    end

    local difficulty = record.difficulty or {}
    local selfFound  = record.selfFound or {}
    local timeState  = record.time or {}
    local economy    = record.economy or {}
    local money      = economy.money or {}
    local items      = economy.items or {}
    local chain      = record.chain or {}
    local stats      = GetStatsTable() or {}

    local sFlags = 0
    if selfFound.claimed     then sFlags = sFlags + SF_CLAIMED end
    if selfFound.claimLapsed then sFlags = sFlags + SF_LAPSED end
    if selfFound.suspended   then sFlags = sFlags + SF_SUSPENDED end

    local function tier(value) return tostring(floor(tonumber(value) or 0)) end
    local function opt(value) return value and ToB36(value) or "" end

    local fields = {
        tostring(X.SCHEMA),                                          --  1
        guid,                                                        --  2
        tostring(ORIGIN_TO_CODE[record.origin or ""] or 0),          --  3
        ToB36(record.createdAt or 0),                                --  4

        tostring(STATUS_TO_CODE[difficulty.status or ""] or 0),      --  5
        tier(difficulty.highestVerifiedTier),                        --  6
        tier(difficulty.permanentCapTier),                           --  7
        tier(difficulty.pendingCapTier),                             --  8
        tier(difficulty.deathFloorTier),                             --  9
        tier(difficulty.startedAtLevel),                             -- 10
        ToB36(difficulty.deaths or 0),                               -- 11
        ToB36(difficulty.repairViolations or 0),                     -- 12
        PackWarnings(difficulty),                                    -- 13

        tostring(STATUS_TO_CODE[selfFound.status or ""] or 0),       -- 14
        tier(selfFound.startedAtLevel),                              -- 15
        tier(selfFound.qualifyFromLevel),                            -- 16
        tier(selfFound.claimedAtLevel),                              -- 17
        tostring(sFlags),                                            -- 18
        opt(selfFound.restoreAtTracked),                             -- 19
        ToB36(selfFound.violations or 0),                            -- 20
        tostring(ViolationCode(selfFound.lastViolation)),            -- 21
        PackWarnings(selfFound),                                     -- 22

        ToB36(timeState.anchorPlayed or 0),                          -- 23
        ToB36(freshPlayed or timeState.lastServerPlayed or 0),       -- 24
        ToB36(timeState.trackedSinceAnchor or 0),                    -- 25
        ToB36(timeState.untrackedSeconds or 0),                      -- 26
        -- Field kept so the wire format keeps its shape, but the band it used
        -- to carry no longer exists: the receiving side derives the tracking
        -- verdict from fields 23-26, which are the evidence the band was only
        -- ever a conclusion about. Carrying the conclusion as well meant an
        -- import could import a verdict that the numbers beside it disagreed
        -- with, and that could never recover.
        "1",                                                         -- 27

        opt(money.last),                                             -- 28
        opt(money.lastPlayed),                                       -- 29
        ToB36(money.unexplained or 0),                               -- 30
        ToB36(money.anomalies or 0),                                 -- 31
        ToB36(items.anomalies or 0),                                 -- 32

        PackDurability(record),                                      -- 33

        chain.head or "",                                            -- 34
        ToB36(chain.sequence or 0),                                  -- 35

        ToB36(stats.destroyedItems or 0),                            -- 36
        ToB36(stats.rustedItems or 0),                               -- 37
        ToB36(stats.deaths or 0),                                    -- 38
        ToB36(stats.bestItemLostIlvl or 0),                          -- 39
        PackBestItem(stats.bestItemLostLink),                        -- 40
    }

    local body = concat(fields, FIELD_SEP)
    return X.PREFIX .. ":" .. Hash(body) .. ":" .. body
end

-- Import --------------------------------------------------------------------------

-- Split preserving empty fields, since position is the only thing identifying
-- them.
local function SplitFields(body)
    local out, cursor = {}, 1
    while true do
        local nextSep = body:find(FIELD_SEP, cursor, true)
        out[#out + 1] = nextSep and body:sub(cursor, nextSep - 1) or body:sub(cursor)
        if not nextSep then break end
        cursor = nextSep + 1
    end
    return out
end

-- Parse and check everything checkable without the server. Returns a decoded
-- table, or nil plus a reason. Every field is validated for type and range
-- before any of it is applied.
function X.Parse(text)
    if type(text) ~= "string" then return nil, "nothing to import" end
    -- Line breaks are stripped wherever they appear: no field can contain one,
    -- so any that survives was introduced in transit.
    text = text:gsub("[\r\n%s]", "")
    if text == "" then return nil, "nothing to import" end

    local prefix, checksum, body = text:match("^(RC%d+):(%x+):(.*)$")
    if not prefix then
        return nil, "this does not look like a Rustcore transfer string"
    end
    if prefix ~= X.PREFIX then
        return nil, "this transfer was created by an incompatible version of Rustcore"
    end
    if Hash(body) ~= checksum then
        return nil, "the transfer string is damaged or was edited"
    end

    local raw = SplitFields(body)
    if #raw ~= X.FIELD_COUNT then
        return nil, "this transfer is malformed"
    end

    -- Small typed readers. Any failure aborts the whole import rather than
    -- silently substituting a default, because a field Rustcore cannot read is a
    -- field it cannot make a certification decision from.
    local bad = false
    local function int(index, lo, hi)
        local n = tonumber(raw[index])
        if not n or n ~= floor(n) or n < lo or n > hi then bad = true; return nil end
        return n
    end
    local function b36(index)
        local n = FromB36(raw[index])
        if not n then bad = true end
        return n
    end
    local function b36opt(index)
        if raw[index] == "" then return nil end
        local n = FromB36(raw[index])
        if not n then bad = true end
        return n
    end
    local function tierOpt(index)
        local n = int(index, 0, V.MAX_TIER or 5)
        if n == 0 then return nil end
        return n
    end
    -- Character levels, not tiers. They travel in the same plain-decimal shape
    -- as a tier does, which is why they were read back through tierOpt at first,
    -- but a level is bounded by the game's level cap rather than by MAX_TIER --
    -- so every character past level 5 failed the range check and its transfer
    -- was rejected as malformed. The bound here only exists to reject garbage;
    -- the level cap itself is not Transfer's business to enforce.
    local function levelOpt(index)
        local n = int(index, 0, 255)
        if n == 0 then return nil end
        return n
    end

    local schema = int(1, X.SCHEMA, X.SCHEMA)
    if bad or schema ~= X.SCHEMA then
        return nil, "this transfer was created by an incompatible version of Rustcore"
    end

    local guid = raw[2]
    if type(guid) ~= "string" or guid == "" then return nil, "this transfer is malformed" end

    local dWarn = UnpackWarnings(raw[13])
    local sWarn = UnpackWarnings(raw[22])
    if not dWarn or not sWarn then return nil, "this transfer is malformed" end

    local durability = nil
    if raw[33] ~= "" then
        durability = UnpackDurability(raw[33])
        if not durability then return nil, "this transfer is malformed" end
    end

    local chainHead = raw[34]
    if chainHead ~= "" and not chainHead:match("^%x+$") then
        return nil, "this transfer is malformed"
    end

    local decoded = {
        guid        = guid,
        origin      = CODE_TO_ORIGIN[int(3, 0, 3) or 0],
        createdAt   = b36(4),

        dStatus     = CODE_TO_STATUS[int(5, 0, 6) or 0],
        dTier       = int(6, 0, V.MAX_TIER or 5),
        dCap        = tierOpt(7),
        dPending    = tierOpt(8),
        dFloor      = tierOpt(9),
        dLevel      = levelOpt(10),
        dDeaths     = b36(11),
        dRepairs    = b36(12),
        dWarnings   = dWarn,

        sStatus     = CODE_TO_STATUS[int(14, 0, 6) or 0],
        sLevel      = levelOpt(15),
        sQualify    = levelOpt(16),
        sClaimLevel = levelOpt(17),
        sFlags      = int(18, 0, 7),
        sRestoreAt  = b36opt(19),
        sViolations = b36(20),
        sViolCode   = int(21, 0, 9),
        sWarnings   = sWarn,

        anchor      = b36(23),
        played      = b36(24),
        tracked     = b36(25),
        untracked   = b36(26),
        band        = CODE_TO_BAND[int(27, 1, 3) or 1],

        moneyLast   = b36opt(28),
        moneyPlayed = b36opt(29),
        moneyUnexpl = b36(30),
        moneyAnom   = b36(31),
        itemAnom    = b36(32),

        durability  = durability,

        chainHead   = chainHead,
        chainSeq    = b36(35),

        statBroken  = b36(36),
        statRusted  = b36(37),
        statDeaths  = b36(38),
        statIlvl    = b36(39),
        bestItem    = (raw[40] ~= "") and UnpackBestItem(raw[40]) or nil,
    }

    if bad then return nil, "this transfer is malformed" end
    if raw[40] ~= "" and not decoded.bestItem then
        return nil, "this transfer is malformed"
    end

    -- Verification is bound to the character it was earned on.
    local currentGuid = CurrentGuid()
    if not currentGuid then
        return nil, "your character ID is not available yet; try again in a moment"
    end
    if decoded.guid ~= currentGuid then
        return nil, "this transfer belongs to a different character"
    end

    return decoded
end

-- Reconciliation ------------------------------------------------------------------

function X.Reconcile(decoded, serverPlayed)
    local exported = decoded.played or 0
    local difference = (serverPlayed or 0) - exported

    if difference < -60 then
        return false, "this transfer is from further ahead than this character"
    end

    if difference > X.PLAYED_TOLERANCE then
        return false, string.format(
            "%d minutes have been played since this was exported (limit %d)",
            floor(difference / 60), floor(X.PLAYED_TOLERANCE / 60))
    end

    local sessionTracked = 0
    if V.Time and V.Time.GetSessionTracked then
        sessionTracked = tonumber(V.Time.GetSessionTracked()) or 0
    end
    if sessionTracked > difference then sessionTracked = difference end
    if sessionTracked < 0 then sessionTracked = 0 end

    -- The elapsed played time has to be *explained* by play this session watched,
    -- not merely be small. Without this the tolerance is a ten-minute window to
    -- do something prohibited and then undo it: export, break a rule, relog,
    -- import. The relog is what this catches -- a fresh session has tracked
    -- almost nothing while the server's clock kept running.
    local unaccounted = difference - sessionTracked
    if unaccounted > X.UNACCOUNTED_ALLOWANCE then
        return false, string.format(
            "%d minutes of play since the export were not watched by Rustcore "
            .. "on this PC; export again there and log out within a minute of "
            .. "pressing Export",
            floor(unaccounted / 60) + 1)
    end

    return true, nil, sessionTracked
end

-- Pessimising merge ----------------------------------------------------------------
--
-- An import brings state from elsewhere; it must never improve on what this
-- machine has seen with its own eyes. The rule is the one V.SetStatus enforces
-- everywhere else -- certification only ever moves downward -- so every field
-- takes whichever side is worse, and a transfer can restore a history without
-- erasing a finding.

local function WorseStatus(a, b)
    if not a or a == "" then return b end
    if not b or b == "" then return a end
    return (V.StatusRank(a) >= V.StatusRank(b)) and a or b
end

local function LowerTier(a, b)
    if type(a) ~= "number" then return b end
    if type(b) ~= "number" then return a end
    return a < b and a or b
end

local function HigherCount(a, b)
    return math.max(tonumber(a) or 0, tonumber(b) or 0)
end

-- The gap band and its comparator used to live here. Both are gone: the
-- tracking verdict is derived from the untracked seconds now, so there is no
-- band on either side of an import to compare.

local function MergeWarnings(target, localWarnings)
    if type(localWarnings) ~= "table" then return end
    for kind, count in pairs(localWarnings) do
        target[kind] = HigherCount(target[kind], count)
    end
end

local function PessimiseAgainstLocal(record, previous)
    if type(previous) ~= "table" then return false end

    local changed = false
    local pd, pf = previous.difficulty or {}, previous.selfFound or {}
    local rd, rf = record.difficulty, record.selfFound

    -- Both sides read as evidence, never as the composed status. The composed
    -- value includes derived components, and a local record whose tracking gap
    -- happened to be open at import time would otherwise have that moment
    -- frozen into the imported record as though Rustcore had caught something.
    local function noteStatus(track, localStatus)
        local mine = track.evidenceStatus or track.status
        local worse = WorseStatus(mine, localStatus)
        if worse ~= mine then
            track.evidenceStatus = worse
            track.status = worse
            changed = true
        end
    end

    noteStatus(rd, pd.evidenceStatus or pd.status)
    noteStatus(rf, pf.evidenceStatus or pf.status)

    rd.highestVerifiedTier = LowerTier(rd.highestVerifiedTier, pd.highestVerifiedTier)
    rd.permanentCapTier    = LowerTier(rd.permanentCapTier, pd.permanentCapTier)
    rd.deathFloorTier      = LowerTier(rd.deathFloorTier, pd.deathFloorTier)
    rd.pendingCapTier      = LowerTier(rd.pendingCapTier, pd.pendingCapTier)

    rd.deaths           = HigherCount(rd.deaths, pd.deaths)
    rd.repairViolations = HigherCount(rd.repairViolations, pd.repairViolations)
    rf.violations       = HigherCount(rf.violations, pf.violations)
    if not rf.lastViolation and pf.lastViolation then
        rf.lastViolation = pf.lastViolation
    end
    if (rf.violations or 0) > 0 or (rd.repairViolations or 0) > 0 then changed = true end

    MergeWarnings(rd.warnings, pd.warnings)
    MergeWarnings(rf.warnings, pf.warnings)

    if pf.suspended then rf.suspended = true end
    if pf.claimLapsed then rf.claimLapsed = true end
    if type(pf.restoreAtTracked) == "number" then
        rf.restoreAtTracked = math.max(tonumber(rf.restoreAtTracked) or 0, pf.restoreAtTracked)
    end

    -- The measurement, and only the measurement. The verdict the two sides
    -- reached about it is not merged, because it is not stored on either side
    -- any more -- keeping the worse of two stale conclusions was exactly the
    -- latch that made a closed gap impossible to recover from.
    local pt = previous.time or {}
    record.time.untrackedSeconds = HigherCount(record.time.untrackedSeconds, pt.untrackedSeconds)

    local pe = previous.economy or {}
    local pem, pei = pe.money or {}, pe.items or {}
    record.economy.money.unexplained = HigherCount(record.economy.money.unexplained, pem.unexplained)
    record.economy.money.anomalies   = HigherCount(record.economy.money.anomalies, pem.anomalies)
    record.economy.items.anomalies   = HigherCount(record.economy.items.anomalies, pei.anomalies)

    -- Durability evidence: keep whichever side records the *lower* remaining
    -- durability for a slot, so an import cannot restore a healthier reading and
    -- hide a repair that happened here.
    local pdur = previous.durabilityState
    if type(pdur) == "table" and type(pdur.slots) == "table" then
        record.durabilityState = record.durabilityState or { slots = {}, established = true }
        local slots = record.durabilityState.slots
        for slot, entry in pairs(pdur.slots) do
            local mine = slots[slot]
            if type(entry) == "table" and (not mine or (entry.cur or 0) < (mine.cur or 0)) then
                slots[slot] = { cur = entry.cur, max = entry.max, id = entry.id, guid = entry.guid }
            end
        end
    end

    -- Keep whichever chain has seen more; a local chain further along covers
    -- events the export never knew about.
    local pc = previous.chain or {}
    if (tonumber(pc.sequence) or 0) > (tonumber(record.chain.sequence) or 0) then
        record.chain.head = pc.head or record.chain.head
        record.chain.sequence = pc.sequence
    end

    return changed
end

-- Apply -------------------------------------------------------------------------------

local function ApplyFields(decoded, serverPlayed, creditSeconds)
    local key, previousRecord = V.FindRecordKey()
    if not key then
        key = (Rustcore and Rustcore.GetCharacterKey and Rustcore.GetCharacterKey())
            or (UnitGUID and UnitGUID("player")) or (UnitName and UnitName("player")) or "player"
    end

    local record = {
        schemaVersion = V.SCHEMA_VERSION,
        createdAt     = decoded.createdAt or (time and time() or 0),
        addonVersion  = V.GetAddonVersion(),
        identity      = V.BuildIdentity(),
        origin        = decoded.origin or "IMPORT",
        migrationComplete = true,
        importedAt    = time and time() or 0,
    }

    record.difficulty = V.NewTrack(decoded.dStatus or V.STATUS.UNVERIFIED)
    record.difficulty.highestVerifiedTier = decoded.dTier or 0
    record.difficulty.permanentCapTier    = decoded.dCap
    record.difficulty.pendingCapTier      = decoded.dPending
    record.difficulty.deathFloorTier      = decoded.dFloor
    record.difficulty.startedAtLevel      = decoded.dLevel
    record.difficulty.currentTier         = V.GetCurrentTier()
    record.difficulty.deaths              = decoded.dDeaths or 0
    record.difficulty.repairViolations    = decoded.dRepairs or 0
    record.difficulty.warnings            = decoded.dWarnings or {}

    local flags = decoded.sFlags or 0
    local function hasFlag(bit) return floor(flags / bit) % 2 == 1 end

    record.selfFound = V.NewTrack(decoded.sStatus or V.STATUS.UNCERTAIN)
    record.selfFound.startedAtLevel   = decoded.sLevel
    record.selfFound.qualifyFromLevel = decoded.sQualify
    record.selfFound.claimedAtLevel   = decoded.sClaimLevel
    record.selfFound.claimed          = hasFlag(SF_CLAIMED)
    record.selfFound.claimLapsed      = hasFlag(SF_LAPSED) or nil
    record.selfFound.suspended        = hasFlag(SF_SUSPENDED) or nil
    record.selfFound.restoreAtTracked = decoded.sRestoreAt
    record.selfFound.violations       = decoded.sViolations or 0
    record.selfFound.lastViolation    = (decoded.sViolCode or 0) > 0
        and VIOLATION_TEXT[decoded.sViolCode] or nil
    record.selfFound.warnings         = decoded.sWarnings or {}

    record.time = {
        anchorPlayed       = decoded.anchor or 0,
        lastServerPlayed   = serverPlayed,
        trackedSinceAnchor = (decoded.tracked or 0) + (creditSeconds or 0),
        untrackedSeconds   = decoded.untracked or 0,
        lastPlayedCheck    = time and time() or nil,
    }

    record.economy = {
        money = {
            last        = decoded.moneyLast,
            lastPlayed  = decoded.moneyPlayed,
            unexplained = decoded.moneyUnexpl or 0,
            anomalies   = decoded.moneyAnom or 0,
        },
        items = { anomalies = decoded.itemAnom or 0 },
    }

    if decoded.durability then
        record.durabilityState = { slots = decoded.durability, established = true }
    end

    record.chain = {
        head     = decoded.chainHead or "",
        sequence = decoded.chainSeq or 0,
        events   = {},
    }

    local keptLocal = PessimiseAgainstLocal(record, previousRecord)
    record.importKeptLocalFindings = keptLocal or nil

    V.GetStore()[key] = record

    -- Stats. Merged rather than replaced: these only count upward during play,
    -- so the higher of the two sides restores a history without letting an old
    -- string undo losses recorded here since it was written.
    local stats = GetStatsTable()
    if stats then
        stats.destroyedItems = HigherCount(stats.destroyedItems, decoded.statBroken or 0)
        stats.rustedItems    = HigherCount(stats.rustedItems, decoded.statRusted or 0)
        stats.deaths         = HigherCount(stats.deaths, decoded.statDeaths or 0)
        if (decoded.statIlvl or 0) > (tonumber(stats.bestItemLostIlvl) or 0) then
            -- The link itself is rebuilt from the item id through GetItemInfo.
            ApplyBestItemLink(decoded.bestItem, decoded.statIlvl)
        end
    end

    if V.Integrity and V.Integrity.Append then
        V.Integrity.Append("IMPORT", {
            played = floor(serverPlayed or 0),
            credit = floor(creditSeconds or 0),
        })
    end
    if V.Integrity and V.Integrity.Seal then V.Integrity.Seal() end

    return record
end

-- Flows ----------------------------------------------------------------------------

function X.BeginExport(callback)
    local record = V.GetRecord()
    if not record then
        callback(nil, "no verification record for this character")
        return
    end

    local done = false
    -- The played figure comes from the TIME_PLAYED_MSG payload rather than
    -- Time.lua's stored copy: both modules listen for that event and the order
    -- their frames are called in is not defined.
    local function finish(played)
        if done then return end
        done = true
        local str, err = X.BuildString(played)
        if str and V.Integrity and V.Integrity.Append then
            V.Integrity.Append("EXPORT", { played = floor(played or 0) })
        end
        callback(str, err)
    end

    X.pendingExport = finish
    if V.Time and V.Time.Request then V.Time.Request() end

    if C_Timer and C_Timer.After then
        C_Timer.After(X.PLAYED_TIMEOUT, function()
            if X.pendingExport ~= finish then return end
            X.pendingExport = nil
            finish()
        end)
    else
        finish()
    end
end

function X.BeginImport(text, callback)
    local decoded, err = X.Parse(text)
    if not decoded then
        callback(false, err)
        return
    end

    local done = false
    local function finish(played)
        if done then return end
        done = true

        local serverPlayed = played or (V.Time and V.Time.GetLastServerPlayed()) or 0
        local ok, reason, credit = X.Reconcile(decoded, serverPlayed)
        if not ok then
            callback(false, reason)
            return
        end

        ApplyFields(decoded, serverPlayed, credit)

        -- The imported money figures belong to the other PC's last reading, so
        -- the live comparison here starts from the real balance instead.
        if V.Money and V.Money.Rebase then V.Money.Rebase() end
        if V.Inventory and V.Inventory.Rebase then V.Inventory.Rebase() end

        if RustcoreDragon then
            if RustcoreDragon.RefreshPlayerFrame then RustcoreDragon.RefreshPlayerFrame() end
            if RustcoreDragon.RefreshTargetFrame then RustcoreDragon.RefreshTargetFrame() end
        end
        if RustcoreSelfFoundBuff and RustcoreSelfFoundBuff.Refresh then
            RustcoreSelfFoundBuff.Refresh()
        end
        if RustcoreStats and RustcoreStats.Refresh then RustcoreStats.Refresh() end

        local record = V.GetRecord()
        local message = string.format("Verification imported. %d clean minute(s) on this PC kept.",
            floor((credit or 0) / 60))
        if record and record.importKeptLocalFindings then
            message = message .. " This computer had already recorded something "
                .. "the transfer did not, so that was kept."
        end
        callback(true, message)
    end

    X.pendingImport = finish
    if V.Time and V.Time.Request then V.Time.Request() end

    if C_Timer and C_Timer.After then
        C_Timer.After(X.PLAYED_TIMEOUT, function()
            if X.pendingImport ~= finish then return end
            X.pendingImport = nil
            callback(false, "the server did not report played time; try again")
            done = true
        end)
    else
        finish()
    end
end

function X.OnTimePlayed(totalPlayed)
    local exportCallback = X.pendingExport
    local importCallback = X.pendingImport
    X.pendingExport, X.pendingImport = nil, nil
    if exportCallback then exportCallback(totalPlayed) end
    if importCallback then importCallback(totalPlayed) end
end

function X.Init()
    if X.initialized then return end
    X.initialized = true

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("TIME_PLAYED_MSG")
    frame:SetScript("OnEvent", function(_, _, totalPlayed)
        local ok, err = pcall(X.OnTimePlayed, totalPlayed)
        if not ok then
            print("|cffff4444Rustcore ERROR:|r transfer: " .. tostring(err))
        end
    end)
    X.frame = frame
end
