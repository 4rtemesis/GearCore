-- Rustcore: Options window
-- Accessible via /rustcore or /rc

RustcoreOptions = {}

local optFrame

local DIFF_LABELS = { [1]="Lite", [2]="Normal", [3]="Hard", [4]="Brutal", [5]="Extreme" }
local DIFF_DESCS  = {
    [1] = "Only repair is blocked. No items are lost on death.",
    [2] = "Lose 1 random equipped item on death.",
    [3] = "Lose 25% of your equipped items on death (rounded up).",
    [4] = "Lose 50% of your equipped items on death (rounded up).",
    [5] = "Lose every equipped item on death.",
} 

local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil
local DEFAULT_TITLE_TEXT = "|cffff4444Rustcore|r Options"
local COMBAT_TITLE_TEXT = "|cffff4444Settings are locked while in combat.|r"

local function SettingsLocked()
    return Rustcore and Rustcore.SettingsLocked and Rustcore.SettingsLocked()
end

local function ApplyDifficultyValue(slider, diffDesc, value)
    local v = math.max(1, math.min(5, math.floor(value + 0.5)))
    if math.abs((slider:GetValue() or v) - v) > 0.001 then
        slider:SetValue(v)
        return
    end

    if not Rustcore.SetSetting("difficulty", v) then
        local current = Rustcore.GetSetting("difficulty")
        if math.abs((slider:GetValue() or current) - current) > 0.001 then
            slider:SetValue(current)
        end
        return
    end
    local txt = _G[slider:GetName().."Text"]
    if txt then txt:SetText(DIFF_LABELS[v]) end
    diffDesc:SetText(DIFF_DESCS[v])
    local parent = slider:GetParent()
    if parent then
        RustcoreTheme.SetDifficultyBackground(parent, v)
    end
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function MakeCheckbox(parent, labelText, tooltipText, anchorTo, yOff, settingKey)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOff)

    RustcoreTheme.SkinCheckbox(cb)

    local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    lbl:SetText(labelText)

    if tooltipText then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltipText, nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    cb:SetScript("OnClick", function(self)
        if not Rustcore.SetSetting(settingKey, self:GetChecked() and true or false) then
            cb:Refresh()
        end
    end)

    cb.Refresh = function()
        cb:SetChecked(Rustcore.GetSetting(settingKey))
    end

    return cb
end

local function RefreshCombatLockState(frame)
    local locked = SettingsLocked()
    if frame.diffSlider then
        if locked then frame.diffSlider:Disable() else frame.diffSlider:Enable() end
        frame.diffSlider:SetAlpha(locked and 0.5 or 1)
    end

    local controls = {
        frame.cbSelfFound,
        frame.cbWeapon,
        frame.cbRepair,
        frame.cbMinimap,
        frame.cbBroadcast,
        frame.cbShowPopup,
        frame.cbShowWarning,
    }
    for _, control in ipairs(controls) do
        if control then
            if locked then control:Disable() else control:Enable() end
            control:SetAlpha(locked and 0.5 or 1)
        end
    end

    if frame.combatNote then
        if locked then
            if frame.titleText then
                frame.titleText:SetText(COMBAT_TITLE_TEXT)
            end
            frame.combatNote:Show()
        else
            if frame.titleText then
                frame.titleText:SetText(DEFAULT_TITLE_TEXT)
            end
            frame.combatNote:Hide()
        end
    end
