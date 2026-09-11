-- Rustcore: Hardcore gear-loss addon for WoW Classic
-- Records equipped items at combat entry to prevent unequip-before-death cheating.
-- On death, marks a subset of items for deletion based on difficulty setting.

RustcoreDB = RustcoreDB or {}

Rustcore = {}

-- UnitFullName("player") only reliably returns a realm for cross-realm
-- units; for the player's own character the realm return is often blank,
-- so GetRealmName() is the source of truth for "what server am I on".
local function GetPlayerRealmName()
    local _, realm = UnitFullName and UnitFullName("player")
    if realm and realm ~= "" then return realm end
    return GetRealmName and GetRealmName() or nil
end

local function GetCurrentCharacterKey()
    local guid = UnitGUID and UnitGUID("player")
    if guid and guid ~= "" then return guid end
    local name = UnitName("player")
    local realm = GetPlayerRealmName()
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- Per-character settings profile. Keyed by GetCurrentCharacterKey() so each
-- character has independent settings; new characters start with an empty
-- profile table and are seeded from `defaults` lazily via Rustcore.GetSetting.
local function EnsureProfile()
    RustcoreDB.profiles = RustcoreDB.profiles or {}
    local key = GetCurrentCharacterKey()
    RustcoreDB.profiles[key] = RustcoreDB.profiles[key] or {}
    local profile = RustcoreDB.profiles[key]
    local name = UnitName("player")
    local realm = GetPlayerRealmName()
    if name and realm and realm ~= "" then
        profile.characterLabel = name .. "-" .. realm
    elseif not profile.characterLabel then
        profile.characterLabel = name or key
    end
    return profile
end

-- The difficulty palette, indexed by tier. Shared rather than kept private to
-- the options window, because the stats counters tint themselves from these same
-- values and the two are supposed to match -- a second copy would drift the
-- moment one of them was adjusted.
Rustcore.DIFFICULTY_COLORS = {
    [1] = { 0.494, 0.663, 0.337 }, -- Rusted
    [2] = { 0.62,  0.58,  0.28  }, -- Broken
    [3] = { 0.72,  0.43,  0.19  }, -- Shattered
    [4] = { 0.62,  0.22,  0.16  }, -- Crumbling
    [5] = { 0.52,  0.07,  0.06  }, -- Dust
}

-- The same five hues turned up for small text on dark art.
--
-- The palette above is deliberately earthy, which suits the big difficulty title
-- but leaves three-digit counter numerals hard to read against the dark counter
-- graphic. These keep each tier's hue exactly and raise only saturation and
-- brightness, to roughly where the durability readout sits -- that one uses
-- near-primary colours at 0.85 saturation, and stays legible at a glance.
Rustcore.DIFFICULTY_COLORS_VIVID = {
    [1] = { 0.51, 0.92, 0.14 }, -- Rusted
    [2] = { 0.94, 0.85, 0.14 }, -- Broken
    [3] = { 0.97, 0.50, 0.12 }, -- Shattered
    [4] = { 0.95, 0.25, 0.14 }, -- Crumbling
    [5] = { 0.93, 0.13, 0.11 }, -- Dust
}

local defaults = {
    difficulty      = 2,     -- 1=Lite, 2=Normal, 3=Hard, 4=Brutal, 5=Extreme
    selfFound       = false, -- block mailbox / AH / trade
    allowRepair     = false, -- if false (default), repair is blocked
    keepMainWeapon  = false, -- spare main weapon slot from deletion
    ignoreDeathAfterEnemyPlayerDamage = false, -- skip deletion if a hostile player damaged you during the fight
    selfFoundBuffEnabled = true, -- show verified Self-Found status as a buff icon on the player's own buff bar
    selfFoundAllowConjured = false, -- permit player trades in which every item on both sides is conjured
    showMinimapButton = true, -- show the minimap launcher button
    broadcastDeaths = true,  -- broadcast death to Rustcore channel
    broadcastDeathsRealmWide = true, -- also broadcast via the shared realm-wide channel, not just guild/group
    guildDeathMessage = true, -- send a guild chat message after the death animation
    showDeathPopup  = true,  -- show popup notification for other players' deaths
    showDeathWarning= true, -- show center-screen warning for other players' deaths
    showDeathWarningSound = true, -- play MetalDrum.wav when the center-screen warning shows
    showStatsWindow = false, -- show the always-on-screen item loss stats window
    showDurabilityHUD = true,    -- show custom per-slot durability HUD (replaces native frame)
    showAllDurability = false,   -- show all equipped slots regardless of durability level
    durHUDGrowUpward = false,    -- stack durability HUD rows upward instead of downward
    durHUDReverseOrder = false,  -- reverse stack sort so most-damaged item sits at the bottom
    durHUDHorizontal = false,    -- lay the durability counters out in a row instead of a column
    durHUDBackground = false,   -- draw the rivet panel behind the durability counters
    durHUDBackgroundOpacity = 0.78, -- opacity of the durability HUD background art
    durHUDBackgroundShadow = 0.78,  -- opacity of the solid black plane behind that art
    statsBackground = true,        -- draw the rivet panel behind the stats window
    statsBackgroundOpacity = 0.78, -- opacity of the stats window background art
    statsBackgroundShadow = 0.78, -- opacity of the solid black plane behind the background art
    statsHorizontalLayout = false, -- arrange all stats window elements on a single row
    -- Which counters the stats window shows. Broken, Rusted and the best item
    -- lost are the original three and stay on; deaths is new and stays off until
    -- asked for, so an existing window does not change shape on update.
    statShowBroken  = true,  -- show the Broken (items destroyed) counter
    statShowRusted  = true,  -- show the Rusted (items worn out) counter
    statShowDeaths  = false, -- show the Deaths counter
    statShowBestItem = true, -- show the best item lost panel
    statsColoredNumbers = true, -- tint each stats counter with its matching difficulty colour
    dragonPlayerFrame = true, -- show a difficulty-tier dragon overlay on your own player frame
    dragonTargetFrame = true,  -- show a difficulty-tier dragon overlay on the target frame when targeting a Rustcore user
    showDeathlogWindow = false, -- show the death log window listing other players' deaths
    showDeathlogLevel = true,   -- show the victim's level in each death log entry
    showDeathlogCount = true,   -- show how many items were lost
    showDeathlogItem = true,    -- show an icon for the most valuable item lost
    showDeathlogSource = true,  -- show what killed the player
    deathlogMinLevel = 0,       -- hide deathlog entries below this level (0 = show all)
    deathlogMinQuality = 0,     -- hide deaths that lost nothing this rare (0 = show all)
    deathlogBackgroundOpacity = 0.78, -- deathlog background art opacity
    deathlogBackgroundShadow = 0.78, -- deathlog dark overlay opacity
    deathlogFontSize = 11,      -- deathlog row text size
}

