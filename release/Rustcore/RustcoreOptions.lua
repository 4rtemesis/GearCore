-- Rustcore: Options window
-- Accessible via /rustcore or /rc

RustcoreOptions = {}

local optFrame

local DIFF_LABELS = { [1]="Rusted", [2]="Broken", [3]="Shattered", [4]="Crumbling", [5]="Dust" }
local DIFF_DESCS  = {
    [1] = "Only repair is blocked. No items are lost on death.",
    [2] = "Lose 1 random equipped item on death.",
    [3] = "Lose 25% of your equipped items on death (rounded up).",
    [4] = "Lose 50% of your equipped items on death (rounded up).",
    [5] = "Lose every equipped item on death.",
}
-- Shared with the stats counters, which tint themselves from the same palette.
local DIFF_COLORS = Rustcore.DIFFICULTY_COLORS

local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil
local DEFAULT_TITLE_TEXT = "OPTIONS"
local COMBAT_NOTE_TEXT = "Settings locked in combat"
local RUSTED_FONT_PATH = Rustcore.GetAssetPath("Font/RUSTED PERSONAL USE.ttf")
local BODY_FONT_PATH = Rustcore.GetAssetPath("Font/BPpong.otf")
local TITLE_COLOR = { 1, 1, 1 }

local function ApplyBodyFont(fontString, size)
    if not fontString then return end
    fontString:SetFont(BODY_FONT_PATH, math.max(10, (size or 18) - 2), "")
end

local function ApplyDifficultyLabelStyle(slider, value)
    local label = slider and slider.GetName and _G[slider:GetName().."Text"]
    if not label then return end

    local v = math.max(1, math.min(5, math.floor((value or 1) + 0.5)))
    local color = DIFF_COLORS[v] or DIFF_COLORS[1]
    label:SetWidth(220)
    label:SetText(DIFF_LABELS[v])
    label:SetFont(RUSTED_FONT_PATH, 34, "")
    label:SetTextColor(color[1], color[2], color[3])
    label:SetShadowColor(0, 0, 0, 1)
    label:SetShadowOffset(2, -2)
end

-- Takes over the difficulty title slot (normally "Rusted"/"Broken"/etc, styled
-- via ApplyDifficultyLabelStyle) while settings are locked, instead of showing
-- a separate combat-lock note elsewhere on the panel. Sized up and outlined
-- so it reads clearly in that larger title slot instead of looking muted.
--
-- Tinted from the vivid palette, not the earthy one the difficulty title uses.
-- The earthy colours are chosen to sit back behind a large display face, which
-- is the wrong job here -- at the Dust tier in particular the title colour is a
-- near-black red, and a notice nobody can read is worse than no notice at all.
local function ApplyCombatLockLabelStyle(slider, value)
    local label = slider and slider.GetName and _G[slider:GetName().."Text"]
    if not label then return end

    local v = math.max(1, math.min(5, math.floor((value or 1) + 0.5)))
    local palette = Rustcore.DIFFICULTY_COLORS_VIVID or DIFF_COLORS
    local color = palette[v] or palette[1]
    label:SetWidth(340)
    label:SetText(COMBAT_NOTE_TEXT)
    label:SetFont(BODY_FONT_PATH, 24, "OUTLINE")
    label:SetTextColor(color[1], color[2], color[3])
    label:SetShadowColor(0, 0, 0, 1)
    label:SetShadowOffset(2, -2)
end

local function SettingsLocked()
    return Rustcore and Rustcore.SettingsLocked and Rustcore.SettingsLocked()
end

local function ApplyDifficultyValue(slider, diffDesc, value)
    local v = math.max(1, math.min(5, math.floor(value + 0.5)))
    local previous = Rustcore.GetSetting("difficulty")
    if math.abs((slider:GetValue() or v) - v) > 0.001 then
        slider:SetValue(v)
        return
    end

    if previous == v then
        ApplyDifficultyLabelStyle(slider, v)
        diffDesc:SetText(DIFF_DESCS[v])
        local parent = slider:GetParent()
        if parent then
            RustcoreTheme.SetDifficultyBackground(parent, v)
        end
        return
    end

    if not Rustcore.SetSetting("difficulty", v) then
        local current = Rustcore.GetSetting("difficulty")
        if math.abs((slider:GetValue() or current) - current) > 0.001 then
            slider:SetValue(current)
        end
        return
    end
    PlaySoundFile(Rustcore.GetAssetPath("Audio/difficultysound.wav"), "Master")
    ApplyDifficultyLabelStyle(slider, v)
    diffDesc:SetText(DIFF_DESCS[v])
    local parent = slider:GetParent()
    if parent then
        RustcoreTheme.SetDifficultyBackground(parent, v)
    end
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function MakeCheckbox(parent, labelText, tooltipText, anchorTo, yOff, settingKey, xOff, size, fontSize)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(size or 26, size or 26)
    cb:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", xOff or 0, yOff)

    RustcoreTheme.SkinCheckbox(cb)

    local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    lbl:SetText(labelText)
    ApplyBodyFont(lbl, fontSize or 17)
    -- Exposed so a caller can hang an annotation off the end of the label rather
    -- than on a line of its own.
    cb.label = lbl

    if tooltipText then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltipText, nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    cb:SetScript("OnClick", function(self)
        PlaySoundFile(Rustcore.GetAssetPath("Audio/ticksound2.wav"), "Master")
        if not Rustcore.SetSetting(settingKey, self:GetChecked() and true or false) then
            cb:Refresh()
        end
    end)

    cb.Refresh = function()
        cb:SetChecked(Rustcore.GetSetting(settingKey))
    end

    return cb
end

local function MakeSettingSlider(parent, name, labelText, y, minValue, maxValue, step, settingKey, formatter, tooltipText)
    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", parent, "TOPLEFT", 28, y)
    slider:SetWidth(180)
    slider:SetMinMaxValues(minValue, maxValue)
    slider:SetValueStep(step)
    local track = RustcoreTheme.SkinSlider(slider, 180, -1)

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("BOTTOM", slider, "TOP", 0, 6)
    label:SetText(labelText)
    ApplyBodyFont(label, 14)

    local low = _G[name .. "Low"]
    local high = _G[name .. "High"]
    local valueText = _G[name .. "Text"]
    if low then low:SetText("") end
    if high then high:SetText("") end
    if valueText then
        valueText:ClearAllPoints()
        valueText:SetPoint("TOP", track, "BOTTOM", 0, -4)
        ApplyBodyFont(valueText, 14)
    end

    if tooltipText then
        slider:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltipText, nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        slider:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    slider:SetScript("OnValueChanged", function(self, value)
        local normalized
        if step >= 1 then
            normalized = math.floor(value + 0.5)
        else
            normalized = math.floor(value * 100 + 0.5) / 100
        end
        if math.abs((self:GetValue() or normalized) - normalized) > 0.001 then
            self:SetValue(normalized)
            return
        end
        if valueText then valueText:SetText(formatter(normalized)) end
        if Rustcore.GetSetting(settingKey) ~= normalized and not Rustcore.SetSetting(settingKey, normalized) then
            self:SetValue(Rustcore.GetSetting(settingKey))
        end
    end)
    slider:SetValue(Rustcore.GetSetting(settingKey))
    return slider
end

