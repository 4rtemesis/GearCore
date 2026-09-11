-- Rustcore Verification: playtime continuity (plan sections 16-18).
--
-- The server's /played is the ground truth for how long a character has been
-- in the world. Rustcore accrues its own tracked time while loaded, and the
-- difference between the two is time the character was played without Rustcore
-- watching.
--
-- Reconciliation is cumulative from a single anchor rather than per-interval:
--   untracked = (serverPlayed - anchorPlayed) - trackedSinceAnchor
-- Per-interval deltas would report a false gap at every session boundary,
-- because the seconds between the last accrual tick and the actual disconnect
-- are counted by the server but not by us. Measuring against one fixed anchor
-- lets that per-session drift stay small instead of accumulating as violations.
--
-- The anchor is set the first time a record sees a /played reply, so everything
-- a character did before verification existed is grandfathered (plan section 4).

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.Time = V.Time or {}
local T = V.Time

local max, floor = math.max, math.floor

-- Plan section 16: poll every five minutes.
T.POLL_INTERVAL = 300
-- How often tracked time is accrued. Small enough that a crash loses very
-- little, large enough to be free.
T.ACCRUE_INTERVAL = 10
-- How much of a character's life Rustcore is allowed to have missed, as a share
-- of total /played. Proportional on purpose and with no absolute ceiling: an
-- hour unwatched means something very different on a 20-hour character than on
-- a 400-hour one, and a fixed cap would punish exactly the long-lived
-- characters who have the most history to show for themselves.
--
-- The share tightens with level, because both of the things that make a gap
-- forgivable fade as a character grows. A level 8 character has a couple of
-- hours on the clock, so one crashed session is a large fraction of its entire
-- life -- and it also has nothing worth cheating for. A level 50 character has
-- hundreds of hours behind it and a certification that means something, and the
-- same lost session is noise against the first and worth guarding for the
-- second. Holding both to one percentage means the early character is the only
-- one that can realistically fail it, which is backwards.
--
--   level 1-5   50% of the run may be unobserved
--   level 10    35%
--   level 20    20%
--   level 30    12%
--   level 40     8%
--   level 50+    5%
--
-- Anchors, not brackets. The share slides between them one level at a time, so
-- no single ding costs meaningful headroom. Read as brackets the same table
-- would halve the allowance on a level-up: a gap sitting comfortably inside
-- tolerance at 20 would be outside it at 21, on a character that had done
-- nothing in between but play. Tightening by a percent or two per level costs
-- the same headroom over the same span without ever making levelling the thing
-- that decided it.
T.TOLERANCE_ANCHORS = {
    {  5, 0.50 },
    { 10, 0.35 },
    { 20, 0.20 },
    { 30, 0.12 },
    { 40, 0.08 },
    { 50, 0.05 },
}

-- What a character past the last anchor is held to -- and what an unknown level
-- is held to as well. Leniency is something a record earns by demonstrating how
-- young it is, so a level Rustcore cannot read gets the strict figure. Every
-- consequence downstream is an absence-of-evidence verdict that watched play
-- undoes, so a missing level costs headroom and never anything permanent.
T.TOLERANCE_FLOOR = 0.05

-- The four zones, as multiples of the allowance for the current level.
--
--   up to 80%    Verified. Nothing is recorded.
--   80%..100%    Verified, with a note. The certification stands.
--   100%..200%   Uncertain. Not certified at this moment, and explicitly earned
--                back by playing on with Rustcore running.
--   over 200%    Not verified. Still an absence of evidence rather than a
--                violation, and still recoverable -- it simply takes
--                proportionally more watched play to get back.
--
-- Never FAILED at any size. Not having been watched is not a rule violation,
-- and no quantity of it turns into one.
T.WARN_SHARE = 0.80
T.UNVERIFIED_MULTIPLE = 2
-- A floor under the allowance, so a brand new character is not held to a
-- percentage of almost nothing: five minutes is about what one crash or one Lua
-- error costs. A floor and not a grant -- it raises the allowance for a
-- character too young to have earned a meaningful one, and does nothing at all
-- once the percentage overtakes it, which happens within the first hour.
T.GAP_MINIMUM = 300
-- Below this, a measured gap is not recorded at all. Even measuring against one
-- fixed anchor leaves a residue at every session boundary: the server counts the
-- seconds between our last accrual tick and the actual disconnect, and a loading
-- screen or a Lua error on logout adds a few more. That residue is an artefact of
-- how the two clocks are read, not play that happened unwatched, and a minute of
-- it is far below anything the tolerance would act on. Recording it only ever
-- made the tracking bar sit permanently short of full for no reason a player
-- could do anything about.
T.GAP_IGNORE = 60

