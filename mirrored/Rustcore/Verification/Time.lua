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
-- hour unwatched means something very different on a 20-hour character than on a
-- 400-hour one, and a fixed cap would punish exactly the long-lived characters
-- who have the most history to show for themselves.
--
--   up to GAP_RATIO         normal. Nothing is recorded.
--   GAP_RATIO..GAP_SEVERE   flagged, still certified.
--   above GAP_SEVERE_RATIO  UNVERIFIED -- too much went unseen to vouch for.
--
-- Never FAILED at any size. Not being watched is not a violation.
T.GAP_RATIO = 0.02
T.GAP_SEVERE_RATIO = 0.05
-- A floor under both, so a brand new character is not held to a percentage of
-- almost nothing: five minutes is about what one crash or Lua error costs.
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

-- Plan section 17.
-- Where a gap stops being normal and starts being worth noting.
function T.GetAllowedGap(totalPlayed)
    totalPlayed = totalPlayed or T.GetLastServerPlayed()
    return max(T.GAP_MINIMUM, (totalPlayed or 0) * T.GAP_RATIO)
end

-- Where a gap costs the certification. This is the number the tracking bar is
-- drawn against, because it is the one the player is actually running out of --
-- crossing the warning line above only annotates the record.
function T.GetSevereGap(totalPlayed)
    totalPlayed = totalPlayed or T.GetLastServerPlayed()
    return max(T.GAP_MINIMUM * (T.GAP_SEVERE_RATIO / T.GAP_RATIO),
               (totalPlayed or 0) * T.GAP_SEVERE_RATIO)
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

local function ApplyGapConsequence(state, gap, allowed, severe)
    local band
    if gap <= allowed then
        band = "OK"
    elseif gap < severe then
        band = "WARNING"
    else
        -- Reaching the severe ratio is enough; it does not have to be exceeded.
        band = "SEVERE"
    end

    if band == state.gapBand or band == "OK" then
        state.gapBand = state.gapBand or band
        return
    end
    -- Bands only ever escalate. A later reconciliation cannot talk a character
    -- back down out of a gap that was already recorded.
    if state.gapBand == "SEVERE" then return end
    state.gapBand = band

    -- Worded as time not observed rather than as an accusation: the overwhelming
    -- cause is Rustcore having been switched off, or a client that crashed.
    local detail = ("%dm unobserved of %dm allowed"):format(
        floor(gap / 60), floor(severe / 60))
    if band == "WARNING" then
        V.AddWarning("difficulty", "untrackedPlay", detail)
        V.AddWarning("selfFound", "untrackedPlay", detail)
    else
        -- Too much of this character's life happened with nobody watching for a
        -- certification to mean anything. UNVERIFIED, never FAILED -- there is no
        -- violation here, only an absence of evidence.
        V.SetStatus("difficulty", V.STATUS.UNVERIFIED, "playtime not observed: " .. detail)
        V.SetStatus("selfFound", V.STATUS.UNVERIFIED, "playtime not observed: " .. detail)
    end
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
        state.gapBand = "OK"
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

    ApplyGapConsequence(state, state.untrackedSeconds,
        T.GetAllowedGap(totalPlayed), T.GetSevereGap(totalPlayed))

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
