-- Rustcore Verification: Self-Found certification (plan sections 6 and 19-28).
--
-- Phase 4 scope is only the start of the claim: when it begins, what baseline
-- it begins from, and whether a late start can still earn verification. The
-- direct restrictions -- trade, auction house, mail -- land in Phase 5 and hang
-- off this same track.
--
-- The track exists on every character but only carries a claim once Self-Found
-- is actually switched on. Until then it sits unclaimed at UNCERTAIN, which is
-- the one status Core will ever promote; starting it at UNVERIFIED would
-- permanently lock out a player who enables Self-Found at level 1 tomorrow.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.SelfFound = V.SelfFound or {}
local SF = V.SelfFound

local function Setting(key)
    if Rustcore and Rustcore.GetSetting then return Rustcore.GetSetting(key) end
    return nil
end

local function Append(eventType, payload)
    if V.Integrity and V.Integrity.Append then V.Integrity.Append(eventType, payload) end
end

local function Seal()
    if V.Integrity and V.Integrity.Seal then V.Integrity.Seal() end
end

local function RefreshBuff()
    if RustcoreSelfFoundBuff and RustcoreSelfFoundBuff.Refresh then
        RustcoreSelfFoundBuff.Refresh()
    end
end

-- Baseline (plan section 6) --------------------------------------------------
--
-- "Existing items and gold at activation become the baseline unless they are
-- sufficiently abnormal to trigger suspicion." Phase 4 records that baseline.
-- Judging it against the level-scaled thresholds in sections 23-27 is Phase 7's
-- job, and it needs this snapshot to have been taken at the right moment.

-- Slots 1-19: the whole paper doll in Classic, ammo and tabard included.
local EQUIPMENT_SLOTS = 19

-- Mirrors CaptureBagSnapshot in Rustcore.lua: C_Container is the current API
-- and the loose globals are the pre-10.0 spelling still present on older
-- clients, so both are tried rather than assumed.
local function BagItemCounts()
    local counts, total = {}, 0
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
            if id then
                counts[id] = (counts[id] or 0) + (count or 1)
                total = total + (count or 1)
            end
        end
    end
    return counts, total
end

function SF.CaptureBaseline()
    local equipped = {}
    for slot = 1, EQUIPMENT_SLOTS do
        local id = GetInventoryItemID and GetInventoryItemID("player", slot)
        if id then equipped[slot] = id end
    end

    -- Only the total, never the per-item table.
    --
    -- The full bag contents used to be written here, and nothing ever read them
    -- back: every inventory comparison Rustcore makes is between two snapshots
    -- taken in the same session, held in Inventory.lua as a module local. So the
    -- table was pure weight in SavedVariables, growing with the player's bags,
    -- for evidence that was never consulted. Durability snapshots are what carry
    -- item evidence across a logout, and those are far smaller and far more
    -- meaningful.
    local _, bagTotal = BagItemCounts()
    return {
        takenAt  = time and time() or 0,
        level    = V.GetPlayerLevel(),
        money    = GetMoney and GetMoney() or 0,
        played   = V.Time and V.Time.GetLastServerPlayed and V.Time.GetLastServerPlayed() or 0,
        bagCount = bagTotal,
        equipped = equipped,
    }
end

-- Claiming Self-Found --------------------------------------------------------

-- Plan section 6: Self-Found ideally begins at level 1, and enabling it at
-- level 8 or below is a late start that can still qualify. Later than that,
-- Rustcore never watched the early game and has no way to tell where the
-- character's gear and gold came from.
local function StatusForClaimLevel(level)
    if not level or level <= 1 then return V.STATUS.VERIFIED end
    if level <= V.LATE_START_MAX_LEVEL then return V.STATUS.UNCERTAIN end
    return V.STATUS.UNVERIFIED
end

function SF.Claim()
    local record = V.GetRecord()
    local track = record and record.selfFound
    if not track or track.claimed then return false end

    local level = V.GetPlayerLevel()
    track.claimed = true
    track.claimedAtLevel = level
    -- The qualification window is measured from the claim, not from when the
    -- record was created: enabling Self-Found at level 30 on a character
    -- Rustcore has watched since level 1 is still a level-30 start.
    track.qualifyFromLevel = level
    track.claimedAt = time and time() or 0
    record.selfFoundBaseline = SF.CaptureBaseline()

    Append("SF_CLAIM", {
        level = level or 0,
        money = record.selfFoundBaseline.money or 0,
        items = record.selfFoundBaseline.bagCount or 0,
    })

    local wanted = StatusForClaimLevel(level)
    if wanted == V.STATUS.VERIFIED then
        V.Promote("selfFound", "Self-Found from level 1")
    elseif wanted == V.STATUS.UNVERIFIED then
        V.SetStatus("selfFound", V.STATUS.UNVERIFIED,
            "Self-Found started at level " .. tostring(level or "?"))
    end
    -- A late start inside the window needs no transition at all: UNCERTAIN is
    -- where an unclaimed track already sits. It simply starts qualifying.

    Seal()
    RefreshBuff()
    return true
end

