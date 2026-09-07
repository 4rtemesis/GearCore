-- RustcoreSelfFoundComm: lets Rustcore users see each other's verified Self
-- Found status, and (separately) each other's difficulty tier for the dragon
-- frame overlay. Clicking (targeting/focusing) a player queries them with a
-- direct addon whisper; any Rustcore client that receives the query answers
-- directly to the requester with its difficulty tier plus whether it
-- currently reports "verified"
-- self-found (Rustcore.GetSelfFoundIconState). Only the verified flag stays
-- privacy-gated the way it always has - the self-found icon only ever shows
-- for a "yes"; difficulty rides along unconditionally since running the
-- addon at all is what the dragon overlay cares about, not self-found status.
--
-- Message format: RCSF~Q~<name>                          (query: "tell me about <name>")
--                 RCSF~R~<name>~<verified 1|0>~<difficulty>  (response)

RustcoreSelfFoundComm = {}

local PREFIX = "RCSF"
local DELIM = "~"
local QUERY_TTL = 15
local RESPONSE_TTL = 120
local POLL_INTERVAL = 1
local ICON_SIZE = 14

local queried = {}      -- normalized name -> last query time
local verified = {}     -- normalized name -> last verified-response time
local seen = {}          -- normalized name -> last any-response time (addon presence, regardless of verified)
local difficultyOf = {} -- normalized name -> last reported difficulty tier
local overlays = {}     -- frame -> overlay texture
local prefixRegistered = false

local WATCHED_FRAMES = {
    { frame = "TargetFrame", unit = "target" },
    { frame = "FocusFrame", unit = "focus" },
    { frame = "PartyMemberFrame1", unit = "party1" },
    { frame = "PartyMemberFrame2", unit = "party2" },
    { frame = "PartyMemberFrame3", unit = "party3" },
    { frame = "PartyMemberFrame4", unit = "party4" },
}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function NormalizeName(name)
    if type(name) ~= "string" or name == "" then return nil end
    if Ambiguate then
        return Ambiguate(name, "short")
    end
    return name:match("^[^-]+") or name
end

local function GetUnitFullName(unit)
    local name, realm
    if UnitFullName then
        name, realm = UnitFullName(unit)
    else
        name, realm = UnitName(unit)
    end
    if not name then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

local function SendMessage(msg, whisperTarget)
    if not prefixRegistered then return false end
    if whisperTarget and whisperTarget ~= "" then
        if C_ChatInfo and C_ChatInfo.SendAddonMessage then
            C_ChatInfo.SendAddonMessage(PREFIX, msg, "WHISPER", whisperTarget)
            return true
        elseif SendAddonMessage then
            SendAddonMessage(PREFIX, msg, "WHISPER", whisperTarget)
            return true
        end
    end
    if RustcoreBroadcast and RustcoreBroadcast.SendAddonMessage then
        return RustcoreBroadcast.SendAddonMessage(PREFIX, msg)
    end
    return false
end

local function IsVerifiedFresh(name)
    local t = verified[name]
    return t and (GetTime() - t) < RESPONSE_TTL
end

local function IsSeenFresh(name)
    local t = seen[name]
    return t and (GetTime() - t) < RESPONSE_TTL
end

-- Returns the difficulty tier (1-5) the given player last reported, or nil
-- if we've never gotten a fresh response from them (i.e. they're not a
-- known Rustcore user right now). Not gated on self-found verified status -
-- only on the player actually running the addon. `name` may be unqualified
-- or realm-qualified.
function RustcoreSelfFoundComm.GetKnownDifficulty(name)
    name = NormalizeName(name)
    if not name or not IsSeenFresh(name) then return nil end
    return difficultyOf[name]
end

function RustcoreSelfFoundComm.IsKnownSelfFound(name)
    name = NormalizeName(name)
    return name and IsVerifiedFresh(name) or false
end

-- ── Sending ───────────────────────────────────────────────────────────────────

local function RequestStatus(fullName)
    local name = NormalizeName(fullName)
    if not name or name == NormalizeName(UnitName("player")) then return end
    local now = GetTime()
    if queried[name] and now - queried[name] < QUERY_TTL then return end
    queried[name] = now
    if not SendMessage(table.concat({ "Q", name }, DELIM), fullName) then
        queried[name] = nil
    end
end

local function HandleQuery(name, sender)
    name = NormalizeName(name)
    local myName = NormalizeName(UnitName("player"))
    if name ~= myName then return end
    local isVerified = Rustcore.GetSelfFoundIconState and Rustcore.GetSelfFoundIconState() == "verified"
    -- Plan section 46: peers are told the verified tier, never the raw
    -- setting, so a dragon another player sees always means something. 0 is
    -- outside the 1-5 range the receiver accepts, so an uncertified character
    -- simply shows no dragon on older clients as well as new ones.
    local V = RustcoreVerification
    local difficulty
    if V and V.Difficulty and V.Difficulty.GetBroadcastTier then
        difficulty = V.Difficulty.GetBroadcastTier() or 0
    else
        difficulty = (Rustcore.GetSetting and Rustcore.GetSetting("difficulty")) or 1
    end
    SendMessage(table.concat({ "R", myName, isVerified and "1" or "0", tostring(difficulty) }, DELIM), sender)
end

