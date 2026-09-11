-- RustcoreSelfFoundBuff: shows verified Self Found status as a real-looking
-- buff on the player's own buff bar (spell 431567, Blizzard's actual
-- Hardcore "Self-Found Adventurer" buff) instead of a custom stats-panel icon.
--
-- Two earlier approaches (shifting BuffFrame's own anchor, then reading and
-- reassigning Blizzard's real BuffButtonN positions) both fought Blizzard's
-- own layout code and lost - the real buttons kept snapping back to their
-- own computed slots, leaving our icon stranded on top of/beside them.
--
-- This version stops trying to cooperate with Blizzard's layout entirely:
-- the whole native BuffFrame is made invisible and mouse-transparent (alpha
-- 0, EnableMouse off - not :Hide(), so Blizzard's own bookkeeping is left
-- alone), and we draw our own row of icons from scratch by reading aura
-- data directly via UnitAura("player", i, "HELPFUL"). Debuffs are already
-- shown natively elsewhere on screen and are intentionally not duplicated
-- here. Our self-found icon is always slot 1; every real buff follows in
-- slot 2, 3, ... in the same top-right-anchored, left-growing, row-wrapping
-- grid BuffFrame itself uses (see MANUAL_OFFSET_X/Y below for fine-tuning
-- on clients where that default is a pixel or two off).
--
-- A second, independent display mirrors this same hide-and-redraw approach
-- on TargetFrame when the targeted player is locally or remotely verified
-- as Self Found, since the real aura row never includes our synthetic buff.

RustcoreSelfFoundBuff = RustcoreSelfFoundBuff or {}

local TOOLTIP_TITLE = "Self-Found Adventurer"
local TOOLTIP_BODY = "Unable to trade, use the auction house, or send and receive most mail."

local function ShowSelfFoundTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText(TOOLTIP_TITLE, 1, 0.82, 0, 1, true)
    GameTooltip:AddLine(TOOLTIP_BODY, 1, 1, 1, true)
    GameTooltip:Show()
end
-- Matches BuffButtonTemplate's native 30x30 size; native spacing between
-- icons reads slightly wider than the plain 3px button-template gap.
local BUTTON_SIZE = 30
local GAP = 5
local REFRESH_INTERVAL = 0.2

-- Native buffs pulse (fade in/out) once they hit their last 30 seconds, and
-- their duration text turns white once it's showing seconds instead of
-- minutes/hours - matched here so our redrawn icons read the same way.
local FLASH_THRESHOLD_SECONDS = 30
local FLASH_MIN_ALPHA = 0.5
local FLASH_PERIOD = 1
local COLOR_DURATION_NORMAL = { 1, 0.82, 0 }
local COLOR_DURATION_SECONDS = { 1, 1, 1 }

-- Blizzard's own FrameXML anchors real slot 1 at BuffFrame's TOPRIGHT with
-- a 0,0 offset, but this client's Edit Mode buff frame renders about half
-- an icon further right than that - shifted left by half BUTTON_SIZE to
-- compensate. Nudge further and /reload if a given build is still off by a
-- few pixels - a live offset can't be derived from a screenshot alone.
local MANUAL_OFFSET_X, MANUAL_OFFSET_Y = -(BUTTON_SIZE / 2), 0

local iconFrame
local buttonPool = {}
local active = false
local sinceRefresh = 0
local activeButtonCount = 0
local RefreshAuraLayout -- forward-declared: OnUpdate (below) needs to call it before it's defined
local HideNativeBuffFrame -- forward-declared: OnUpdate (below) needs to call it before it's defined
local HideNativeTargetAurasForVerifiedTarget -- forward-declared: OnUpdate (below) needs to call it before it's defined
local RefreshTargetIcon -- forward-declared: OnUpdate (below) needs to call it before it's defined
local UpdateAuraFlash -- forward-declared: OnUpdate (below) needs to call it before it's defined

local function EnsureIconFrame()
    if iconFrame then return iconFrame end

    iconFrame = CreateFrame("Button", "RustcoreSelfFoundBuffIcon", UIParent)
    iconFrame:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    iconFrame:SetFrameStrata("MEDIUM")
    iconFrame:EnableMouse(true)
    iconFrame:Hide()

    iconFrame.texture = iconFrame:CreateTexture(nil, "ARTWORK")
    iconFrame.texture:SetAllPoints(iconFrame)
    -- Real BuffButtonTemplate icons are shown uncropped (full 0-1 texcoords) -
    -- the thin border you see on a normal buff is baked into the icon art
    -- itself, not a separate frame texture.

    iconFrame:SetScript("OnEnter", function(self)
        ShowSelfFoundTooltip(self)
    end)
    iconFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Self-heal on a short throttle instead of depending on any one Blizzard
    -- event/function to fire reliably. OnUpdate only runs while the frame is
    -- shown, so this costs nothing while self-found is inactive. Hiding the
    -- native BuffFrame is reasserted every tick (cheap, single call) since
    -- Blizzard's own aura fade animations can fight a one-time SetAlpha.
    iconFrame:SetScript("OnUpdate", function(self, elapsed)
        HideNativeBuffFrame()
        HideNativeTargetAurasForVerifiedTarget()
        pcall(UpdateAuraFlash)
        sinceRefresh = sinceRefresh + elapsed
        if sinceRefresh < REFRESH_INTERVAL then return end
        sinceRefresh = 0
        pcall(RefreshAuraLayout)
        -- RefreshTargetIcon otherwise only runs reactively off
        -- PLAYER_TARGET_CHANGED/UNIT_AURA. TargetFrame.buffs can get
        -- repositioned by Blizzard (e.g. Edit Mode layout changes) without
        -- either of those firing, leaving our icon anchored to a stale
        -- position until the next qualifying event - so self-heal it here
        -- the same way the native buff frame hiding above already does.
        pcall(RefreshTargetIcon)
    end)

    return iconFrame
end

local function CreateAuraButton()
    local b = CreateFrame("Button", nil, UIParent)
    b:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    b:SetFrameStrata("MEDIUM")
    b:EnableMouse(true)
    b:RegisterForClicks("RightButtonUp")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)

    -- Weapon-enchant (poison/oil/stone) icons get a purple border in the
    -- native UI to set them apart from real buffs; we hide Blizzard's own
    -- TempEnchant buttons so we have to draw that border ourselves. Rather
    -- than fake it, this is Blizzard's own asset for exactly this purpose -
    -- the native BuffButtonTempEnchant template (used by TempEnchant1/2)
    -- overlays this same texture at 32x32 centered on a 30x30 button
    -- (BuffFrame.xml), and the purple color is baked into the art itself.
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetTexture("Interface\\Buttons\\UI-TempEnchant-Border")
    b.border:SetSize(32, 32)
    b.border:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.border:Hide()

    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)

    b.duration = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.duration:SetPoint("TOP", b, "BOTTOM", 0, 0)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        if self.weaponSlot then
            GameTooltip:SetInventoryItem("player", self.weaponSlot)
        elseif self.auraIndex and GameTooltip.SetUnitAura then
            GameTooltip:SetUnitAura("player", self.auraIndex, self.auraFilter)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    b:SetScript("OnClick", function(self)
        if self.auraIndex then
            pcall(CancelUnitBuff, "player", self.auraIndex, self.auraFilter)
        end
    end)

    return b
