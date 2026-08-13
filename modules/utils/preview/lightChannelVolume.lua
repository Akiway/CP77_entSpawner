local lcHelper = require("modules/utils/ui/lightChannelHelper")
local logger = require("modules/utils/core/logger")
local utils = require("modules/utils/core/utils")
local Cron = require("modules/utils/vendor/Cron")

---Runtime preview for `worldLightChannelVolumeNode`.
---
---The node itself can not be placed at runtime, but the engine has an entity side equivalent of it:
---`entLightChannelComponent`, which carries the same `rendLightChannel` mask and a `GeometryShape`
---instead of the node's `AreaShapeOutline`. Attaching one of those to the placeholder entity of an
---area spawnable is what makes the volume actually affect lighting while editing, instead of only
---being drawn as an outline.
---
---The outline is a polygon extruded along +Z, so the shape built here is a closed prism: side quads
---plus a triangulated cap on each end, wound so every face normal points out of the volume.
local lightChannelVolume = {}

---Name of the component this module manages on a spawnable's entity.
lightChannelVolume.componentName = "lightChannelVolume"

---`AreaShapeOutline` only stores a byte for the marker count, and the exporter clamps to it, so the
---preview clamps to the same number to stay consistent with what actually ends up in the sector.
local maxMarkers = 255

---`entIVisualComponent` hides itself past `autoHideDistance`, measured from the component, and a
---volume that hides is a volume that stops restricting - the lights it was clipping pop back to
---unrestricted. The node has no such distance (sector streaming handles it), so the preview asks for
---one large enough to never trigger.
local volumeAutoHideDistance = 10000

---Volumes are static world data ingame, so the renderer has no reason to expect one to appear, move,
---or change channels while lights are already registered - which is what the editor does constantly.
---Re-registering the lights is what makes them notice, and it is debounced because outline drags
---change the volume every frame.
local lightRefreshDelay = 0.2

---Lights outside the volume can not be affected by it, so they are left alone. The margin covers the
---light reaching into the volume from outside it, on top of its own radius.
local lightRefreshMargin = 5

local supported = nil
local buildFailureReported = false
local assignFailureReported = false

-- Weak, so an area or a whole project that gets removed between the edit and the flush does not get
-- kept alive by a queue entry, and does not come back as an orphan entity either.
local pendingTimer = nil
local pendingRoots = setmetatable({}, { __mode = "kv" })
local pendingSelection = {}
local pendingBounds = nil

local pendingRebuildTimer = nil
local pendingRebuilds = setmetatable({}, { __mode = "k" })

---Whether this game/CET build exposes the types the preview needs.
---@return boolean
function lightChannelVolume.isSupported()
    if supported ~= nil then return supported end

    local ok, result = pcall(function ()
        return entLightChannelComponent.new() ~= nil and GeometryShape.new() ~= nil and GeometryShapeFace.new() ~= nil
    end)

    supported = ok and result == true

    if not supported then
        logger:warn("Light channel volumes can not be previewed: entLightChannelComponent / GeometryShape are unavailable.")
    end

    return supported
end

