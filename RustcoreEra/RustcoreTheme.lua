RustcoreTheme = RustcoreTheme or {}

local function Asset(name)
    return Rustcore.GetAssetPath("UI/" .. name)
end

local FRAME_INSET = 18
local CORNER_SIZE = 64
local EDGE_CENTER_OFFSET = 1
local HORIZONTAL_EDGE_HEIGHT = 18
local VERTICAL_EDGE_WIDTH = 18
local BUTTON_TEXT_OFFSET_Y = -1
local SLIDER_THUMB_WIDTH = 9
local SLIDER_THUMB_HEIGHT = 36
local EXIT_BUTTON_SIZE = 22
local FRAME_BACKGROUND_ALPHA = 0.78
local DIFFICULTY_BACKGROUNDS = {
    [1] = "background1 copy.tga",
    [2] = "background2 copy.tga",
    [3] = "background3 copy.tga",
    [4] = "background4 copy.tga",
    [5] = "background5 copy.tga",
}

local function ApplyTexture(texture, path)
    texture:SetTexture(path)
    texture:SetTexCoord(0, 1, 0, 1)
end

local function EnsureButtonState(button)
    local text = button:GetFontString()
    if not text then return end

    if button:IsEnabled() then
        text:SetTextColor(1, 0.93, 0.8)
    else
        text:SetTextColor(0.62, 0.56, 0.47)
    end
end

function RustcoreTheme.ApplyFrameSkin(frame)
    if frame.rustcoreThemeFrameSkin then return frame.rustcoreThemeFrameSkin end

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", frame, "TOPLEFT", FRAME_INSET, -FRAME_INSET)
    bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -FRAME_INSET, FRAME_INSET)
    ApplyTexture(bg, Asset(DIFFICULTY_BACKGROUNDS[1]))
    bg:SetAlpha(FRAME_BACKGROUND_ALPHA)

    local border = CreateFrame("Frame", nil, frame)
    border:SetAllPoints(frame)
    border:SetFrameLevel(frame:GetFrameLevel() + 1)

    local edgeTop = border:CreateTexture(nil, "ARTWORK")
    edgeTop:SetPoint("TOPLEFT", frame, "TOPLEFT", CORNER_SIZE - 8 + EDGE_CENTER_OFFSET, -EDGE_CENTER_OFFSET)
    edgeTop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(CORNER_SIZE - 8 + EDGE_CENTER_OFFSET), -EDGE_CENTER_OFFSET)
    edgeTop:SetHeight(HORIZONTAL_EDGE_HEIGHT)
    ApplyTexture(edgeTop, Asset("Rustcore-frame-horizontalNorth-1 copy.tga"))

    local edgeBottom = border:CreateTexture(nil, "ARTWORK")
    edgeBottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", CORNER_SIZE - 8 + EDGE_CENTER_OFFSET, EDGE_CENTER_OFFSET)
    edgeBottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(CORNER_SIZE - 8 + EDGE_CENTER_OFFSET), EDGE_CENTER_OFFSET)
    edgeBottom:SetHeight(HORIZONTAL_EDGE_HEIGHT)
    ApplyTexture(edgeBottom, Asset("Rustcore-frame-horizontalSouth-1 copy.tga"))
    edgeBottom:SetTexCoord(0, 1, 1, 0)

    local edgeLeft = border:CreateTexture(nil, "ARTWORK")
    edgeLeft:SetPoint("TOPLEFT", frame, "TOPLEFT", EDGE_CENTER_OFFSET, -(CORNER_SIZE - 8 + EDGE_CENTER_OFFSET))
    edgeLeft:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", EDGE_CENTER_OFFSET, CORNER_SIZE - 8 + EDGE_CENTER_OFFSET)
    edgeLeft:SetWidth(VERTICAL_EDGE_WIDTH)
    ApplyTexture(edgeLeft, Asset("Rustcore-frame-verticalWest-1 copy.tga"))

    local edgeRight = border:CreateTexture(nil, "ARTWORK")
    edgeRight:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -EDGE_CENTER_OFFSET, -(CORNER_SIZE - 8 + EDGE_CENTER_OFFSET))
    edgeRight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -EDGE_CENTER_OFFSET, CORNER_SIZE - 8 + EDGE_CENTER_OFFSET)
    edgeRight:SetWidth(VERTICAL_EDGE_WIDTH)
    ApplyTexture(edgeRight, Asset("Rustcore-frame-verticalEast-1 copy.tga"))
    edgeRight:SetTexCoord(1, 0, 0, 1)

    local cornerNW = border:CreateTexture(nil, "OVERLAY")
    cornerNW:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    cornerNW:SetSize(CORNER_SIZE, CORNER_SIZE)
    ApplyTexture(cornerNW, Asset("Rustcore-frame-NWcorner-1 copy.tga"))

    local cornerNE = border:CreateTexture(nil, "OVERLAY")
    cornerNE:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    cornerNE:SetSize(CORNER_SIZE, CORNER_SIZE)
    ApplyTexture(cornerNE, Asset("Rustcore-frame-NEcorner-1 copy.tga"))

    local cornerSW = border:CreateTexture(nil, "OVERLAY")
    cornerSW:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    cornerSW:SetSize(CORNER_SIZE, CORNER_SIZE)
    ApplyTexture(cornerSW, Asset("Rustcore-frame-SWcorner-1copy.tga"))

    local cornerSE = border:CreateTexture(nil, "OVERLAY")
    cornerSE:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    cornerSE:SetSize(CORNER_SIZE, CORNER_SIZE)
    ApplyTexture(cornerSE, Asset("Rustcore-frame-SEcorner-1copy.tga"))

    frame.rustcoreThemeBackground = bg
    frame.rustcoreThemeFrameSkin = border
    return border
