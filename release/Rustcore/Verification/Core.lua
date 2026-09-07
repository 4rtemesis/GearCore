-- Rustcore Verification: shared state, statuses and transitions.
--
-- Two independent certification tracks live side by side on every character:
--   difficulty  -- the hardest preset the character can still legitimately claim
--   selfFound   -- whether Self-Found is still certifiable
-- Neither track influences the other.
--
-- Nothing in Phase 1 gates the portrait or the Self-Found buff yet. This file
-- owns the schema and the transition rules so later phases only have to call in.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification

V.SCHEMA_VERSION = 1

V.STATUS = {
    VERIFIED   = "VERIFIED",
    WARNING    = "WARNING",
    -- Not certified at the moment, but nothing is wrong: the certification is
    -- paused and will come back on its own. Distinct from UNVERIFIED, which is
    -- the end of the road, and from UNCERTAIN, which is a start that has not
    -- earned certification yet rather than one that lost it.
    SUSPENDED  = "SUSPENDED",
    UNCERTAIN  = "UNCERTAIN",
    UNVERIFIED = "UNVERIFIED",
    FAILED     = "FAILED",
}

-- Severity ordering. A track may always move to a worse (higher) rank; it may
-- never climb back up on its own, which is what makes FAILED permanent and
-- keeps a settings change from restoring a certification that was lost.
local STATUS_RANK = {
    VERIFIED   = 1,
    WARNING    = 2,
    SUSPENDED  = 3,
    UNCERTAIN  = 4,
    UNVERIFIED = 5,
    FAILED     = 6,
}

-- Statuses a character can still come back from. Everything else is final.
-- The distinction the player actually cares about: "keep playing" versus "this
-- run cannot be certified any more".
local RECOVERABLE = {
    VERIFIED  = true,
    WARNING   = true,
    SUSPENDED = true,
    UNCERTAIN = true,
}

function V.IsRecoverable(status)
    return RECOVERABLE[status or ""] == true
end

-- Difficulty presets, easiest to hardest, mirroring DIFF_LABELS in
-- RustcoreOptions.lua. Higher index means more restrictive.
V.TIER_NAMES = { [1] = "Rusted", [2] = "Broken", [3] = "Shattered", [4] = "Crumbling", [5] = "Dust" }
V.MAX_TIER = 5

-- Level windows for late starts.
V.LATE_START_MAX_LEVEL = 8
V.QUALIFY_LEVEL_SPAN = 2
V.QUALIFY_LEVEL_CAP = 10
-- A floor underneath the level requirement, not a substitute for it: the plan
-- asks for tracked progression rather than wall-clock time, so this only rules
-- out the case where two levels arrive minutes after installing and Rustcore
-- has barely observed the character at all.
V.QUALIFY_MIN_TRACKED = 1800

local function Now()
    return time and time() or 0
end

function V.GetAddonVersion()
    local version
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        version = C_AddOns.GetAddOnMetadata("Rustcore", "Version")
    elseif GetAddOnMetadata then
        version = GetAddOnMetadata("Rustcore", "Version")
    end
    return version or "unknown"
end

-- UnitLevel("player") can still report the old level while PLAYER_LEVEL_UP is
-- being handled, so the level carried by that event is remembered and the
-- higher of the two is used. Keeping the maximum is safe in one direction
-- only: the announced level is never ahead of the real one.
local announcedLevel

function V.NoteAnnouncedLevel(level)
    if type(level) ~= "number" or level < 1 then return end
    if not announcedLevel or level > announcedLevel then announcedLevel = level end
end

function V.GetPlayerLevel()
    local level = UnitLevel and UnitLevel("player")
    if type(level) ~= "number" or level < 1 then level = nil end
    if announcedLevel and (not level or announcedLevel > level) then
        return announcedLevel
    end
    return level
end

-- ── Identity ─────────────────────────────────────────────────────────────────

