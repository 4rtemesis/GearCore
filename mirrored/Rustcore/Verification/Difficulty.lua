-- Rustcore Verification: difficulty certification (plan sections 7-12 and 15).
--
-- Two numbers describe a character's difficulty standing and they must not be
-- confused:
--   currentTier         the preset selected in the options right now
--   highestVerifiedTier the hardest preset Rustcore can still vouch for
--
-- Selecting an easier preset does not by itself destroy a harder certification
-- (section 8). The certification only moves down when an easier rule set
-- actually governs something that happened -- in practice, a death (section 9).
-- highestVerifiedTier only ever moves downward; no setting change can lift it
-- again (section 10).

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.Difficulty = V.Difficulty or {}
local D = V.Difficulty

-- Exception mapping (plan section 11) ----------------------------------------
--
-- One central table rather than checks scattered through the addon. `boundOn`
-- says when the rule bites, which is the whole point of section 9: enabling an
-- exception is not a violation, letting it change what actually happened is.
--
--   DEATH_WITH_LOSS  the exception altered a death that would otherwise have
--                    taken items under the selected preset
--   DEATH_SKIPPED    the exception cancelled the death penalty outright
--   REPAIR           the exception permits an action forbidden at every preset;
--                    the violation is the action, not the setting
D.EXCEPTION_RULES = {
    -- Every preset above Rusted is defined by what a death takes from you, so
    -- shielding the main weapon from that is only compatible with Rusted.
    keepMainWeapon = {
        setting         = "keepMainWeapon",
        boundOn         = "DEATH_WITH_LOSS",
        maxVerifiedTier = 1,
        label           = "main weapon protected from deletion",
    },
    -- A death that costs nothing is a Rusted death whatever the options say.
    -- The plan does not name this exception, so it is mapped by the same logic
    -- section 9 applies to difficulty changes: certification follows the rules
    -- that actually ran.
    ignoreDeathAfterEnemyPlayerDamage = {
        setting         = "ignoreDeathAfterEnemyPlayerDamage",
        boundOn         = "DEATH_SKIPPED",
        maxVerifiedTier = 1,
        label           = "death penalty skipped after enemy player damage",
    },
    -- Rustcore blocks repair at every preset, so enabling this only makes the
    -- violation possible (section 12). Phase 3 owns detection and calls
    -- D.OnRepairPerformed when a repair is actually observed.
    allowRepair = {
        setting         = "allowRepair",
        boundOn         = "REPAIR",
        maxVerifiedTier = nil,
        failsOnUse      = true,
        label           = "repair permitted",
    },
}

local function Setting(key)
    if Rustcore and Rustcore.GetSetting then
        return Rustcore.GetSetting(key)
    end
    return nil
end

local function Append(eventType, payload)
    if V.Integrity and V.Integrity.Append then
        V.Integrity.Append(eventType, payload)
    end
end

-- The dragon is the public face of this track, so anything that can change the
-- answer repaints it immediately rather than waiting for the next refresh.
local function RefreshPortrait()
    if not RustcoreDragon then return end
    if RustcoreDragon.RefreshPlayerFrame then RustcoreDragon.RefreshPlayerFrame() end
    if RustcoreDragon.RefreshTargetFrame then RustcoreDragon.RefreshTargetFrame() end
end

-- Exceptions in force right now ----------------------------------------------

-- Which exceptions are switched on. Reported in the Verification tab and folded
-- into chain events; on its own this changes no certification.
function D.GetActiveExceptions()
    local active = {}
    for name, rule in pairs(D.EXCEPTION_RULES) do
        if Setting(rule.setting) then active[name] = true end
    end
    return active
end

-- The cap the enabled exceptions would impose if every one of them became
-- relevant. Advisory only, so an exception's cost is visible to the player
-- before a death makes it permanent.
function D.GetPotentialCapTier()
    local cap
    for name in pairs(D.GetActiveExceptions()) do
        local ruleCap = D.EXCEPTION_RULES[name].maxVerifiedTier
        if ruleCap and (not cap or ruleCap < cap) then cap = ruleCap end
    end
    return cap
end

-- Selected difficulty --------------------------------------------------------

-- Record the selected preset. Called at login and whenever the option changes.
-- Section 8: this is bookkeeping, never a certification change.
-- The hardest tier this character is still allowed to be certified for.
--
-- Two things hold it down, both permanent once set:
--   permanentCapTier  an exception or a death that ran under weaker rules
--   deathFloorTier    the weakest rule set that has ever governed a death
--
-- With neither, there is no ceiling: nothing has happened that a harder preset
-- would have made harder.
local function CertificationCeiling(track)
    local ceiling = V.MAX_TIER
    if type(track.permanentCapTier) == "number" and track.permanentCapTier < ceiling then
        ceiling = track.permanentCapTier
    end
    if type(track.deathFloorTier) == "number" and track.deathFloorTier < ceiling then
        ceiling = track.deathFloorTier
    end
    return ceiling
