local utils = require("modules/utils/utils")
local Cron = require("modules/utils/Cron")
local settings = require("modules/utils/settings")
local editor = require("modules/utils/editor/editor")
local previewControls = require("modules/utils/previewControls")
local logger = require("modules/utils/logger")

---Lightweight preview for prefab (group) favorites.
---Spawns a transient, real-scale "ghost" of the whole prefab as a rotating turntable,
---centered in front of the camera and framed by an adaptive backdrop grid, then despawns
---it once the hover ends. Unlike the single-asset backdrop preview nothing is rescaled -
---instead the whole cluster is placed further away the larger it is, so it fits on screen.
---@class prefabPreview
---@field active boolean
---@field generation number
---@field records table[] List of { spawnable, relPos, relRot }
---@field backdrop spawnable?
---@field timer number?
---@field queue table[]?
---@field queueIndex number
---@field center Vector4?
---@field extent number
---@field startTime number
---@field spinAngle number Turntable angle the automatic spin last reached, in degrees
local prefabPreview = {
    active = false,
    generation = 0,
    records = {},
    backdrop = nil,
    timer = nil,
    queue = nil,
    queueIndex = 1,
    center = nil,
    extent = 1,
    startTime = 0,
    spinAngle = 0
}

local DEFAULT_MAX_ASSETS = 300
local SPAWN_CHUNK_SIZE = 20

-- Turntable / framing tuning
local SPIN_SPEED_DEG = 40            -- degrees per second the prefab rotates around its vertical axis
local DISTANCE_MARGIN = 1.6          -- multiplier on the fit distance ("a bit further away")
local MIN_DISTANCE = 1.5             -- never place the prefab closer than this
local MIN_EXTENT = 0.4               -- floor for the prefab bounding radius
local EXTENT_MARGIN_MULT = 1.25      -- element origins underestimate real size; pad the radius
local EXTENT_MARGIN_ADD = 0.4
local BACKDROP_BEHIND_FACTOR = 1.15  -- push the grid this many radii behind the prefab center
local BACKDROP_SCALE_FACTOR = 0.32   -- base_grid visual scale per radius
local MIN_BACKDROP_SCALE = 0.15
local BACKDROP_MESH = "base\\spawner\\base_grid.w2mesh"
local BACKDROP_TILT = { roll = 0, pitch = -90, yaw = 0 } -- stands the flat grid up to face the camera

---Returns the configured maximum number of assets a prefab may contain to still be previewable.
---A value of 0 disables prefab previews entirely.
---@return number
function prefabPreview.getMaxAssets()
    local configured = tonumber(settings.prefabPreviewMaxAssets)
    if not configured then
        return DEFAULT_MAX_ASSETS
    end

    return math.max(0, math.floor(configured))
end

---Recursively collects the serialized spawnable payloads of a prefab group.
---@param data table Serialized group (favorite.data)
---@return table[] entries List of spawnable save-data tables (data.spawnable)
local function collectSpawnableData(data)
    local entries = {}
    local stack = { data }

    while #stack > 0 do
        local current = table.remove(stack)

        for _, child in pairs(current.childs or {}) do
            if utils.isSerializedSpawnable(child) then
                if type(child.spawnable) == "table" and type(child.spawnable.modulePath) == "string" then
                    table.insert(entries, child.spawnable)
                end
            elseif utils.isSerializedGroup(child) then
                table.insert(stack, child)
            end
        end
    end

    return entries
end