end

local function AcquireButton(i)
    local b = buttonPool[i]
    if not b then
        b = CreateAuraButton()
        buttonPool[i] = b
    end
    return b
end

local DURATION_SECONDS_THRESHOLD = 60

local function FormatDuration(seconds)
    if seconds >= 3600 then
        return math.ceil(seconds / 3600) .. " h"
    elseif seconds >= DURATION_SECONDS_THRESHOLD then
        return math.ceil(seconds / 60) .. " m"
    else
        return math.max(math.ceil(seconds), 0) .. " s"
    end
end

local function ComputePerRow()
    local frame = _G.BuffFrame
    local width = frame and frame.GetWidth and frame:GetWidth()
    if not width or width <= 0 then return 6 end
    return math.max(math.floor((width + GAP) / (BUTTON_SIZE + GAP)), 1)
end

-- 1-based grid slot -> anchored position, matching BuffFrame's own
-- top-right-anchored, left-growing, row-wrapping layout. baseX/baseY apply
-- MANUAL_OFFSET_X/Y on top of the verified (0,0)-at-TOPRIGHT default.
local function PositionSlot(button, slotIndex, perRow, baseX, baseY)
    local col = (slotIndex - 1) % perRow
    local row = math.floor((slotIndex - 1) / perRow)
    button:ClearAllPoints()
    button:SetPoint("TOPRIGHT", _G.BuffFrame, "TOPRIGHT",
        baseX - (col * (BUTTON_SIZE + GAP)), baseY - (row * (BUTTON_SIZE + GAP)))