local pendingSilentRequest = false
local originalDisplayTimePlayed
local accrueTicker, pollTicker
local eventFrame

local function GetTimeState()
    local record = V.GetRecord()
    if not record then return nil end
    record.time = record.time or {}
    local state = record.time
    state.anchorPlayed       = state.anchorPlayed       or nil
    state.trackedSinceAnchor = state.trackedSinceAnchor or 0
    state.untrackedSeconds   = state.untrackedSeconds   or 0
    return state
end

-- Time accrued since this login. Deliberately a module local rather than a
-- field on the record: "this session" is not a thing that should survive into
-- SavedVariables, and Phase 8 relies on it being the real session total when it
-- decides how much locally tracked play an import may keep (plan section 40).
local sessionTracked = 0

function T.GetSessionTracked()
    return sessionTracked
end

function T.GetLastServerPlayed()
    local record = V.GetRecord()
    return record and record.time and record.time.lastServerPlayed or 0
end

function T.GetUntrackedSeconds()
    local record = V.GetRecord()
    return record and record.time and record.time.untrackedSeconds or 0
end

-- The share a level is entitled to, interpolated between the anchors above so
-- that no single level costs more headroom than its neighbours.
function T.ToleranceForLevel(level)
    if type(level) ~= "number" then return T.TOLERANCE_FLOOR end
    local anchors = T.TOLERANCE_ANCHORS
    local prevLevel, prevShare
    for i = 1, #anchors do
        local atLevel, share = anchors[i][1], anchors[i][2]
        if level <= atLevel then
            -- Before the first anchor there is nothing to slide from, so the
            -- opening allowance is flat across those levels.
            if not prevLevel or atLevel <= prevLevel then return share end
            return prevShare + (share - prevShare)
                * ((level - prevLevel) / (atLevel - prevLevel))
        end
        prevLevel, prevShare = atLevel, share
    end
    return T.TOLERANCE_FLOOR
end

-- The share in force right now.
--
-- Always the *current* level's share, never the one that applied when a gap
-- happened. The question this module answers is "can this run be vouched for
-- today", and today is the only tense it has: a gap recorded at level 12 and
-- never added to is measured against level 12's allowance while the character
-- is 12, and against level 40's once it gets there. That is also what makes
-- playing on work, because the played total in the denominator grows a great
-- deal faster than the share tightens.
function T.GetTolerance(level)
    if level == nil and V.GetPlayerLevel then level = V.GetPlayerLevel() end
    return T.ToleranceForLevel(level)
end

-- Plan section 17. The unobserved time this character is allowed, in seconds.
function T.GetAllowedGap(totalPlayed, level)
    totalPlayed = totalPlayed or T.GetLastServerPlayed()
    return max(T.GAP_MINIMUM, (totalPlayed or 0) * T.GetTolerance(level))
end

-- ── The derived verdict ──────────────────────────────────────────────────────
--
-- Everything below is computed on demand from two sealed numbers -- the missing
-- seconds and the server's /played total -- and none of what it concludes is
-- written down anywhere. That is deliberate, and it is the whole of the design.
-- A stored verdict is by construction a verdict that cannot improve, and this
-- one has to be able to, because the thing it measures genuinely does get
-- better when the player plays.
--
-- Recovery is not a loophole. The missing seconds never fall; what rises is the
-- total they are a share of, and all of that rise has to be watched. Halving
-- the missing share means doubling the character's entire played history;
-- coming back from 20% missing to 5% means playing four times every hour the
-- character has ever had. Nobody grinds their way out of a gap they created on
-- purpose. Everybody whose client crashed once simply carries on and stops
-- hearing about it, which is the entire population this rule is really about.

local GAP_REASON = "playtime not observed: "

