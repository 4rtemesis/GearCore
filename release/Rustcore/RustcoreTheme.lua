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
local SLIDER_THUMB_WIDTH = 14
local SLIDER_THUMB_HEIGHT = 36
local EXIT_BUTTON_SIZE = 22
local FRAME_BACKGROUND_ALPHA = 0.78

-- Native pixel size of the top/bottom edge strip. It is not a power of two, so
-- the GPU cannot wrap it: a repeating edge has to be laid out as real texture
-- instances rather than asked for with SetHorizTile.
local EDGE_TILE_ASPECT = 1231 / 88

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

local DELETE_BUTTON_FONT_SIZE = 22
local DELETE_BUTTON_LETTER_SPACING = 4
local DELETE_BUTTON_TEXT_COLOR = { 0.85, 0.85, 0.82 }
local DELETE_BUTTON_TEXT_DISABLED_COLOR = { 0.5, 0.5, 0.48 }
local DELETE_BUTTON_SHADOW_COLOR = { 0, 0, 0, 1 }

local function EnsureDeleteButtonState(button)
    local letters = button.rustcoreDeleteLetters
    if not letters then return end
    local color = button:IsEnabled() and DELETE_BUTTON_TEXT_COLOR or DELETE_BUTTON_TEXT_DISABLED_COLOR
    for _, fs in ipairs(letters) do
        fs:SetTextColor(color[1], color[2], color[3])
    end
end

-- WoW font strings have no letter-tracking control, so the "DELETE" label is laid
-- out as individually spaced font strings instead of relying on the button's
-- built-in (hidden) text region.
local function LayoutDeleteButtonLetters(button, text)
    local letters = button.rustcoreDeleteLetters
    if not letters then
        letters = {}
        button.rustcoreDeleteLetters = letters
    end

    text = text or ""
    for i = #text + 1, #letters do
        letters[i]:Hide()
    end

    local fontPath = Rustcore.GetAssetPath("Font/BPpong.otf")
    local widths, totalWidth = {}, 0
    for i = 1, #text do
        local fs = letters[i]
        if not fs then
            fs = button:CreateFontString(nil, "OVERLAY")
            letters[i] = fs
        end
        fs:SetFont(fontPath, DELETE_BUTTON_FONT_SIZE, "")
        fs:SetShadowColor(DELETE_BUTTON_SHADOW_COLOR[1], DELETE_BUTTON_SHADOW_COLOR[2], DELETE_BUTTON_SHADOW_COLOR[3], DELETE_BUTTON_SHADOW_COLOR[4])
        fs:SetShadowOffset(2, -2)
        fs:SetText(text:sub(i, i))
        fs:Show()
        local w = fs:GetStringWidth()
        widths[i] = w
        totalWidth = totalWidth + w + (i < #text and DELETE_BUTTON_LETTER_SPACING or 0)
    end

    local x = -totalWidth / 2
    for i = 1, #text do
        local fs = letters[i]
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", button, "CENTER", x, BUTTON_TEXT_OFFSET_Y)
        x = x + widths[i] + DELETE_BUTTON_LETTER_SPACING
    end

    EnsureDeleteButtonState(button)
end

function RustcoreTheme.SkinDeleteButton(button)
    if button.rustcoreDeleteBtnSkin then
        EnsureDeleteButtonState(button)
        return
    end

    button:SetNormalTexture(Asset("RedButton copy.tga"))
    button:SetPushedTexture(Asset("RedButtonPressed copy.tga"))
    button:SetDisabledTexture(Asset("deletebuttonwait copy.tga"))
    button:SetPushedTextOffset(0, BUTTON_TEXT_OFFSET_Y)

    local normal   = button:GetNormalTexture()
    local pushed   = button:GetPushedTexture()
    local disabled = button:GetDisabledTexture()

    if normal   then normal:SetAllPoints(button)   end
    if pushed   then pushed:SetAllPoints(button)   end
    if disabled then
        disabled:ClearAllPoints()
        disabled:SetPoint("TOPLEFT",     button, "TOPLEFT",     -10, 0)
        disabled:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -10, 0)
    end

    button:SetHighlightTexture(Asset("RedButtonHighlight copy.tga"))
    local hl = button:GetHighlightTexture()
    if hl then
        hl:SetAllPoints(button)
        hl:SetVertexColor(1, 1, 1, 0.55)
    end

    local fontString = button:GetFontString()
    if fontString then
        fontString:SetAlpha(0)
        LayoutDeleteButtonLetters(button, fontString:GetText())
    end

    if not button.rustcoreDeleteTextHooked then
        button.SetText = function(self, text)
            LayoutDeleteButtonLetters(self, text)
        end
        button.rustcoreDeleteTextHooked = true
    end

    button:HookScript("OnEnable", EnsureDeleteButtonState)
    button:HookScript("OnDisable", EnsureDeleteButtonState)
    button.rustcoreDeleteBtnSkin = true
    EnsureDeleteButtonState(button)
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