-- Every record is bound to the character it was earned on.
-- Rustcore.GetCharacterKey() is the player GUID wherever the client exposes
-- one, so the key and the identity block normally agree; the identity block is
-- stored separately anyway because import validation compares against it.
function V.BuildIdentity()
    local _, class = UnitClass("player")
    local _, race = UnitRace("player")
    return {
        guid  = UnitGUID and UnitGUID("player") or nil,
        name  = UnitName("player"),
        realm = GetRealmName and GetRealmName() or nil,
        class = class,
        race  = race,
    }
end

-- True when `identity` describes the character currently logged in. GUID is
-- authoritative; name/realm is only consulted when neither side has a GUID.
function V.IdentityMatchesPlayer(identity)
    if type(identity) ~= "table" then return false end
    local current = V.BuildIdentity()
    if identity.guid and current.guid then
        return identity.guid == current.guid
    end
    if identity.guid or current.guid then
        return false
    end
    return identity.name == current.name and identity.realm == current.realm
end

-- ── Record access ────────────────────────────────────────────────────────────

function V.GetStore()
    RustcoreDB = RustcoreDB or {}
    RustcoreDB.verification = RustcoreDB.verification or {}
    return RustcoreDB.verification
end

-- Rustcore keys its per-character tables by GUID, falling back to name-realm
-- and then to bare name. UnitGUID("player") is not dependable during
-- ADDON_LOADED, so a record may have been written under a different key in an
-- earlier session. Every key this character could plausibly have used is
-- considered, or the record would be orphaned -- and silently replaced by a
-- fresh, unverified one -- the first time the GUID happens to arrive in time.
function V.CandidateKeys()
    local keys, seen = {}, {}
    local function add(key)
        if key and key ~= "" and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end

    if Rustcore and Rustcore.GetCharacterKey then add(Rustcore.GetCharacterKey()) end
    add(UnitGUID and UnitGUID("player") or nil)
    local name = UnitName and UnitName("player") or nil
    local realm = GetPlayerRealmName and GetPlayerRealmName() or nil
    if name and realm and realm ~= "" then add(name .. "-" .. realm) end
    add(name)

    -- Last resort, and the one that actually catches key drift. UnitGUID is not
    -- dependable during ADDON_LOADED, so a session where it answered and one
    -- where it did not will key the same character differently -- and none of
    -- the guesses above can reproduce a GUID the client has not handed over yet.
    -- EnsureProfile stamps characterLabel on every run, so matching on it finds
    -- this character's tables whatever key they were written under.
    if name and realm and realm ~= "" and RustcoreDB and type(RustcoreDB.profiles) == "table" then
        local label = name .. "-" .. realm
        for key, profile in pairs(RustcoreDB.profiles) do
            if type(profile) == "table" and profile.characterLabel == label then
                add(key)
            end
        end
    end

    return keys
end

-- The key this character's record is actually stored under, plus the record.
function V.FindRecordKey()
    local store = V.GetStore()
    for _, key in ipairs(V.CandidateKeys()) do
        if store[key] then return key, store[key] end
    end
    return nil, nil
end

-- The current character's record, or nil when Migration has not created one
-- yet. Callers must tolerate nil: everything before Migration.Run() sees it.
function V.GetRecord()
    local _, record = V.FindRecordKey()
    return record
end

function V.GetTrack(trackName)
    local record = V.GetRecord()
    return record and record[trackName] or nil
end

-- Skeleton for one certification track. Warnings are typed rather than a
-- single counter so unrelated suspicions never combine into a failure.
function V.NewTrack(status)
    return {
        status = status,
        warnings = {},
        startedAtLevel = nil,
        verificationStartPlayed = nil,
        failedReason = nil,
        failedAt = nil,
    }
end

-- ── Difficulty helpers ───────────────────────────────────────────────────────

function V.GetCurrentTier()
    local tier = Rustcore and Rustcore.GetSetting and Rustcore.GetSetting("difficulty") or 1
    if type(tier) ~= "number" then tier = 1 end
    if tier < 1 then tier = 1 end
    if tier > V.MAX_TIER then tier = V.MAX_TIER end
    return tier
end

function V.GetTierName(tier)
    return V.TIER_NAMES[tier] or tostring(tier)
