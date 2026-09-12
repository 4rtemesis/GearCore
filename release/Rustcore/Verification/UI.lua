-- Rustcore Verification: the Verification tab (plan sections 45 and 46).
--
-- What this page is for: telling the player how much of their certification
-- Rustcore can actually stand behind, in plain language.
--
-- Section 45 draws one hard line -- the raw hash chain and the internal event
-- history are not shown. They are machinery, they would mean nothing to a
-- player, and displaying them would invite exactly the kind of hand-editing the
-- chain exists to detect. What is shown is the conclusion and the evidence
-- behind it: the status, how much of the character's play Rustcore actually
-- watched, and anything it has flagged.
--
-- Section 28's tone applies to every string here. A lost certification is
-- reported as lost, never as an accusation.

RustcoreVerification = RustcoreVerification or {}
local V = RustcoreVerification
V.UI = V.UI or {}
local UI = V.UI

local BODY_FONT_PATH = Rustcore.GetAssetPath("Font/BPpong.otf")

-- Status presentation -----------------------------------------------------------

-- Colour and wording per status. The word is what the player reads first, so it
-- says what Rustcore can vouch for rather than what the player may have done.
-- The status word carries the outlook by itself, so there is no second line
-- spelling it out. The colours follow it:
--
--   green  certified. VERIFIED and WARNING both land here.
--   blue   not certified yet, but still reachable by playing on.
--   amber  over, but through absence of evidence rather than wrongdoing.
--   red    over, because a rule was observed being broken.
--
-- That last split is the important one, and it is why UNVERIFIED and FAILED are
-- not the same colour or the same word:
--
--   UNVERIFIED  Rustcore never saw enough to vouch for the run. No accusation.
--   FAILED      Rustcore watched a challenge rule being broken.
--
-- A run that has simply not been watched long enough yet is Uncertain. A run
-- held up by something the player can act on right now is Suspended -- the two
-- were the same word until it turned out they are not the same situation at all:
-- one is waiting on Rustcore and the other is waiting on the player.
--
-- The sixth entry is the standing line to use when there is a stated reason.
-- The fifth reads correctly on its own and wrongly underneath a cause: telling
-- somebody why their certification stopped and then adding "no rule violation
-- was detected" answers a question they did not ask and contradicts the line
-- above it. Where the sixth is absent the fifth is used either way.
local STATUS_LOOK = {
    VERIFIED   = { 0.35, 0.9,  0.35, "Verified",     "No rule violations detected." },
    WARNING    = { 0.35, 0.9,  0.35, "Verified",     "A gap has been noted in the observed play time. The certification is still active." },
    SUSPENDED  = { 0.55, 0.75, 0.95, "Suspended",    "The certification is paused, not lost.",
                                                     "The certification is paused, not lost. Put this right and it comes straight back." },
    UNCERTAIN  = { 0.55, 0.75, 0.95, "Uncertain",    "Still being observed. Keep playing to earn certification." },
    UNVERIFIED = { 0.85, 0.6,  0.3,  "Not verified", "Rustcore does not have enough evidence to verify this run. No rule violation was detected.",
                                                     "This run cannot be certified while that stands." },
    FAILED     = { 0.9,  0.3,  0.3,  "Failed",       "A challenge rule violation was detected." },
}

local function Look(status)
    return STATUS_LOOK[status or ""] or STATUS_LOOK.UNVERIFIED
end

