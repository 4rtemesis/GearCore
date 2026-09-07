-- Rustcore: first-login "select your difficulty" popup
-- Shown once per character, the first time it logs in, unless already dismissed.

RustcoreDifficultyPopup = {}

local f

local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil
local HEADER_FONT_PATH = Rustcore.GetAssetPath("Font/RUSTED PERSONAL USE.ttf")
local BODY_FONT_PATH   = Rustcore.GetAssetPath("Font/BPpong.otf")
local BODY_COLOR = { 0.92, 0.89, 0.82 } -- off-white, used for the difficulty panel descriptions
local WELCOME_TEXT_COLOR = { 1, 0.82, 0 } -- yellow, used for the intro description lines

local FRAME_WIDTH, FRAME_HEIGHT = 560, 386
local PANEL_WIDTH = 150
local PANEL_HEIGHT = 118
local PANEL_GAP  = 16
local HEADER_FONT_SIZE = 38
local HEADER_Y_OFFSET = 36
local DESCRIPTION_Y_OFFSET = 82
local BODY_FONT_SIZE = 15
-- The Self-Found row sits under the panels as a secondary choice, so it is set a
-- step below the panel descriptions rather than matching them.
local SELF_FOUND_FONT_SIZE = 13
local SELF_FOUND_CHECK_SIZE = 20
local DESATURATE_DIM = 0.55
local DESATURATE_MIN = 0.18 -- floor so very dark source colors (e.g. Dust's deep red) don't desaturate to near-black

-- Grayscale-and-dim a color for the unselected-panel text state.
local function DesaturatedColor(color)
    local lum = (0.3 * color[1] + 0.59 * color[2] + 0.11 * color[3]) * DESATURATE_DIM
    lum = math.max(lum, DESATURATE_MIN)
    return { lum, lum, lum }
end

-- Same label styling as the DELETE button (RustcoreTheme.lua) so the SELECT
-- button matches it exactly.
local SELECT_FONT_PATH = Rustcore.GetAssetPath("Font/BPpong.otf")
local SELECT_FONT_SIZE = 22
local SELECT_LETTER_SPACING = 4
local SELECT_TEXT_COLOR = { 0.85, 0.85, 0.82 }

-- Only the Rusted, Broken, and Dust tiers are offered in this popup.
local PANEL_DATA = {
    {
        value = 1,
        header = "RUSTED",
        headerColor = { 0.494, 0.663, 0.337 }, -- matches options difficulty slider
        body = "No repair",
    },
    {
        value = 2,
        header = "BROKEN",
        headerColor = { 0.62, 0.58, 0.28 }, -- matches options difficulty slider
        body = "Lose a piece of gear on death",
    },
    {
        value = 5,
        header = "DUST",
        headerColor = { 0.52, 0.07, 0.06 }, -- matches options difficulty slider
        body = "Lose ALL gear on death",
    },
}

local DEFAULT_PANEL_INDEX = 2 -- Broken

-- Native SetShadowColor/SetShadowOffset doesn't render on this client, so the
-- shadow is faked with a second, black, offset copy of the text drawn
-- underneath the real one instead.
local function BuildSpacedHeader(panel, text, color)
    local shadowFs = panel:CreateFontString(nil, "OVERLAY")
    shadowFs:SetFont(HEADER_FONT_PATH, HEADER_FONT_SIZE, "")
    shadowFs:SetTextColor(0, 0, 0, 0.75)
    shadowFs:SetJustifyH("CENTER")
    shadowFs:SetPoint("TOP", panel, "TOP", 1, -HEADER_Y_OFFSET - 1)
    shadowFs:SetText(text)
    shadowFs:Show()

    local fs = panel:CreateFontString(nil, "OVERLAY")
    fs:SetFont(HEADER_FONT_PATH, HEADER_FONT_SIZE, "")
    fs:SetTextColor(unpack(color))
    fs:SetJustifyH("CENTER")
    fs:SetPoint("TOP", panel, "TOP", 0, -HEADER_Y_OFFSET)
    fs:SetText(text)
    fs:Show()

    return { fs }
end

-- Same letter-by-letter layout as BuildSpacedHeader, but matching the DELETE
-- button's exact font/size/spacing/shadow (RustcoreTheme.lua) so SELECT
-- looks identical to it.
local function BuildSelectButtonText(button, text)
    local widths, letters, shadows, totalWidth = {}, {}, {}, 0
    for i = 1, #text do
        local sh = button:CreateFontString(nil, "OVERLAY")
        sh:SetFont(SELECT_FONT_PATH, SELECT_FONT_SIZE, "")
        sh:SetTextColor(0, 0, 0, 1)
        sh:SetText(text:sub(i, i))
        sh:Show()
        shadows[i] = sh

        local fs = button:CreateFontString(nil, "OVERLAY")
        fs:SetFont(SELECT_FONT_PATH, SELECT_FONT_SIZE, "")
        fs:SetTextColor(unpack(SELECT_TEXT_COLOR))
        fs:SetText(text:sub(i, i))
        fs:Show()
        local w = fs:GetStringWidth()
        if not w or w <= 0 then
            w = SELECT_FONT_SIZE * 0.55
        end
        widths[i] = w
        letters[i] = fs
        totalWidth = totalWidth + w + (i < #text and SELECT_LETTER_SPACING or 0)
    end

    local x = -totalWidth / 2
    for i = 1, #text do
        local fs = letters[i]
        local sh = shadows[i]
        fs:SetPoint("LEFT", button, "CENTER", x, 0)
        sh:SetPoint("LEFT", button, "CENTER", x + 1.5, -1.5)
        x = x + widths[i] + SELECT_LETTER_SPACING
    end
end

-- Recompute a panel's header/body text colors from its selected + hovering
-- state. Hovering an unselected panel fully removes its desaturation, same
-- as being selected.
local function ApplyPanelTextColors(panel)
    local headerColor, bodyColor
    if panel.selected or panel.hovering then
        headerColor = panel.headerColor
        bodyColor = BODY_COLOR
    else
        headerColor = DesaturatedColor(panel.headerColor)
        bodyColor = DesaturatedColor(BODY_COLOR)
    end
    for _, letter in ipairs(panel.headerLetters) do
        letter:SetTextColor(unpack(headerColor))
    end
    panel.body:SetTextColor(unpack(bodyColor))
end

local function BuildPanel(parent, index, data)
    local panel = CreateFrame("Button", nil, parent)
    panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)

    panel.headerColor = data.headerColor
    panel.headerLetters = BuildSpacedHeader(panel, data.header, data.headerColor)

    -- Fake shadow (see BuildSpacedHeader note): black copy offset behind
    -- the real body text, since native shadowing doesn't render here.
    -- Sized with a single anchor + explicit SetWidth (like diffDesc in
    -- RustcoreOptions.lua) rather than a two-point TOPLEFT/BOTTOMRIGHT
    -- anchor: on a freshly built, never-yet-rendered frame the dual-anchor
    -- form was resolving to zero width, wrapping every word onto its own
    -- line and rendering nothing at all.
    local bodyShadow = panel:CreateFontString(nil, "OVERLAY")
    bodyShadow:SetPoint("TOP", panel, "TOP", 1, -DESCRIPTION_Y_OFFSET - 1)
    bodyShadow:SetWidth(PANEL_WIDTH - 20)
    bodyShadow:SetFont(BODY_FONT_PATH, BODY_FONT_SIZE, "")
    bodyShadow:SetTextColor(0, 0, 0, 0.75)
    bodyShadow:SetJustifyH("CENTER")
    bodyShadow:SetJustifyV("TOP")
    bodyShadow:SetWordWrap(true)
    bodyShadow:SetText(data.body)

    local body = panel:CreateFontString(nil, "OVERLAY")
    body:SetPoint("TOP", panel, "TOP", 0, -DESCRIPTION_Y_OFFSET)
    body:SetWidth(PANEL_WIDTH - 20)
    body:SetFont(BODY_FONT_PATH, BODY_FONT_SIZE, "")
    body:SetTextColor(unpack(BODY_COLOR))
    body:SetJustifyH("CENTER")
    body:SetJustifyV("TOP")
    body:SetWordWrap(true)
    body:SetText(data.body)
    panel.body = body

    panel:SetScript("OnClick", function()
        PlaySoundFile(Rustcore.GetAssetPath("Audio/ticksound2.wav"), "Master")
        RustcoreDifficultyPopup.SetSelected(index)
    end)

    panel:SetScript("OnEnter", function()
        panel.hovering = true
        ApplyPanelTextColors(panel)
    end)
    panel:SetScript("OnLeave", function()
        panel.hovering = false
        ApplyPanelTextColors(panel)
    end)

    return panel
end

local function MarkSeen()
    Rustcore.SetProfileValue("hasSeenDifficultyPopup", true)
end

local function BuildFrame()
    local frame = CreateFrame("Frame", "RustcoreDifficultyPopupFrame", UIParent, backdropTemplate)
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    -- FULLSCREEN_DIALOG sits above the DIALOG strata used by the options
    -- window, so the popup stays on top even if options is opened over it.
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    RustcoreTheme.ApplyFrameSkin(frame)

    -- Match the options window: difficulty artwork below a fixed dark overlay.
    local bgShade = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
    bgShade:SetAllPoints(frame.rustcoreThemeBackground)
    bgShade:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    bgShade:SetVertexColor(0, 0, 0, 0.62)

    local WELCOME_LINE1 = "Your gear is temporary. Your scars are not."
    local WELCOME_LINE2 = "Choose the hardship that will define your journey."
    local WELCOME_NOTE  = "(You can change these settings and find more customization in the options window.)"

    -- Fake shadow (see BuildSpacedHeader note): black copy offset behind
    -- the real text, since native shadowing doesn't render here.
    local titleShadow = frame:CreateFontString(nil, "OVERLAY")
    titleShadow:SetPoint("TOP", frame, "TOP", 1, -41)
    titleShadow:SetFont(BODY_FONT_PATH, 26, "")
    titleShadow:SetTextColor(0, 0, 0, 0.75)
    titleShadow:SetJustifyH("CENTER")
    titleShadow:SetWidth(FRAME_WIDTH - 40)
    titleShadow:SetWordWrap(false)
    titleShadow:SetText("RUSTCORE")

    local title = frame:CreateFontString(nil, "OVERLAY")
    title:SetPoint("TOP", frame, "TOP", 0, -40)
    title:SetFont(BODY_FONT_PATH, 26, "")
    title:SetTextColor(1, 1, 1)
    title:SetJustifyH("CENTER")
    title:SetWidth(FRAME_WIDTH - 40)
    title:SetWordWrap(false)
    title:SetText("RUSTCORE")

    -- Line 2 uses a smaller font than line 1 so the whole sentence fits on one line.
    local line1Shadow = frame:CreateFontString(nil, "OVERLAY")
    line1Shadow:SetPoint("TOP", title, "BOTTOM", 1, -10)
    line1Shadow:SetFont(BODY_FONT_PATH, 18, "")
    line1Shadow:SetTextColor(0, 0, 0, 0.75)
    line1Shadow:SetJustifyH("CENTER")
    line1Shadow:SetWidth(FRAME_WIDTH - 40)
    line1Shadow:SetWordWrap(false)
    line1Shadow:SetText(WELCOME_LINE1)

    local line1 = frame:CreateFontString(nil, "OVERLAY")
    line1:SetPoint("TOP", title, "BOTTOM", 0, -9)
    line1:SetFont(BODY_FONT_PATH, 18, "")
    line1:SetTextColor(unpack(WELCOME_TEXT_COLOR))
    line1:SetJustifyH("CENTER")
    line1:SetWidth(FRAME_WIDTH - 40)
    line1:SetWordWrap(false)
    line1:SetText(WELCOME_LINE1)

    local line2Shadow = frame:CreateFontString(nil, "OVERLAY")
    line2Shadow:SetPoint("TOP", line1, "BOTTOM", 1, -3)
    line2Shadow:SetFont(BODY_FONT_PATH, 18, "")
    line2Shadow:SetTextColor(0, 0, 0, 0.75)
    line2Shadow:SetJustifyH("CENTER")
    line2Shadow:SetWidth(FRAME_WIDTH - 40)
    line2Shadow:SetWordWrap(false)
    line2Shadow:SetText(WELCOME_LINE2)

    local line2 = frame:CreateFontString(nil, "OVERLAY")
    line2:SetPoint("TOP", line1, "BOTTOM", 0, -2)
    line2:SetFont(BODY_FONT_PATH, 18, "")
    line2:SetTextColor(unpack(WELCOME_TEXT_COLOR))
    line2:SetJustifyH("CENTER")
    line2:SetWidth(FRAME_WIDTH - 40)
    line2:SetWordWrap(false)
    line2:SetText(WELCOME_LINE2)

    local closeBtn = CreateFrame("Button", nil, frame)
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -6)
    closeBtn:SetFrameLevel(frame:GetFrameLevel() + 10)
    closeBtn:SetScript("OnClick", function()
        MarkSeen()
        frame:Hide()
    end)
    RustcoreTheme.SkinExitButton(closeBtn)

    local noteShadow = frame:CreateFontString(nil, "OVERLAY")
    noteShadow:SetPoint("TOP", line2, "BOTTOM", 1, -6)
    noteShadow:SetFont(BODY_FONT_PATH, 11, "")
    noteShadow:SetTextColor(0, 0, 0, 0.75)
    noteShadow:SetJustifyH("CENTER")
    noteShadow:SetWidth(FRAME_WIDTH - 60)
    noteShadow:SetWordWrap(true)
    noteShadow:SetText(WELCOME_NOTE)

    local note = frame:CreateFontString(nil, "OVERLAY")
    note:SetPoint("TOP", line2, "BOTTOM", 0, -5)
    note:SetFont(BODY_FONT_PATH, 11, "")
    note:SetTextColor(0.6, 0.6, 0.6)
    note:SetJustifyH("CENTER")
    note:SetWidth(FRAME_WIDTH - 60)
    note:SetWordWrap(true)
    note:SetText(WELCOME_NOTE)

    local panelRow = CreateFrame("Frame", nil, frame)
    panelRow:SetPoint("TOP", note, "BOTTOM", 0, 8)
    panelRow:SetSize(PANEL_WIDTH * 3 + PANEL_GAP * 2, PANEL_HEIGHT)

    frame.panels = {}
    for i, data in ipairs(PANEL_DATA) do
        local panel = BuildPanel(panelRow, i, data)
        panel:SetPoint("TOPLEFT", panelRow, "TOPLEFT", (i - 1) * (PANEL_WIDTH + PANEL_GAP), 0)
        frame.panels[i] = panel
    end

    -- Self-Found, offered alongside the difficulty because this is the one
    -- moment the choice is free: both are cleanest started at level 1, and a
    -- player who has to go and find the option later has usually already
    -- traded, mailed or bought something.
    --
    -- Nothing is applied here. Like the difficulty panels, the tick is only an
    -- intent until Select commits it -- a popup that changed a setting the
    -- moment it was touched would leave a half-made choice behind if it were
    -- closed.
    local sfLabel = frame:CreateFontString(nil, "OVERLAY")
    sfLabel:SetFont(BODY_FONT_PATH, SELF_FOUND_FONT_SIZE, "")
    sfLabel:SetTextColor(unpack(BODY_COLOR))
    sfLabel:SetText("Self-Found")
    -- Anchored right of centre by half the checkbox and its gap, so the pair
    -- reads as centred under the panels.
    sfLabel:SetPoint("TOP", panelRow, "BOTTOM", 13, -22)

    -- The label is two words, so what the mode actually costs lives in a
    -- tooltip. Written as the restrictions themselves rather than a summary:
    -- this is the moment the player decides, and "everything you own, you found
    -- yourself" sounds appealing right up until the auction house is closed.
    local SELF_FOUND_TOOLTIP =
        "Everything your character owns must be found by that character.\n\n"
        .. "While Self-Found is on:\n"
        .. "|cffff8080-|r Trading with other players is blocked\n"
        .. "|cffff8080-|r The auction house is blocked\n"
        .. "|cffff8080-|r Mail from players and the auction house is locked, "
        .. "including anything attached to it\n"
        .. "|cffff8080-|r Sending items or gold by mail is blocked"

    local sfCheck = CreateFrame("CheckButton", nil, frame)
    sfCheck:SetSize(SELF_FOUND_CHECK_SIZE, SELF_FOUND_CHECK_SIZE)
    sfCheck:SetPoint("RIGHT", sfLabel, "LEFT", -6, 1)
    RustcoreTheme.SkinCheckbox(sfCheck)
    sfCheck:SetChecked(Rustcore.GetSetting("selfFound") and true or false)
    sfCheck:SetScript("OnClick", function()
        PlaySoundFile(Rustcore.GetAssetPath("Audio/ticksound2.wav"), "Master")
    end)

    -- Reaches out over the label, so the words are clickable and hoverable too
    -- rather than only the small box beside them.
    sfCheck:SetHitRectInsets(0, -72, 0, 0)

    local function ShowSelfFoundTooltip(owner)
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:SetText("Self-Found", 1, 0.82, 0)
        GameTooltip:AddLine(SELF_FOUND_TOOLTIP, 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end
    sfCheck:SetScript("OnEnter", function(self) ShowSelfFoundTooltip(self) end)
    sfCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame.selfFoundCheck = sfCheck

    local selectBtn = CreateFrame("Button", "RustcoreDifficultySelectButton", frame)
    selectBtn:SetSize(150, 56)
    -- Clears the panels, the tick row and the gaps either side of it.
    selectBtn:SetPoint("TOP", panelRow, "BOTTOM", 0, -58)
    RustcoreTheme.SkinDeleteButton(selectBtn)
    -- Built directly here (same font/size/spacing/shadow as the DELETE
    -- button's own LayoutDeleteButtonLetters) instead of going through
    -- SkinDeleteButton's SetText hook, which wasn't rendering a shadow here.
    BuildSelectButtonText(selectBtn, "SELECT")
    selectBtn:SetScript("OnClick", function()
        local data = PANEL_DATA[frame.selectedIndex or DEFAULT_PANEL_INDEX]
        Rustcore.SetSetting("difficulty", data.value)
        -- Only written when it differs, so an untouched tick on a character
        -- that already has Self-Found on does not count as switching it on
        -- again -- which the verification track would read as a fresh claim.
        local wantSelfFound = sfCheck:GetChecked() and true or false
        if (Rustcore.GetSetting("selfFound") and true or false) ~= wantSelfFound then
            Rustcore.SetSetting("selfFound", wantSelfFound)
        end
        PlaySoundFile(Rustcore.GetAssetPath("Audio/difficultysound.wav"), "Master")
        MarkSeen()
        frame:Hide()
    end)

    frame:Hide()
    return frame
end

function RustcoreDifficultyPopup.SetSelected(index)
    if not f then return end
    f.selectedIndex = index
    local selectedData = PANEL_DATA[index]
    if selectedData then
        RustcoreTheme.SetDifficultyBackground(f, selectedData.value)
    end
    for i, panel in ipairs(f.panels) do
        local selected = (i == index)
        panel.selected = selected
        ApplyPanelTextColors(panel)
    end
end

function RustcoreDifficultyPopup.Show()
    if not f then f = BuildFrame() end
    RustcoreDifficultyPopup.SetSelected(DEFAULT_PANEL_INDEX)
    -- Seeded from the live setting each time, so reopening the popup shows what
    -- is actually in force rather than whatever was last ticked and abandoned.
    if f.selfFoundCheck then
        f.selfFoundCheck:SetChecked(Rustcore.GetSetting("selfFound") and true or false)
    end
    f:Show()
end

function RustcoreDifficultyPopup.MaybeShowOnLogin()
    if Rustcore.GetProfileValue("hasSeenDifficultyPopup") then return end
    RustcoreDifficultyPopup.Show()
end