end

-- ── Status transitions ───────────────────────────────────────────────────────

function V.StatusRank(status)
    return STATUS_RANK[status] or 0
end

function V.IsCertified(status)
    return status == V.STATUS.VERIFIED or status == V.STATUS.WARNING
end

local function AppendChain(eventType, payload)
    if V.Integrity and V.Integrity.Append then
        V.Integrity.Append(eventType, payload)
    end
end

-- Move a track to `newStatus`. Degradation only: a request to improve a track
-- is ignored, which is what stops a FAILED or UNVERIFIED certification from
-- being recovered by toggling a setting.
-- Promotion out of UNCERTAIN goes through V.Promote instead.
function V.SetStatus(trackName, newStatus, reason)
    local track = V.GetTrack(trackName)
    if not track then return false end
    if not STATUS_RANK[newStatus] then return false end
    if V.StatusRank(newStatus) <= V.StatusRank(track.status) then
        return false
    end

    local previous = track.status
    track.status = newStatus

    -- Kept for every degradation, not only the terminal one. The Verification
    -- tab has to be able to say *why* a run is not certified, and UNVERIFIED is
    -- the status a player is most likely to be looking at while wondering
    -- exactly that -- until now the reason went into the chain event and
    -- nowhere the player could read it.
    --
    -- Deliberately outside the seal: Integrity.CriticalState already covers the
    -- status itself, and this is a label on a decision that is sealed, not a
    -- decision of its own. Editing it in SavedVariables changes the wording of
    -- a loss, never whether it happened.
    track.statusReason = reason
    track.statusAt = Now()

    if newStatus == V.STATUS.FAILED then
        track.failedReason = reason
        track.failedAt = Now()
    end

    AppendChain("STATUS", {
        track = trackName,
        from = previous,
        to = newStatus,
        reason = reason or "",
    })
    return true
end

-- The one sanctioned upward move: UNCERTAIN -> VERIFIED once a late start has
-- been observed cleanly for long enough. Deliberately refuses to lift any
-- other status so it can never launder a failure.
function V.Promote(trackName, reason)
    local track = V.GetTrack(trackName)
    if not track or track.status ~= V.STATUS.UNCERTAIN then return false end

    track.status = V.STATUS.VERIFIED
    AppendChain("PROMOTE", {
        track = trackName,
        to = V.STATUS.VERIFIED,
        reason = reason or "",
    })
    return true
end

-- The other sanctioned upward move: SUSPENDED -> VERIFIED, once whatever paused
-- the certification is over. Like Promote it refuses every other status, so a
-- run that was genuinely disqualified can never be talked back up.
--
-- The caller decides whether restoring is warranted; this only enforces that
-- SUSPENDED is the one state it may be done from.
function V.Restore(trackName, reason)
    local track = V.GetTrack(trackName)
    if not track or track.status ~= V.STATUS.SUSPENDED then return false end

    track.status = V.STATUS.VERIFIED
    AppendChain("RESTORE", {
        track = trackName,
        to = V.STATUS.VERIFIED,
        reason = reason or "",
    })
    return true
end

-- ── Late-start qualification (plan sections 5 and 6) ─────────────────────────