function RustcoreTheme.CreateRivetPanelArt(parent, opacity, shadowOpacity, borderSize, tileEdges)
    opacity = opacity or FRAME_BACKGROUND_ALPHA
    shadowOpacity = shadowOpacity or 0
    borderSize = borderSize or FRAME_INSET
    local pieces = {}
    local shadowPieces = {}
    local borderPieces = {}
    local shadowBorderPieces = {}

    local function CreatePiece(name, textureName, layer, sublevel)
        local texture = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel)
        texture:SetTexture(Rustcore.GetAssetPath("UI/" .. textureName))
        texture:SetTexCoord(0, 1, 0, 1)
        texture:SetAlpha(opacity)
        pieces[name] = texture
        return texture
    end

    local function CreateShadowPiece(name, textureName)
        local texture = parent:CreateTexture(nil, "BACKGROUND", nil, -1)
        texture:SetTexture(Rustcore.GetAssetPath("UI/" .. textureName))
        texture:SetTexCoord(0, 1, 0, 1)
        texture:SetVertexColor(0, 0, 0, 1)
        texture:SetAlpha(shadowOpacity)
        shadowPieces[name] = texture
        return texture
    end

    local centerShadow = CreateShadowPiece("center", "newstatsC.tga")
    local center = CreatePiece("center", "newstatsC.tga")
    centerShadow:SetPoint("TOPLEFT", parent, "TOPLEFT", borderSize, -borderSize)
    centerShadow:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -borderSize, borderSize)
    center:SetPoint("TOPLEFT", parent, "TOPLEFT", borderSize, -borderSize)
    center:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -borderSize, borderSize)

    local shade = parent:CreateTexture(nil, "ARTWORK")
    shade:SetPoint("TOPLEFT", center, "TOPLEFT", 0, 0)
    shade:SetPoint("BOTTOMRIGHT", center, "BOTTOMRIGHT", 0, 0)
    shade:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    shade:SetVertexColor(0, 0, 0, 0.10 * opacity)

    local topShadow = CreateShadowPiece("top", "newstatsUB.tga")
    local top = CreatePiece("top", "newstatsUB.tga", "ARTWORK")
    topShadow:SetPoint("TOPLEFT", parent, "TOPLEFT", borderSize, 0)
    topShadow:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", -borderSize, -borderSize)
    top:SetPoint("TOPLEFT", parent, "TOPLEFT", borderSize, 0)
    top:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", -borderSize, -borderSize)

    local bottomShadow = CreateShadowPiece("bottom", "newstatsBB.tga")
    local bottom = CreatePiece("bottom", "newstatsBB.tga", "ARTWORK")
    bottomShadow:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", borderSize, borderSize)
    bottomShadow:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -borderSize, 0)
    bottom:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", borderSize, borderSize)
    bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -borderSize, 0)

    local leftShadow = CreateShadowPiece("left", "newstatsLB.tga")
    local left = CreatePiece("left", "newstatsLB.tga", "ARTWORK")
    leftShadow:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -borderSize)
    leftShadow:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", borderSize, borderSize)
    left:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -borderSize)
    left:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", borderSize, borderSize)

    local rightShadow = CreateShadowPiece("right", "newstatsRB.tga")
    local right = CreatePiece("right", "newstatsRB.tga", "ARTWORK")
    rightShadow:SetPoint("TOPLEFT", parent, "TOPRIGHT", -borderSize, -borderSize)
    rightShadow:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, borderSize)
    right:SetPoint("TOPLEFT", parent, "TOPRIGHT", -borderSize, -borderSize)
    right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, borderSize)

    local topLeftShadow = CreateShadowPiece("topLeft", "newstatsULC.tga")
    local topLeft = CreatePiece("topLeft", "newstatsULC.tga", "ARTWORK")
    topLeftShadow:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    topLeftShadow:SetSize(borderSize, borderSize)
    topLeft:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    topLeft:SetSize(borderSize, borderSize)

    local topRightShadow = CreateShadowPiece("topRight", "newstatsURC.tga")
    local topRight = CreatePiece("topRight", "newstatsURC.tga", "ARTWORK")
    topRightShadow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    topRightShadow:SetSize(borderSize, borderSize)
    topRight:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    topRight:SetSize(borderSize, borderSize)

    local bottomLeftShadow = CreateShadowPiece("bottomLeft", "newstatsLLC.tga")
    local bottomLeft = CreatePiece("bottomLeft", "newstatsLLC.tga", "ARTWORK")
    bottomLeftShadow:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    bottomLeftShadow:SetSize(borderSize, borderSize)
    bottomLeft:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
    bottomLeft:SetSize(borderSize, borderSize)

    local bottomRightShadow = CreateShadowPiece("bottomRight", "newstatsLRC.tga")
    local bottomRight = CreatePiece("bottomRight", "newstatsLRC.tga", "ARTWORK")
    bottomRightShadow:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    bottomRightShadow:SetSize(borderSize, borderSize)
    bottomRight:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    bottomRight:SetSize(borderSize, borderSize)

    borderPieces[1] = top
    borderPieces[2] = bottom
    borderPieces[3] = left
    borderPieces[4] = right
    borderPieces[5] = topLeft
    borderPieces[6] = topRight
    borderPieces[7] = bottomLeft
    borderPieces[8] = bottomRight
    shadowBorderPieces[1] = topShadow
    shadowBorderPieces[2] = bottomShadow
    shadowBorderPieces[3] = leftShadow
    shadowBorderPieces[4] = rightShadow
    shadowBorderPieces[5] = topLeftShadow
    shadowBorderPieces[6] = topRightShadow
    shadowBorderPieces[7] = bottomLeftShadow
    shadowBorderPieces[8] = bottomRightShadow

    -- Optional repeating top/bottom edge. The default is one copy stretched
    -- across the whole span, which is fine on a tall window but smears badly
    -- on something as short and wide as the durability row. Tiling draws the
    -- art at its own aspect instead, repeated end to end, so the rivets keep
    -- their real spacing whatever the panel's width.
    --
    -- Only the last tile in a row is cropped, via texture coordinates, and the
    -- pool only ever grows. A tile is registered into pieces/shadowPieces while
    -- it is on screen and unregistered once the panel shrinks past it, so the
    -- alpha and show/hide loops callers run over those tables always see
    -- exactly the tiles that are visible -- and never revive a stale one.
    if tileEdges then
        local edges = {
            { base = "top",    anchor = "TOPLEFT",    art = "newstatsUB.tga",
              registry = pieces,       tiles = { top } },
            { base = "bottom", anchor = "BOTTOMLEFT", art = "newstatsBB.tga",
              registry = pieces,       tiles = { bottom } },
            { base = "top",    anchor = "TOPLEFT",    art = "newstatsUB.tga",
              registry = shadowPieces, tiles = { topShadow },    shadow = true },
            { base = "bottom", anchor = "BOTTOMLEFT", art = "newstatsBB.tga",
              registry = shadowPieces, tiles = { bottomShadow }, shadow = true },
        }

        local function LayoutEdgeTiles()
            local span = parent:GetWidth()
            if not span then return end
            span = span - borderSize * 2
            if span <= 0 then return end

            local tileW = borderSize * EDGE_TILE_ASPECT
            -- The epsilon keeps an exact fit from rounding up into a sliver.
            local wanted = math.max(1, math.ceil(span / tileW - 0.002))

            for _, edge in ipairs(edges) do
                for index = 1, wanted do
                    local key = index == 1 and edge.base or (edge.base .. index)
                    local tile = edge.tiles[index]
                    if not tile then
                        if edge.shadow then
                            tile = CreateShadowPiece(key, edge.art)
                        else
                            tile = CreatePiece(key, edge.art, "ARTWORK")
                        end
                        -- Born matching the tile that is already correct, so a
                        -- resize after an opacity change can't create a tile at
                        -- the alpha the panel had when it was first built.
                        tile:SetAlpha(edge.tiles[1]:GetAlpha())
                        if edge.tiles[1]:IsShown() then tile:Show() else tile:Hide() end
                        edge.tiles[index] = tile
                    end
                    local used = math.max(1, math.min(tileW, span - (index - 1) * tileW))
                    tile:ClearAllPoints()
                    tile:SetPoint(edge.anchor, parent, edge.anchor,
                        borderSize + (index - 1) * tileW, 0)
                    tile:SetSize(used, borderSize)
                    tile:SetTexCoord(0, used / tileW, 0, 1)
                    edge.registry[key] = tile
                end
                for index = wanted + 1, #edge.tiles do
                    edge.registry[edge.base .. index] = nil
                    edge.tiles[index]:Hide()
                end
            end
        end

        parent:HookScript("OnSizeChanged", LayoutEdgeTiles)
        LayoutEdgeTiles()
    end

    return {
        pieces = pieces,
        shadowPieces = shadowPieces,
        borderPieces = borderPieces,
        shadowBorderPieces = shadowBorderPieces,
        center = center,
        shade = shade,
    }