end

function D.SyncSelectedTier()
    local track = V.GetTrack("difficulty")
    if not track then return end

    local tier = V.GetCurrentTier()
    local previous = track.currentTier
    track.currentTier = tier

    -- Selecting a harder preset raises the certification to match it.
    --
    -- Section 10 forbids a *setting change* from lifting a certification that
    -- was lost, and that still holds: the ceiling above is what a cap or a death
    -- pinned down, and nothing here can move it. What this allows is the case
    -- the plan never covers -- a character whose record was created while an
    -- easier preset was selected, most obviously one made at the default before
    -- the player picked Dust on the login popup. Refusing to raise it there
    -- certified the default forever and there was no way to ever reach the
    -- harder tiers, which is plainly not what section 7 describes.
    --
    -- Harder rules are strictly more restrictive, so moving up is never a way to
    -- dodge anything; only deaths under weaker rules are, and those set the
    -- ceiling.
    if V.IsCertified(track.status) then
        local ceiling = CertificationCeiling(track)
        local wanted = tier < ceiling and tier or ceiling
        if wanted > (track.highestVerifiedTier or 0) then
            track.highestVerifiedTier = wanted
        end
    end

    if previous and previous ~= tier then
        Append("DIFFICULTY_CHANGE", {
            from = previous,
            to = tier,
            verified = track.highestVerifiedTier or 0,
        })
    elseif V.Integrity and V.Integrity.Seal then
        V.Integrity.Seal()
    end

    RefreshPortrait()
    return tier
end

-- Death (plan section 9) -----------------------------------------------------

-- context:
--   tier              preset selected when the player died
--   penaltyApplied    false when an exception cancelled the death penalty
--   mainWeaponSkipped true when the main-weapon exception withheld an equipped
--                     item from the deletion pool
--   markedCount       how many items the death actually marked
--
-- Returns the tier certification is capped to.
function D.OnDeath(context)
    context = context or {}
    local track = V.GetTrack("difficulty")
    if not track then return end

    local selected = context.tier
    if type(selected) ~= "number" then selected = V.GetCurrentTier() end

    -- Which rule set actually governed this death.
    local effective, reason = selected, nil
    if context.penaltyApplied == false then
        local rule = D.EXCEPTION_RULES.ignoreDeathAfterEnemyPlayerDamage
        effective, reason = rule.maxVerifiedTier, rule.label
    elseif context.mainWeaponSkipped and selected > 1 then
        local rule = D.EXCEPTION_RULES.keepMainWeapon
        effective, reason = rule.maxVerifiedTier, rule.label
    elseif selected < (track.highestVerifiedTier or 0) then
        reason = "death while " .. V.GetTierName(selected) .. " rules were active"
    end

    -- While the track is still UNCERTAIN there is no certification to lower --
    -- highestVerifiedTier is 0 until a promotion happens -- so the rule set this
    -- death actually ran under is remembered instead. Section 9 still applies
    -- when the promotion eventually lands: it can never certify anything harder
    -- than what was in force at the deaths Rustcore watched.
    if not V.IsCertified(track.status) and type(effective) == "number" then
        if not track.pendingCapTier or effective < track.pendingCapTier then
            track.pendingCapTier = effective
        end
    end

    track.deaths = (track.deaths or 0) + 1
    track.lastDeathAt = time and time() or nil
    track.lastDeathTier = selected

    -- The weakest rule set that has ever actually governed a death. This is what
    -- section 9 really measures: the character cannot claim to have maintained a
    -- preset harder than the one that was in force when it mattered. Recorded
    -- separately from permanentCapTier because CapDifficultyTier declines to
    -- write a cap that would not lower anything -- dying at Rusted while already
    -- certified Rusted sets no cap, but it must still stop a later switch to
    -- Dust from certifying Dust.
    if type(effective) == "number" then
        if not track.deathFloorTier or effective < track.deathFloorTier then
            track.deathFloorTier = effective
        end
    end

    Append("DEATH", {
        tier = selected,
        effective = effective,
        applied = context.penaltyApplied ~= false,
        marked = context.markedCount or 0,
        weaponKept = context.mainWeaponSkipped and true or false,
    })

    -- CapDifficultyTier appends its own CAP event and reseals; it returns false
    -- when the cap would not actually lower anything.
    if not V.CapDifficultyTier(effective, reason or "death") then
        if V.Integrity and V.Integrity.Seal then V.Integrity.Seal() end
    end

    RefreshPortrait()
    return track.highestVerifiedTier or 0
