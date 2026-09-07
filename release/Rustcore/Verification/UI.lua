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
-- spelling it out. Two rules make that work, and the colours follow them:
--
--   red    the run is over. Only ever used where nothing will bring it back.
--   blue   not certified yet, but still reachable by playing on.
--
-- UNVERIFIED therefore reads as the final "Not verified", and anything Rustcore
-- merely needs more time for is Uncertain instead -- which is why a suspension
-- and a late start share that word: from the player's side they are the same
-- situation, and the difference between them is Rustcore's business.
local STATUS_LOOK = {
    VERIFIED   = { 0.35, 0.9,  0.35, "Verified",     "Rustcore has detected no rule violations." },
    WARNING    = { 1.0,  0.82, 0.2,  "Verified",     "Something unexplained was noted. Certification still stands." },
    SUSPENDED  = { 0.55, 0.75, 0.95, "Uncertain",    "Not certified yet. Keep playing and it will be." },
    UNCERTAIN  = { 0.55, 0.75, 0.95, "Uncertain",    "Still being observed. Keep playing to earn certification." },
    UNVERIFIED = { 0.9,  0.3,  0.3,  "Not verified", "This run can no longer be certified." },
    FAILED     = { 0.9,  0.3,  0.3,  "Not verified", "This run can no longer be certified." },
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
    { "played time decreased",
      "Your played time went backwards, which playing cannot cause." },
    { "integrity",
      "Rustcore's saved record no longer matched its own checksum." },
    { "identity mismatch",
      "This record was made on a different character." },
    { "repair performed",
      "Your gear was repaired, which this difficulty does not allow." },
    { "repeated unexplained durability increase",
      "Durability went up more than once with no repair Rustcore could see." },
    { "Self-Found started level",
      "Self-Found was switched on too late in the run to be certified." },
    { "Self-Found switched off", "Self-Found is switched off." },
    { "Self-Found was switched off", "Self-Found is switched off." },
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
}

-- What a WARNING status is about. Named rather than counted: the question is
-- why the run is not a clean Verified, and "2" is not an answer to it.
local function WarningReason(track)
    local parts = {}
    for kind in pairs(track.warnings or {}) do
        parts[#parts + 1] = WARNING_TEXT[kind] or tostring(kind)
    end
    if #parts == 0 then return nil end
    table.sort(parts)
    return "Noted: " .. table.concat(parts, "; ") .. "."
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
    local blurb = look[5]
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

    -- 0 means nothing watched, 1 means fully within tolerance.
    function bar:SetFraction(fraction)
        fraction = math.max(0, math.min(1, tonumber(fraction) or 0))
        self.fill:SetWidth(math.max(1, (self.width - 2) * fraction))
        if fraction >= 0.75 then
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
        "Rustcore stores your certification on this computer, so a second PC "
        .. "starts out knowing nothing about this character.\n\n"
        .. "Export writes everything Rustcore has tracked -- both certifications, "
        .. "your stats, and a fresh reading of your /played time -- into one line "
        .. "of text. Import it on the other PC to continue there.\n\n"
        .. "The /played reading is what makes it trustworthy: an import is only "
        .. "accepted within 10 minutes of the export, so an old string cannot be "
        .. "used later to undo something. Clean minutes you played before "
        .. "importing are kept, not discarded.")

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
            ShowSelfFound(false)
            widgets.bar:SetFraction(0)
            widgets.cDetail:SetText("")
            return
        end

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
            tierLine = tierLine .. "  (capped at "
                .. V.GetTierName(difficulty.permanentCapTier)
                .. " by an earlier death under weaker rules)"
        end
        widgets.dTier:SetText(tierLine)
        widgets.dNote:SetText(NoteFor("difficulty", difficulty, dLook))

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

        -- Tracking confidence. The fraction is how much of the allowance is
        -- still unspent, so a full green bar means Rustcore watched essentially
        -- everything and an empty one means it lost the thread.
        local untracked = timeState.untrackedSeconds or 0
        local allowed = (V.Time and V.Time.GetAllowedGap and V.Time.GetAllowedGap()) or 1
        -- Anything under the deadband reads as full. Time.lua no longer records
        -- gaps that small, so this only shows up on a record written before that
        -- change -- but a bar sitting a hair short of the end over a few seconds
        -- of logout drift is exactly the thing the deadband exists to stop.
        local ignore = (V.Time and V.Time.GAP_IGNORE) or 60
        widgets.bar:SetFraction(untracked < ignore and 1
            or (1 - (untracked / math.max(1, allowed))))

        local band = timeState.gapBand or "OK"
        local cLines = {}
        cLines[1] = string.format("Tracked: %s     Missing: %s",
            FormatDuration(timeState.trackedSinceAnchor or 0), FormatDuration(untracked))
        if band == "OK" then
            -- Measured against the same deadband as the bar and the figure above
            -- it, so all three agree. Below it there is nothing to report, not a
            -- small amount of something.
            cLines[#cLines + 1] = untracked >= ignore
                and "Rustcore has watched enough of this character to vouch for it."
                or "Rustcore has watched this character continuously."
        elseif band == "WARNING" then
            cLines[#cLines + 1] = "Some play happened while Rustcore was not running."
        else
            cLines[#cLines + 1] = "Too much play happened without Rustcore watching to certify this character."
        end

        -- How much more play covers the missing time. The allowance is a
        -- proportion of total played time, so it grows as the character does:
        -- untracked / GAP_RATIO is the played total at which this gap is back
        -- inside tolerance, and what is left of it is what there is to play.
        --
        -- The exact allowance is deliberately not printed. A number of minutes
        -- a player is permitted to go unwatched reads as a budget to spend,
        -- which is the opposite of what it is.
        if untracked > allowed then
            local ratio = (V.Time and V.Time.GAP_RATIO) or 0.02
            local needed = (untracked / ratio) - ((V.Time and V.Time.GetLastServerPlayed
                and V.Time.GetLastServerPlayed()) or 0)
            if needed > 0 then
                cLines[#cLines + 1] = string.format(
                    "About %s more play and the missing time is back inside tolerance.",
                    FormatDuration(needed))
            end
        end

        -- Said plainly, because the bar refilling and the certification coming
        -- back are not the same thing. A gap band only ever escalates, so play
        -- that covers the gap protects what is left rather than undoing what
        -- has already been lost -- and implying otherwise would be the one
        -- thing worse than saying nothing.
        if band == "WARNING" then
            cLines[#cLines + 1] = "The note it left on the record stays either way."
        elseif band == "SEVERE" then
            cLines[#cLines + 1] = "Playing on will not bring this certification back."
        end

        widgets.cDetail:SetText(table.concat(cLines, "\n"))
    end

    UI.Refresh()
    return UI.Refresh
end