end

function HideNativeBuffFrame()
    local frame = _G.BuffFrame
    if frame then
        frame:SetAlpha(0)
        frame:EnableMouse(false)
    end

    -- Weapon-enchant (poison/oil/stone) buffs aren't part of BuffFrame at
    -- all in Classic/TBC FrameXML - there's no wrapping "TemporaryEnchantFrame"
    -- container, just three standalone global buttons. Hiding BuffFrame alone
    -- left these visible, showing Blizzard's own purple-bordered icon
    -- underneath/beside ours.
    for i = 1, 3 do
        local enchantButton = _G["TempEnchant" .. i]
        if enchantButton then
            enchantButton:SetAlpha(0)
            enchantButton:EnableMouse(false)
        end
    end
end

local function ShowNativeBuffFrame()
    local frame = _G.BuffFrame
    if frame then
        frame:SetAlpha(1)
        frame:EnableMouse(true)
    end

    for i = 1, 3 do
        local enchantButton = _G["TempEnchant" .. i]
        if enchantButton then
            enchantButton:SetAlpha(1)
            enchantButton:EnableMouse(true)
        end
    end
end

function RefreshAuraLayout()
    if not active or not iconFrame or not _G.BuffFrame then return end

    HideNativeBuffFrame()

    local perRow = ComputePerRow()
    local baseX, baseY = MANUAL_OFFSET_X, MANUAL_OFFSET_Y
    PositionSlot(iconFrame, 1, perRow, baseX, baseY)

    local slotIndex = 2
    local usedCount = 0
    local now = GetTime()

    local auraIndex = 1
    while true do
        local name, icon, count, _, duration, expirationTime = UnitAura("player", auraIndex, "HELPFUL")
        if not name then break end

        usedCount = usedCount + 1
        local b = AcquireButton(usedCount)
        b.auraIndex = auraIndex
        b.auraFilter = "HELPFUL"
        b.weaponSlot = nil
        b.border:Hide()
        b.icon:SetTexture(icon)
        b.count:SetText((count and count > 1) and tostring(count) or "")
        if duration and duration > 0 and expirationTime then
            b.expirationTime = expirationTime
        else
            b.expirationTime = nil
            b.duration:SetText("")
        end
        PositionSlot(b, slotIndex, perRow, baseX, baseY)
        b:Show()

        slotIndex = slotIndex + 1
        auraIndex = auraIndex + 1
    end

    -- Temporary weapon enchants (poisons/oils/stones) aren't real auras -
    -- UnitAura never returns them - so without this they silently vanish
    -- from our redrawn bar even though Blizzard's native BuffFrame shows
    -- them via its own separate TemporaryEnchantFrame code path.
    local function AddWeaponEnchantSlot(hasEnchant, expirationMs, charges, invSlot)
        if not hasEnchant then return end
        usedCount = usedCount + 1
        local b = AcquireButton(usedCount)
        b.auraIndex = nil
        b.auraFilter = nil
        b.weaponSlot = invSlot
        b.border:Show()
        b.icon:SetTexture(GetInventoryItemTexture("player", invSlot))
        b.count:SetText((charges and charges > 0) and tostring(charges) or "")
        if expirationMs and expirationMs > 0 then
            b.expirationTime = now + (expirationMs / 1000)
        else
            b.expirationTime = nil
            b.duration:SetText("")
        end
        PositionSlot(b, slotIndex, perRow, baseX, baseY)
        b:Show()

        slotIndex = slotIndex + 1
    end

    local hasMainHandEnchant, mainHandExpiration, mainHandCharges, _mainHandEnchantID,
          hasOffHandEnchant, offHandExpiration, offHandCharges = GetWeaponEnchantInfo()
    AddWeaponEnchantSlot(hasMainHandEnchant, mainHandExpiration, mainHandCharges, INVSLOT_MAINHAND)
    AddWeaponEnchantSlot(hasOffHandEnchant, offHandExpiration, offHandCharges, INVSLOT_OFFHAND)

    for i = 1, usedCount do
        local b = buttonPool[i]
        if b.expirationTime then
            local remaining = b.expirationTime - now
            b.duration:SetText(FormatDuration(remaining))
            local color = (remaining < DURATION_SECONDS_THRESHOLD) and COLOR_DURATION_SECONDS or COLOR_DURATION_NORMAL
            b.duration:SetTextColor(color[1], color[2], color[3])
        end
    end

    activeButtonCount = usedCount

    for i = usedCount + 1, #buttonPool do
        buttonPool[i]:SetAlpha(1)
        buttonPool[i]:Hide()
    end