-- Answers one question: may this track be promoted out of UNCERTAIN right now?
-- It deliberately decides nothing else -- what a promotion means for a track is
-- the owning module's business -- and it returns its reason either way so the
-- caller can put it in the chain event or the Verification tab.
--
-- The level requirement is the primary test, because the plan asks for the
-- check to rest on tracked progression rather than elapsed time. Everything
-- else here is a continuity requirement: Rustcore has to have actually been
-- watching for that progression to mean anything.
function V.EvaluateQualification(trackName)
    local track = V.GetTrack(trackName)
    if not track then return false, "no verification record" end
    if track.status ~= V.STATUS.UNCERTAIN then return false, "not uncertain" end

    local startedAt = track.qualifyFromLevel or track.startedAtLevel
    if type(startedAt) ~= "number" then return false, "start level unknown" end
    if startedAt > V.LATE_START_MAX_LEVEL then
        return false, "started after the early window"
    end

    -- Any recorded suspicion at all blocks the promotion. Refusing to certify
    -- is not an accusation: the character keeps the status it already had, and
    -- the qualification window exists to find a clean stretch, not to forgive
    -- a dirty one.
    if type(track.warnings) == "table" then
        for kind, count in pairs(track.warnings) do
            if (count or 0) > 0 then return false, "warning recorded: " .. tostring(kind) end
        end
    end

    local required = startedAt + V.QUALIFY_LEVEL_SPAN
    if required > V.QUALIFY_LEVEL_CAP then required = V.QUALIFY_LEVEL_CAP end
    local level = V.GetPlayerLevel()
    if not level or level < required then
        return false, string.format("level %d of %d", level or 0, required)
    end

    local record = V.GetRecord()
    local state = record and record.time
    if not state or not state.anchorPlayed then return false, "no playtime anchor" end
    -- Time.lua only ever escalates this band, so a gap found during the window
    -- cannot be waited out.
    if state.gapBand and state.gapBand ~= "OK" then return false, "tracking gap" end
    if (state.trackedSinceAnchor or 0) < V.QUALIFY_MIN_TRACKED then
        return false, "not enough tracked play"
    end

    return true, string.format("level %d after starting at %d", level, startedAt)
end

-- Re-run both tracks. Cheap and idempotent -- every check refuses unless its
-- track is still UNCERTAIN -- so any event that might have moved a character
-- closer can just call this.
function V.CheckQualifications()
    if V.Difficulty and V.Difficulty.CheckQualification then
        V.Difficulty.CheckQualification()
    end
    if V.SelfFound and V.SelfFound.CheckQualification then
        V.SelfFound.CheckQualification()
    end
    -- A suspension waiting out its clean-play requirement is lifted from here
    -- too, so the five-minute /played poll doubles as its retry.
    if V.SelfFound and V.SelfFound.CheckRestore then
        V.SelfFound.CheckRestore()
    end
end

-- Record a typed warning and return the new count for that type, so callers
-- can implement "first occurrence warns, second fails" without unrelated
-- warning types interfering.
function V.AddWarning(trackName, warningType, detail)
    local track = V.GetTrack(trackName)
    if not track then return 0 end

    track.warnings = track.warnings or {}
    local count = (track.warnings[warningType] or 0) + 1
    track.warnings[warningType] = count

    -- A warning never demotes a track that is already worse than WARNING.
    if track.status == V.STATUS.VERIFIED then
        track.status = V.STATUS.WARNING
    end

    AppendChain("WARN", {
        track = trackName,
        kind = warningType,
        count = count,
        detail = detail or "",
    })
    return count
end

function V.GetWarningCount(trackName, warningType)
    local track = V.GetTrack(trackName)
    if not track or not track.warnings then return 0 end
    return track.warnings[warningType] or 0
end

-- Permanently lower the difficulty cap. Used by Phase 2 when a death happens
-- under weaker rules than the character was certified for.
function V.CapDifficultyTier(tier, reason)
    local track = V.GetTrack("difficulty")
    if not track then return false end
    if type(tier) ~= "number" then return false end
    if tier < 1 then tier = 1 end
    if track.highestVerifiedTier and tier >= track.highestVerifiedTier then
        return false
    end

    local previous = track.highestVerifiedTier
    track.highestVerifiedTier = tier
    track.permanentCapTier = tier

    AppendChain("CAP", {
        from = previous or 0,
        to = tier,
        reason = reason or "",
    })
    return true
end

-- Whether the character may display the dragon for `tier`.
-- Phase 1 only answers the question; RustcoreDragon is wired to it in Phase 2.
function V.CanUseDifficultyPortrait(tier)
    local track = V.GetTrack("difficulty")
    if not track then return false end
    if not V.IsCertified(track.status) then return false end
    return (tier or V.GetCurrentTier()) <= (track.highestVerifiedTier or 0)
end