local function FormatShort(seconds)
    seconds = floor(max(0, tonumber(seconds) or 0))
    local hours = floor(seconds / 3600)
    local minutes = floor((seconds % 3600) / 60)
    if hours > 0 then return ("%dh %02dm"):format(hours, minutes) end
    return ("%dm"):format(minutes)
end

-- Missing time in seconds, with the session-boundary deadband applied.
function T.GetMissingSeconds()
    local missing = T.GetUntrackedSeconds() or 0
    if missing < T.GAP_IGNORE then return 0 end
    return missing
end

-- Missing time as a share of the whole run, derived fresh on every call. Nil
-- when there is no played total to divide by, which is every moment before the
-- first /played reply lands.
function T.GetMissingPercent()
    local played = T.GetLastServerPlayed()
    if not played or played <= 0 then return nil end
    return T.GetMissingSeconds() / played
end

-- The status that playtime coverage alone gives this run, and the reason for
-- it. This is the function registered with V.RegisterComponent, so it is one of
-- the inputs V.Compose takes the worst of -- it can hold a run back, and it can
-- stop holding one back, but it can never lift anything else that is wrong.
--
-- The same answer serves both tracks on purpose. Time Rustcore did not see is
-- missing from the difficulty run and from the Self-Found run equally; there is
-- only one clock.
--
-- UNVERIFIED at the far end and never FAILED. A run this thinly covered cannot
-- be vouched for, but nothing was detected either, and the distance between
-- those two is the distance between a pause and an accusation.
function T.ComponentStatus(level)
    local record = V.GetRecord()
    local state = record and record.time
    -- Nothing measured yet. The anchor is set by the first /played reply and
    -- everything before it is grandfathered (plan section 4).
    if not state or not state.anchorPlayed then return nil end

    local missing = T.GetMissingSeconds()
    if missing <= 0 then return V.STATUS.VERIFIED end

    local allowed = T.GetAllowedGap(state.lastServerPlayed, level)
    if missing <= allowed * T.WARN_SHARE then return V.STATUS.VERIFIED end

    -- Worded as time not observed rather than as an accusation: the
    -- overwhelming cause is Rustcore having been switched off, or a client that
    -- crashed with the character still logged in.
    local detail = GAP_REASON .. ("%s unobserved of %s allowed"):format(
        FormatShort(missing), FormatShort(allowed))

    if missing <= allowed then return V.STATUS.WARNING, detail end
    if missing <= allowed * T.UNVERIFIED_MULTIPLE then
        return V.STATUS.UNCERTAIN, detail
    end
    return V.STATUS.UNVERIFIED, detail
end

-- How much further watched play brings the missing time back inside the
-- allowance, in seconds. Zero when there is nothing to make up.
--
-- The allowance is a share of the played total and watched play raises that
-- total without touching the gap, so the answer is just the played total at
-- which the share finally covers the gap, less the played total already there:
--
--   required = missing / share - played
--
-- Recomputed on every call rather than pinned at the moment of the verdict, so
-- it stays true across a level-up instead of being a promise made under a rule
-- that has since changed. Levelling does move it, but the movement is small and
-- the played term dominates it in every direction that matters.
function T.GetRequiredTracked(level)
    local missing = T.GetMissingSeconds()
    if missing <= 0 then return 0 end

    local played = T.GetLastServerPlayed() or 0
    if missing <= T.GetAllowedGap(played, level) then return 0 end

    local share = T.GetTolerance(level)
    if not share or share <= 0 then return nil end

    local required = (missing / share) - played
    if required <= 0 then return 0 end
    return required
end

-- ── Requesting /played ───────────────────────────────────────────────────────

