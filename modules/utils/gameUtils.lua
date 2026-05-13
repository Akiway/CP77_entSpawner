local settings = require("modules/utils/settings")
local Cron = require("modules/utils/Cron")
local utils = require("modules/utils/utils")

local gameUtils = {}
local locKeyCache = {}

---@param rotationLike any
---@return EulerAngles?
local function toEulerAnglesSafe(rotationLike)
    if not rotationLike then
        return nil
    end

    if rotationLike.roll ~= nil and rotationLike.pitch ~= nil and rotationLike.yaw ~= nil then
        return EulerAngles.new(rotationLike.roll, rotationLike.pitch, rotationLike.yaw)
    end

    local okEuler, euler = pcall(function ()
        if type(rotationLike.ToEulerAngles) == "function" then
            return rotationLike:ToEulerAngles()
        end
        return nil
    end)
    if okEuler and euler then
        return euler
    end

    return nil
end

---@param euler EulerAngles?
---@return EulerAngles
local function cloneEulerOrDefault(euler)
    if euler then
        return EulerAngles.new(euler.roll or 0, euler.pitch or 0, euler.yaw or 0)
    end

    return EulerAngles.new(0, 0, 0)
end

---@param player any
---@param fallbackRotation any?
---@return EulerAngles
local function resolveTeleportRotation(player, fallbackRotation)
    local targetEuler = toEulerAnglesSafe(fallbackRotation)
    if targetEuler then
        return cloneEulerOrDefault(targetEuler)
    end

    if player then
        local playerEuler = toEulerAnglesSafe(player:GetWorldOrientation())
        if playerEuler then
            return cloneEulerOrDefault(playerEuler)
        end

        local yaw = (type(player.GetWorldYaw) == "function" and player:GetWorldYaw()) or 0
        return EulerAngles.new(0, 0, yaw)
    end

    return EulerAngles.new(0, 0, 0)
end

local function isLocKey(value)
    return type(value) == "string" and string.match(utils.trimString(value), "^LocKey#%d+$") ~= nil
end

local function isSecondaryKey(value)
    return type(value) == "string" and string.match(utils.trimString(value), "^SecondaryKey#%d+$") ~= nil
end

local function isRawLocalizationKey(value)
    if type(value) ~= "string" then
        return false
    end

    local normalized = utils.trimString(value)
    if string.match(normalized, "^#%d+$") then
        return true
    end

    -- Heuristic for hash-like numeric keys.
    return #normalized >= 6 and string.match(normalized, "^%d+$") ~= nil
end

local function isNamespacedLocalizationKey(value)
    if type(value) ~= "string" then
        return false
    end

    local normalized = utils.trimString(value)
    if normalized == "" or string.find(normalized, "%s") then
        return false
    end

    -- Namespaced secondary keys are usually tokenized with multiple separators,
    -- e.g. "Gameplay-Devices-DisplayNames-Button".
    local separatorCount = 0
    for _ in string.gmatch(normalized, "[-_%.:/]") do
        separatorCount = separatorCount + 1
    end

    if separatorCount < 2 then
        return false
    end

    return string.match(normalized, "^[A-Za-z][A-Za-z0-9%-%._:/]*$") ~= nil
end

local function isLocalizationKeyLike(value)
    return isLocKey(value) or isSecondaryKey(value) or isRawLocalizationKey(value) or isNamespacedLocalizationKey(value)
end

---Get player world position used for spawning logic.
---When editor mode is active, this returns a point in front of the camera
---at `settings.spawnDist` instead of the player's current feet position.
---@param editorActive boolean? Whether 3D editor mode is active.
---@return Vector4 position
function gameUtils.getPlayerPosition(editorActive)
    local pos = Game.GetPlayer():GetWorldPosition()

    if editorActive then
        local forward = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetAxisY()
        pos = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation()

        pos.z = pos.z + forward.z * settings.spawnDist
        pos.x = pos.x + forward.x * settings.spawnDist
        pos.y = pos.y + forward.y * settings.spawnDist
    end

    return pos
end

---Check whether the mod pause time dilation is currently active.
---@return boolean isPaused
function gameUtils.isPauseActive()
    local timeSystem = Game.GetTimeSystem()
    if not timeSystem then return false end

    return timeSystem:IsTimeDilationActive("console")
end

---Enable or disable pause time dilation managed by this mod.
---@param state boolean `true` to pause game time, `false` to resume.
function gameUtils.setPause(state)
    local timeSystem = Game.GetTimeSystem()
    if not timeSystem then return end

    if state then
        timeSystem:SetTimeDilation("console", 0.000000001)
    else
        timeSystem:UnsetTimeDilation("console")
    end
end