end

-- Native buff icons pulse over their last 30 seconds; run every frame (not
-- on the throttled refresh timer) so the fade reads smoothly instead of
-- stepping in REFRESH_INTERVAL-sized jumps.
function UpdateAuraFlash()
    if not active or activeButtonCount == 0 then return end
    local now = GetTime()
    for i = 1, activeButtonCount do
        local b = buttonPool[i]
        if b and b:IsShown() and b.expirationTime then
            local remaining = b.expirationTime - now
            if remaining > 0 and remaining <= FLASH_THRESHOLD_SECONDS then
                local phase = (now % FLASH_PERIOD) / FLASH_PERIOD
                local wave = 0.5 - 0.5 * math.cos(phase * 2 * math.pi)
                b:SetAlpha(1 - wave * (1 - FLASH_MIN_ALPHA))
            else
                b:SetAlpha(1)
            end
        end
    end
end

-- ── Verified-target display (TargetFrame) ────────────────────────────────
-- TargetFrame draws its own buff/debuff icons reflecting the targeted
-- unit's real aura data, in two dedicated sub-containers (TargetFrame.buffs
-- / .debuffs) separate from the player's own BuffFrame above. Since our
-- self-found icon isn't a real aura it never shows up there on its own -
-- for a verified player we mirror the main bar's approach exactly: hide both
-- native containers and redraw everything ourselves from UnitAura data with
-- our icon in slot 1, so real auras start at slot 2. Other targets remain
-- native and untouched.
--
-- Blizzard's own target/focus aura buttons render at 21x21 (smaller than
-- the 30x30 main buff bar) - matched here so ours doesn't stand out.
local TARGET_BUTTON_SIZE = 21
local TARGET_GAP = 3
local TARGET_ROW_WIDTH = 122 -- Blizzard's own max row width for these auras
local TARGET_PER_ROW = math.max(math.floor((TARGET_ROW_WIDTH + TARGET_GAP) / (TARGET_BUTTON_SIZE + TARGET_GAP)), 1)
local TARGET_START_X = 21
local TARGET_BOTTOM_START_Y = 28
local TARGET_TOP_START_Y = -14

local targetIcon
local targetButtonPool = {}

local function EnsureTargetIcon()
    if targetIcon then return targetIcon end

    targetIcon = CreateFrame("Button", "RustcoreSelfFoundTargetIcon", UIParent)
    targetIcon:SetSize(TARGET_BUTTON_SIZE, TARGET_BUTTON_SIZE)
    targetIcon:SetFrameStrata("MEDIUM")
    targetIcon:EnableMouse(true)
    targetIcon:Hide()

    targetIcon.texture = targetIcon:CreateTexture(nil, "ARTWORK")
    targetIcon.texture:SetAllPoints(targetIcon)

    targetIcon:SetScript("OnEnter", function(self)
        ShowSelfFoundTooltip(self)
    end)
    targetIcon:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return targetIcon
end

-- Blizzard's own debuff-border colours. These used to be read straight off the
-- global DebuffTypeColor, which is where the ring on a native target frame gets
-- its colour from -- but the Anniversary client stopped defining that global, so
-- the lookup came back nil and every debuff fell through to the undispellable
-- red. A poison read as red, a curse read as red, and the ring stopped saying
-- anything at all. The numbers below are the ones Blizzard shipped, so a client
-- that still exposes the table is preferred over them and the two agree anyway.
local DEBUFF_TYPE_COLOR = {
    Magic   = { r = 0.20, g = 0.60, b = 1.00 },
    Curse   = { r = 0.60, g = 0.00, b = 1.00 },
    Disease = { r = 0.60, g = 0.40, b = 0.00 },
    Poison  = { r = 0.00, g = 0.60, b = 0.00 },
    none    = { r = 0.80, g = 0.00, b = 0.00 },
}