-- RequestTimePlayed always prints the result to chat, and the printing goes
-- through the global ChatFrame_DisplayTimePlayed rather than through the chat
-- message pipeline -- ChatFrame_AddMessageEventFilter cannot intercept
-- TIME_PLAYED_MSG. The only way to keep our own polling silent is to replace
-- that global and forward to the original when the request was not ours.
-- hooksecurefunc is not usable here because it cannot suppress the original.
--
-- Arguments are forwarded verbatim: Classic and BCC call this as
-- (totalTime, levelTime) while retail passes the chat frame first.
-- Catch-all: filter the chat frames themselves.
--
-- Replacing ChatFrame_DisplayTimePlayed below is the tidy fix, but it only works
-- on a client that still routes the reply through that function, and it loses to
-- any addon that replaces the same global after us. Whatever prints the two
-- lines has to reach a chat frame's AddMessage to do it, so filtering there
-- catches the reply no matter which path produced it.
--
-- Matched by content against Blizzard's own localised format strings, so the
-- filter drops exactly the two /played lines and nothing else, in any locale.
local playedPatterns

local function BuildPlayedPatterns()
    playedPatterns = {}
    for _, name in ipairs({ "TIME_PLAYED_TOTAL", "TIME_PLAYED_LEVEL" }) do
        local fmt = _G[name]
        if type(fmt) == "string" and fmt ~= "" then
            -- Escape the literal parts, turn the placeholder into a wildcard.
            local head = fmt:match("^(.-)%%s") or fmt
            head = head:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
            if head ~= "" then playedPatterns[#playedPatterns + 1] = "^" .. head end
        end
    end
end

local function IsPlayedLine(message)
    if type(message) ~= "string" then return false end
    if not playedPatterns then BuildPlayedPatterns() end
    for _, pattern in ipairs(playedPatterns) do
        if message:find(pattern) then return true end
    end
    return false
end

local function InstallAddMessageFilter()
    local count = NUM_CHAT_WINDOWS or 10
    for index = 1, count do
        local frame = _G["ChatFrame" .. index]
        if frame and frame.AddMessage and not frame.rustcorePlayedFilter then
            frame.rustcorePlayedFilter = true
            local original = frame.AddMessage
            frame.AddMessage = function(self, message, ...)
                if pendingSilentRequest and IsPlayedLine(message) then return end
                return original(self, message, ...)
            end
        end
    end
end

local function InstallChatSuppression()
    InstallAddMessageFilter()
    if originalDisplayTimePlayed then return end
    if type(ChatFrame_DisplayTimePlayed) ~= "function" then return end

    originalDisplayTimePlayed = ChatFrame_DisplayTimePlayed
    ChatFrame_DisplayTimePlayed = function(...)
        -- Deliberately does not clear the flag. ChatFrame_OnEvent runs this once
        -- per chat frame registered for TIME_PLAYED_MSG, so clearing on the
        -- first call let every additional chat window print the reply anyway --
        -- which is what the spam was. The flag is cleared one frame later
        -- instead, by the handler below, once the whole dispatch is done.
        if pendingSilentRequest then return end
        return originalDisplayTimePlayed(...)
    end
end

-- Re-arm after the current event dispatch has finished. Every chat frame has
-- had its turn by then, and a /played the player types themselves afterwards
-- prints normally.
local function ClearSilentRequestSoon()
    if not pendingSilentRequest then return end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function() pendingSilentRequest = false end)
    else
        pendingSilentRequest = false
    end
end

-- Ask the server for /played without echoing it to chat.
-- Safe to call from anywhere; later phases call this around exports, imports
-- and major verification transitions (plan section 16).
function T.Request()
    if type(RequestTimePlayed) ~= "function" then return end
    InstallChatSuppression()
    pendingSilentRequest = true
    RequestTimePlayed()
end

-- ── Tracked time accrual ─────────────────────────────────────────────────────

local lastAccrual

-- Accrual is driven by elapsed GetTime() rather than by counting ticks, so a
-- loading screen or a frozen frame still counts as tracked time. That matches
-- the server, which counts it in /played too.
local function Accrue()
    local state = GetTimeState()
    if not state then return end

    local now = GetTime()
    if not lastAccrual then
        lastAccrual = now
        return
    end

    local elapsed = now - lastAccrual
    lastAccrual = now
    if elapsed <= 0 then return end

    state.trackedSinceAnchor = (state.trackedSinceAnchor or 0) + elapsed
    sessionTracked = sessionTracked + elapsed
    state.lastAccruedAt = time and time() or nil

    -- The seal covers trackedSinceAnchor, so it has to be re-stamped or the
    -- next login would read a record that fails its own integrity check.
    if V.Integrity and V.Integrity.Seal then
        V.Integrity.Seal()
    end