-- Gear slots tracked (shirt=4, tabard=19 excluded)
local GEAR_SLOTS = { 1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18 }

-- Classes whose ranged slot (18) is a wand, not a bow/gun
local WAND_CLASSES = { PRIEST=true, MAGE=true, WARLOCK=true }

local combatSnapshot  = {}   -- items recorded on combat entry
local markedItems     = {}   -- items selected for deletion after death
local isDead          = false
local lastDeathSource = nil  -- last attacker/environment that hit the player
local tookEnemyPlayerDamageThisCombat = false
local pendingGuildDeathMessage
local minimapButton
local UpdateMinimapButtonPosition
local ApplyRepairBlock
local ClearPendingDeletionData
local activeSelfFoundSource
local selfFoundBagSnapshot
local selfFoundMoneySnapshot
local minimapShapes = {
    ["ROUND"] = {true, true, true, true},
    ["SQUARE"] = {false, false, false, false},
    ["CORNER-TOPLEFT"] = {false, false, false, true},
    ["CORNER-TOPRIGHT"] = {false, false, true, false},
    ["CORNER-BOTTOMLEFT"] = {false, true, false, false},
    ["CORNER-BOTTOMRIGHT"] = {true, false, false, false},
    ["SIDE-LEFT"] = {false, true, false, true},
    ["SIDE-RIGHT"] = {true, false, true, false},
    ["SIDE-TOP"] = {false, false, true, true},
    ["SIDE-BOTTOM"] = {true, true, false, false},
    ["TRICORNER-TOPLEFT"] = {false, true, true, true},
    ["TRICORNER-TOPRIGHT"] = {true, false, true, true},
    ["TRICORNER-BOTTOMLEFT"] = {true, true, false, true},
    ["TRICORNER-BOTTOMRIGHT"] = {true, true, true, false},
}

local function GetMinimapAngleFromCursor()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    return math.deg(math.atan2(cy - my, cx - mx)) % 360
end

local function ApplyMinimapButtonVisibility()
    if not minimapButton then return end
    if Rustcore.GetSetting("showMinimapButton") then
        minimapButton:Show()
        UpdateMinimapButtonPosition()
    else
        minimapButton:Hide()
    end
end

-- ── Settings ──────────────────────────────────────────────────────────────────

function Rustcore.GetSetting(key)
    local profile = EnsureProfile()
    if profile[key] == nil then
        profile[key] = defaults[key]
    end
    return profile[key]
end

-- Non-gameplay layout/placement values (window position, size, minimap angle).
-- Still per-character, but not combat-locked and not seeded from `defaults` —
-- dragging a window shouldn't silently fail to save just because you're in combat.
function Rustcore.GetProfileValue(key)
    return EnsureProfile()[key]
end

function Rustcore.SetProfileValue(key, value)
    EnsureProfile()[key] = value
end

