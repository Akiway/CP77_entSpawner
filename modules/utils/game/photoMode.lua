---Photo mode target resolution.
---
---In photo mode the real player is hidden and a stand-in puppet is spawned from
---`Character.Player_Puppet_Photomode`. That puppet can be moved and posed independently of the
---player, so anything that wants to target "the player" on screen has to target the puppet instead.
---Photo mode NPCs are spawned the same way (`Character.<Name>_Puppet_Photomode`) and are tracked
---here as well, so they can be targeted individually.
---
---There is no engine getter for any of them (`gamePhotoModeSystem` only exposes `IsPhotoModeActive`
---and friends), so they are captured from `PhotoModePlayerEntityComponent:SetupInventory`, which
---assigns `fakePuppet` before doing anything else. Inside a vehicle no puppet is spawned at all,
---which is why the player accessors fall back to the player object.
local photoMode = {}

---@class photoModePuppet
---@field entity any Live puppet entity
---@field name string Character name, derived from the puppet's character record
---@field isPlayer boolean

local PLAYER_PUPPET_RECORD = "Character.Player_Puppet_Photomode"
local PLAYER_FALLBACK_NAME = "V"
local NPC_FALLBACK_NAME = "NPC"

local initialized = false
---@type {handle: any, id: any, key: string?, isPlayer: boolean, name: string?}[] Capture order
local captures = {}

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

---Record path of a puppet, e.g. "Character.Ozob_Puppet_Photomode".
---@param puppet any
---@return string?
local function getRecordPath(puppet)
    local okID, id = pcall(function ()
        return puppet:GetRecordID()
    end)
    if not okID or not id then
        return nil
    end

    local okValue, path = pcall(function ()
        return id.value
    end)
    if okValue and type(path) == "string" and path ~= "" then
        return path
    end

    local okDebug, debugPath = pcall(function ()
        -- The stub types this as a method, it is a static taking just the ID.
        ---@diagnostic disable-next-line: missing-parameter
        return TDBID.ToStringDEBUG(id)
    end)
    if okDebug and type(debugPath) == "string" and debugPath ~= "" then
        return debugPath
    end

    return nil
end

---Photo mode NPC records are clones of the player character record: no display name of their own,
---tagged `Player`, `voiceTag` "v". `GetTweakDBDisplayName` therefore answers "V" for most of them,
---so the record name is what actually identifies the character, and the display name is only a
---fallback for puppets whose record cannot be read.
---@param puppet any
---@return string?
local function getDisplayName(puppet)
    local path = getRecordPath(puppet)
    if path then
        local recordName = path:match("^Character%.(.+)_Puppet_Photomode$")
        if recordName then
            -- "AdamSmasher" reads as "Adam Smasher".
            return (recordName:gsub("(%l)(%u)", "%1 %2"))
        end
    end

    local ok, name = pcall(function ()
        return puppet:GetTweakDBDisplayName(true)
    end)

    if not ok or type(name) ~= "string" or name == "" then
        return nil
    end

    return name
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
---@return any? id, string? key
local function getEntityID(puppet)
    local ok, id = pcall(function ()
        return puppet:GetEntityID()
    end)
    if not ok or not id then
        return nil, nil
    end

    local okHash, hash = pcall(function ()
        return tostring(id.hash)
    end)

    return id, okHash and hash or nil
end

---A removed or swapped out puppet stays lockable through its handle, and can still answer a
---position, so attachment is what actually separates a live puppet from a leftover one.
---@param entity any
---@return boolean
local function isAlive(entity)
    if not entity then
        return false
    end

    local okAttached, attached = pcall(function ()
        return entity:IsAttached()
    end)
    if okAttached and attached == false then
        return false
    end

    return getWorldPosition(entity) ~= nil
end

---@param entry table
---@return any? entity
local function resolveEntry(entry)
    if entry.id then
        local ok, entity = pcall(Game.FindEntityByID, entry.id)
        if ok and entity and isAlive(entity) then
            return entity
        end

        -- The captured handle outlives the puppet, so it must not be used as a fallback here: once
        -- the entity lookup no longer returns a live puppet, the capture is gone for good.
        return nil
    end

    -- No entity ID was readable at capture time, the handle is all there is to go on.
    if isAlive(entry.handle) then
        return entry.handle
    end

    return nil
