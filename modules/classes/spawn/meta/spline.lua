local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local gameUtils = require("modules/utils/game/gameUtils")
local cache = require("modules/utils/game/cache")
local builder = require("modules/utils/game/entityBuilder")
local Cron = require("modules/utils/vendor/Cron")
local history = require("modules/utils/project/history")
local settings = require("modules/utils/core/settings")
local visualizer = require("modules/utils/preview/visualizer")
local logger = require("modules/utils/core/logger")

local minCurvePreviewSamples = 8
local maxCurvePreviewSamples = 24
-- Measured ceiling: the game crashes once a single entity carries more components than this.
-- bendedMesh's PATH_PREVIEW_MAX_SEGMENTS encodes the same limit. It is per entity, not global:
-- a project holds thousands of components across its spawnables without trouble.
local maxEntityPreviewComponents = 320
-- Which is why the curve preview does not live on the spline node entity at all. Its lines are
-- spread over dedicated host entities holding this many each, so the number of spline points is
-- bounded by what you are willing to render, not by the engine.
local curvePreviewComponentsPerHost = 256
local curvePreviewHostTemplate = "base\\spawner\\empty_entity.ent"
-- Safety valve only: past this the preview decimates rather than spawning hosts without end.
local curvePreviewComponentCeiling = 4096
-- Chord error, in meters, that segments are flattened to at the lowest and highest curve quality.
local minCurveFlattenTolerance = 0.002
local maxCurveFlattenTolerance = 0.2
local lengthIntegrationEpsilon = 0.00001
local lengthIntegrationMaxDepth = 18

---Class for worldSplineNode
---@class spline : visualized
---@field splinePath string
---@field points table
---@field reverse boolean
---@field looped boolean
---@field protected maxPropertyWidth number
---@field previewCharacter string
---@field splineFollowerSpeed number
---@field splineFollower boolean
---@field npcID entEntityID
---@field npcSpawning boolean
---@field cronID number
---@field rigs table
---@field apps table
local spline = setmetatable({}, { __index = visualized })

function spline:new()
	local o = visualized.new(self)

    o.spawnListType = "files"
    o.dataType = "Spline"
    o.spawnDataPath = "data/spawnables/meta/Spline/"
    o.modulePath = "meta/spline"
    o.node = "worldSplineNode"
    o.description = "Basic spline with auto-tangents, which can be referenced using its NodeRef."
    o.icon = IconGlyphs.VectorPolyline

    -- Marks any worldSplineNode-derived spawnable (basic spline, speed spline, ...).
    -- Consumed by hierarchy state icons and spline marker preview refresh.
    o.isSplineNode = true

    o.previewed = true
    o.previewColor = "violet"
    o.splinePath = ""

    o.reverse = false
    o.looped = false
    o.points = {}
    o.pointDefs = {}

    o.previewCharacter = settings.defaultAISpotNPC or ""
    o.splineFollowerSpeed = settings.defaultAISpotSpeed or 1.0
    o.splineFollower = false

    o.maxPropertyWidth = nil
    o.npcID = nil
    o.npcSpawning = false
    o.cronID = nil
    o.rigs = {}
    o.apps = {}
    o.splineMoveType = "Walk"
    o.splineReachDistance = 0.85
    o._currentPointIndex = nil
    o.curvePreviewSamples = math.floor(math.max(minCurvePreviewSamples, math.min(maxCurvePreviewSamples, settings.defaultSplineCurveQuality or 12)))
    o._curvePreviewComponentCount = 0

    setmetatable(o, { __index = self })
   	return o
end

function spline:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    self.previewCharacter = utils.stripNonASCII(self.previewCharacter)
    self.curvePreviewSamples = math.floor(math.max(minCurvePreviewSamples, math.min(maxCurvePreviewSamples, self.curvePreviewSamples or 12)))

    self.pointDefs = {}
    if data.pointDefs and #data.pointDefs > 0 then
        for _, pointDef in ipairs(data.pointDefs) do
            local tangentIn = pointDef.tangentIn or { x = 0, y = 0, z = 0 }
            local tangentOut = pointDef.tangentOut or { x = 0, y = 0, z = 0 }
            table.insert(self.pointDefs, {
                position = pointDef.position or { x = 0, y = 0, z = 0 },
                tangentIn = tangentIn,
                tangentOut = tangentOut,
                automaticTangents = pointDef.automaticTangents == nil and true or pointDef.automaticTangents
            })
        end
    elseif data.points and #data.points > 0 then
        for _, point in ipairs(data.points) do
            table.insert(self.pointDefs, {
                position = point,
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            })
        end
    end

    if self.splinePath and self.splinePath ~= "" and self.splinePath ~= "None" then
        Cron.After(0.5, function()
            self:refreshLinkedMarkerTangents(self.looped)
            self:respawn()
        end)
    end
end

function spline:getVisualizerSize()
    return { x = 0.25, y = 0.25, z = 0.25 }
end

function spline:getNPC()
    return gameUtils.getNPC(self.npcID)
end

