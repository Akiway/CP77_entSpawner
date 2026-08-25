local builder = require("modules/utils/game/entityBuilder")
local logger = require("modules/utils/core/logger")

local hostTemplate = "base\\spawner\\empty_entity.ent"

---A pool of entities that exist only to carry preview components.
---
---The game crashes once a single entity holds much more than ~320 components, so anything that
---draws an unbounded number of them spreads the load over as many hosts as it needs instead of
---piling them onto the owner entity. Hosts sit at the owner's own position and rotation, which
---is what lets every component keep using owner-local coordinates unchanged.
---@class previewHostPool
---@field componentsPerHost number
---@field onHostReady function
---@field hosts table Host records keyed by chunk: `{ entityID, entity }`.
---@field slots table Slot number keyed by component name, for name-addressed pools.
---@field nextSlot number Highest slot handed out so far.
---@field pending boolean A component was requested from a host that is still spawning.
local previewHostPool = {}
previewHostPool.__index = previewHostPool

---@param componentsPerHost number How many components each host may carry.
---@param onHostReady function Called once a host has assembled, to redraw with it available.
---@return previewHostPool
function previewHostPool.new(componentsPerHost, onHostReady)
    return setmetatable({
        componentsPerHost = math.max(1, math.floor(componentsPerHost)),
        onHostReady = onHostReady,
        hosts = {},
        slots = {},
        nextSlot = 0,
        pending = false
    }, previewHostPool)
end

---Host index carrying component `index`.
---@param index number
---@return number
function previewHostPool:getChunk(index)
    return math.floor((index - 1) / self.componentsPerHost) + 1
end

---Hosts needed to carry `count` components.
---@param count number
---@return number
function previewHostPool:getChunkCount(count)
    return math.ceil(count / self.componentsPerHost)
end

---Slot held by `name`, claiming the next free one the first time it is asked for. Lets callers
---with several independent component families pack them all into the same hosts.
---@param name string
---@return number
function previewHostPool:getSlot(name)
    if not self.slots[name] then
        self.nextSlot = self.nextSlot + 1
        self.slots[name] = self.nextSlot
    end

    return self.slots[name]
end

---Resolves a host record to a live entity. The entity system does not hand an entity back while
---it is still assembling, so the one the assemble callback captured is the fallback -- the same
---two-step lookup `spawnable:getEntity` uses.
---@param record table
---@return entEntity|nil
function previewHostPool:resolve(record)
    local live = Game.GetStaticEntitySystem():GetEntity(record.entityID)
    if live then return live end

    if record.entity then
        local ok, entityID = pcall(function ()
            return record.entity:GetEntityID()
        end)

        if ok and entityID and entityID.hash == record.entityID.hash then
            return record.entity
        end
    end

    return nil
end

---Fetches host `chunk`, spawning it when it does not exist yet.
---@param chunk number
---@param position Vector4 Owner position; hosts sit exactly on it.
---@param rotation EulerAngles? Owner rotation. Identity when omitted.
---@return entEntity|nil entity `nil` while the host is still spawning.
function previewHostPool:getHost(chunk, position, rotation)
    if self.hosts[chunk] then
        return self:resolve(self.hosts[chunk])
    end

    local spec = StaticEntitySpec.new()
    spec.templatePath = hostTemplate
    spec.position = position
    spec.orientation = (rotation or EulerAngles.new(0, 0, 0)):ToQuat()
    spec.attached = true

    local entityID = Game.GetStaticEntitySystem():SpawnEntity(spec)
    if not entityID or not entityID.hash or entityID.hash == 0 then
        logger:warn("Failed to spawn a preview host entity")
        return nil
    end

    local record = { entityID = entityID }
    self.hosts[chunk] = record

    -- Components can only be added once the host has assembled. The builder fires this once and
    -- then forgets it, so the entity it hands over has to be kept: nothing else can produce it
    -- until the host finishes attaching, and the redraw below needs it now.
    builder.registerAssembleCallback(entityID, function (entity)
        if self.hosts[chunk] ~= record then return end

        record.entity = entity
        self.onHostReady()
    end)

    return nil
end

---Host carrying component `index`, spawning it when needed. Marks the pool pending when that
---host is not usable yet, so the caller knows its component count is not final.
---@param index number
---@param position Vector4
---@param rotation EulerAngles?
---@return entEntity|nil
function previewHostPool:hostFor(index, position, rotation)
    local host = self:getHost(self:getChunk(index), position, rotation)

    if not host then
        self.pending = true
        return nil
    end

    return host
end

---As `hostFor`, for callers addressing components by name rather than by a dense index.
---@param name string
---@param position Vector4
---@param rotation EulerAngles?
---@return entEntity|nil
function previewHostPool:hostForName(name, position, rotation)
    return self:hostFor(self:getSlot(name), position, rotation)
end

---Existing component `name` at `index`, without spawning anything.
---@param index number
---@param name string
---@return entIComponent|nil
function previewHostPool:findComponent(index, name)
    local record = self.hosts[self:getChunk(index)]
    if not record then return nil end

    local host = self:resolve(record)
    if not host then return nil end

    return host:FindComponentByName(name)
end

---Existing component `name`, for name-addressed pools. Never claims a slot for an unknown name.
---@param name string
---@return entIComponent|nil
function previewHostPool:findComponentByName(name)
    if not self.slots[name] then return nil end

    return self:findComponent(self.slots[name], name)
end

---Spawns every host needed to carry `count` components, so a preview that has just grown
---converges in a single redraw instead of one redraw per host.
---@param count number
---@param position Vector4
---@param rotation EulerAngles?
function previewHostPool:ensure(count, position, rotation)
    for chunk = 1, self:getChunkCount(count) do
        self:getHost(chunk, position, rotation)
    end
end

---Despawns hosts past the first `chunks`, giving their components back.
---@param chunks number
function previewHostPool:trim(chunks)
    for chunk, record in pairs(self.hosts) do
        if chunk > chunks then
            Game.GetStaticEntitySystem():DespawnEntity(record.entityID)
            self.hosts[chunk] = nil
        end
    end

    -- Slots on a despawned host have to be forgotten, or the next request for that name would
    -- be handed a component that no longer exists.
    local kept = chunks * self.componentsPerHost
    for name, slot in pairs(self.slots) do
        if slot > kept then
            self.slots[name] = nil
        end
    end
    self.nextSlot = math.min(self.nextSlot, kept)
end

---Despawns every host, taking all their components with them.
function previewHostPool:despawn()
    for chunk, record in pairs(self.hosts) do
        Game.GetStaticEntitySystem():DespawnEntity(record.entityID)
        self.hosts[chunk] = nil
    end

    self.slots = {}
    self.nextSlot = 0
end

---Hosts carry components in owner-local coordinates, so they follow the owner when it moves.
---@param position Vector4
---@param rotation EulerAngles?
function previewHostPool:updateTransforms(position, rotation)
    for _, record in pairs(self.hosts) do
        local host = self:resolve(record)

        if host then
            local transform = host:GetWorldTransform()
            transform:SetPosition(position)
            transform:SetOrientationEuler(rotation or EulerAngles.new(0, 0, 0))
            host:SetWorldTransform(transform)
        end
    end
end

return previewHostPool