-- Keys of every gameplay/UI toggle setting (as opposed to the pure layout
-- values handled by Get/SetProfileValue). Used by the options window's
-- character-import feature to copy toggles and difficulty, not just placement.
function Rustcore.GetDefaultSettingKeys()
    local keys = {}
    for k in pairs(defaults) do
        keys[#keys + 1] = k
    end
    return keys
end

function Rustcore.SettingsLocked()
    return InCombatLockdown and InCombatLockdown()
end

function Rustcore.RefreshMinimapPosition()
    if UpdateMinimapButtonPosition then
        UpdateMinimapButtonPosition()
    end
end

function Rustcore.GetCharacterKey()
    return GetCurrentCharacterKey()
end

function Rustcore.GetAssetPath(filename)
    local folder = Rustcore.assetFolder or "Rustcore"
    return "Interface\\AddOns\\" .. folder .. "\\" .. filename
end

local function EnsureSelfFoundProfile()
    RustcoreDB.selfFoundCharacters = RustcoreDB.selfFoundCharacters or {}
    local key = Rustcore.GetCharacterKey and Rustcore.GetCharacterKey() or UnitName("player") or "player"
    RustcoreDB.selfFoundCharacters[key] = RustcoreDB.selfFoundCharacters[key] or {}
    local profile = RustcoreDB.selfFoundCharacters[key]
    if profile.startedAtLevelOne == nil then profile.startedAtLevelOne = false end
    if profile.hasEnabledSelfFound == nil then profile.hasEnabledSelfFound = profile.startedAtLevelOne or false end
    if profile.externalItemReceived == nil then profile.externalItemReceived = false end
    return profile
end

local function MarkSelfFoundEnabled()
    if not Rustcore.GetSetting("selfFound") then return end
    local profile = EnsureSelfFoundProfile()
    profile.hasEnabledSelfFound = true
    if (UnitLevel("player") or 0) <= 1 then
        profile.startedAtLevelOne = true
    end
end

-- The single gate for the Self-Found buff (RustcoreSelfFoundBuff) and for the
-- one bit peers are told about (RustcoreSelfFoundComm). Plan section 28: the
-- buff shows during VERIFIED and WARNING and is hidden during UNCERTAIN,
-- UNVERIFIED and FAILED; section 46: peers learn the flag and nothing else.
function Rustcore.GetSelfFoundIconState()
    local profile = EnsureSelfFoundProfile()
    if not profile.hasEnabledSelfFound or profile.externalItemReceived then
        return nil
    end
    if not Rustcore.GetSetting("selfFound") then
        return "warning"
    end

    -- Verification has the final say, and its absence is not a pass.
    --
    -- This used to report "verified" when no record existed, on the reasoning
    -- that a load failure should not blank a buff the player already had. But
    -- the buff is a claim that Rustcore is vouching for this run, and it is also
    -- what peers are told, so answering "verified" when verification cannot
    -- answer at all is the one direction this must not fail in.
    local V = RustcoreVerification
    if not (V and V.GetTrack and V.IsSelfFoundCertified) then return nil end
    if not V.GetTrack("selfFound") then return nil end
    return V.IsSelfFoundCertified() and "verified" or nil
end

-- Spell 431567 "Self-Found Adventurer" is Blizzard's real Hardcore
-- Self-Found buff. We show its actual icon (fetched live, not a bundled
-- asset) so our own tracked self-found status reads as that real buff.
local SELF_FOUND_SPELL_ID = 431567

function Rustcore.GetSelfFoundIconTexture()
    local tex
    if C_Spell and C_Spell.GetSpellTexture then
        tex = C_Spell.GetSpellTexture(SELF_FOUND_SPELL_ID)
    elseif GetSpellTexture then
        tex = GetSpellTexture(SELF_FOUND_SPELL_ID)
    end
    return tex or Rustcore.GetAssetPath("UI/Rustcore Selffound copy 2.tga")
end

local function RefreshSelfFoundStatsIcon()
    if RustcoreSelfFoundBuff and RustcoreSelfFoundBuff.Refresh then
        RustcoreSelfFoundBuff.Refresh()
    end
end

local function GetBagItemLinkAndCount(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then
            return info.hyperlink, info.stackCount or 1
        end
    elseif GetContainerItemInfo then
        local _, count, _, _, _, _, link = GetContainerItemInfo(bag, slot)
        return link, count or 1
    end
end

local function GetItemCountKey(link)
    if not link then return nil end
    return link:match("item:(%d+)") or link
end

local function CaptureBagSnapshot()
    local snapshot = {}
    local maxBag = NUM_BAG_SLOTS or 4
    for bag = 0, maxBag do
        local slots = 0
        if C_Container and C_Container.GetContainerNumSlots then
            slots = C_Container.GetContainerNumSlots(bag) or 0
        elseif GetContainerNumSlots then
            slots = GetContainerNumSlots(bag) or 0
        end
        for slot = 1, slots do
            local link, count = GetBagItemLinkAndCount(bag, slot)
            local key = GetItemCountKey(link)
            if key then
                snapshot[key] = (snapshot[key] or 0) + (count or 1)
            end
        end
    end
    return snapshot
end

local function MarkExternalSelfFoundItem(source)
    local profile = EnsureSelfFoundProfile()
    if profile.externalItemReceived then return end
    profile.externalItemReceived = true
    profile.externalItemSource = source
    profile.externalItemTime = time and time() or nil
    print("|cffff4444Rustcore:|r Self Found verification lost after receiving something from " .. source .. ".")
    RefreshSelfFoundStatsIcon()
end

local function CheckForExternalSelfFoundItems(source)
    if not activeSelfFoundSource or activeSelfFoundSource ~= source or not selfFoundBagSnapshot then return end
    if source ~= "mail" and source ~= "trade" then return end
    local current = CaptureBagSnapshot()
    for key, count in pairs(current) do
        if count > (selfFoundBagSnapshot[key] or 0) then
            MarkExternalSelfFoundItem(source)
            break
        end
    end

    if selfFoundMoneySnapshot and GetMoney and GetMoney() > selfFoundMoneySnapshot then
        MarkExternalSelfFoundItem(source)
    end
end

local function BeginSelfFoundSource(source)
    if Rustcore.GetSetting("selfFound") then return end
    activeSelfFoundSource = source
    selfFoundBagSnapshot = CaptureBagSnapshot()
    selfFoundMoneySnapshot = GetMoney and GetMoney() or nil
    RefreshSelfFoundStatsIcon()
end

local function EndSelfFoundSource(source)
    if activeSelfFoundSource ~= source then return end
    C_Timer.After(0.5, function()
        CheckForExternalSelfFoundItems(source)
        if activeSelfFoundSource == source then
            activeSelfFoundSource = nil
            selfFoundBagSnapshot = nil
            selfFoundMoneySnapshot = nil
        end
    end)
end

function Rustcore.SetSetting(key, value)
    if Rustcore.SettingsLocked() then
        print("|cffff4444Rustcore:|r Settings cannot be changed while in combat.")
        return false
    end
    EnsureProfile()[key] = value
    if key == "selfFound" then
        if value then
            MarkSelfFoundEnabled()
        end
        if RustcoreVerification and RustcoreVerification.SelfFound then
            -- Plan section 6: the claim and its baseline start the moment
            -- Self-Found is switched on, not at the next login.
            RustcoreVerification.SelfFound.OnSettingChanged(value and true or false)
        end
        RefreshSelfFoundStatsIcon()
    end
    if key == "selfFoundBuffEnabled" then
        RefreshSelfFoundStatsIcon()
    end
    if key == "difficulty" and RustcoreVerification and RustcoreVerification.Difficulty then
        -- Plan section 8: a difficulty change is recorded, never a
        -- certification change. Kept out of the refresh chain below so it
        -- cannot depend on which optional UI modules happen to be loaded.
        RustcoreVerification.Difficulty.SyncSelectedTier()
    end
    if key == "showMinimapButton" then
        ApplyMinimapButtonVisibility()
    elseif key == "allowRepair" and ApplyRepairBlock then
        C_Timer.After(0, ApplyRepairBlock)
        if RustcoreStats and RustcoreStats.RefreshLayout then
            RustcoreStats.RefreshLayout()
        end
    elseif key == "showStatsWindow" and RustcoreStats then
        RustcoreStats.ApplyVisibility()
    elseif key == "difficulty" and RustcoreStats and RustcoreStats.RefreshStyle then
        RustcoreStats.RefreshStyle()
        RustcoreStats.RefreshLayout()
        if RustcoreDragon then
            if RustcoreDragon.RefreshPlayerFrame then RustcoreDragon.RefreshPlayerFrame() end
            if RustcoreDragon.RefreshTargetFrame then RustcoreDragon.RefreshTargetFrame() end
        end
    elseif key == "statsBackground" and RustcoreStats then
        if RustcoreStats.HandleBackgroundChanged then
            RustcoreStats.HandleBackgroundChanged()
        elseif RustcoreStats.RefreshLayout then
            RustcoreStats.RefreshLayout()
        end
    elseif key == "statsBackgroundOpacity" and RustcoreStats and RustcoreStats.RefreshBackgroundOpacity then
        RustcoreStats.RefreshBackgroundOpacity()
    elseif key == "statsBackgroundShadow" and RustcoreStats and RustcoreStats.RefreshBackgroundShadow then
        RustcoreStats.RefreshBackgroundShadow()
    elseif key == "dragonPlayerFrame" and RustcoreDragon and RustcoreDragon.RefreshPlayerFrame then
        RustcoreDragon.RefreshPlayerFrame()
    elseif key == "dragonTargetFrame" and RustcoreDragon and RustcoreDragon.RefreshTargetFrame then
        RustcoreDragon.RefreshTargetFrame()
    elseif key == "deathlogBackgroundOpacity" and RustcoreDeathlog and RustcoreDeathlog.RefreshBackgroundOpacity then
        RustcoreDeathlog.RefreshBackgroundOpacity()
    elseif key == "deathlogBackgroundShadow" and RustcoreDeathlog and RustcoreDeathlog.RefreshBackgroundShadow then
        RustcoreDeathlog.RefreshBackgroundShadow()
    elseif key == "deathlogFontSize" and RustcoreDeathlog and RustcoreDeathlog.RefreshFontSize then
        RustcoreDeathlog.RefreshFontSize()
    elseif key == "statsColoredNumbers" and RustcoreStats and RustcoreStats.Refresh then
        -- Colour only: the digits are re-tinted in place, nothing moves.
        RustcoreStats.Refresh()
    elseif (key == "statsHorizontalLayout"
            or key == "statShowRusted" or key == "statShowBroken"
            or key == "statShowDeaths" or key == "statShowBestItem")
            and RustcoreStats then
        -- Turning a counter on or off changes how many cells the row has, so
        -- the window has to be re-measured, not just repainted.
        if RustcoreStats.ApplyLayoutModeChange then
            RustcoreStats.ApplyLayoutModeChange()
        elseif RustcoreStats.RefreshLayout then
            RustcoreStats.RefreshLayout()
        end
    elseif key == "durHUDGrowUpward" and RustcoreDurability then
        if RustcoreDurability.HandleGrowUpwardChanged then
            RustcoreDurability.HandleGrowUpwardChanged()
        elseif RustcoreDurability.RefreshPosition then
            RustcoreDurability.RefreshPosition()
        end
    elseif (key == "showDurabilityHUD" or key == "showAllDurability") and RustcoreDurability and RustcoreDurability.Refresh then
        RustcoreDurability.Refresh()
    elseif key == "durHUDReverseOrder" and RustcoreDurability and RustcoreDurability.HandleReverseOrderChanged then
        RustcoreDurability.HandleReverseOrderChanged()
    elseif key == "durHUDHorizontal" and RustcoreDurability then
        if RustcoreDurability.HandleHorizontalChanged then
            RustcoreDurability.HandleHorizontalChanged()
        elseif RustcoreDurability.RefreshPosition then
            RustcoreDurability.RefreshPosition()
        end
    elseif key == "durHUDBackground" and RustcoreDurability then
        if RustcoreDurability.HandleBackgroundChanged then
            RustcoreDurability.HandleBackgroundChanged()
        elseif RustcoreDurability.RefreshPosition then
            RustcoreDurability.RefreshPosition()
        end
    elseif key == "durHUDBackgroundOpacity" and RustcoreDurability and RustcoreDurability.RefreshBackgroundOpacity then
        RustcoreDurability.RefreshBackgroundOpacity()
    elseif key == "durHUDBackgroundShadow" and RustcoreDurability and RustcoreDurability.RefreshBackgroundShadow then
        RustcoreDurability.RefreshBackgroundShadow()
    elseif key == "showDeathlogWindow" and RustcoreDeathlog then
        RustcoreDeathlog.ApplyVisibility()
    elseif (key == "showDeathlogLevel" or key == "showDeathlogCount" or key == "showDeathlogItem" or key == "showDeathlogSource" or key == "deathlogMinLevel" or key == "deathlogMinQuality") and RustcoreDeathlog then
        RustcoreDeathlog.RefreshRows()
    end
    return true
end

-- Death rarity filter ---------------------------------------------------------
--
-- One rule with three consumers -- the chat line, the centre-screen warning and
-- the death log -- so it is answered once here instead of three times in three
-- modules that would drift apart.
--
-- The slider is a floor, not a band: at Green, a death that lost a blue is
-- still worth hearing about. Position 0 is off and lets everything through,
-- including a death that lost nothing at all; every position above it implies
-- at least one item was lost, because that is what a rarity is a statement
-- about.
local QUALITY_FILTER_NAMES = {
    [0] = "Off",
    [1] = "Grey",
    [2] = "White",
    [3] = "Green",
    [4] = "Blue",
    [5] = "Epic",
}

function Rustcore.GetDeathQualityFilterName(value)
    return QUALITY_FILTER_NAMES[tonumber(value) or -1] or tostring(value)
end

-- Reverse of ITEM_QUALITY_COLORS, built on first use rather than at load: this
-- file runs before the client has necessarily finished setting that global up.
local qualityByHex

-- GetItemInfo is the better answer whenever it has one, but it returns nil for
-- an item this client has never seen -- which is the ordinary case for a
-- stranger's death arriving over the realm channel. The quality colour is baked
-- into the link itself and is always present, so it is the fallback rather than
-- the other way round.
function Rustcore.GetDeathItemQuality(link)
    if type(link) ~= "string" or link == "" then return nil end

    if GetItemInfo then
        local quality = select(3, GetItemInfo(link))
        if quality then return quality end
    end

    if not qualityByHex then
        qualityByHex = {}
        if ITEM_QUALITY_COLORS then
            for quality, color in pairs(ITEM_QUALITY_COLORS) do
                if type(quality) == "number" and type(color) == "table" and color.hex then
                    qualityByHex[color.hex:lower()] = quality
                end
            end
        end
    end

    local hex = link:match("^|c(%x%x%x%x%x%x%x%x)")
    if not hex then return nil end
    return qualityByHex["|c" .. hex:lower()]
end

-- True when a death is worth showing. `d` is the wire payload: `count` is how
-- many items the death took, and `link` is the single representative item that
-- travelled with it, so this is only ever as good as that one link.
function Rustcore.DeathPassesQualityFilter(d)
    local value = tonumber(Rustcore.GetSetting("deathlogMinQuality")) or 0
    if value <= 0 then return true end
    if not d then return false end

    -- Every position above Off is a statement about an item that was lost, so a
    -- death that took nothing is out before rarity is even considered.
    if (tonumber(d.count) or 0) <= 0 then return false end

    -- Grey is the lowest rarity there is, so "grey or better" is satisfied by
    -- any loss at all and never needs the link resolved. That matters: it keeps
    -- the first position working even for an item this client cannot identify.
    local minQuality = value - 1
    if minQuality <= 0 then return true end

    local quality = Rustcore.GetDeathItemQuality(d.link)
    if not quality then return false end
    return quality >= minQuality
end

-- Pre-profiles layout keys that used to live flat on RustcoreDB.
local LEGACY_LAYOUT_KEYS = { "durHUDPos", "statsWindowPoint", "statsWindowSize", "minimapAngle" }

-- One-time claim of the old account-wide flat settings by whichever character
-- logs in first after this update. Every other/future character starts at
-- `defaults`. Safe to call every login: no-ops once RustcoreDB.legacySettingsMigrated is set.
local function MigrateLegacySettings()
    RustcoreDB.profiles = RustcoreDB.profiles or {}
    if RustcoreDB.legacySettingsMigrated then return end

    local profile = EnsureProfile()
    for k in pairs(defaults) do
        if RustcoreDB[k] ~= nil then
            profile[k] = RustcoreDB[k]
            RustcoreDB[k] = nil
        end
    end
    for _, k in ipairs(LEGACY_LAYOUT_KEYS) do
        if RustcoreDB[k] ~= nil then
            profile[k] = RustcoreDB[k]
            RustcoreDB[k] = nil
        end
    end

    RustcoreDB.legacySettingsMigrated = true
end

local function InitSettings()
    -- Migrate old blockRepair key to allowRepair
    if RustcoreDB.blockRepair ~= nil and RustcoreDB.allowRepair == nil then
        RustcoreDB.allowRepair = not RustcoreDB.blockRepair
        RustcoreDB.blockRepair = nil
    end
    -- Migrate showDurabilityTooltip → showDurabilityHUD
    if RustcoreDB.showDurabilityTooltip ~= nil and RustcoreDB.showDurabilityHUD == nil then
        RustcoreDB.showDurabilityHUD = RustcoreDB.showDurabilityTooltip
        RustcoreDB.showDurabilityTooltip = nil
    end
    MigrateLegacySettings()

    local profile = EnsureProfile()
    if not profile.statsBackgroundDefaults78Migrated then
        if profile.statsBackgroundShadow == nil or profile.statsBackgroundShadow == 0 then
            profile.statsBackgroundShadow = 0.78
        end
        profile.statsBackgroundDefaults78Migrated = true
    end
end

-- ── Weapon-slot detection ─────────────────────────────────────────────────────

local function GetMainWeaponSlot()
    local _, class = UnitClass("player")
    if class == "HUNTER" then
        return 18  -- ranged weapon
    elseif WAND_CLASSES[class] then
        if GetInventoryItemLink("player", 18) then
            return 18
        end
        return 16
    else
        return 16
    end
end

-- ── Combat snapshot ───────────────────────────────────────────────────────────

-- True when the last snapshot actually withheld an equipped item because of
-- the main-weapon exception. Verification needs to know whether the exception
-- changed anything, not merely whether it was switched on.
local snapshotWeaponSkipped = false

local function TakeSnapshot()
    wipe(combatSnapshot)
    local skipSlot = Rustcore.GetSetting("keepMainWeapon") and GetMainWeaponSlot() or nil
    snapshotWeaponSkipped = false
    if skipSlot and GetInventoryItemLink("player", skipSlot) then
        -- A broken item is ineligible anyway, so shielding it changed nothing.
        local durCurrent, durMax = GetInventoryItemDurability(skipSlot)
        local isBroken = durCurrent ~= nil and durMax ~= nil and durMax > 0 and durCurrent == 0
        snapshotWeaponSkipped = not isBroken
    end
    for _, slotId in ipairs(GEAR_SLOTS) do
        if slotId ~= skipSlot then
            local link = GetInventoryItemLink("player", slotId)
            if link then
                local durCurrent, durMax = GetInventoryItemDurability(slotId)
                local isBroken = durCurrent ~= nil and durMax ~= nil and durMax > 0 and durCurrent == 0
                if not isBroken then
                    local name, _, _, ilvl = GetItemInfo(link)
                    local tex = GetInventoryItemTexture("player", slotId) or GetItemIcon(link)
                    combatSnapshot[#combatSnapshot + 1] = {
                        slot = slotId,
                        link = link,
                        name = name or ("Slot " .. slotId),
                        tex = tex,
                        ilvl = ilvl or 0,
                    }
                end
            end
        end
    end
end

-- ── Death logic ───────────────────────────────────────────────────────────────

local function ShuffleInPlace(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end

local function BuildMarkedItems(source)
    wipe(markedItems)
    if #source == 0 then return end

    local difficulty = Rustcore.GetSetting("difficulty")

    if difficulty == 1 then
        -- Lite: repair is blocked, no items lost
        return

    elseif difficulty == 2 then
        -- Normal: lose 1 random item
        markedItems[1] = source[math.random(#source)]

    elseif difficulty == 3 then
        -- Hard: lose 25% rounded up
        local pool = {}
        for _, item in ipairs(source) do pool[#pool+1] = item end
        ShuffleInPlace(pool)
        local loseCount = math.ceil(#pool * 0.25)
        for i = 1, loseCount do
            markedItems[#markedItems+1] = pool[i]
        end

    elseif difficulty == 4 then
        -- Brutal: lose 50% rounded up
        local pool = {}
        for _, item in ipairs(source) do pool[#pool+1] = item end
        ShuffleInPlace(pool)
        local loseCount = math.ceil(#pool * 0.50)
        for i = 1, loseCount do
            markedItems[#markedItems+1] = pool[i]
        end

    elseif difficulty == 5 then
        -- Extreme: lose everything
        for _, item in ipairs(source) do
            markedItems[#markedItems+1] = item
        end
    end
end

local function FindHighestIlvlItem(items)
    local bestItem, bestIlvl = nil, -1
    for _, item in ipairs(items or {}) do
        if item and item.link then
            local ilvl = select(4, GetItemInfo(item.link)) or 0
            if ilvl > bestIlvl then
                bestItem = item
                bestIlvl = ilvl
            end
        end
    end
    return bestItem, math.max(bestIlvl, 0)
end

local function QueueGuildDeathMessage(items, deathSource)
    if not Rustcore.GetSetting("guildDeathMessage") then
        pendingGuildDeathMessage = nil
        return
    end
    if not IsInGuild or not IsInGuild() then
        pendingGuildDeathMessage = nil
        return
    end

    local bestItem = FindHighestIlvlItem(items)
    if not bestItem or not bestItem.link then
        pendingGuildDeathMessage = nil
        return
    end

    pendingGuildDeathMessage = {
        itemLink = bestItem.link,
        count = #items,
        deathSource = (deathSource and deathSource ~= "") and deathSource or "Unknown",
    }
end

function Rustcore.FlushPendingGuildDeathMessage()
    if not pendingGuildDeathMessage then return end
    if not Rustcore.GetSetting("guildDeathMessage") then
        pendingGuildDeathMessage = nil
        return
    end
    if not IsInGuild or not IsInGuild() then
        pendingGuildDeathMessage = nil
        return
    end

    local message = "[Rustcore] " .. pendingGuildDeathMessage.deathSource
        .. " broke " .. pendingGuildDeathMessage.count
        .. " of my items, including: " .. pendingGuildDeathMessage.itemLink
    if RustcoreBroadcast and RustcoreBroadcast.QueueChatMessage then
        RustcoreBroadcast.QueueChatMessage(message, "GUILD")
    end
    pendingGuildDeathMessage = nil
end

-- Certification follows the rules that actually governed the death, so
-- verification is told what happened rather than what the options say
-- (plan section 9). Wrapped so a verification fault can never break a death.
local function NotifyVerificationDeath(penaltyApplied, markedCount)
    -- Every death path funnels through here, so it is also where the stats
    -- counter is bumped -- including the paths where an exception cancelled the
    -- penalty, since the character still died.
    if RustcoreStats and RustcoreStats.RegisterDeath then
        pcall(RustcoreStats.RegisterDeath)
    end
    if not (RustcoreVerification and RustcoreVerification.Difficulty) then return end
    local ok, err = pcall(RustcoreVerification.Difficulty.OnDeath, {
        tier = Rustcore.GetSetting("difficulty"),
        penaltyApplied = penaltyApplied,
        mainWeaponSkipped = penaltyApplied and snapshotWeaponSkipped or false,
        markedCount = markedCount or 0,
    })
    if not ok then
        print("|cffff4444Rustcore ERROR:|r verification death hook: " .. tostring(err))
    end
end

local function OnPlayerDead()
    local ok, err = pcall(function()
        if Rustcore.GetSetting("ignoreDeathAfterEnemyPlayerDamage") and tookEnemyPlayerDamageThisCombat then
            ClearPendingDeletionData()
            pendingGuildDeathMessage = nil
            wipe(markedItems)
            RustcoreBroadcast.Announce(markedItems, lastDeathSource)
            NotifyVerificationDeath(false, 0)
            print("|cffff4444Rustcore:|r Death penalty skipped because you took damage from an enemy player during that combat.")
            return
        end

        local source = (#combatSnapshot > 0) and combatSnapshot or nil
        if not source then
            TakeSnapshot()
            source = combatSnapshot
        end

        BuildMarkedItems(source)
        NotifyVerificationDeath(true, #markedItems)

        -- Always announce the death itself (deathlog entry + channel broadcast),
        -- even when nothing was lost (Lite mode, or no eligible items in the
        -- snapshot) — otherwise deaths with no item loss never register for
        -- other players.
        RustcoreBroadcast.Announce(markedItems, lastDeathSource)

        if #markedItems > 0 then
            RustcoreDB.pendingDeletion = {}
            RustcoreDB.pendingDeletionSnapshot = {}
            RustcoreDB.pendingDeletionOwner = GetCurrentCharacterKey()
            for _, item in ipairs(markedItems) do
                RustcoreDB.pendingDeletion[#RustcoreDB.pendingDeletion+1] = {
                    slot = item.slot, link = item.link, name = item.name, tex = item.tex, ilvl = item.ilvl,
                }
                -- Verification is told here rather than by the deletion frame,
                -- because the frame is the thing a player can close. What the
                -- death took is settled at this point whether or not anybody
                -- ever looks at the window.
                if RustcoreVerification and RustcoreVerification.DeathLoss
                    and RustcoreVerification.DeathLoss.Note then
                    pcall(RustcoreVerification.DeathLoss.Note, item.link, item.slot)
                end
            end
            for _, item in ipairs(source) do
                RustcoreDB.pendingDeletionSnapshot[#RustcoreDB.pendingDeletionSnapshot+1] = {
                    slot = item.slot, link = item.link, name = item.name, tex = item.tex, ilvl = item.ilvl,
                }
            end
            RustcoreDB.lastDeathSource = lastDeathSource
            QueueGuildDeathMessage(markedItems, lastDeathSource)
            if RustcoreUI and RustcoreUI.SetSpinCompleteCallback then
                RustcoreUI.SetSpinCompleteCallback(Rustcore.FlushPendingGuildDeathMessage)
            end
            RustcoreUI.ShowDeletionFrame(markedItems, source)
        else
            if Rustcore.GetSetting("difficulty") == 1 then
                print("|cffff4444Rustcore:|r Lite mode — no items lost.")
            else
                print("|cffff4444Rustcore:|r No items marked for deletion.")
            end
        end
    end)
    if not ok then
        print("|cffff4444Rustcore ERROR:|r " .. tostring(err))
    end
end

-- ── Merchant repair blocking ──────────────────────────────────────────────────

ApplyRepairBlock = function()
    if not Rustcore.GetSetting("allowRepair") then
        if MerchantRepairAllButton  then MerchantRepairAllButton:Disable();  MerchantRepairAllButton:SetAlpha(0.35)  end
        if MerchantRepairItemButton then MerchantRepairItemButton:Disable(); MerchantRepairItemButton:SetAlpha(0.35) end
    else
        if MerchantRepairAllButton  then MerchantRepairAllButton:Enable();  MerchantRepairAllButton:SetAlpha(1) end
        if MerchantRepairItemButton then MerchantRepairItemButton:Enable(); MerchantRepairItemButton:SetAlpha(1) end
    end
end

local function ResetRepairButtons()
    if MerchantRepairAllButton  then MerchantRepairAllButton:Enable();  MerchantRepairAllButton:SetAlpha(1) end
    if MerchantRepairItemButton then MerchantRepairItemButton:Enable(); MerchantRepairItemButton:SetAlpha(1) end
end

ClearPendingDeletionData = function()
    RustcoreDB.pendingDeletion = nil
    RustcoreDB.pendingDeletionSnapshot = nil
    RustcoreDB.pendingDeletionOwner = nil
    RustcoreDB.lastDeathSource = nil
end

local function PendingDeletionBelongsToCurrentCharacter()
    return RustcoreDB.pendingDeletionOwner == nil or RustcoreDB.pendingDeletionOwner == GetCurrentCharacterKey()
end

-- ── Event handling ────────────────────────────────────────────────────────────

UpdateMinimapButtonPosition = function()
    if not minimapButton then return end
    local angle = math.rad(Rustcore.GetProfileValue("minimapAngle") or 220)
    local x, y = math.cos(angle), math.sin(angle)
    local quadrant = 1
    if x < 0 then quadrant = quadrant + 1 end
    if y > 0 then quadrant = quadrant + 2 end
    local minimapShape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local quadTable = minimapShapes[minimapShape] or minimapShapes["ROUND"]
    local radius = 5
    local width = (Minimap:GetWidth() / 2) + radius
    local height = (Minimap:GetHeight() / 2) + radius
    if quadTable[quadrant] then
        x, y = x * width, y * height
    else
        local diagWidth = math.sqrt(2 * (width ^ 2)) - 10
        local diagHeight = math.sqrt(2 * (height ^ 2)) - 10
        x = math.max(-width, math.min(x * diagWidth, width))
        y = math.max(-height, math.min(y * diagHeight, height))
    end
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    if minimapButton or not Minimap then return end

    local btn = CreateFrame("Button", "RustcoreMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForDrag("LeftButton")
    btn:RegisterForClicks("AnyUp")

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -5)
    bg:SetVertexColor(0.15, 0.15, 0.15)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(Rustcore.GetAssetPath("RCicon.png"))
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -6)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon
    btn.iconBaseSize = 17

    if btn.CreateMaskTexture and icon.AddMaskTexture then
        local mask = btn:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetPoint("CENTER", icon, "CENTER", 0, 0)
        mask:SetSize(17, 17)
        icon:AddMaskTexture(mask)
        btn.iconMask = mask
    end

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    local highlight = btn:GetHighlightTexture()
    highlight:SetBlendMode("ADD")
    highlight:SetSize(53, 53)
    highlight:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

    local clickAnim = icon:CreateAnimationGroup()
    local shrink = clickAnim:CreateAnimation("Scale")
    shrink:SetOrder(1)
    shrink:SetDuration(0.06)
    shrink:SetScale(0.88, 0.88)
    shrink:SetOrigin("CENTER", 0, 0)

    local grow = clickAnim:CreateAnimation("Scale")
    grow:SetOrder(2)
    grow:SetDuration(0.08)
    grow:SetScale(1.1363636, 1.1363636)
    grow:SetOrigin("CENTER", 0, 0)

    clickAnim:SetScript("OnPlay", function()
        if btn.icon then
            btn.icon:SetSize(btn.iconBaseSize, btn.iconBaseSize)
        end
    end)
    clickAnim:SetScript("OnFinished", function()
        if btn.icon then
            btn.icon:SetSize(btn.iconBaseSize, btn.iconBaseSize)
        end
    end)
    btn.clickAnim = clickAnim

    btn:SetScript("OnEnter", function(self)
        if self:GetHighlightTexture() then
            self:GetHighlightTexture():Show()
        end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Rustcore")
        GameTooltip:AddLine("Left-click: Open options", 1, 1, 1)
        GameTooltip:AddLine("Right-click: Show pending deletions", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        if self:GetHighlightTexture() then
            self:GetHighlightTexture():Hide()
        end
        GameTooltip:Hide()
    end)
    btn:SetScript("OnClick", function(_, button)
        if btn.clickAnim then
            btn.clickAnim:Stop()
            btn.clickAnim:Play()
        end
        if button == "RightButton" then
            RustcoreUI.ReopenDeletionFrame()
        else
            RustcoreOptions.Toggle()
        end
    end)
    btn:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        self.dragging = true
        self:SetScript("OnUpdate", function()
            Rustcore.SetProfileValue("minimapAngle", GetMinimapAngleFromCursor())
            UpdateMinimapButtonPosition()
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self:UnlockHighlight()
        self.dragging = nil
        self:SetScript("OnUpdate", nil)
        Rustcore.SetProfileValue("minimapAngle", GetMinimapAngleFromCursor())
        UpdateMinimapButtonPosition()
    end)

    minimapButton = btn
    ApplyMinimapButtonVisibility()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_UNGHOST")
eventFrame:RegisterEvent("UI_SCALE_CHANGED")
eventFrame:RegisterEvent("MAIL_SHOW")
eventFrame:RegisterEvent("MAIL_CLOSED")
-- AUCTION_HOUSE_SHOW is handled in Verification/SelfFoundRestrict.lua.
eventFrame:RegisterEvent("TRADE_SHOW")
eventFrame:RegisterEvent("TRADE_CLOSED")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("PLAYER_MONEY")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if (...) == "Rustcore" then
            Rustcore.assetFolder = (...)
            -- Must run before InitSettings and before any other module
            -- creates per-character tables: verification tells a returning
            -- Rustcore character from a new one by reading RustcoreDB while
            -- it is still exactly as the last session left it.
            if RustcoreVerification and RustcoreVerification.CaptureLegacyEvidence then
                RustcoreVerification.CaptureLegacyEvidence()
            end
            InitSettings()
            EnsureSelfFoundProfile()
            MarkSelfFoundEnabled()
            RustcoreBroadcast.Init()
            if RustcoreStats and RustcoreStats.Init then
                RustcoreStats.Init()
            end
            if RustcoreDurability and RustcoreDurability.Init then
                RustcoreDurability.Init()
            end
            if RustcoreDeathlog and RustcoreDeathlog.Init then
                RustcoreDeathlog.Init()
            end
            if RustcoreVerification and RustcoreVerification.Init then
                RustcoreVerification.Init()
            end
            CreateMinimapButton()
            print("|cffff4444Rustcore|r loaded. |cffffd700/rustcore|r for options.")

            if RustcoreDB.pendingDeletion and #RustcoreDB.pendingDeletion > 0 and PendingDeletionBelongsToCurrentCharacter() then
                C_Timer.After(1, function()
                    RustcoreUI.ShowDeletionFrame(RustcoreDB.pendingDeletion, RustcoreDB.pendingDeletionSnapshot, true)
                end)
            end

            if RustcoreDifficultyPopup and RustcoreDifficultyPopup.MaybeShowOnLogin then
                C_Timer.After(1, RustcoreDifficultyPopup.MaybeShowOnLogin)
            end
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        TakeSnapshot()
        tookEnemyPlayerDamageThisCombat = false

    elseif event == "PLAYER_REGEN_ENABLED" then
        if not isDead then
            wipe(combatSnapshot)
            lastDeathSource = nil
            tookEnemyPlayerDamageThisCombat = false
        end

    elseif event == "PLAYER_DEAD" then
        isDead = true
        OnPlayerDead()

    elseif event == "PLAYER_ALIVE" then
        isDead = false
        wipe(combatSnapshot)
        wipe(markedItems)
        lastDeathSource = nil
        tookEnemyPlayerDamageThisCombat = false

        if not UnitIsDeadOrGhost("player") then
            if RustcoreDB.pendingDeletion and #RustcoreDB.pendingDeletion > 0 and PendingDeletionBelongsToCurrentCharacter() then
                C_Timer.After(1, function()
                    RustcoreUI.OnResurrect(RustcoreDB.pendingDeletion, RustcoreDB.pendingDeletionSnapshot)
                end)
            end
        end

    elseif event == "PLAYER_UNGHOST" then
        if UnitIsDeadOrGhost("player") then return end
        if RustcoreDB.pendingDeletion and #RustcoreDB.pendingDeletion > 0 and PendingDeletionBelongsToCurrentCharacter() then
            C_Timer.After(1, function()
                RustcoreUI.OnResurrect(RustcoreDB.pendingDeletion, RustcoreDB.pendingDeletionSnapshot)
            end)
        end

    elseif event == "PLAYER_ENTERING_WORLD" or event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
        UpdateMinimapButtonPosition()

    elseif event == "MAIL_SHOW" then
        if not Rustcore.GetSetting("selfFound") then
            -- Self-Found off: nothing to block, but the legacy icon state still
            -- tracks whether this character ever took items from another player.
            BeginSelfFoundSource("mail")
        end
        -- Self-Found on: the mailbox deliberately stays open. NPC and quest mail
        -- has to keep working, so Verification/Mail.lua locks the forbidden mail
        -- individually instead of hiding the whole frame.

    elseif event == "MAIL_CLOSED" then
        EndSelfFoundSource("mail")

    elseif event == "TRADE_SHOW" then
        if not Rustcore.GetSetting("selfFound") then
            -- Self-Found off: nothing to block, but the legacy icon state still
            -- tracks whether this character ever took items from another player.
            BeginSelfFoundSource("trade")
        end

    elseif event == "TRADE_CLOSED" then
        EndSelfFoundSource("trade")

    elseif event == "BAG_UPDATE_DELAYED" then
        if activeSelfFoundSource then
            CheckForExternalSelfFoundItems(activeSelfFoundSource)
        end

    elseif event == "PLAYER_MONEY" then
        if activeSelfFoundSource then
            CheckForExternalSelfFoundItems(activeSelfFoundSource)
        end

    elseif event == "MERCHANT_SHOW" then
        ApplyRepairBlock()

    elseif event == "MERCHANT_CLOSED" then
        ResetRepairButtons()

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender = ...
        RustcoreBroadcast.OnAddonMessage(prefix, message, distribution, sender)
    end
end)

-- ── Combat log ────────────────────────────────────────────────────────────────
do
    local playerGUID
    local clFrame = CreateFrame("Frame")
    clFrame:RegisterEvent("PLAYER_LOGIN")
    clFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    clFrame:SetScript("OnEvent", function(_, ev, ...)
        if ev == "PLAYER_LOGIN" then
            playerGUID = UnitGUID("player")
            return
        end
        local _, subEv, _, _, srcName, srcFlags, _, dstGUID = CombatLogGetCurrentEventInfo()
        if not subEv or dstGUID ~= playerGUID then return end
        if subEv == "ENVIRONMENTAL_DAMAGE" then
            lastDeathSource = select(12, CombatLogGetCurrentEventInfo())
        elseif subEv:find("DAMAGE", 1, true) and srcName and srcName ~= "" then
            lastDeathSource = srcName
            if Rustcore.GetSetting("ignoreDeathAfterEnemyPlayerDamage")
                and srcFlags
                and bit.band(srcFlags, COMBATLOG_OBJECT_TYPE_PLAYER or 0) ~= 0
                and bit.band(srcFlags, COMBATLOG_OBJECT_REACTION_HOSTILE or 0) ~= 0 then
                tookEnemyPlayerDamageThisCombat = true
            end
        end
    end)
end

-- ── Block auto-repair from other addons ──────────────────────────────────────
do
    local _origRepairAllItems = RepairAllItems
    RepairAllItems = function(...)
        if not Rustcore.GetSetting("allowRepair") then
            print("|cffff4444Rustcore:|r Repair blocked.")
            return
        end
        if _origRepairAllItems then
            return _origRepairAllItems(...)
        end
    end

    if ShowRepairCursor then
        local _origShowRepairCursor = ShowRepairCursor
        ShowRepairCursor = function(...)
            if not Rustcore.GetSetting("allowRepair") then
                print("|cffff4444Rustcore:|r Repair blocked.")
                return
            end
            return _origShowRepairCursor(...)
        end
    end
end

-- ── Slash commands ────────────────────────────────────────────────────────────

SLASH_RUSTCORE1 = "/rustcore"
SLASH_RUSTCORE2 = "/rc"
SlashCmdList["RUSTCORE"] = function()
    RustcoreOptions.Toggle()
end

-- Manual trigger for the difficulty popup, since its auto-show-on-login
-- call is disabled while we isolate a login crash (2026-07-28).
SLASH_RCPOPUP1 = "/rcpopup"
SlashCmdList["RCPOPUP"] = function()
    if not (RustcoreDifficultyPopup and RustcoreDifficultyPopup.Show) then
        print("|cffff4444Rustcore:|r difficulty popup is not loaded.")
        return
    end
    local ok, err = pcall(RustcoreDifficultyPopup.Show)
    if not ok then
        print("|cffff4444Rustcore:|r difficulty popup error: " .. tostring(err))
    end
end
