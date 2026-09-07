-- Rustcore Verification: record creation, grandfathering and identity binding
-- (plan sections 3, 4 and 5).
--
-- Two entry points, called from Rustcore.lua's ADDON_LOADED handler:
--   CaptureEvidence()  before any other module touches RustcoreDB
--   Run()              after settings are initialised
--
-- The split exists because Rustcore's own modules create empty per-character
-- tables as soon as they initialise. Reading RustcoreDB first is the only way
-- to tell "this character has played Rustcore before" from "this session just
-- created the table". Evidence is judged on content as well as existence, so
-- the classification still holds even if the ordering ever changes.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.Migration = V.Migration or {}
local M = V.Migration

-- Slots that carry durability, matching SLOT_DATA in RustcoreDurability.lua.
-- Phase 3 takes ownership of durability comparison; this is only the baseline
-- snapshot the plan asks migration to take (section 4, step 5).
local DURABLE_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }

local evidence

-- Legacy data is looked up under every key this character could plausibly have
-- used (V.CandidateKeys in Core), or grandfathering would silently miss a
-- character whose tables were written before UnitGUID was available.

local function CountKeys(tbl)
    if type(tbl) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

-- A profile that exists before Rustcore.lua has initialised settings was
-- written by an earlier session. `characterLabel` is stamped by EnsureProfile
-- on every run, so anything beyond it is a setting the player actually changed.
local function InspectProfile(profile)
    if type(profile) ~= "table" then return false, false end
    local meaningful = false
    for key in pairs(profile) do
        if key ~= "characterLabel" then
            meaningful = true
            break
        end
    end
    return true, meaningful
end

local function InspectSelfFound(profile)
    if type(profile) ~= "table" then return false end
    return profile.hasEnabledSelfFound == true
        or profile.startedAtLevelOne == true
        or profile.externalItemReceived == true
end

-- Stats tables are created empty on first run, so existence proves nothing.
-- Only actual recorded losses count as evidence of prior play.
local function InspectStats(stats)
    if type(stats) ~= "table" then return false end
    return (stats.destroyedItems or 0) > 0
        or (stats.rustedItems or 0) > 0
        or (stats.bestItemLostIlvl or 0) > 0
        or CountKeys(stats.rustedItemKeys) > 0
        or CountKeys(stats.zeroDurabilitySlots) > 0
end

-- Called first thing in ADDON_LOADED, before InitSettings and before any other
-- Rustcore module has had a chance to create per-character tables.
function M.CaptureEvidence()
    if evidence then return evidence end

    evidence = {
        profileExisted   = false,
        profileChanged   = false,
        selfFoundHistory = false,
        statsHistory     = false,
        legacyGlobals    = false,
        savedDifficulty  = nil,
        savedSelfFound   = nil,
    }

    local db = RustcoreDB
    if type(db) ~= "table" then
        -- No SavedVariables at all: a genuinely new install.
        return evidence
    end

    -- Pre-profile-era Rustcore stored a couple of settings globally. Their
    -- presence proves an old install, though not which character used it, so
    -- it only ever corroborates per-character evidence.
    evidence.legacyGlobals = db.legacySettingsMigrated ~= nil
        or db.allowRepair ~= nil
        or db.blockRepair ~= nil

    for _, key in ipairs(V.CandidateKeys()) do
        local profile = db.profiles and db.profiles[key]
        local existed, changed = InspectProfile(profile)
        if existed then
            evidence.profileExisted = true
            if profile.difficulty ~= nil and evidence.savedDifficulty == nil then
                evidence.savedDifficulty = profile.difficulty
            end
            if profile.selfFound ~= nil and evidence.savedSelfFound == nil then
                evidence.savedSelfFound = profile.selfFound
            end
        end
        if changed then evidence.profileChanged = true end

        if InspectSelfFound(db.selfFoundCharacters and db.selfFoundCharacters[key]) then
            evidence.selfFoundHistory = true
        end
        if InspectStats(db.characterStats and db.characterStats[key]) then
            evidence.statsHistory = true
        end
    end

    return evidence
end