---Set the player scene tier in the player-state-machine blackboard.
---@param tier number Scene tier value (commonly `1` for normal, `4` for editor/freecam use).
function gameUtils.setSceneTier(tier)
    local blackboardDefs = Game.GetAllBlackboardDefs()
    local blackboardPSM = Game.GetBlackboardSystem():GetLocalInstanced(GetPlayer():GetEntityID(), blackboardDefs.PlayerStateMachine)
    blackboardPSM:SetInt(blackboardDefs.PlayerStateMachine.SceneTier, tier, true)
end


---Converts a quaternion-like or Euler-like rotation value to Euler angles when possible.
---@param rotationLike any
---@return EulerAngles?
function gameUtils.toEulerAnglesSafe(rotationLike)
    return toEulerAnglesSafe(rotationLike)
end

---Teleports the player with robust rotation conversion and optional Freefly coordination.
---By default, this temporarily pauses Freefly (if active), teleports, then restores Freefly.
---@param position Vector4
---@param rotationLike any?
---@param opts table? Optional flags. Supports `pauseFreefly` (boolean, default `true`).
function gameUtils.teleportPlayer(position, rotationLike, opts)
    opts = opts or {}

    local player = GetPlayer()
    if not player or not position then
        return false
    end

    local targetPosition = Vector4.new(position)
    local targetRotation = resolveTeleportRotation(player, rotationLike)

    local freefly = GetMod("freefly")
    local freeflyWasActive = false
    local shouldPauseFreefly = freefly and opts.pauseFreefly ~= false

    if shouldPauseFreefly and freefly.runtimeData.active then
        freeflyWasActive = true
        freefly.runtimeData.active = false
        freefly.logic.toggleFlight(freefly, freefly.runtimeData.active)
    end

    Game.GetTeleportationFacility():Teleport(player, targetPosition, targetRotation)

    if freeflyWasActive then
        Cron.NextTick(function ()
            if freefly and freefly.runtimeData and freefly.logic and type(freefly.logic.toggleFlight) == "function" then
                freefly.runtimeData.active = true
                freefly.logic.toggleFlight(freefly, freefly.runtimeData.active)
            end
        end)
    end
end

---Resolve a dynamic NPC/entity handle by entity ID.
---@param npcID entEntityID? Dynamic entity ID.
---@return Entity? npc Resolved entity handle, or `nil` when unavailable.
function gameUtils.getNPC(npcID)
    if not npcID then return end

    return Game.GetDynamicEntitySystem():GetEntity(npcID)
end

---Resolve a localization key string into localized text.
---Supports chained key indirections (for example `LocKey#...` -> `SecondaryKey#...` -> text).
---@param value any Candidate localization key (e.g. `LocKey#123`).
---@param cache table? Optional cache table to reuse between callers.
---@return string? localizedText Localized text, or `nil` when unresolved.
function gameUtils.resolveLocKey(value, cache)
    if type(value) ~= "string" then
        return nil
    end

    local key = utils.trimString(value)
    if key == "" or key == "None" or key == "0" then
        return nil
    end

    if not isLocalizationKeyLike(key) then
        return nil
    end

    local lookupCache = cache or locKeyCache
    local cached = lookupCache[key]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    local function analyzeCandidate(currentKey, candidate)
        if type(candidate) ~= "string" then
            return nil, nil
        end

        local normalized = utils.trimString(candidate)
        if normalized == "" or normalized == currentKey then
            return nil, nil
        end

        if isLocalizationKeyLike(normalized) then
            return nil, normalized
        end

        return candidate, nil
    end

    local currentKey = key
    local visited = {}

    for _ = 1, 8 do
        if visited[currentKey] then
            break
        end
        visited[currentKey] = true

        local nextKey = nil

        local okText, text = pcall(function ()
            return GetLocalizedText(currentKey)
        end)
        if okText then
            local localized, chained = analyzeCandidate(currentKey, text)
            if localized then
                lookupCache[key] = localized
                return localized
            end
            nextKey = chained or nextKey
        end

        local okByKey, byKeyText = pcall(function ()
            CName.add(currentKey)
            return GetLocalizedTextByKey(CName.new(currentKey))
        end)
        if okByKey then
            local localized, chained = analyzeCandidate(currentKey, byKeyText)
            if localized then
                lookupCache[key] = localized
                return localized
            end
            nextKey = chained or nextKey
        end

        local okLocKey, locKeyText = pcall(function ()
            CName.add(currentKey)
            return LocKeyToString(CName.new(currentKey))
        end)
        if okLocKey then
            local localized, chained = analyzeCandidate(currentKey, locKeyText)
            if localized then
                lookupCache[key] = localized
                return localized
            end
            nextKey = chained or nextKey
        end

        if not nextKey or visited[nextKey] then
            break
        end

        currentKey = nextKey
    end

    lookupCache[key] = false
    return nil
end

return gameUtils