local function HandleResponse(name, verifiedFlag, difficulty, sender)
    name = NormalizeName(name)
    local senderName = NormalizeName(sender)
    if not name or not senderName or name ~= senderName then return end
    name = senderName
    seen[name] = GetTime()
    local reportedDifficulty = tonumber(difficulty)
    if reportedDifficulty and reportedDifficulty >= 1 and reportedDifficulty <= 5 then
        difficultyOf[name] = math.floor(reportedDifficulty)
    else
        difficultyOf[name] = nil
    end
    if verifiedFlag == "1" then
        verified[name] = GetTime()
    else
        verified[name] = nil
    end
    RustcoreSelfFoundComm.RefreshOverlays()
    if RustcoreDragon and RustcoreDragon.RefreshTargetFrame then
        RustcoreDragon.RefreshTargetFrame()
    end
    if RustcoreSelfFoundBuff and RustcoreSelfFoundBuff.RefreshTarget then
        RustcoreSelfFoundBuff.RefreshTarget()
    end
end

-- ── Portrait overlay ─────────────────────────────────────────────────────────

local function EnsureOverlay(frame)
    local existing = overlays[frame]
    if existing then return existing end
    if not frame.portrait then return nil end

    local tex = frame:CreateTexture(nil, "OVERLAY")
    tex:SetSize(ICON_SIZE, ICON_SIZE)
    tex:SetPoint("BOTTOMRIGHT", frame.portrait, "BOTTOMRIGHT", 2, -2)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    tex:Hide()
    overlays[frame] = tex
    return tex
end

local function UpdateFrameOverlay(frame, unit)
    if not frame then return end

    -- TargetFrame now gets the full synthetic Self Found aura from
    -- RustcoreSelfFoundBuff. Do not also draw the legacy portrait badge,
    -- which overlaps the level text and duplicates the same status.
    if frame == _G.TargetFrame then
        local tex = overlays[frame]
        if tex then tex:Hide() end
        return
    end

    if not UnitExists(unit) or not UnitIsPlayer(unit) then
        local tex = overlays[frame]
        if tex then tex:Hide() end
        return
    end

    local tex = EnsureOverlay(frame)
    if not tex then return end

    local name = NormalizeName(UnitName(unit))
    local isVerified
    if UnitIsUnit(unit, "player") then
        isVerified = Rustcore.GetSelfFoundIconState and Rustcore.GetSelfFoundIconState() == "verified"
    else
        isVerified = IsVerifiedFresh(name)
    end
    if isVerified then
        tex:SetTexture(Rustcore.GetSelfFoundIconTexture())
        tex:Show()
    else
        tex:Hide()
    end
end

function RustcoreSelfFoundComm.RefreshOverlays()
    for _, entry in ipairs(WATCHED_FRAMES) do
        local frame = _G[entry.frame]
        if frame then
            UpdateFrameOverlay(frame, entry.unit)
        end
    end
end

local function OnUnitChanged(unit)
    if UnitExists(unit) and UnitIsPlayer(unit) then
        RequestStatus(GetUnitFullName(unit))
    end
    RustcoreSelfFoundComm.RefreshOverlays()
end

-- Ask about whoever is under the cursor, without drawing anything.
--
-- Classic has no mouseover unit frame, so there is nothing to decorate here.
-- The point is timing: the dragon on the target portrait and the target's
-- Self-Found buff both read a cache that a whisper round trip fills, and until
-- now that trip only started on PLAYER_TARGET_CHANGED -- so the art arrived a
-- beat after the frame did, and every target visibly popped in. A player's
-- cursor is on someone before their click is, so the answer is usually already
-- home by the time the target frame draws.
--
-- Safe to fire freely: RequestStatus is de-duplicated by QUERY_TTL, so sweeping
-- the cursor across a crowded bank sends one whisper per player per 15 seconds
-- rather than one per frame.
local function OnMouseoverChanged()
    if UnitExists("mouseover") and UnitIsPlayer("mouseover") then
        -- Not filtered for the player themselves here; RequestStatus already
        -- refuses to query itself, and one owner for that rule is enough.
        RequestStatus(GetUnitFullName("mouseover"))
    end
end

local function RefreshWatchedUnits()
    for _, entry in ipairs(WATCHED_FRAMES) do
        if UnitExists(entry.unit) and UnitIsPlayer(entry.unit) and not UnitIsUnit(entry.unit, "player") then
            RequestStatus(GetUnitFullName(entry.unit))
        end
    end
    RustcoreSelfFoundComm.RefreshOverlays()
    if RustcoreDragon and RustcoreDragon.RefreshTargetFrame then
        RustcoreDragon.RefreshTargetFrame()
    end
    if RustcoreSelfFoundBuff and RustcoreSelfFoundBuff.RefreshTarget then
        RustcoreSelfFoundBuff.RefreshTarget()
    end
end

-- ── Events ────────────────────────────────────────────────────────────────────

local eventFrame = CreateFrame("Frame")
local sincePoll = 0
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(PREFIX)
        end
        prefixRegistered = true
        C_Timer.After(0.5, RefreshWatchedUnits)

    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(0.5, RefreshWatchedUnits)

    elseif event == "PLAYER_TARGET_CHANGED" then
        OnUnitChanged("target")

    elseif event == "PLAYER_FOCUS_CHANGED" then
        OnUnitChanged("focus")

    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        OnMouseoverChanged()

    elseif event == "GROUP_ROSTER_UPDATE" then
        RefreshWatchedUnits()

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, _, sender = ...
        if prefix ~= PREFIX then return end
        local kind, name, verifiedFlag, difficulty = strsplit(DELIM, msg)
        if kind == "Q" then
            HandleQuery(name, sender)
        elseif kind == "R" then
            HandleResponse(name, verifiedFlag, difficulty, sender)
        end
    end
end)

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    sincePoll = sincePoll + elapsed
    if sincePoll < POLL_INTERVAL then return end
    sincePoll = 0
    RefreshWatchedUnits()
end)