-- Plan section 4: detect a pre-verification character from the organic save
-- data Rustcore already created, never from a dedicated flag.
local function IsLegacyCharacter()
    if not evidence then return false end
    if evidence.statsHistory or evidence.selfFoundHistory then return true end
    if evidence.profileChanged then return true end
    -- A bare profile with nothing but characterLabel is only convincing when
    -- something else says an older Rustcore was installed.
    return evidence.profileExisted and evidence.legacyGlobals
end

-- ── Baselines (plan section 4, steps 5-7; section 6) ──────────────────────────

local function SnapshotBaseline(record)
    local baseline = {
        level = UnitLevel and UnitLevel("player") or nil,
        money = GetMoney and GetMoney() or nil,
        takenAt = time and time() or nil,
        durability = {},
    }

    for _, slot in ipairs(DURABLE_SLOTS) do
        local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
        if link then
            local current, maximum = GetInventoryItemDurability(slot)
            if current and maximum and maximum > 0 then
                baseline.durability[slot] = { cur = current, max = maximum }
            end
        end
    end

    record.baseline = baseline
    return baseline
end

-- ── Record creation ──────────────────────────────────────────────────────────

local function DifficultyStatusForNewCharacter(level)
    -- Plan section 5. Level 1 is the canonical clean start: the character has
    -- not progressed at all, so there is nothing that could have been
    -- circumvented and it is verified outright. Levels 2 to 8 install "shortly
    -- after beginning" and sit at UNCERTAIN until the qualification window in
    -- Phase 4 promotes them. Later than that stays UNVERIFIED.
    if not level or level <= 1 then
        return V.STATUS.VERIFIED
    elseif level <= V.LATE_START_MAX_LEVEL then
        return V.STATUS.UNCERTAIN
    end
    return V.STATUS.UNVERIFIED
end

local function CreateRecord(key)
    local level = UnitLevel and UnitLevel("player") or nil
    local legacy = IsLegacyCharacter()
    local tier = V.GetCurrentTier()
    local selfFoundOn = Rustcore and Rustcore.GetSetting and Rustcore.GetSetting("selfFound") or false

    local record = {
        schemaVersion = V.SCHEMA_VERSION,
        createdAt     = time and time() or 0,
        addonVersion  = V.GetAddonVersion(),
        identity      = V.BuildIdentity(),
        origin        = legacy and "LEGACY_MIGRATION" or "NEW_CHARACTER",
        migrationComplete = false,
        evidence      = evidence,
        time          = {},
    }

    local difficultyStatus
    if legacy then
        -- Plan section 4: existing Rustcore data is accepted as the starting
        -- truth, and a grandfathered player must not end up worse off than
        -- someone who started fresh today.
        difficultyStatus = V.STATUS.VERIFIED
    else
        difficultyStatus = DifficultyStatusForNewCharacter(level)
    end

    record.difficulty = V.NewTrack(difficultyStatus)
    record.difficulty.startedAtLevel = level
    record.difficulty.highestVerifiedTier = V.IsCertified(difficultyStatus) and tier or 0
    record.difficulty.currentTier = tier

    -- The Self-Found track is created for every character but only carries a
    -- claim once Self-Found is actually switched on. Until then it sits at
    -- UNCERTAIN, which is the only status Core allows to be promoted later --
    -- starting it at UNVERIFIED would permanently lock out a player who turns
    -- Self-Found on at level 1 tomorrow.
    local selfFoundClaimed = legacy and (evidence.selfFoundHistory or selfFoundOn) or selfFoundOn
    local selfFoundStatus
    if not selfFoundClaimed then
        selfFoundStatus = V.STATUS.UNCERTAIN
    elseif legacy then
        selfFoundStatus = V.STATUS.VERIFIED
    else
        selfFoundStatus = DifficultyStatusForNewCharacter(level)
    end

    record.selfFound = V.NewTrack(selfFoundStatus)
    record.selfFound.startedAtLevel = level
    record.selfFound.claimed = selfFoundClaimed and true or false
    if selfFoundClaimed then
        -- The claim starts here, so this is the level section 6 measures its
        -- qualification window from.
        record.selfFound.claimedAtLevel = level
        record.selfFound.qualifyFromLevel = level
        record.selfFound.claimedAt = record.createdAt
    end

    SnapshotBaseline(record)

    V.GetStore()[key] = record

    if V.Integrity and V.Integrity.Genesis then
        V.Integrity.Genesis(record, record.origin)
    end
    if V.Integrity and V.Integrity.Append then
        V.Integrity.Append("CREATE", {
            origin = record.origin,
            level = level or 0,
            tier = tier,
            difficulty = difficultyStatus,
            selfFound = selfFoundStatus,
            claimed = selfFoundClaimed and true or false,
        })
    end

    record.migrationComplete = true
    if V.Integrity and V.Integrity.Seal then
        V.Integrity.Seal(record)
    end

    -- Plan section 4, step 4: take a fresh /played reading immediately. This is
    -- what anchors the playtime accounting, so everything before this moment is
    -- grandfathered rather than counted as untracked.
    if V.Time and V.Time.Request then
        V.Time.Request()
    end

    return record