function V.IsSelfFoundCertified()
    local track = V.GetTrack("selfFound")
    return track ~= nil and V.IsCertified(track.status)
end

-- ── Init ─────────────────────────────────────────────────────────────────────

-- Called from Rustcore.lua's ADDON_LOADED handler, after settings are ready.
-- Order matters: Migration creates the record, then the trackers attach to it.
function V.Init()
    if V.initialized then return end
    V.initialized = true

    -- Time first: Migration asks for a fresh /played as soon as it creates a
    -- record, and the TIME_PLAYED_MSG listener has to exist before that reply
    -- can arrive. Migration then runs the integrity check itself, before it
    -- touches an existing record, so tampering cannot be sealed over.
    if V.Time and V.Time.Init then
        V.Time.Init()
    end
    if V.Migration and V.Migration.Run then
        V.Migration.Run()
    end
    if V.Integrity and V.Integrity.Init then
        V.Integrity.Init()
    end
    -- After the record exists and has been integrity-checked, so a tampered
    -- record is already UNVERIFIED before difficulty reads it.
    if V.Difficulty and V.Difficulty.Init then
        V.Difficulty.Init()
    end
    -- Self-Found next: it may claim, promote or drop its own track during Init,
    -- and all of that goes through Core and Integrity, which are up by now.
    if V.SelfFound and V.SelfFound.Init then
        V.SelfFound.Init()
    end
    -- Before the restrictions, which hand the trade window over to it.
    if V.Conjured and V.Conjured.Init then
        V.Conjured.Init()
    end
    -- After SelfFound, because the restrictions report violations through
    -- V.SelfFound.Fail and read the claim it just settled.
    if V.SelfFoundRestrict and V.SelfFoundRestrict.Init then
        V.SelfFoundRestrict.Init()
    end
    -- Mail belongs to the same group: it classifies against NPCMailDB and
    -- reports through the same track.
    if V.Mail and V.Mail.Init then
        V.Mail.Init()
    end
    -- Economy first of the three: it owns the activity context and the
    -- thresholds that Money and Inventory both consult.
    if V.Economy and V.Economy.Init then
        V.Economy.Init()
    end
    if V.Money and V.Money.Init then
        V.Money.Init()
    end
    if V.Inventory and V.Inventory.Init then
        V.Inventory.Init()
    end
    -- Durability last: it compares against the stored snapshot and reports
    -- through V.Difficulty, so both must already exist.
    if V.Durability and V.Durability.Init then
        V.Durability.Init()
    end
    -- Transfer only listens for /played replies; it reads every other module's
    -- state on demand, so it goes up once they all exist.
    if V.Transfer and V.Transfer.Init then
        V.Transfer.Init()
    end

    -- UnitGUID("player") is not dependable during ADDON_LOADED, so the record
    -- confirms its character binding once the player is fully in the world.
    -- Qualification is re-evaluated whenever the character could have moved
    -- closer to it: gaining a level, and arriving in the world. Time.lua adds a
    -- third trigger on every /played reply, which makes its five-minute poll
    -- double as the retry for the tracked-time floor.
    local qualifyFrame = CreateFrame("Frame")
    qualifyFrame:RegisterEvent("PLAYER_LEVEL_UP")
    qualifyFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    qualifyFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "PLAYER_LEVEL_UP" then
            V.NoteAnnouncedLevel(...)
        end
        V.CheckQualifications()
    end)

    local loginFrame = CreateFrame("Frame")
    loginFrame:RegisterEvent("PLAYER_LOGIN")
    loginFrame:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_LOGIN")
        if V.Migration and V.Migration.FinalizeIdentity then
            V.Migration.FinalizeIdentity()
        end
    end)
    if IsLoggedIn and IsLoggedIn() then
        loginFrame:UnregisterEvent("PLAYER_LOGIN")
        if V.Migration and V.Migration.FinalizeIdentity then
            V.Migration.FinalizeIdentity()
        end
    end
end