-- Inset sub-toggles that only matter while their parent checkbox's setting
-- is on; dims/disables them to match, independent of (and layered underneath)
-- the combat-lock state.
local DEPENDENT_TOGGLES = {
    { parentKey = "selfFound",          field = "cbSelfFoundBuff" },
    { parentKey = "selfFound",          field = "cbSelfFoundConjured" },
    { parentKey = "showStatsWindow",    field = "cbStatRusted" },
    { parentKey = "showStatsWindow",    field = "cbStatBroken" },
    { parentKey = "showStatsWindow",    field = "cbStatDeaths" },
    { parentKey = "showStatsWindow",    field = "cbStatBestItem" },
    { parentKey = "showStatsWindow",    field = "cbStatsColoredNumbers" },
    { parentKey = "showStatsWindow",    field = "cbStatsTitles" },
    { parentKey = "showStatsWindow",    field = "cbStatsIcons" },
    { parentKey = "showDurabilityHUD",  field = "cbDurShowAll" },
    { parentKey = "showDurabilityHUD",  field = "cbDurHorizontal" },
    { parentKey = "showDurabilityHUD",  field = "cbDurBackground" },
    { parentKey = "showDurabilityHUD",  field = "cbDurGrowUpward" },
    { parentKey = "showDurabilityHUD",  field = "cbDurReverseOrder" },
    { parentKey = "showDurabilityHUD",  field = "cbDurTitle" },
    { parentKey = "showStatsWindow",    field = "cbStatsHorizontal" },
    { parentKey = "showStatsWindow",    field = "cbStatsBackground" },
    { parentKey = "broadcastDeaths",    field = "cbGuildMessage" },
    { parentKey = "broadcastDeaths",    field = "cbRealmBroadcast" },
    { parentKey = "showDeathWarning",   field = "cbShowWarningSound" },
    { parentKey = "showDeathlogWindow", field = "cbDeathlogLevel" },
    { parentKey = "showDeathlogWindow", field = "cbDeathlogSource" },
    { parentKey = "showDeathlogWindow", field = "cbDeathlogCount" },
    { parentKey = "showDeathlogWindow", field = "cbDeathlogItem" },
}

local DEPENDENT_PARENT_KEYS = {
    "selfFound", "showDurabilityHUD", "showStatsWindow",
    "broadcastDeaths", "showDeathWarning", "showDeathlogWindow",
}

local function DependentParentsSignature()
    local parts = {}
    for i, key in ipairs(DEPENDENT_PARENT_KEYS) do
        parts[i] = Rustcore.GetSetting(key) and "1" or "0"
    end
    return table.concat(parts)
end

local function RefreshDependentToggles(frame)
    local locked = SettingsLocked()
    for _, dep in ipairs(DEPENDENT_TOGGLES) do
        local cb = frame[dep.field]
        if cb then
            local usable = Rustcore.GetSetting(dep.parentKey) and not locked
            if usable then cb:Enable() else cb:Disable() end
            cb:SetAlpha(usable and 1 or 0.5)
        end
    end
end

local function RefreshCombatLockState(frame)
    local locked = SettingsLocked()
    if frame.diffSlider then
        if locked then frame.diffSlider:Disable() else frame.diffSlider:Enable() end
        frame.diffSlider:SetAlpha(locked and 0.5 or 1)
    end
    if frame.opacitySlider then
        if locked then frame.opacitySlider:Disable() else frame.opacitySlider:Enable() end
        frame.opacitySlider:SetAlpha(locked and 0.5 or 1)
    end
    if frame.shadowSlider then
        if locked then frame.shadowSlider:Disable() else frame.shadowSlider:Enable() end
        frame.shadowSlider:SetAlpha(locked and 0.5 or 1)
    end
    if frame.minLevelSlider then
        if locked then frame.minLevelSlider:Disable() else frame.minLevelSlider:Enable() end
        frame.minLevelSlider:SetAlpha(locked and 0.5 or 1)
    end
    if frame.minQualitySlider then
        if locked then frame.minQualitySlider:Disable() else frame.minQualitySlider:Enable() end
        frame.minQualitySlider:SetAlpha(locked and 0.5 or 1)
    end
    for _, slider in ipairs({ frame.deathlogOpacitySlider, frame.deathlogShadowSlider, frame.deathlogFontSlider }) do
        if slider then
            if locked then slider:Disable() else slider:Enable() end
            slider:SetAlpha(locked and 0.5 or 1)
        end
    end

    local controls = {
        frame.cbSelfFound,
        frame.cbSelfFoundBuff,
        frame.cbSelfFoundConjured,
        frame.cbWeapon,
        frame.cbRepair,
        frame.cbPvpDeathProtection,
        frame.cbMinimap,
        frame.cbBroadcast,
        frame.cbGuildMessage,
        frame.cbRealmBroadcast,
        frame.cbShowPopup,
        frame.cbShowWarning,
        frame.cbShowWarningSound,
        frame.cbStats,
        frame.cbDeathlog,
        frame.cbDeathlogLevel,
        frame.cbDeathlogCount,
        frame.cbDeathlogItem,
        frame.cbDeathlogSource,
        frame.cbDurHUD,
        frame.cbDurHorizontal,
        frame.cbDurBackground,
        frame.cbDurShowAll,
        frame.cbDurGrowUpward,
        frame.cbDurReverseOrder,
        frame.cbDurTitle,
        frame.cbStatsHorizontal,
        frame.cbStatsBackground,
        frame.cbStatsTitles,
        frame.cbStatsIcons,
        frame.cbStatRusted,
        frame.cbStatBroken,
        frame.cbStatDeaths,
        frame.cbStatBestItem,
        frame.cbStatsColoredNumbers,
        frame.cbDragonPlayerFrame,
        frame.cbDragonTargetFrame,
        frame.importBtn,
    }
    for _, control in ipairs(controls) do
        if control then
            if locked then control:Disable() else control:Enable() end
            control:SetAlpha(locked and 0.5 or 1)
        end
    end

    if frame.importDropdown then
        frame.importDropdown:SetAlpha(locked and 0.5 or 1)
    end
    if frame.importDropdownClick then
        frame.importDropdownClick:EnableMouse(not locked)
    end

    if frame.titleText then
        frame.titleText:SetText(DEFAULT_TITLE_TEXT)
    end
    if frame.diffSlider then
        if locked then
            ApplyCombatLockLabelStyle(frame.diffSlider, Rustcore.GetSetting("difficulty"))
        else
            ApplyDifficultyLabelStyle(frame.diffSlider, Rustcore.GetSetting("difficulty"))
        end
    end

    RefreshDependentToggles(frame)