end

function M.Run()
    if not Rustcore or not Rustcore.GetCharacterKey then return end
    M.CaptureEvidence()

    -- A record written before the GUID was available lives under a name-realm
    -- key, so look under every key this character could have used before
    -- concluding there is nothing to migrate.
    local key, record = V.FindRecordKey()
    if not record then
        key = Rustcore.GetCharacterKey()
        if not key then return end
        CreateRecord(key)
        return
    end

    -- Verify the record before touching it, so nothing below can re-seal over
    -- evidence of tampering.
    if V.Integrity and V.Integrity.Init then
        V.Integrity.Init()
    end

    -- Adopt records written by an older schema rather than rebuilding them,
    -- which would hand a fresh certification to anyone who edited the version.
    if record.schemaVersion ~= V.SCHEMA_VERSION then
        record.schemaVersion = V.SCHEMA_VERSION
        record.upgradedAt = time and time() or 0
        if V.Integrity and V.Integrity.Seal then V.Integrity.Seal(record) end
    end
    record.addonVersion = V.GetAddonVersion()
    if record.difficulty then
        record.difficulty.currentTier = V.GetCurrentTier()
    end

    M.RepairSealVersionFalsePositive(record)
    M.MaybeGrandfatherExisting(record)
    M.RepairUnexplainedSelfFound(record)
end

-- Undo an integrity failure that Rustcore caused itself.
--
-- Seal version 9 shipped with money figures that were written without
-- re-stamping the seal. Time.lua re-seals every ten seconds as a side effect of
-- accruing tracked time, so the mismatch was usually invisible -- but a session
-- that ended inside one of those windows saved a record whose seal genuinely did
-- not match its contents, and the next login correctly reported exactly that.
-- The record was not tampered with; Rustcore failed to seal it.
--
-- Scoped to that one seal version on purpose. This is not a general amnesty for
-- integrity failures -- a real tamper would simply be repaired away, which would
-- leave the check meaning nothing. Records sealed by any other version are
-- untouched, and after this runs once the record re-seals at the current version
-- and is held to the check normally from then on.
function M.RepairSealVersionFalsePositive(record)
    if not record then return false end
    if not record.tamperReason then return false end

    local chain = record.chain
    if type(chain) ~= "table" then return false end

    -- Scoped to records sealed before the field fingerprint existed, which is
    -- every record written by a build that could produce this false positive and
    -- none written afterwards. Once a record has a fingerprint its seal is
    -- trustworthy, and a failure from that point on is left standing.
    if chain.sealFields ~= nil then return false end

    -- Only the statuses this bug could have caused are lifted, and only where
    -- integrity was the stated reason. Anything Rustcore actually observed --
    -- a violation, a repair, a tracking gap -- was recorded separately and is
    -- left exactly as it stands.
    -- What the track is restored *to* follows the evidence still on the record,
    -- because the status it held before the false failure was not written down.
    -- A difficulty track with a tier had been certified; one without had not yet
    -- earned it. Restoring everything to VERIFIED would hand certification to
    -- characters that were only part-way through qualifying, so those go back to
    -- UNCERTAIN and the normal qualification path decides as it would have.
    local restored = false
    for _, trackName in ipairs({ "difficulty", "selfFound" }) do
        local track = record[trackName]
        if type(track) == "table"
            and track.status == V.STATUS.UNVERIFIED
            and type(track.statusReason) == "string"
            and track.statusReason:sub(1, 10) == "integrity:" then

            local wasCertified
            if trackName == "difficulty" then
                wasCertified = (tonumber(track.highestVerifiedTier) or 0) >= 1
            else
                wasCertified = track.claimed and not track.claimLapsed
            end

            track.status = wasCertified and V.STATUS.VERIFIED or V.STATUS.UNCERTAIN
            track.statusReason = nil
            track.statusAt = nil
            restored = true
        end
    end

    record.tamperReason = nil
    if restored and V.Integrity and V.Integrity.Append then
        V.Integrity.Append("SEAL_REPAIR", { from = chain.sealVersion or 0 })
    end
    if V.Integrity and V.Integrity.Seal then V.Integrity.Seal(record) end

    if restored then
        print("|cffff4444Rustcore:|r A verification checksum error caused by an "
            .. "earlier Rustcore version has been corrected.")
    end
    return restored
