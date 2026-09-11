-- Rustcore: Custom durability HUD
-- Per-slot artwork replaces WoW's native DurabilityFrame when enabled.
-- Normal mode: only shows slots at or below 20% durability.
-- Show-all mode: shows every equipped slot with a durability value.

RustcoreDurability = {}

local BODY_FONT_PATH    -- resolved in Init

-- Frame sizing
local FRAME_W           = 110
local FRAME_H           = 38
local SLOT_GAP          = -2

-- Horizontal mode sits the frames side by side instead of stacking them, so
-- SLOT_GAP's overlap does not carry over: it exists to hide a transparent
-- sliver along the *bottom* edge of the frame art, and side-by-side frames
-- never put that edge over anything. What the art does carry on its left and
-- right edges is padding, which reads as a wide gutter once the frames sit
-- flush -- so this pulls them back together by roughly that much. Tune here;
-- nothing else depends on the value.
local H_SLOT_GAP        = -4

-- Optional panel background (durHUDBackground). Reuses the same rivet art as
-- the stats window and the death log so the three read as one set.
--
-- BG_BORDER is how wide that art draws its border; the BG_PAD values are how
-- far the counters are held off each container edge.
--
-- They are split per side rather than shared because an even inset does not
-- read as even here. The counter artwork carries more dead space along its
-- right edge than its left, so a matching right inset looks like a wider
-- gutter; trimming it is what actually centres the row. Top and bottom sit
-- slightly inside the border for the same reason -- the counter frames are
-- only 38 tall, and a full border's worth of clearance above and below left
-- the panel looking mostly empty.
--
-- Undershooting the border is safe: the counters are child frames, so they
-- always draw above the parent's border textures. A smaller inset tucks a
-- counter nearer the border, it never lets the border cover one.
local HUD_BG_BORDER     = 14
local HUD_BG_PAD_LEFT   = 14
local HUD_BG_PAD_RIGHT  = 8
local HUD_BG_PAD_VERT   = 11
local HUD_BG_ALPHA      = 0.78

-- The padding exists only to clear the border art, so it follows the
-- background on and off instead of being a setting of its own.
local function BackgroundPadding()
    if not Rustcore.GetSetting("durHUDBackground") then return 0, 0, 0 end
    return HUD_BG_PAD_LEFT, HUD_BG_PAD_RIGHT, HUD_BG_PAD_VERT
end

-- Counter frame overlay art is 1890x558 (native); stretched to FRAME_W at full
-- height it squashes the icon cutout into a tall rectangle, so the overlay is
-- sized to this shorter height (and vertically centered) to keep the cutout square.
local COUNTER_FRAME_H   = 32

-- Counter digit layout — positions as fractions of FRAME_W, all relative to "LEFT"
-- Counter area sits in the right portion of the counter overlay texture.
local COUNTER_CENTER_X  = 0.62    -- center of counter area as fraction of FRAME_W
local DIGIT_SPACING     = 0.148   -- distance between adjacent digit centers (fraction of FRAME_W)
local DIGIT_SLOT_W      = 16      -- pixel width of each clipping digit slot
local DIGIT_FONT_SIZE   = 13
-- Clipping window for animation — only one character tall so the roll looks like
-- a physical counter drum, not a digit flying across the whole frame.
local DIGIT_SLOT_H      = DIGIT_FONT_SIZE + 4

-- Per-digit pixel nudge: { hundreds, tens, ones }
-- Positive = right, negative = left.  Applied on top of the spacing formula.
local DIGIT_NUDGE = { -5, -2, 1 }

local COUNTER_ROLL_DURATION = 0.18  -- seconds per digit roll