-- Called from Rustcore.SetSetting the moment the option is toggled, so the
-- baseline is taken then rather than at the next login.
function SF.OnSettingChanged(enabled)
    local track = V.GetTrack("selfFound")
    if not track then return end

    if enabled then
        if not track.claimed then
            SF.Claim()
            return
        end
        -- Re-enabling never restores anything. If Rustcore saw the option go
        -- off, or saw it already off at a login, that gap is unwatched time in
        -- which nothing stopped the character trading, so the claim cannot be
        -- vouched for any more.
        Append("SF_ENABLE", { level = V.GetPlayerLevel() or 0 })
        -- A suspension Rustcore watched all the way through costs nothing on its
        -- own; if something had arrived during it, SF.Fail would already have
        -- taken the certification and V.SetStatus would refuse to give it back.
        track.suspended = nil
        track.claimLapsed = nil
        SF.CheckRestore()
        Seal()
        RefreshBuff()
        return
    end

    if not track.claimed then return end

    -- Switching Self-Found off suspends the claim rather than ending it.
    --
    -- It used to drop straight to UNVERIFIED, which V.SetStatus can never undo,
    -- so toggling the option off and immediately back on destroyed the
    -- certification permanently. That punished a misclick as harshly as a
    -- violation, which is exactly what section 51 says not to do.
    --
    -- The reasoning behind the old behaviour was that nothing is enforced while
    -- the option is off, so the gap cannot be vouched for. That is true of
    -- enforcement but not of observation: Rustcore is still loaded and still
    -- watching trades, mail and the economy. Detection therefore follows the
    -- claim rather than the option now, and anything that actually arrives
    -- during a suspension is caught and costs the certification -- see SF.Fail,
    -- which records it as UNVERIFIED rather than FAILED, because a player who
    -- switched the mode off has opted out rather than cheated.
    --
    -- The buff disappears meanwhile regardless: GetSelfFoundIconState only
    -- reports "verified" while the option is actually on.
    track.disabledAt = time and time() or 0
    track.suspended = true
    -- Watched the whole way through, so there is nothing to make up: switching
    -- it back on restores the certification immediately.
    track.restoreAtTracked = nil
    Append("SF_DISABLE", { level = V.GetPlayerLevel() or 0 })
    V.SetStatus("selfFound", V.STATUS.SUSPENDED, "Self-Found switched off")
    Seal()
    RefreshBuff()
end

-- True while the claim exists but the player has the option switched off in
-- this session. Distinct from claimLapsed, which is the harsher cross-session
-- case: there Rustcore was not running and genuinely saw nothing.
function SF.IsSuspended()
    local track = V.GetTrack("selfFound")
    if not track or not track.claimed then return false end
    if track.suspended then return true end
    return not Setting("selfFound")
end

-- Violation (plan sections 19, 43 and 47) ------------------------------------

-- Permanent loss of the Self-Found certification. Reserved for a violation
-- Rustcore actually observed -- an item or gold arriving from a prohibited
-- source -- rather than for evidence that merely looks wrong; section 47 sends
-- circumstantial findings to V.AddWarning instead.
--
-- Section 43: there is no reset. V.SetStatus only ever moves a track to a worse
-- status, so a later toggle cannot lift this, and the chain event survives in
-- the rolling window as the record of why.
function SF.Fail(reason, detail)
    local track = V.GetTrack("selfFound")
    if not track then return false end
    if track.status == V.STATUS.FAILED then return false end

    track.violations = (track.violations or 0) + 1
    track.lastViolation = reason

    Append("SF_VIOLATION", {
        reason = reason or "",
        detail = detail or "",
        level  = V.GetPlayerLevel() or 0,
        count  = track.violations,
        while_ = SF.IsSuspended() and "suspended" or "active",
    })

    -- A player who switched Self-Found off has opted out of the mode, not broken
    -- a rule they were claiming to follow. Section 47 separates those: the first
    -- is missing standing, the second is a violation. Both are permanent, since
    -- V.SetStatus only ever moves a track downward.
    local outcome = SF.IsSuspended() and V.STATUS.UNVERIFIED or V.STATUS.FAILED
    V.SetStatus("selfFound", outcome, reason or "prohibited Self-Found acquisition")
    Seal()
    RefreshBuff()

    -- Section 28: the wording reports a lost certification, never an accusation.
    print("|cffff4444Rustcore:|r Self-Found verification lost: " .. tostring(reason or "prohibited acquisition") .. ".")
    return true
end

-- Restoring a suspension --------------------------------------------------------

-- How much clean tracked play is required before a suspension Rustcore did not
-- watch can be lifted. Only applies to the cross-session case; a suspension that
-- happened with the addon running is restored the moment Self-Found comes back
-- on, because there is nothing Rustcore failed to see.
SF.RESTORE_TRACKED_SECONDS = 1800

