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

local function ApplyDifficultyValue(slider, diffDesc, value)
    local v = math.max(1, math.min(5, math.floor(value + 0.5)))
    if math.abs((slider:GetValue() or v) - v) > 0.001 then
        slider:SetValue(v)
        return
    end

    Rustcore.SetSetting("difficulty", v)
    local txt = _G[slider:GetName().."Text"]
    if txt then txt:SetText(DIFF_LABELS[v]) end
    diffDesc:SetText(DIFF_DESCS[v])
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function MakeCheckbox(parent, labelText, tooltipText, anchorTo, yOff, settingKey)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOff)

    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")

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
        Rustcore.SetSetting(settingKey, self:GetChecked() and true or false)
    end)

    cb.Refresh = function()
        cb:SetChecked(Rustcore.GetSetting(settingKey))
    end

    return cb
end

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildOptionsFrame()
    local f = CreateFrame("Frame", "RustcoreOptionsFrame", UIParent, backdropTemplate)
    f:SetSize(390, 590)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left=11, right=12, top=12, bottom=11 },
    })

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("|cffff4444Rustcore|r Options")

    local dragHandle = CreateFrame("Frame", nil, f)
    dragHandle:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    dragHandle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -10)
    dragHandle:SetHeight(28)
    dragHandle:EnableMouse(true)
    dragHandle:RegisterForDrag("LeftButton")
    dragHandle:SetScript("OnDragStart", function() f:StartMoving() end)
    dragHandle:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    -- ── Difficulty section ────────────────────────────────────────────────────
    local diffHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    diffHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -52)
    diffHeader:SetText("Difficulty Mode")

    -- Five-step slider (1=Lite, 2=Normal, 3=Hard, 4=Brutal, 5=Extreme)
    local slider = CreateFrame("Slider", "RustcoreDifficultySlider", f, "OptionsSliderTemplate")
    slider:SetPoint("TOP", f, "TOP", 0, -90)
    slider:SetWidth(300)
    slider:SetMinMaxValues(1, 5)
    slider:SetValueStep(1)

    local sliderTrack = CreateFrame("Frame", nil, f, backdropTemplate)
    sliderTrack:SetSize(284, 8)
    sliderTrack:SetPoint("CENTER", slider, "CENTER", 0, -1)
    sliderTrack:SetFrameLevel(slider:GetFrameLevel() - 1)
    sliderTrack:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    sliderTrack:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
    sliderTrack:SetBackdropBorderColor(0.72, 0.58, 0.18, 0.95)

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
        sliderText:SetPoint("BOTTOM", sliderTrack, "TOP", 0, 12)
        sliderText:SetJustifyH("CENTER")
        sliderText:SetWidth(284)
    end
    f.sliderText = sliderText

    local diffDesc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    diffDesc:SetPoint("TOPLEFT", sliderTrack, "BOTTOMLEFT", 16, -28)
    diffDesc:SetWidth(284)
    diffDesc:SetJustifyH("LEFT")
    diffDesc:SetTextColor(1, 0.82, 0)
    diffDesc:SetText(DIFF_DESCS[Rustcore.GetSetting("difficulty")])

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
    sfHeader:SetPoint("TOPLEFT", diffDesc, "BOTTOMLEFT", 0, -22)
    sfHeader:SetText("Self-Found")

    local cbSelfFound = MakeCheckbox(f,
        "Self-Found Mode",
        "Blocks access to the mailbox, auction house, and player trading.",
        sfHeader, -8, "selfFound")

    -- ── Exceptions section ────────────────────────────────────────────────────
    local excHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    excHeader:SetPoint("TOPLEFT", cbSelfFound, "BOTTOMLEFT", 0, -18)
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

    -- ── Death broadcast section ───────────────────────────────────────────────
    local bcHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bcHeader:SetPoint("TOPLEFT", excNote, "BOTTOMLEFT", -30, -22)
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
    queueHeader:SetPoint("TOPLEFT", cbShowWarning, "BOTTOMLEFT", 0, -22)
    queueHeader:SetText("Death Penalty Queue")

    local queueBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    queueBtn:SetSize(300, 28)
    queueBtn:SetPoint("TOPLEFT", queueHeader, "BOTTOMLEFT", 0, -8)
    queueBtn:SetScript("OnClick", function()
        f:Hide()
        RustcoreUI.ReopenDeletionFrame()
    end)
    f.queueBtn = queueBtn

    -- Store refs for Refresh
    f.cbSelfFound   = cbSelfFound
    f.cbWeapon      = cbWeapon
    f.cbRepair      = cbRepair
    f.cbBroadcast   = cbBroadcast
    f.cbShowPopup   = cbShowPopup
    f.cbShowWarning = cbShowWarning

    f:SetScript("OnShow", function(self)
        local v = Rustcore.GetSetting("difficulty")
        self.diffSlider:SetValue(v)
        if self.sliderText then self.sliderText:SetText(DIFF_LABELS[v]) end
        self.diffDesc:SetText(DIFF_DESCS[v])
        self.cbSelfFound:Refresh()
        self.cbWeapon:Refresh()
        self.cbRepair:Refresh()
        self.cbBroadcast:Refresh()
        self.cbShowPopup:Refresh()
        self.cbShowWarning:Refresh()

        local count = RustcoreUI.GetPendingCount()
        if count > 0 then
            self.queueBtn:SetText("Show Pending Deletions  (" .. count .. " items)")
            self.queueBtn:Enable()
        else
            self.queueBtn:SetText("No Pending Deletions")
            self.queueBtn:Disable()
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
