-- GearCore: Options window
-- Accessible via /gearcore or /gc

GearCoreOptions = {}

local optFrame

local DIFF_LABELS = { [1]="Lite", [2]="Difficult", [3]="Extreme" }
local DIFF_DESCS  = {
    [1] = "Lose 1 random equipped item on death.",
    [2] = "Keep 2 random items — lose everything else.",
    [3] = "Lose every equipped item on death.",
}

-- See GearCoreUI.lua for explanation of this pattern.
local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil

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
        GearCore.SetSetting(settingKey, self:GetChecked() and true or false)
    end)

    cb.Refresh = function()
        cb:SetChecked(GearCore.GetSetting(settingKey))
    end

    return cb
end

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildOptionsFrame()
    local f = CreateFrame("Frame", "GearCoreOptionsFrame", UIParent, backdropTemplate)
    f:SetSize(390, 390)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left=11, right=12, top=12, bottom=11 },
    })

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetText("|cffff4444GearCore|r Options")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    -- ── Difficulty section ────────────────────────────────────────────────────
    local diffHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    diffHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -52)
    diffHeader:SetText("Difficulty Mode")

    -- Three-step slider (1=Lite, 2=Difficult, 3=Extreme)
    local slider = CreateFrame("Slider", "GearCoreDifficultySlider", f, "OptionsSliderTemplate")
    -- Anchor to the frame center so the Low/High labels don't overflow the sides.
    -- diffHeader stays as a visual label; slider position is independent.
    slider:SetPoint("TOP", f, "TOP", 0, -90)
    slider:SetWidth(300)
    slider:SetMinMaxValues(1, 3)
    slider:SetValueStep(1)

    -- OptionsSliderTemplate creates these child globals; guard in case the client
    -- uses a different template variant where the names don't match.
    local sliderLow  = _G[slider:GetName().."Low"]
    local sliderHigh = _G[slider:GetName().."High"]
    local sliderText = _G[slider:GetName().."Text"]
    if sliderLow  then sliderLow:SetText("Lite")    end
    if sliderHigh then sliderHigh:SetText("Extreme") end
    if sliderText then sliderText:SetText(DIFF_LABELS[GearCore.GetSetting("difficulty")]) end
    f.sliderText = sliderText  -- save ref for OnShow refresh

    local diffDesc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    diffDesc:SetPoint("TOP", slider, "BOTTOM", 0, -10)
    diffDesc:SetTextColor(1, 0.82, 0)
    diffDesc:SetText(DIFF_DESCS[GearCore.GetSetting("difficulty")])

    slider:SetValue(GearCore.GetSetting("difficulty"))
    slider:SetScript("OnValueChanged", function(self, value)
        local v = math.floor(value + 0.5)
        GearCore.SetSetting("difficulty", v)
        local txt = _G[self:GetName().."Text"]
        if txt then txt:SetText(DIFF_LABELS[v]) end
        diffDesc:SetText(DIFF_DESCS[v])
    end)

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

    local cbRepair = MakeCheckbox(f,
        "Block Item Repair",
        "Disables the Repair All and Repair Item buttons at merchants.",
        cbSelfFound, -8, "blockRepair")

    -- ── Weapon exception section ──────────────────────────────────────────────
    local wpnHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    wpnHeader:SetPoint("TOPLEFT", cbRepair, "BOTTOMLEFT", 0, -18)
    wpnHeader:SetText("Weapon Exception")

    local cbWeapon = MakeCheckbox(f,
        "Keep Main Weapon",
        "Spares your main weapon from deletion.\n"
        .."Hunter: Ranged slot\n"
        .."Melee (Warrior/Paladin/Rogue/Shaman/Druid): Main Hand\n"
        .."Caster (Priest/Mage/Warlock): Wand if equipped, else Main Hand",
        wpnHeader, -8, "keepMainWeapon")

    -- Weapon note
    local wpnNote = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    wpnNote:SetPoint("TOPLEFT", cbWeapon, "BOTTOMLEFT", 30, -4)
    wpnNote:SetTextColor(0.7, 0.7, 0.7)
    wpnNote:SetText("Applies to the Lite, Difficult, and Extreme modes.")

    -- Store refs for Refresh
    f.cbSelfFound = cbSelfFound
    f.cbRepair    = cbRepair
    f.cbWeapon    = cbWeapon

    f:SetScript("OnShow", function(self)
        local v = GearCore.GetSetting("difficulty")
        self.diffSlider:SetValue(v)
        if self.sliderText then self.sliderText:SetText(DIFF_LABELS[v]) end
        self.diffDesc:SetText(DIFF_DESCS[v])
        self.cbSelfFound:Refresh()
        self.cbRepair:Refresh()
        self.cbWeapon:Refresh()
    end)

    f:Hide()
    return f
end

-- ── Public API ────────────────────────────────────────────────────────────────

function GearCoreOptions.Toggle()
    if not optFrame then optFrame = BuildOptionsFrame() end
    if optFrame:IsShown() then
        optFrame:Hide()
    else
        optFrame:Show()
    end
end