end

-- Undo a Self-Found certification that was ended for no reason Rustcore can
-- point at.
--
-- Earlier builds dropped the track straight to UNVERIFIED the moment Self-Found
-- was switched off. UNVERIFIED is terminal -- V.SetStatus only moves downward --
-- so a setting toggle permanently ended a run that had done nothing wrong. That
-- behaviour is gone (the track is suspended now, and comes back), but characters
-- are still carrying its result, and they cannot recover on their own.
--
-- Only the reason for a status is missing here, not the evidence behind it: an
-- UNVERIFIED reached through tampering, a broken chain or an excessive tracking
-- gap always leaves a trace, and every one of those traces is checked below.
-- When none of them is present, nothing was ever actually detected, and the
-- guiding principle is to certify rather than to withhold.
--
-- Repaired to SUSPENDED rather than to VERIFIED, so the ordinary restore path
-- decides what happens next: certified once Self-Found is on again and the
-- character has been watched cleanly, still paused until then.
function M.RepairUnexplainedSelfFound(record)
    if not record then return false end
    local selfFound = record.selfFound
    local difficulty = record.difficulty
    if not selfFound or not difficulty then return false end

    if selfFound.status ~= V.STATUS.UNVERIFIED then return false end
    if not selfFound.claimed then return false end
    if (selfFound.violations or 0) > 0 then return false end

    if type(selfFound.warnings) == "table" then
        for _, count in pairs(selfFound.warnings) do
            if (count or 0) > 0 then return false end
        end
    end

    -- Anything Rustcore genuinely detected would have marked these.
    if record.tamperReason then return false end
    local timeState = record.time or {}
    if timeState.gapBand and timeState.gapBand ~= "OK" then return false end

    -- The difficulty track is the honest summary of whether this character has
    -- ever looked wrong. If that is still certified, nothing was found.
    if not V.IsCertified(difficulty.status) then return false end

    selfFound.status = V.STATUS.SUSPENDED
    selfFound.suspended = true
    selfFound.restoreAtTracked = nil
    record.selfFoundRepairedAt = time and time() or 0

    if V.Integrity and V.Integrity.Append then
        V.Integrity.Append("SF_REPAIR", { from = V.STATUS.UNVERIFIED, to = V.STATUS.SUSPENDED })
    end
    if V.Integrity and V.Integrity.Seal then V.Integrity.Seal(record) end
    return true
end

