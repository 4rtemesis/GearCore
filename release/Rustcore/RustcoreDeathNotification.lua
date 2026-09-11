-- Rustcore: center-screen death notification plate, replaces the native
-- raid warning "another Rustcore player died" events (RustcoreBroadcast.Display).
--
-- The plate is lowered in on its chains from above the top of the screen rather
-- than simply appearing: a 1.2 second fall, a metal impact, and a shake as the
-- chains go taut. It leaves the same way, hauled back up out of frame on the
-- chains rather than fading out where it hangs.

RustcoreDeathNotification = {}

local notifFrame

local BODY_FONT_PATH = Rustcore.GetAssetPath("Font/BPpong.otf")
local ART_PATH = Rustcore.GetAssetPath("UI/Deathplatewithchains.tga")
local IMPACT_SOUND_PATH = Rustcore.GetAssetPath("Audio/MetalDrum.wav")
local CHAIN_SOUND_PATH = Rustcore.GetAssetPath("Audio/Chains.wav")

-- The art is a 2000x1500 canvas holding two chains that run off the top edge and
-- the plate hanging beneath them. Only the plate carries content, so everything
-- below is expressed as a fraction of the whole canvas and measured off it
-- directly: the plate's opaque bounds are x[68,1929] y[845,1399].
local TEXTURE_WIDTH, TEXTURE_HEIGHT = 2000, 1500
local PLATE_LEFT_FRAC, PLATE_RIGHT_FRAC = 68 / TEXTURE_WIDTH, 1929 / TEXTURE_WIDTH

-- The plate is sized, and the canvas around it follows -- sizing the canvas
-- instead would silently shrink the readable part by the height of the chains.
--
-- The chains are part of the same canvas, so shrinking the plate shortens them
-- too and the whole assembly hangs higher up the screen. That is wanted here:
-- at 540 the plate sat far enough down to read as an interruption.
--
-- The type does not follow the plate down. Below a certain size a death notice
-- stops being read at a glance and starts being squinted at, which is the one
-- thing this frame exists to avoid, so the last trim came out of the margin
-- instead.
local PLATE_WIDTH = 344
local FRAME_WIDTH = PLATE_WIDTH / (PLATE_RIGHT_FRAC - PLATE_LEFT_FRAC)
local FRAME_HEIGHT = FRAME_WIDTH * (TEXTURE_HEIGHT / TEXTURE_WIDTH)

-- The canvas top sits on the screen top, so the chains enter frame at the very
-- edge and read as coming from somewhere above it. That also fixes where the
-- plate hangs -- 845/1500 of the way down the canvas, a little under a third of
-- the screen -- which is why there is no separate anchor fraction any more: the
-- chain length in the art decides it. Raise this to hang the assembly lower.
local REST_TOP_OFFSET = 0

-- Content sits inside the plate's recessed inner panel, which spans y 0.613 to
-- 0.893 of the canvas: the two lines centred as a group in that band. A death
-- with no item loss shows one line, so that case gets its own centred position
-- rather than holding the top slot of a pair and leaving the lower half empty.
--
-- The item icon that used to head this group is gone, and its share of the panel
-- goes to the type. Scaling the old 17 down with the plate would have landed at
-- 12 and kept the text exactly as legible as it already was; the panel has the
-- room, so it only comes down to 15.
--
-- The margin absorbs what the type will not. With nothing but text inside, the
-- plate need not hold a square clear, and holding the text width steady while
-- the plate narrows is what keeps a line from wrapping where it did not before
-- -- the wrap, not the plate, is what would actually cost legibility here.
local LINE1_Y_FRACTION = 0.695
local SOLO_LINE_Y_FRACTION = 0.725
local LINE_GAP = 5
local TEXT_WIDTH = PLATE_WIDTH - 34
local LINE1_FONT_SIZE = 15
local LINE2_FONT_SIZE = 15

-- The fall. Distance is the whole canvas plus a margin, so the lowest point of
-- the plate starts clear of the screen edge and nothing is visible until it
-- swings into frame.
local DROP_DURATION = 1.2
local DROP_DISTANCE = FRAME_HEIGHT + 20

local DISPLAY_DURATION = 7.5

-- The exit covers the same distance in less time than the fall. A fall is only
-- released; being pulled up is worked at, and a retract that took as long as the
-- drop read as the plate drifting off rather than as something hauling it.
local RETRACT_DURATION = 0.9

-- The chain clip outlasts the lift, so it is faded rather than left to finish.
-- The sound belongs to the plate leaving; carrying on over an empty screen after
-- it has gone turns a departure into a loose end. Timed to fall silent a little
-- before the retract ends, since the plate clears the top edge well before the
-- easing is finished with it.
local CHAIN_FADE_AT = 0.35
local CHAIN_FADE_MS = 400

