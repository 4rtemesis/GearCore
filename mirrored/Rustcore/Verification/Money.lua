-- Rustcore Verification: Self-Found money monitoring
-- (plan sections 23, 24 and 25).
--
-- Section 23 sets the ambition deliberately low: do not try to explain every
-- copper. Only two things matter here.
--
--   direction  a gain can be an acquisition; spending never is. Money going
--              down is not tracked beyond keeping the running figure honest.
--   magnitude  an unexplained gain is judged against what is normal for the
--              character's level, not against a ledger of where it came from.
--
-- Everything that legitimately produces money -- looting, quest rewards, selling
-- to a vendor, NPC mail -- is filtered out by Economy.lua's context window
-- before magnitude is ever consulted, so in ordinary play this module reaches
-- its thresholds essentially never.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.Money = V.Money or {}
local Mo = V.Money

local function E()
    return V.Economy
end

local function CurrentMoney()
    return (GetMoney and GetMoney()) or 0
end

-- Both `last` and `lastPlayed` are covered by the integrity seal, so every write
-- to them has to re-stamp it.
--
-- Leaving that to Time.lua's ten-second accrual, which re-seals as a side effect,
-- worked right up until a session ended inside one of those windows: the saved
-- record then carried new money figures under an older seal, and the next login
-- reported the record as failing its own checksum. Sealing at the point of
-- change removes the window entirely.
local function Reseal()
    if V.Integrity and V.Integrity.Seal then V.Integrity.Seal() end
end

-- State ----------------------------------------------------------------------

-- Persisted, because the comparison has to survive a logout: money earned while
-- Rustcore was not watching should still be noticed next login.
local function GetState()
    local economy = E() and E().GetState()
    if not economy then return nil end
    economy.money = economy.money or {}
    local state = economy.money
    if state.unexplained == nil then state.unexplained = 0 end
    if state.anomalies == nil then state.anomalies = 0 end
    return state
end

Mo.GetState = GetState

-- Evaluation ------------------------------------------------------------------

-- An unexplained gain, in copper, judged against the level-scaled thresholds.
local function Judge(amount)
    local economy = E()
    local level = V.GetPlayerLevel() or 1
    local warn = economy.GetGoldWarningThreshold(level)
    local fail = economy.GetGoldFailureThreshold(level)

    if amount < warn then return nil end
    return (amount >= fail) and "fail" or "warn"
end

-- Set once the world is loaded. Until then GetMoney() can still answer 0, and
-- comparing a real balance against that phantom zero would read as the player
-- suddenly acquiring everything they own.
-- Live judging is held off until the cross-session check below has run, because
-- the persisted baseline belongs to the previous session and the live path would
-- read the whole gap as one enormous single gain.
local ready = false
local gapChecked = false

-- Cross-session gold (evaluated once per login) ---------------------------------
--
-- The baseline is no longer thrown away at login. If Rustcore was switched off
-- for a while, the gold it last saw and the gold there is now are the only
-- evidence of what happened in between -- discarding it meant an entire
-- unwatched stretch cost nothing at all.
--
-- What this can conclude is limited, and the limits are deliberate. It cannot
-- see *where* gold came from, only that there is more of it than that much
-- unobserved play plausibly produces. That is inference, so it can reach WARNING
-- or UNVERIFIED and never FAILED, and the budget below is set generously: the
-- aim is to catch a character arriving with a fortune after twenty unwatched
-- minutes, not to audit anyone's questing.

-- Multiplies the level's single-gain failure threshold into a per-hour earning
-- rate. Three times what would be a suspicious one-off gain, every hour, is far
-- above what Classic actually pays at any level.
Mo.PLAUSIBLE_RATE_MULTIPLIER = 3
-- How far past that budget stops being "a good run" and starts being impossible.
Mo.IMPLAUSIBLE_MULTIPLIER = 4
-- Gaps shorter than this are not reasoned about at all. The persisted pair is
-- refreshed on the five-minute /played poll, so the tail of any session -- up to
-- one whole poll interval -- looks unobserved at the next login even though
-- nothing was missed. This floor sits comfortably above that artefact.
Mo.GAP_FLOOR = 900

-- The most gold this character could plausibly have come by during `seconds` of
-- play Rustcore did not see.
function Mo.PlausibleGain(seconds, level)
    local economy = E()
    level = level or V.GetPlayerLevel() or 1
    local hours = math.max(0, (seconds or 0)) / 3600
    -- The flat term covers whatever was already in flight when the addon stopped
    -- watching, so a very short gap is not judged on rate alone.
    return economy.GetGoldWarningThreshold(level)
        + (economy.GetGoldFailureThreshold(level) * Mo.PLAUSIBLE_RATE_MULTIPLIER * hours)
end