end

function RustcoreTheme.SkinSlider(slider, width, trackYOffset)
    if slider.rustcoreThemeSliderTrack then
        slider.rustcoreThemeSliderTrack:SetWidth(width)
        return slider.rustcoreThemeSliderTrack
    end

    local sliderName = slider.GetName and slider:GetName()
    if sliderName then
        for _, suffix in ipairs({ "Background", "Left", "Middle", "Right" }) do
            local region = _G[sliderName .. suffix]
            if region then region:SetTexture(nil) end
        end
    end

    -- UISliderTemplate bakes its groove texture straight onto the slider's
    -- BACKGROUND layer; SetTexture(nil) removes it outright so it can't be
    -- re-shown by any later enable/disable state change.
    local numRegions = select("#", slider:GetRegions())
    for i = 1, numRegions do
        local region = select(i, slider:GetRegions())
        if region and region.GetObjectType and region:GetObjectType() == "Texture" then
            region:SetTexture(nil)
        end
    end

    -- Drawn in ARTWORK (above the template's BACKGROUND groove) so our track
    -- fully covers the native texture even if it couldn't be stripped above.
    local track = slider:CreateTexture(nil, "ARTWORK")
    track:SetPoint("CENTER", slider, "CENTER", 0, trackYOffset or -1)
    track:SetSize(width, 24)
    ApplyTexture(track, Asset("Rustcore-texture-slider-1 copy.tga"))

    slider:SetThumbTexture(Asset("Rustcore-texture-sliderhandle-2.tga"))
    local thumb = slider:GetThumbTexture()
    if thumb then
        thumb:SetSize(SLIDER_THUMB_WIDTH, SLIDER_THUMB_HEIGHT)
        thumb:SetVertexColor(0.92, 0.92, 0.92, 1)
    end

    slider.rustcoreThemeSliderTrack = track
    return track
end