end

-- ── Reconciliation ───────────────────────────────────────────────────────────

local TRACKS = { "difficulty", "selfFound" }

-- Whether anything Rustcore actually caught stands against `trackName`.
--
-- An unwatched stretch is an absence of evidence; a violation is the presence
-- of it, and the two do not cancel out. Used by the migration that hands old
-- gap verdicts back to the component below: a record that was condemned by a
-- gap *and* by something real must keep the real half.
--
-- Scoped to the one track, plus the record-wide integrity signal. A Self-Found
-- trade is evidence about Self-Found and says nothing about whether the
-- difficulty run was played honestly, so reading both tracks meant a single
-- trade permanently blocked a recovery the difficulty track had every right to.
--
-- The gap no longer raises warnings of its own, so there is no longer a kind to
-- exclude here; untrackedPlay is only still named because records written by
-- older builds are carrying the counts those builds recorded, and a note about
-- the gap must not be read as evidence against the gap.
local function NothingElseRecorded(record, trackName)
    if record and record.tamperReason then
        return false, "record integrity is in question"
    end
    local track = V.GetTrack(trackName)
    if track then
        if (track.violations or 0) > 0 then
            return false, "a violation was recorded"
        end
        if type(track.warnings) == "table" then
            for kind, count in pairs(track.warnings) do
                if kind ~= "untrackedPlay" and (count or 0) > 0 then
                    return false, "an unexplained change was recorded: " .. tostring(kind)
                end
            end
        end
    end
    return true
end

T.NothingElseRecorded = NothingElseRecorded

-- Fields written by the build that stored its gap verdict instead of deriving
-- it. Nothing reads them any more, and leaving them on the record would leave
-- a stale verdict sitting next to a live one for anyone inspecting
-- SavedVariables. Migration.ReleaseLegacyGapVerdict deals with the statuses
-- those fields caused; this only clears the bookkeeping behind them.
local function ClearLegacyGapState(state)
    if not state then return end
    state.gapBand = nil
    state.gapGrace = nil
    state.gapRatio = nil
    state.gapFloor = nil
    state.gapSuspended = nil
end

local function Reconcile(totalPlayed, levelPlayed)
    local state = GetTimeState()
    if not state then return end

    state.lastServerPlayed = totalPlayed
    state.lastLevelPlayed = levelPlayed
    state.lastPlayedCheck = time and time() or nil

    if not state.anchorPlayed then
        -- First reply for this record. Everything before this instant is
        -- accepted as-is, which is what grandfathers legacy characters.
        state.anchorPlayed = totalPlayed
        state.trackedSinceAnchor = 0
        state.untrackedSeconds = 0
        if V.Integrity and V.Integrity.Append then
            V.Integrity.Append("TIME_ANCHOR", { played = floor(totalPlayed) })
        end
        return
    end

    local serverElapsed = totalPlayed - state.anchorPlayed
    if serverElapsed < 0 then
        -- /played went backwards. This is not something a player can cause by
        -- playing, so it is treated as tampering evidence rather than a gap.
        V.SetStatus("difficulty", V.STATUS.UNVERIFIED, "played time decreased")
        V.SetStatus("selfFound", V.STATUS.UNVERIFIED, "played time decreased")
        if V.Integrity and V.Integrity.Seal then V.Integrity.Seal() end
        return
    end

    local gap = serverElapsed - (state.trackedSinceAnchor or 0)
    if gap < 0 then gap = 0 end
    -- Session-boundary residue is discarded rather than recorded (see GAP_IGNORE).
    -- This is a deadband, not a discount: once a gap is real it is measured whole,
    -- so there is no minute of unwatched play to be had by logging out often.
    if gap < T.GAP_IGNORE then gap = 0 end
    -- Keep the worst gap ever measured. Tracked time can drift slightly ahead
    -- of the server (a long loading screen accrues on our side but not on
    -- theirs), and without this a player could idle a detected gap away.
    --
    -- Seconds, and only seconds. What is kept here is the measurement, which
    -- honestly never falls -- the time really was missed. The *share* it
    -- represents is not stored at all and is derived fresh in ComponentStatus,
    -- which is what lets it fall as the run grows around it. Storing the worst
    -- share the way this stores the worst seconds is exactly the mistake that
    -- made recovery impossible.
    if gap > (state.untrackedSeconds or 0) then
        state.untrackedSeconds = gap
    end
    -- Clear residue recorded by an earlier version, which had no deadband. Only
    -- ever downward and only below the deadband, so nothing that was judged
    -- against the tolerance is touched: the band and any warning it raised stand
    -- exactly as they were.
    if (state.untrackedSeconds or 0) > 0 and state.untrackedSeconds < T.GAP_IGNORE then
        state.untrackedSeconds = 0
    end

    -- Nothing is decided here. The measurement above is the whole of this
    -- module's output, and what it means for the certification is worked out on
    -- demand by T.ComponentStatus -- which is precisely what lets the verdict
    -- follow the number back down when watched play closes the gap.
    ClearLegacyGapState(state)
    if V.ComposeAll then V.ComposeAll() end

    if V.Integrity and V.Integrity.Seal then
        V.Integrity.Seal()
    end