-- Runs once, on the first /played reply after login. `serverPlayed` comes from
-- the event payload rather than Time.lua's stored copy, because both modules
-- listen for TIME_PLAYED_MSG and the order they are called in is not defined.
function Mo.CheckSessionGap(serverPlayed)
    if gapChecked then return end
    gapChecked = true

    local state = GetState()
    if not state then ready = true; return end

    local current = CurrentMoney()
    local baseline = state.last
    local baselinePlayed = state.lastPlayed

    -- Establish the new baseline whatever the outcome, so the next login
    -- measures from here.
    local function settle()
        state.last = current
        state.lastPlayed = serverPlayed
        ready = true
        Reseal()
    end

    if baseline == nil or baselinePlayed == nil or not serverPlayed then
        return settle()
    end

    -- How much of the elapsed server time nobody was watching. Play this session
    -- has already tracked is accounted for; the rest happened with Rustcore off.
    local elapsed = serverPlayed - baselinePlayed
    local tracked = (V.Time and V.Time.GetSessionTracked and V.Time.GetSessionTracked()) or 0
    local unobserved = elapsed - tracked
    if unobserved <= Mo.GAP_FLOOR then return settle() end

    local gained = current - baseline
    if gained <= 0 then return settle() end
    if not E().ShouldJudge() then return settle() end

    local level = V.GetPlayerLevel() or 1
    local budget = Mo.PlausibleGain(unobserved, level)
    if gained <= budget then return settle() end

    local band = (gained > budget * Mo.IMPLAUSIBLE_MULTIPLIER) and "fail" or "warn"
    state.unexplained = (state.unexplained or 0) + (gained - budget)
    state.anomalies = (state.anomalies or 0) + 1
    state.lastAnomaly = gained
    state.lastAnomalyAt = time and time() or 0

    -- Escalate deliberately bypasses the economy failure gate for the top band
    -- here by naming it a different warning type: inferred gold can cost the
    -- certification, but only ever as UNVERIFIED.
    E().EscalateUnverifiable(band, "goldDiscrepancy", string.format(
        "%s gained over %dm of unobserved play at level %d",
        E().FormatMoney(gained), math.floor(unobserved / 60), level))

    if V.Integrity and V.Integrity.Seal then V.Integrity.Seal() end
    return settle()
end

-- Called on every money change.
function Mo.Evaluate()
    local state = GetState()
    if not state then return end

    local current = CurrentMoney()
    local previous = state.last

    -- First reading on this character, or the figure is not trustworthy yet:
    -- adopt it and judge nothing.
    if previous == nil or not ready then
        state.last = current
        Reseal()
        return
    end

    state.last = current
    Reseal()

    local delta = current - previous
    if delta <= 0 then return end          -- spending is never a violation
    if not E().ShouldJudge() then return end

    -- Quest rewards state their amount outright, so that much is settled
    -- exactly rather than merely excused.
    local remaining = E().ConsumeExpectedMoney(delta)
    if remaining <= 0 then return end

    -- Anything the player was plainly in the middle of doing.
    if E().IsExplained() then return end

    state.unexplained = (state.unexplained or 0) + remaining

    local band = Judge(remaining)
    if not band then return end

    state.anomalies = (state.anomalies or 0) + 1
    state.lastAnomaly = remaining
    state.lastAnomalyAt = time and time() or 0

    E().Escalate(band, "goldDiscrepancy", string.format(
        "%s unexplained at level %d",
        E().FormatMoney(remaining), V.GetPlayerLevel() or 0))

    if V.Integrity and V.Integrity.Seal then V.Integrity.Seal() end
end

-- Take the current figure as the new baseline without judging it. Used where
-- Rustcore has no business comparing -- a fresh claim, or after an import.
function Mo.Rebase()
    local state = GetState()
    if not state then return end
    state.last = CurrentMoney()
    state.lastPlayed = (V.Time and V.Time.GetLastServerPlayed and V.Time.GetLastServerPlayed()) or nil
    ready = true
    gapChecked = true
    Reseal()
end

-- Events -----------------------------------------------------------------------

function Mo.OnEvent(event, ...)
    if event == "PLAYER_MONEY" then
        Mo.Evaluate()

    elseif event == "TIME_PLAYED_MSG" then
        -- The first reply after login is what makes the cross-session check
        -- possible: until it lands there is no way to know how much of the gap
        -- was unobserved, and therefore no basis for judging the gold.
        local totalPlayed = ...
        if type(totalPlayed) == "number" then
            if not gapChecked then
                Mo.CheckSessionGap(totalPlayed)
            else
                -- Keep the persisted pair meaning "the gold, and the /played,
                -- at the last moment Rustcore was watching". Without this the
                -- pair would still describe login, and the next session would
                -- read this entire session as unobserved play.
                local state = GetState()
                if state then
                    state.last = CurrentMoney()
                    state.lastPlayed = totalPlayed
                    Reseal()
                end
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Deliberately does not rebase. The persisted baseline is the only
        -- record of what Rustcore last saw, and CheckSessionGap needs it intact.
        -- If no /played reply ever arrives, this is the fallback that lets live
        -- monitoring start rather than stalling forever.
        if C_Timer and C_Timer.After then
            C_Timer.After(30, function()
                if not gapChecked then pcall(Mo.CheckSessionGap, nil) end
            end)
        end
    end
end

function Mo.Init()
    if Mo.initialized then return end
    Mo.initialized = true

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_MONEY")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("TIME_PLAYED_MSG")
    frame:SetScript("OnEvent", function(_, event, ...)
        -- A fault in verification must never break the game session.
        local ok, err = pcall(Mo.OnEvent, event, ...)
        if not ok then
            print("|cffff4444Rustcore ERROR:|r money verification: " .. tostring(err))
        end
    end)
    Mo.frame = frame
end