end

-- Repair (plan section 12) ---------------------------------------------------

-- Called by Phase 3 when a repair is actually observed, not when the option is
-- switched on. Rustcore blocks repair at every preset including Rusted, so an
-- observed repair breaks the rules the character was playing under rather than
-- merely looking suspicious -- section 47 maps that to FAILED.
function D.OnRepairPerformed(detail)
    local track = V.GetTrack("difficulty")
    if not track then return end

    track.repairViolations = (track.repairViolations or 0) + 1
    Append("REPAIR_VIOLATION", { detail = detail or "", count = track.repairViolations })
    V.SetStatus("difficulty", V.STATUS.FAILED, "repair performed: " .. tostring(detail or "observed"))
    RefreshPortrait()
    return track.repairViolations
end

-- An unexplained durability increase is evidence, not observation: the first is
-- a warning and the portrait stays (plan section 14). Phase 3 decides when the
-- evidence is good enough to call this.
function D.OnUnexplainedRepairEvidence(detail)
    local track = V.GetTrack("difficulty")
    if not track then return end

    V.AddWarning("difficulty", "unexplainedRepair", detail or "")
    local count = V.GetWarningCount("difficulty", "unexplainedRepair")
    Append("REPAIR_WARNING", { detail = detail or "", count = count })

    if count >= 2 then
        -- Repeated unexplained increases stop being a coincidence.
        -- UNVERIFIED, not FAILED. A durability figure going up is evidence of a
        -- repair, not an observation of one: item swaps, server corrections and
        -- identity ambiguity between two copies of the same item can all produce
        -- it. Repeating makes coincidence unlikely, but it never turns inference
        -- into something Rustcore watched happen -- and FAILED is reserved for
        -- what it watched. An actual observed repair still fails, above.
        V.SetStatus("difficulty", V.STATUS.UNVERIFIED, "repeated unexplained durability increase")
    end
    RefreshPortrait()
    return count
end

-- Qualification (plan section 5) ---------------------------------------------

-- A character that installed Rustcore inside the early window and has been
-- tracked cleanly for about two levels earns its certification here. Core owns
-- the decision; this owns what the promotion is actually worth.
function D.CheckQualification()
    local ok, reason = V.EvaluateQualification("difficulty")
    if not ok then return false end

    local track = V.GetTrack("difficulty")
    if not track then return false end

    -- Nothing was ever certified while the track sat at UNCERTAIN, so this is
    -- where highestVerifiedTier gets its first value. It is the preset being
    -- played now, held down by any death during the window that ran under
    -- weaker rules.
    local tier = V.GetCurrentTier()
    local pending = track.pendingCapTier
    if type(pending) == "number" and pending < tier then
        tier = pending
        track.permanentCapTier = tier
    end
    track.highestVerifiedTier = tier

    if not V.Promote("difficulty", reason) then return false end
    if V.Integrity and V.Integrity.Seal then V.Integrity.Seal() end
    RefreshPortrait()
    return true
end

-- Portrait (plan sections 7 and 15) ------------------------------------------

-- The tier the local player's dragon should show, or nil when no dragon may be
-- shown at all.
--
-- Section 7: the dragon represents the hardest difficulty still legitimately
-- verified. Section 15: it follows the selected preset, but only as far as that
-- preset is still verified -- a character capped at Broken who selects Dust
-- shows Broken, never Dust.
function D.GetPortraitTier()
    local track = V.GetTrack("difficulty")
    if not track then
        -- No record, so nothing has been verified. This used to fall back to the
        -- selected preset, which meant the dragon showed the difficulty the
        -- player had merely *chosen* whenever verification was unavailable --
        -- exactly the claim the dragon is supposed to not make. A missing record
        -- is an absence of evidence, and the honest answer to "what is this
        -- character verified for" is then nothing at all.
        return nil
    end

    if not V.IsCertified(track.status) then return nil end

    local highest = track.highestVerifiedTier or 0
    if highest < 1 then return nil end

    local selected = V.GetCurrentTier()
    if selected < highest then return selected end
    return highest
end

-- What other players may learn about this character (plan section 46): the
-- verified tier, or nil when there is nothing to claim. Never the raw setting.
function D.GetBroadcastTier()
    return D.GetPortraitTier()
end

function D.Init()
    if D.initialized then return end
    D.initialized = true
    D.SyncSelectedTier()
end
