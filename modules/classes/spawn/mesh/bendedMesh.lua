local mesh = require("modules/classes/spawn/mesh/mesh")
local spawnable = require("modules/classes/spawn/spawnable")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local history = require("modules/utils/project/history")
local intersection = require("modules/utils/editor/intersection")
local visualizer = require("modules/utils/preview/visualizer")
local previewHosts = require("modules/utils/preview/previewHosts")
local field = require("modules/utils/ui/field")
local cache = require("modules/utils/game/cache")

local bendedMesh = setmetatable({}, { __index = mesh })
local zeroVector3 = { x = 0, y = 0, z = 0 }

local function normalizeVector4(raw, fallback)
    local source = raw or {}
    local f = fallback or Vector4.new(0, 0, 0, 0)

    return Vector4.new(
        utils.toNumber(source.x or source.X, f.x),
        utils.toNumber(source.y or source.Y, f.y),
        utils.toNumber(source.z or source.Z, f.z),
        utils.toNumber(source.w or source.W, f.w)
    )
end

local function copyDeformedBox(box)
    local fallback = {
        min = Vector4.new(-0.5, -0.5, -0.5, 1),
        max = Vector4.new(0.5, 0.5, 0.5, 1)
    }
    local source = box or {}

    local minimum = normalizeVector4(source.min or source.Min, fallback.min)
    local maximum = normalizeVector4(source.max or source.Max, fallback.max)

    return {
        min = Vector4.new(math.min(minimum.x, maximum.x), math.min(minimum.y, maximum.y), math.min(minimum.z, maximum.z), 1),
        max = Vector4.new(math.max(minimum.x, maximum.x), math.max(minimum.y, maximum.y), math.max(minimum.z, maximum.z), 1)
    }
end

local function copyPathPoint(point, fallback)
    local source = point or {}
    local base = fallback or { x = 0, y = 0, z = 0, roll = 0, anchored = false }
    local anchored = utils.toBoolean(source.anchored or source.anchor or source.isAnchored, base.anchored)

    return {
        x = utils.toNumber(source.x or source.X, base.x),
        y = utils.toNumber(source.y or source.Y, base.y),
        z = utils.toNumber(source.z or source.Z, base.z),
        roll = utils.toNumber(source.roll or source.Roll, base.roll),
        anchored = anchored == true
    }
end

local function lerpPathPoint(a, b, t)
    return {
        x = a.x + (b.x - a.x) * t,
        y = a.y + (b.y - a.y) * t,
        z = a.z + (b.z - a.z) * t,
        roll = a.roll + (b.roll - a.roll) * t
    }
end