-- UnitAura reports "no dispel type" as nil on some clients and as an empty
-- string on others, and neither is a key in either table.
local function DebuffColor(debuffType)
    local key = debuffType
    if key == nil or key == "" then key = "none" end

    local palette = _G.DebuffTypeColor
    local color = palette and (palette[key] or palette["none"])
    return color or DEBUFF_TYPE_COLOR[key] or DEBUFF_TYPE_COLOR.none
end

local function CreateTargetAuraButton()
    local b = CreateFrame("Button", nil, UIParent)
    b:SetSize(TARGET_BUTTON_SIZE, TARGET_BUTTON_SIZE)
    b:SetFrameStrata("MEDIUM")
    b:EnableMouse(true)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)

    -- Debuffs wear the coloured ring real ones do. Blizzard's own asset and
    -- texcoords, taken from the TargetDebuffButton template, so it lines up with
    -- the native frames rather than approximating them. The ring art is white;
    -- the colour comes from DebuffColor, which is what tells Magic from Curse
    -- from Poison at a glance -- and plain red for anything undispellable.
    b.debuffBorder = b:CreateTexture(nil, "OVERLAY")
    b.debuffBorder:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
    b.debuffBorder:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
    b.debuffBorder:SetPoint("TOPLEFT", b, "TOPLEFT", -1, 1)
    b.debuffBorder:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 1, -1)
    b.debuffBorder:Hide()

    -- Matches the radial "wipe" every real buff/debuff button shows for
    -- time remaining, including the faint glow along the swipe edge. The
    -- countdown-number overlay is a separate opt-in Blizzard adds on top of
    -- the swipe itself - real buff/debuff buttons don't show it, so it's
    -- explicitly hidden here to match.
    b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cooldown:SetAllPoints(b)
    b.cooldown:SetDrawEdge(true)
    b.cooldown:SetReverse(true)
    if b.cooldown.SetHideCountdownNumbers then
        b.cooldown:SetHideCountdownNumbers(true)
    end

    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        if self.auraIndex and GameTooltip.SetUnitAura then
            GameTooltip:SetUnitAura("target", self.auraIndex, self.auraFilter)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return b
end

local function AcquireTargetButton(i)
    local b = targetButtonPool[i]
    if not b then
        b = CreateTargetAuraButton()
        targetButtonPool[i] = b
    end
    return b
end

-- `rowOffset` pushes a run of icons onto its own line below the ones above it.
-- Debuffs use it so they never share a row with buffs, the way the native
-- target frame keeps its two rows apart.
local function PositionTargetSlot(button, slotIndex, rowOffset)
    local col = (slotIndex - 1) % TARGET_PER_ROW
    local row = math.floor((slotIndex - 1) / TARGET_PER_ROW) + (rowOffset or 0)
    button:ClearAllPoints()

    -- Match Blizzard's TargetFrame_UpdateBuffAnchor constants directly.
    -- This avoids depending on TargetFrame.buffs being positioned by Edit
    -- Mode first, while still honoring the live Buffs on Top setting.
    local step = TARGET_BUTTON_SIZE + TARGET_GAP
    if _G.TargetFrame.buffsOnTop then
        button:SetPoint("BOTTOMLEFT", _G.TargetFrame, "TOPLEFT",
            TARGET_START_X + (col * step),
            TARGET_TOP_START_Y + (row * step))
    else
        button:SetPoint("TOPLEFT", _G.TargetFrame, "BOTTOMLEFT",
            TARGET_START_X + (col * step),
            TARGET_BOTTOM_START_Y - (row * step))
    end
end

