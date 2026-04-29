-- GearCore: Options window
-- Accessible via /gearcore or /gc

GearCoreOptions = {}

local optFrame

local DIFF_LABELS = { [1]="Lite", [2]="Difficult", [3]="Extreme" }
local DIFF_DESCS  = {
    [1] = "Lose 1 random equipped item on death.",
    [2] = "Lose half your equipped items at random, rounded up.",
    [3] = "Lose every equipped item on death.",
}

-- See GearCoreUI.lua for explanation of this pattern.
local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil

local function ApplyDifficultyValue(slider, diffDesc, value)
    local v = math.max(1, math.min(3, math.floor(value + 0.5)))
    if math.abs((slider:GetValue() or v) - v) > 0.001 then
        slider:SetValue(v)
        return
    end

    GearCore.SetSetting("difficulty", v)
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
    f:SetSize(390, 455)
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
    title:SetText("|cffff4444GearCore|r Options")

    local dragHandle = CreateFrame("Frame", nil, f)
    dragHandle:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    dragHandle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -10)
    dragHandle:SetHeight(28)
    dragHandle:EnableMouse(true)
    dragHandle:RegisterForDrag("LeftButton")
    dragHandle:SetScript("OnDragStart", function()
        f:StartMoving()
    end)
    dragHandle:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
    end)

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

    -- OptionsSliderTemplate creates these child globals; guard in case the client
    -- uses a different template variant where the names don't match.
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
    local sliderMid = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sliderMid:SetPoint("TOP", sliderTrack, "BOTTOM", 0, -6)
    sliderMid:SetTextColor(0.82, 0.82, 0.82)
    sliderMid:SetText("Difficult")
    if sliderText then
        sliderText:SetText(DIFF_LABELS[GearCore.GetSetting("difficulty")])
        sliderText:ClearAllPoints()
        sliderText:SetPoint("BOTTOMLEFT", sliderTrack, "TOPLEFT", 0, 12)
        sliderText:SetJustifyH("LEFT")
        sliderText:SetWidth(284)
    end
    f.sliderText = sliderText  -- save ref for OnShow refresh

    local diffDesc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    diffDesc:SetPoint("TOPLEFT", sliderTrack, "BOTTOMLEFT", 16, -28)
    diffDesc:SetWidth(284)
    diffDesc:SetJustifyH("LEFT")
    diffDesc:SetTextColor(1, 0.82, 0)
    diffDesc:SetText(DIFF_DESCS[GearCore.GetSetting("difficulty")])

    slider:SetScript("OnValueChanged", function(self, value)
        ApplyDifficultyValue(self, diffDesc, value)
    end)
    slider:SetScript("OnMouseUp", function(self)
        ApplyDifficultyValue(self, diffDesc, self:GetValue())
    end)
    slider:SetValue(GearCore.GetSetting("difficulty"))

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

    -- ── Death penalty recovery ────────────────────────────────────────────────
    local queueHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    queueHeader:SetPoint("TOPLEFT", wpnNote, "BOTTOMLEFT", -30, -22)
    queueHeader:SetText("Death Penalty Queue")

    local queueBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    queueBtn:SetSize(300, 28)
    queueBtn:SetPoint("TOP", f, "TOP", 0, -382)
    queueBtn:SetScript("OnClick", function()
        f:Hide()
        GearCoreUI.ReopenDeletionFrame()
    end)
    f.queueBtn = queueBtn

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

        local count = GearCoreUI.GetPendingCount()
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

function GearCoreOptions.Toggle()
    if not optFrame then optFrame = BuildOptionsFrame() end
    if optFrame:IsShown() then
        optFrame:Hide()
    else
        optFrame:Show()
    end
end

function GearCoreOptions.Hide()
    if optFrame and optFrame:IsShown() then
        optFrame:Hide()
    end
end