end

function RustcoreTheme.SetDifficultyBackground(frame, difficulty)
    if not frame or not frame.rustcoreThemeBackground then return end
    local background = DIFFICULTY_BACKGROUNDS[difficulty] or DIFFICULTY_BACKGROUNDS[1]
    ApplyTexture(frame.rustcoreThemeBackground, Asset(background))
end

function RustcoreTheme.SkinButton(button)
    if button.rustcoreThemeButtonSkin then
        EnsureButtonState(button)
        return
    end

    button:SetNormalTexture(Asset("Rustcore-texture-button-1 copy.tga"))
    button:SetPushedTexture(Asset("Rustcore-texture-buttonpressed-1.tga"))
    button:SetDisabledTexture(Asset("Rustcore-texture-buttonunavailable-1 copy.tga"))
    button:SetPushedTextOffset(0, BUTTON_TEXT_OFFSET_Y)

    local normal = button:GetNormalTexture()
    local pushed = button:GetPushedTexture()
    local disabled = button:GetDisabledTexture()

    if normal then normal:SetAllPoints(button) end
    if pushed then pushed:SetAllPoints(button) end
    if disabled then disabled:SetAllPoints(button) end

    local hover = button:CreateTexture(nil, "OVERLAY")
    hover:SetPoint("TOPLEFT", button, "TOPLEFT", 3, -3)
    hover:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -3, 3)
    hover:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    hover:SetBlendMode("ADD")
    hover:SetVertexColor(1, 0.46, 0.12, 0.09)
    hover:Hide()
    button.rustcoreThemeHover = hover

    button:HookScript("OnEnter", function(self)
        if self:IsEnabled() and self.rustcoreThemeHover then
            self.rustcoreThemeHover:Show()
        end
    end)
    button:HookScript("OnLeave", function(self)
        if self.rustcoreThemeHover then
            self.rustcoreThemeHover:Hide()
        end
    end)

    button:HookScript("OnEnable", EnsureButtonState)
    button:HookScript("OnDisable", function(self)
        EnsureButtonState(self)
        if self.rustcoreThemeHover then
            self.rustcoreThemeHover:Hide()
        end
    end)
    button.rustcoreThemeButtonSkin = true
    EnsureButtonState(button)
end

function RustcoreTheme.SkinExitButton(button)
    if button.rustcoreThemeExitSkin then return end

    button:SetNormalTexture(Asset("Rustcore-texture-exitbutton-1 copy.tga"))
    button:SetPushedTexture(Asset("Rustcore-texture-exitbutton-1 copy.tga"))
    button:SetSize(EXIT_BUTTON_SIZE, EXIT_BUTTON_SIZE)

    local normal = button:GetNormalTexture()
    local pushed = button:GetPushedTexture()

    if normal then normal:SetAllPoints(button) end
    if pushed then
        pushed:SetAllPoints(button)
        pushed:SetVertexColor(0.84, 0.84, 0.84, 1)
    end

    local hover = button:CreateTexture(nil, "OVERLAY")
    hover:SetAllPoints(button)
    hover:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    hover:SetBlendMode("ADD")
    hover:SetVertexColor(1, 0.55, 0.16, 0.18)
    hover:Hide()
    button.rustcoreThemeExitHover = hover

    button:HookScript("OnEnter", function(self)
        if self.rustcoreThemeExitHover then
            self.rustcoreThemeExitHover:Show()
        end
    end)
    button:HookScript("OnClick", function()
        PlaySoundFile(Rustcore.GetAssetPath("Audio/Exitsound.wav"), "Master")
    end)
    button:HookScript("OnLeave", function(self)
        if self.rustcoreThemeExitHover then
            self.rustcoreThemeExitHover:Hide()
        end
    end)

    button:SetHitRectInsets(-4, -4, -4, -4)
    button.rustcoreThemeExitSkin = true