-- TargetFrame.buffs/.debuffs (used above only as an occasional anchor
-- reference by Blizzard's own code) are NOT the real parent of the actual
-- icon buttons - those are individually named and parented directly to
-- TargetFrame itself (TargetFrameBuff1, TargetFrameDebuff1, ...), so they
-- have to be hidden one at a time rather than via a single container alpha.
local function SetNativeTargetAurasHidden(hidden)
    for _, prefix in ipairs({ "TargetFrameBuff", "TargetFrameDebuff" }) do
        local i = 1
        while true do
            local b = _G[prefix .. i]
            if not b then break end
            b:SetAlpha(hidden and 0 or 1)
            b:EnableMouse(not hidden)
            i = i + 1
        end
    end
end

local function IsVerifiedTarget()
    if not UnitExists("target") or not UnitIsPlayer("target") or not _G.TargetFrame then
        return false
    end
    if UnitIsUnit("target", "player") then
        return Rustcore.GetSelfFoundIconState and Rustcore.GetSelfFoundIconState() == "verified"
    end
    return RustcoreSelfFoundComm
        and RustcoreSelfFoundComm.IsKnownSelfFound
        and RustcoreSelfFoundComm.IsKnownSelfFound(UnitName("target"))
end

function HideNativeTargetAurasForVerifiedTarget()
    if IsVerifiedTarget() then
        SetNativeTargetAurasHidden(true)
    end
end

function RefreshTargetIcon()
    local icon = EnsureTargetIcon()

    if not IsVerifiedTarget() then
        icon:Hide()
        SetNativeTargetAurasHidden(false)
        for _, b in ipairs(targetButtonPool) do
            b:Hide()
        end
        return
    end

    SetNativeTargetAurasHidden(true)

    icon.texture:SetTexture(Rustcore.GetSelfFoundIconTexture())
    PositionTargetSlot(icon, 1)
    icon:Show()

    local usedCount = 0

    -- Buffs and debuffs are laid out as two separate runs rather than one
    -- continuous list. Sharing a counter made a debuff simply follow the last
    -- buff along the same row, which is not how the native target frame reads:
    -- there, debuffs are their own line and carry a coloured ring.
    local function AddAura(filter, slotIndex, rowOffset)
        local auraIndex = 1
        while true do
            local name, auraIcon, count, debuffType, duration, expirationTime =
                UnitAura("target", auraIndex, filter)
            if not name then break end

            usedCount = usedCount + 1
            local b = AcquireTargetButton(usedCount)
            b.auraIndex = auraIndex
            b.auraFilter = filter
            b.icon:SetTexture(auraIcon)
            b.count:SetText((count and count > 1) and tostring(count) or "")
            if duration and duration > 0 and expirationTime then
                b.cooldown:SetCooldown(expirationTime - duration, duration)
                b.cooldown:Show()
            else
                b.cooldown:Hide()
            end

            if filter == "HARMFUL" then
                local color = DebuffColor(debuffType)
                b.debuffBorder:SetVertexColor(color.r, color.g, color.b)
                b.debuffBorder:Show()
            else
                b.debuffBorder:Hide()
            end

            PositionTargetSlot(b, slotIndex, rowOffset)
            b:Show()

            slotIndex = slotIndex + 1
            auraIndex = auraIndex + 1
        end
        return slotIndex
    end

    -- Buffs continue the row the Self-Found icon opened at slot 1.
    local afterBuffs = AddAura("HELPFUL", 2, 0)
    -- Debuffs start fresh on the line under whatever the buffs filled.
    local buffRows = math.ceil((afterBuffs - 1) / TARGET_PER_ROW)
    AddAura("HARMFUL", 1, buffRows)

    for i = usedCount + 1, #targetButtonPool do
        targetButtonPool[i]:Hide()
    end
end

function RustcoreSelfFoundBuff.RefreshTarget()
    pcall(RefreshTargetIcon)
end

function RustcoreSelfFoundBuff.Refresh()
    EnsureIconFrame()

    local state = Rustcore.GetSelfFoundIconState and Rustcore.GetSelfFoundIconState()
    local buffEnabled = Rustcore.GetSetting("selfFoundBuffEnabled") ~= false
    active = state == "verified" and buffEnabled

    if active then
        iconFrame.texture:SetTexture(Rustcore.GetSelfFoundIconTexture())
        iconFrame:Show()
        pcall(RefreshAuraLayout)
    else
        iconFrame:Hide()
        ShowNativeBuffFrame()
        for _, b in ipairs(buttonPool) do
            b:Hide()
        end
    end

    pcall(RefreshTargetIcon)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterUnitEvent("UNIT_AURA", "player", "target")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        -- BuffFrame may not have settled yet at this exact point; a short
        -- delay lets Blizzard finish its own first layout pass before we
        -- start reading/hiding it.
        C_Timer.After(0.5, function()
            pcall(RustcoreSelfFoundBuff.Refresh)
        end)
    elseif event == "PLAYER_TARGET_CHANGED" then
        RustcoreSelfFoundBuff.RefreshTarget()
    else
        pcall(RefreshAuraLayout)
        RustcoreSelfFoundBuff.RefreshTarget()
    end
end)