-- Called from Rustcore.lua's ADDON_LOADED handler *before* any other module
-- touches RustcoreDB, so Migration can tell a returning character's saved data
-- apart from tables the current session is about to create.
function V.CaptureLegacyEvidence()
    if V.Migration and V.Migration.CaptureEvidence then
        V.Migration.CaptureEvidence()
    end
end

-- ── Debug readout ────────────────────────────────────────────────────────────

-- /rcverify prints the current certification state. Read-only: it never
-- changes a status, so it is safe to leave in a release build.
local function FormatDuration(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

SLASH_RCVERIFY1 = "/rcverify"
SlashCmdList["RCVERIFY"] = function()
    local record = V.GetRecord()
    if not record then
        print("|cffff4444Rustcore:|r no verification record for this character yet.")
        return
    end

    local difficulty = record.difficulty or {}
    local selfFound = record.selfFound or {}
    local timeState = record.time or {}

    print("|cffff4444Rustcore verification|r  (" .. tostring(record.origin) .. ")")
    print(string.format("  Difficulty: %s  highest verified: %s  selected: %s",
        tostring(difficulty.status),
        V.GetTierName(difficulty.highestVerifiedTier or 0),
        V.GetTierName(V.GetCurrentTier())))
    print(string.format("  Self-Found: %s  claimed: %s  buff: %s",
        tostring(selfFound.status),
        selfFound.claimed and "yes" or "no",
        V.IsSelfFoundCertified() and "shown" or "hidden"))

    local enforcing = V.SelfFoundRestrict and V.SelfFoundRestrict.IsEnforcing
        and V.SelfFoundRestrict.IsEnforcing()
    local mailOn = V.Mail and V.Mail.IsEnforcing and V.Mail.IsEnforcing()
    print(string.format("    Trade/AH: %s   Mail: %s   violations: %d%s",
        enforcing and "blocked" or "not enforced",
        mailOn and "filtered" or "not enforced",
        selfFound.violations or 0,
        selfFound.lastViolation and ("  (" .. tostring(selfFound.lastViolation) .. ")") or ""))

    local economy = record.economy
    if economy and V.Economy then
        local money = economy.money or {}
        local items = economy.items or {}
        local level = V.GetPlayerLevel() or 1
        print(string.format("    Economy: unexplained %s over %d event(s), item flags %d",
            V.Economy.FormatMoney(money.unexplained or 0),
            money.anomalies or 0, items.anomalies or 0))
        print(string.format("      Gold thresholds at level %d: warn %s  fail %s   failures %s",
            level,
            V.Economy.FormatMoney(V.Economy.GetGoldWarningThreshold(level)),
            V.Economy.FormatMoney(V.Economy.GetGoldFailureThreshold(level)),
            V.Economy.ALLOW_ECONOMY_FAILURE and "enabled" or "|cffffd700warn-only|r"))
    end

    local warnings = {}
    for kind, count in pairs(selfFound.warnings or {}) do
        warnings[#warnings + 1] = string.format("%s=%d", tostring(kind), count or 0)
    end
    for kind, count in pairs(difficulty.warnings or {}) do
        warnings[#warnings + 1] = string.format("%s=%d", tostring(kind), count or 0)
    end
    if #warnings > 0 then
        table.sort(warnings)
        print("    Warnings: " .. table.concat(warnings, "  "))
    end

    local allowed = V.Time and V.Time.GetAllowedGap and V.Time.GetAllowedGap() or 0
    print(string.format("  Played: %s   tracked: %s   untracked: %s (allowed %s)",
        FormatDuration(timeState.lastServerPlayed),
        FormatDuration(timeState.trackedSinceAnchor),
        FormatDuration(timeState.untrackedSeconds),
        FormatDuration(allowed)))

    local chain = record.chain or {}
    local ok, reason = true, nil
    if V.Integrity and V.Integrity.Check then ok, reason = V.Integrity.Check(record) end
    print(string.format("  Chain: %d events, head %s, integrity %s",
        chain.events and #chain.events or 0,
        tostring(chain.head),
        ok and "|cff44ff44ok|r" or ("|cffff4444" .. tostring(reason) .. "|r")))
end