end

function RustcoreTheme.SkinMinimizeButton(button)
    if button.rustcoreThemeMinimizeSkin then return end

    button:SetNormalTexture(Asset("Rustcore-texture-minimizebutton-1.tga"))
    button:SetPushedTexture(Asset("Rustcore-texture-minimizebutton-1.tga"))
    button:SetSize(EXIT_BUTTON_SIZE, EXIT_BUTTON_SIZE)

    local normal = button:GetNormalTexture()
    local pushed = button:GetPushedTexture()

    if normal then normal:SetAllPoints(button) end
    if pushed then
        pushed:SetAllPoints(button)
        pushed:SetVertexColor(0.84, 0.84, 0.84, 1)
    end

    local hover = button:CreateTexture(nil, "OVERLAY")
    hover:SetAllPoints(button)
    hover:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    hover:SetBlendMode("ADD")
    hover:SetVertexColor(1, 0.55, 0.16, 0.18)
    hover:Hide()
    button.rustcoreThemeMinimizeHover = hover

    button:HookScript("OnEnter", function(self)
        if self.rustcoreThemeMinimizeHover then
            self.rustcoreThemeMinimizeHover:Show()
        end
    end)
    button:HookScript("OnClick", function()
        PlaySoundFile(Rustcore.GetAssetPath("Audio/Exitsound.wav"), "Master")
    end)
    button:HookScript("OnLeave", function(self)
        if self.rustcoreThemeMinimizeHover then
            self.rustcoreThemeMinimizeHover:Hide()
        end
    end)

    button:SetHitRectInsets(-4, -4, -4, -4)
    button.rustcoreThemeMinimizeSkin = true
end

function RustcoreTheme.SkinCheckbox(checkbox)
    if checkbox.rustcoreThemeCheckboxSkin then return end

    checkbox:SetNormalTexture(Asset("Rustcore-texture-checkboxunticked-1.tga"))
    checkbox:SetPushedTexture(Asset("Rustcore-texture-checkboxunticked-1.tga"))
    checkbox:SetHighlightTexture(Asset("Rustcore-texture-checkboxunticked-1.tga"), "ADD")
    checkbox:SetCheckedTexture(Asset("Rustcore-texture-checkboxticked-1.tga"))
    checkbox:SetDisabledCheckedTexture(Asset("Rustcore-texture-checkboxticked-1.tga"))

    local normal = checkbox:GetNormalTexture()
    local pushed = checkbox:GetPushedTexture()
    local highlight = checkbox:GetHighlightTexture()
    local checked = checkbox:GetCheckedTexture()
    local disabled = checkbox:GetDisabledCheckedTexture()

    if normal then normal:SetAllPoints(checkbox) end
    if pushed then
        pushed:SetAllPoints(checkbox)
        pushed:SetVertexColor(0.92, 0.92, 0.92, 1)
    end
    if highlight then
        highlight:SetAllPoints(checkbox)
        highlight:SetVertexColor(1, 1, 1, 0.12)
    end
    if checked then checked:SetAllPoints(checkbox) end
    if disabled then disabled:SetAllPoints(checkbox) end

    checkbox.rustcoreThemeCheckboxSkin = true
end

function RustcoreTheme.SkinSlider(slider, width, trackYOffset)
    if slider.rustcoreThemeSliderTrack then
        slider.rustcoreThemeSliderTrack:SetWidth(width)
        return slider.rustcoreThemeSliderTrack
    end

    local sliderName = slider.GetName and slider:GetName()
    if sliderName then
        for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
            local region = _G[sliderName .. suffix]
            if region then region:Hide() end
        end
    end

    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("CENTER", slider, "CENTER", 0, trackYOffset or -1)
    track:SetSize(width, 24)
    ApplyTexture(track, Asset("Rustcore-texture-slider-1.tga"))

    slider:SetThumbTexture(Asset("Rustcore-texture-sliderhandle-1.tga"))
    local thumb = slider:GetThumbTexture()
    if thumb then
        thumb:SetSize(SLIDER_THUMB_WIDTH, SLIDER_THUMB_HEIGHT)
        thumb:SetVertexColor(0.92, 0.92, 0.92, 1)
    end

    slider.rustcoreThemeSliderTrack = track
    return track
end