function spline:getInterpolatedPosition(t)
    if #self.points == 0 then
        self:loadSplinePoints()
    end

    -- t ranges from 0 to 1
    if #self.points == 0 then
        return self.position
    end

    if #self.points == 1 then
        return self.points[1]
    end

    local points = {}
    for i = 1, #self.points do
        table.insert(points, self.points[i])
    end

    -- Calculate which segment t falls into
    local segmentCount = #points - 1
    local scaledT = t * segmentCount
    local segmentIndex = math.floor(scaledT) + 1
    local localT = scaledT - math.floor(scaledT)

    if self.looped and segmentIndex > segmentCount then
        segmentIndex = 1
        localT = 0
    end

    if segmentIndex > segmentCount then
        return points[#points]
    end

    local p0 = points[segmentIndex]
    local p1 = points[segmentIndex + 1]

    -- Linear interpolation between two points
    local interpolated = Vector4.new(
        p0.x + (p1.x - p0.x) * localT,
        p0.y + (p1.y - p0.y) * localT,
        p0.z + (p1.z - p0.z) * localT,
        0
    )

    return interpolated
end

function spline:getOrderedPoints()
    if #self.points == 0 then
        self:loadSplinePoints()
    end

    local ordered = {}
    for i = 1, #self.points do
        table.insert(ordered, self.points[i])
    end

    return ordered
end

function spline:hasCurveTangents(pointDefs)
    local function lengthSq(tab)
        return tab.x * tab.x + tab.y * tab.y + tab.z * tab.z
    end

    if not pointDefs or #pointDefs < 2 then
        return false
    end

    for i = 1, #pointDefs - 1 do
        local current = pointDefs[i]
        local nxt = pointDefs[i + 1]
        if current and nxt and (lengthSq(current.tangentOut) > 0.00000001 or lengthSq(nxt.tangentIn) > 0.00000001) then
            return true
        end
    end

    if self.looped then
        local last = pointDefs[#pointDefs]
        local first = pointDefs[1]
        if last and first and (lengthSq(last.tangentOut) > 0.00000001 or lengthSq(first.tangentIn) > 0.00000001) then
            return true
        end
    end

    return false
end

function spline:getFollowerPathPoints()
    local pointDefs = self:getFollowerPreviewSplineMarkerDefs()
    local function applyPreviewDirection(points)
        if not self.reverse then
            return points
        end

        local reversed = {}
        for i = #points, 1, -1 do
            table.insert(reversed, points[i])
        end

        return reversed
    end

    if #pointDefs == 0 then
        self:loadSplinePoints()
        local points = {}
        for i = 1, #self.points do
            table.insert(points, self.points[i])
        end
        return applyPreviewDirection(points)
    end

    if not self:hasCurveTangents(pointDefs) then
        local points = {}
        for _, pointDef in ipairs(pointDefs) do
            table.insert(points, utils.fromVector(pointDef.position))
        end
        return applyPreviewDirection(points)
    end

    local pathPoints = {}
    local samples = math.max(minCurvePreviewSamples, math.min(maxCurvePreviewSamples, self.curvePreviewSamples or 12))

    local function sampleSegment(defA, defB)
        local p0 = defA.position
        local p1 = defB.position
        local c0 = utils.addVector(p0, Vector4.new(defA.tangentOut.x, defA.tangentOut.y, defA.tangentOut.z, 0))
        local c1 = utils.addVector(p1, Vector4.new(defB.tangentIn.x, defB.tangentIn.y, defB.tangentIn.z, 0))

        if #pathPoints == 0 then
            table.insert(pathPoints, utils.fromVector(p0))
        end

        for i = 1, samples do
            local t = i / samples
            table.insert(pathPoints, utils.fromVector(self:getBezierPoint(p0, c0, c1, p1, t)))
        end
    end

    for i = 1, #pointDefs - 1 do
        sampleSegment(pointDefs[i], pointDefs[i + 1])
    end

    if self.looped and #pointDefs > 1 then
        sampleSegment(pointDefs[#pointDefs], pointDefs[1])
    end

    return applyPreviewDirection(pathPoints)
end

function spline:getTotalLength()
    local pointDefs = self:getFollowerPreviewSplineMarkerDefs()

    local function sumLinear(points, looped)
        if #points < 2 then
            return 0
        end

        local total = 0
        for i = 1, #points - 1 do
            total = total + utils.distanceVector(points[i], points[i + 1])
        end

        if looped and #points > 1 then
            total = total + utils.distanceVector(points[#points], points[1])
        end

        return total
    end

    if #pointDefs == 0 then
        self:loadSplinePoints()
        local points = {}
        for i = 1, #self.points do
            table.insert(points, self.points[i])
        end

        return sumLinear(points, self.looped)
    end

    local total = 0
    local function bezierSegmentLength(defA, defB)
        local p0 = defA.position
        local p1 = defB.position
        local c0 = utils.addVector(p0, Vector4.new(defA.tangentOut.x, defA.tangentOut.y, defA.tangentOut.z, 0))
        local c1 = utils.addVector(p1, Vector4.new(defB.tangentIn.x, defB.tangentIn.y, defB.tangentIn.z, 0))

        return self:getBezierArcLength(p0, c0, c1, p1, lengthIntegrationEpsilon, lengthIntegrationMaxDepth)
    end

    for i = 1, #pointDefs - 1 do
        total = total + bezierSegmentLength(pointDefs[i], pointDefs[i + 1])
    end

    if self.looped and #pointDefs > 1 then
        total = total + bezierSegmentLength(pointDefs[#pointDefs], pointDefs[1])
    end

    return total
end

function spline:refreshLinkedMarkerTangents(refreshEdgeTangents)
    local paths = self:loadSplinePaths()
    if utils.indexValue(paths, self.splinePath) == -1 then return end

    local splineGroup = self.object.sUI.getElementByPath(self.splinePath)
    if not splineGroup then return end

    local markers = {}
    for _, child in ipairs(splineGroup.childs) do
        if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
            table.insert(markers, child.spawnable)
        end
    end

    for _, marker in ipairs(markers) do
        -- Always refresh marker connector transforms when spline topology changes
        -- (e.g. looped on/off), otherwise the last->first straight segment can stay stale.
        marker:updateTransform(splineGroup)
    end

    if refreshEdgeTangents and #markers > 1 then
        local first = markers[1]
        local last = markers[#markers]

        if first and first.symmetricTangents then
            first:applyAutoTangents(splineGroup)
            first:updateTransform(splineGroup)
        end

        if last and last.symmetricTangents then
            last:applyAutoTangents(splineGroup)
            last:updateTransform(splineGroup)
        end
    end
end

function spline:buildMoveCommand(targetPos)
    local dest = NewObject("WorldPosition")
    dest:SetVector4(dest, ToVector4(targetPos))

    local positionSpec = NewObject("AIPositionSpec")
    positionSpec:SetWorldPosition(positionSpec, dest)

    local cmd = NewObject("handle:AIMoveToCommand")
    cmd.movementTarget = positionSpec
    cmd.rotateEntityTowardsFacingTarget = false
    cmd.ignoreNavigation = false
    cmd.desiredDistanceFromTarget = self.splineReachDistance
    cmd.movementType = self.splineMoveType
    cmd.finishWhenDestinationReached = true

    return cmd
end

function spline:sendMoveCommand(npc, targetPos)
    if not npc then return false end
    local aiController = npc:GetAIControllerComponent()
    if not aiController then return false end

    aiController:SendCommand(self:buildMoveCommand(targetPos))
    return true
end

function spline:loadSplinePoints()
    self.points = {}
    local paths = self:loadSplinePaths()

    if utils.indexValue(paths, self.splinePath) ~= -1 then
        local splineGroup = self.object.sUI.getElementByPath(self.splinePath)
        if splineGroup then
            for _, child in pairs(splineGroup.childs) do
                if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
                    table.insert(self.points, utils.fromVector(child.spawnable.position))
                end
            end
        end
    end
end

function spline:collectSplineMarkerDefs()
    local defs = {}
    if not self.splinePath or self.splinePath == "" or self.splinePath == "None" then
        return defs
    end

    local splineGroup = self.object.sUI.getElementByPath(self.splinePath)
    if not splineGroup then
        return defs
    end

    for _, child in ipairs(splineGroup.childs) do
        if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
            local marker = child.spawnable
            local saved = marker.spawnData or {}
            local tangentIn = marker.tangentIn or saved.tangentIn or { x = 0, y = 0, z = 0 }
            local tangentOut = marker.tangentOut or saved.tangentOut or { x = 0, y = 0, z = 0 }

            table.insert(defs, {
                position = marker.position,
                tangentIn = {
                    x = tonumber(tangentIn.x) or 0,
                    y = tonumber(tangentIn.y) or 0,
                    z = tonumber(tangentIn.z) or 0
                },
                tangentOut = {
                    x = tonumber(tangentOut.x) or 0,
                    y = tonumber(tangentOut.y) or 0,
                    z = tonumber(tangentOut.z) or 0
                },
                automaticTangents = marker.automaticTangents == nil and true or marker.automaticTangents
            })
        end
    end

    return defs
end

function spline:getSplineMarkerDefs()
    return self:collectSplineMarkerDefs()
end

function spline:getFollowerPreviewSplineMarkerDefs()
    local defs = self:collectSplineMarkerDefs()
    if #defs == 0 then
        return defs
    end

    return self:buildPreviewSplineMarkerDefs(defs)
end

function spline:buildPreviewSplineMarkerDefs(defs)
    if #defs == 0 then
        return defs
    end

    local function toV4(tab)
        return Vector4.new(tab.x, tab.y, tab.z, 0)
    end

    local function toTable(v)
        return { x = v.x, y = v.y, z = v.z }
    end

    local previewDefs = utils.deepcopy(defs)

    for i, def in ipairs(previewDefs) do
        if def.automaticTangents then
            local prevIndex = i - 1
            local nextIndex = i + 1
            local prev = previewDefs[prevIndex]
            local nxt = previewDefs[nextIndex]

            if self.looped then
                if not prev then prev = previewDefs[#previewDefs] end
                if not nxt then nxt = previewDefs[1] end
            end

            local currentPos = toV4(def.position)
            local tangent = Vector4.new(0, 0, 0, 0)

            if prev and nxt then
                tangent = utils.subVector(toV4(nxt.position), toV4(prev.position))
                tangent = Vector4.new(tangent.x / 6, tangent.y / 6, tangent.z / 6, 0)
            elseif nxt then
                tangent = utils.subVector(toV4(nxt.position), currentPos)
                tangent = Vector4.new(tangent.x / 3, tangent.y / 3, tangent.z / 3, 0)
            elseif prev then
                tangent = utils.subVector(currentPos, toV4(prev.position))
                tangent = Vector4.new(tangent.x / 3, tangent.y / 3, tangent.z / 3, 0)
            end

            def.tangentIn = toTable(Vector4.new(-tangent.x, -tangent.y, -tangent.z, 0))
            def.tangentOut = toTable(tangent)
        end
    end

    return previewDefs
end

function spline:getPreviewSplineMarkerDefs()
    local defs = self:getSplineMarkerDefs()
    return self:buildPreviewSplineMarkerDefs(defs)
end

function spline:getBezierPoint(p0, c0, c1, p1, t)
    local u = 1 - t
    local uu = u * u
    local uuu = uu * u
    local tt = t * t
    local ttt = tt * t

    return Vector4.new(
        uuu * p0.x + 3 * uu * t * c0.x + 3 * u * tt * c1.x + ttt * p1.x,
        uuu * p0.y + 3 * uu * t * c0.y + 3 * u * tt * c1.y + ttt * p1.y,
        uuu * p0.z + 3 * uu * t * c0.z + 3 * u * tt * c1.z + ttt * p1.z,
        0
    )
end

function spline:getBezierSpeed(p0, c0, c1, p1, t)
    local u = 1 - t
    local uu = u * u
    local tt = t * t

    local aX = c0.x - p0.x
    local aY = c0.y - p0.y
    local aZ = c0.z - p0.z
    local bX = c1.x - c0.x
    local bY = c1.y - c0.y
    local bZ = c1.z - c0.z
    local cX = p1.x - c1.x
    local cY = p1.y - c1.y
    local cZ = p1.z - c1.z

    local dX = 3 * (uu * aX + 2 * u * t * bX + tt * cX)
    local dY = 3 * (uu * aY + 2 * u * t * bY + tt * cY)
    local dZ = 3 * (uu * aZ + 2 * u * t * bZ + tt * cZ)

    return math.sqrt(dX * dX + dY * dY + dZ * dZ)
end

function spline:getBezierArcLength(p0, c0, c1, p1, epsilon, maxDepth)
    epsilon = epsilon or lengthIntegrationEpsilon
    maxDepth = maxDepth or lengthIntegrationMaxDepth

    local function simpson(fa, fm, fb, h)
        return h * (fa + 4 * fm + fb) / 6
    end

    local function integrateRecursive(a, b, fa, fm, fb, whole, eps, depth)
        local m = (a + b) / 2
        local lm = (a + m) / 2
        local rm = (m + b) / 2

        local flm = self:getBezierSpeed(p0, c0, c1, p1, lm)
        local frm = self:getBezierSpeed(p0, c0, c1, p1, rm)

        local left = simpson(fa, flm, fm, m - a)
        local right = simpson(fm, frm, fb, b - m)
        local delta = left + right - whole

        if depth <= 0 or math.abs(delta) <= 15 * eps then
            -- Richardson extrapolation term improves final precision.
            return left + right + delta / 15
        end

        return integrateRecursive(a, m, fa, flm, fm, left, eps / 2, depth - 1)
            + integrateRecursive(m, b, fm, frm, fb, right, eps / 2, depth - 1)
    end

    local a = 0
    local b = 1
    local m = 0.5
    local fa = self:getBezierSpeed(p0, c0, c1, p1, a)
    local fm = self:getBezierSpeed(p0, c0, c1, p1, m)
    local fb = self:getBezierSpeed(p0, c0, c1, p1, b)
    local whole = simpson(fa, fm, fb, b - a)

    return integrateRecursive(a, b, fa, fm, fb, whole, epsilon, maxDepth)
end

---Distance from `point` to the chord between `p0` and `p1`.
---@param point Vector4
---@param p0 Vector4
---@param p1 Vector4
---@return number
local function chordDistance(point, p0, p1)
    local dx, dy, dz = p1.x - p0.x, p1.y - p0.y, p1.z - p0.z
    local px, py, pz = point.x - p0.x, point.y - p0.y, point.z - p0.z
    local lengthSq = dx * dx + dy * dy + dz * dz

    if lengthSq > 0.000001 then
        local t = math.max(0, math.min(1, (px * dx + py * dy + pz * dz) / lengthSq))
        px, py, pz = px - dx * t, py - dy * t, pz - dz * t
    end

    return math.sqrt(px * px + py * py + pz * pz)
end

---Chord error, in meters, that segments get flattened to at the given curve quality.
---@param quality number
---@return number
local function getFlattenTolerance(quality)
    local t = (quality - minCurvePreviewSamples) / math.max(1, maxCurvePreviewSamples - minCurvePreviewSamples)

    return maxCurveFlattenTolerance * (minCurveFlattenTolerance / maxCurveFlattenTolerance) ^ t
end

---Which host holds line `index`, and the component name it goes under.
---@param index number Global 1-based line index.
---@return number chunk, string name
local function getCurvePreviewAddress(index)
    return math.floor((index - 1) / curvePreviewComponentsPerHost) + 1, "curvePreview" .. tostring(index)
end

---Whether `entity` can take one more preview component without crossing the ceiling.
---@param entity entEntity
---@return boolean
function spline:canAddPreviewComponent(entity)
    local count = 0

    for _ in pairs(entity:GetComponents()) do
        count = count + 1
    end

    return count < maxEntityPreviewComponents
end

---Host records the curve preview lines live on, keyed by chunk: `{ entityID, entity }`.
---@return table
function spline:getCurvePreviewHosts()
    self._curvePreviewHosts = self._curvePreviewHosts or {}

    return self._curvePreviewHosts
end

---Resolves a host record to a live entity. The entity system does not hand the entity back
---while it is still assembling, so the one the assemble callback captured is the fallback --
---the same two-step `spawnable:getEntity` uses.
---@param record table
---@return entEntity|nil
function spline:resolveCurvePreviewHost(record)
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

---Fetches host `chunk`, spawning it when it does not exist yet. Hosts sit at the spline's own
---origin with no rotation, which is what lets every line keep using spline-local coordinates.
---@param chunk number 1-based host index.
---@return entEntity|nil entity `nil` while the host is still spawning; the assemble callback redraws.
function spline:getCurvePreviewHost(chunk)
    local hosts = self:getCurvePreviewHosts()

    if hosts[chunk] then
        return self:resolveCurvePreviewHost(hosts[chunk])
    end

    local spec = StaticEntitySpec.new()
    spec.templatePath = curvePreviewHostTemplate
    spec.position = self.position
    spec.orientation = EulerAngles.new(0, 0, 0):ToQuat()
    spec.attached = true

    local entityID = Game.GetStaticEntitySystem():SpawnEntity(spec)
    if not entityID or not entityID.hash or entityID.hash == 0 then
        logger:warn("Failed to spawn a curve preview host for a Spline")
        return nil
    end

    local record = { entityID = entityID }
    hosts[chunk] = record

    -- Components can only be added once the host has assembled. The builder fires this once and
    -- then forgets it, so the entity it passes has to be kept: nothing else can hand it over
    -- until the host finishes attaching, and the redraw below needs it now.
    builder.registerAssembleCallback(entityID, function (entity)
        if self:getCurvePreviewHosts()[chunk] ~= record then return end

        record.entity = entity
        self:updateCurvePreview()
    end)

    return nil
end

---Spawns every host the next draw is going to need, so a spline that just outgrew its
---current hosts converges in a single redraw instead of one redraw per host.
---@param count number Number of hosts required.
function spline:ensureCurvePreviewHosts(count)
    for chunk = 1, count do
        self:getCurvePreviewHost(chunk)
    end
end

---Despawns every host, taking all curve preview lines with them.
function spline:despawnCurvePreviewHosts()
    local hosts = self:getCurvePreviewHosts()

    for chunk, record in pairs(hosts) do
        Game.GetStaticEntitySystem():DespawnEntity(record.entityID)
        hosts[chunk] = nil
    end

    self._curvePreviewComponentCount = 0
end

---Despawns hosts the preview has outgrown, so shortening a spline gives the components back.
---@param usedChunks number Number of hosts the current preview actually fills.
function spline:trimCurvePreviewHosts(usedChunks)
    local hosts = self:getCurvePreviewHosts()

    for chunk, record in pairs(hosts) do
        if chunk > usedChunks then
            Game.GetStaticEntitySystem():DespawnEntity(record.entityID)
            hosts[chunk] = nil
        end
    end

    self._curvePreviewComponentCount = math.min(self._curvePreviewComponentCount, usedChunks * curvePreviewComponentsPerHost)
end

---Hosts carry lines in spline-local coordinates, so they have to follow the node when it moves.
function spline:updateCurvePreviewHostTransforms()
    for _, record in pairs(self:getCurvePreviewHosts()) do
        local host = self:resolveCurvePreviewHost(record)

        if host then
            local transform = host:GetWorldTransform()
            transform:SetPosition(self.position)
            transform:SetOrientationEuler(EulerAngles.new(0, 0, 0))
            host:SetWorldTransform(transform)
        end
    end
end

---Existing line component for `index`, without spawning a host for it.
---@param index number
---@return entMeshComponent|nil
function spline:findCurvePreviewComponent(index)
    local chunk, name = getCurvePreviewAddress(index)
    local record = self:getCurvePreviewHosts()[chunk]
    if not record then return nil end

    local host = self:resolveCurvePreviewHost(record)
    if not host then return nil end

    return host:FindComponentByName(name)
end

---@param index number
---@return entMeshComponent|nil
function spline:getCurvePreviewComponent(index)
    local chunk, name = getCurvePreviewAddress(index)
    local host = self:getCurvePreviewHost(chunk)

    if not host then
        self._curvePreviewHostPending = true
        return nil
    end

    local component = host:FindComponentByName(name)
    if component then
        return component
    end

    component = entMeshComponent.new()
    component.name = name
    component.mesh = ResRef.FromString("base\\spawner\\cube_aligned.mesh")
    component.meshAppearance = self.previewColor or "violet"
    component.visualScale = Vector3.new(0.005, 0.005, 0.005)
    component.isEnabled = self.previewed
    visualizer.bindToPlacedParent(host, component)
    host:AddComponent(component)

    return component
end

---Splits the preview markers into bezier segments, including the closing one when looped.
---@param pointDefs table
---@return table segments List of { defA, defB } pairs.
function spline:getCurveSegments(pointDefs)
    local segments = {}
    if #pointDefs < 2 then return segments end

    for i = 1, #pointDefs - 1 do
        table.insert(segments, { pointDefs[i], pointDefs[i + 1] })
    end

    if self.looped then
        table.insert(segments, { pointDefs[#pointDefs], pointDefs[1] })
    end

    return segments
end

---Control points of the bezier running between two marker defs.
---@return Vector4 p0, Vector4 c0, Vector4 c1, Vector4 p1
function spline:getSegmentControlPoints(defA, defB)
    local p0 = defA.position
    local p1 = defB.position
    local c0 = utils.addVector(p0, Vector4.new(defA.tangentOut.x, defA.tangentOut.y, defA.tangentOut.z, 0))
    local c1 = utils.addVector(p1, Vector4.new(defB.tangentIn.x, defB.tangentIn.y, defB.tangentIn.z, 0))

    return p0, c0, c1, p1
end

---How many samples a segment needs to stay within `tolerance` of the real curve. The control
---points bound how far a bezier leaves its chord and uniform subdivision cuts that error by
---roughly n², so a straight run costs a single line and only real curvature costs more.
---@param tolerance number Chord error budget in meters.
---@param maxSamples number Upper bound, from the curve quality setting.
---@return number
function spline:getSegmentSampleCount(p0, c0, c1, p1, tolerance, maxSamples)
    local deviation = math.max(chordDistance(c0, p0, p1), chordDistance(c1, p0, p1))
    if deviation <= tolerance then return 1 end

    return math.max(1, math.min(maxSamples, math.ceil(math.sqrt(0.75 * deviation / tolerance))))
end

---Sample count for every segment, and the number of lines they add up to.
---@param segments table
---@param quality number
---@param tolerance number
---@return table samplesPerSegment, number total
function spline:getCurvePreviewPlan(segments, quality, tolerance)
    local samplesPerSegment = {}
    local total = 0

    for i, segment in ipairs(segments) do
        local p0, c0, c1, p1 = self:getSegmentControlPoints(segment[1], segment[2])
        local samples = self:getSegmentSampleCount(p0, c0, c1, p1, tolerance, quality)

        samplesPerSegment[i] = samples
        total = total + samples
    end

    return samplesPerSegment, total
end

function spline:renderCurveSegmentLine(startPos, endPos, index)
    local diff = utils.subVector(endPos, startPos)
    local length = diff:Length()
    if length <= 0.0001 then
        return false
    end

    local line = self:getCurvePreviewComponent(index)
    if not line then return false end

    local localStart = utils.subVector(startPos, self.position)
    local yaw = diff:ToRotation().yaw + 90
    local roll = diff:ToRotation().pitch

    line.visualScale = Vector3.new(math.max(0.0001, length / 2), 0.01, 0.01)
    line:SetLocalOrientation(EulerAngles.new(roll, 0, yaw):ToQuat())
    line:SetLocalPosition(Vector4.new(localStart.x, localStart.y, localStart.z, 0))
    line:Toggle(self.previewed)
    line:RefreshAppearance()

    return true
end

function spline:drawBezierPreviewSegment(defA, defB, samples, used, budget)
    local p0, c0, c1, p1 = self:getSegmentControlPoints(defA, defB)
    local prev = p0

    for i = 1, samples do
        if used >= budget then break end

        local current = self:getBezierPoint(p0, c0, c1, p1, i / samples)
        local nextUsed = used + 1
        if self:renderCurveSegmentLine(prev, current, nextUsed) then
            used = nextUsed
        end
        prev = current
    end

    return used
end

---Draws the whole spline with `budget` evenly spaced samples instead of a fixed number per
---segment. Only reached by splines with more segments than the safety ceiling: every sample
---still sits on the real curve, the preview just gets coarser rather than stopping partway.
---@param segments table
---@param budget number
---@return number used
function spline:drawDecimatedCurvePreview(segments, budget)
    local used = 0
    local prev = nil

    for step = 0, budget do
        local position = (step / budget) * #segments
        local index = math.min(#segments, math.floor(position) + 1)
        local p0, c0, c1, p1 = self:getSegmentControlPoints(segments[index][1], segments[index][2])
        local current = self:getBezierPoint(p0, c0, c1, p1, position - (index - 1))

        if prev and used < budget then
            local nextUsed = used + 1
            if self:renderCurveSegmentLine(prev, current, nextUsed) then
                used = nextUsed
            end
        end

        prev = current
    end

    return used
end

function spline:updateCurvePreview()
    if not self:getEntity() then return end

    local used = 0
    self._curvePreviewHostPending = false

    -- A hidden preview draws nothing: no hosts get spawned for it, and any it already has are
    -- left alone so toggling the preview back on is instant rather than a respawn.
    if self.previewed then
        local segments = self:getCurveSegments(self:getPreviewSplineMarkerDefs())
        local quality = math.floor(math.max(minCurvePreviewSamples, math.min(maxCurvePreviewSamples, self.curvePreviewSamples or 12)))
        local tolerance = getFlattenTolerance(quality)

        if #segments > curvePreviewComponentCeiling then
            self:ensureCurvePreviewHosts(math.ceil(curvePreviewComponentCeiling / curvePreviewComponentsPerHost))
            used = self:drawDecimatedCurvePreview(segments, curvePreviewComponentCeiling)
        else
            local samplesPerSegment, total = self:getCurvePreviewPlan(segments, quality, tolerance)
            self:ensureCurvePreviewHosts(math.ceil(math.min(total, curvePreviewComponentCeiling) / curvePreviewComponentsPerHost))

            for i, segment in ipairs(segments) do
                used = self:drawBezierPreviewSegment(segment[1], segment[2], samplesPerSegment[i], used, curvePreviewComponentCeiling)
            end
        end
    end

    -- While a host is still spawning the line count is not final: leave the components and the
    -- hosts as they are, and let that host's assemble callback redraw with the real total.
    if self._curvePreviewHostPending then return end

    for i = used + 1, self._curvePreviewComponentCount do
        local line = self:findCurvePreviewComponent(i)
        if line then
            line:Toggle(false)
        end
    end

    self._curvePreviewComponentCount = math.max(self._curvePreviewComponentCount, used)

    if self.previewed then
        self:trimCurvePreviewHosts(math.max(1, math.ceil(used / curvePreviewComponentsPerHost)))
    end
end

function spline:onNPCSpawned(npc)
    -- Ensure we have a valid character record, fallback to saved default if current is empty
    if not self.previewCharacter or not self.previewCharacter:match("^Character.") then
        self.previewCharacter = settings.defaultAISpotNPC or ""
        if not self.previewCharacter or not self.previewCharacter:match("^Character.") then
            return
        end
    end

    local points = self:getFollowerPathPoints()
    if #points == 0 then return end

    npc:SetIndividualTimeDilation("", self.splineFollowerSpeed)

    if #points == 1 then
        Game.GetTeleportationFacility():Teleport(npc, ToVector4(points[1]), EulerAngles.new(0, 0, 0))
        return
    end

    -- Start at the first marker, then move marker-to-marker using AI navigation.
    Game.GetTeleportationFacility():Teleport(npc, ToVector4(points[1]), EulerAngles.new(0, 0, 0))
    self._currentPointIndex = 2
    self:sendMoveCommand(npc, points[self._currentPointIndex])
    self._activeTargetPos = utils.fromVector(ToVector4(points[self._currentPointIndex]))

    self.cronID = Cron.Every(0.1, function()
        if not self.npcID or not self:isSpawned() or not self.splineFollower then return end

        local follower = self:getNPC()
        if not follower then return end

        local ordered = self:getFollowerPathPoints()
        if #ordered < 2 then return end

        if not self._currentPointIndex then
            self._currentPointIndex = 2
        end

        if self._currentPointIndex > #ordered then
            if self.looped then
                self._currentPointIndex = 1
            else
                self._currentPointIndex = #ordered
                return
            end
        end

        local target = ordered[self._currentPointIndex]
        if not target then return end

        if not self._activeTargetPos or utils.distanceVector(self._activeTargetPos, target) > 0.01 then
            self:sendMoveCommand(follower, target)
            self._activeTargetPos = utils.fromVector(ToVector4(target))
        end

        if utils.distanceVector(follower:GetWorldPosition(), target) <= self.splineReachDistance then
            self._currentPointIndex = self._currentPointIndex + 1

            if self._currentPointIndex > #ordered then
                if self.looped then
                    self._currentPointIndex = 1
                else
                    self._currentPointIndex = #ordered
                    return
                end
            end

            self:sendMoveCommand(follower, ordered[self._currentPointIndex])
            self._activeTargetPos = utils.fromVector(ToVector4(ordered[self._currentPointIndex]))
        end
    end)
end

function spline:onAssemble(entity)
    visualized.onAssemble(self, entity)
    self:updateCurvePreview()

    if not self.splineFollower then return end

    local points = self:getFollowerPathPoints()
    local spawnPos = self.position
    if #points > 0 then
        spawnPos = ToVector4(points[1])
    end

    local spec = DynamicEntitySpec.new()
    spec.recordID = self.previewCharacter
    spec.position = spawnPos
    spec.orientation = EulerAngles.new(0, 0, 0):ToQuat()
    spec.alwaysSpawned = true
    self.npcID = Game.GetDynamicEntitySystem():CreateEntity(spec)
    self.npcSpawning = true

    builder.registerAttachCallback(self.npcID, function(entity)
        self:onNPCSpawned(entity)
    end)

    local appCacheKey = self.previewCharacter .. "_apps"
    cache.tryGet(appCacheKey)
    .notFound(function(task)
        local finished = false
        local function complete(apps)
            if finished then return end
            finished = true

            cache.addValue(appCacheKey, apps or {})
            task:taskCompleted()
        end

        local templateFlat = TweakDB:GetFlat(self.previewCharacter .. ".entityTemplatePath")
        local templateHash = templateFlat and templateFlat.hash
        if not templateHash then
            complete({})
            return
        end

        local templateResRef = ResRef.FromHash(templateHash)
        local depot = Game.GetResourceDepot()
        local exists = false
        if depot then
            pcall(function()
                exists = depot:ResourceExists(templateResRef)
            end)
        end
        if not exists then
            complete({})
            return
        end

        local ok = pcall(function()
            builder.registerLoadResource(templateResRef, function(resource)
                local apps = {}
                if resource and resource.appearances then
                    for _, appearance in ipairs(resource.appearances) do
                        if appearance and appearance.name and appearance.name.value then
                            table.insert(apps, appearance.name.value)
                        end
                    end
                end

                complete(apps)
            end)
        end)
        if not ok then
            complete({})
        end
    end)
    .found(function()
        self.apps = cache.getValue(appCacheKey) or {}
    end)
end

function spline:despawn()
    visualized.despawn(self)

    self:despawnCurvePreviewHosts()

    if self.cronID then
        Cron.Halt(self.cronID)
        self.cronID = nil
    end

    if not self.npcID then return end

    Game.GetDynamicEntitySystem():DeleteEntity(self.npcID)
    self.npcID = nil
    self.npcSpawning = false
    self._currentPointIndex = nil
    self._activeTargetPos = nil
end

function spline:spawn()
    self.rotation = EulerAngles.new(0, 0, 0)
    visualized.spawn(self)
end

function spline:update()
    self.rotation = EulerAngles.new(0, 0, 0)
    visualized.update(self)
    self:updateCurvePreviewHostTransforms()
    self:updateCurvePreview()
end

function spline:getTransformUIConfig()
    return {
        showRotation = false,
        showScale = false
    }
end

function spline:setPreview(state)
    visualized.setPreview(self, state)
    self:updateCurvePreview()
end

function spline:save()
    local data = visualized.save(self)

    local pointDefs = self:getSplineMarkerDefs()
    if #pointDefs == 0 and self.pointDefs and #self.pointDefs > 0 then
        pointDefs = utils.deepcopy(self.pointDefs)
    end
    if #pointDefs == 0 and self.points and #self.points > 0 then
        for _, point in ipairs(self.points) do
            table.insert(pointDefs, {
                position = point,
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            })
        end
    end

    local points = {}
    local savedPointDefs = {}
    for _, pointDef in ipairs(pointDefs) do
        local position = utils.fromVector(pointDef.position)
        local tangentIn = pointDef.tangentIn or { x = 0, y = 0, z = 0 }
        local tangentOut = pointDef.tangentOut or { x = 0, y = 0, z = 0 }

        table.insert(points, position)
        table.insert(savedPointDefs, {
            position = position,
            tangentIn = {
                x = tonumber(tangentIn.x) or 0,
                y = tonumber(tangentIn.y) or 0,
                z = tonumber(tangentIn.z) or 0
            },
            tangentOut = {
                x = tonumber(tangentOut.x) or 0,
                y = tonumber(tangentOut.y) or 0,
                z = tonumber(tangentOut.z) or 0
            },
            automaticTangents = pointDef.automaticTangents == nil and true or pointDef.automaticTangents
        })
    end

    data.splinePath = self.splinePath
    data.points = points
    data.pointDefs = savedPointDefs
    data.reverse = self.reverse
    data.looped = self.looped
    data.previewCharacter = self.previewCharacter
    data.splineFollowerSpeed = self.splineFollowerSpeed
    data.splineFollower = self.splineFollower
    data.splineMoveType = self.splineMoveType
    data.curvePreviewSamples = self.curvePreviewSamples

    return data
end

function spline:loadSplinePaths()
    local paths = {}
    local ownRoot = self.object:getRootParent()

    for _, container in pairs(self.object.sUI.containerPaths) do
        if container.ref:getRootParent() == ownRoot then
            local nMarkers = 0
            for _, child in pairs(container.ref.childs) do
                if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
                    nMarkers = nMarkers + 1
                end

                if nMarkers == 2 then
                    table.insert(paths, container.path)
                    break
                end
            end
        end
    end

    return paths
end

function spline:draw()
    visualized.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize position", "Curve Quality", "Spline Path", "Spline Length", "Reverse", "Looped", "Preview NPC", "Preview NPC Record", "Movement Type", "Movement Speed" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    local paths = self:loadSplinePaths()
    table.insert(paths, 1, "None")

    local index = math.max(1, utils.indexValue(paths, self.splinePath))

    style.mutedText("Spline Path")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local idx, changed = style.trackedCombo(self.object, "##splinePath", index - 1, paths, 225)
    if changed then
        self.splinePath = paths[idx + 1]
        if self.object and self.object.sUI and self.object.sUI.bumpWireframeEpoch then
            self.object.sUI.bumpWireframeEpoch()
        end
        self:respawn()
    end
    style.tooltip("Path to the group containing the spline points.\nMust be contained within the same root group as this spline.")

    style.mutedText("Spline Length")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    ImGui.Text(string.format("%.2fm", self:getTotalLength()))
    style.tooltip("Total spline length based on current curve sampling.")

    style.mutedText("Reverse")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local changed
    self.reverse, changed = style.trackedCheckbox(self.object, "##reverse", self.reverse)
    if changed then
        self:updateCurvePreview()
        if self.splineFollower then
            self:respawn()
        end
    end

    style.mutedText("Looped")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.looped, changed = style.trackedCheckbox(self.object, "##looped", self.looped)
    if changed then
        self:refreshLinkedMarkerTangents(true)
        self:respawn()
    end

    if ImGui.TreeNodeEx("Previewing Options", ImGuiTreeNodeFlags.SpanFullWidth) then
        local previewPropertyWidth = self.maxPropertyWidth + ImGui.GetTreeNodeToLabelSpacing()

        self:drawPreviewCheckbox("Preview Spline", previewPropertyWidth)

        style.mutedText("Curve Quality")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        local finished
        self.curvePreviewSamples, changed, finished = style.trackedDragInt(self.object, "##curvePreviewSamples", self.curvePreviewSamples, minCurvePreviewSamples, maxCurvePreviewSamples, 60)
        style.tooltip("Preview accuracy. Samples are spent where the curve actually bends, so\nstraight runs stay cheap no matter how many points the spline has.")
        if changed then
            self:updateCurvePreview()
        end
        if finished then
            self:respawn()
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        ImGui.PushID("saveCurveQuality")
        if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
            settings.defaultSplineCurveQuality = math.floor(math.max(minCurvePreviewSamples, math.min(maxCurvePreviewSamples, self.curvePreviewSamples or 12)))
            settings.save()
        end
        ImGui.PopID()
        style.tooltip("Save this curve quality as the default for Spline previews.")
        style.pushButtonNoBG(false)

        style.mutedText("Preview NPC")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.splineFollower, changed = style.trackedCheckbox(self.object, "##splineFollower", self.splineFollower)
        if changed then
            self:respawn()
        end

        style.mutedText("Preview NPC Record")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.previewCharacter, _, finished = style.trackedTextField(self.object, "##previewCharacter", self.previewCharacter, "Character.", 200)
        if finished then
            self:respawn()
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
            settings.defaultAISpotNPC = self.previewCharacter
            settings.save()
        end
        style.tooltip("Save this character as the default for Spline previews.")
        style.pushButtonNoBG(false)

        if self.splineFollower then
            local npc = self:getNPC()
            local isNPC = self.previewCharacter:match("^Character.")

            if isNPC then
                local movementTypes = { "Walk", "Sprint" }
                local moveTypeIndex = math.max(1, utils.indexValue(movementTypes, self.splineMoveType))
                style.mutedText("Movement Type")
                ImGui.SameLine()
                ImGui.SetCursorPosX(previewPropertyWidth)
                local moveIdx
                moveIdx, changed = style.trackedCombo(self.object, "##splineMoveType", moveTypeIndex - 1, movementTypes, 120)
                if changed then
                    self.splineMoveType = movementTypes[moveIdx + 1]
                    self:respawn()
                end

                style.mutedText("Movement Speed")
                ImGui.SameLine()
                ImGui.SetCursorPosX(previewPropertyWidth)
                self.splineFollowerSpeed, changed, _ = style.trackedDragFloat(self.object, "##splineFollowerSpeed", self.splineFollowerSpeed, 0.1, 0, 5, "%.2f", 60)
                style.tooltip("Speed of the character movement along the spline. Preview only.")
                if changed and npc then
                    npc:SetIndividualTimeDilation("", self.splineFollowerSpeed)
                end
                ImGui.SameLine()
                style.pushButtonNoBG(true)

                ImGui.PushID("saveSpeed")
                if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
                    settings.defaultAISpotSpeed = self.splineFollowerSpeed
                    settings.save()
                end
                ImGui.PopID()

                style.tooltip("Save this speed as the default for Spline previews.")
                style.pushButtonNoBG(false)
            end
        end

        ImGui.TreePop()
    end
end

function spline:getProperties()
    return self:addNodeProperty(visualized.getProperties(self))
end

function spline:export()
    local data = visualized.export(self)
    data.type = "worldSplineNode"
    data.data = {}

    local pointDefs = {}
    if self.pointDefs and #self.pointDefs > 0 then
        pointDefs = utils.deepcopy(self.pointDefs)
    elseif self.points and #self.points > 0 then
        for _, point in pairs(self.points) do
            table.insert(pointDefs, {
                position = point,
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            })
        end
    end

    if #pointDefs == 0 then
        table.insert(self.object.sUI.spawner.baseUI.exportUI.exportIssues.noSplineMarker, self.object.name)

        return data
    end

    local points = {}

    for _, pointDef in pairs(pointDefs) do
        local position = utils.subVector(ToVector4(pointDef.position), self.position)
        local tangentIn = pointDef.tangentIn or { x = 0, y = 0, z = 0 }
        local tangentOut = pointDef.tangentOut or { x = 0, y = 0, z = 0 }
        local automaticTangents = pointDef.automaticTangents == nil and true or pointDef.automaticTangents

        table.insert(points, {
            ["$type"] = "SplinePoint",
            ["position"] = {
                ["$type"] = "Vector3",
                ["X"] = position.x,
                ["Y"] = position.y,
                ["Z"] = position.z
            },
            ["automaticTangents"] = automaticTangents and 1 or 0,
            ["tangents"] = {
                ["Elements"] = {
                    {
                        ["$type"] = "Vector3",
                        ["X"] = tonumber(tangentIn.x) or 0,
                        ["Y"] = tonumber(tangentIn.y) or 0,
                        ["Z"] = tonumber(tangentIn.z) or 0
                    },
                    {
                        ["$type"] = "Vector3",
                        ["X"] = tonumber(tangentOut.x) or 0,
                        ["Y"] = tonumber(tangentOut.y) or 0,
                        ["Z"] = tonumber(tangentOut.z) or 0
                    }
                }
            }
        })
    end

    data.data = {
        ["splineData"] = {
            ["Data"] = {
                ["$type"] = "Spline",
                ["points"] = points,
                ["reversed"] = self.reverse and 1 or 0,
                ["looped"] = self.looped and 1 or 0
            }
        }
    }

    return data
end

return spline