-- Plan section 4, applied to a record that already exists.
--
-- Legacy detection has to read RustcoreDB before any other module touches it,
-- and it has to find this character's tables under whatever key an earlier
-- session used. Either can miss -- most easily when UnitGUID is unavailable
-- during ADDON_LOADED and the tables were written under a different key -- and
-- when it missed, the character was written down as NEW_CHARACTER and started
-- unverified despite a full history of Rustcore play.
--
-- The plan is unambiguous that this is the wrong outcome: existing Rustcore data
-- is the starting truth, and a grandfathered player must not end up worse off
-- than someone starting fresh today. So the question is asked again on later
-- logins rather than only once.
--
-- Tightly bounded, because this is the one path that raises a certification.
-- It only applies to a record that has never had anything happen to it: no
-- deaths, no violations, no warnings, nothing recorded past its own creation.
-- A record that was degraded by something Rustcore actually observed is never
-- touched, so this cannot launder a failure.
function M.MaybeGrandfatherExisting(record)
    if not record or record.origin ~= "NEW_CHARACTER" then return false end
    if not IsLegacyCharacter() then return false end

    local difficulty = record.difficulty or {}
    local selfFound = record.selfFound or {}

    if (difficulty.deaths or 0) > 0 then return false end
    if (difficulty.repairViolations or 0) > 0 then return false end
    if (selfFound.violations or 0) > 0 then return false end
    if difficulty.permanentCapTier or difficulty.deathFloorTier then return false end
    if difficulty.status == V.STATUS.FAILED or selfFound.status == V.STATUS.FAILED then return false end

    local function HasWarning(track)
        if type(track.warnings) ~= "table" then return false end
        for _, count in pairs(track.warnings) do
            if (count or 0) > 0 then return true end
        end
        return false
    end
    if HasWarning(difficulty) or HasWarning(selfFound) then return false end

    -- A tracking gap is evidence about this record's own history, not about
    -- whether the character predates verification, and section 18 already
    -- decided what it costs. Leave that verdict alone.
    local timeState = record.time or {}
    if timeState.gapBand and timeState.gapBand ~= "OK" then return false end

    record.origin = "LEGACY_MIGRATION"
    record.regrandfatheredAt = time and time() or 0

    difficulty.status = V.STATUS.VERIFIED
    difficulty.highestVerifiedTier = V.GetCurrentTier()
    record.difficulty = difficulty

    -- Self-Found is only granted where the old data shows it was actually being
    -- played; a claim is never invented for a character that never made one.
    if selfFound.claimed then
        selfFound.status = V.STATUS.VERIFIED
        record.selfFound = selfFound
    end

    if V.Integrity and V.Integrity.Append then
        V.Integrity.Append("REGRANDFATHER", {
            tier = difficulty.highestVerifiedTier or 0,
            selfFound = selfFound.claimed and 1 or 0,
        })
    end
    if V.Integrity and V.Integrity.Seal then V.Integrity.Seal(record) end

    print("|cffff4444Rustcore:|r Existing Rustcore history found for this character. Verification restored.")
    return true
end

-- Plan section 3: the record is bound to UnitGUID("player"). That GUID is not
-- reliably available during ADDON_LOADED, so binding is confirmed at
-- PLAYER_LOGIN: adopted if the record never had one, and checked if it did.
-- The record is stored under whatever Rustcore.GetCharacterKey() returned when
-- it was created. Once the GUID is known that key changes, so the record moves
-- with it rather than being left behind for the next session to miss and
-- replace with a fresh, unverified one.
local function Rekey(oldKey, record)
    if not Rustcore or not Rustcore.GetCharacterKey then return end
    local canonical = Rustcore.GetCharacterKey()
    if not canonical or canonical == "" or canonical == oldKey then return end

    local store = V.GetStore()
    if store[canonical] and store[canonical] ~= record then return end
    store[canonical] = record
    if oldKey then store[oldKey] = nil end
end

function M.FinalizeIdentity()
    local key, record = V.FindRecordKey()
    if not record then return end

    local guid = UnitGUID and UnitGUID("player")
    if not guid or guid == "" then return end

    record.identity = record.identity or {}
    if not record.identity.guid then
        record.identity.guid = guid
        record.identity.name = record.identity.name or UnitName("player")
        record.identity.realm = record.identity.realm or (GetRealmName and GetRealmName() or nil)
        Rekey(key, record)
        if V.Integrity and V.Integrity.Seal then V.Integrity.Seal(record) end
        return
    end

    if record.identity.guid ~= guid then
        -- This record belongs to a different character. Verification never
        -- transfers between characters, so nothing here can be certified.
        V.SetStatus("difficulty", V.STATUS.UNVERIFIED, "identity mismatch")
        V.SetStatus("selfFound", V.STATUS.UNVERIFIED, "identity mismatch")
        if V.Integrity and V.Integrity.Seal then V.Integrity.Seal(record) end
    end
end