---Computes the bounding-box center and bounding radius of the collected element origins.
---The radius is padded to approximate real asset sizes (only origins are known upfront).
---@param entries table[]
---@return Vector4 center
---@return number extent Bounding radius
local function computeCenterAndExtent(entries)
    local min = { x = math.huge, y = math.huge, z = math.huge }
    local max = { x = -math.huge, y = -math.huge, z = -math.huge }
    local found = false

    for _, entry in ipairs(entries) do
        local pos = entry.position
        if type(pos) == "table" then
            local x = pos.x or 0
            local y = pos.y or 0
            local z = pos.z or 0
            min.x = math.min(min.x, x)
            min.y = math.min(min.y, y)
            min.z = math.min(min.z, z)
            max.x = math.max(max.x, x)
            max.y = math.max(max.y, y)
            max.z = math.max(max.z, z)
            found = true
        end
    end

    if not found then
        return Vector4.new(0, 0, 0, 0), MIN_EXTENT
    end

    local center = Vector4.new((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2, 0)

    local radius = 0.5 * utils.distanceVector(min, max)
    radius = math.max(MIN_EXTENT, radius * EXTENT_MARGIN_MULT + EXTENT_MARGIN_ADD)

    return center, radius
end

-- Collision spawnables are skipped entirely in the preview (they add nothing visual).
local COLLISION_MODULE_PATHS = {
    ["collision/collider"] = true,
    ["collision/meshCollider"] = true
}

-- Spawnables previewed as a different, simpler class (e.g. dynamic meshes shown as static
-- meshes so they don't fall/simulate while being previewed).
local PREVIEW_MODULE_REMAP = {
    ["physics/dynamicMesh"] = "mesh/mesh",
    ["physics/destructibleMesh"] = "mesh/mesh"
}

---Resolves the spawnable module path used for the preview, or nil when it should be skipped.
---@param modulePath string
---@return string?
local function resolvePreviewModulePath(modulePath)
    if COLLISION_MODULE_PATHS[modulePath] then
        return nil
    end

    -- Account for old AMM import bug where entities got saved as the base entity class.
    if modulePath == "entity/entity" then
        modulePath = "entity/entityTemplate"
    end

    return PREVIEW_MODULE_REMAP[modulePath] or modulePath
end

---Whether the given favorite data can be previewed as a prefab.
---@param data table? Serialized favorite data
---@param assetCount number? Precomputed asset count, if available
---@return boolean
function prefabPreview.isPreviewable(data, assetCount)
    local max = prefabPreview.getMaxAssets()
    if max < 1 then
        return false
    end

    if not utils.isSerializedGroup(data) then
        return false
    end

    local count = assetCount
    if count == nil then
        count = #collectSpawnableData(data)
    end

    return count ~= nil and count > 0 and count <= max
end

---@return boolean
function prefabPreview.isActive()
    return prefabPreview.active or prefabPreview.timer ~= nil
end

---Returns the backdrop grid rotation for the given camera-facing rotation, or nil when unavailable.
---@param facing EulerAngles?
---@return EulerAngles?
local function getBackdropRotation(facing)
    if not facing then
        return nil
    end

    return utils.addEulerRelative(facing, BACKDROP_TILT)
end

---Computes the current camera-aligned turntable orientation for the whole prefab.
---Orienting in camera space keeps the prefab presented to the viewer at any camera pitch,
---while the time-based spin around the camera up axis reveals every side. Once the keyboard
---controls take over, the spin freezes and the manual orbit takes it from there instead.
---@return Quaternion?
local function computeBaseQuat()
    local cameraRotation = editor.getCameraRotation()
    if not cameraRotation then
        return nil
    end

    local camQuat = cameraRotation:ToQuat()
    local camUp = camQuat:Transform(Vector4.new(0, 0, 1, 0)):Normalize()

    local spinAngle
    if previewControls.isActive() then
        spinAngle = prefabPreview.spinAngle + previewControls.yaw
    else
        spinAngle = ((Cron.time - prefabPreview.startTime) * SPIN_SPEED_DEG) % 360
        prefabPreview.spinAngle = spinAngle
    end

    local quat = utils.multQuat(Quaternion.SetAxisAngle(camUp, math.rad(spinAngle)), camQuat)

    if previewControls.isActive() then
        local camRight = camQuat:Transform(Vector4.new(1, 0, 0, 0)):Normalize()
        quat = utils.multQuat(Quaternion.SetAxisAngle(camRight, math.rad(previewControls.pitch)), quat)
    end

    return quat
end

---Computes the screen-centered world anchor whose distance adapts to the prefab size.
---@return Vector4? anchor
local function computePreviewAnchor()
    local fov = editor.getCameraFOV() or 68
    local halfFov = math.rad(math.max(1, fov) / 2)
    local tanHalf = math.tan(halfFov)
    if tanHalf <= 0.0001 then
        tanHalf = 0.5
    end

    local distance = math.max(MIN_DISTANCE, (prefabPreview.extent / tanHalf) * DISTANCE_MARGIN / previewControls.zoom)
    local anchor = editor.getForward(distance)
    if not anchor or (anchor.x == 0 and anchor.y == 0 and anchor.z == 0) then
        return nil
    end

    return anchor
end

---Despawns all previewed instances and the backdrop, and clears preview state.
function prefabPreview.stop()
    prefabPreview.generation = prefabPreview.generation + 1

    if prefabPreview.timer then
        Cron.Halt(prefabPreview.timer)
        prefabPreview.timer = nil
    end

    for _, record in ipairs(prefabPreview.records) do
        local ok, err = pcall(function ()
            record.spawnable:despawn()
        end)
        if not ok then
            logger:error(string.format("[Prefab Preview] Failed to despawn preview instance: %s", tostring(err)))
        end
    end

    if prefabPreview.backdrop then
        pcall(function ()
            prefabPreview.backdrop:despawn()
        end)
        prefabPreview.backdrop = nil
    end

    prefabPreview.records = {}
    prefabPreview.queue = nil
    prefabPreview.queueIndex = 1
    prefabPreview.center = nil
    prefabPreview.spinAngle = 0
    prefabPreview.active = false
end

---Spawns a single collected spawnable entry and records its transform relative to the prefab center.
---@param spawnableData table
---@param anchor Vector4 Current preview anchor
---@param baseQuat Quaternion Current camera-aligned turntable orientation
---@param records table[] Output list the spawned record is appended to
local function spawnPreviewEntry(spawnableData, anchor, baseQuat, records)
    local modulePath = resolvePreviewModulePath(spawnableData.modulePath)
    if not modulePath then
        return
    end

    local okRequire, class = pcall(require, "modules/classes/spawn/" .. modulePath)
    if not okRequire or not class or not class.new then
        return
    end

    local elementPos = ToVector4(spawnableData.position or { x = 0, y = 0, z = 0, w = 0 })
    local elementRot = ToEulerAngles(spawnableData.rotation or { roll = 0, pitch = 0, yaw = 0 })

    local relPos = utils.subVector(elementPos, prefabPreview.center)
    local relRot = elementRot:ToQuat()
    local worldPos = utils.addVector(anchor, baseQuat:Transform(relPos))
    local worldRot = utils.multQuat(baseQuat, relRot):ToEulerAngles()

    local ok, instance = pcall(function ()
        local spawnable = class:new()
        spawnable:loadSpawnData(spawnableData, worldPos, worldRot)
        spawnable:spawn()
        return spawnable
    end)

    if ok and instance then
        table.insert(records, {
            spawnable = instance,
            relPos = relPos,
            relRot = relRot
        })
    else
        logger:error(string.format("[Prefab Preview] Failed to spawn preview for \"%s\": %s", tostring(modulePath), tostring(instance)))
    end
end

---Spawns the adaptive backdrop grid framing the prefab.
---@param anchor Vector4
local function spawnBackdrop(anchor)
    local scale = math.max(MIN_BACKDROP_SCALE, prefabPreview.extent * BACKDROP_SCALE_FACTOR)
    local rotation = getBackdropRotation(editor.getCameraFacingRotation()) or EulerAngles.new(0, 0, 0)

    local ok, backdrop = pcall(function ()
        local mesh = require("modules/classes/spawn/mesh/mesh"):new()
        mesh:loadSpawnData({ spawnData = BACKDROP_MESH, scale = { x = scale, y = scale, z = scale } }, anchor, rotation)
        mesh:spawn()
        return mesh
    end)

    if ok and backdrop then
        prefabPreview.backdrop = backdrop
    else
        logger:error(string.format("[Prefab Preview] Failed to spawn backdrop: %s", tostring(backdrop)))
    end
end

---Starts previewing a prefab favorite.
---Spawns are chunked across frames to avoid frame spikes for larger prefabs.
---@param data table Serialized favorite data (a group)
function prefabPreview.start(data)
    prefabPreview.stop()

    local entries = collectSpawnableData(data)
    if #entries == 0 or #entries > prefabPreview.getMaxAssets() then
        return
    end

    local center, extent = computeCenterAndExtent(entries)
    prefabPreview.center = center
    prefabPreview.extent = extent
    prefabPreview.startTime = Cron.time

    local anchor = computePreviewAnchor()
    if not anchor then
        return
    end

    prefabPreview.active = true
    prefabPreview.records = {}
    prefabPreview.queue = entries
    prefabPreview.queueIndex = 1

    spawnBackdrop(anchor)

    local generation = prefabPreview.generation

    prefabPreview.timer = Cron.OnUpdate(function (timer)
        if generation ~= prefabPreview.generation then
            timer:Halt()
            return
        end

        local spawnAnchor = computePreviewAnchor() or anchor
        local spawnBase = computeBaseQuat() or EulerAngles.new(0, 0, 0):ToQuat()

        local processed = 0
        while processed < SPAWN_CHUNK_SIZE and prefabPreview.queueIndex <= #prefabPreview.queue do
            local spawnableData = prefabPreview.queue[prefabPreview.queueIndex]
            prefabPreview.queueIndex = prefabPreview.queueIndex + 1
            processed = processed + 1

            spawnPreviewEntry(spawnableData, spawnAnchor, spawnBase, prefabPreview.records)
        end

        if prefabPreview.queueIndex > #prefabPreview.queue then
            timer:Halt()
            if generation == prefabPreview.generation then
                prefabPreview.timer = nil
                prefabPreview.queue = nil
            end
        end
    end)
end

---Per-frame maintenance: keeps the prefab centered in front of the camera, spins it around
---the camera up axis (so it stays presented to the viewer at any pitch), and re-frames the
---backdrop toward the viewer.
function prefabPreview.update()
    if not prefabPreview.active or not prefabPreview.center then
        return
    end

    local anchor = computePreviewAnchor()
    if not anchor then
        return
    end

    local baseQuat = computeBaseQuat()
    if not baseQuat then
        return
    end

    for _, record in ipairs(prefabPreview.records) do
        local spawnable = record.spawnable
        if spawnable:isSpawned() then
            spawnable.position = utils.addVector(anchor, baseQuat:Transform(record.relPos))
            spawnable.rotation = utils.multQuat(baseQuat, record.relRot):ToEulerAngles()
            spawnable:update()
        end
    end

    if prefabPreview.backdrop and prefabPreview.backdrop:isSpawned() then
        local rotation = getBackdropRotation(editor.getCameraFacingRotation())
        local forward = editor.getCameraForward()
        if rotation and forward then
            prefabPreview.backdrop.position = utils.addVector(anchor, utils.multVector(forward:Normalize(), prefabPreview.extent * BACKDROP_BEHIND_FACTOR))
            prefabPreview.backdrop.rotation = rotation
            prefabPreview.backdrop:update()
        end
    end
end

return prefabPreview