end

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildOptionsFrame()
    local f = CreateFrame("Frame", "RustcoreOptionsFrame", UIParent, backdropTemplate)
    f:SetSize(580, 500)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    RustcoreTheme.ApplyFrameSkin(f)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -22)
    title:SetText(DEFAULT_TITLE_TEXT)
    f.titleText = title

    local dragHandle = CreateFrame("Frame", nil, f)
    dragHandle:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    dragHandle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -10)
    dragHandle:SetHeight(28)
    dragHandle:EnableMouse(true)
    dragHandle:RegisterForDrag("LeftButton")
    dragHandle:SetScript("OnDragStart", function() f:StartMoving() end)
    dragHandle:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -18)
    closeBtn:SetFrameLevel(f:GetFrameLevel() + 10)
    closeBtn:SetScript("OnClick", function() f:Hide() end)
    RustcoreTheme.SkinExitButton(closeBtn)

    local leftColX = 34
    local rightColX = 294

    -- ── Difficulty section ────────────────────────────────────────────────────
    local diffHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    diffHeader:SetPoint("TOPLEFT", f, "TOPLEFT", leftColX, -58)
    diffHeader:SetText("Difficulty Mode")
    f.diffHeader = diffHeader

    -- Five-step slider (1=Lite, 2=Normal, 3=Hard, 4=Brutal, 5=Extreme)
    local slider = CreateFrame("Slider", "RustcoreDifficultySlider", f, "OptionsSliderTemplate")
    slider:SetPoint("TOP", title, "BOTTOM", 0, -34)
    slider:SetWidth(420)
    slider:SetMinMaxValues(1, 5)
    slider:SetValueStep(1)
    local sliderTrack = RustcoreTheme.SkinSlider(slider, 450, -1)

    local sliderLow  = _G[slider:GetName().."Low"]
    local sliderHigh = _G[slider:GetName().."High"]
    local sliderText = _G[slider:GetName().."Text"]
    if sliderLow then
        sliderLow:SetText("Lite")
        sliderLow:ClearAllPoints()
        sliderLow:SetPoint("TOPLEFT", sliderTrack, "BOTTOMLEFT", -2, -6)
    end
    if sliderHigh then
        sliderHigh:SetText("Extreme")
        sliderHigh:ClearAllPoints()
        sliderHigh:SetPoint("TOPRIGHT", sliderTrack, "BOTTOMRIGHT", 2, -6)
    end
    if sliderText then
        sliderText:SetText(DIFF_LABELS[Rustcore.GetSetting("difficulty")])
        sliderText:ClearAllPoints()
        sliderText:SetPoint("LEFT", diffHeader, "RIGHT", 12, 0)
        sliderText:SetJustifyH("LEFT")
        sliderText:SetWidth(110)
    end
    f.sliderText = sliderText

    local diffDesc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    diffDesc:SetPoint("TOPLEFT", sliderTrack, "BOTTOMLEFT", 8, -26)
    diffDesc:SetWidth(420)
    diffDesc:SetJustifyH("LEFT")
    diffDesc:SetTextColor(1, 0.82, 0)
    diffDesc:SetText(DIFF_DESCS[Rustcore.GetSetting("difficulty")])

    local combatNote = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    combatNote:SetPoint("BOTTOMLEFT", diffHeader, "TOPLEFT", 0, 8)
    combatNote:SetWidth(480)
    combatNote:SetJustifyH("LEFT")
    combatNote:SetWordWrap(true)
    combatNote:Hide()
    f.combatNote = combatNote

    slider:SetScript("OnValueChanged", function(self, value)
        ApplyDifficultyValue(self, diffDesc, value)
    end)
    slider:SetScript("OnMouseUp", function(self)
        ApplyDifficultyValue(self, diffDesc, self:GetValue())
    end)
    slider:SetValue(Rustcore.GetSetting("difficulty"))

    f.diffSlider = slider
    f.diffDesc   = diffDesc

    -- ── Self-Found section ────────────────────────────────────────────────────
    local sfHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sfHeader:SetPoint("TOPLEFT", diffDesc, "BOTTOMLEFT", -8, -26)
    sfHeader:SetText("Self-Found")

    local cbSelfFound = MakeCheckbox(f,
        "Self-Found Mode",
        "Blocks access to the mailbox, auction house, and player trading.",
        sfHeader, -8, "selfFound")

    -- ── Exceptions section ────────────────────────────────────────────────────
    local excHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    excHeader:SetPoint("TOPLEFT", cbSelfFound, "BOTTOMLEFT", 0, -16)
    excHeader:SetText("Exceptions")

    local cbWeapon = MakeCheckbox(f,
        "Keep Main Weapon",
        "Spares your main weapon from deletion.\n"
        .."Hunter: Ranged slot\n"
        .."Melee (Warrior/Paladin/Rogue/Shaman/Druid): Main Hand\n"
        .."Caster (Priest/Mage/Warlock): Wand if equipped, else Main Hand",
        excHeader, -8, "keepMainWeapon")

    local cbRepair = MakeCheckbox(f,
        "Allow Item Repair",
        "Allows repair at merchants. By default repair is always blocked.",
        cbWeapon, -8, "allowRepair")

    local excNote = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    excNote:SetPoint("TOPLEFT", cbRepair, "BOTTOMLEFT", 30, -4)
    excNote:SetTextColor(0.7, 0.7, 0.7)
    excNote:SetText("Applies to all difficulty modes.")

    local uiHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    uiHeader:SetPoint("TOPLEFT", sfHeader, "TOPLEFT", rightColX - leftColX, 0)
    uiHeader:SetText("Interface")

    local cbMinimap = MakeCheckbox(f,
        "Show Minimap Button",
        "Show or hide the Rustcore minimap button.",
        uiHeader, -8, "showMinimapButton")

    -- ── Death broadcast section ───────────────────────────────────────────────
    local bcHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bcHeader:SetPoint("TOPLEFT", cbMinimap, "BOTTOMLEFT", 0, -16)
    bcHeader:SetText("Death Broadcast")

    local cbBroadcast = MakeCheckbox(f,
        "Broadcast My Death",
        "Announces your death and the item you lost to other Rustcore users\nvia a shared addon channel.",
        bcHeader, -8, "broadcastDeaths")

    local cbShowPopup = MakeCheckbox(f,
        "Show Death Popup",
        "Display a popup notification when another Rustcore player dies.",
        cbBroadcast, -8, "showDeathPopup")

    local cbShowWarning = MakeCheckbox(f,
        "Show Center Warning",
        "Display a center-screen raid warning when another Rustcore player dies.",
        cbShowPopup, -8, "showDeathWarning")

    -- ── Death penalty recovery ────────────────────────────────────────────────
    local queueHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    queueHeader:SetPoint("BOTTOM", f, "BOTTOM", 0, 106)
    queueHeader:SetText("Death Penalty Queue")

    local queueBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    queueBtn:SetSize(230, 40)
    queueBtn:SetPoint("TOP", queueHeader, "BOTTOM", 0, -10)
    queueBtn:SetScript("OnClick", function()
        f:Hide()
        RustcoreUI.ReopenDeletionFrame()
    end)
    RustcoreTheme.SkinButton(queueBtn)
    f.queueBtn = queueBtn

    -- Store refs for Refresh
    f.cbSelfFound   = cbSelfFound
    f.cbWeapon      = cbWeapon
    f.cbRepair      = cbRepair
    f.cbMinimap     = cbMinimap
    f.cbBroadcast   = cbBroadcast
    f.cbShowPopup   = cbShowPopup
    f.cbShowWarning = cbShowWarning

    f:SetScript("OnShow", function(self)
        local v = Rustcore.GetSetting("difficulty")
        RustcoreTheme.SetDifficultyBackground(self, v)
        self.diffSlider:SetValue(v)
        if self.sliderText then self.sliderText:SetText(DIFF_LABELS[v]) end
        self.diffDesc:SetText(DIFF_DESCS[v])
        self.cbSelfFound:Refresh()
        self.cbWeapon:Refresh()
        self.cbRepair:Refresh()
        self.cbMinimap:Refresh()
        self.cbBroadcast:Refresh()
        self.cbShowPopup:Refresh()
        self.cbShowWarning:Refresh()

        local count = RustcoreUI.GetPendingCount()
        if count > 0 then
            self.queueBtn:SetText("Show Pending Deletions")
            self.queueBtn:Enable()
        else
            self.queueBtn:SetText("No Pending Deletions")
            self.queueBtn:Disable()
        end

        RefreshCombatLockState(self)
    end)

    f:SetScript("OnUpdate", function(self)
        if self._combatLocked ~= SettingsLocked() then
            self._combatLocked = SettingsLocked()
            RefreshCombatLockState(self)
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
        optFrame:Show()
    end
end

function RustcoreOptions.Hide()
    if optFrame and optFrame:IsShown() then
        optFrame:Hide()
    end
end
