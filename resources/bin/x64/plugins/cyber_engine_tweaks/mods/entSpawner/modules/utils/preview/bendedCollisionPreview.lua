local builder = require("modules/utils/game/entityBuilder")
local logger = require("modules/utils/core/logger")

---Live collision of bended meshes in the editor: one host entity per mesh carrying convex colliders,
---cooked by the engine from their vertices. Colliders only take effect when added during assembly,
---so a changed shape respawns the host. It is removed as soon as the shape changes and rebuilt once
---the shape has been stable for `settleTime` with the mouse released, so editor tools that raycast
---(surface snap, drape) never hit the mesh's own outdated collision.
---@class bendedCollisionPreview
local preview = {}

local hostTemplate = "base\\spawner\\empty_entity.ent"
local settleTime = 0.3
local collidersPerComponent = 64

---@class bendedCollisionRecord
---@field owner table Spawnable providing `getCollisionShapes()`, `position` and `rotation`.
---@field signature string?
---@field changedAt number Clock of the last signature change.
---@field entityID entEntityID?
---@field built boolean The current signature has a host (or failed to get one).
---@field removedTick integer? Update tick of the last host removal.
---@field count integer Convex pieces on the current host.
---@field issue string? Why the owner has no collision.

local records = {}
local clock = 0
local tick = 0
local mouseDown = false
local waiting = {}

---@param owner table
---@return bendedCollisionRecord
local function getRecord(owner)
    local record = records[owner]
    if not record then
        record = { owner = owner, changedAt = 0, built = false, count = 0 }
        records[owner] = record
    end
    return record
end

---@param record bendedCollisionRecord
local function despawnHost(record)
    if record.entityID then
        Game.GetStaticEntitySystem():DespawnEntity(record.entityID)
        record.entityID = nil
        record.removedTick = tick
    end
    record.count = 0
end

---@return physicsFilterData
local function makeFilter()
    local filterData = physicsFilterData.new()
    filterData.preset = CName.new("World Static")

    local query = physicsQueryFilter.new()
    query.mask1 = 0
    query.mask2 = 70107400

    local sim = physicsSimulationFilter.new()
    sim.mask1 = 114696
    sim.mask2 = 23627

    filterData.queryFilter = query
    filterData.simulationFilter = sim
    return filterData
end

---@param entity entEntity
---@param shapes bendedCollisionShape[]
local function addColliders(entity, shapes)
    local colliders = {}
    local part = 0

    local function flush()
        if #colliders == 0 then return end
        part = part + 1
        local component = entColliderComponent.new()
        component.name = CName.new("bendedCollision" .. part)
        component.colliders = colliders
        component.filterData = makeFilter()
        entity:AddComponent(component)
        colliders = {}
    end

    for _, shape in ipairs(shapes) do
        local vertices = {}
        for i, point in ipairs(shape.points) do
            vertices[i] = Vector3.new(point.x, point.y, point.z)
        end

        local convex = physicsColliderConvex.new()
        convex.vertices = vertices
        convex.material = CName.new(shape.material)
        table.insert(colliders, convex)

        if #colliders >= collidersPerComponent then
            flush()
        end
    end
    flush()
end

---@param record bendedCollisionRecord
local function build(record)
    record.built = true
    despawnHost(record)

    local ok, shapes, issue = pcall(record.owner.getCollisionShapes, record.owner)
    if not ok then
        logger:warn("Bended collision failed: " .. tostring(shapes))
        record.issue = "Collision could not be built."
        return
    end
    record.issue = issue
    if not shapes or #shapes == 0 then return end

    local spec = StaticEntitySpec.new()
    spec.templatePath = hostTemplate
    spec.position = record.owner.position
    spec.orientation = record.owner.rotation:ToQuat()
    spec.attached = true

    local entityID = Game.GetStaticEntitySystem():SpawnEntity(spec)
    if not entityID or not entityID.hash or entityID.hash == 0 then
        record.issue = "The collision host could not be spawned."
        return
    end

    record.entityID = entityID
    record.count = #shapes

    builder.registerAssembleCallback(entityID, function (entity)
        if record.entityID ~= entityID then return end
        addColliders(entity, shapes)
    end)
end

---Declares the owner's current shape. A new signature removes the collision until it settles.
---@param owner table
---@param signature string
function preview.request(owner, signature)
    local record = getRecord(owner)
    if record.signature == signature then return end

    record.signature = signature
    record.changedAt = clock
    record.built = false
    record.issue = nil
    despawnHost(record)
end

---Removes the owner's collision now; it comes back with the next settled shape.
---@param owner table
function preview.suspend(owner)
    local record = records[owner]
    if not record then return end

    despawnHost(record)
    record.built = false
    record.changedAt = clock
end

---Suspends the owner's collision and runs `callback` once raycasts no longer hit it: a despawned
---host stays in the physics scene until the next frame. The callback runs from onDraw.
---@param owner table
---@param callback function
function preview.withoutCollision(owner, callback)
    preview.suspend(owner)

    local record = records[owner]
    if record and record.removedTick == tick then
        table.insert(waiting, { tick = tick, callback = callback })
    else
        callback()
    end
end

---@param owner table
function preview.release(owner)
    local record = records[owner]
    if not record then return end

    despawnHost(record)
    records[owner] = nil
end

---`active`, `pending`, `none` or `off`, with the piece count and the reason when there is none.
---@param owner table
---@return string status
---@return integer count
---@return string? issue
function preview.getStatus(owner)
    local record = records[owner]
    if not record or not record.signature then return "off", 0, nil end
    if not record.built then return "pending", 0, nil end
    if record.entityID then return "active", record.count, nil end
    return "none", 0, record.issue
end

---Reads the mouse (ImGui is not callable from onUpdate), released while CET is closed, and runs the
---`withoutCollision` callbacks that are due.
---@param overlayOpen boolean
function preview.onDraw(overlayOpen)
    mouseDown = overlayOpen and ImGui.IsMouseDown(ImGuiMouseButton.Left) or false

    if #waiting == 0 or waiting[1].tick == tick then return end
    local due = waiting
    waiting = {}
    for _, entry in ipairs(due) do
        if entry.tick == tick then
            table.insert(waiting, entry)
        else
            local ok, err = pcall(entry.callback)
            if not ok then
                logger:warn("Bended collision callback failed: " .. tostring(err))
            end
        end
    end
end

---@param dt number
function preview.update(dt)
    clock = clock + (dt or 0)
    tick = tick + 1

    for _, record in pairs(records) do
        if not record.built and record.signature and not mouseDown and clock - record.changedAt >= settleTime then
            build(record)
        end
    end
end

---Forgets every host, e.g. when the game session ends and the entities are gone.
function preview.reset()
    waiting = {}
    for _, record in pairs(records) do
        record.entityID = nil
        record.built = false
        record.count = 0
    end
end

return preview