local function FormatDuration(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then return string.format("%dh %02dm", hours, minutes) end
    return string.format("%dm", minutes)
end

-- Reasons -------------------------------------------------------------------
--
-- Everything that costs a certification records why it did, but in the
-- shorthand the module that found it was thinking in -- "untracked playtime:
-- untracked=4210s allowed=300s". Section 45 asks for the conclusion *and* the
-- evidence behind it in language a player can read, so the shorthand is
-- translated here rather than shown raw.
--
-- Matched by prefix, because most of these carry a precise and unreadable
-- detail tail. Anything unmatched falls through to the original text: every
-- reason string in the tree is already close to English, and substituting a
-- vaguer sentence for an unrecognised one would hide the single thing the
-- player opened this tab to find out.
local REASON_TEXT = {
    { "untracked playtime",
      "Too much play happened while Rustcore was not running." },
    { "playtime not observed",
      "Too much play happened while Rustcore was not running." },
    { "death-marked item not destroyed",
      "Gear a death marked for deletion has not been destroyed." },
    { "played time decreased",
      "Your played time went backwards, which playing cannot cause." },
    { "integrity",
      "Rustcore's saved record did not match its own checksum. This pauses "
      .. "certification rather than ending the run, and it lifts itself after "
      .. "a clean stretch of play." },
    { "identity mismatch",
      "This record was made on a different character." },
    { "repair performed",
      "Your gear was repaired, which this difficulty does not allow." },
    { "repeated unexplained durability increase",
      "Durability went up more than once with no repair Rustcore could see." },
    { "Self-Found started level",
      "Self-Found was switched on too late in the run to be certified." },
    -- Both of these describe how a pause began, and both are written at the
    -- moment it begins -- but a suspension outlives its cause. Switching
    -- Self-Found back on does not lift it on its own (SF.EvaluateRestore wants
    -- to have watched the run cleanly first), and RepairUnexplainedSelfFound
    -- can park a track here without the option ever having been touched. So a
    -- player ends up reading "Self-Found is switched off" while looking at a
    -- ticked box. The status is SUSPENDED; say that, rather than restating a
    -- stale cause in the present tense.
    { "Self-Found switched off",
      "Self-Found verification is paused. It resumes once Self-Found is on and the run has been watched cleanly again." },
    { "Self-Found was switched off",
      "Self-Found verification is paused. It resumes once Self-Found is on and the run has been watched cleanly again." },
}

local function Humanise(reason)
    if type(reason) ~= "string" or reason == "" then return nil end
    for _, entry in ipairs(REASON_TEXT) do
        if reason:sub(1, #entry[1]) == entry[1] then return entry[2] end
    end
    -- Left as written, with a full stop so it sits beside the translated ones
    -- as a sentence.
    local text = reason:sub(1, 1):upper() .. reason:sub(2)
    if not text:match("[%.%!%?]$") then text = text .. "." end
    return text
end

local WARNING_TEXT = {
    untrackedPlay     = "some play happened while Rustcore was not running",
    unexplainedRepair = "durability went up with no repair Rustcore could see",
    goldDiscrepancy   = "gold arrived that Rustcore could not account for",
    itemDiscrepancy   = "an item arrived that Rustcore could not account for",
    mailAcquisition   = "something arrived by mail",
    -- Present for completeness rather than for display: DeathLoss records
    -- this warning and drops the difficulty track to UNVERIFIED in the same
    -- call, so today the note is written by the UNVERIFIED branch instead.
    -- It is here so the kind can never surface as a raw camelCase key if a
    -- future path records it without the loss, or if one arrives on a
    -- transfer from a build that treats it more leniently.
    deathLossItem     = "gear a death marked for deletion was not destroyed",
}

-- What a WARNING status is about, as a finished sentence.
--
-- Named rather than counted: the question is why the run is not a clean
-- Verified, and "2" is not an answer to it. It also carries the standing clause
-- itself, so the caller has no reason to follow it with a second, vaguer line.
-- The standing line below is written for the one case that still reaches it --
-- a tracking gap inside tolerance, which records no named warning at all.
local function WarningReason(track)
    local parts = {}
    for kind in pairs(track.warnings or {}) do
        parts[#parts + 1] = WARNING_TEXT[kind] or tostring(kind)
    end
    if #parts == 0 then return nil end
    table.sort(parts)
    local text = table.concat(parts, "; ")
    return text:sub(1, 1):upper() .. text:sub(2) .. ". The certification stands."
end

-- The one sentence explaining the current status, or nil when the status needs
-- no explaining -- a clean Verified is not owed an excuse.
local function StatusReason(trackName, track)
    local status = track.status

    if status == V.STATUS.FAILED then
        return Humanise(track.failedReason or track.statusReason)

    elseif status == V.STATUS.UNVERIFIED or status == V.STATUS.SUSPENDED then
        -- statusReason is only recorded from this version on. lastViolation is
        -- the same string on the Self-Found track and has been stored (and
        -- sealed) all along, so a run lost before this change still has a
        -- cause to show. When neither exists the line is simply omitted rather
        -- than guessed at after the fact.
        return Humanise(track.statusReason or track.lastViolation)

    elseif status == V.STATUS.UNCERTAIN then
        -- Not a loss. This run has not earned certification yet, and
        -- EvaluateQualification already knows exactly what is still missing.
        local ok, why = V.EvaluateQualification(trackName)
        if ok then return "Everything needed is in place; this certifies shortly." end
        return Humanise(why)

    elseif status == V.STATUS.WARNING then
        return WarningReason(track)
    end

    return nil
end

-- Reason first, then the standing line for the status. On a lost run that puts
-- the cause above "This run can no longer be certified", which is the order the
-- sentences are actually read in.
local function NoteFor(trackName, track, look)
    local reason = StatusReason(trackName, track)
    -- A WARNING reason is already a complete statement including the standing
    -- clause, so the generic line underneath would only repeat it less clearly.
    if reason and track.status == V.STATUS.WARNING then return reason end
    local blurb = reason and (look[6] or look[5]) or look[5]
    if reason and blurb then return reason .. "\n" .. blurb end
    return reason or blurb or ""
end

local function ApplyFont(fontString, size)
    if not fontString then return end
    fontString:SetFont(BODY_FONT_PATH, size or 14, "")
end

-- Small builders ------------------------------------------------------------------

local function MakeText(parent, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ApplyFont(fs, size)
    fs:SetJustifyH("LEFT")
    if r then fs:SetTextColor(r, g, b) end
    return fs
end

-- The certainty bar. The player asked to see how sure Rustcore is, and this is
-- the honest answer: continuity. Everything else on the page is a yes or a no,
-- but how much of the character's life Rustcore actually watched is a matter of
-- degree, and it is what every certification ultimately rests on.
local function MakeBar(parent, width)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(width, 12)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    bg:SetVertexColor(0, 0, 0, 0.55)

    local fill = bar:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 1, 1)
    fill:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    bar.fill = fill
    bar.width = width

    -- 0 means no headroom left, 1 means nothing missing at all.
    --
    -- The colour comes from the verdict when one is passed, not from the length
    -- of the fill. Those are two different questions and deciding them
    -- separately let them disagree: a character sitting comfortably inside
    -- tolerance would draw amber because the fraction happened to land in the
    -- middle of the meter, which tells the player the run is in trouble at the
    -- same moment the words above it say it is fine.
    function bar:SetFraction(fraction, status)
        fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
        self.fill:SetWidth(math.max(1, (self.width - 2) * fraction))
        if status == V.STATUS.VERIFIED then
            self.fill:SetVertexColor(0.35, 0.85, 0.35, 1)
        elseif status == V.STATUS.WARNING then
            self.fill:SetVertexColor(1, 0.8, 0.2, 1)
        elseif status then
            self.fill:SetVertexColor(0.9, 0.35, 0.3, 1)
        elseif fraction >= 0.75 then
            self.fill:SetVertexColor(0.35, 0.85, 0.35, 1)
        elseif fraction >= 0.4 then
            self.fill:SetVertexColor(1, 0.8, 0.2, 1)
        else
            self.fill:SetVertexColor(0.9, 0.35, 0.3, 1)
        end
    end

    return bar
end

-- Page ------------------------------------------------------------------------------

-- Builds the tab's contents into `page` and returns a refresh function.
-- RustcoreOptions owns the tab and the page frame; everything inside is ours.
function UI.BuildPage(page)
    local PAD_L = 26
    local WIDTH = 380

    local scroll = CreateFrame("ScrollFrame", "RustcoreVerificationScrollFrame", page,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -24, 42)
    scroll:EnableMouseWheel(true)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(410, 720)
    scroll:SetScrollChild(content)

    local scrollBar = scroll.ScrollBar or _G["RustcoreVerificationScrollFrameScrollBar"]
    scroll:SetScript("OnMouseWheel", function(_, delta)
        if not scrollBar then return end
        local minValue, maxValue = scrollBar:GetMinMaxValues()
        local nextValue = scrollBar:GetValue() - (delta * 28)
        scrollBar:SetValue(math.max(minValue, math.min(maxValue, nextValue)))
    end)

    local widgets = {}

    -- Difficulty ------------------------------------------------------------
    local dHeader = MakeText(content, 19, 1, 0.82, 0)
    dHeader:SetPoint("TOPLEFT", content, "TOPLEFT", PAD_L, -18)
    dHeader:SetText("Difficulty Certification")

    -- The status leads. It is the answer to the question this tab exists to
    -- answer; which run the answer is about is a caption underneath it.
    widgets.dStatus = MakeText(content, 22)
    widgets.dStatus:SetPoint("TOPLEFT", dHeader, "BOTTOMLEFT", 0, -8)

    widgets.dTier = MakeText(content, 13, 0.75, 0.75, 0.75)
    widgets.dTier:SetPoint("TOPLEFT", widgets.dStatus, "BOTTOMLEFT", 0, -4)
    widgets.dTier:SetWidth(WIDTH)
    widgets.dTier:SetWordWrap(true)

    widgets.dNote = MakeText(content, 13, 0.75, 0.75, 0.75)
    widgets.dNote:SetPoint("TOPLEFT", widgets.dTier, "BOTTOMLEFT", 0, -6)
    widgets.dNote:SetWidth(WIDTH)
    widgets.dNote:SetWordWrap(true)

    -- Grandfathered characters. Shown because the alternative is a player
    -- wondering why a character that predates verification is certified at all,
    -- and concluding something is broken. It carries no penalty.
    -- Sits beside the status word rather than under the block: it is a footnote
    -- on how this character came to be certified, not a finding of its own, and
    -- a line of its own gave it more weight than it deserves.
    widgets.dOrigin = MakeText(content, 12, 0.62, 0.72, 0.58)
    widgets.dOrigin:SetPoint("LEFT", widgets.dStatus, "RIGHT", 8, -1)

    -- Self-Found -------------------------------------------------------------
    -- Above Tracking Confidence: both certifications belong together, and the
    -- continuity bar is the evidence underneath them rather than a third
    -- verdict to read between them.
    widgets.sHeader = MakeText(content, 19, 1, 0.82, 0)
    widgets.sHeader:SetPoint("TOPLEFT", widgets.dNote, "BOTTOMLEFT", 0, -18)
    widgets.sHeader:SetText("Self-Found")

    -- Same size as the difficulty status: they are two verdicts of equal
    -- standing, and the smaller type read as a footnote to the first one.
    widgets.sStatus = MakeText(content, 22)
    widgets.sStatus:SetPoint("TOPLEFT", widgets.sHeader, "BOTTOMLEFT", 0, -8)

    widgets.sNote = MakeText(content, 13, 0.75, 0.75, 0.75)
    widgets.sNote:SetPoint("TOPLEFT", widgets.sStatus, "BOTTOMLEFT", 0, -4)
    widgets.sNote:SetWidth(WIDTH)
    widgets.sNote:SetWordWrap(true)

    -- Tracking confidence ----------------------------------------------------
    -- Re-anchored in Refresh, because the Self-Found block above it is hidden
    -- on characters that never claimed the mode. A hidden font string keeps its
    -- rectangle, so anchoring to it unconditionally would leave the gap behind.
    local cHeader = MakeText(content, 19, 1, 0.82, 0)
    cHeader:SetText("Tracking Confidence")
    widgets.cHeader = cHeader

    widgets.bar = MakeBar(content, WIDTH - 20)
    widgets.bar:SetPoint("TOPLEFT", cHeader, "BOTTOMLEFT", 0, -10)

    widgets.cDetail = MakeText(content, 13, 0.85, 0.85, 0.85)
    widgets.cDetail:SetPoint("TOPLEFT", widgets.bar, "BOTTOMLEFT", 0, -8)
    widgets.cDetail:SetWidth(WIDTH)
    widgets.cDetail:SetWordWrap(true)

    -- Transfer ---------------------------------------------------------------
    local tHeader = MakeText(content, 19, 1, 0.82, 0)
    tHeader:SetPoint("TOPLEFT", widgets.cDetail, "BOTTOMLEFT", 0, -18)
    tHeader:SetText("Move To Another PC")

    local tBlurb = MakeText(content, 13, 0.75, 0.75, 0.75)
    tBlurb:SetPoint("TOPLEFT", tHeader, "BOTTOMLEFT", 0, -8)
    tBlurb:SetWidth(WIDTH)
    tBlurb:SetWordWrap(true)
    tBlurb:SetText(
        "Export writes everything Rustcore has tracked for this character "
        .. "into one line of text. Import it on the other PC to continue "
        .. "there.\n\n"
        -- One minute is advice, not the limit: UNACCOUNTED_ALLOWANCE is ninety
        -- seconds, and the margin is there so a player who follows this to the
        -- letter still lands inside it.
        .. "Log out within 1 minute of pressing Export. Play on this PC after "
        .. "that is the one thing the transfer cannot account for, and the "
        .. "import will be refused.\n\n"
        .. "Time logged out costs nothing, so carrying the string across can "
        .. "take as long as you like. Import within 10 minutes of played time "
        .. "once you are back in game.")

    local exportBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    exportBtn:SetSize(110, 24)
    exportBtn:SetPoint("TOPLEFT", tBlurb, "BOTTOMLEFT", 0, -12)
    exportBtn:SetText("Export")
    RustcoreTheme.SkinButton(exportBtn)
    ApplyFont(exportBtn:GetFontString(), 14)

    local importBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    importBtn:SetSize(110, 24)
    importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 10, 0)
    importBtn:SetText("Import")
    RustcoreTheme.SkinButton(importBtn)
    ApplyFont(importBtn:GetFontString(), 14)

    -- The transfer string itself. One scrolling edit box used for both
    -- directions: export fills it and selects it for Ctrl+C (section 34),
    -- import reads whatever was pasted in.
    local boxFrame = CreateFrame("Frame", nil, content,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    boxFrame:SetPoint("TOPLEFT", exportBtn, "BOTTOMLEFT", 0, -10)
    boxFrame:SetSize(WIDTH - 10, 70)

    local boxBg = boxFrame:CreateTexture(nil, "BACKGROUND")
    boxBg:SetAllPoints(boxFrame)
    boxBg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    boxBg:SetVertexColor(0, 0, 0, 0.6)

    local boxScroll = CreateFrame("ScrollFrame", "RustcoreTransferScroll", boxFrame,
        "UIPanelScrollFrameTemplate")
    boxScroll:SetPoint("TOPLEFT", boxFrame, "TOPLEFT", 6, -6)
    boxScroll:SetPoint("BOTTOMRIGHT", boxFrame, "BOTTOMRIGHT", -26, 6)

    local edit = CreateFrame("EditBox", nil, boxScroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("GameFontHighlightSmall")
    -- A scroll child needs a size of its own. The height is deliberately far
    -- taller than the visible window so a long transfer string has room to wrap
    -- and the scroll frame does the rest.
    edit:SetSize(WIDTH - 44, 400)
    -- Transfer strings run to several hundred characters. An edit box with a
    -- default cap would silently truncate one, and a truncated string fails its
    -- checksum on the far side with no obvious cause.
    edit:SetMaxLetters(0)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    boxScroll:SetScrollChild(edit)
    widgets.edit = edit

    local status = MakeText(content, 13, 0.85, 0.85, 0.85)
    status:SetPoint("TOPLEFT", boxFrame, "BOTTOMLEFT", 0, -8)
    status:SetWidth(WIDTH)
    status:SetWordWrap(true)
    widgets.transferStatus = status

    local function SetStatus(text, r, g, b)
        status:SetText(text or "")
        status:SetTextColor(r or 0.85, g or 0.85, b or 0.85)
    end

    exportBtn:SetScript("OnClick", function()
        SetStatus("Reading your played time from the server...")
        V.Transfer.BeginExport(function(str, err)
            if not str then
                SetStatus(err or "Export failed.", 0.9, 0.4, 0.4)
                return
            end
            edit:SetText(str)
            edit:SetFocus()
            edit:HighlightText()
            SetStatus("Copy this with Ctrl+C, then paste it on the other PC and press Import.",
                0.5, 0.9, 0.5)
        end)
    end)

    importBtn:SetScript("OnClick", function()
        local text = edit:GetText()
        SetStatus("Checking the transfer against your played time...")
        V.Transfer.BeginImport(text, function(ok, message)
            if ok then
                SetStatus(message or "Verification imported.", 0.5, 0.9, 0.5)
                edit:SetText("")
                if UI.Refresh then UI.Refresh() end
            else
                SetStatus(message or "Import refused.", 0.9, 0.4, 0.4)
            end
        end)
    end)

    -- Refresh ---------------------------------------------------------------

    -- Show or hide the whole Self-Found block, moving Tracking Confidence up
    -- behind it. Anchoring is redone rather than relying on the hidden widgets
    -- collapsing, which they do not.
    local function ShowSelfFound(show)
        -- Show/Hide rather than SetShown: these are font strings, and Show and
        -- Hide are the pair every client has had on a region.
        for _, key in ipairs({ "sHeader", "sStatus", "sNote" }) do
            if show then widgets[key]:Show() else widgets[key]:Hide() end
        end
        widgets.cHeader:ClearAllPoints()
        widgets.cHeader:SetPoint("TOPLEFT",
            show and widgets.sNote or widgets.dNote, "BOTTOMLEFT", 0, -18)
    end

    function UI.Refresh()
        local record = V.GetRecord()
        if not record then
            widgets.dStatus:SetText("No record")
            widgets.dStatus:SetTextColor(0.7, 0.7, 0.7)
            widgets.dTier:SetText("")
            widgets.dNote:SetText("Rustcore has not started tracking this character yet.")
            widgets.dOrigin:SetText("")
            ShowSelfFound(false)
            widgets.bar:SetFraction(0)
            widgets.cDetail:SetText("")
            return
        end

        -- Rebuilt before anything is drawn. The derived half of a status moves
        -- without anyone writing to the record -- a level-up alone retightens
        -- the allowance -- so the cached value the panel reads below is only
        -- trustworthy if it was rebuilt this frame.
        if V.ComposeAll then V.ComposeAll() end

        local difficulty = record.difficulty or {}
        local selfFound  = record.selfFound or {}
        local timeState  = record.time or {}

        -- Difficulty. The status word is the headline and carries the status
        -- colour; the tier under it is a grey caption saying which run that
        -- verdict is about.
        local dLook = Look(difficulty.status)
        widgets.dStatus:SetText(dLook[4])
        widgets.dStatus:SetTextColor(dLook[1], dLook[2], dLook[3])

        local tier = difficulty.highestVerifiedTier or 0
        local tierName
        if V.IsCertified(difficulty.status) and tier >= 1 then
            tierName = V.GetTierName(tier)
        else
            -- Nothing is certified, so there is no certified tier to name. What
            -- the character is actually playing is still the useful caption.
            tierName = V.GetTierName(V.GetCurrentTier())
        end
        local tierLine = "Difficulty: " .. tierName
        if difficulty.permanentCapTier then
            -- Kept because a cap is a live limit on what this run can ever
            -- certify, not a tally of things that have happened to it.
            tierLine = tierLine .. "  (Capped at "
                .. V.GetTierName(difficulty.permanentCapTier)
                .. " by a death under weaker rules)"
        end
        widgets.dTier:SetText(tierLine)

        -- Gear a death marked for deletion that the player still has. Named
        -- here, under the verdict it is holding up, because that is the
        -- question it answers -- next to the playtime figures it was sitting
        -- beside an unrelated number and explaining nothing.
        local dNote = NoteFor("difficulty", difficulty, dLook)
        local owed = (V.DeathLoss and V.DeathLoss.GetPending
            and V.DeathLoss.GetPending()) or {}
        if #owed > 0 then
            local names, overdue = {}, false
            for _, row in ipairs(owed) do
                names[#names + 1] = row.name
                if row.recorded then overdue = true end
            end
            local one = #names == 1
            dNote = dNote .. "\nStill carried: " .. table.concat(names, ", ") .. "."

            if overdue then
                dNote = dNote .. (one
                    and "\nIt was held too long to be undone. Destroying it now will not restore the certification."
                    or "\nThey were held too long to be undone. Destroying them now will not restore the certification.")
            else
                local left = V.DeathLoss.GetTimeRemaining
                    and V.DeathLoss.GetTimeRemaining()
                if left and left > 0 then
                    dNote = dNote .. string.format(
                        one and "\nDestroy it within about %s of played time to keep the certification."
                            or "\nDestroy them within about %s of played time to keep the certification.",
                        FormatDuration(left))
                end
            end
        end
        widgets.dNote:SetText(dNote)

        -- Reuses record.origin, which the record has carried since it was
        -- created; nothing extra is stored or transferred for this.
        widgets.dOrigin:SetText(record.origin == "LEGACY_MIGRATION"
            and "(grandfathered)" or "")

        -- Self-Found. Follows the checkbox, not the record: switching the mode
        -- off is opting out of it, and a block reporting on a mode the player
        -- has turned off is a row of the page spent saying nothing.
        --
        -- The record is untouched by this. Nothing here decides anything -- the
        -- claim, the suspension and the loss all stand exactly as they were,
        -- and switching Self-Found back on shows them again unchanged.
        local enabled = (Rustcore and Rustcore.GetSetting and Rustcore.GetSetting("selfFound"))
            and selfFound.status ~= nil
        ShowSelfFound(enabled and true or false)
        if enabled then
            local sLook = Look(selfFound.status)
            widgets.sStatus:SetText(sLook[4])
            widgets.sStatus:SetTextColor(sLook[1], sLook[2], sLook[3])

            -- A suspension can say something more useful than "keep playing":
            -- how much longer, or what is standing in the way. It replaces the
            -- standing line but not the reason, so the cause still comes first.
            local sNote = NoteFor("selfFound", selfFound, sLook)
            if selfFound.status == V.STATUS.SUSPENDED and V.SelfFound and V.SelfFound.EvaluateRestore then
                local ok, why, remaining = V.SelfFound.EvaluateRestore()
                local line
                if ok then
                    line = "Ready to be certified again."
                elseif remaining then
                    line = string.format("About %s more clean play and this is certified again.",
                        FormatDuration(remaining))
                elseif why then
                    line = "Held back: " .. why .. "."
                end
                if line then
                    local reason = StatusReason("selfFound", selfFound)
                    sNote = reason and (reason .. "\n" .. line) or line
                end
            end
            -- The note is the whole block. What Self-Found blocks -- trading,
            -- the auction house, mail -- is the rule text on the options page,
            -- and repeating it here told the player nothing about their run.
            -- All this has to say is the verdict and what is behind it.
            widgets.sNote:SetText(sNote)
        end

        -- Tracking confidence.
        --
        -- Every figure below is worked out on the spot from the missing seconds
        -- and the character's level as it stands right now. None of it is stored
        -- anywhere, which is what lets the whole section improve: play on with
        -- Rustcore watching and the unobserved share of the run falls, the words
        -- change, and eventually the section stops having anything to say.
        local untracked = (V.Time and V.Time.GetMissingSeconds
            and V.Time.GetMissingSeconds()) or 0
        local allowed = (V.Time and V.Time.GetAllowedGap
            and V.Time.GetAllowedGap()) or 0
        local timeStatus = (V.Time and V.Time.ComponentStatus
            and V.Time.ComponentStatus()) or V.STATUS.VERIFIED

        -- Drawn against twice the allowance, which puts the certification line
        -- at the halfway mark. Running the bar to the allowance itself would
        -- bottom out the moment certification lapsed and then sit at empty
        -- however much watched play followed -- exactly when the player most
        -- needs to see the thing moving.
        local ceiling = allowed * ((V.Time and V.Time.UNVERIFIED_MULTIPLE) or 2)
        local fraction = 1
        if ceiling > 0 and untracked > 0 then
            fraction = 1 - (untracked / ceiling)
        end
        widgets.bar:SetFraction(fraction, timeStatus)

        -- The three figures the verdict is made of, on one line: what Rustcore
        -- watched, what it did not, and how much of the second it will accept.
        --
        -- Tinted rather than coloured. The two halves want telling apart at a
        -- glance, but this is a summary and not an alarm -- unobserved play is
        -- usually a crash or an evening without the addon, and painting it in
        -- warning red would say something about the player that the number
        -- itself does not. The allowance is left in the body colour because it
        -- is the yardstick, not a result.
        local cLines = {}
        cLines[1] = string.format(
            "|cffa8d4a8Observed:|r %s   |cffd4a8a8Unobserved:|r %s   Allowed tolerance: %.0f%%",
            FormatDuration(timeState.trackedSinceAnchor or 0),
            FormatDuration(untracked),
            ((V.Time and V.Time.GetTolerance and V.Time.GetTolerance()) or 0) * 100)

        -- Said of the gap and not of the player. A gap almost always means the
        -- addon was switched off or the client crashed, and a tolerated one is
        -- not a mark against anybody.
        if V.IsCertified(timeStatus) then
            if timeStatus == V.STATUS.WARNING then
                cLines[#cLines + 1] = "Some play happened while Rustcore was not "
                    .. "running. That is within tolerance and the certification stands."
            elseif untracked > 0 then
                cLines[#cLines + 1] =
                    "Rustcore has observed enough of this character to vouch for it."
            else
                cLines[#cLines + 1] =
                    "Rustcore has observed this character continuously."
            end
        else
            cLines[#cLines + 1] = "Too much of this character's play happened "
                .. "without Rustcore running for it to be certified right now. "
                .. "This is missing evidence, not a rule violation, and watched "
                .. "play earns the certification back."
        end

        -- The share itself, printed only for the character it is currently
        -- costing something. The allowance is already on the first line, so
        -- this adds the one thing that line cannot show: how far over it is,
        -- and that the bar moved because of the character's level.
        if not V.IsCertified(timeStatus) then
            local percent = V.Time and V.Time.GetMissingPercent
                and V.Time.GetMissingPercent()
            if percent then
                cLines[#cLines + 1] = string.format(
                    "Unobserved play is %.1f%% of this character's total, above what level %d allows.",
                    percent * 100, V.GetPlayerLevel and V.GetPlayerLevel() or 0)
            end
        end

        -- How much more watched play brings the share back under the line.
        --
        -- Recalculated from scratch every refresh rather than pinned when the
        -- gap opened, and it does not retreat as the player walks toward it:
        -- the missing seconds stay put while the played total grows, so every
        -- watched hour is an hour off this figure. Levelling on the way there
        -- tightens the allowance and can add to it, which is honest -- the
        -- standard genuinely did just rise -- and the anchors are close enough
        -- together that it moves by minutes, not hours.
        local needed = V.Time and V.Time.GetRequiredTracked
            and V.Time.GetRequiredTracked()
        if needed and needed > 0 then
            cLines[#cLines + 1] = string.format(
                "Continue playing with Rustcore for about %s to restore verification.",
                FormatDuration(needed))
        end

        widgets.cDetail:SetText(table.concat(cLines, "\n"))
    end

    UI.Refresh()
    return UI.Refresh
end