-- Whether the certification may come back, and if not, what is still owed.
-- Returns ok, reason, secondsRemaining.
--
-- The governing idea, and the reason this is deliberately generous: a suspension
-- is not evidence of anything. The player turned a setting off. If Rustcore has
-- not actually caught anything -- no violation, no anomaly, no tampering, and a
-- difficulty track it still trusts -- then refusing to certify punishes them for
-- a setting toggle, and the whole plan leans the other way when it is unsure.
function SF.EvaluateRestore()
    local track = V.GetTrack("selfFound")
    if not track then return false, "no verification record" end
    if track.status ~= V.STATUS.SUSPENDED then return false, "not suspended" end
    if not track.claimed then return false, "no Self-Found claim" end
    if not Setting("selfFound") then return false, "Self-Found is switched off" end

    if (track.violations or 0) > 0 then
        return false, "a Self-Found violation was recorded"
    end
    if type(track.warnings) == "table" then
        for kind, count in pairs(track.warnings) do
            if (count or 0) > 0 then
                return false, "an unexplained change was recorded: " .. tostring(kind)
            end
        end
    end

    -- The difficulty track is the proxy for "has Rustcore seen anything wrong
    -- with this character at all". Tampering, a broken integrity chain and an
    -- excessive tracking gap all land on both tracks, so a difficulty track that
    -- is still certified means none of them happened.
    local difficulty = V.GetTrack("difficulty")
    if difficulty and not V.IsCertified(difficulty.status) then
        return false, "difficulty certification is not currently valid"
    end

    local required = track.restoreAtTracked
    if type(required) == "number" then
        local record = V.GetRecord()
        local tracked = record and record.time and record.time.trackedSinceAnchor or 0
        if tracked < required then
            return false, "more clean play needed", required - tracked
        end
    end

    return true, "clean play since Self-Found resumed"
end

-- Lift the suspension when it is due. Cheap and idempotent: it refuses unless
-- the track is still SUSPENDED, so anything that might have moved the character
-- closer can simply call it.
function SF.CheckRestore()
    local ok, reason = SF.EvaluateRestore()
    if not ok then return false end
    if not V.Restore("selfFound", reason) then return false end

    local track = V.GetTrack("selfFound")
    if track then track.restoreAtTracked = nil end

    Seal()
    RefreshBuff()
    print("|cffff4444Rustcore:|r Self-Found verification restored.")
    return true
end

-- Qualification (plan section 6) ---------------------------------------------

-- UNCERTAIN -> VERIFIED once a late start has been watched cleanly for about
-- two levels. Refuses unless Self-Found is actually on right now, so a claim
-- that is currently switched off can never mature into a certification while
-- nobody is enforcing it.
function SF.CheckQualification()
    local track = V.GetTrack("selfFound")
    if not track or not track.claimed or track.claimLapsed then return false end
    if not Setting("selfFound") then return false end

    local ok, reason = V.EvaluateQualification("selfFound")
    if not ok then return false end
    if not V.Promote("selfFound", reason) then return false end

    Seal()
    RefreshBuff()
    return true
end

function SF.Init()
    if SF.initialized then return end
    SF.initialized = true

    local track = V.GetTrack("selfFound")
    if not track then return end

    local enabled = Setting("selfFound") and true or false

    if enabled and not track.claimed then
        -- Switched on in a session Rustcore was not watching, or a record that
        -- predates claim tracking. Either way the claim starts now, at the
        -- level the character is actually at.
        SF.Claim()
        return
    end

    if track.claimed then
        -- Records written before this phase have no qualifyFromLevel; the level
        -- the record was created at is the best available answer, and it is
        -- exact whenever Self-Found was already on at creation.
        if track.qualifyFromLevel == nil then
            track.qualifyFromLevel = track.claimedAtLevel or track.startedAtLevel
        end

        -- Migration marks the claim without taking a baseline, so the first
        -- login after a claim is where one gets captured. When the claim was
        -- made as the record was created that is still the claim moment; on an
        -- older record it is not, and Phase 7 needs to know the difference
        -- before it reads anything into the numbers.
        local record = V.GetRecord()
        if record and not record.selfFoundBaseline then
            record.selfFoundBaseline = SF.CaptureBaseline()
            if track.claimedAt == nil or track.claimedAt ~= record.createdAt then
                record.selfFoundBaseline.backfilled = true
            end
        end

        if not enabled then
            -- Off at login with a claim on file. Rustcore did not watch whatever
            -- happened while it was off, so the certification is paused -- but
            -- paused, not ended: the player switched a setting, which is not
            -- evidence of anything.
            --
            -- Because that stretch was unwatched, this one asks for a spell of
            -- clean play once Self-Found comes back on, rather than restoring
            -- the instant the box is ticked.
            track.claimLapsed = true
            track.suspended = true
            if not track.restoreAtTracked then
                local record = V.GetRecord()
                local tracked = record and record.time and record.time.trackedSinceAnchor or 0
                track.restoreAtTracked = tracked + SF.RESTORE_TRACKED_SECONDS
            end
            V.SetStatus("selfFound", V.STATUS.SUSPENDED, "Self-Found was switched off")
            Seal()
            RefreshBuff()
            return
        end

        -- Enabled at login. A suspension carried over from a previous session is
        -- reconsidered here rather than only when the option is toggled.
        if track.status == V.STATUS.SUSPENDED then
            track.suspended = nil
            track.claimLapsed = nil
            SF.CheckRestore()
        end

        SF.CheckQualification()
    end
end