---@param points table[] Polygon points as `{x, y, z}`, in outline order.
---@return number area Signed XY area; positive when the polygon is counter clockwise seen from above.
local function getSignedArea(points)
    local area = 0

    for index = 1, #points do
        local nxt = points[index % #points + 1]
        area = area + (points[index].x * nxt.y - nxt.x * points[index].y)
    end

    return area * 0.5
end

local function cross2D(ax, ay, bx, by)
    return ax * by - ay * bx
end

---@return boolean
local function isPointInTriangle(point, a, b, c)
    local d1 = cross2D(b.x - a.x, b.y - a.y, point.x - a.x, point.y - a.y)
    local d2 = cross2D(c.x - b.x, c.y - b.y, point.x - b.x, point.y - b.y)
    local d3 = cross2D(a.x - c.x, a.y - c.y, point.x - c.x, point.y - c.y)

    local hasNegative = d1 < 0 or d2 < 0 or d3 < 0
    local hasPositive = d1 > 0 or d2 > 0 or d3 > 0

    return not (hasNegative and hasPositive)
end

---Ear clipping in the XY plane. Outlines are free form, so a triangle fan would fold the cap of any
---concave outline back over itself; this keeps the cap inside the polygon instead.
---@param points table[] Counter clockwise polygon points.
---@return table[] triangles Triples of 1-based indices into `points`.
local function triangulate(points)
    local triangles = {}
    local count = #points

    if count < 3 then return triangles end

    local remaining = {}
    for index = 1, count do
        remaining[index] = index
    end

    local guard = count * count

    while #remaining > 3 and guard > 0 do
        guard = guard - 1
        local clipped = false

        for slot = 1, #remaining do
            local previous = points[remaining[(slot - 2) % #remaining + 1]]
            local current = points[remaining[slot]]
            local nxt = points[remaining[slot % #remaining + 1]]

            -- Convex corner for a counter clockwise polygon
            if cross2D(current.x - previous.x, current.y - previous.y, nxt.x - current.x, nxt.y - current.y) > 0 then
                local isEar = true

                for _, index in ipairs(remaining) do
                    local candidate = points[index]

                    if candidate ~= previous and candidate ~= current and candidate ~= nxt and isPointInTriangle(candidate, previous, current, nxt) then
                        isEar = false
                        break
                    end
                end

                if isEar then
                    table.insert(triangles, { remaining[(slot - 2) % #remaining + 1], remaining[slot], remaining[slot % #remaining + 1] })
                    table.remove(remaining, slot)
                    clipped = true
                    break
                end
            end
        end

        if not clipped then break end
    end

    -- Whatever is left is either the final triangle, or a self intersecting outline that ear clipping
    -- can not resolve. Fanning the remainder keeps the cap closed, which matters more here than being
    -- exact, since such an outline has no well defined inside to begin with.
    for slot = 2, #remaining - 1 do
        table.insert(triangles, { remaining[1], remaining[slot], remaining[slot + 1] })
    end

    return triangles
end

local function appendTriangle(indices, a, b, c)
    table.insert(indices, a)
    table.insert(indices, b)
    table.insert(indices, c)
end

---@param faceIndexLists integer[][] Per face, its 0-based vertex indices wound counter clockwise seen from outside.
---@return table faces `GeometryShapeFace` instances.
local function buildFaces(faceIndexLists)
    local faces = {}

    for _, faceIndices in ipairs(faceIndexLists) do
        local face = GeometryShapeFace.new()
        face.indices = faceIndices

        table.insert(faces, face)
    end

    return faces
end

---Builds the closed prism for an outline.
---
---Vertices are component local, so they are stored relative to `origin` (the position of the entity
---the component gets attached to). Bottom/top vertices of marker `i` end up at `2i` and `2i + 1`.
---@param markers table[] World space outline points, in outline order.
---@param height number Extrusion height along +Z.
---@param origin Vector4 Entity position the shape is relative to.
---@return userdata? shape `GeometryShape` handle, or nil when the outline can not form a volume.
function lightChannelVolume.buildPrismShape(markers, height, origin)
    if not lightChannelVolume.isSupported() then return nil end
    if type(markers) ~= "table" or height == nil or height <= 0.001 then return nil end

    local points = {}

    for index, marker in ipairs(markers) do
        if index > maxMarkers then break end

        local position = ToVector4(marker)
        table.insert(points, {
            x = position.x - origin.x,
            y = position.y - origin.y,
            z = position.z - origin.z
        })
    end

    if #points < 3 then return nil end

    -- Markers are authored in whatever order they were placed in, but both the ear clipping above and
    -- the outward winding below assume counter clockwise seen from above.
    if getSignedArea(points) < 0 then
        local reversed = {}

        for index = #points, 1, -1 do
            table.insert(reversed, points[index])
        end

        points = reversed
    end

    local count = #points
    local vertices = {}
    local indices = {}
    local faceIndexLists = {}

    for _, point in ipairs(points) do
        table.insert(vertices, Vector3.new(point.x, point.y, point.z))
        table.insert(vertices, Vector3.new(point.x, point.y, point.z + height))
    end

    -- Walls
    for index = 1, count do
        local nxt = index % count + 1
        local bottom, top = (index - 1) * 2, (index - 1) * 2 + 1
        local nextBottom, nextTop = (nxt - 1) * 2, (nxt - 1) * 2 + 1

        appendTriangle(indices, bottom, nextBottom, nextTop)
        appendTriangle(indices, bottom, nextTop, top)
        table.insert(faceIndexLists, { bottom, nextBottom, nextTop, top })
    end

    -- Caps. The top keeps the polygon winding (normal up), the bottom is reversed (normal down).
    local bottomFace, topFace = {}, {}

    for index = 1, count do
        table.insert(bottomFace, (count - index) * 2)
        table.insert(topFace, (index - 1) * 2 + 1)
    end

    for _, triangle in ipairs(triangulate(points)) do
        local a, b, c = triangle[1], triangle[2], triangle[3]

        appendTriangle(indices, (a - 1) * 2, (c - 1) * 2, (b - 1) * 2)
        appendTriangle(indices, (a - 1) * 2 + 1, (b - 1) * 2 + 1, (c - 1) * 2 + 1)
    end

    table.insert(faceIndexLists, bottomFace)
    table.insert(faceIndexLists, topFace)

    local ok, shape = pcall(function ()
        local geometry = GeometryShape.new()
        geometry.vertices = vertices
        geometry.indices = indices
        geometry.faces = buildFaces(faceIndexLists)

        return geometry
    end)

    if not ok or not shape then
        if not buildFailureReported then
            buildFailureReported = true
            logger:warn("Failed to build a light channel volume shape: " .. tostring(shape))
        end

        return nil
    end

    return shape
end

---Both properties are assigned through conversions that fail quietly: handles go through an implicit
---cast that can end up a no-op, and bitfields silently become 0 for anything that is not a number. A
---component holding neither shape nor channels does nothing, which looks exactly like the volume not
---working at all, so the values are read back to turn that into something the log can show.
---@param component entIComponent
---@param mask number Channel mask that was just written.
local function verifyAssignment(component, mask)
    if assignFailureReported then return end

    local storedMask = lcHelper.readMask(component.channels)

    if component.shape ~= nil and storedMask == mask then return end

    assignFailureReported = true
    logger:warn(string.format(
        "Light channel volume did not stick: entLightChannelComponent.shape reads back as %s, channels as %s (wrote %s).",
        tostring(component.shape), tostring(storedMask), tostring(mask)
    ))
end

---@param entity entEntity
---@param shape userdata `GeometryShape` handle.
---@param selection boolean[] Channel states, in `style.lightChannelEnum` order.
---@param enabled boolean
---@return boolean success
local function attach(entity, shape, selection, enabled)
    local ok, err = pcall(function ()
        local mask = lcHelper.getMask(selection)
        local component = entLightChannelComponent.new()
        component.name = lightChannelVolume.componentName
        component.shape = shape
        component.channels = mask
        component.autoHideDistance = volumeAutoHideDistance
        component.isEnabled = enabled

        verifyAssignment(component, mask)
        entity:AddComponent(component)
    end)

    if not ok then
        logger:warn("Failed to attach a light channel volume component: " .. tostring(err))
    end

    return ok
end

---Creates or updates the light channel volume component of an entity.
---@param entity entEntity?
---@param shape userdata? `GeometryShape` handle. Nil disables the volume.
---@param selection boolean[] Channel states, in `style.lightChannelEnum` order.
---@param enabled boolean Whether the volume should affect lighting.
---@return boolean success
function lightChannelVolume.apply(entity, shape, selection, enabled)
    if not entity or not lightChannelVolume.isSupported() then return false end

    local active = enabled and shape ~= nil
    local component = entity:FindComponentByName(lightChannelVolume.componentName)

    if not component then
        if not shape then return false end

        return attach(entity, shape, selection, active)
    end

    local ok, err = pcall(function ()
        -- The render side caches shape and channels when the component registers, so it has to be
        -- taken down and brought back up for an edit to show, same as the preview meshes do.
        component:Toggle(false)

        if shape then
            local mask = lcHelper.getMask(selection)

            component.shape = shape
            component.channels = mask
            component.autoHideDistance = volumeAutoHideDistance
            verifyAssignment(component, mask)
        end

        component.isEnabled = active

        if active then
            component:Toggle(true)
        end
    end)

    if not ok then
        logger:warn("Failed to update a light channel volume component: " .. tostring(err))
    end

    return ok
end

---@param a boolean[]
---@param b boolean[]
---@return boolean
local function sharesChannel(a, b)
    for index, state in ipairs(a) do
        if state and b[index] then return true end
    end

    return false
end

---@param position Vector4
---@param bounds table {min, max} in world space.
---@param reach number Extra distance the light covers beyond its own position.
---@return boolean
local function reachesBounds(position, bounds, reach)
    return position.x >= bounds.min.x - reach and position.x <= bounds.max.x + reach
        and position.y >= bounds.min.y - reach and position.y <= bounds.max.y + reach
        and position.z >= bounds.min.z - reach and position.z <= bounds.max.z + reach
end

---@param spawnable table
---@param selection boolean[] Union of the channels of every volume that changed.
---@param bounds table Union of the bounds of every volume that changed.
---@return boolean
local function isAffectedLight(spawnable, selection, bounds)
    if type(spawnable.lightChannels) ~= "table" then return false end
    if not spawnable.isSpawned or not spawnable:isSpawned() then return false end
    if not sharesChannel(spawnable.lightChannels, selection) then return false end

    local entity = spawnable.getEntity and spawnable:getEntity() or nil
    -- Fog volumes and reflection probes carry a channel selection too, but only lights have a light
    -- component to re-register, and only they visibly react to a volume.
    if not entity or not entity:FindComponentByName("light") then return false end

    return reachesBounds(spawnable.position, bounds, (tonumber(spawnable.radius) or 0) + lightRefreshMargin)
end

local function flushLightRefresh()
    local roots, selection, bounds = pendingRoots, pendingSelection, pendingBounds

    pendingTimer = nil
    pendingRoots = setmetatable({}, { __mode = "kv" })
    pendingSelection, pendingBounds = {}, nil

    if not bounds then return end

    for root, object in pairs(roots) do
        local sUI = object.sUI

        if sUI then
            if sUI.ensureCache then
                sUI.ensureCache()
            end

            for _, entry in pairs(sUI.paths or {}) do
                local ref = entry.ref
                local spawnable = ref and utils.isA(ref, "spawnableElement") and ref.spawnable or nil

                if spawnable and ref.getRootParent and ref:getRootParent() == root and isAffectedLight(spawnable, selection, bounds) then
                    spawnable:respawn()
                end
            end
        end
    end
end

---Queues a re-registration of the lights a changed volume can reach.
---
---Everything queued between now and the flush is merged into one pass, so dragging an outline around
---does not respawn the same lights every frame.
---@param object element? Element of the area whose volume changed.
---@param selection boolean[] Channels of that volume.
---@param bounds table? World space `{min, max}` of the volume. Nothing is queued without it.
function lightChannelVolume.scheduleLightRefresh(object, selection, bounds)
    if not object or not bounds or not lightChannelVolume.isSupported() then return end

    local root = object.getRootParent and object:getRootParent() or nil
    if not root or not object.sUI then return end

    pendingRoots[root] = object

    for index, state in ipairs(selection) do
        pendingSelection[index] = pendingSelection[index] or state
    end

    if pendingBounds then
        pendingBounds.min.x = math.min(pendingBounds.min.x, bounds.min.x)
        pendingBounds.min.y = math.min(pendingBounds.min.y, bounds.min.y)
        pendingBounds.min.z = math.min(pendingBounds.min.z, bounds.min.z)
        pendingBounds.max.x = math.max(pendingBounds.max.x, bounds.max.x)
        pendingBounds.max.y = math.max(pendingBounds.max.y, bounds.max.y)
        pendingBounds.max.z = math.max(pendingBounds.max.z, bounds.max.z)
    else
        pendingBounds = utils.deepcopy(bounds)
    end

    if pendingTimer then
        Cron.Halt(pendingTimer)
    end

    pendingTimer = Cron.After(lightRefreshDelay, flushLightRefresh)
end

local function flushVolumeRebuilds()
    local rebuilds = pendingRebuilds

    pendingRebuildTimer = nil
    pendingRebuilds = setmetatable({}, { __mode = "k" })

    for spawnable in pairs(rebuilds) do
        if spawnable.isSpawned and spawnable:isSpawned() then
            -- Assembling builds the component from scratch, and the fresh `applyVolume` that runs with
            -- it queues the light refresh, which is why that is not done here: the lights have to
            -- re-register after the volume is back, not before.
            spawnable:respawn()
        end
    end
end

---Queues a rebuild of the volume of an area whose outline, channels, or transform settled.
---
---Updating the live component covers the change already, but only if swapping the shape and channels
---on a registered component is something the render side picks up - which is not a given for data it
---only ever sees baked into a sector. Respawning the entity a moment after the edit settles takes
---that out of the equation, while the in place update keeps the meantime roughly right.
---@param spawnable table Area spawnable to rebuild.
function lightChannelVolume.scheduleVolumeRebuild(spawnable)
    if not spawnable or not lightChannelVolume.isSupported() then return end

    pendingRebuilds[spawnable] = true

    if pendingRebuildTimer then
        Cron.Halt(pendingRebuildTimer)
    end

    pendingRebuildTimer = Cron.After(lightRefreshDelay, flushVolumeRebuilds)
end

return lightChannelVolume