-- Low-durability state triggers at 5 points remaining or 20% remaining,
-- whichever the item reaches first (mirrors WoW Classic's own durability frame).
local MIN_DURABILITY_POINTS = 5
local LOW_THRESHOLD_PCT     = 0.20

-- Threshold (as a fraction of max durability) at which the low-durability
-- state triggers for a given item: whichever of "5 points remaining" or
-- "20% remaining" is reached first, i.e. whichever is the larger fraction.
-- Capped below 1.0 to avoid a divide-by-zero in GetDurabilityColor for
-- items with very low max durability.
local function GetLowThresholdPct(maximum)
    if not maximum or maximum <= 0 then return LOW_THRESHOLD_PCT end
    return math.min(0.999, math.max(LOW_THRESHOLD_PCT, MIN_DURABILITY_POINTS / maximum))
end

local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Equipped slots with durability. Slot 15 (Back/Cloak) omitted — no durability.
local SLOT_DATA = { 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }

-- Icon layout constants (sized to fit the new counter frame's icon cutout, ~22px square)
local ICON_IMAGE_SIZE  = 24                       -- item icon image
local ICON_BORDER_SIZE = 40                       -- sizing basis for the rust overlay host
local RUSTED_SIZE      = 27                       -- rustedframe.tga overlay
local RUSTED_INSET     = (ICON_BORDER_SIZE - RUSTED_SIZE) / 2  -- inset from border edges
local ICON_CENTER_X    = 16                       -- icon center from frame LEFT
local ICON_Y_OFFSET    = 0                        -- icon elements vertically centered
local RUSTED_X_OFFSET  = -1                       -- rust overlay x offset
local ICON_INSET       = 0.08                     -- texcoord crop (removes border artifact)

-- Sepia tint multiplied over the fully-desaturated icon once an item enters
-- the low-durability zone. Muted (channels closer together) rather than a
-- vivid orange so the rusted-wipe overlay reads more clearly against it.
local SEPIA_R, SEPIA_G, SEPIA_B = 0.62, 0.55, 0.48

-- The sepia overlay ramps in gradually from full durability up to this cap
-- by the time the item reaches the low-durability threshold, rather than
-- snapping straight to fully desaturated; from the threshold down to 0 the
-- rust wipe (rustedTex) takes over and the sepia alpha holds steady here.
local SEPIA_ALPHA_CAP = 0.9

-- Colors are blended toward gray by this much to soften the raw neon RGB mix below.
local COLOR_SATURATION = 0.85

local function Desaturate(r, g, b)
    local gray = (r + g + b) / 3
    return gray + (r - gray) * COLOR_SATURATION,
           gray + (g - gray) * COLOR_SATURATION,
           gray + (b - gray) * COLOR_SATURATION
end

-- Midpoint (as a fraction of max durability) at which the digit colour sits
-- exactly at yellow. Deliberately independent of GetLowThresholdPct — that
-- threshold still drives the sepia/rust visual effects and the "show in
-- normal mode" cutoff below, but the numeric colour ramp uses a fixed 50%
-- point so green/yellow/red are spread evenly across the whole range instead
-- of yellow being crammed into the last 5-20%.
local COLOR_MIDPOINT_PCT = 0.5

-- Green (100%) → Yellow (at COLOR_MIDPOINT_PCT) → Red (0%)
local function GetDurabilityColor(current, maximum)
    if maximum == 0 or current == 0 then return Desaturate(1, 0, 0) end
    local pct = math.min(1, current / maximum)
    if pct >= COLOR_MIDPOINT_PCT then
        local t = (pct - COLOR_MIDPOINT_PCT) / (1 - COLOR_MIDPOINT_PCT)  -- 0 at midpoint (yellow) → 1 at full (green)
        return Desaturate(1 - t, 1, 0)
    else
        local t = pct / COLOR_MIDPOINT_PCT  -- 1 at midpoint (yellow) → 0 at empty (red)
        return Desaturate(1, t, 0)
    end
end

-- 0 at full durability → SEPIA_ALPHA_CAP right at the low-durability
-- threshold, then held flat below the threshold (the rust wipe takes over
-- from there instead of pushing desaturation any further).
local function GetSepiaAlpha(pct, threshold)
    if pct <= threshold then return SEPIA_ALPHA_CAP end
    local range = 1 - threshold
    if range <= 0 then return SEPIA_ALPHA_CAP end
    local t = Clamp((1 - pct) / range, 0, 1)
    return t * SEPIA_ALPHA_CAP
end

-- ── Rolling digit animation (mirrors RustcoreStats pattern) ───────────────────

-- Animate a single digit slot to a new character with the given colour.
-- slot must have: .oldText, .newText (FontStrings), .currentValue (string|nil)
local function SetCounterDigit(slot, char, r, g, b)
    slot.oldText:SetTextColor(r, g, b)
    slot.newText:SetTextColor(r, g, b)

    if slot.currentValue == nil then
        -- First display: snap immediately, no animation
        slot.currentValue = char
        slot.oldText:SetText(char)
        slot.oldText:ClearAllPoints()
        slot.oldText:SetPoint("CENTER", slot, "CENTER", 0, 0)
        slot.oldText:Show()
        slot.newText:Hide()
        slot:SetScript("OnUpdate", nil)
        return
    end

    if slot.currentValue == char then
        -- Value unchanged, just update colour on the visible text
        return
    end

    -- Roll new digit in from above, old digit out through the bottom
    slot:SetScript("OnUpdate", nil)
    slot.elapsed = 0
    slot.oldText:SetText(slot.currentValue)
    slot.oldText:ClearAllPoints()
    slot.oldText:SetPoint("CENTER", slot, "CENTER", 0, 0)
    slot.newText:SetText(char)
    slot.newText:ClearAllPoints()
    slot.newText:SetPoint("CENTER", slot, "CENTER", 0, slot:GetHeight())
    slot.oldText:Show()
    slot.newText:Show()
    slot.currentValue = char

    slot:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        local progress = Clamp(self.elapsed / COUNTER_ROLL_DURATION, 0, 1)
        local eased = progress * progress * (3 - 2 * progress)  -- smoothstep
        local travel = self:GetHeight()

        self.oldText:ClearAllPoints()
        self.oldText:SetPoint("CENTER", self, "CENTER", 0, -travel * eased)
        self.newText:ClearAllPoints()
        self.newText:SetPoint("CENTER", self, "CENTER", 0, travel * (1 - eased))

        if progress >= 1 then
            self.oldText:SetText(self.currentValue)
            self.oldText:ClearAllPoints()
            self.oldText:SetPoint("CENTER", self, "CENTER", 0, 0)
            self.oldText:Show()
            self.newText:Hide()
            self:SetScript("OnUpdate", nil)
        end
    end)
end

-- Set all three counter digit slots to display 'value' (0–100) in the given colour.
-- digits[1]=hundreds, digits[2]=tens, digits[3]=ones.
local function SetCounterDigits(digits, value, r, g, b)
    local str = tostring(math.max(0, math.floor(value)))
    local len = #str
    local chars = {
        len >= 3 and str:sub(-3, -3) or "0",   -- hundreds (always present, pads with 0)
        len >= 2 and str:sub(-2, -2) or "0",   -- tens (always present, pads with 0)
        str:sub(-1),                            -- ones (always present)
    }

    for i = 1, 3 do
        local slot = digits[i]
        if chars[i] then
            slot:Show()
            SetCounterDigit(slot, chars[i], r, g, b)
        else
            -- Digit not needed; hide immediately and reset so next show is clean
            slot:Hide()
            slot:SetScript("OnUpdate", nil)
            slot.currentValue = nil
        end
    end
end

-- ── Frame construction ────────────────────────────────────────────────────────

local hudContainer = nil
local slotEntries  = {}
local frameBySlot  = {} -- slot id -> icon frame, built once in BuildHUD
local activeOrder  = {} -- slot ids in current stack order (1 = nearest anchor);
                         -- stable across updates so existing icons don't
                         -- reshuffle as durability percentages change —
                         -- newly-visible slots are inserted by rank instead
local lastLinkBySlot = {} -- slot id -> item identity last seen there; lets a
                           -- re-equip into an already-tracked slot be treated
                           -- as a new insertion instead of keeping the old
                           -- item's rank position

-- What counts as "the same item still in this slot".
--
-- An item link cannot answer that on its own: durability is not part of a link,
-- so two copies of the same sword produce byte-identical links no matter how
-- worn each one is. Swapping one for the other therefore looked like nothing had
-- happened -- the icon kept its rank, and a fresh copy replacing a broken one
-- could even trip the "just broke" flash.
--
-- C_Item.GetItemGUID does distinguish the two copies. It exists on the Classic
-- clients but is feature-detected anyway, and the link is the fallback where it
-- is missing -- no worse than the behaviour this replaces.
local function GetSlotIdentity(slot, link)
    if C_Item and C_Item.GetItemGUID and ItemLocation and ItemLocation.CreateFromEquipmentSlot then
        local ok, guid = pcall(function()
            local loc = ItemLocation:CreateFromEquipmentSlot(slot)
            if not loc or not loc:IsValid() then return nil end
            return C_Item.GetItemGUID(loc)
        end)
        if ok and guid then return guid end
    end
    return link
end
local lastDurabilityBySlot = {} -- slot id -> durability last seen there for
                                 -- the item currently in lastLinkBySlot; used
                                 -- to detect the >0 -> 0 "just broke" edge

-- Anchor corner used to pin the HUD container. The edges the corner names are
-- the ones that stay put when the HUD resizes, so the corner is what actually
-- decides which way the counters grow.
--
-- A vertical stack changes height, so the choice is between pinning the top
-- edge (rows extend downward) and the bottom (rows extend upward). A
-- horizontal row changes width instead and its height never varies, which
-- leaves Grow Upward no vertical growth to steer -- so on that axis it picks
-- the pinned side instead: left edge fixed means the row extends rightward.
-- Same setting, same idea (grow away from the far edge rather than toward it),
-- applied to the axis the current layout actually moves along.
local function GetHUDAnchorCorner()
    local grow = Rustcore.GetSetting("durHUDGrowUpward")
    if Rustcore.GetSetting("durHUDHorizontal") then
        return grow and "TOPLEFT" or "TOPRIGHT"
    end
    return grow and "BOTTOMRIGHT" or "TOPRIGHT"
end

-- Keep at least this many pixels of the HUD on-screen along each axis, so a
-- freshly-seeded position (or a drag) can never leave it somewhere the user
-- can't find to drag back.
local MIN_ONSCREEN = 40

-- Base left-shift applied to the native-mirrored default so a fresh HUD
-- doesn't hug the exact edge Blizzard's own frame sits at.
local DEFAULT_X_INSET = 26

-- Extra left-shift applied per visible right-side vertical action bar
-- (MultiBarLeft/MultiBarRight sit in that column below the minimap in the
-- default UI), so a fresh HUD doesn't land underneath them. Only ever
-- applied to a position the user hasn't dragged themselves — see
-- GetOrSeedCornerPos and StopHUDDrag's "userMoved" flag.
local ACTIONBAR_X_SHIFT = 42

local function GetRightActionBarShift()
    local shift = 0
    if MultiBarRight and MultiBarRight:IsShown() then
        shift = shift + ACTIONBAR_X_SHIFT
    end
    if MultiBarLeft and MultiBarLeft:IsShown() then
        shift = shift + ACTIONBAR_X_SHIFT
    end
    return shift
end

-- Each corner expressed as the direction an offset must move along each axis
-- to travel *into* the screen from that corner. The clamp and convert helpers
-- below work in that neutral "distance from my own anchored edge" space and
-- multiply by the sign to get back to real offsets, so one piece of math
-- covers all four corners instead of a per-corner branch in four places.
local CORNER_SIGNS = {
    TOPRIGHT    = { x = -1, y = -1 },
    BOTTOMRIGHT = { x = -1, y =  1 },
    TOPLEFT     = { x =  1, y = -1 },
    BOTTOMLEFT  = { x =  1, y =  1 },
}

-- Deterministic order for "any other saved corner will do" fallbacks. pairs()
-- would find one too, but not the same one twice -- and a seeded position that
-- varies between logins is the exact drift this per-corner table exists to
-- prevent.
local CORNER_ORDER = { "TOPRIGHT", "BOTTOMRIGHT", "TOPLEFT", "BOTTOMLEFT" }

local function CornerSigns(corner)
    return CORNER_SIGNS[corner] or CORNER_SIGNS.TOPRIGHT
end

local function ClampEdgeOffset(offset, frameSize, screenSize)
    -- offset grows as the frame moves away from its anchored edge. The far
    -- bound scales with the SCREEN (how far it can travel before it's gone),
    -- and the near bound with the FRAME (how far it can back up past its own
    -- anchor before it's gone).
    local lo, hi = -(frameSize - MIN_ONSCREEN), screenSize - MIN_ONSCREEN
    if lo > hi then return offset end -- frame bigger than the screen minus margins; leave it alone
    return Clamp(offset, lo, hi)
end

-- Clamping in the corner-agnostic "distance from the anchored edge, growing
-- into the screen" form lets one set of bounds apply correctly on both axes
-- and from any corner, and guarantees the result can never end up off-screen.
local function ClampToScreen(corner, x, y, w, h, sw, sh)
    local s = CornerSigns(corner)
    -- Multiplying by the sign moves into that space; multiplying by it again
    -- moves back, since every sign is +/-1.
    local edgeX = ClampEdgeOffset(x * s.x, w, sw)
    local edgeY = ClampEdgeOffset(y * s.y, h, sh)
    return edgeX * s.x, edgeY * s.y
end

-- Re-express a saved offset in another corner's coordinate space while keeping
-- the HUD's actual on-screen position unchanged. An offset means "distance
-- from my own edge", so an axis only needs converting when the two corners sit
-- on opposite edges of it: the same pixel is then the screen span, less the
-- frame size, less the original distance -- measured from the other side.
local function ConvertCornerOffset(fromCorner, toCorner, x, y, w, h, sw, sh)
    local from, to = CornerSigns(fromCorner), CornerSigns(toCorner)
    local nx, ny = x, y
    if from.x ~= to.x then
        nx = to.x * (sw - (x * from.x) - w)
    end
    if from.y ~= to.y then
        ny = to.y * (sh - (y * from.y) - h)
    end
    return nx, ny
end

-- Best-effort seed the very first time the HUD is ever shown (no saved
-- position yet): mirror wherever Blizzard's own DurabilityFrame currently sits
-- on screen, converted into an offset from our anchor corner, so the custom
-- HUD starts out where players already expect it. Uses resolved on-screen
-- extents (not GetPoint's raw anchor) so it works no matter what frame the
-- native durability frame happens to be anchored to. Returns nil if the native
-- frame isn't laid out yet, so callers can fall back.
local function GetNativeDurabilityDefault(corner)
    if not DurabilityFrame or not DurabilityFrame.GetRight then return nil end
    local left, right = DurabilityFrame:GetLeft(), DurabilityFrame:GetRight()
    local top, bottom = DurabilityFrame:GetTop(), DurabilityFrame:GetBottom()
    local uiLeft, uiRight = UIParent:GetLeft(), UIParent:GetRight()
    local uiTop, uiBottom = UIParent:GetTop(), UIParent:GetBottom()
    if not (left and right and top and bottom
            and uiLeft and uiRight and uiTop and uiBottom) then return nil end

    local s = CornerSigns(corner)
    -- The inset pushes the HUD further into the screen, which is the sign's
    -- direction by definition. The action-bar dodge is right-side-specific, so
    -- it only applies when the HUD is actually hugging the right edge.
    local shift = (s.x < 0) and GetRightActionBarShift() or 0
    local x = ((s.x < 0) and (right - uiRight) or (left - uiLeft))
              + (DEFAULT_X_INSET + shift) * s.x
    local y = (s.y > 0) and (bottom - uiBottom) or (top - uiTop)
    return x, y
end

-- Saved positions are kept per-corner ({ TOPRIGHT = {x,y}, BOTTOMLEFT =
-- {x,y}, ... }) instead of one spot that gets converted back and forth on every
-- toggle. Once a corner has been used, switching back to it is a plain table
-- lookup with no runtime math — nothing left to drift or jump on repeat
-- toggles. Old saves used a flat { point, x, y } shape; migrate those in.
local function GetHUDPosTable()
    local raw = Rustcore.GetProfileValue("durHUDPos")
    if raw and raw.point and raw.x and not raw.TOPRIGHT and not raw.BOTTOMRIGHT then
        raw = { [raw.point] = { x = raw.x, y = raw.y } }
    end
    return raw or {}
end

-- A corner with nothing saved yet is seeded once: converted from another
-- corner's spot if one exists (so it starts out looking like the HUD didn't
-- move at all), otherwise from Blizzard's native frame or a hardcoded
-- fallback. Returns whether a seed was needed so the caller knows to persist it.
--
-- As long as the user has never actually dragged the HUD (raw.userMoved),
-- a "saved" corner here is really just last session's auto-seed, not a
-- real placement choice -- so it's recomputed fresh instead of reused. That's
-- what lets the default spot auto-adjust for right-side action bars turning
-- on/off between sessions without ever touching a position the user picked.
local function GetOrSeedCornerPos(corner, raw, w, h, sw, sh)
    local saved = raw[corner]
    if saved and raw.userMoved then return saved.x, saved.y, false end

    if raw.userMoved then
        for _, other in ipairs(CORNER_ORDER) do
            local pos = (other ~= corner) and raw[other] or nil
            if pos then
                local nx, ny = ConvertCornerOffset(other, corner, pos.x, pos.y, w, h, sw, sh)
                return nx, ny, true
            end
        end
    end

    local nx, ny = GetNativeDurabilityDefault(corner)
    local s = CornerSigns(corner)
    local shift = (s.x < 0) and GetRightActionBarShift() or 0
    return nx or ((60 + shift) * s.x), ny or (220 * s.y), true
end

-- This only ever runs at init, on manual drag-stop, or when the grow-upward
-- setting actually changes — never on a routine durability update.
local function ApplyHUDPosition()
    if not hudContainer then return end
    local corner = GetHUDAnchorCorner()
    local w, h = hudContainer:GetWidth(), hudContainer:GetHeight()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()

    local raw = GetHUDPosTable()
    local x0, y0, isNew = GetOrSeedCornerPos(corner, raw, w, h, sw, sh)
    local x, y = ClampToScreen(corner, x0, y0, w, h, sw, sh)

    hudContainer:ClearAllPoints()
    hudContainer:SetPoint(corner, UIParent, corner, x, y)

    -- Persist when freshly seeded, or when the clamp actually had to move a
    -- stale/out-of-bounds saved value — that permanently heals it instead of
    -- reclamping the same bad value on every future login.
    if isNew or x ~= x0 or y ~= y0 then
        raw[corner] = { x = x, y = y }
        Rustcore.SetProfileValue("durHUDPos", raw)
    end
end

-- Forces the container's live on-screen rect back onto a single explicit
-- (corner, UIParent, corner, x, y) point, deriving x/y from the *current
-- rendered edges* rather than any cached raw[corner] entry (which goes
-- stale the moment a different corner was active last). Needed anywhere the
-- real anchor corner can end up different from what GetHUDAnchorCorner()
-- expects — most importantly right after a drag: StopMovingOrSizing()
-- always snaps to whichever screen corner ended up closest to the mouse,
-- which is frequently NOT the corner this addon treats as fixed. Left
-- alone, that mismatch means a later SetHeight (during a routine item
-- add/remove) ends up moving an edge the render loop believes is pinned —
-- which is what made counters drift or "shrink from the middle" instead of
-- extending cleanly from one fixed end, but only once the HUD had been
-- dragged somewhere the closest corner wasn't the intended one. Returns the
-- resulting x, y, or nil if the live rect isn't available yet.
local function ReanchorToFixedCorner(corner)
    if not hudContainer then return nil end
    local left, right = hudContainer:GetLeft(), hudContainer:GetRight()
    local top, bottom = hudContainer:GetTop(), hudContainer:GetBottom()
    local uiLeft, uiRight = UIParent:GetLeft(), UIParent:GetRight()
    local uiTop, uiBottom = UIParent:GetTop(), UIParent:GetBottom()
    if not (left and right and top and bottom
            and uiLeft and uiRight and uiTop and uiBottom) then return nil end

    local w, h = hudContainer:GetWidth(), hudContainer:GetHeight()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()

    local s = CornerSigns(corner)
    local x0 = (s.x < 0) and (right - uiRight) or (left - uiLeft)
    local y0 = (s.y > 0) and (bottom - uiBottom) or (top - uiTop)
    local x, y = ClampToScreen(corner, x0, y0, w, h, sw, sh)

    hudContainer:ClearAllPoints()
    hudContainer:SetPoint(corner, UIParent, corner, x, y)
    return x, y
end

-- Re-anchors to a different corner when a setting changes which edges are
-- meant to stay put, keeping the HUD pixel-identical on screen while it
-- happens.
local function RepositionForAnchorChange()
    if not hudContainer then return end
    local corner = GetHUDAnchorCorner()
    local x, y = ReanchorToFixedCorner(corner)
    if not x then
        ApplyHUDPosition()
        return
    end

    local raw = GetHUDPosTable()
    raw[corner] = { x = x, y = y }
    Rustcore.SetProfileValue("durHUDPos", raw)
end

-- Re-seeds the default position live when a right-side action bar toggles
-- on/off mid-session, so the auto-adjust in GetOrSeedCornerPos doesn't just
-- apply on next login. No-ops once the user has actually dragged the HUD
-- (raw.userMoved), since that's a real placement, not a default.
local function MaybeReseedDefaultPosition()
    if not hudContainer then return end
    if GetHUDPosTable().userMoved then return end
    ApplyHUDPosition()
end

-- Dragging is initiated from whichever icon frame is under the cursor (they
-- sit on top of the container and would otherwise swallow the mouse), but
-- every icon frame gets Hidden/Shown on each durability update. If the icon
-- that started the drag gets hidden mid-drag, its OnDragStop never fires and
-- StopMovingOrSizing() never runs — leaving the whole HUD glued to the mouse
-- cursor from then on. Routing both container and icon frames through these
-- shared start/stop functions, and hooking OnHide on all of them as a safety
-- net, guarantees the drag always gets released no matter which frame vanishes.
local function StopHUDDrag()
    if hudContainer and hudContainer.isDragging then
        hudContainer.isDragging = nil
        hudContainer:StopMovingOrSizing()

        -- StopMovingOrSizing() snaps to whichever screen corner ended up
        -- closest to the drag, not necessarily the corner this addon
        -- treats as fixed (see ReanchorToFixedCorner) — force it back so
        -- every later routine update can keep trusting that corner stayed
        -- put, instead of only fixing it up on the next toggle/reload.
        local corner = GetHUDAnchorCorner()
        local x, y = ReanchorToFixedCorner(corner)
        if not x then
            local _, _, _, gx, gy = hudContainer:GetPoint()
            x, y = gx, gy
        end

        local raw = GetHUDPosTable()
        raw[corner] = { x = x, y = y }
        -- Marks this as a real user placement, so the default-position
        -- auto-adjust (see GetOrSeedCornerPos) never overrides it again.
        raw.userMoved = true
        Rustcore.SetProfileValue("durHUDPos", raw)
    end
end

local function StartHUDDrag()
    if hudContainer and not hudContainer.isDragging then
        hudContainer.isDragging = true
        hudContainer:StartMoving()
    end
end

local function BuildDigitSlot(parent, idx)
    -- idx 1=hundreds, 2=tens, 3=ones
    -- Center X of each slot, measured from frame's LEFT anchor
    local centerX = math.floor(FRAME_W * COUNTER_CENTER_X
                                + (idx - 2) * (FRAME_W * DIGIT_SPACING) + 0.5)
                    + DIGIT_NUDGE[idx]

    local slot = CreateFrame("Frame", nil, parent)
    -- Explicit level keeps digits above the counter frame overlay (set below).
    slot:SetFrameLevel(parent:GetFrameLevel() + 5)
    -- Height = one digit character; SetClipsChildren keeps the roll inside this window.
    slot:SetSize(DIGIT_SLOT_W, DIGIT_SLOT_H)
    slot:SetPoint("CENTER", parent, "LEFT", centerX, 0)
    if slot.SetClipsChildren then slot:SetClipsChildren(true) end
    slot:EnableMouse(false)   -- let drag events fall through to the parent slot frame

    local function MakeText()
        local fs = slot:CreateFontString(nil, "OVERLAY")
        fs:SetFont(BODY_FONT_PATH, DIGIT_FONT_SIZE, "")
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
        fs:SetJustifyH("CENTER")
        fs:SetJustifyV("MIDDLE")
        fs:SetSize(DIGIT_SLOT_W, DIGIT_SLOT_H)
        fs:SetPoint("CENTER", slot, "CENTER", 0, 0)
        return fs
    end

    slot.oldText = MakeText()
    slot.newText = MakeText()
    slot.newText:Hide()
    slot.currentValue = nil

    slot:Hide()
    return slot
end

local function BuildSlotFrame(parent, slotId)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(FRAME_W, FRAME_H)
    f.slotId = slotId

    -- Black fill behind icon
    local iconBg = f:CreateTexture(nil, "BACKGROUND")
    iconBg:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
    iconBg:SetPoint("CENTER", f, "LEFT", ICON_CENTER_X, ICON_Y_OFFSET)
    iconBg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    iconBg:SetVertexColor(0, 0, 0, 1)

    -- Full-colour item icon (shown at 100% durability, fades to sepia as durability drops)
    local iconTex = f:CreateTexture(nil, "ARTWORK")
    iconTex:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
    iconTex:SetPoint("CENTER", f, "LEFT", ICON_CENTER_X, ICON_Y_OFFSET)
    iconTex:SetTexCoord(ICON_INSET, 1 - ICON_INSET, ICON_INSET, 1 - ICON_INSET)

    -- Sepia overlay (snaps to full alpha once the low-durability threshold is reached)
    local sepiaTex = f:CreateTexture(nil, "OVERLAY")
    sepiaTex:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
    sepiaTex:SetPoint("CENTER", f, "LEFT", ICON_CENTER_X, ICON_Y_OFFSET)
    sepiaTex:SetTexCoord(ICON_INSET, 1 - ICON_INSET, ICON_INSET, 1 - ICON_INSET)
    sepiaTex:SetDesaturation(1)
    sepiaTex:SetVertexColor(SEPIA_R, SEPIA_G, SEPIA_B, 0)   -- starts invisible

    -- Slight shadow over the icon so it reads as sitting in the frame, not pasted on top
    local shadowTex = f:CreateTexture(nil, "OVERLAY")
    shadowTex:SetSize(ICON_IMAGE_SIZE, ICON_IMAGE_SIZE)
    shadowTex:SetPoint("CENTER", f, "LEFT", ICON_CENTER_X, ICON_Y_OFFSET)
    shadowTex:SetColorTexture(0, 0, 0, 0.20)

    -- Rusted frame overlay: wipes top-down from the low-durability threshold to 0% durability
    local rustedHost = CreateFrame("Frame", nil, f)
    rustedHost:SetSize(ICON_BORDER_SIZE, ICON_BORDER_SIZE)
    rustedHost:SetPoint("CENTER", f, "LEFT", ICON_CENTER_X, ICON_Y_OFFSET)
    rustedHost:SetFrameLevel(f:GetFrameLevel() + 3)
    rustedHost:EnableMouse(false)
    local rustedTex = rustedHost:CreateTexture(nil, "OVERLAY")
    rustedTex:SetWidth(RUSTED_SIZE)
    rustedTex:SetHeight(0)
    rustedTex:SetPoint("TOPLEFT", rustedHost, "TOPLEFT", RUSTED_INSET + RUSTED_X_OFFSET, -RUSTED_INSET)
    rustedTex:SetTexture(Rustcore.GetAssetPath("UI/rustedframe.tga"))
    rustedTex:SetTexCoord(0, 1, 0, 0)

    -- Counter frame overlay: has a cutout window over the icon, so it must draw
    -- above the icon/border/rust layers (not just above the icon's own textures).
    local overlayHost = CreateFrame("Frame", nil, f)
    overlayHost:SetSize(FRAME_W, COUNTER_FRAME_H)
    overlayHost:SetPoint("CENTER", f, "CENTER", 0, 0)
    overlayHost:SetFrameLevel(f:GetFrameLevel() + 4)
    overlayHost:EnableMouse(false)
    local overlayTex = overlayHost:CreateTexture(nil, "OVERLAY")
    overlayTex:SetAllPoints(overlayHost)
    overlayTex:SetTexture(Rustcore.GetAssetPath("UI/durability counter frame copy.tga"))

    -- Digit slots (child frames, draw above all textures automatically)
    local digits = {}
    for i = 1, 3 do
        digits[i] = BuildDigitSlot(f, i)
    end

    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", StartHUDDrag)
    f:SetScript("OnDragStop", StopHUDDrag)
    f:HookScript("OnHide", StopHUDDrag)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetInventoryItem("player", self.slotId)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.iconTex   = iconTex
    f.sepiaTex  = sepiaTex
    f.rustedTex = rustedTex
    f.digits    = digits
    f:Hide()
    return f
end

-- The art is built once and toggled, rather than created and destroyed, so
-- flipping the setting can't leak textures across a session.
local function ApplyBackgroundVisibility()
    if not hudContainer then return end
    local on = Rustcore.GetSetting("durHUDBackground") and true or false
    for _, piece in pairs(hudContainer.backgroundPieces or {}) do
        if on then piece:Show() else piece:Hide() end
    end
    for _, piece in pairs(hudContainer.backgroundShadowPieces or {}) do
        if on then piece:Show() else piece:Hide() end
    end
    if hudContainer.shade then
        if on then hudContainer.shade:Show() else hudContainer.shade:Hide() end
    end
end

local function BuildHUD()
    if hudContainer then return end

    BODY_FONT_PATH = Rustcore.GetAssetPath("Font/BPpong.otf")

    local f = CreateFrame("Frame", "RustcoreDurabilityHUD", UIParent)
    f:SetSize(FRAME_W, 10)
    f:SetFrameStrata("LOW")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", StartHUDDrag)
    f:SetScript("OnDragStop", StopHUDDrag)
    f:HookScript("OnHide", StopHUDDrag)

    -- Panel art goes on the container rather than a child frame: a frame's own
    -- textures always draw below its child frames, so the slot frames sit on top
    -- of this without anyone having to manage frame levels.
    local panelArt = RustcoreTheme.CreateRivetPanelArt(
        f,
        Rustcore.GetSetting("durHUDBackgroundOpacity") or HUD_BG_ALPHA,
        Rustcore.GetSetting("durHUDBackgroundShadow") or HUD_BG_ALPHA,
        HUD_BG_BORDER,
        -- The row is short and very wide, so a single stretched edge strip
        -- smears its rivets into streaks; tiling keeps them at their real size.
        true)
    f.backgroundPieces = panelArt.pieces
    f.backgroundShadowPieces = panelArt.shadowPieces
    f.shade = panelArt.shade

    hudContainer = f
    ApplyBackgroundVisibility()
    ApplyHUDPosition()

    -- Right-side action bars (MultiBarLeft/MultiBarRight) share screen space
    -- with the default HUD spot; re-seed the default live if either toggles
    -- while the user hasn't dragged the HUD themselves.
    if MultiBarRight then
        MultiBarRight:HookScript("OnShow", MaybeReseedDefaultPosition)
        MultiBarRight:HookScript("OnHide", MaybeReseedDefaultPosition)
    end
    if MultiBarLeft then
        MultiBarLeft:HookScript("OnShow", MaybeReseedDefaultPosition)
        MultiBarLeft:HookScript("OnHide", MaybeReseedDefaultPosition)
    end

    f:Hide()

    slotEntries = {}
    for _, slot in ipairs(SLOT_DATA) do
        local sf = BuildSlotFrame(f, slot)
        slotEntries[#slotEntries + 1] = { slot = slot, frame = sf }
        frameBySlot[slot] = sf
    end
end

-- ── Break reaction (shake + crash sound) ────────────────────────────────────────

-- Small decaying shake played on the item's HUD row when it breaks. Offsets
-- sum to zero so the row settles back exactly on its anchored position
-- (Translation animations offset visually without touching the frame's own
-- SetPoint anchor, so this coexists fine with the stack-reflow logic below).
local function PlayBreakShake(frame)
    if not frame.breakShakeAnim then
        local ag = frame:CreateAnimationGroup()
        local function Step(order, dx, duration)
            local t = ag:CreateAnimation("Translation")
            t:SetOrder(order)
            t:SetDuration(duration)
            t:SetOffset(dx, 0)
        end
        Step(1, -4, 0.035)
        Step(2, 8, 0.05)
        Step(3, -7, 0.05)
        Step(4, 5, 0.045)
        Step(5, -2, 0.04)
        frame.breakShakeAnim = ag
    end
    frame.breakShakeAnim:Stop()
    frame.breakShakeAnim:Play()
end

-- Item just went from >0 durability to 0. Shake its HUD row always; only
-- play a crash sound if the break happened mid-combat.
local function HandleItemBroke(frame)
    PlayBreakShake(frame)
    if InCombatLockdown() then
        PlaySoundFile(Rustcore.GetAssetPath("Audio/crash" .. math.random(1, 5) .. ".wav"), "Master")
    end
end

-- ── HUD update ────────────────────────────────────────────────────────────────

local function UpdateHUD()
    if not hudContainer then return end

    local showHUD = Rustcore.GetSetting("showDurabilityHUD")
    if not showHUD then
        hudContainer:Hide()
        return
    end

    local showAll      = Rustcore.GetSetting("showAllDurability")
    local visibleSlots = {} -- { slot = slot, pct = pct }, this pass only

    for _, entry in ipairs(slotEntries) do
        local slot    = entry.slot
        local link    = GetInventoryItemLink("player", slot)
        local visible = false
        local pct     = 1  -- default; overwritten when durability is read

        local identity = link and GetSlotIdentity(slot, link) or nil

        if link then
            local current, maximum = GetInventoryItemDurability(slot)
            if current ~= nil and maximum ~= nil and maximum > 0 then
                pct = current / maximum
                local threshold = GetLowThresholdPct(maximum)
                if showAll or pct <= threshold then
                    local itemTex = GetInventoryItemTexture("player", slot)
                    local fallback = "Interface\\Icons\\INV_Misc_QuestionMark"
                    entry.frame.iconTex:SetTexture(itemTex or fallback)
                    entry.frame.sepiaTex:SetTexture(itemTex or fallback)

                    -- Sepia ramps in gradually as durability drops, capping at
                    -- SEPIA_ALPHA_CAP once the low-durability threshold is hit;
                    -- rust is what ramps the rest of the way from there to 0.
                    local sepiaAlpha = GetSepiaAlpha(pct, threshold)
                    entry.frame.sepiaTex:SetVertexColor(SEPIA_R, SEPIA_G, SEPIA_B, sepiaAlpha)

                    -- Rusted wipe: 0 coverage at the threshold → full at 0%
                    local rustedFrac = Clamp(
                        (threshold - pct) / threshold, 0, 1)
                    entry.frame.rustedTex:SetHeight(RUSTED_SIZE * rustedFrac)
                    entry.frame.rustedTex:SetTexCoord(0, 1, 0, rustedFrac)

                    -- "Just broke" edge: only fires when we previously saw this
                    -- same item above 0 durability, not on login/re-equip with
                    -- an already-broken item.
                    local prevDurability = (identity == lastLinkBySlot[slot]) and lastDurabilityBySlot[slot] or nil
                    if current == 0 and prevDurability and prevDurability > 0 then
                        HandleItemBroke(entry.frame)
                    end
                    lastDurabilityBySlot[slot] = current

                    local r, g, b = GetDurabilityColor(current, maximum)
                    SetCounterDigits(entry.frame.digits, current, r, g, b)
                    visible = true
                end
            end
        end

        if not visible then
            for _, d in ipairs(entry.frame.digits) do
                d:Hide()
                d:SetScript("OnUpdate", nil)
                d.currentValue = nil
            end
            entry.frame.sepiaTex:SetVertexColor(SEPIA_R, SEPIA_G, SEPIA_B, 0)
            entry.frame.rustedTex:SetHeight(0)
            entry.frame.rustedTex:SetTexCoord(0, 1, 0, 0)
        end

        entry.frame:SetShown(visible)
        if visible then
            visibleSlots[#visibleSlots + 1] = { slot = slot, pct = pct, link = identity }
        end
    end

    -- Stable stack order: a slot keeps its spot once placed, even as its
    -- percentage drifts — durability ticks on already-shown items never
    -- reshuffle the stack. A newly-visible slot is inserted by rank against
    -- the other currently-placed slots (worst-first), so a freshly equipped
    -- item lands in the correct spot relative to everything already shown
    -- instead of only ever comparing against the current worst item.
    local pctBySlot  = {}
    local linkBySlot = {}
    for _, entry in ipairs(visibleSlots) do
        pctBySlot[entry.slot]  = entry.pct
        linkBySlot[entry.slot] = entry.link
    end

    -- A slot only keeps its old rank if the same item is still equipped
    -- there; a re-equip (even into a slot that was already tracked) is
    -- treated like a fresh insertion below so it re-ranks immediately
    -- instead of just replacing the previous item's position.
    local newOrder = {}
    for _, slot in ipairs(activeOrder) do
        if pctBySlot[slot] and linkBySlot[slot] == lastLinkBySlot[slot] then
            newOrder[#newOrder + 1] = slot
        end
    end

    local placed = {}
    for _, slot in ipairs(newOrder) do
        placed[slot] = true
    end

    for _, entry in ipairs(visibleSlots) do
        if not placed[entry.slot] then
            -- Find the first already-placed slot that's less damaged than
            -- this one and insert just before it, so the new slot lands in
            -- correct worst-first rank order; if nothing already placed is
            -- less damaged, it joins the far (best) end. Every frame gets
            -- SetPoint'd fresh from activeOrder each update (below), so a
            -- mid-stack insertion here is not a source of visual jumps.
            local insertAt = #newOrder + 1
            for i, slot in ipairs(newOrder) do
                if entry.pct < pctBySlot[slot] then
                    insertAt = i
                    break
                end
            end
            table.insert(newOrder, insertAt, entry.slot)
            placed[entry.slot] = true
        end
    end
    activeOrder = newOrder

    for slot in pairs(lastLinkBySlot) do
        if not linkBySlot[slot] then
            lastLinkBySlot[slot] = nil
        end
    end
    for slot, link in pairs(linkBySlot) do
        lastLinkBySlot[slot] = link
    end

    if #activeOrder > 0 then
        -- Vertical stacks a column; horizontal lays out a single row. Either
        -- way the container is pinned by one corner and grows away from it, so
        -- the pinned edge stays put and only the free edges move.
        local horizontal = Rustcore.GetSetting("durHUDHorizontal")
        local padL, padR, padY = BackgroundPadding()
        if horizontal then
            hudContainer:SetSize(
                #activeOrder * FRAME_W + (#activeOrder - 1) * H_SLOT_GAP + padL + padR,
                FRAME_H + padY * 2)
        else
            hudContainer:SetSize(
                FRAME_W + padL + padR,
                #activeOrder * FRAME_H + (#activeOrder - 1) * SLOT_GAP + padY * 2)
        end
        -- No repositioning here: the container keeps a single anchor point
        -- (SetPoint(corner, ...)), and resizing only moves the unanchored
        -- edges, so the anchor itself never drifts on its own. Re-running the
        -- clamp/corner-conversion math on every tick was the actual source of
        -- the "HUD jumps on equip" bugs. Position is now only touched on a
        -- manual drag (StopHUDDrag), or when a setting that changes which edge
        -- is pinned changes (RefreshPosition, HandleHorizontalChanged).
        local growUpward = Rustcore.GetSetting("durHUDGrowUpward")
        local reverseOrder = Rustcore.GetSetting("durHUDReverseOrder")

        if horizontal then
            -- One row. The container is pinned by whichever side Grow Upward
            -- selected (see GetHUDAnchorCorner), and the frames are laid out
            -- from that same side, so the fixed end is the one that keeps its
            -- pixels as items come and go.
            --
            -- activeOrder is worst-first, so walking it forward from the
            -- pinned side would park the worst item at the right end in one
            -- mode and the left in the other. Reversing the walk when growing
            -- right cancels that out -- exactly as the vertical stack reverses
            -- when growing upward. The worst item then sits at the visual
            -- right either way, which makes toggling the setting a no-op for
            -- the pixels already on screen; all it changes is which end moves
            -- next. durHUDReverseOrder flips that to the visual left.
            local growRight = growUpward
            local walkReversed = growRight
            if reverseOrder then walkReversed = not walkReversed end
            local first, last, step = 1, #activeOrder, 1
            if walkReversed then
                first, last, step = #activeOrder, 1, -1
            end
            -- H_SLOT_GAP's overlap trims cosmetic side padding; it is not
            -- the seam nudge SLOT_GAP does, which hides a sliver along the
            -- frame art's bottom edge that nothing here stacks over anything.
            local xOff = 0
            for i = first, last, step do
                local sf = frameBySlot[activeOrder[i]]
                sf:ClearAllPoints()
                if growRight then
                    sf:SetPoint("TOPLEFT", hudContainer, "TOPLEFT", -xOff + padL, -padY)
                else
                    sf:SetPoint("TOPRIGHT", hudContainer, "TOPRIGHT", xOff - padR, -padY)
                end
                xOff = xOff - FRAME_W - H_SLOT_GAP
            end
        else
            local yOff = 0
            -- activeOrder is always sorted worst-first regardless of anchor
            -- mode. Grow-down anchors the top edge, so worst-first order is
            -- walked forward (worst lands at the fixed top). Grow-up anchors
            -- the bottom edge instead, so the same array is walked in reverse
            -- (best lands at the fixed bottom). That keeps the worst item at
            -- the visual top in both modes, and makes toggling the setting a
            -- no-op for on-screen pixels since it is only reinterpreting the
            -- same ranks from the other end. durHUDReverseOrder flips which
            -- end the walk starts from (XOR'd against growUpward) so the worst
            -- item lands at the visual bottom instead, independent of which
            -- edge is anchored.
            local walkReversed = growUpward
            if reverseOrder then walkReversed = not walkReversed end
            local first, last, step = 1, #activeOrder, 1
            if walkReversed then
                first, last, step = #activeOrder, 1, -1
            end
            -- Every frame overlaps the one below it by SLOT_GAP, which hides
            -- the transparent sliver at the bottom of the frame art. The
            -- bottom-most frame has nothing under it to do that hiding, so its
            -- own bottom edge shows and reads as a one-pixel seam against the
            -- row above. Pulling just that frame up by a pixel closes it
            -- without disturbing the rest of the stack, which already sits
            -- flush.
            --
            -- Which iteration is visually lowest depends on the anchor:
            -- growing upward pins the bottom edge, so the first frame placed
            -- is the lowest; growing downward pins the top, so the last is.
            local bottomIteration = growUpward and first or last
            for i = first, last, step do
                local sf = frameBySlot[activeOrder[i]]
                local nudge = (i == bottomIteration) and 1 or 0
                sf:ClearAllPoints()
                if growUpward then
                    sf:SetPoint("BOTTOMLEFT", hudContainer, "BOTTOMLEFT", padL, -yOff + nudge + padY)
                else
                    sf:SetPoint("TOPLEFT", hudContainer, "TOPLEFT", padL, yOff + nudge - padY)
                end
                yOff = yOff - FRAME_H - SLOT_GAP
            end
        end
        hudContainer:Show()
        if DurabilityFrame then DurabilityFrame:Hide() end
    else
        hudContainer:Hide()
    end
end

-- ── Native DurabilityFrame suppression ───────────────────────────────────────

local function HookNativeDurabilityFrame()
    if not DurabilityFrame then return end
    DurabilityFrame:HookScript("OnShow", function(self)
        if Rustcore.GetSetting("showDurabilityHUD") then
            self:Hide()
        end
    end)
end

-- ── Event handling ────────────────────────────────────────────────────────────

local evFrame = CreateFrame("Frame")
evFrame:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
evFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
evFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_INVENTORY_CHANGED" and unit ~= "player" then return end
    if not hudContainer then return end

    -- Deferred one frame: GetInventoryItemDurability can still report the
    -- previous item's value in the same tick the inventory-changed event
    -- fires, before the client's local item cache has caught up.
    C_Timer.After(0, UpdateHUD)

    -- One frame is not always enough. Swapping in another copy of an item you
    -- are already wearing produces no durability event of its own -- the item id
    -- did not change -- and the slot can keep reporting the old copy's figure
    -- for a moment afterwards. Without these the counter would sit on the
    -- previous item's durability until something else happened to refresh it.
    if event == "UNIT_INVENTORY_CHANGED" then
        C_Timer.After(0.2, UpdateHUD)
        C_Timer.After(0.8, UpdateHUD)
    end
end)

-- ── Public API ────────────────────────────────────────────────────────────────

function RustcoreDurability.Init()
    BuildHUD()
    HookNativeDurabilityFrame()
    UpdateHUD()
end

function RustcoreDurability.Refresh()
    UpdateHUD()
end

-- Jumps to whatever position is saved/seeded for the current corner. Used
-- when there's no on-screen position worth preserving continuity with —
-- e.g. importing another profile's layout, where landing on the imported
-- spot is the whole point.
function RustcoreDurability.RefreshPosition()
    ApplyHUDPosition()
    UpdateHUD()
end

-- Re-anchors to the corner matching the current grow-upward setting while
-- keeping the HUD's on-screen position unchanged, then re-lays-out the
-- stack immediately so direction/order corrects itself right away instead
-- of waiting for the next durability-changing event. Use this (not
-- RefreshPosition) whenever durHUDGrowUpward itself just changed.
function RustcoreDurability.HandleGrowUpwardChanged()
    RepositionForAnchorChange()
    UpdateHUD()
end

-- Reverse order only flips which end the stable walk starts from (see
-- UpdateHUD); the anchor corner is untouched in either layout, so a plain
-- re-layout is enough.
function RustcoreDurability.HandleReverseOrderChanged()
    UpdateHUD()
end

-- Switching between a column and a row changes the container's width by up to
-- an order of magnitude, and the frames inside are anchored to edges that swap
-- roles. Lay the new shape out first, then re-pin and re-clamp from the live
-- rect so the HUD keeps the on-screen spot it had instead of being measured
-- against the shape it no longer has.
function RustcoreDurability.HandleHorizontalChanged()
    UpdateHUD()
    RepositionForAnchorChange()
end

-- Turning the background on or off changes the padding, and so the container's
-- size, which is why this lays out before it re-pins -- the same ordering, and
-- for the same reason, as HandleHorizontalChanged.
function RustcoreDurability.HandleBackgroundChanged()
    ApplyBackgroundVisibility()
    UpdateHUD()
    RepositionForAnchorChange()
end

function RustcoreDurability.RefreshBackgroundOpacity()
    if not hudContainer then return end
    local opacity = Rustcore.GetSetting("durHUDBackgroundOpacity") or HUD_BG_ALPHA
    for _, piece in pairs(hudContainer.backgroundPieces or {}) do
        piece:SetAlpha(opacity)
    end
    if hudContainer.shade then
        hudContainer.shade:SetVertexColor(0, 0, 0, 0.10 * opacity)
    end
end

function RustcoreDurability.RefreshBackgroundShadow()
    if not hudContainer then return end
    local opacity = Rustcore.GetSetting("durHUDBackgroundShadow") or HUD_BG_ALPHA
    for _, piece in pairs(hudContainer.backgroundShadowPieces or {}) do
        piece:SetAlpha(opacity)
    end
end