end

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildOptionsFrame()
    local f = CreateFrame("Frame", "RustcoreOptionsFrame", UIParent, backdropTemplate)
    f:SetSize(640, 580)
    f:SetPoint("CENTER", 0, 20)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    RustcoreTheme.ApplyFrameSkin(f)

    -- Keep the difficulty artwork, but darken it enough for controls and labels.
    local bgShade = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    bgShade:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -18)
    bgShade:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 18)
    bgShade:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    bgShade:SetVertexColor(0, 0, 0, 0.62)

    -- The border art (RustcoreTheme.ApplyFrameSkin) lives on its own child
    -- frame at f's level + 1; a plain texture painted directly on f would
    -- always lose to that child frame regardless of draw layer, so the
    -- panel and its text both live on this one elevated child frame instead.
    local titleFrame = CreateFrame("Frame", nil, f)
    titleFrame:SetSize(96, 18)
    titleFrame:SetPoint("CENTER", f, "TOP", 0, -15)
    titleFrame:SetFrameLevel(f:GetFrameLevel() + 5)

    local titlePanel = titleFrame:CreateTexture(nil, "ARTWORK")
    titlePanel:SetTexture(Rustcore.GetAssetPath("UI/Window-title-panel.tga"))
    titlePanel:SetSize(140, 30)
    titlePanel:SetPoint("CENTER", titleFrame, "CENTER", 0, 0)

    local title = titleFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", titleFrame, "CENTER", 0, -1)
    title:SetWidth(92)
    ApplyBodyFont(title, 16)
    title:SetTextColor(unpack(TITLE_COLOR))
    title:SetShadowColor(0, 0, 0, 0.6)
    title:SetShadowOffset(1, -1)
    title:SetText(DEFAULT_TITLE_TEXT)
    f.titleText = title

    local dragHandle = CreateFrame("Frame", nil, f)
    dragHandle:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    dragHandle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -10)
    dragHandle:SetHeight(38)
    dragHandle:EnableMouse(true)
    dragHandle:RegisterForDrag("LeftButton")
    dragHandle:SetScript("OnDragStart", function() f:StartMoving() end)
    dragHandle:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -6)
    closeBtn:SetFrameLevel(f:GetFrameLevel() + 10)
    closeBtn:SetScript("OnClick", function() f:Hide() end)
    RustcoreTheme.SkinExitButton(closeBtn)

    local RefreshAllControls

    local diffHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    diffHeader:SetPoint("TOP", f, "TOP", 0, -58)
    diffHeader:SetJustifyH("CENTER")
    diffHeader:SetText("")
    ApplyBodyFont(diffHeader, 18)
    f.diffHeader = diffHeader

    local slider = CreateFrame("Slider", "RustcoreDifficultySlider", f, "OptionsSliderTemplate")
    slider:SetPoint("TOP", diffHeader, "BOTTOM", 0, -30)
    slider:SetWidth(380)
    slider:SetMinMaxValues(1, 5)
    slider:SetValueStep(1)
    local sliderTrack = RustcoreTheme.SkinSlider(slider, 400, -1)

    local sliderLow  = _G[slider:GetName().."Low"]
    local sliderHigh = _G[slider:GetName().."High"]
    local sliderText = _G[slider:GetName().."Text"]
    if sliderLow then
        sliderLow:SetText("Rusted")
        sliderLow:ClearAllPoints()
        sliderLow:SetPoint("TOPLEFT", sliderTrack, "BOTTOMLEFT", 4, -4)
        ApplyBodyFont(sliderLow, 14)
    end
    if sliderHigh then
        sliderHigh:SetText("Dust")
        sliderHigh:ClearAllPoints()
        sliderHigh:SetPoint("TOPRIGHT", sliderTrack, "BOTTOMRIGHT", -4, -4)
        ApplyBodyFont(sliderHigh, 14)
    end
    if sliderText then
        sliderText:SetText(DIFF_LABELS[Rustcore.GetSetting("difficulty")])
        sliderText:ClearAllPoints()
        sliderText:SetPoint("CENTER", diffHeader, "CENTER", 0, 0)
        sliderText:SetJustifyH("CENTER")
        sliderText:SetWidth(220)
        ApplyDifficultyLabelStyle(slider, Rustcore.GetSetting("difficulty"))
    end
    f.sliderText = sliderText

    local diffDesc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    diffDesc:SetPoint("TOP", sliderTrack, "BOTTOM", 0, -22)
    diffDesc:SetWidth(490)
    diffDesc:SetJustifyH("CENTER")
    diffDesc:SetTextColor(1, 0.82, 0)
    diffDesc:SetText(DIFF_DESCS[Rustcore.GetSetting("difficulty")])
    ApplyBodyFont(diffDesc, 14)


    slider:SetScript("OnValueChanged", function(self, value)
        ApplyDifficultyValue(self, diffDesc, value)
    end)
    slider:SetScript("OnMouseUp", function(self)
        ApplyDifficultyValue(self, diffDesc, self:GetValue())
    end)
    slider:SetValue(Rustcore.GetSetting("difficulty"))

    f.diffSlider = slider
    f.diffDesc   = diffDesc

    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -154)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 18)

    local topRule = content:CreateTexture(nil, "ARTWORK")
    topRule:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    topRule:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    topRule:SetHeight(4)
    topRule:SetTexture(Rustcore.GetAssetPath("UI/Line-horizontal.tga"))

    local navWidth = 160
    local navShade = content:CreateTexture(nil, "BACKGROUND", nil, 3)
    navShade:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -2)
    navShade:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    navShade:SetWidth(navWidth)
    navShade:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    navShade:SetVertexColor(0, 0, 0, 0.72)

    local navRule = content:CreateTexture(nil, "ARTWORK")
    navRule:SetPoint("TOPLEFT", content, "TOPLEFT", navWidth, -2)
    navRule:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", navWidth, 0)
    navRule:SetWidth(4)
    navRule:SetTexture(Rustcore.GetAssetPath("UI/Line-vertical.tga"))

    local function MakePage()
        local page = CreateFrame("Frame", nil, content)
        page:SetPoint("TOPLEFT", content, "TOPLEFT", navWidth + 2, -2)
        page:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
        page:Hide()
        return page
    end

    local function MakeHeader(page, text, y)
        local header = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        header:SetPoint("TOPLEFT", page, "TOPLEFT", 26, y)
        header:SetText(text)
        ApplyBodyFont(header, 19)
        return header
    end

    local function MakeRule(page, y)
        local rule = page:CreateTexture(nil, "ARTWORK")
        rule:SetPoint("TOPLEFT", page, "TOPLEFT", 20, y)
        rule:SetPoint("TOPRIGHT", page, "TOPRIGHT", -20, y)
        rule:SetHeight(4)
        rule:SetTexture(Rustcore.GetAssetPath("UI/Line-horizontal.tga"))
        return rule
    end

    local gameplayPage = MakePage()
    local interfacePage = MakePage()
    local notificationsPage = MakePage()
    local appearancePage = MakePage()
    local temperedPage = MakePage()

    local function PercentFormatter(value) return math.floor(value * 100 + 0.5) .. "%" end

    -- Plain frame, no scroll. Everything on this page fits the window as it is,
    -- and a scroll bar that never has anything to scroll is just a strip of
    -- furniture down the side.
    local interfaceContent = CreateFrame("Frame", nil, interfacePage)
    interfaceContent:SetPoint("TOPLEFT", interfacePage, "TOPLEFT", 0, 0)
    interfaceContent:SetPoint("BOTTOMRIGHT", interfacePage, "BOTTOMRIGHT", 0, 0)

    local notificationsScroll = CreateFrame(
        "ScrollFrame",
        "RustcoreNotificationsOptionsScrollFrame",
        notificationsPage,
        "UIPanelScrollFrameTemplate"
    )
    notificationsScroll:SetPoint("TOPLEFT", notificationsPage, "TOPLEFT", 0, 0)
    notificationsScroll:SetPoint("BOTTOMRIGHT", notificationsPage, "BOTTOMRIGHT", -24, 42)
    notificationsScroll:EnableMouseWheel(true)

    local notificationsContent = CreateFrame("Frame", nil, notificationsScroll)
    notificationsContent:SetSize(410, 700)
    notificationsScroll:SetScrollChild(notificationsContent)

    local notificationsScrollBar = notificationsScroll.ScrollBar
        or _G[notificationsScroll:GetName().."ScrollBar"]
    notificationsScroll:SetScript("OnMouseWheel", function(_, delta)
        if not notificationsScrollBar then return end
        local minValue, maxValue = notificationsScrollBar:GetMinMaxValues()
        local nextValue = notificationsScrollBar:GetValue() - (delta * 28)
        notificationsScrollBar:SetValue(math.max(minValue, math.min(maxValue, nextValue)))
    end)

    local appearanceScroll = CreateFrame(
        "ScrollFrame",
        "RustcoreAppearanceOptionsScrollFrame",
        appearancePage,
        "UIPanelScrollFrameTemplate"
    )
    appearanceScroll:SetPoint("TOPLEFT", appearancePage, "TOPLEFT", 0, 0)
    appearanceScroll:SetPoint("BOTTOMRIGHT", appearancePage, "BOTTOMRIGHT", -24, 42)
    appearanceScroll:EnableMouseWheel(true)

    local appearanceContent = CreateFrame("Frame", nil, appearanceScroll)
    appearanceContent:SetSize(410, 660)
    appearanceScroll:SetScrollChild(appearanceContent)

    local appearanceScrollBar = appearanceScroll.ScrollBar
        or _G[appearanceScroll:GetName().."ScrollBar"]
    appearanceScroll:SetScript("OnMouseWheel", function(_, delta)
        if not appearanceScrollBar then return end
        local minValue, maxValue = appearanceScrollBar:GetMinMaxValues()
        local nextValue = appearanceScrollBar:GetValue() - (delta * 28)
        appearanceScrollBar:SetValue(math.max(minValue, math.min(maxValue, nextValue)))
    end)

    -- Gameplay
    --
    -- The exceptions are laid out by what they cost, because the cost is not
    -- obvious from the labels and it is permanent once a death makes it matter.
    -- Each one says underneath it what it does to certification, colour-coded so
    -- the harmless one does not read like the disqualifying one.
    -- Bright enough to read at this size against the panel art. The muted
    -- versions these replace looked right in isolation and turned to mud beside
    -- a full-brightness option label -- which is the only place they are ever
    -- seen, now that they sit on the same line.
    local NOTE_NEUTRAL = { 0.55, 0.92, 0.55 }
    local NOTE_CAUTION = { 1.0,  0.82, 0.25 }
    local NOTE_SEVERE  = { 1.0,  0.45, 0.4  }

    -- Set beside the option's own label instead of underneath it. These are one
    -- short clause each, and a line apiece turned four checkboxes into eight
    -- rows of text -- which also pushed everything below off a fixed-height
    -- page. Kept to the consequence itself: when it bites is the rule's own
    -- business, and saying so was words the player did not need.
    local function MakeRuleNote(checkbox, text, color)
        local note = gameplayPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        note:SetPoint("LEFT", checkbox.label, "RIGHT", 8, 0)
        note:SetJustifyH("LEFT")
        note:SetText(text)
        ApplyBodyFont(note, 13)
        note:SetTextColor(color[1], color[2], color[3])
        return note
    end

    local rulesHeader = MakeHeader(gameplayPage, "Self-Found", -20)
    local cbSelfFound = MakeCheckbox(gameplayPage,
        "Self-Found Mode",
        "Blocks access to the mailbox, auction house, and player trading.",
        rulesHeader, -6, "selfFound")

    MakeRuleNote(cbSelfFound, "Certified separately.", NOTE_NEUTRAL)

    local cbSelfFoundBuff = MakeCheckbox(gameplayPage,
        "Show Buff Icon",
        "Shows verified Self-Found status as a buff icon on your buff bar. Disable to leave your buff bar untouched.",
        cbSelfFound, -3, "selfFoundBuffEnabled", 34, 20, 14)

    -- Second column on the buff icon's row rather than a row of its own: the
    -- page is a fixed height and already runs to the rule below, so a new full
    -- -width row would push the Death Rule Exceptions block off the bottom.
    local cbSelfFoundConjured = MakeCheckbox(gameplayPage,
        "Trade Conjured Items",
        "Allows player trades in which every item on both sides is a conjured item and neither side offers money. "
        .."Accept stays disabled until Rustcore has verified the contents. Anything else still ends Self-Found certification.",
        cbSelfFound, -3, "selfFoundAllowConjured", 234, 20, 14)

    local exceptionsHeader = gameplayPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    exceptionsHeader:SetPoint("TOPLEFT", cbSelfFoundBuff, "BOTTOMLEFT", -34, -14)
    exceptionsHeader:SetText("Death Rule Exceptions")
    ApplyBodyFont(exceptionsHeader, 19)

    local cbPvpDeathProtection = MakeCheckbox(gameplayPage,
        "Ignore PVP Death",
        "If an enemy player damages you at any point during a combat, dying in the same combat will not mark any items for deletion.",
        exceptionsHeader, -6, "ignoreDeathAfterEnemyPlayerDamage")

    MakeRuleNote(cbPvpDeathProtection, "No effect on verification.", NOTE_NEUTRAL)

    local cbWeapon = MakeCheckbox(gameplayPage,
        "Keep Main Weapon",
        "Spares your main weapon from deletion.\n"
        .."Hunter: Ranged slot\n"
        .."Melee (Warrior/Paladin/Rogue/Shaman/Druid): Main Hand\n"
        .."Caster (Priest/Mage/Warlock): Wand if equipped, else Main Hand",
        cbPvpDeathProtection, -4, "keepMainWeapon")

    MakeRuleNote(cbWeapon, "Caps verification at Rusted.", NOTE_CAUTION)

    local cbRepair = MakeCheckbox(gameplayPage,
        "Allow Item Repair",
        "Allows repair at merchants. By default repair is always blocked.",
        cbWeapon, -4, "allowRepair")

    MakeRuleNote(cbRepair, "Ends difficulty verification.", NOTE_SEVERE)

    MakeRule(gameplayPage, -232)
    local profileHeader = MakeHeader(gameplayPage, "Character Profile", -250)

    local profileDesc = gameplayPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    profileDesc:SetPoint("TOPLEFT", profileHeader, "BOTTOMLEFT", 0, -6)
    profileDesc:SetWidth(360)
    profileDesc:SetJustifyH("LEFT")
    profileDesc:SetText("Import settings from another character, or delete a character's stored data.")
    ApplyBodyFont(profileDesc, 14)

    -- Interface
    local featuresHeader = MakeHeader(interfaceContent, "Features", -20)
    local cbMinimap = MakeCheckbox(interfaceContent,
        "Show Minimap Button",
        "Show or hide the Rustcore minimap button.",
        featuresHeader, -6, "showMinimapButton")

    local cbDurHUD = MakeCheckbox(interfaceContent,
        "Show Durability HUD",
        "Replaces WoW's native durability frame with per-slot artwork. Only slots near 0 durability are shown by default. Reload UI to restore the original durability frame after disabling.",
        cbMinimap, -4, "showDurabilityHUD")

    -- Two columns under the HUD toggle, the same shape the Self-Found block
    -- uses: the settings that tune the layout run down the left, and the
    -- layout choice itself sits alone on the right. Declared first here but
    -- anchored to the second column -- both columns hang off cbDurHUD at the
    -- same yOff, so source order doesn't set what lands where, xOff does.
    local cbDurHorizontal = MakeCheckbox(interfaceContent,
        "Horizontal Display",
        "Lays the durability counters out in a single row instead of a vertical stack. The row grows leftward from the HUD's right edge.",
        cbDurHUD, -3, "durHUDHorizontal", 234, 20, 14)

    local cbDurBackground = MakeCheckbox(interfaceContent,
        "Panel Background",
        "Draws the same rivet panel behind the durability counters that the stats window and death log use. It also pads the counters away from the edge so the border stays clear of them.",
        cbDurHorizontal, -3, "durHUDBackground", 0, 20, 14)

    local cbDurShowAll = MakeCheckbox(interfaceContent,
        "Always Show All Slots",
        "Show durability for every equipped slot at all times, not just items with low durability.",
        cbDurHUD, -3, "showAllDurability", 34, 20, 14)

    local cbDurGrowUpward = MakeCheckbox(interfaceContent,
        "Grow Upward",
        "Makes the durability HUD grow upward from its anchor point instead of downward. With Horizontal Display on it grows to the right instead of to the left.",
        cbDurShowAll, -3, "durHUDGrowUpward", 0, 20, 14)

    local cbDurReverseOrder = MakeCheckbox(interfaceContent,
        "Reverse Order",
        "Reverses the durability HUD stack order, placing the most damaged item at the bottom instead of the top. In Horizontal Display it moves the most damaged item to the far end of the row instead.",
        cbDurGrowUpward, -3, "durHUDReverseOrder", 0, 20, 14)

    local cbDurTitle = MakeCheckbox(interfaceContent,
        "Panel Title",
        "Puts a \"Durability\" heading across the top of the durability HUD. One heading for the whole panel, not one per counter.",
        cbDurReverseOrder, -3, "durHUDShowTitle", 0, 20, 14)

    local cbStats = MakeCheckbox(interfaceContent,
        "Show Stats Window",
        "Show or hide the Rustcore item loss stats window.",
        cbDurTitle, -7, "showStatsWindow", -34)

    local cbStatsHorizontal = MakeCheckbox(interfaceContent,
        "Horizontal Display",
        "Lays the stats counters out side by side in a single row instead of stacking them into a column.",
        cbStats, -3, "statsHorizontalLayout", 234, 20, 14)

    local cbStatsBackground = MakeCheckbox(interfaceContent,
        "Panel Background",
        "Draws the rivet panel behind the stats window. Turning it off also drops the extra margin that was reserved for the panel border, letting the window pull its content in tighter.",
        cbStatsHorizontal, -3, "statsBackground", 0, 20, 14)

    local cbStatsTitles = MakeCheckbox(interfaceContent,
        "Counter Titles",
        "Puts a heading above each stats counter naming what it counts. One per counter, since every row counts something different.",
        cbStatsBackground, -3, "statsShowTitles", 0, 20, 14)

    local cbStatsIcons = MakeCheckbox(interfaceContent,
        "Counter Icons",
        "Shows an icon beside each stats counter. Turning it off falls back to the plain counter graphic the window used before the icons, with the same numbers in it.",
        cbStatsTitles, -3, "statsShowIcons", 0, 20, 14)

    local cbStatRusted = MakeCheckbox(interfaceContent,
        "Rusted Counter",
        "Show the count of items worn down to zero durability.",
        cbStats, -3, "statShowRusted", 34, 20, 14)

    local cbStatBroken = MakeCheckbox(interfaceContent,
        "Broken Counter",
        "Show the count of items destroyed on death.",
        cbStatRusted, -3, "statShowBroken", 0, 20, 14)

    local cbStatDeaths = MakeCheckbox(interfaceContent,
        "Deaths Counter",
        "Show how many times this character has died.",
        cbStatBroken, -3, "statShowDeaths", 0, 20, 14)

    local cbStatBestItem = MakeCheckbox(interfaceContent,
        "Best Item Lost",
        "Show the highest item level piece this character has lost.",
        cbStatDeaths, -3, "statShowBestItem", 0, 20, 14)

    local cbDragonPlayerFrame = MakeCheckbox(interfaceContent,
        "Dragon on Player Frame",
        "Shows a dragon on your own player frame that reflects your current difficulty tier.",
        cbStatBestItem, -7, "dragonPlayerFrame", -34)

    local cbDragonTargetFrame = MakeCheckbox(interfaceContent,
        "Dragon on Target Frame",
        "Shows a dragon on the target frame reflecting the difficulty tier of the targeted player, when they also run Rustcore. Also shown when targeting yourself.",
        cbDragonPlayerFrame, -7, "dragonTargetFrame")

    -- Notifications
    local deathlogHeader = MakeHeader(notificationsContent, "Death Log", -20)
    local cbDeathlog = MakeCheckbox(notificationsContent,
        "Show Death Log",
        "Show or hide the Rustcore death log window listing other players' deaths.",
        deathlogHeader, -6, "showDeathlogWindow")

    local cbDeathlogLevel = MakeCheckbox(notificationsContent,
        "Show Level", "Show the victim's level in each death log entry.",
        cbDeathlog, -3, "showDeathlogLevel", 34, 20, 14)

    local cbDeathlogSource = MakeCheckbox(notificationsContent,
        "Show Death Source", "Show what killed the player.",
        cbDeathlogLevel, -3, "showDeathlogSource", 0, 20, 14)

    local cbDeathlogCount = MakeCheckbox(notificationsContent,
        "Show Items", "Show the number of items lost in each death log entry.",
        cbDeathlogSource, -3, "showDeathlogCount", 0, 20, 14)

    local cbDeathlogItem = MakeCheckbox(notificationsContent,
        "Show Lost Item", "Show an icon (with tooltip) for the most valuable item lost.",
        cbDeathlogCount, -3, "showDeathlogItem", 0, 20, 14)

    MakeRule(notificationsContent, -195)
    local bcHeader = MakeHeader(notificationsContent, "Broadcast", -215)
    local cbBroadcast = MakeCheckbox(notificationsContent,
        "Broadcast My Death",
        "Announces your death and the item you lost to other Rustcore users.",
        bcHeader, -6, "broadcastDeaths")

    local cbGuildMessage = MakeCheckbox(notificationsContent,
        "Guild Broadcast",
        "Send a message in guild chat when you die with the item you lost.",
        cbBroadcast, -4, "guildDeathMessage", 34, 20, 14)

    local cbRealmBroadcast = MakeCheckbox(notificationsContent,
        "Realm Broadcast",
        "Broadcast your death realm-wide to other Rustcore users via a shared channel, not just guild/group.",
        cbGuildMessage, -3, "broadcastDeathsRealmWide", 0, 20, 14)

    local cbShowPopup = MakeCheckbox(notificationsContent,
        "Show Death Messages",
        "Display a chat message when another Rustcore player dies.",
        cbRealmBroadcast, -8, "showDeathPopup", -34)

    local cbShowWarning = MakeCheckbox(notificationsContent,
        "Show Center Warning",
        "Display a center-screen raid warning when another Rustcore player dies.",
        cbShowPopup, -4, "showDeathWarning")

    local cbShowWarningSound = MakeCheckbox(notificationsContent,
        "Play Death Sound",
        "Play a sound when the center-screen death warning shows.",
        cbShowWarning, -4, "showDeathWarningSound", 34, 20, 14)

    local minLevelSlider = MakeSettingSlider(
        notificationsContent,
        "RustcoreDeathlogMinLevelSlider",
        "Minimum Level",
        -445, 0, 60, 1, "deathlogMinLevel",
        function(value) return value == 0 and "Off" or tostring(value) end,
        "Hides death messages, the center-screen warning, and the death log entry itself for players below this level. Set to Off to show all levels."
    )

    -- Sits under Minimum Level because the two read as one pair: both narrow
    -- the same three surfaces, one by who died and one by what it cost them.
    local minQualitySlider = MakeSettingSlider(
        notificationsContent,
        "RustcoreDeathlogMinQualitySlider",
        "Minimum Item Rarity",
        -510, 0, 5, 1, "deathlogMinQuality",
        function(value) return Rustcore.GetDeathQualityFilterName(value) end,
        "Hides death messages, the center-screen warning, and the death log entry itself unless the death cost an item of at least this rarity. Set to Off to show every death, including ones that lost nothing."
    )

    -- Appearance
    local statsAppearanceHeader = MakeHeader(appearanceContent, "Stats Panel", -20)
    local cbStatsColoredNumbers = MakeCheckbox(appearanceContent,
        "Coloured Numbers",
        "Tints each stats counter with its matching difficulty colour instead of showing them all in the same tone.",
        statsAppearanceHeader, -6, "statsColoredNumbers", 8, 22, 15)

    local opacitySlider = MakeSettingSlider(
        appearanceContent,
        "RustcoreStatsOpacitySlider",
        "Background Opacity",
        -97, 0, 1, 0.01, "statsBackgroundOpacity",
        PercentFormatter,
        "Only has an effect while Panel Background is switched on for the stats window."
    )
    local shadowSlider = MakeSettingSlider(
        appearanceContent,
        "RustcoreStatsShadowSlider",
        "Dark Backdrop",
        -162, 0, 1, 0.01, "statsBackgroundShadow",
        PercentFormatter,
        "Only has an effect while Panel Background is switched on for the stats window."
    )
    MakeRule(appearanceContent, -217)
    MakeHeader(appearanceContent, "Death Log", -237)
    local deathlogOpacitySlider = MakeSettingSlider(
        appearanceContent,
        "RustcoreDeathlogOpacitySlider",
        "Background Opacity",
        -282, 0, 1, 0.01, "deathlogBackgroundOpacity",
        PercentFormatter
    )
    local deathlogShadowSlider = MakeSettingSlider(
        appearanceContent,
        "RustcoreDeathlogShadowSlider",
        "Dark Backdrop",
        -347, 0, 1, 0.01, "deathlogBackgroundShadow",
        PercentFormatter
    )
    local deathlogFontSlider = MakeSettingSlider(
        appearanceContent,
        "RustcoreDeathlogFontSlider",
        "Font Size",
        -412, 9, 16, 1, "deathlogFontSize",
        function(value) return tostring(value) end
    )

    MakeRule(appearanceContent, -467)
    MakeHeader(appearanceContent, "Durability HUD", -487)
    local durOpacitySlider = MakeSettingSlider(
        appearanceContent,
        "RustcoreDurabilityOpacitySlider",
        "Background Opacity",
        -532, 0, 1, 0.01, "durHUDBackgroundOpacity",
        PercentFormatter,
        "Only has an effect while Panel Background is switched on for the durability HUD."
    )
    local durShadowSlider = MakeSettingSlider(
        appearanceContent,
        "RustcoreDurabilityShadowSlider",
        "Dark Backdrop",
        -597, 0, 1, 0.01, "durHUDBackgroundShadow",
        PercentFormatter,
        "Only has an effect while Panel Background is switched on for the durability HUD."
    )

    -- About
    local aboutTitle = temperedPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    aboutTitle:SetPoint("TOPLEFT", temperedPage, "TOPLEFT", 26, -26)
    aboutTitle:SetJustifyH("LEFT")
    aboutTitle:SetText("Rustcore")
    ApplyBodyFont(aboutTitle, 22)
    aboutTitle:SetTextColor(1, 0.82, 0)

    local aboutBy = temperedPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    aboutBy:SetPoint("TOPLEFT", aboutTitle, "BOTTOMLEFT", 0, -4)
    aboutBy:SetJustifyH("LEFT")
    aboutBy:SetText("Made by Artemesis")
    ApplyBodyFont(aboutBy, 15)
    aboutBy:SetTextColor(0.75, 0.75, 0.75)

    local aboutBody = temperedPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    aboutBody:SetPoint("TOPLEFT", aboutBy, "BOTTOMLEFT", 0, -14)
    aboutBody:SetPoint("TOPRIGHT", temperedPage, "TOPRIGHT", -26, 0)
    aboutBody:SetJustifyH("LEFT")
    aboutBody:SetWordWrap(true)
    aboutBody:SetText(
        "Rustcore is an optional challenge for WoW Classic, built to make gear "
        .. "feel more meaningful and add a little more tension and immersion to "
        .. "your character's journey. Play it as strictly or casually as you "
        .. "like.\n\n"
        .. "The addon also tracks whether a character has been following the "
        .. "rules of their chosen difficulty and Self-Found settings. "
        .. "Verification is purely for bragging rights and isn't required to "
        .. "use any of Rustcore's features. It mainly affects the portrait "
        .. "dragon and the Self-Found buff that other Rustcore players can see "
        .. "when targeting you.")
    ApplyBodyFont(aboutBody, 14)

    local aboutJoin = temperedPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    aboutJoin:SetPoint("TOPLEFT", aboutBody, "BOTTOMLEFT", 0, -14)
    aboutJoin:SetPoint("TOPRIGHT", temperedPage, "TOPRIGHT", -26, 0)
    aboutJoin:SetJustifyH("LEFT")
    aboutJoin:SetWordWrap(true)
    aboutJoin:SetText("Found a bug, have an idea, or think something could be "
        .. "improved? You can reach me through my free Patreon. Check the "
        .. "Rustcore CurseForge page description for the link.")
    ApplyBodyFont(aboutJoin, 14)
    aboutJoin:SetTextColor(0.85, 0.75, 0.5)

    -- The Tempered Souls supporters section lived here. Removed for now; the
    -- page ends at the CurseForge line above.

    local importDropdown = CreateFrame("Frame", "RustcoreImportProfileDropdown", gameplayPage, "UIDropDownMenuTemplate")
    importDropdown:SetPoint("TOPLEFT", profileDesc, "BOTTOMLEFT", 0, -10)
    UIDropDownMenu_SetWidth(importDropdown, 190)

    local ddName = importDropdown:GetName()
    local ddLeft, ddMiddle, ddRight, ddButton, ddText, ddIcon =
        _G[ddName.."Left"], _G[ddName.."Middle"], _G[ddName.."Right"],
        _G[ddName.."Button"], _G[ddName.."Text"], _G[ddName.."Icon"]
    if ddLeft then ddLeft:Hide() end
    if ddMiddle then ddMiddle:Hide() end
    if ddRight then ddRight:Hide() end
    if ddIcon then ddIcon:Hide() end
    if ddButton then ddButton:Hide(); ddButton:EnableMouse(false) end

    local ddBg = importDropdown:CreateTexture(nil, "BACKGROUND")
    ddBg:SetTexture(Rustcore.GetAssetPath("UI/Lostitemframe Dark copy.tga"))
    ddBg:SetSize(190, 26)
    ddBg:SetPoint("TOPLEFT", importDropdown, "TOPLEFT", 0, 0)

    local PLACEHOLDER_COLOR = { 0.6, 0.6, 0.6 }
    local SELECTED_COLOR = { 1, 1, 1 }

    if ddText then
        ddText:ClearAllPoints()
        ddText:SetJustifyH("LEFT")
        ddText:SetPoint("LEFT", ddBg, "LEFT", 10, -1)
        ApplyBodyFont(ddText, 14)
    end

    local ddClick = CreateFrame("Button", nil, importDropdown)
    ddClick:SetAllPoints(ddBg)

    local importBtn = CreateFrame("Button", nil, gameplayPage, "UIPanelButtonTemplate")
    importBtn:SetSize(82, 22)
    importBtn:SetPoint("LEFT", ddBg, "RIGHT", 12, 0)
    importBtn:SetText("Import")
    RustcoreTheme.SkinButton(importBtn)
    ApplyBodyFont(importBtn:GetFontString(), 14)

    local LAYOUT_IMPORT_KEYS = { "durHUDPos", "statsWindowPoint", "statsWindowSize", "minimapAngle", "deathlogWindowPoint", "deathlogWindowSize" }
    local selectedProfileKey = nil

    local function RefreshImportDropdownText()
        local profiles = RustcoreDB.profiles or {}
        local currentKey = Rustcore.GetCharacterKey()
        if selectedProfileKey and (selectedProfileKey == currentKey or not profiles[selectedProfileKey]) then
            selectedProfileKey = nil
        end
        if selectedProfileKey and profiles[selectedProfileKey] then
            UIDropDownMenu_SetText(importDropdown, profiles[selectedProfileKey].characterLabel or selectedProfileKey)
            if ddText then ddText:SetTextColor(unpack(SELECTED_COLOR)) end
        else
            UIDropDownMenu_SetText(importDropdown, "Click to select")
            if ddText then ddText:SetTextColor(unpack(PLACEHOLDER_COLOR)) end
        end
    end

    ddClick:SetScript("OnClick", function()
        if SettingsLocked() then return end
        ToggleDropDownMenu(1, nil, importDropdown, importDropdown, 0, 0)
    end)

    local function ApplyDropdownListStyle(level, value, dropDownFrame)
        if dropDownFrame ~= importDropdown then return end
        if UIDROPDOWNMENU_OPEN_MENU ~= ddName then return end
        level = level or 1
        local listFrame = _G["DropDownList"..level]
        if not (listFrame and listFrame:IsShown()) then return end
        if level == 1 then
            listFrame:ClearAllPoints()
            listFrame:SetPoint("TOP", ddBg, "BOTTOM", -6, 2)
            if listFrame.SetBackdrop then listFrame:SetBackdrop(nil) end
            local listBackdrop = _G[listFrame:GetName().."Backdrop"]
            if listBackdrop then
                listBackdrop:Hide()
                if listBackdrop.SetBackdrop then listBackdrop:SetBackdrop(nil) end
            end
        end
        for i = 1, UIDROPDOWNMENU_MAXBUTTONS do
            local btn = _G["DropDownList"..level.."Button"..i]
            if not btn or not btn:IsShown() then break end
            local btnText = _G[btn:GetName().."NormalText"]
            if btnText then ApplyBodyFont(btnText, 14) end
        end
    end
    hooksecurefunc("ToggleDropDownMenu", ApplyDropdownListStyle)

    UIDropDownMenu_Initialize(importDropdown, function(self, level)
        local profiles = RustcoreDB.profiles or {}
        local currentKey = Rustcore.GetCharacterKey()
        for key, profile in pairs(profiles) do
            if key ~= currentKey then
                local info = UIDropDownMenu_CreateInfo()
                info.text = profile.characterLabel or key
                info.value = key
                info.justificationH = "RIGHT"
                info.func = function()
                    selectedProfileKey = key
                    RefreshImportDropdownText()
                    CloseDropDownMenus()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end)

    importBtn:SetScript("OnClick", function()
        if not selectedProfileKey then return end
        if SettingsLocked() then
            print("|cffff4444Rustcore:|r Settings cannot be changed while in combat.")
            return
        end
        local profiles = RustcoreDB.profiles or {}
        local source = profiles[selectedProfileKey]
        if not source then return end

        for _, key in ipairs(LAYOUT_IMPORT_KEYS) do
            if source[key] ~= nil then
                Rustcore.SetProfileValue(key, source[key])
            end
        end
        for _, key in ipairs(Rustcore.GetDefaultSettingKeys()) do
            if source[key] ~= nil then
                Rustcore.SetSetting(key, source[key])
            end
        end

        if RustcoreDurability and RustcoreDurability.RefreshPosition then RustcoreDurability.RefreshPosition() end
        if RustcoreStats and RustcoreStats.RefreshPosition then RustcoreStats.RefreshPosition() end
        if RustcoreDeathlog and RustcoreDeathlog.RefreshPosition then RustcoreDeathlog.RefreshPosition() end
        if Rustcore.RefreshMinimapPosition then Rustcore.RefreshMinimapPosition() end
        if RefreshAllControls then RefreshAllControls(f) end

        PlaySoundFile(Rustcore.GetAssetPath("Audio/ticksound2.wav"), "Master")
    end)

    -- ── Deleting a character's stored data ───────────────────────────────────
    --
    -- Every table a character writes into, not just profiles. Leaving three of
    -- the four behind is precisely how a deleted character's history came back
    -- to haunt the next character to reuse the name: the profile was gone, but
    -- the stats and the verification record were still sitting under the shared
    -- name key, and were read as evidence of a past life.
    local PROFILE_TABLES = {
        "profiles", "characterStats", "selfFoundCharacters", "verification",
    }

    -- Every key the selected character could be filed under, minus every key
    -- that might be ours.
    --
    -- The label scan is the same trick V.CandidateKeys uses, for the same
    -- reason: a character keyed by GUID in one table and by name-realm in
    -- another is still one character, and deleting half of it would leave
    -- exactly the orphaned fragments this button exists to clear out.
    --
    -- The protection pass at the end is not paranoia. A deleted character and a
    -- freshly made one with the same name share a characterLabel, which is the
    -- single most likely reason anybody opens this menu -- so the sweep that
    -- finds the old data will reach the live character too unless it is stopped.
    -- Only the direct keys are protected, not V.CandidateKeys, because that
    -- function's own label scan would hand back the foreign key as well and
    -- quietly turn the whole thing into a no-op.
    local function KeysForProfile(key)
        local keys, seen = { key }, { [key] = true }

        local function add(k)
            if k and k ~= "" and not seen[k] then
                seen[k] = true
                keys[#keys + 1] = k
            end
        end

        local profiles = type(RustcoreDB) == "table" and RustcoreDB.profiles or nil
        local entry = type(profiles) == "table" and profiles[key] or nil
        local label = type(entry) == "table" and entry.characterLabel or nil

        if label then
            if type(profiles) == "table" then
                for k, profile in pairs(profiles) do
                    if type(profile) == "table" and profile.characterLabel == label then
                        add(k)
                    end
                end
            end

            -- A verification record can be keyed by a GUID that never reached
            -- the profile table, so it has to be matched on what it knows about
            -- itself rather than on where it happens to be filed.
            local store = type(RustcoreDB) == "table" and RustcoreDB.verification or nil
            if type(store) == "table" then
                for k, record in pairs(store) do
                    local id = type(record) == "table" and record.identity or nil
                    if type(id) == "table" and id.name and id.realm
                        and (id.name .. "-" .. id.realm) == label then
                        add(k)
                    end
                end
            end
        end

        local mine = {}
        local function protect(k)
            if k and k ~= "" then mine[k] = true end
        end
        protect(Rustcore.GetCharacterKey and Rustcore.GetCharacterKey())
        protect(UnitGUID and UnitGUID("player"))
        local name = UnitName and UnitName("player")
        local realm = GetNormalizedRealmName and GetNormalizedRealmName()
        if not realm or realm == "" then
            realm = GetRealmName and GetRealmName() or nil
        end
        if name and realm and realm ~= "" then protect(name .. "-" .. realm) end
        protect(name)

        local out = {}
        for _, k in ipairs(keys) do
            if not mine[k] then out[#out + 1] = k end
        end
        return out
    end

    local function DeleteProfile(key)
        if type(RustcoreDB) ~= "table" then return end
        for _, k in ipairs(KeysForProfile(key)) do
            for _, tableName in ipairs(PROFILE_TABLES) do
                local t = RustcoreDB[tableName]
                if type(t) == "table" then t[k] = nil end
            end
        end
    end

    -- Blizzard's own confirmation, because this is the one action in the addon
    -- that destroys something the player cannot get back, and a dialog they
    -- already recognise from deleting a character or an item says that faster
    -- than anything custom could.
    StaticPopupDialogs["RUSTCORE_DELETE_PROFILE"] = {
        text = "Delete all Rustcore data for %s?\n\nSettings, statistics and verification history for that character will be removed. This cannot be undone.",
        button1 = YES,
        button2 = NO,
        showAlert = true,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        -- Past the dialogs Blizzard's own protected code reuses, so ours cannot
        -- taint one of them.
        preferredIndex = 3,
        OnAccept = function(self, data)
            local key = data or self.data
            if not key then return end
            DeleteProfile(key)
            if selectedProfileKey == key then selectedProfileKey = nil end
            RefreshImportDropdownText()
            PlaySoundFile(Rustcore.GetAssetPath("Audio/ticksound2.wav"), "Master")
        end,
    }

    local deleteBtn = CreateFrame("Button", nil, gameplayPage, "UIPanelButtonTemplate")
    deleteBtn:SetSize(82, 22)
    deleteBtn:SetPoint("LEFT", importBtn, "RIGHT", 8, 0)
    deleteBtn:SetText("Delete")
    RustcoreTheme.SkinButton(deleteBtn)
    ApplyBodyFont(deleteBtn:GetFontString(), 14)

    deleteBtn:SetScript("OnClick", function()
        if not selectedProfileKey then return end
        if SettingsLocked() then
            print("|cffff4444Rustcore:|r Settings cannot be changed while in combat.")
            return
        end

        -- The label rather than the key, because the key is a GUID as often as
        -- not and nobody can confirm a deletion they cannot read.
        local profiles = RustcoreDB.profiles or {}
        local source = profiles[selectedProfileKey]
        local label = (type(source) == "table" and source.characterLabel)
            or selectedProfileKey

        local dialog = StaticPopup_Show("RUSTCORE_DELETE_PROFILE", label)
        -- Captured now, so a dropdown change while the dialog is open cannot
        -- redirect the deletion at somebody else.
        if dialog then dialog.data = selectedProfileKey end
    end)

    RefreshImportDropdownText()

    -- Verification tab. Built by Verification/UI.lua, which owns everything
    -- inside the page; this only supplies the frame and the tab that shows it.
    local verificationPage = MakePage()
    local refreshVerification
    if RustcoreVerification and RustcoreVerification.UI and RustcoreVerification.UI.BuildPage then
        refreshVerification = RustcoreVerification.UI.BuildPage(verificationPage)
    end
    f.refreshVerification = refreshVerification

    local pages = {
        gameplay = gameplayPage,
        interface = interfacePage,
        notifications = notificationsPage,
        appearance = appearancePage,
        tempered = temperedPage,
        verification = verificationPage,
    }
    local tabs = {}

    local function ShowPage(pageKey)
        for key, page in pairs(pages) do
            if key == pageKey then page:Show() else page:Hide() end
        end
        -- Verification state moves while the window is closed, so the page is
        -- rebuilt from the record every time it is opened rather than kept live.
        if pageKey == "verification" and refreshVerification then
            pcall(refreshVerification)
        end
        for key, tab in pairs(tabs) do
            local selected = key == pageKey
            -- The pressed artwork is what marks the selected tab. The lock is
            -- visual only: Blizzard holds its own micro buttons in PUSHED while
            -- their panel is open and they stay enabled, so clicking the tab
            -- that is already open still works.
            tab:SetButtonState(selected and "PUSHED" or "NORMAL", selected)
            local tabText = tab:GetFontString()
            if tabText then
                tabText:SetTextColor(selected and 1 or 0.95, selected and 0.82 or 0.78, selected and 0 or 0.52)
            end
        end
        f.activePage = pageKey
    end

    local function MakeTab(pageKey, label, index)
        local tab = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        tab:SetSize(navWidth, 42)
        tab:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -2 - ((index - 1) * 42))
        tab:SetText(label)
        RustcoreTheme.SkinButton(tab)
        ApplyBodyFont(tab:GetFontString(), 17)

        local nativeHighlight = tab:GetHighlightTexture()
        if nativeHighlight then
            nativeHighlight:SetTexture(nil)
            nativeHighlight:Hide()
        end
        local normalTexture = tab:GetNormalTexture()
        if normalTexture and normalTexture.SetDesaturated then
            normalTexture:SetDesaturated(true)
        end
        local pushedTexture = tab:GetPushedTexture()
        if pushedTexture then
            if pushedTexture.SetDesaturated then pushedTexture:SetDesaturated(true) end
            pushedTexture:SetVertexColor(0.42, 0.62, 1, 1)
        end
        if tab.rustcoreThemeHover then
            tab.rustcoreThemeHover:SetBlendMode("BLEND")
            tab.rustcoreThemeHover:SetVertexColor(0.16, 0.4, 0.86, 0.38)
        end

        tab:SetScript("OnClick", function()
            PlaySoundFile(Rustcore.GetAssetPath("Audio/ticksound2.wav"), "Master")
            ShowPage(pageKey)
        end)
        tabs[pageKey] = tab
    end

    MakeTab("gameplay", "Gameplay", 1)
    MakeTab("interface", "Interface", 2)
    MakeTab("notifications", "Notifications", 3)
    MakeTab("appearance", "Appearance", 4)
    MakeTab("tempered", "About", 5)
    MakeTab("verification", "Verification", 6)
    ShowPage("gameplay")

    -- Store refs for Refresh
    f.cbSelfFound   = cbSelfFound
    f.cbSelfFoundBuff = cbSelfFoundBuff
    f.cbSelfFoundConjured = cbSelfFoundConjured
    f.cbWeapon      = cbWeapon
    f.cbRepair      = cbRepair
    f.cbPvpDeathProtection = cbPvpDeathProtection
    f.cbMinimap     = cbMinimap
    f.cbBroadcast   = cbBroadcast
    f.cbGuildMessage= cbGuildMessage
    f.cbRealmBroadcast = cbRealmBroadcast
    f.cbShowPopup   = cbShowPopup
    f.cbShowWarning = cbShowWarning
    f.cbShowWarningSound = cbShowWarningSound
    f.cbStats       = cbStats
    f.cbStatRusted  = cbStatRusted
    f.cbStatBroken  = cbStatBroken
    f.cbStatDeaths  = cbStatDeaths
    f.cbStatBestItem = cbStatBestItem
    f.cbStatsColoredNumbers = cbStatsColoredNumbers
    f.cbDeathlog = cbDeathlog
    f.cbDeathlogLevel = cbDeathlogLevel
    f.cbDeathlogCount = cbDeathlogCount
    f.cbDeathlogItem = cbDeathlogItem
    f.cbDeathlogSource = cbDeathlogSource
    f.opacitySlider   = opacitySlider
    f.shadowSlider    = shadowSlider
    f.minLevelSlider  = minLevelSlider
    f.minQualitySlider = minQualitySlider
    f.deathlogOpacitySlider = deathlogOpacitySlider
    f.deathlogShadowSlider = deathlogShadowSlider
    f.deathlogFontSlider = deathlogFontSlider
    f.cbDurHUD      = cbDurHUD
    f.cbDurHorizontal = cbDurHorizontal
    f.cbDurBackground = cbDurBackground
    f.durOpacitySlider = durOpacitySlider
    f.durShadowSlider  = durShadowSlider
    f.cbDurShowAll  = cbDurShowAll
    f.cbDurGrowUpward = cbDurGrowUpward
    f.cbDurReverseOrder = cbDurReverseOrder
    f.cbDurTitle = cbDurTitle
    f.cbStatsHorizontal = cbStatsHorizontal
    f.cbStatsBackground = cbStatsBackground
    f.cbStatsTitles = cbStatsTitles
    f.cbStatsIcons = cbStatsIcons
    f.cbDragonPlayerFrame = cbDragonPlayerFrame
    f.cbDragonTargetFrame = cbDragonTargetFrame
    f.importBtn     = importBtn
    f.importDropdown = importDropdown
    f.importDropdownClick = ddClick
    f.RefreshImportDropdownText = RefreshImportDropdownText

    RefreshAllControls = function(self)
        local v = Rustcore.GetSetting("difficulty")
        RustcoreTheme.SetDifficultyBackground(self, v)
        self.diffSlider:SetValue(v)
        ApplyDifficultyLabelStyle(self.diffSlider, v)
        self.diffDesc:SetText(DIFF_DESCS[v])
        self.cbSelfFound:Refresh()
        self.cbSelfFoundBuff:Refresh()
        self.cbSelfFoundConjured:Refresh()
        self.cbWeapon:Refresh()
        self.cbRepair:Refresh()
        self.cbPvpDeathProtection:Refresh()
        self.cbMinimap:Refresh()
        self.cbBroadcast:Refresh()
        self.cbGuildMessage:Refresh()
        self.cbRealmBroadcast:Refresh()
        self.cbShowPopup:Refresh()
        self.cbShowWarning:Refresh()
        self.cbShowWarningSound:Refresh()
        self.cbStats:Refresh()
        self.cbDeathlog:Refresh()
        self.cbDeathlogLevel:Refresh()
        self.cbDeathlogCount:Refresh()
        self.cbDeathlogItem:Refresh()
        self.cbDeathlogSource:Refresh()
        self.opacitySlider:SetValue(Rustcore.GetSetting("statsBackgroundOpacity"))
        self.shadowSlider:SetValue(Rustcore.GetSetting("statsBackgroundShadow"))
        self.minLevelSlider:SetValue(Rustcore.GetSetting("deathlogMinLevel"))
        self.minQualitySlider:SetValue(Rustcore.GetSetting("deathlogMinQuality"))
        self.deathlogOpacitySlider:SetValue(Rustcore.GetSetting("deathlogBackgroundOpacity"))
        self.deathlogShadowSlider:SetValue(Rustcore.GetSetting("deathlogBackgroundShadow"))
        self.deathlogFontSlider:SetValue(Rustcore.GetSetting("deathlogFontSize"))
        self.cbDurHUD:Refresh()
        self.cbDurHorizontal:Refresh()
        self.cbDurBackground:Refresh()
        self.durOpacitySlider:SetValue(Rustcore.GetSetting("durHUDBackgroundOpacity"))
        self.durShadowSlider:SetValue(Rustcore.GetSetting("durHUDBackgroundShadow"))
        self.cbDurShowAll:Refresh()
        self.cbDurGrowUpward:Refresh()
        self.cbDurReverseOrder:Refresh()
        self.cbDurTitle:Refresh()
        self.cbStatsHorizontal:Refresh()
        self.cbStatsBackground:Refresh()
        self.cbStatsTitles:Refresh()
        self.cbStatsIcons:Refresh()
        self.cbStatRusted:Refresh()
        self.cbStatBroken:Refresh()
        self.cbStatDeaths:Refresh()
        self.cbStatBestItem:Refresh()
        self.cbStatsColoredNumbers:Refresh()
        self.cbDragonPlayerFrame:Refresh()
        self.cbDragonTargetFrame:Refresh()
        self.RefreshImportDropdownText()
    end

    f:SetScript("OnShow", function(self)
        RefreshAllControls(self)
        RefreshCombatLockState(self)
    end)

    f:SetScript("OnUpdate", function(self)
        if self._combatLocked ~= SettingsLocked() then
            self._combatLocked = SettingsLocked()
            RefreshCombatLockState(self)
        elseif self._depSignature ~= DependentParentsSignature() then
            self._depSignature = DependentParentsSignature()
            RefreshDependentToggles(self)
        end
    end)

    f:Hide()
    return f
end

-- ── Public API ────────────────────────────────────────────────────────────────

function RustcoreOptions.Toggle()
    if not optFrame then optFrame = BuildOptionsFrame() end
    if optFrame:IsShown() then
        optFrame:Hide()
    else
        PlaySoundFile(Rustcore.GetAssetPath("Audio/Metalsound.wav"), "Master")
        optFrame:Show()
    end
end

function RustcoreOptions.Hide()
    if optFrame and optFrame:IsShown() then
        optFrame:Hide()
    end
end
