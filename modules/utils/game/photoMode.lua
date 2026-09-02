---Photo mode target resolution.
---
---In photo mode the real player is hidden and a stand-in puppet is spawned from
---`Character.Player_Puppet_Photomode`. That puppet can be moved and posed independently of the
---player, so anything that wants to target "the player" on screen has to target the puppet instead.
---There is no engine getter for it (`gamePhotoModeSystem` only exposes `IsPhotoModeActive` and
---friends), so it is captured from `PhotoModePlayerEntityComponent:SetupInventory`, which assigns
---`fakePuppet` before doing anything else.
---
---Photo mode NPCs spawn the same component, so captures are filtered by record ID. Inside a vehicle
---no puppet is spawned at all, which is why every accessor falls back to the player.
local photoMode = {}

local PLAYER_PUPPET_RECORD = "Character.Player_Puppet_Photomode"

local initialized = false
---@type {handle: any, id: any}? Puppet captured for the current photo mode session
local captured = nil

---@param object any
---@return Vector4?
local function getWorldPosition(object)
    if not object then
        return nil
    end

    local ok, position = pcall(function ()
        return object:GetWorldPosition()
    end)

    return ok and position or nil
end

---@param puppet any
---@return boolean matches, boolean resolved `resolved` is false when the record could not be read
local function isPlayerPuppet(puppet)
    local ok, matches = pcall(function ()
        return puppet:GetRecordID() == TweakDBID.new(PLAYER_PUPPET_RECORD)
    end)

    if not ok then
        return false, false
    end

    return matches == true, true
end

---@param puppet any
local function capture(puppet)
    local id = nil
    local okID, entityID = pcall(function ()
        return puppet:GetEntityID()
    end)
    if okID then
        id = entityID
    end

    captured = { handle = puppet, id = id }
end

---Resolves the captured puppet, dropping it once it is gone (photo mode closed, session ended).
---@return any? puppet
local function resolveCaptured()
    if not captured then
        return nil
    end

    if captured.id then
        local ok, entity = pcall(Game.FindEntityByID, captured.id)
        if ok and entity then
            return entity
        end
    end

    -- No entity ID, or the puppet is not registered under it: the weak handle still answers as long
    -- as the puppet is alive, and safely fails once it is not.
    if getWorldPosition(captured.handle) then
        return captured.handle
    end

    captured = nil

    return nil
end

---Registers the photo mode observers. Safe to call more than once.
function photoMode.init()
    if initialized then return end
    initialized = true

    -- The CET stub types the ObserveAfter callback as taking no arguments, it does get the instance.
    ---@diagnostic disable-next-line: redundant-parameter
    ObserveAfter('PhotoModePlayerEntityComponent', 'SetupInventory', function (component)
        local ok, puppet = pcall(function ()
            return component.fakePuppet
        end)
        if not ok or not puppet then return end

        local matches, resolved = isPlayerPuppet(puppet)

        if resolved then
            -- Photo mode NPCs run the same component, they must not replace V as the target.
            if not matches then return end
        elseif captured ~= nil then
            -- Record unreadable: fall back to "first puppet of the session", V's is always spawned
            -- before any NPC can be added.
            return
        end

        capture(puppet)
    end)

    Observe('gameuiPhotoModeMenuController', 'OnHide', function ()
        captured = nil
    end)
end

---Live photo mode puppet for V, if there is one.
---@return any? puppet
function photoMode.getPuppet()
    return resolveCaptured()
end

---@return boolean
function photoMode.hasPuppet()
    return photoMode.getPuppet() ~= nil
end

---The object representing the player on screen: the photo mode puppet while it exists, the player
---otherwise.
---@return any? object
function photoMode.getTargetObject()
    return photoMode.getPuppet() or GetPlayer()
end

---World position of the object representing the player on screen.
---@return Vector4?
function photoMode.getTargetPosition()
    return getWorldPosition(photoMode.getTargetObject())
end

return photoMode