end

-- ── Wiring ───────────────────────────────────────────────────────────────────

local function OnLogin()
    lastAccrual = GetTime()
    T.Request()

    if not accrueTicker and C_Timer and C_Timer.NewTicker then
        accrueTicker = C_Timer.NewTicker(T.ACCRUE_INTERVAL, Accrue)
        pollTicker = C_Timer.NewTicker(T.POLL_INTERVAL, T.Request)
    end
end

local function OnEvent(_, event, ...)
    if event == "TIME_PLAYED_MSG" then
        local totalPlayed, levelPlayed = ...
        ClearSilentRequestSoon()
        if type(totalPlayed) == "number" then
            Reconcile(totalPlayed, levelPlayed)
            -- The tracked-time floor in the qualification window can only
            -- change when a reply lands, so the five-minute poll doubles as
            -- the retry for it (plan sections 5 and 6).
            if V.CheckQualifications then V.CheckQualifications() end
        end
    elseif event == "PLAYER_LOGIN" then
        OnLogin()
    elseif event == "PLAYER_LEVEL_UP" then
        Accrue()
        T.Request()
        -- The allowance is a function of level, so the verdict can change on a
        -- ding with nothing else having happened. Recomposed here so the panel
        -- is right immediately rather than at the next five-minute poll.
        if V.ComposeAll then V.ComposeAll() end
    elseif event == "PLAYER_LOGOUT" then
        -- Last chance to bank the tail of the session before SavedVariables is
        -- written. Does not fire on a crash or Alt-F4, in which case the whole
        -- session is lost from SavedVariables anyway and the resulting gap is
        -- what the tolerance in section 17 exists to absorb.
        Accrue()
        -- Then seal unconditionally, whatever Accrue decided to do.
        --
        -- This is the safety net under the whole scheme: SavedVariables is
        -- written moments from now, and the seal has to describe what is in it.
        -- Any module that changes a sealed field and forgets to re-stamp would
        -- otherwise save a record that fails its own check at the next login,
        -- and the player would be told their record looks tampered with because
        -- Rustcore made a bookkeeping mistake. Sealing here makes that class of
        -- bug impossible to reach the player at all.
        if V.Integrity and V.Integrity.Seal then V.Integrity.Seal() end
    end
end

function T.Init()
    if T.initialized then return end
    T.initialized = true

    -- Registered before anything can ask for a status. Both tracks get the same
    -- answer, because there is only one clock and the time it did not see is
    -- missing from both runs equally.
    if V.RegisterComponent then
        V.RegisterComponent("time", function() return T.ComponentStatus() end)
    end

    InstallChatSuppression()

    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("TIME_PLAYED_MSG")
    eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
    eventFrame:RegisterEvent("PLAYER_LOGOUT")
    eventFrame:SetScript("OnEvent", OnEvent)

    if IsLoggedIn and IsLoggedIn() then
        -- Init normally runs during ADDON_LOADED, before PLAYER_LOGIN. If it
        -- somehow runs later, do the login work now instead of waiting for an
        -- event that has already passed.
        OnLogin()
    else
        eventFrame:RegisterEvent("PLAYER_LOGIN")
    end
end