local function ClassColorCode(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return "|cffffffff" end
    return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

-- Shadow copies must not inherit the real text's embedded color escapes
-- (class color, item rarity color) or they'd render in that color instead
-- of solid black - strip them down to the plain visible characters.
local function StripColorCodes(text)
    if not text then return text end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|H.-|h", "")
    text = text:gsub("|h", "")
    text = text:gsub("|r", "")
    return text
end

-- Native SetShadowColor/SetShadowOffset doesn't render on this client (see
-- RustcoreDifficultyPopup.lua's BuildSpacedHeader), so the shadow is faked
-- with a second, black, offset copy of the text drawn underneath the real one.
local function CreateShadowedFontString(parent, fontSize)
    local shadow = parent:CreateFontString(nil, "OVERLAY")
    shadow:SetFont(BODY_FONT_PATH, fontSize, "")
    shadow:SetTextColor(0, 0, 0, 0.75)
    shadow:SetJustifyH("CENTER")
    shadow:SetWordWrap(true)

    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(BODY_FONT_PATH, fontSize, "")
    fs:SetTextColor(1, 1, 1)
    fs:SetJustifyH("CENTER")
    fs:SetWordWrap(true)

    fs.shadow = shadow
    return fs
end

local function SetShadowedText(fs, text)
    fs:SetText(text)
    fs.shadow:SetText(StripColorCodes(text))
end

local function SetShadowedShown(fs, shown)
    if shown then
        fs:Show()
        fs.shadow:Show()
    else
        fs:Hide()
        fs.shadow:Hide()
    end
end

-- Both copies move together, the shadow one pixel down and right of the real
-- text. Re-anchoring is needed because the single-line layout sits lower than
-- the first of two lines does.
local function PlaceShadowedLine(fs, parent, yFraction)
    local y = -(FRAME_HEIGHT * yFraction)
    fs:ClearAllPoints()
    fs:SetPoint("TOP", parent, "TOP", 0, y)
    fs.shadow:ClearAllPoints()
    fs.shadow:SetPoint("TOP", parent, "TOP", 1, y - 1)
end

-- The second line hangs off the bottom of the first rather than off a fraction
-- of its own. On the 540 plate a wrap was the rare case; at 378 a long name and
-- a long killer will reach the edge often, and a fixed fraction would have drawn
-- the second line straight through the wrapped tail of the first.
local function PlaceLineUnder(fs, above)
    fs:ClearAllPoints()
    fs:SetPoint("TOP", above, "BOTTOM", 0, -LINE_GAP)
    fs.shadow:ClearAllPoints()
    fs.shadow:SetPoint("TOP", above, "BOTTOM", 1, -LINE_GAP - 1)
end

-- ── Impact ──────────────────────────────────────────────────────────────────

-- The shake at the bottom of the fall. Translation animations offset a frame
-- visually without touching its anchor, so this composes with the drop below
-- rather than fighting it -- but only if the offsets sum to zero on both axes,
-- or the plate would finish the shake somewhere other than where it landed.
--
-- The first step overshoots downward and the second pulls back past the resting
-- point: that is the chains going taut, and it is what makes the stop read as a
-- weight arriving rather than an animation ending.
local function PlayImpactShake(frame)
    if not frame.impactShake then
        local ag = frame:CreateAnimationGroup()
        local function Step(order, dx, dy, duration)
            local t = ag:CreateAnimation("Translation")
            t:SetOrder(order)
            t:SetDuration(duration)
            t:SetOffset(dx, dy)
        end
        Step(1, 0, -7, 0.05)
        Step(2, 3, 9, 0.07)
        Step(3, -4, -5, 0.06)
        Step(4, 3, 3, 0.05)
        Step(5, -2, -1, 0.05)
        Step(6, 0, 1, 0.04)
        frame.impactShake = ag
    end
    frame.impactShake:Stop()
    frame.impactShake:Play()
end

local function SetDropOffset(frame, above)
    frame:ClearAllPoints()
    frame:SetPoint("TOP", UIParent, "TOP", 0, above - REST_TOP_OFFSET)
end

-- ── Exit ────────────────────────────────────────────────────────────────────

-- Eased out where the drop is eased in, because that is the difference between
-- the two movements: a falling plate starts at rest, a hauled one starts at
-- whatever speed the pull gives it. Most of the distance goes in the first
-- third, so it reads as slack coming up hard and then a steady lift, and by the
-- time it slows the plate is already past the top edge.
local function OnRetractUpdate(frame)
    local progress = (GetTime() - frame.retractStart) / RETRACT_DURATION
    if progress >= 1 then
        frame:SetScript("OnUpdate", nil)
        SetDropOffset(frame, 0)
        frame:Hide()
        return
    end
    if progress < 0 then progress = 0 end
    SetDropOffset(frame, DROP_DISTANCE * progress * (2 - progress))
end

-- Fading the clip needs the handle PlaySoundFile hands back, and neither that
-- nor StopSound is guaranteed on every client this runs on. A missing one costs
-- the fade and nothing else: the clip plays out the way it used to.
local function FadeChains(handle)
    if not handle or not StopSound then return end
    if not (C_Timer and C_Timer.After) then return end
    C_Timer.After(CHAIN_FADE_AT, function() StopSound(handle, CHAIN_FADE_MS) end)
end

-- The same chain clip as the drop, because it is the same chains doing the same
-- work in the other direction. The plate itself does not fade: it is being taken
-- away, and dimming it on the way out would say it had never quite been there.
local function StartRetract(frame)
    frame.hideTimer = nil
    if Rustcore.GetSetting("showDeathWarningSound") then
        local _, handle = PlaySoundFile(CHAIN_SOUND_PATH, "Master")
        FadeChains(handle)
    end
    frame.retractStart = GetTime()
    frame:SetScript("OnUpdate", OnRetractUpdate)
end

-- Everything that happens when the plate arrives: the drum, the shake, and the
-- start of the clock that takes it away again. The display time is counted from
-- the landing rather than from the death, so a player who looks up at the sound
-- still gets the full DISPLAY_DURATION to read it.
local function Land(frame)
    frame:SetScript("OnUpdate", nil)
    SetDropOffset(frame, 0)

    if Rustcore.GetSetting("showDeathWarningSound") then
        PlaySoundFile(IMPACT_SOUND_PATH, "Master")
    end
    PlayImpactShake(frame)

    frame.hideTimer = C_Timer.NewTimer(DISPLAY_DURATION, function()
        StartRetract(frame)
    end)
end

-- Squared easing, because that is what falling does: no speed at the top, most
-- of the distance covered in the last third, and full speed at the bottom. An
-- eased-out stop would look like the plate was being set down by hand.
local function OnDropUpdate(frame)
    local progress = (GetTime() - frame.dropStart) / DROP_DURATION
    if progress >= 1 then
        Land(frame)
        return
    end
    if progress < 0 then progress = 0 end
    SetDropOffset(frame, DROP_DISTANCE * (1 - progress * progress))
end

local function BuildFrame()
    local f = CreateFrame("Frame", "RustcoreDeathNotificationFrame", UIParent)
    f:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    f:SetFrameStrata("HIGH")
    SetDropOffset(f, 0)

    local art = f:CreateTexture(nil, "BACKGROUND")
    art:SetAllPoints(f)
    art:SetTexture(ART_PATH)
    f.art = art

    local line1 = CreateShadowedFontString(f, LINE1_FONT_SIZE)
    line1:SetWidth(TEXT_WIDTH)
    line1.shadow:SetWidth(TEXT_WIDTH)
    PlaceShadowedLine(line1, f, LINE1_Y_FRACTION)
    f.line1 = line1

    local line2 = CreateShadowedFontString(f, LINE2_FONT_SIZE)
    line2:SetWidth(TEXT_WIDTH)
    line2.shadow:SetWidth(TEXT_WIDTH)
    PlaceLineUnder(line2, line1)
    f.line2 = line2

    f:Hide()
    return f
end

local function EnsureFrame()
    if not notifFrame then
        notifFrame = BuildFrame()
    end
    return notifFrame
end

function RustcoreDeathNotification.Show(d)
    if not d or not d.name then return end
    local f = EnsureFrame()

    -- A second death arriving mid-animation restarts the whole thing from above
    -- the screen. The retract needs no unwinding of its own -- it lives entirely
    -- in the OnUpdate that the drop is about to overwrite -- but its timer and
    -- the impact shake are both still owed a stop.
    if f.hideTimer then f.hideTimer:Cancel() end
    if f.impactShake then f.impactShake:Stop() end

    local srcStr = (d.source and d.source ~= "" and d.source ~= "Unknown") and d.source or "unknown"
    local hasLoss = d.count and d.count > 0

    -- The same sentence as the chat line in RustcoreBroadcast.Display, broken at
    -- its comma. One death described in two different phrasings read as two
    -- separate reports of it. Level and zone stay out: the plate is the glance,
    -- the chat line is the record.
    local nameStr = ClassColorCode(d.class) .. d.name .. "|r"

    if hasLoss then
        local itemStr = (d.link and d.link ~= "") and d.link or "an item"
        local countStr = d.count .. (d.count == 1 and " item" or " items")
        SetShadowedText(f.line1, nameStr .. " died to " .. srcStr .. ",")
        SetShadowedText(f.line2, "losing " .. countStr .. ", including " .. itemStr .. ".")
        SetShadowedShown(f.line2, true)
        PlaceShadowedLine(f.line1, f, LINE1_Y_FRACTION)
    else
        -- The comma has nothing to carry on to, so the sentence closes here.
        SetShadowedText(f.line1, nameStr .. " died to " .. srcStr .. ".")
        SetShadowedShown(f.line2, false)
        -- One line, so it centres on the panel instead of holding the top slot
        -- of a pair and leaving the bottom half of the plate empty.
        PlaceShadowedLine(f.line1, f, SOLO_LINE_Y_FRACTION)
    end

    f:SetAlpha(1)
    SetDropOffset(f, DROP_DISTANCE)
    f:Show()

    -- Chains first, over the fall itself; the drum lands with the plate. The
    -- clip is a shade over the drop duration, so it is still running when the
    -- plate arrives rather than leaving a silent beat before the impact.
    if Rustcore.GetSetting("showDeathWarningSound") then
        PlaySoundFile(CHAIN_SOUND_PATH, "Master")
    end

    f.dropStart = GetTime()
    f:SetScript("OnUpdate", OnDropUpdate)
end