end

---Drops captures whose puppet is gone (NPC swapped out, photo mode closed, session ended).
---@return {entry: table, entity: any}[]
local function resolveCaptures()
    local live = {}
    local remaining = {}

    for _, entry in ipairs(captures) do
        local entity = resolveEntry(entry)
        if entity then
            table.insert(remaining, entry)
            table.insert(live, { entry = entry, entity = entity })
        end
    end

    captures = remaining

    return live
end

---@param puppet any
---@param isPlayer boolean
local function capture(puppet, isPlayer)
    local id, key = getEntityID(puppet)
    local entry = { handle = puppet, id = id, key = key, isPlayer = isPlayer, name = getDisplayName(puppet) }

    -- Photo mode re-runs the setup on the same puppet (outfit and weapon changes), and swapping the
    -- NPC reuses the slot, so a known puppet is refreshed rather than duplicated.
    for index, existing in ipairs(captures) do
        local sameEntity = key ~= nil and existing.key == key
        if sameEntity or (isPlayer and existing.isPlayer) then
            captures[index] = entry
            return
        end
    end

    table.insert(captures, entry)
end

---Drops every NPC capture, keeping V's puppet.
local function clearNPCs()
    local remaining = {}
    for _, entry in ipairs(captures) do
        if entry.isPlayer then
            table.insert(remaining, entry)
        end
    end

    captures = remaining
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

        -- Record unreadable: treat the first puppet of the session as V, it is always spawned before
        -- any NPC can be added.
        local isPlayer = resolved and matches or (not resolved and #captures == 0)

        capture(puppet, isPlayer)
    end)

    -- Photo mode drives a single NPC slot (`m_currentNpc`), and the selection is what triggers the
    -- spawn, so by the time this fires the NPCs on record are the outgoing ones. Whatever comes in
    -- registers itself through SetupInventory once its puppet is ready. Liveness alone is not enough
    -- here: a swapped out puppet can stay resolvable for a while.
    Observe('gameuiPhotoModeMenuController', 'OnSetSetSelectedNpc', function ()
        clearNPCs()
    end)

    Observe('gameuiPhotoModeMenuController', 'OnHide', function ()
        captures = {}
    end)
end

---Every live photo mode puppet, in spawn order, so V first.
---@return photoModePuppet[]
function photoMode.getPuppets()
    local puppets = {}
    local npcIndex = 0

    for _, resolved in ipairs(resolveCaptures()) do
        local entry = resolved.entry

        if not entry.isPlayer then
            npcIndex = npcIndex + 1
        end

        -- The display name is not always readable at capture time, so it is retried until it is.
        if not entry.name then
            entry.name = getDisplayName(resolved.entity)
        end

        local fallback = entry.isPlayer and PLAYER_FALLBACK_NAME or (NPC_FALLBACK_NAME .. " " .. npcIndex)

        table.insert(puppets, {
            entity = resolved.entity,
            name = entry.name or fallback,
            isPlayer = entry.isPlayer
        })
    end

    return puppets
end

---Live photo mode NPC puppets, in spawn order.
---@return photoModePuppet[]
function photoMode.getNPCs()
    local npcs = {}

    for _, puppet in ipairs(photoMode.getPuppets()) do
        if not puppet.isPlayer then
            table.insert(npcs, puppet)
        end
    end

    return npcs
end

---Live photo mode puppet for V, if there is one.
---@return any? puppet
function photoMode.getPuppet()
    for _, puppet in ipairs(photoMode.getPuppets()) do
        if puppet.isPlayer then
            return puppet.entity
        end
    end

    return nil
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

---World position of a puppet returned by `getPuppets` / `getNPCs`.
---@param puppet photoModePuppet?
---@return Vector4?
function photoMode.getPuppetPosition(puppet)
    return getWorldPosition(puppet and puppet.entity or nil)
end

return photoMode