local function catmullRomScalar(p0, p1, p2, p3, t)
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * (
        (2 * p1) +
        (-p0 + p2) * t +
        (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
        (-p0 + 3 * p1 - 3 * p2 + p3) * t3
    )
end

local function catmullRomPathPoint(p0, p1, p2, p3, t)
    return {
        x = catmullRomScalar(p0.x, p1.x, p2.x, p3.x, t),
        y = catmullRomScalar(p0.y, p1.y, p2.y, p3.y, t),
        z = catmullRomScalar(p0.z, p1.z, p2.z, p3.z, t),
        -- Keep roll interpolation linear to avoid angular overshoot.
        roll = p1.roll + (p2.roll - p1.roll) * t
    }
end

local pathUpAxisOptions = {
    "World Z (Up)",
    "World Y",
    "World X"
}

local pathInterpolationOptions = {
    "Linear (Segmented)",
    "Catmull-Rom (Smooth)",
    "Bezier (Auto Handles)"
}

local PATH_PREVIEW_FOCUS_POINT = 1
local PATH_PREVIEW_LINE_THICKNESS = 0.04
local PATH_PREVIEW_POINT_SCALE = 0.01
local PATH_PREVIEW_FRAME_LENGTH = 0.22
-- A single entity crashes the game past roughly this many components, so the path preview
-- is spread over host entities holding this many each rather than piled onto the mesh.
local PATH_PREVIEW_COMPONENTS_PER_HOST = 256
local PATH_PREVIEW_MAX_SEGMENTS = 320
local PATH_PREVIEW_MAX_FRAMES = 80
local PATH_POINT_ANCHOR_COLOR = 0xFFE6D8AD
local BEZIER_AUTO_HANDLE_FACTOR = 1 / 3
local BEZIER_NEIGHBOR_HANDLE_FACTOR = 0.5

local deformationClipboardKey = "bendedMeshDeformationData"

local function toTypedVector4(vector)
    return {
        ["$type"] = "Vector4",
        X = vector.x,
        Y = vector.y,
        Z = vector.z,
        W = vector.w
    }
end

local function toTypedMatrix(matrix)
    return {
        ["$type"] = "Matrix",
        X = toTypedVector4(matrix.X),
        Y = toTypedVector4(matrix.Y),
        Z = toTypedVector4(matrix.Z),
        W = toTypedVector4(matrix.W)
    }
end

local function buildStraightPathPoints(length, pointCount)
    local count = math.max(2, math.floor(utils.toNumber(pointCount, 2)))
    local step = count > 1 and (length / (count - 1)) or 0
    local points = {}

    for index = 1, count do
        table.insert(points, {
            x = 0,
            y = step * (index - 1),
            z = 0,
            roll = 0,
            anchored = index == 1 or index == count
        })
    end

    return points
end

local function transformPointWithFrame(frame, point)
    local right = frame.right or { x = 1, y = 0, z = 0 }
    local forward = frame.forward or { x = 0, y = 1, z = 0 }
    local up = frame.up or { x = 0, y = 0, z = 1 }
    local position = frame.position or { x = 0, y = 0, z = 0 }

    return Vector4.new(
        right.x * point.x + forward.x * point.y + up.x * point.z + position.x,
        right.y * point.x + forward.y * point.y + up.y * point.z + position.y,
        right.z * point.x + forward.z * point.y + up.z * point.z + position.z,
        1
    )
end

local function getDefaultNavmeshImpactIndex(enumValues)
    local index = utils.indexValue(enumValues, "Road")
    if index == -1 then
        return 0
    end

    return math.max(index - 1, 0)
end

local function normalizeDirection(vec)
    local length = math.sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
    if length <= 0.000001 then
        return { x = 0, y = 0, z = 0 }
    end

    return {
        x = vec.x / length,
        y = vec.y / length,
        z = vec.z / length
    }
end

local function dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function cross(a, b)
    return {
        x = a.y * b.z - a.z * b.y,
        y = a.z * b.x - a.x * b.z,
        z = a.x * b.y - a.y * b.x
    }
end

local function isDirectionZero(vec)
    return math.abs(vec.x) < 0.000001 and math.abs(vec.y) < 0.000001 and math.abs(vec.z) < 0.000001
end

local function length3(vec)
    return math.sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
end

local function cubicBezierScalar(p0, p1, p2, p3, t)
    local oneMinusT = 1 - t
    local oneMinusT2 = oneMinusT * oneMinusT
    local t2 = t * t

    return oneMinusT2 * oneMinusT * p0
        + 3 * oneMinusT2 * t * p1
        + 3 * oneMinusT * t2 * p2
        + t2 * t * p3
end

local function bezierAutoPathPoint(previousPoint, startPoint, endPoint, nextPoint, t)
    local segment = {
        x = endPoint.x - startPoint.x,
        y = endPoint.y - startPoint.y,
        z = endPoint.z - startPoint.z
    }
    local segmentLength = length3(segment)

    if segmentLength <= 0.000001 then
        return {
            x = startPoint.x,
            y = startPoint.y,
            z = startPoint.z,
            roll = startPoint.roll + (endPoint.roll - startPoint.roll) * t
        }
    end

    local segmentDirection = normalizeDirection(segment)
    local startDirection = normalizeDirection({
        x = endPoint.x - previousPoint.x,
        y = endPoint.y - previousPoint.y,
        z = endPoint.z - previousPoint.z
    })
    local endDirection = normalizeDirection({
        x = nextPoint.x - startPoint.x,
        y = nextPoint.y - startPoint.y,
        z = nextPoint.z - startPoint.z
    })

    if isDirectionZero(startDirection) or dot(startDirection, segmentDirection) < 0 then
        startDirection = segmentDirection
    end
    if isDirectionZero(endDirection) or dot(endDirection, segmentDirection) < 0 then
        endDirection = segmentDirection
    end

    local startNeighborLength = length3({
        x = startPoint.x - previousPoint.x,
        y = startPoint.y - previousPoint.y,
        z = startPoint.z - previousPoint.z
    })
    local endNeighborLength = length3({
        x = nextPoint.x - endPoint.x,
        y = nextPoint.y - endPoint.y,
        z = nextPoint.z - endPoint.z
    })

    local startHandleLength = segmentLength * BEZIER_AUTO_HANDLE_FACTOR
    local endHandleLength = segmentLength * BEZIER_AUTO_HANDLE_FACTOR

    if startNeighborLength > 0.000001 then
        startHandleLength = math.min(startHandleLength, startNeighborLength * BEZIER_NEIGHBOR_HANDLE_FACTOR)
    end
    if endNeighborLength > 0.000001 then
        endHandleLength = math.min(endHandleLength, endNeighborLength * BEZIER_NEIGHBOR_HANDLE_FACTOR)
    end

    local startControl = {
        x = startPoint.x + startDirection.x * startHandleLength,
        y = startPoint.y + startDirection.y * startHandleLength,
        z = startPoint.z + startDirection.z * startHandleLength
    }
    local endControl = {
        x = endPoint.x - endDirection.x * endHandleLength,
        y = endPoint.y - endDirection.y * endHandleLength,
        z = endPoint.z - endDirection.z * endHandleLength
    }

    return {
        x = cubicBezierScalar(startPoint.x, startControl.x, endControl.x, endPoint.x, t),
        y = cubicBezierScalar(startPoint.y, startControl.y, endControl.y, endPoint.y, t),
        z = cubicBezierScalar(startPoint.z, startControl.z, endControl.z, endPoint.z, t),
        -- Keep roll interpolation linear to avoid angular overshoot.
        roll = startPoint.roll + (endPoint.roll - startPoint.roll) * t
    }
end

local function getPathUpAxis(index)
    if index == 1 then
        return { x = 0, y = 1, z = 0 }
    end

    if index == 2 then
        return { x = 1, y = 0, z = 0 }
    end

    return { x = 0, y = 0, z = 1 }
end

local function buildBasisFromForward(forward, upHint)
    local f = normalizeDirection(forward)
    if isDirectionZero(f) then
        f = { x = 0, y = 1, z = 0 }
    end

    local right = normalizeDirection(cross(f, upHint or { x = 0, y = 0, z = 1 }))
    if isDirectionZero(right) then
        right = normalizeDirection(cross(f, { x = 0, y = 1, z = 0 }))
    end
    if isDirectionZero(right) then
        right = normalizeDirection(cross(f, { x = 1, y = 0, z = 0 }))
    end
    if isDirectionZero(right) then
        right = { x = 1, y = 0, z = 0 }
    end

    local up = normalizeDirection(cross(right, f))
    if isDirectionZero(up) then
        up = { x = 0, y = 0, z = 1 }
    end

    right = normalizeDirection(cross(f, up))
    return right, f, up
end

local function rotateAroundAxis(vector, axis, angleRadians)
    local axisNormalized = normalizeDirection(axis)
    if isDirectionZero(axisNormalized) then
        return vector
    end

    local cosTheta = math.cos(angleRadians)
    local sinTheta = math.sin(angleRadians)
    local crossAxisVector = cross(axisNormalized, vector)
    local axisDotVector = dot(axisNormalized, vector)

    return {
        x = vector.x * cosTheta + crossAxisVector.x * sinTheta + axisNormalized.x * axisDotVector * (1 - cosTheta),
        y = vector.y * cosTheta + crossAxisVector.y * sinTheta + axisNormalized.y * axisDotVector * (1 - cosTheta),
        z = vector.z * cosTheta + crossAxisVector.z * sinTheta + axisNormalized.z * axisDotVector * (1 - cosTheta)
    }
end

local function normalizeQuaternion(quat)
    local length = math.sqrt(quat.i * quat.i + quat.j * quat.j + quat.k * quat.k + quat.r * quat.r)
    if length <= 0.000001 then
        return Quaternion.new(0, 0, 0, 1)
    end

    return Quaternion.new(quat.i / length, quat.j / length, quat.k / length, quat.r / length)
end

local function quaternionFromBasis(right, forward, up)
    local m00, m01, m02 = right.x, forward.x, up.x
    local m10, m11, m12 = right.y, forward.y, up.y
    local m20, m21, m22 = right.z, forward.z, up.z

    local qx, qy, qz, qw
    local trace = m00 + m11 + m22

    if trace > 0 then
        local s = math.sqrt(trace + 1) * 2
        qw = 0.25 * s
        qx = (m21 - m12) / s
        qy = (m02 - m20) / s
        qz = (m10 - m01) / s
    elseif m00 > m11 and m00 > m22 then
        local s = math.sqrt(1 + m00 - m11 - m22) * 2
        qw = (m21 - m12) / s
        qx = 0.25 * s
        qy = (m01 + m10) / s
        qz = (m02 + m20) / s
    elseif m11 > m22 then
        local s = math.sqrt(1 + m11 - m00 - m22) * 2
        qw = (m02 - m20) / s
        qx = (m01 + m10) / s
        qy = 0.25 * s
        qz = (m12 + m21) / s
    else
        local s = math.sqrt(1 + m22 - m00 - m11) * 2
        qw = (m10 - m01) / s
        qx = (m02 + m20) / s
        qy = (m12 + m21) / s
        qz = 0.25 * s
    end

    return normalizeQuaternion(Quaternion.new(qx, qy, qz, qw))
end

local function getPathStartFrame(pathPoints, upAxisIndex)
    local firstPoint = pathPoints and pathPoints[1]
    local secondPoint = pathPoints and pathPoints[2]

    local position = {
        x = utils.toNumber(firstPoint and firstPoint.x, 0),
        y = utils.toNumber(firstPoint and firstPoint.y, 0),
        z = utils.toNumber(firstPoint and firstPoint.z, 0)
    }

    local forward = { x = 0, y = 1, z = 0 }
    if secondPoint then
        forward = {
            x = utils.toNumber(secondPoint.x, 0) - position.x,
            y = utils.toNumber(secondPoint.y, 0) - position.y,
            z = utils.toNumber(secondPoint.z, 0) - position.z
        }
    end
    forward = normalizeDirection(forward)
    if isDirectionZero(forward) then
        forward = { x = 0, y = 1, z = 0 }
    end

    local clampedUpAxisIndex = math.max(0, math.min(math.floor(utils.toNumber(upAxisIndex, 0)), #pathUpAxisOptions - 1))
    local upHint = getPathUpAxis(clampedUpAxisIndex)
    local right, _, up = buildBasisFromForward(forward, upHint)

    local roll = utils.toNumber(firstPoint and firstPoint.roll, 0)
    if math.abs(roll) > 0.00001 then
        local angle = math.rad(roll)
        right = normalizeDirection(rotateAroundAxis(right, forward, angle))
        up = normalizeDirection(rotateAroundAxis(up, forward, angle))
    end

    local upReference = {
        x = upHint.x - dot(upHint, forward) * forward.x,
        y = upHint.y - dot(upHint, forward) * forward.y,
        z = upHint.z - dot(upHint, forward) * forward.z
    }
    upReference = normalizeDirection(upReference)
    if not isDirectionZero(upReference) and dot(up, upReference) < 0 then
        right = { x = -right.x, y = -right.y, z = -right.z }
        up = { x = -up.x, y = -up.y, z = -up.z }
    end

    return {
        position = position,
        right = right,
        forward = forward,
        up = up
    }
end

function bendedMesh:new()
    local o = mesh.new(self)

    o.dataType = "Bended Mesh"
    o.modulePath = "mesh/bendedMesh"
    o.spawnDataPath = "data/spawnables/mesh/bended/"
    o.node = "worldBendedMeshNode"
    o.description = "Places a world bended mesh node with path-based deformation editing and deformed bounding box."
    o.previewNote = "Deformation is not simulated in-editor; exported deformation data is used ingame."
    o.icon = IconGlyphs.SineWave

    o.isBendedRoad = true
    o.removeFromRainMap = false
    o.navmeshImpactEnum = utils.enumTable("NavGenNavmeshImpact")
    if #o.navmeshImpactEnum == 0 then
        o.navmeshImpactEnum = { "Road" }
    end
    o.navigationImpact = getDefaultNavmeshImpactIndex(o.navmeshImpactEnum)
    o.castLocalShadows = 1
    o.castShadows = 1
    o.deformedBox = copyDeformedBox(nil)
    o.pathPoints = { { x = 0, y = 0, z = 0, roll = 0, anchored = true } }
    o.pathLooped = false
    o.pathUseAlgorithm = true
    o.pathInterpolation = 0
    o.pathUpAxis = 0
    o.pathPreviewEnabled = true
    o.pathPreviewShowFrames = true
    o.pathPreviewSegmentCount = 0
    o.pathPreviewControlCount = 0
    o.pathPreviewFrameCount = 0
    o.pathPreviewSubdivisionCount = 0
    o.bendedColliderShape = 0
    o.bendedColliderStep = 1
    o.bendedColliderOverlap = 0.05
    o.version = 0
    o.pendingAutoFit = false
    o.maxPropertyWidth = nil

    o.hideGenerate = true
    o.convertTarget = 0

    setmetatable(o, { __index = self })
    return o
end

function bendedMesh:loadSpawnData(data, position, rotation)
    mesh.loadSpawnData(self, data, position, rotation)

    self.isBendedRoad = utils.toBoolean(data.isBendedRoad, true)
    self.removeFromRainMap = utils.toBoolean(data.removeFromRainMap, false)
    self.version = data.version or self.version

    local navigationImpact = data.navigationImpact
    if navigationImpact == nil and data.navigationSetting then
        navigationImpact = data.navigationSetting.navmeshImpact
    end

    if type(navigationImpact) == "string" then
        local index = utils.indexValue(self.navmeshImpactEnum, navigationImpact)
        self.navigationImpact = math.max(index - 1, 0)
    elseif type(navigationImpact) == "number" then
        self.navigationImpact = math.max(0, math.min(math.floor(navigationImpact), math.max(0, #self.navmeshImpactEnum - 1)))
    end

    self.deformedBox = copyDeformedBox(data.deformedBox)

    self.pathLooped = utils.toBoolean(data.pathLooped, self.pathLooped)
    self.pathUseAlgorithm = utils.toBoolean(data.pathUseAlgorithm, self.pathUseAlgorithm)
    self.pathInterpolation = math.max(0, math.min(math.floor(utils.toNumber(data.pathInterpolation, self.pathInterpolation)), #pathInterpolationOptions - 1))
    self.pathUpAxis = math.max(0, math.min(math.floor(utils.toNumber(data.pathUpAxis, self.pathUpAxis)), #pathUpAxisOptions - 1))
    self.pathPreviewEnabled = utils.toBoolean(data.pathPreviewEnabled, self.pathPreviewEnabled)
    self.pathPreviewShowFrames = utils.toBoolean(data.pathPreviewShowFrames, self.pathPreviewShowFrames)
    self.bendedColliderShape = math.max(0, math.min(2, math.floor(utils.toNumber(data.bendedColliderShape, self.bendedColliderShape))))
    self.bendedColliderStep = math.max(1, math.min(16, math.floor(utils.toNumber(data.bendedColliderStep, self.bendedColliderStep))))
    self.bendedColliderOverlap = math.max(0, math.min(0.5, utils.toNumber(data.bendedColliderOverlap, self.bendedColliderOverlap)))

    self.pathPoints = {}
    for _, point in ipairs(data.pathPoints or {}) do
        table.insert(self.pathPoints, copyPathPoint(point))
    end

    self:ensurePathPoints()

    self.pendingAutoFit = true
    self:updatePathVisualization()
end

function bendedMesh:onAssemble(entity)
    mesh.onAssemble(self, entity)
    self:updatePathVisualization()
end

function bendedMesh:updateScale()
    mesh.updateScale(self)
    self:updatePathVisualization()
end

function bendedMesh:save()
    self:ensurePathPoints()
    self:applyPathAlgorithmToNonAnchored()

    if self.bBoxLoaded then
        self:autoFitDeformedBox()
    end

    local data = mesh.save(self)
    local normalizedBox = self:getNormalizedDeformedBox()

    data.isBendedRoad = self.isBendedRoad
    data.removeFromRainMap = self.removeFromRainMap
    data.navigationImpact = self.navigationImpact
    data.version = self.version
    data.pathLooped = self.pathLooped
    data.pathUseAlgorithm = self.pathUseAlgorithm
    data.pathInterpolation = self.pathInterpolation
    data.pathUpAxis = self.pathUpAxis
    data.pathPreviewEnabled = self.pathPreviewEnabled
    data.pathPreviewShowFrames = self.pathPreviewShowFrames
    data.bendedColliderShape = self.bendedColliderShape
    data.bendedColliderStep = self.bendedColliderStep
    data.bendedColliderOverlap = self.bendedColliderOverlap
    data.pathPoints = {}
    data.deformedBox = {
        min = { x = normalizedBox.min.x, y = normalizedBox.min.y, z = normalizedBox.min.z, w = 1 },
        max = { x = normalizedBox.max.x, y = normalizedBox.max.y, z = normalizedBox.max.z, w = 1 }
    }

    for _, point in ipairs(self.pathPoints) do
        table.insert(data.pathPoints, copyPathPoint(point))
    end

    return data
end

function bendedMesh:isDeformationClipboardPayloadValid(payload)
    if type(payload) ~= "table" then
        return false
    end

    local hasPath = type(payload.pathPoints) == "table" and #payload.pathPoints > 0
    return hasPath
end

function bendedMesh:getDeformationClipboardPayload()
    self:ensurePathPoints()
    self:applyPathAlgorithmToNonAnchored()

    local payload = {
        version = 4,
        pathLooped = self.pathLooped,
        pathUseAlgorithm = self.pathUseAlgorithm,
        pathInterpolation = self.pathInterpolation,
        pathUpAxis = self.pathUpAxis,
        pathPoints = {}
    }

    for _, point in ipairs(self.pathPoints or {}) do
        table.insert(payload.pathPoints, copyPathPoint(point))
    end

    return payload
end

function bendedMesh:applyDeformationClipboardPayload(payload)
    if not self:isDeformationClipboardPayloadValid(payload) then
        return false
    end

    local hasPath = type(payload.pathPoints) == "table" and #payload.pathPoints > 0

    if payload.pathLooped ~= nil then
        self.pathLooped = utils.toBoolean(payload.pathLooped, self.pathLooped)
    end
    if payload.pathUseAlgorithm ~= nil then
        self.pathUseAlgorithm = utils.toBoolean(payload.pathUseAlgorithm, self.pathUseAlgorithm)
    end
    if payload.pathInterpolation ~= nil then
        self.pathInterpolation = math.max(0, math.min(math.floor(utils.toNumber(payload.pathInterpolation, self.pathInterpolation)), #pathInterpolationOptions - 1))
    end
    if payload.pathUpAxis ~= nil then
        self.pathUpAxis = math.max(0, math.min(math.floor(utils.toNumber(payload.pathUpAxis, self.pathUpAxis)), #pathUpAxisOptions - 1))
    end

    self.pathPoints = {}
    if hasPath then
        for _, point in ipairs(payload.pathPoints) do
            table.insert(self.pathPoints, copyPathPoint(point))
        end
    end
    self:ensurePathPoints()

    self:autoFitDeformedBox()

    self:refreshArrowScale()
    return true
end

function bendedMesh:getContinuationLength()
    local length = 0
    local frames = self:getSampledPathFrames()
    local frameCount = #frames

    if frameCount >= 2 then
        local previous = frames[frameCount - 1]
        local current = frames[frameCount]
        if previous and previous.position and current and current.position then
            length = utils.distanceVector(zeroVector3, {
                x = current.position.x - previous.position.x,
                y = current.position.y - previous.position.y,
                z = current.position.z - previous.position.z
            })
        end
    end

    if length <= 0.0001 then
        local bboxLength = math.abs((self.bBox.max and self.bBox.max.y or 0.5) - (self.bBox.min and self.bBox.min.y or -0.5))
        length = math.max(length, bboxLength)
    end

    if length <= 0.0001 then
        length = 1
    end

    return length
end

function bendedMesh:getMeshBoundLengthAlongDirection(direction)
    local axis = normalizeDirection(direction or { x = 0, y = 1, z = 0 })
    if isDirectionZero(axis) then
        axis = { x = 0, y = 1, z = 0 }
    end

    local extentX = math.abs((self.bBox.max and self.bBox.max.x or 0.5) - (self.bBox.min and self.bBox.min.x or -0.5))
    local extentY = math.abs((self.bBox.max and self.bBox.max.y or 0.5) - (self.bBox.min and self.bBox.min.y or -0.5))
    local extentZ = math.abs((self.bBox.max and self.bBox.max.z or 0.5) - (self.bBox.min and self.bBox.min.z or -0.5))

    local projected = math.abs(axis.x) * extentX + math.abs(axis.y) * extentY + math.abs(axis.z) * extentZ
    if projected < 0.001 then
        projected = math.max(extentX, extentY, extentZ, 1)
    end

    return projected
end

function bendedMesh:getWorldTransformFromPathFrame(frame)
    local objectQuat = self.rotation:ToQuat()
    local scaledLocalPosition = self:toScaledLocalPoint({
        x = frame.position.x,
        y = frame.position.y,
        z = frame.position.z
    })
    local worldOffset = objectQuat:Transform(Vector4.new(scaledLocalPosition.x, scaledLocalPosition.y, scaledLocalPosition.z, 0))
    local worldPosition = Vector4.new(
        self.position.x + worldOffset.x,
        self.position.y + worldOffset.y,
        self.position.z + worldOffset.z,
        0
    )

    local rightWorldVec = objectQuat:Transform(Vector4.new(frame.right.x, frame.right.y, frame.right.z, 0))
    local forwardWorldVec = objectQuat:Transform(Vector4.new(frame.forward.x, frame.forward.y, frame.forward.z, 0))
    local upWorldVec = objectQuat:Transform(Vector4.new(frame.up.x, frame.up.y, frame.up.z, 0))

    local forward = normalizeDirection(forwardWorldVec)
    if isDirectionZero(forward) then
        forward = { x = 0, y = 1, z = 0 }
    end

    local up = normalizeDirection(upWorldVec)
    if isDirectionZero(up) or math.abs(dot(up, forward)) > 0.9999 then
        up = { x = 0, y = 0, z = 1 }
        if math.abs(dot(up, forward)) > 0.9999 then
            up = { x = 1, y = 0, z = 0 }
        end
    end

    up = normalizeDirection({
        x = up.x - dot(up, forward) * forward.x,
        y = up.y - dot(up, forward) * forward.y,
        z = up.z - dot(up, forward) * forward.z
    })
    if isDirectionZero(up) then
        up = { x = 0, y = 0, z = 1 }
    end

    local right = normalizeDirection(cross(forward, up))
    if isDirectionZero(right) then
        right = normalizeDirection(rightWorldVec)
    end
    if isDirectionZero(right) then
        right = { x = 1, y = 0, z = 0 }
    end

    up = normalizeDirection(cross(right, forward))
    if isDirectionZero(up) then
        up = { x = 0, y = 0, z = 1 }
    end

    right = normalizeDirection(cross(forward, up))
    local worldRotation = quaternionFromBasis(right, forward, up):ToEulerAngles()

    return worldPosition, worldRotation
end

function bendedMesh:createContinuationMesh()
    if not self.object or not self.object.parent or self.object:isLocked() then
        return false
    end

    local frames = self:getSampledPathFrames()
    local frameCount = #frames
    if frameCount == 0 then
        return false
    end

    local endFrame = frames[frameCount]
    if not endFrame or not endFrame.position or not endFrame.right or not endFrame.forward or not endFrame.up then
        return false
    end

    local worldPosition, worldRotation = self:getWorldTransformFromPathFrame(endFrame)
    local continuationLength = self:getContinuationLength()
    local signedLength = continuationLength
    if self.scale and self.scale.y and self.scale.y < 0 then
        signedLength = -signedLength
    end

    local requiredPointCount = self:getMeshBonesQuantity()
    if requiredPointCount == nil or requiredPointCount < 2 then
        self:ensurePathPoints()
        requiredPointCount = math.max(2, #(self.pathPoints or {}))
    end

    local data = self.object:serialize()
    if not data or not data.spawnable then
        return false
    end

    local continuationPathPoints = nil
    local defaultPathPoints = cache.getDefaultBendedPathPoints(self.spawnData)
    if type(defaultPathPoints) == "table" and #defaultPathPoints > 1 then
        continuationPathPoints = {}
        for _, point in ipairs(defaultPathPoints) do
            table.insert(continuationPathPoints, copyPathPoint(point))
        end
    end

    if type(continuationPathPoints) ~= "table" or #continuationPathPoints < 2 then
        continuationPathPoints = buildStraightPathPoints(signedLength, requiredPointCount)
    elseif requiredPointCount ~= nil and requiredPointCount >= 2 and #continuationPathPoints ~= requiredPointCount then
        -- Keep deformation count valid if preset data and runtime rig count disagree.
        continuationPathPoints = buildStraightPathPoints(signedLength, requiredPointCount)
    end

    local continuationUpAxis = math.max(0, math.min(math.floor(utils.toNumber(data.spawnable.pathUpAxis, self.pathUpAxis or 0)), #pathUpAxisOptions - 1))
    local continuationStartFrame = getPathStartFrame(continuationPathPoints, continuationUpAxis)
    local targetQuat = worldRotation:ToQuat()
    local startQuat = quaternionFromBasis(continuationStartFrame.right, continuationStartFrame.forward, continuationStartFrame.up)
    local continuationQuat = normalizeQuaternion(Quaternion.MulInverse(targetQuat, startQuat))
    local continuationScale = data.spawnable.scale or self.scale or { x = 1, y = 1, z = 1 }
    local startScaledLocal = {
        x = continuationStartFrame.position.x * utils.toNumber(continuationScale.x, 1),
        y = continuationStartFrame.position.y * utils.toNumber(continuationScale.y, 1),
        z = continuationStartFrame.position.z * utils.toNumber(continuationScale.z, 1)
    }
    local startWorldOffset = continuationQuat:Transform(Vector4.new(startScaledLocal.x, startScaledLocal.y, startScaledLocal.z, 0))
    local continuationPosition = Vector4.new(
        worldPosition.x - startWorldOffset.x,
        worldPosition.y - startWorldOffset.y,
        worldPosition.z - startWorldOffset.z,
        0
    )
    local continuationRotation = continuationQuat:ToEulerAngles()

    data.name = utils.generateCopyName(self.object.name)
    data.spawnable.position = { x = continuationPosition.x, y = continuationPosition.y, z = continuationPosition.z, w = 0 }
    data.spawnable.rotation = { roll = continuationRotation.roll, pitch = continuationRotation.pitch, yaw = continuationRotation.yaw }
    data.spawnable.nodeRef = ""
    data.spawnable.pathLooped = false
    data.spawnable.deformedBox = nil
    data.spawnable.pathPoints = continuationPathPoints

    local newElement = require("modules/classes/editor/spawnableElement"):new(self.object.sUI)
    newElement:load(data)

    local parent = self.object.parent
    local index = utils.indexValue(parent.childs, self.object) + 1
    if index < 1 then
        index = #parent.childs + 1
    end
    newElement:setParent(parent, index)

    if self.object.sUI and self.object.sUI.unselectAll then
        self.object.sUI.unselectAll()
    end
    newElement:setSelected(true)
    if self.object.sUI then
        if self.object.sUI.requestScrollToElement then
            self.object.sUI.requestScrollToElement(newElement)
        else
            self.object.sUI.scrollToSelected = true
            self.object.sUI.scrollTargetId = newElement.id
            self.object.sUI.scrollRetryCount = 0
        end
    end

    history.addAction(history.getInsert({ newElement }))
    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Created continuation bended mesh"))
    return true
end

function bendedMesh:getWorldPointFromLocal(localPoint)
    local objectQuat = self.rotation:ToQuat()
    local scaledLocal = self:toScaledLocalPoint(localPoint)
    local worldOffset = objectQuat:Transform(Vector4.new(scaledLocal.x, scaledLocal.y, scaledLocal.z, 0))

    return Vector4.new(
        self.position.x + worldOffset.x,
        self.position.y + worldOffset.y,
        self.position.z + worldOffset.z,
        0
    )
end

function bendedMesh:buildSegmentColliderTransform(startFrame, endFrame, halfWidth, halfHeight, overlapFactor)
    if not startFrame or not endFrame or not startFrame.position or not endFrame.position then
        return nil
    end

    local startPos = self:getWorldPointFromLocal(startFrame.position)
    local endPos = self:getWorldPointFromLocal(endFrame.position)
    local diff = {
        x = endPos.x - startPos.x,
        y = endPos.y - startPos.y,
        z = endPos.z - startPos.z
    }
    local length = utils.distanceVector(zeroVector3, diff)
    if length <= 0.0001 then
        return nil
    end

    local forward = normalizeDirection(diff)
    if isDirectionZero(forward) then
        return nil
    end

    local objectQuat = self.rotation:ToQuat()
    local upHintVec = objectQuat:Transform(Vector4.new(
        startFrame.up and startFrame.up.x or 0,
        startFrame.up and startFrame.up.y or 0,
        startFrame.up and startFrame.up.z or 1,
        0
    ))
    local upHint = normalizeDirection(upHintVec)
    if isDirectionZero(upHint) or math.abs(dot(upHint, forward)) > 0.9999 then
        upHint = { x = 0, y = 0, z = 1 }
        if math.abs(dot(upHint, forward)) > 0.9999 then
            upHint = { x = 1, y = 0, z = 0 }
        end
    end

    local right = normalizeDirection(cross(forward, upHint))
    if isDirectionZero(right) and startFrame.right then
        local rightHintVec = objectQuat:Transform(Vector4.new(startFrame.right.x, startFrame.right.y, startFrame.right.z, 0))
        right = normalizeDirection(rightHintVec)
    end
    if isDirectionZero(right) then
        right = { x = 1, y = 0, z = 0 }
    end

    local up = normalizeDirection(cross(right, forward))
    if isDirectionZero(up) then
        up = { x = 0, y = 0, z = 1 }
    end
    right = normalizeDirection(cross(forward, up))

    local midpoint = Vector4.new(
        (startPos.x + endPos.x) * 0.5,
        (startPos.y + endPos.y) * 0.5,
        (startPos.z + endPos.z) * 0.5,
        0
    )
    local rotation = quaternionFromBasis(right, forward, up):ToEulerAngles()
    local halfLength = math.max(0.01, (length * 0.5) * (1 + overlapFactor))

    return midpoint, rotation, {
        x = math.max(0.005, halfWidth),
        y = halfLength,
        z = math.max(0.005, halfHeight)
    }
end

function bendedMesh:interpolatePathFrameForSegment(frameA, frameB, t)
    local function lerpAxis(axisA, axisB, fallback)
        local a = axisA or fallback
        local b = axisB or a
        local axis = normalizeDirection({
            x = (a.x or fallback.x) + ((b.x or a.x or fallback.x) - (a.x or fallback.x)) * t,
            y = (a.y or fallback.y) + ((b.y or a.y or fallback.y) - (a.y or fallback.y)) * t,
            z = (a.z or fallback.z) + ((b.z or a.z or fallback.z) - (a.z or fallback.z)) * t
        })

        if isDirectionZero(axis) then
            axis = normalizeDirection(a or fallback)
        end
        if isDirectionZero(axis) then
            axis = fallback
        end

        return axis
    end

    local startPos = frameA and frameA.position or { x = 0, y = 0, z = 0 }
    local endPos = frameB and frameB.position or startPos

    return {
        right = normalizeDirection(lerpAxis(frameA and frameA.right, frameB and frameB.right, { x = 1, y = 0, z = 0 })),
        forward = normalizeDirection(lerpAxis(frameA and frameA.forward, frameB and frameB.forward, { x = 0, y = 1, z = 0 })),
        up = normalizeDirection(lerpAxis(frameA and frameA.up, frameB and frameB.up, { x = 0, y = 0, z = 1 })),
        position = {
            x = startPos.x + ((endPos.x or startPos.x) - startPos.x) * t,
            y = startPos.y + ((endPos.y or startPos.y) - startPos.y) * t,
            z = startPos.z + ((endPos.z or startPos.z) - startPos.z) * t
        }
    }
end

function bendedMesh:generateBendedColliders()
    if not self.object or not self.object.parent or self.object:isLocked() then
        return false
    end

    local frames = self:getSampledPathFrames()
    if #frames < 2 then
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Warning, 2500, "Need at least 2 sampled path points to generate colliders"))
        return false
    end

    local width = math.abs((self.bBox.max and self.bBox.max.x or 0.5) - (self.bBox.min and self.bBox.min.x or -0.5)) * math.abs(self.scale.x or 1)
    local height = math.abs((self.bBox.max and self.bBox.max.z or 0.5) - (self.bBox.min and self.bBox.min.z or -0.5)) * math.abs(self.scale.z or 1)
    local halfWidth = math.max(0.01, width * 0.5)
    local halfHeight = math.max(0.01, height * 0.5)

    local splitStep = math.max(1, math.min(16, math.floor(self.bendedColliderStep or 1)))
    local overlap = math.max(0, math.min(0.5, self.bendedColliderOverlap or 0))
    local shape = 0
    if self.bendedColliderShape ~= nil then
        shape = math.max(0, math.min(2, math.floor(self.bendedColliderShape)))
    end

    local parent = self.object.parent
    local index = utils.indexValue(parent.childs, self.object) + 1
    if index < 1 then
        index = #parent.childs + 1
    end

    local group = require("modules/classes/editor/positionableGroup"):new(self.object.sUI)
    group.name = self.object.name .. "_colliders"
    group:setParent(parent, index)
    group.headerOpen = false

    local created = 0
    for segmentIndex = 1, #frames - 1 do
        local frameA = frames[segmentIndex]
        local frameB = frames[segmentIndex + 1]

        for splitIndex = 1, splitStep do
            local t0 = (splitIndex - 1) / splitStep
            local t1 = splitIndex / splitStep
            local subFrameA = self:interpolatePathFrameForSegment(frameA, frameB, t0)
            local subFrameB = self:interpolatePathFrameForSegment(frameA, frameB, t1)
            local position, rotation, extents = self:buildSegmentColliderTransform(subFrameA, subFrameB, halfWidth, halfHeight, overlap)

            if position and rotation and extents then
                local collider = require("modules/classes/spawn/collision/collider"):new()
                local colliderData = {
                    shape = shape,
                    extents = { x = extents.x, y = extents.y, z = extents.z }
                }

                if shape == 1 then
                    colliderData.radius = math.max(extents.x, extents.z)
                    colliderData.height = math.max(0.01, extents.y * 2 - colliderData.radius * 2)
                elseif shape == 2 then
                    colliderData.radius = math.max(extents.x, extents.y, extents.z)
                end

                collider:loadSpawnData(colliderData, position, rotation)

                local colliderElement = require("modules/classes/editor/spawnableElement"):new(self.object.sUI)
                colliderElement:load({
                    name = self.object.name .. "_segCollider_" .. tostring(created + 1),
                    spawnable = collider:save(),
                    modulePath = "modules/classes/editor/spawnableElement"
                })
                colliderElement:setParent(group)
                created = created + 1
            end
        end
    end

    if created == 0 then
        group:remove()
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Warning, 2500, "No valid bend segments for collider generation"))
        return false
    end

    history.addAction(history.getInsert({ group }))
    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Generated %d bended colliders", created)))
    return true
end

function bendedMesh:ensurePathPoints()
    self.pathPoints = self.pathPoints or {}
    if #self.pathPoints == 0 then
        local defaultPoints = cache.getDefaultBendedPathPoints(self.spawnData)
        if type(defaultPoints) == "table" and #defaultPoints > 0 then
            for _, point in ipairs(defaultPoints) do
                table.insert(self.pathPoints, copyPathPoint(point))
            end
        end

        if #self.pathPoints == 0 then
            table.insert(self.pathPoints, { x = 0, y = 0, z = 0, roll = 0, anchored = true })
        end
    end

    for index, point in ipairs(self.pathPoints) do
        -- A point that says nothing about being anchored is one the payload never authored, and
        -- the two ends of a path are anchored by default. That is a third state on top of the
        -- boolean, so it is settled here rather than through a coercion fallback.
        local authored = point.anchored or point.anchor or point.isAnchored

        if authored == nil then
            point.anchored = index == 1 or index == #self.pathPoints
        else
            point.anchored = utils.toBoolean(authored)
        end
    end

    if #self.pathPoints >= 1 then
        self.pathPoints[1].anchored = true
    end
    if #self.pathPoints >= 2 then
        self.pathPoints[#self.pathPoints].anchored = true
    end
end

function bendedMesh:isPathPointAnchored(index)
    local pathPoints = self.pathPoints or {}

    if index <= 1 or index >= #pathPoints then
        return true
    end

    local point = pathPoints[index]
    return point and point.anchored == true or false
end

function bendedMesh:applyPathAlgorithmToNonAnchored()
    self:ensurePathPoints()

    if not self.pathUseAlgorithm then
        return false
    end

    if #self.pathPoints <= 2 then
        return false
    end

    local interpolation = math.max(0, math.min(math.floor(self.pathInterpolation or 0), #pathInterpolationOptions - 1))
    local anchorIndices = {}

    for index = 1, #self.pathPoints do
        if self:isPathPointAnchored(index) then
            table.insert(anchorIndices, index)
        end
    end

    if #anchorIndices < 2 then
        return false
    end

    local changedAny = false

    for anchorOrder = 1, #anchorIndices - 1 do
        local startIndex = anchorIndices[anchorOrder]
        local endIndex = anchorIndices[anchorOrder + 1]
        local span = endIndex - startIndex

        if span > 1 then
            local startPoint = self.pathPoints[startIndex]
            local endPoint = self.pathPoints[endIndex]
            local previousAnchorIndex = anchorIndices[math.max(anchorOrder - 1, 1)]
            local nextAnchorIndex = anchorIndices[math.min(anchorOrder + 2, #anchorIndices)]
            local previousAnchorPoint = self.pathPoints[previousAnchorIndex] or startPoint
            local nextAnchorPoint = self.pathPoints[nextAnchorIndex] or endPoint

            for pointIndex = startIndex + 1, endIndex - 1 do
                if not self:isPathPointAnchored(pointIndex) then
                    local t = (pointIndex - startIndex) / span
                    local computed

                    if interpolation == 2 then
                        computed = bezierAutoPathPoint(previousAnchorPoint, startPoint, endPoint, nextAnchorPoint, t)
                    elseif interpolation == 1 and #anchorIndices >= 3 then
                        computed = catmullRomPathPoint(previousAnchorPoint, startPoint, endPoint, nextAnchorPoint, t)
                    else
                        computed = lerpPathPoint(startPoint, endPoint, t)
                    end

                    local point = self.pathPoints[pointIndex]
                    if point then
                        if math.abs((point.x or 0) - computed.x) > 0.000001
                            or math.abs((point.y or 0) - computed.y) > 0.000001
                            or math.abs((point.z or 0) - computed.z) > 0.000001
                            or math.abs((point.roll or 0) - computed.roll) > 0.000001 then
                            changedAny = true
                        end

                        point.x = computed.x
                        point.y = computed.y
                        point.z = computed.z
                        point.roll = computed.roll
                    end
                end
            end
        end
    end

    return changedAny
end

---@return integer?
function bendedMesh:getMeshBonesQuantity()
    local resourceData = self.meshResourceData
    if not resourceData then
        resourceData = cache.getMeshResource(self.spawnData)
    end

    if resourceData and type(resourceData.rigMatrices) == "table" and #resourceData.rigMatrices > 0 then
        return #resourceData.rigMatrices
    end

    return cache.getDefaultBendedMatrixCount(self.spawnData)
end

function bendedMesh:makeDefaultPathPointAfterCurrent(index)
    self:ensurePathPoints()

    local current = self.pathPoints[index]

    if not current then
        return { x = 0, y = 0, z = 0, roll = 0, anchored = false }
    end

    local axis = { x = 0, y = 1, z = 0 }
    if index < #self.pathPoints and self.pathPoints[index + 1] then
        axis = normalizeDirection({
            x = self.pathPoints[index + 1].x - current.x,
            y = self.pathPoints[index + 1].y - current.y,
            z = self.pathPoints[index + 1].z - current.z
        })
    elseif index > 1 and self.pathPoints[index - 1] then
        axis = normalizeDirection({
            x = current.x - self.pathPoints[index - 1].x,
            y = current.y - self.pathPoints[index - 1].y,
            z = current.z - self.pathPoints[index - 1].z
        })
    end

    if isDirectionZero(axis) then
        axis = { x = 0, y = 1, z = 0 }
    end

    local offset
    if index == #self.pathPoints then
        if index > 1 and self.pathPoints[index - 1] then
            offset = utils.distanceVector(zeroVector3, {
                x = current.x - self.pathPoints[index - 1].x,
                y = current.y - self.pathPoints[index - 1].y,
                z = current.z - self.pathPoints[index - 1].z
            })
            if offset < 0.001 then
                offset = self:getMeshBoundLengthAlongDirection(axis)
            end
        else
            offset = self:getMeshBoundLengthAlongDirection(axis)
        end
    elseif index < #self.pathPoints and self.pathPoints[index + 1] then
        offset = utils.distanceVector(zeroVector3, {
            x = self.pathPoints[index + 1].x - current.x,
            y = self.pathPoints[index + 1].y - current.y,
            z = self.pathPoints[index + 1].z - current.z
        })
    else
        offset = self:getMeshBoundLengthAlongDirection(axis)
    end

    if offset < 0.001 then
        offset = 1
    end

    return {
        x = current.x + axis.x * offset,
        y = current.y + axis.y * offset,
        z = current.z + axis.z * offset,
        roll = current.roll or 0,
        anchored = false
    }
end

function bendedMesh:getSampledPathPoints()
    self:ensurePathPoints()
    self:applyPathAlgorithmToNonAnchored()

    local controlPoints = self.pathPoints
    local sampled = {}
    local sampleInfo = {}
    local looped = self.pathLooped and #controlPoints > 2

    for index, point in ipairs(controlPoints) do
        table.insert(sampled, copyPathPoint(point))
        if self:isPathPointAnchored(index) then
            table.insert(sampleInfo, { isControlPoint = true, controlPointIndex = index })
        else
            table.insert(sampleInfo, { isControlPoint = false, controlPointIndex = nil })
        end
    end

    if #sampled == 0 then
        table.insert(sampled, { x = 0, y = 0, z = 0, roll = 0, anchored = true })
        table.insert(sampleInfo, { isControlPoint = true, controlPointIndex = 1 })
    end

    return sampled, looped, sampleInfo
end

function bendedMesh:getPathForward(sampledPoints, index, looped)
    if #sampledPoints <= 1 then
        return { x = 0, y = 1, z = 0 }
    end

    local prevIndex = index - 1
    local nextIndex = index + 1

    if looped then
        if prevIndex < 1 then
            prevIndex = #sampledPoints
        end
        if nextIndex > #sampledPoints then
            nextIndex = 1
        end
    end

    local prevPoint = sampledPoints[prevIndex]
    local nextPoint = sampledPoints[nextIndex]
    local current = sampledPoints[index]
    local forward

    if prevPoint and nextPoint then
        forward = {
            x = nextPoint.x - prevPoint.x,
            y = nextPoint.y - prevPoint.y,
            z = nextPoint.z - prevPoint.z
        }
    elseif nextPoint then
        forward = {
            x = nextPoint.x - current.x,
            y = nextPoint.y - current.y,
            z = nextPoint.z - current.z
        }
    elseif prevPoint then
        forward = {
            x = current.x - prevPoint.x,
            y = current.y - prevPoint.y,
            z = current.z - prevPoint.z
        }
    else
        forward = { x = 0, y = 1, z = 0 }
    end

    forward = normalizeDirection(forward)
    if isDirectionZero(forward) then
        return { x = 0, y = 1, z = 0 }
    end

    return forward
end

function bendedMesh:getSampledPathFrames()
    local sampledPoints, looped, sampleInfo = self:getSampledPathPoints()
    local upHint = getPathUpAxis(self.pathUpAxis)
    local frames = {}
    local lastRight = nil

    for index, point in ipairs(sampledPoints) do
        local forward = self:getPathForward(sampledPoints, index, looped)
        local right, _, up = buildBasisFromForward(forward, upHint)

        if lastRight and dot(right, lastRight) < 0 then
            right = { x = -right.x, y = -right.y, z = -right.z }
            up = { x = -up.x, y = -up.y, z = -up.z }
        end

        local roll = utils.toNumber(point.roll, 0)
        if math.abs(roll) < 0.001 then
            roll = 0
        end
        if math.abs(roll) > 0.00001 then
            local angle = math.rad(roll)
            right = normalizeDirection(rotateAroundAxis(right, forward, angle))
            up = normalizeDirection(rotateAroundAxis(up, forward, angle))
        end

        local upReference = {
            x = upHint.x - dot(upHint, forward) * forward.x,
            y = upHint.y - dot(upHint, forward) * forward.y,
            z = upHint.z - dot(upHint, forward) * forward.z
        }
        upReference = normalizeDirection(upReference)
        if not isDirectionZero(upReference) and dot(up, upReference) < 0 then
            right = { x = -right.x, y = -right.y, z = -right.z }
            up = { x = -up.x, y = -up.y, z = -up.z }
        end

        table.insert(frames, {
            position = { x = point.x, y = point.y, z = point.z },
            right = right,
            forward = forward,
            up = up,
            isControlPoint = sampleInfo[index] and sampleInfo[index].isControlPoint == true or false,
            controlPointIndex = sampleInfo[index] and sampleInfo[index].controlPointIndex or nil
        })

        lastRight = right
    end

    if #frames == 0 then
        frames = {
            {
                position = { x = 0, y = 0, z = 0 },
                right = { x = 1, y = 0, z = 0 },
                forward = { x = 0, y = 1, z = 0 },
                up = { x = 0, y = 0, z = 1 },
                isControlPoint = true,
                controlPointIndex = 1
            }
        }
    end

    return frames
end

function bendedMesh:frameToMatrix(frame)
    local right = frame.right or { x = 1, y = 0, z = 0 }
    local forward = frame.forward or { x = 0, y = 1, z = 0 }
    local up = frame.up or { x = 0, y = 0, z = 1 }
    local position = frame.position or { x = 0, y = 0, z = 0 }

    return {
        X = Vector4.new(right.x, right.y, right.z, 0),
        Y = Vector4.new(forward.x, forward.y, forward.z, 0),
        Z = Vector4.new(up.x, up.y, up.z, 0),
        W = Vector4.new(position.x, position.y, position.z, 1),
        isControlPoint = frame.isControlPoint == true,
        controlPointIndex = frame.controlPointIndex
    }
end

function bendedMesh:rebuildMatricesFromPath(updateBox)
    local frames = self:getSampledPathFrames()
    local matrices = {}
    for _, frame in ipairs(frames) do
        table.insert(matrices, self:frameToMatrix(frame))
    end

    if updateBox then
        self:autoFitDeformedBox(frames)
    end

    return matrices
end

function bendedMesh:matrixToPreviewFrame(matrix)
    local axisX = normalizeDirection({
        x = utils.toNumber(matrix and matrix.X and (matrix.X.x or matrix.X.X), 1),
        y = utils.toNumber(matrix and matrix.X and (matrix.X.y or matrix.X.Y), 0),
        z = utils.toNumber(matrix and matrix.X and (matrix.X.z or matrix.X.Z), 0)
    })
    local axisY = normalizeDirection({
        x = utils.toNumber(matrix and matrix.Y and (matrix.Y.x or matrix.Y.X), 0),
        y = utils.toNumber(matrix and matrix.Y and (matrix.Y.y or matrix.Y.Y), 1),
        z = utils.toNumber(matrix and matrix.Y and (matrix.Y.z or matrix.Y.Z), 0)
    })
    local axisZ = normalizeDirection({
        x = utils.toNumber(matrix and matrix.Z and (matrix.Z.x or matrix.Z.X), 0),
        y = utils.toNumber(matrix and matrix.Z and (matrix.Z.y or matrix.Z.Y), 0),
        z = utils.toNumber(matrix and matrix.Z and (matrix.Z.z or matrix.Z.Z), 1)
    })
    local position = {
        x = utils.toNumber(matrix and matrix.W and (matrix.W.x or matrix.W.X), 0),
        y = utils.toNumber(matrix and matrix.W and (matrix.W.y or matrix.W.Y), 0),
        z = utils.toNumber(matrix and matrix.W and (matrix.W.z or matrix.W.Z), 0)
    }

    if isDirectionZero(axisX) then axisX = { x = 1, y = 0, z = 0 } end
    if isDirectionZero(axisY) then axisY = { x = 0, y = 1, z = 0 } end
    if isDirectionZero(axisZ) then axisZ = { x = 0, y = 0, z = 1 } end

    return {
        position = position,
        right = axisX,
        forward = axisY,
        up = axisZ,
        isControlPoint = matrix and matrix.isControlPoint == true,
        controlPointIndex = matrix and matrix.controlPointIndex or nil
    }
end

function bendedMesh:getPreviewFramesFromMatrices(matrices)
    local frames = {}
    for _, matrix in ipairs(matrices or {}) do
        table.insert(frames, self:matrixToPreviewFrame(matrix))
    end

    if #frames == 0 then
        return {
            {
                position = { x = 0, y = 0, z = 0 },
                right = { x = 1, y = 0, z = 0 },
                forward = { x = 0, y = 1, z = 0 },
                up = { x = 0, y = 0, z = 1 },
                isControlPoint = true,
                controlPointIndex = 1
            }
        }
    end

    return frames
end

---Rebuilds the editor path from a set of deformation matrices, inverting
---`rebuildMatricesFromPath`. One matrix is one path point: its W column is the point itself, and
---the twist of its up axis against the untwisted basis of the same forward direction is the
---point's roll. Every rebuilt point comes back anchored, so the path algorithm leaves an
---imported deformation exactly as it was authored.
---@param matrices table Deformation matrices, in node order.
---@param upAxisIndex integer? Up axis to read the twist against, `World Z` by default.
---@return table pathPoints
function bendedMesh.pathPointsFromMatrices(matrices, upAxisIndex)
    local clampedUpAxisIndex = math.max(0, math.min(math.floor(utils.toNumber(upAxisIndex, 0)), #pathUpAxisOptions - 1))
    local upHint = getPathUpAxis(clampedUpAxisIndex)
    local pathPoints = {}

    for _, matrix in ipairs(matrices or {}) do
        local frame = bendedMesh:matrixToPreviewFrame(matrix)
        local _, _, untwistedUp = buildBasisFromForward(frame.forward, upHint)
        local twist = cross(untwistedUp, frame.up)
        local roll = math.deg(math.atan2(dot(twist, frame.forward), dot(untwistedUp, frame.up)))

        if math.abs(roll) < 0.001 then
            roll = 0
        end

        table.insert(pathPoints, {
            x = frame.position.x,
            y = frame.position.y,
            z = frame.position.z,
            roll = roll,
            anchored = true
        })
    end

    return pathPoints
end

---Pool of host entities the path preview lives on. A long path draws far more components than
---one entity can hold, and all four families (segments, control points, subdivisions, frames)
---share that ceiling, so none of them live on the mesh entity itself.
---@return previewHostPool
function bendedMesh:getPathPreviewHosts()
    if not self._pathPreviewHosts then
        self._pathPreviewHosts = previewHosts.new(PATH_PREVIEW_COMPONENTS_PER_HOST, function ()
            self:updatePathVisualization()
        end)
    end

    return self._pathPreviewHosts
end

function bendedMesh:getPathPreviewComponent(name, meshPath, appearance)
    if not self:getEntity() then
        return nil
    end

    local host = self:getPathPreviewHosts():hostForName(name, self.position, self.rotation)
    if not host then
        return nil
    end

    local component = host:FindComponentByName(name)
    if component then
        return component
    end

    if appearance == "green" then
        appearance = "lime"
    end

    component = entMeshComponent.new()
    component.name = name
    component.mesh = ResRef.FromString(meshPath)
    component.meshAppearance = appearance or "default"
    component.visualScale = Vector3.new(0.01, 0.01, 0.01)
    component.isEnabled = false

    -- Keep preview components bound to a stable placed parent so runtime-added
    -- components retain valid local transforms (same pattern as visualizer.lua).
    visualizer.bindToPlacedParent(host, component)

    host:AddComponent(component)
    return component
end

function bendedMesh:togglePathPreviewComponent(name, state)
    local component = self:getPathPreviewHosts():findComponentByName(name)

    if component then
        component:Toggle(state)
    end
end

function bendedMesh:despawn()
    self:getPathPreviewHosts():despawn()
    mesh.despawn(self)
end

function bendedMesh:update()
    mesh.update(self)
    -- Hosts hold the preview in mesh-local coordinates, so they follow the mesh when it moves.
    self:getPathPreviewHosts():updateTransforms(self.position, self.rotation)
end

function bendedMesh:hidePathPreviewOverflow(prefix, used, previousCount)
    for i = used + 1, previousCount do
        self:togglePathPreviewComponent(prefix .. tostring(i), false)
    end
end

function bendedMesh:toScaledLocalPoint(point)
    local scale = self.scale or { x = 1, y = 1, z = 1 }
    return {
        x = point.x * scale.x,
        y = point.y * scale.y,
        z = point.z * scale.z
    }
end

function bendedMesh:getPathPreviewFrameLength()
    local extentX = math.abs((self.bBox.max and self.bBox.max.x or 0.5) - (self.bBox.min and self.bBox.min.x or -0.5))
    local extentY = math.abs((self.bBox.max and self.bBox.max.y or 0.5) - (self.bBox.min and self.bBox.min.y or -0.5))
    local extentZ = math.abs((self.bBox.max and self.bBox.max.z or 0.5) - (self.bBox.min and self.bBox.min.z or -0.5))
    local maxExtent = math.max(extentX, extentY, extentZ, 0.1)

    return math.max(0.02, math.min(4, maxExtent * PATH_PREVIEW_FRAME_LENGTH))
end

function bendedMesh:getMeshWidthRange()
    local minX = self.bBox and self.bBox.min and self.bBox.min.x or -0.5
    local maxX = self.bBox and self.bBox.max and self.bBox.max.x or 0.5

    if minX > maxX then
        minX, maxX = maxX, minX
    end

    if math.abs(maxX - minX) < 0.0001 then
        minX = -0.5
        maxX = 0.5
    end

    return minX, maxX
end

function bendedMesh:renderPathPreviewLine(namePrefix, index, startPoint, endPoint, appearance, thickness)
    local component = self:getPathPreviewComponent(namePrefix .. tostring(index), "base\\spawner\\cube_aligned.mesh", appearance)
    if not component then
        return false
    end

    local diff = {
        x = endPoint.x - startPoint.x,
        y = endPoint.y - startPoint.y,
        z = endPoint.z - startPoint.z
    }
    local length = utils.distanceVector(zeroVector3, diff)
    if length <= 0.0001 then
        component:Toggle(false)
        return false
    end

    local direction = Vector4.new(diff.x, diff.y, diff.z, 0)
    local rotation = direction:ToRotation()
    local yaw = rotation.yaw + 90
    local roll = rotation.pitch

    component.visualScale = Vector3.new(math.max(0.0001, length / 2), thickness, thickness)
    component:SetLocalOrientation(EulerAngles.new(roll, 0, yaw):ToQuat())
    component:SetLocalPosition(Vector4.new(startPoint.x, startPoint.y, startPoint.z, 0))
    component:Toggle(true)
    component:RefreshAppearance()

    return true
end

function bendedMesh:renderPathControlPoint(index, point)
    local component = self:getPathPreviewComponent("bendPathCtrl" .. tostring(index), "base\\environment\\ld_kit\\marker.mesh", "yellow")
    if not component then
        return false
    end

    local scaledPoint = self:toScaledLocalPoint(point)
    component.visualScale = Vector3.new(PATH_PREVIEW_POINT_SCALE, PATH_PREVIEW_POINT_SCALE, PATH_PREVIEW_POINT_SCALE)
    component:SetLocalPosition(Vector4.new(scaledPoint.x, scaledPoint.y, scaledPoint.z, 0))
    component:SetLocalOrientation(EulerAngles.new(0, 0, 0):ToQuat())
    component:Toggle(true)
    component:RefreshAppearance()

    return true
end

function bendedMesh:renderPathSubdivisionMarker(index, frame, xMin, xMax, thickness, color)
    local originLocal = frame.position or { x = 0, y = 0, z = 0 }
    local axisX = normalizeDirection(frame.right or { x = 1, y = 0, z = 0 })
    if isDirectionZero(axisX) then
        axisX = { x = 1, y = 0, z = 0 }
    end

    local startLocal = {
        x = originLocal.x + axisX.x * xMin,
        y = originLocal.y + axisX.y * xMin,
        z = originLocal.z + axisX.z * xMin
    }
    local endLocal = {
        x = originLocal.x + axisX.x * xMax,
        y = originLocal.y + axisX.y * xMax,
        z = originLocal.z + axisX.z * xMax
    }

    local startPoint = self:toScaledLocalPoint(startLocal)
    local endPoint = self:toScaledLocalPoint(endLocal)

    return self:renderPathPreviewLine("bendPathDirMain", index, startPoint, endPoint, color or "red", thickness)
end

function bendedMesh:renderPathFrameWithPrefix(prefix, index, frame, axisLength, thickness, options)
    local originLocal = frame.position or { x = 0, y = 0, z = 0 }
    local axisX = normalizeDirection(frame.right or { x = 1, y = 0, z = 0 })
    local axisY = normalizeDirection(frame.forward or { x = 0, y = 1, z = 0 })
    local axisZ = normalizeDirection(frame.up or { x = 0, y = 0, z = 1 })

    if isDirectionZero(axisX) then axisX = { x = 1, y = 0, z = 0 } end
    if isDirectionZero(axisY) then axisY = { x = 0, y = 1, z = 0 } end
    if isDirectionZero(axisZ) then axisZ = { x = 0, y = 0, z = 1 } end

    local xMin = options and options.xRangeMin
    local xMax = options and options.xRangeMax
    local hasWidthRange = xMin ~= nil and xMax ~= nil
    local xStartLocal = hasWidthRange and {
        x = originLocal.x + axisX.x * xMin,
        y = originLocal.y + axisX.y * xMin,
        z = originLocal.z + axisX.z * xMin
    } or originLocal
    local xEndLocal = hasWidthRange and {
        x = originLocal.x + axisX.x * xMax,
        y = originLocal.y + axisX.y * xMax,
        z = originLocal.z + axisX.z * xMax
    } or {
        x = originLocal.x + axisX.x * axisLength,
        y = originLocal.y + axisX.y * axisLength,
        z = originLocal.z + axisX.z * axisLength
    }
    local yEndLocal = {
        x = originLocal.x + axisY.x * axisLength,
        y = originLocal.y + axisY.y * axisLength,
        z = originLocal.z + axisY.z * axisLength
    }
    local zEndLocal = {
        x = originLocal.x + axisZ.x * axisLength,
        y = originLocal.y + axisZ.y * axisLength,
        z = originLocal.z + axisZ.z * axisLength
    }

    local origin = self:toScaledLocalPoint(originLocal)
    local xStart = self:toScaledLocalPoint(xStartLocal)
    local xEnd = self:toScaledLocalPoint(xEndLocal)
    local yEnd = self:toScaledLocalPoint(yEndLocal)
    local zEnd = self:toScaledLocalPoint(zEndLocal)

    local colorX = options and options.uniformColor or "red"
    local colorY = options and options.uniformColor or "green"
    local colorZ = options and options.uniformColor or "blue"
    local drawn = false
    drawn = self:renderPathPreviewLine(prefix .. "X", index, xStart, xEnd, colorX, thickness) or drawn
    drawn = self:renderPathPreviewLine(prefix .. "Y", index, origin, yEnd, colorY, thickness) or drawn
    drawn = self:renderPathPreviewLine(prefix .. "Z", index, origin, zEnd, colorZ, thickness) or drawn

    return drawn
end

function bendedMesh:renderPathFrame(index, frame, axisLength, thickness, options)
    return self:renderPathFrameWithPrefix("bendPathFrame", index, frame, axisLength, thickness, options)
end

function bendedMesh:hideFrameTriplet(prefix, index)
    self:togglePathPreviewComponent(prefix .. "X" .. tostring(index), false)
    self:togglePathPreviewComponent(prefix .. "Y" .. tostring(index), false)
    self:togglePathPreviewComponent(prefix .. "Z" .. tostring(index), false)
end

function bendedMesh:updatePathVisualization()
    local entity = self:getEntity()
    if not entity then return end
    self:ensurePathPoints()

    local showPreview = (not self.isAssetPreview) and self.pathPreviewEnabled
    if not showPreview then
        -- Despawning the hosts drops every preview component with them, which is cheaper than
        -- hiding them one by one and leaves nothing behind while the preview is off.
        self:getPathPreviewHosts():despawn()
        self.pathPreviewSegmentCount = 0
        self.pathPreviewControlCount = 0
        self.pathPreviewSubdivisionCount = 0
        self.pathPreviewFrameCount = 0
        return
    end

    local segmentThickness = PATH_PREVIEW_LINE_THICKNESS
    local looped = self.pathLooped and #self.pathPoints > 2
    local matrices = self:rebuildMatricesFromPath(false)
    local frames = self:getPreviewFramesFromMatrices(matrices)
    local widthMin, widthMax = self:getMeshWidthRange()
    local previousSegmentCount = self.pathPreviewSegmentCount
    local previousControlCount = self.pathPreviewControlCount
    local previousSubdivisionCount = self.pathPreviewSubdivisionCount
    local previousFrameCount = self.pathPreviewFrameCount

    local usedSegments = 0
    local requiredSegments = 0
    if #frames > 1 then
        requiredSegments = (#frames - 1) + (looped and 1 or 0)
    end

    -- Spawn every host this pass needs up front, so a path that just grew converges in a single
    -- redraw instead of one per host. Overshooting only costs a host the trim below gives back.
    local requiredFrameComponents = 0
    if self.pathPreviewShowFrames then
        requiredFrameComponents = math.min(#frames, PATH_PREVIEW_MAX_SEGMENTS)
            + 3 * math.min(#frames, PATH_PREVIEW_MAX_FRAMES) + 3
    end
    self:getPathPreviewHosts():ensure(requiredSegments + #self.pathPoints + requiredFrameComponents, self.position, self.rotation)
    local maxSegments = requiredSegments

    if #frames > 1 and maxSegments > 0 then
        for i = 1, #frames - 1 do
            if usedSegments >= maxSegments then break end
            local startPoint = self:toScaledLocalPoint(frames[i].position)
            local endPoint = self:toScaledLocalPoint(frames[i + 1].position)
            local nextIndex = usedSegments + 1
            if self:renderPathPreviewLine("bendPathSeg", nextIndex, startPoint, endPoint, "cyan", segmentThickness) then
                usedSegments = nextIndex
            end
        end

        if looped and usedSegments < maxSegments then
            local startPoint = self:toScaledLocalPoint(frames[#frames].position)
            local endPoint = self:toScaledLocalPoint(frames[1].position)
            local nextIndex = usedSegments + 1
            if self:renderPathPreviewLine("bendPathSeg", nextIndex, startPoint, endPoint, "cyan", segmentThickness) then
                usedSegments = nextIndex
            end
        end
    end

    self:hidePathPreviewOverflow("bendPathSeg", usedSegments, previousSegmentCount)
    self.pathPreviewSegmentCount = usedSegments

    local usedControls = 0
    local maxControls = #self.pathPoints

    for _, frame in ipairs(frames) do
        if usedControls >= maxControls then break end
        if frame and frame.isControlPoint and frame.position then
            local nextIndex = usedControls + 1
            if self:renderPathControlPoint(nextIndex, frame.position) then
                usedControls = nextIndex
            end
        end
    end

    self:hidePathPreviewOverflow("bendPathCtrl", usedControls, previousControlCount)
    self.pathPreviewControlCount = usedControls

    if self.pathPreviewShowFrames then
        local frameLength = self:getPathPreviewFrameLength()
        local frameThickness = math.max(0.002, segmentThickness * 0.75)
        local subdivisionThickness = math.max(0.0015, frameThickness * 0.85)
        local usedSubdivisions = 0
        local maxSubdivisions = PATH_PREVIEW_MAX_SEGMENTS

        if maxSubdivisions > 0 then
            for _, frame in ipairs(frames) do
                if usedSubdivisions >= maxSubdivisions then break end
                if frame and not frame.isControlPoint then
                    local nextIndex = usedSubdivisions + 1
                    if self:renderPathSubdivisionMarker(nextIndex, frame, widthMin, widthMax, subdivisionThickness, "red") then
                        usedSubdivisions = nextIndex
                    end
                end
            end
        end

        self:hidePathPreviewOverflow("bendPathDirMain", usedSubdivisions, previousSubdivisionCount)
        self.pathPreviewSubdivisionCount = usedSubdivisions

        local usedFrames = 0
        local maxFrames = PATH_PREVIEW_MAX_FRAMES
        for _, frame in ipairs(frames) do
            if usedFrames >= maxFrames then break end
            if frame and frame.isControlPoint then
                local nextIndex = usedFrames + 1
                if self:renderPathFrame(nextIndex, frame, frameLength, frameThickness, {
                    xRangeMin = widthMin,
                    xRangeMax = widthMax
                }) then
                    usedFrames = nextIndex
                end
            end
        end

        for i = usedFrames + 1, previousFrameCount do
            self:hideFrameTriplet("bendPathFrame", i)
        end
        self.pathPreviewFrameCount = usedFrames

        if #frames > 0 then
            local focusFrame = nil

            for _, frame in ipairs(frames) do
                if frame.controlPointIndex == PATH_PREVIEW_FOCUS_POINT then
                    focusFrame = frame
                    break
                end
            end

            if not focusFrame then
                focusFrame = frames[1]
            end

            if focusFrame then
                self:renderPathFrameWithPrefix("bendPathFocusFrame", 1, focusFrame, frameLength, math.max(0.002, frameThickness * 1.1), {
                    xRangeMin = widthMin,
                    xRangeMax = widthMax
                })
            else
                self:hideFrameTriplet("bendPathFocusFrame", 1)
            end
        else
            self:hideFrameTriplet("bendPathFocusFrame", 1)
        end
    else
        self:hidePathPreviewOverflow("bendPathDirMain", 0, previousSubdivisionCount)
        self:hideFrameTriplet("bendPathFocusFrame", 1)

        for i = 1, previousFrameCount do
            self:hideFrameTriplet("bendPathFrame", i)
        end
        self.pathPreviewSubdivisionCount = 0
        self.pathPreviewFrameCount = 0
    end

    local hosts = self:getPathPreviewHosts()
    if not hosts.pending then
        hosts:trim(math.max(1, hosts:getChunkCount(hosts.nextSlot)))
    end
end

function bendedMesh:autoFitDeformedBox(frames)
    local baseMin = self.bBox and self.bBox.min or Vector4.new(-0.5, -0.5, -0.5, 0)
    local baseMax = self.bBox and self.bBox.max or Vector4.new(0.5, 0.5, 0.5, 0)
    frames = frames or self:getSampledPathFrames()

    local corners = {
        Vector4.new(baseMin.x, baseMin.y, baseMin.z, 1),
        Vector4.new(baseMax.x, baseMin.y, baseMin.z, 1),
        Vector4.new(baseMin.x, baseMax.y, baseMin.z, 1),
        Vector4.new(baseMax.x, baseMax.y, baseMin.z, 1),
        Vector4.new(baseMin.x, baseMin.y, baseMax.z, 1),
        Vector4.new(baseMax.x, baseMin.y, baseMax.z, 1),
        Vector4.new(baseMin.x, baseMax.y, baseMax.z, 1),
        Vector4.new(baseMax.x, baseMax.y, baseMax.z, 1)
    }

    local transformed = {}
    for _, frame in ipairs(frames) do
        for _, corner in ipairs(corners) do
            table.insert(transformed, transformPointWithFrame(frame, corner))
        end
    end

    if #transformed == 0 then
        self.deformedBox = copyDeformedBox(nil)
        return
    end

    local minimum, maximum = utils.getVector4BBox(transformed)
    minimum.w = 1
    maximum.w = 1
    self.deformedBox = {
        min = minimum,
        max = maximum
    }
end

function bendedMesh:drawAppearanceSelector()
    local list = self.apps
    style.pushGreyedOut(#self.apps <= 1)

    if #list == 0 then
        list = { "No apps" }
    end

    style.mutedText("Appearance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.appSearch = self.appSearch or ""
    local selectedApp = self.app
    if selectedApp == nil or selectedApp == "" then
        selectedApp = list[1] or "default"
    end

    local changed
    selectedApp, self.appSearch, changed = style.trackedSearchDropdown(
        "##bendedApp",
        "Search appearance...",
        selectedApp,
        self.appSearch,
        list,
        {
            element = self.object,
            width = 180,
            matchContentWidth = true,
            tooltip = "Select the mesh appearance"
        }
    )

    if changed and #self.apps > 0 then
        self.app = selectedApp
        self.appIndex = math.max(utils.indexValue(self.apps, self.app) - 1, 0)

        local entity = self:getEntity()
        if entity then
            local component = entity:FindComponentByName("mesh")
            if component then
                component.meshAppearance = CName.new(self.app)
                component:LoadAppearance()
                self:setOutline(self.outline)
            end
        end
    end

    ImGui.SameLine()
    ImGui.BeginDisabled(#self.apps <= 1)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.SkipNext .. "##cycleBendedAppearance") then
        self:cycleAppearance()
    end
    style.pushButtonNoBG(false)
    ImGui.EndDisabled()
    style.tooltip("Select the next mesh appearance. Wraps to the first appearance at the end of the list.")
    style.popGreyedOut(#self.apps <= 1)
    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload .. "##reloadBendedAppearanceList") then
        self:reloadAppearances()
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reload appearance list for this asset and refresh cached data.")
end

function bendedMesh:refreshArrowScale()
    local entity = self:getEntity()
    if not entity then return end

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    self:setOutline(self.outline)
    self:updatePathVisualization()
end

function bendedMesh:drawPathPointEditor(index, point, pointCount)
    local changedAny = false
    local anyAnchorChanged = false
    local changed
    local forcedAnchored = index == 1 or index == pointCount
    local anchored = forcedAnchored or point.anchored == true

    if forcedAnchored then
        point.anchored = true
        
        ImGui.BeginDisabled(true)
        style.pushStyleColor(true, ImGuiCol.Text, 0.25, 0.62, 0.97, 1.0)
        style.toggleButton(IconGlyphs.Anchor .. "##pathPointAnchor" .. tostring(index), anchored)
        style.popStyleColor(true)
        style.tooltip("First and last points are always anchored.")
        ImGui.EndDisabled()
    else
        style.pushStyleColor(anchored, ImGuiCol.Text, 0.25, 0.62, 0.97, 1.0)
        local nextAnchored, clicked = style.toggleButton(IconGlyphs.Anchor .. "##pathPointAnchor" .. tostring(index), anchored)
        style.popStyleColor(anchored)
        if clicked then
            history.addAction(history.getElementChange(self.object))
            point.anchored = nextAnchored == true
            anchored = point.anchored == true
            changedAny = true
            anyAnchorChanged = true
        end
        style.tooltip(anchored and "Anchored point" or "Non-anchored point")
    end

    ImGui.SameLine()
    ImGui.BeginDisabled(not anchored)

    point.x, changed, _ = field.advancedTrackedFloat(self.object, "##pathPointX" .. tostring(index), point.x, {suffix = " X", width = 60})
    changedAny = changedAny or changed
    ImGui.SameLine()
    point.y, changed, _ = field.advancedTrackedFloat(self.object, "##pathPointY" .. tostring(index), point.y, {suffix = " Y", width = 60})
    changedAny = changedAny or changed
    ImGui.SameLine()
    point.z, changed, _ = field.advancedTrackedFloat(self.object, "##pathPointZ" .. tostring(index), point.z, {suffix = " Z", width = 60})
    changedAny = changedAny or changed

    ImGui.SameLine()
    ImGui.Dummy(8 * style.viewSize, 0)
    ImGui.SameLine()
    point.roll, changed, _ = field.advancedTrackedFloat(self.object, "##pathPointRoll" .. tostring(index), point.roll, {suffix = " Roll"})
    changedAny = changedAny or changed
    style.tooltip("Roll in degrees around the local forward axis.")

    ImGui.SameLine()
    ImGui.Dummy(8 * style.viewSize, 0)
    ImGui.EndDisabled()

    return changedAny, anyAnchorChanged
end

function bendedMesh:drawPathVisualizationSettings()
    if not ImGui.TreeNodeEx("Visualization", ImGuiTreeNodeFlags.SpanFullWidth) then
        return false
    end

    self:ensurePathPoints()

    local changedAny = false
    local changed

    style.mutedText("In-World Path Viz")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.pathPreviewEnabled, changed = style.trackedCheckbox(self.object, "##pathPreviewEnabled", self.pathPreviewEnabled)
    changedAny = changedAny or changed
    style.tooltip("Show path overlays (points, segments, and local frames) in the world.")

    style.mutedText("Show Local Frames")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.pathPreviewShowFrames, changed = style.trackedCheckbox(self.object, "##pathPreviewShowFrames", self.pathPreviewShowFrames, not self.pathPreviewEnabled)
    changedAny = changedAny or changed

    ImGui.TreePop()
    return changedAny
end

function bendedMesh:drawPathEditor()
    self:ensurePathPoints()
    self:applyPathAlgorithmToNonAnchored()

    local pathVisualizationNeedsUpdate = false
    local pathTopologyChanged = false
    local meshBonesQuantity = self:getMeshBonesQuantity()
    local canEditPointCount = meshBonesQuantity == nil
    local changed

    style.mutedText("Up Axis")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.pathUpAxis, changed = style.trackedCombo(self.object, "##pathUpAxis", self.pathUpAxis, pathUpAxisOptions, 160, {
        tooltip = "Reference axis for constructing local right/up basis from path direction"
    })
    pathVisualizationNeedsUpdate = pathVisualizationNeedsUpdate or changed

    style.mutedText("Loop Path")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.pathLooped, changed = style.trackedCheckbox(self.object, "##pathLooped", self.pathLooped)
    pathVisualizationNeedsUpdate = pathVisualizationNeedsUpdate or changed
    pathTopologyChanged = pathTopologyChanged or changed

    style.mutedText("Use Algorithm")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.pathUseAlgorithm, changed = style.trackedCheckbox(self.object, "##pathUseAlgorithm", self.pathUseAlgorithm)
    if changed and self.pathUseAlgorithm then
        self:applyPathAlgorithmToNonAnchored()
    end
    pathVisualizationNeedsUpdate = pathVisualizationNeedsUpdate or changed
    style.tooltip("When enabled, non-anchored points are computed from anchored points.")

    if self.pathUseAlgorithm then
        style.mutedText("Path Algorithm")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.pathInterpolation, changed = style.trackedCombo(self.object, "##pathInterpolation", self.pathInterpolation, pathInterpolationOptions, 180, {
            tooltip = "Linear interpolates non-anchored points between anchors.\nCatmull-Rom smooths with cubic interpolation.\nBezier builds smooth segments from neighboring anchors using auto handles."
        })
        if changed then
            self.pathInterpolation = math.max(0, math.min(math.floor(self.pathInterpolation), #pathInterpolationOptions - 1))
            self:applyPathAlgorithmToNonAnchored()
        end
        pathVisualizationNeedsUpdate = pathVisualizationNeedsUpdate or changed
    end

    ImGui.Dummy(0, 8 * style.viewSize)
    style.mutedText("Mesh bones quantity : " .. (meshBonesQuantity and tostring(meshBonesQuantity) or "Unknown") .. " " .. IconGlyphs.Bone)
    style.tooltip("Each bended mesh has a rig with specific number of bones.\nEach deformation point refers to a mesh bone.")

    for index, point in ipairs(self.pathPoints) do
        ImGui.PushID(index)
        local deleteRequested = false

        if index == 1 then
            ImGui.Text(IconGlyphs.SourceCommitStart)
        elseif index == #self.pathPoints then
            ImGui.Text(IconGlyphs.SourceCommitEnd)
        else
            ImGui.Text(IconGlyphs.SourceCommit)
        end

        ImGui.SameLine()
        style.mutedText(tostring(index))
        ImGui.SameLine()
        ImGui.SetCursorPosX(120)

        local pointChanged, anchorChanged = self:drawPathPointEditor(index, point, #self.pathPoints)
        pathVisualizationNeedsUpdate = pathVisualizationNeedsUpdate or pointChanged
        pathTopologyChanged = pathTopologyChanged or anchorChanged

        if canEditPointCount then
            local canInsertPoint = index < #self.pathPoints
            ImGui.BeginDisabled(not canInsertPoint)
            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.PlusCircleMultipleOutline) and canInsertPoint then
                history.addAction(history.getElementChange(self.object))
                local midpoint = lerpPathPoint(point, self.pathPoints[index + 1], 0.5)
                midpoint.anchored = false
                table.insert(self.pathPoints, index + 1, midpoint)
                self:ensurePathPoints()
                pathVisualizationNeedsUpdate = true
                pathTopologyChanged = true
            end
            ImGui.EndDisabled()
            style.tooltip("Insert a deformation point between this and the next point")
        end

        ImGui.SameLine()
        ImGui.BeginDisabled(index == 1 or not point.anchored)
        if ImGui.Button(IconGlyphs.ArrowUp) and index > 1 then
            history.addAction(history.getElementChange(self.object))
            self.pathPoints[index], self.pathPoints[index - 1] = self.pathPoints[index - 1], self.pathPoints[index]
            self:ensurePathPoints()
            pathVisualizationNeedsUpdate = true
            pathTopologyChanged = true
        end
        ImGui.EndDisabled()
        style.tooltip("Move the point before")

        ImGui.SameLine()
        ImGui.BeginDisabled(index == #self.pathPoints or not point.anchored)
        if ImGui.Button(IconGlyphs.ArrowDown) and index < #self.pathPoints then
            history.addAction(history.getElementChange(self.object))
            self.pathPoints[index], self.pathPoints[index + 1] = self.pathPoints[index + 1], self.pathPoints[index]
            self:ensurePathPoints()
            pathVisualizationNeedsUpdate = true
            pathTopologyChanged = true
        end
        ImGui.EndDisabled()
        style.tooltip("Move the point after")

        if canEditPointCount then
            ImGui.SameLine()
            local canRemove = #self.pathPoints > 1
            ImGui.BeginDisabled(not canRemove)
            if style.dangerButton(IconGlyphs.DeleteOutline) and canRemove then
                deleteRequested = true
            end
            ImGui.EndDisabled()
        end

        ImGui.PopID()

        if deleteRequested then
            history.addAction(history.getElementChange(self.object))
            table.remove(self.pathPoints, index)
            self:ensurePathPoints()
            pathVisualizationNeedsUpdate = true
            pathTopologyChanged = true
            break
        end
    end

    if canEditPointCount then
        if ImGui.Button(IconGlyphs.PlusCircleOutline) then
            history.addAction(history.getElementChange(self.object))
            table.insert(self.pathPoints, self:makeDefaultPathPointAfterCurrent(#self.pathPoints))
            self:ensurePathPoints()
            pathVisualizationNeedsUpdate = true
            pathTopologyChanged = true
        end
        style.tooltip("Add a new deformation point at the end.")
    end
    ImGui.Dummy(0, 8 * style.viewSize)

    if pathVisualizationNeedsUpdate then
        self:ensurePathPoints()
        self:applyPathAlgorithmToNonAnchored()
        self:autoFitDeformedBox()
        self:refreshArrowScale()

        -- In-world visualization needs a respawn to append newly added components.
        if pathTopologyChanged and self:isSpawned() then
            self:respawn()
        end
    end
end

function bendedMesh:drawDeformationMatrices()
    if not ImGui.TreeNodeEx("Path Deformation", ImGuiTreeNodeFlags.SpanFullWidth) then
        return
    end

    if ImGui.Button("Copy Data") then
        utils.insertClipboardValue(deformationClipboardKey, self:getDeformationClipboardPayload())
    end
    style.tooltip("Copy path deformation settings to clipboard for pasting into another bended mesh.")

    ImGui.SameLine()
    local clipboardPayload = utils.getClipboardValue(deformationClipboardKey)
    local canPaste = self:isDeformationClipboardPayloadValid(clipboardPayload)
    ImGui.BeginDisabled(not canPaste)
    if ImGui.Button("Paste Data") and canPaste then
        history.addAction(history.getElementChange(self.object))
        self:applyDeformationClipboardPayload(clipboardPayload)
    end
    ImGui.EndDisabled()
    style.tooltip("Paste copied path deformation data from another bended mesh.")

    local canCreateContinuation = self.object and self.object.parent and (not self.object:isLocked())
    ImGui.BeginDisabled(not canCreateContinuation)
    if ImGui.Button("Continue as New Mesh") and canCreateContinuation then
        self:createContinuationMesh()
    end
    ImGui.EndDisabled()
    style.tooltip("Create a new bended mesh aligned to this mesh end point, using the same asset and appearance.")

    self:drawPathEditor()

    ImGui.TreePop()
end

function bendedMesh:drawColliderGeneration()
    if not ImGui.TreeNodeEx("Collider Generation", ImGuiTreeNodeFlags.SpanFullWidth) then
        return
    end

    local changed

    style.mutedText("Collider Shape")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.bendedColliderShape, changed = style.trackedCombo(self.object, "##bendedColliderShape", self.bendedColliderShape, { "Box (Recommended)", "Capsule", "Sphere" }, 170, {
        tooltip = "Default is Box. Capsule and Sphere are available but less precise for bend following."
    })
    if changed then
        self.bendedColliderShape = math.max(0, math.min(2, math.floor(self.bendedColliderShape)))
    end

    style.mutedText("Splits / Segment")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.bendedColliderStep, changed, _ = style.trackedDragInt(self.object, "##bendedColliderStep", self.bendedColliderStep, 1, 16, 80)
    if changed then
        self.bendedColliderStep = math.max(1, math.min(16, math.floor(self.bendedColliderStep)))
    end
    style.tooltip("Splits each sampled segment into N colliders. Higher values follow bends more closely.")

    style.mutedText("Length Overlap")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.bendedColliderOverlap, changed, _ = style.trackedDragFloat(self.object, "##bendedColliderOverlap", self.bendedColliderOverlap, 0.005, 0, 0.5, "%.3f", 80)
    if changed then
        self.bendedColliderOverlap = math.max(0, math.min(0.5, self.bendedColliderOverlap))
    end
    style.tooltip("Extra segment length ratio to reduce gaps between generated colliders.")

    local canGenerate = self.object and self.object.parent and (not self.object:isLocked())
    ImGui.BeginDisabled(not canGenerate)
    if ImGui.Button("Generate Bended Colliders") and canGenerate then
        self:generateBendedColliders()
    end
    ImGui.EndDisabled()
    style.tooltip("Create collider chain that follows the bended deformation path.")

    ImGui.TreePop()
end

function bendedMesh:draw()
    if self.pendingAutoFit and self.bBoxLoaded then
        self:autoFitDeformedBox()
        self.pendingAutoFit = false
        self:refreshArrowScale()
    end

    spawnable.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({
            "Appearance",
            "Bended Road",
            "Remove From Rain Map",
            "Navigation Impact",
            "Cast Local Shadows",
            "Cast Shadows",
            "Looped Path",
            "Use Algorithm",
            "Path Algorithm",
            "Mesh bones quantity",
            "In-World Path Viz",
            "Show Local Frames",
            "Collider Shape",
            "Splits / Segment",
            "Length Overlap"
        }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    self:drawAppearanceSelector()

    style.mutedText("Bended Road")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.isBendedRoad, _ = style.trackedCheckbox(self.object, "##isBendedRoad", self.isBendedRoad)

    style.mutedText("Remove From Rain Map")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.removeFromRainMap, _ = style.trackedCheckbox(self.object, "##removeFromRainMap", self.removeFromRainMap)

    style.mutedText("Navigation Impact")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.navigationImpact = math.max(0, math.min(self.navigationImpact or 0, math.max(0, #self.navmeshImpactEnum - 1)))
    self.navigationImpact, _ = style.trackedCombo(self.object, "##navigationImpact", self.navigationImpact, self.navmeshImpactEnum, 160)

    style.mutedText("Cast Local Shadows")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local changed
    self.castLocalShadows, changed = style.trackedCombo(self.object, "##bendedCastLocalShadows", self.castLocalShadows, self.shadowCastingModeEnum, 120)
    self:updateShadowSettings(changed)

    style.mutedText("Cast Shadows")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.castShadows, changed = style.trackedCombo(self.object, "##bendedCastShadows", self.castShadows, self.shadowCastingModeEnum, 120)
    self:updateShadowSettings(changed)
    
    local visualizationChanged = self:drawPathVisualizationSettings()
    if visualizationChanged then
        self:refreshArrowScale()
    end
    self:drawDeformationMatrices()
    self:drawColliderGeneration()
    self:drawConversionSelector("##bendedMeshConverterType", "Lossy Conversion##bendedMeshSingle")
end

function bendedMesh:getProperties()
    return self:addNodeProperty(spawnable.getProperties(self))
end

function bendedMesh:getNormalizedDeformedBox()
    local min = self.deformedBox.min
    local max = self.deformedBox.max

    return {
        min = {
            x = math.min(min.x, max.x),
            y = math.min(min.y, max.y),
            z = math.min(min.z, max.z)
        },
        max = {
            x = math.max(min.x, max.x),
            y = math.max(min.y, max.y),
            z = math.max(min.z, max.z)
        }
    }
end

function bendedMesh:getSize()
    local box = self:getNormalizedDeformedBox()
    return utils.getBoxSize(box, self.scale)
end

function bendedMesh:getBBox()
    local box = self:getNormalizedDeformedBox()
    return utils.getScaledBBox(box, self.scale)
end

function bendedMesh:getCenter()
    local box = self:getNormalizedDeformedBox()
    return utils.getBoxCenter(box, self.scale, self.rotation, self.position)
end

function bendedMesh:calculateIntersection(origin, ray)
    if not self:getEntity() then
        return { hit = false }
    end

    local box = self:getNormalizedDeformedBox()
    local scaleFactor = intersection.getResourcePathScalingFactor(self.spawnData, self:getSize())

    local scaledBBox = utils.getScaledBBoxWithFactor(box, self.scale, scaleFactor)
    local result = intersection.getBoxIntersection(origin, ray, self.position, self.rotation, scaledBBox)

    local unscaledHit
    if result.hit then
        unscaledHit = intersection.getBoxIntersection(origin, ray, self.position, self.rotation, intersection.unscaleBBox(self.spawnData, self:getSize(), scaledBBox))
    end

    return {
        hit = result.hit,
        position = result.position,
        unscaledHit = unscaledHit and unscaledHit.position or result.position,
        collisionType = "bbox",
        distance = result.distance,
        bBox = scaledBBox,
        objectOrigin = self.position,
        objectRotation = self.rotation,
        normal = result.normal
    }
end

function bendedMesh:export()
    local matrices = self:rebuildMatricesFromPath(self.bBoxLoaded)

    local app = self.app
    if app == "" then
        app = "default"
    end

    local normalizedBox = self:getNormalizedDeformedBox()
    local data = spawnable.export(self)
    data.type = "worldBendedMeshNode"
    data.scale = self.scale
    data.data = {
        mesh = {
            DepotPath = {
                ["$storage"] = "string",
                ["$value"] = self.spawnData
            }
        },
        meshAppearance = {
            ["$storage"] = "string",
            ["$value"] = app
        },
        deformationData = {},
        deformedBox = {
            ["$type"] = "Box",
            Min = toTypedVector4(Vector4.new(normalizedBox.min.x, normalizedBox.min.y, normalizedBox.min.z, 1)),
            Max = toTypedVector4(Vector4.new(normalizedBox.max.x, normalizedBox.max.y, normalizedBox.max.z, 1))
        },
        isBendedRoad = self.isBendedRoad and 1 or 0,
        castShadows = self.shadowCastingModeEnum[self.castShadows + 1],
        castLocalShadows = self.shadowCastingModeEnum[self.castLocalShadows + 1],
        removeFromRainMap = self.removeFromRainMap and 1 or 0,
        navigationSetting = {
            ["$type"] = "NavGenNavigationSetting",
            navmeshImpact = self.navmeshImpactEnum[self.navigationImpact + 1] or "Road"
        },
        version = self.version or 0
    }

    for _, matrix in ipairs(matrices) do
        table.insert(data.data.deformationData, toTypedMatrix(matrix))
    end

    return data
end

return bendedMesh
