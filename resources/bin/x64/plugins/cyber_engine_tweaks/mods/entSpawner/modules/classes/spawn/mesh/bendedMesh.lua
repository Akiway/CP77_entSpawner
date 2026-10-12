local mesh = require("modules/classes/spawn/mesh/mesh")
local spawnable = require("modules/classes/spawn/spawnable")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local history = require("modules/utils/project/history")
local intersection = require("modules/utils/editor/intersection")
local visualizer = require("modules/utils/preview/visualizer")
local previewHosts = require("modules/utils/preview/previewHosts")
local bendedPool = require("modules/utils/preview/bendedPool")
local field = require("modules/utils/ui/field")
local cache = require("modules/utils/game/cache")
local bendedRig = require("modules/utils/game/bendedRig")

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

-- Stored 1-based: 1 = legacy (by index, chord end tangents), 2 = along the curve.
local PATH_SOLVER_LEGACY = 1
local PATH_SOLVER_CURVE = 2
local pathSolverOptions = {
    "By Index (Legacy)",
    "Along Curve"
}
local PATH_CURVE_SAMPLES_PER_BONE = 12

-- Stored 1-based. Curve: free control points, bones resampled along it. Bones: one point per bone.
local PATH_MODE_CURVE = 1
local PATH_MODE_BONES = 2
local pathModeOptions = {
    "Curve",
    "Bones (Advanced)"
}
local LENGTH_MODE_FIT = 1
local LENGTH_MODE_KEEP = 2
local lengthModeOptions = {
    "Fit to Curve",
    "Keep Rest Length"
}
local CURVE_SAMPLES_PER_SEGMENT = 48

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

---@param point table?
---@return table curvePoint `{ x, y, z, roll, dir?, lenIn?, lenOut? }`; `dir` set means a manual tangent.
local function copyCurvePoint(point)
    local source = point or {}
    local copy = {
        x = utils.toNumber(source.x, 0),
        y = utils.toNumber(source.y, 0),
        z = utils.toNumber(source.z, 0),
        roll = utils.toNumber(source.roll, 0)
    }

    if type(source.dir) == "table" then
        local dir = normalizeDirection({ x = utils.toNumber(source.dir.x, 0), y = utils.toNumber(source.dir.y, 0), z = utils.toNumber(source.dir.z, 0) })
        if not isDirectionZero(dir) then
            copy.dir = dir
            copy.lenIn = tonumber(source.lenIn)
            copy.lenOut = tonumber(source.lenOut)
        end
    end

    return copy
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

function bendedMesh:new()
    local o = mesh.new(self)

    o.dataType = "Bended Mesh"
    o.modulePath = "mesh/bendedMesh"
    o.spawnDataPath = "data/spawnables/mesh/bended/"
    o.node = "worldBendedMeshNode"
    o.description = "Places a world bended mesh node with path-based deformation editing and deformed bounding box."
    o.previewNote = "Deformation is previewed through a placeholder world node; without Red Hot Tools the mesh is shown undeformed."
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
    o.pathInterpolation = 1
    o.pathUpAxis = 0
    o.pathSolver = PATH_SOLVER_CURVE
    o.pathMode = PATH_MODE_CURVE
    o.pathLengthMode = LENGTH_MODE_FIT
    o.curvePoints = {}
    o.continuationRepeatShape = false
    o.importedDeformation = nil
    o.pathPreviewEnabled = true
    o.pathPreviewShowFrames = true
    o.deformedPreviewEnabled = true
    o.deformedPreviewSignature = nil
    o.deformedPreviewIssue = nil
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

    -- Paths saved before the solver existed keep the legacy placement they were authored with.
    local defaultSolver = (type(data.pathPoints) == "table" and #data.pathPoints > 0) and PATH_SOLVER_LEGACY or PATH_SOLVER_CURVE
    self.pathSolver = math.max(1, math.min(math.floor(utils.toNumber(data.pathSolver, defaultSolver)), #pathSolverOptions))
    self.continuationRepeatShape = utils.toBoolean(data.continuationRepeatShape, self.continuationRepeatShape)

    -- Paths saved before the curve editor existed open in the per-bone editor.
    local defaultMode = (type(data.pathPoints) == "table" and #data.pathPoints > 0 and type(data.curvePoints) ~= "table") and PATH_MODE_BONES or PATH_MODE_CURVE
    self.pathMode = math.max(1, math.min(math.floor(utils.toNumber(data.pathMode, defaultMode)), #pathModeOptions))
    self.pathLengthMode = math.max(1, math.min(math.floor(utils.toNumber(data.pathLengthMode, self.pathLengthMode)), #lengthModeOptions))
    self.curvePoints = {}
    for _, point in ipairs(type(data.curvePoints) == "table" and data.curvePoints or {}) do
        table.insert(self.curvePoints, copyCurvePoint(point))
    end
    self._curveKey = nil
    self.importedDeformation = type(data.importedDeformation) == "table" and data.importedDeformation or nil

    self.pathPreviewEnabled = utils.toBoolean(data.pathPreviewEnabled, self.pathPreviewEnabled)
    self.pathPreviewShowFrames = utils.toBoolean(data.pathPreviewShowFrames, self.pathPreviewShowFrames)
    self.deformedPreviewEnabled = utils.toBoolean(data.deformedPreviewEnabled, self.deformedPreviewEnabled)
    self.bendedColliderShape = math.max(0, math.min(2, math.floor(utils.toNumber(data.bendedColliderShape, self.bendedColliderShape))))
    self.bendedColliderStep = math.max(1, math.min(16, math.floor(utils.toNumber(data.bendedColliderStep, self.bendedColliderStep))))
    self.bendedColliderOverlap = math.max(0, math.min(0.5, utils.toNumber(data.bendedColliderOverlap, self.bendedColliderOverlap)))

    self.pathPoints = {}
    for _, point in ipairs(data.pathPoints or {}) do
        table.insert(self.pathPoints, copyPathPoint(point))
    end

    self:ensurePathPoints()
    self:requestRig()

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
    self:applyEntityMeshVisibility()
end

---@protected
---@param changed boolean
function bendedMesh:updateShadowSettings(changed)
    mesh.updateShadowSettings(self, changed)
    if not changed then return end

    self:applyEntityMeshVisibility()
    self:refreshDeformedPreview()
end

---@param direction integer?
---@return boolean changed
function bendedMesh:cycleAppearance(direction)
    local changed = mesh.cycleAppearance(self, direction)
    if changed then
        self:refreshDeformedPreview()
    end

    return changed
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
    data.pathSolver = self.pathSolver
    data.pathMode = self.pathMode
    data.pathLengthMode = self.pathLengthMode
    data.curvePoints = {}
    for _, point in ipairs(self.curvePoints or {}) do
        table.insert(data.curvePoints, copyCurvePoint(point))
    end
    data.continuationRepeatShape = self.continuationRepeatShape
    data.importedDeformation = self.importedDeformation
    data.pathPreviewEnabled = self.pathPreviewEnabled
    data.pathPreviewShowFrames = self.pathPreviewShowFrames
    data.deformedPreviewEnabled = self.deformedPreviewEnabled
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
        pathSolver = self.pathSolver,
        pathMode = self.pathMode,
        pathLengthMode = self.pathLengthMode,
        pathPoints = {},
        curvePoints = {}
    }

    for _, point in ipairs(self.pathPoints or {}) do
        table.insert(payload.pathPoints, copyPathPoint(point))
    end
    for _, point in ipairs(self.curvePoints or {}) do
        table.insert(payload.curvePoints, copyCurvePoint(point))
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
    if payload.pathSolver ~= nil then
        self.pathSolver = math.max(1, math.min(math.floor(utils.toNumber(payload.pathSolver, self.pathSolver)), #pathSolverOptions))
    end

    if payload.pathLengthMode ~= nil then
        self.pathLengthMode = math.max(1, math.min(math.floor(utils.toNumber(payload.pathLengthMode, self.pathLengthMode)), #lengthModeOptions))
    end

    -- A curve fits any rig, so it is pasted as a curve even across meshes with other bone counts.
    local hasCurve = payload.pathMode == PATH_MODE_CURVE and type(payload.curvePoints) == "table" and #payload.curvePoints >= 2
    self.pathPoints = {}
    if hasPath then
        for _, point in ipairs(payload.pathPoints) do
            table.insert(self.pathPoints, copyPathPoint(point))
        end
    end
    if hasCurve then
        self.pathMode = PATH_MODE_CURVE
        self.curvePoints = {}
        for _, point in ipairs(payload.curvePoints) do
            table.insert(self.curvePoints, copyCurvePoint(point))
        end
        self._curveKey = nil
    elseif hasPath then
        self.pathMode = PATH_MODE_BONES
    end
    self:ensurePathPoints()

    self:autoFitDeformedBox()

    self:refreshArrowScale()
    return true
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

---World pose of a path frame: position through T * R * S, axes through R * S, re-orthonormalized.
---@param frame table Path frame in local space.
---@return table frame `{ position, right, forward, up }` in world space.
function bendedMesh:pathFrameToWorld(frame)
    local quat = self.rotation:ToQuat()
    local scale = self.scale or { x = 1, y = 1, z = 1 }

    local function direction(v)
        local rotated = quat:Transform(Vector4.new(v.x * scale.x, v.y * scale.y, v.z * scale.z, 0))
        return { x = rotated.x, y = rotated.y, z = rotated.z }
    end

    local position = self:getWorldPointFromLocal(frame.position)
    local forward = normalizeDirection(direction(frame.forward))
    if isDirectionZero(forward) then
        forward = { x = 0, y = 1, z = 0 }
    end

    local right = normalizeDirection(cross(forward, direction(frame.up)))
    if isDirectionZero(right) then
        right = normalizeDirection(direction(frame.right))
    end
    if isDirectionZero(right) then
        right = { x = 1, y = 0, z = 0 }
    end

    return {
        position = { x = position.x, y = position.y, z = position.z },
        right = right,
        forward = forward,
        up = normalizeDirection(cross(right, forward))
    }
end

---Rotates a vector around world Z.
---@param v table
---@param degrees number
---@return table
local function rotateYaw(v, degrees)
    local angle = math.rad(degrees)
    local c, s = math.cos(angle), math.sin(angle)
    return { x = v.x * c - v.y * s, y = v.x * s + v.y * c, z = v.z }
end

---@param flat table
---@return table frame
local function frameFromFlat(flat)
    return {
        right = { x = flat[1], y = flat[2], z = flat[3] },
        forward = { x = flat[5], y = flat[6], z = flat[7] },
        up = { x = flat[9], y = flat[10], z = flat[11] },
        position = { x = flat[13], y = flat[14], z = flat[15] }
    }
end

---Creates a bended mesh of the same asset joined to one end of this one.
---The new mesh only takes a yaw, so its `World Z` up axis stays the world's; slope and bank are
---carried by its path instead.
---@param fromStart boolean? Join to the start of this mesh instead of its end.
---@return boolean
function bendedMesh:createContinuationMesh(fromStart)
    if not self.object or not self.object.parent or self.object:isLocked() then
        return false
    end

    local frames = self:getSampledPathFrames()
    local count = #frames
    if count == 0 then
        return false
    end

    local data = self.object:serialize()
    if not data or not data.spawnable then
        return false
    end

    local repeatShape = self.continuationRepeatShape and count >= 2
    local distances = nil
    if not repeatShape then
        distances = self:getRestDistances()
        local pointCount = self:getMeshBonesQuantity() or count
        if not distances or #distances ~= pointCount then
            distances = {}
            local step = self:getMeshBoundLengthAlongDirection({ x = 0, y = 1, z = 0 }) / math.max(1, pointCount - 1)
            for index = 1, pointCount do
                distances[index] = (index - 1) * step
            end
        end
    end

    ---Frames of the new mesh, in the space `sourceFrames` are given in.
    local function buildDesired(sourceFrames, spacing)
        local target = fromStart and sourceFrames[1] or sourceFrames[count]
        local desired = {}
        local motion = nil

        if repeatShape then
            -- Same curve again: the rigid motion taking the far end of this mesh onto the joined end.
            local far = fromStart and sourceFrames[count] or sourceFrames[1]
            motion = bendedRig.mul(bendedRig.inverse(bendedRig.fromFrame(far)), bendedRig.fromFrame(target))
            for index, frame in ipairs(sourceFrames) do
                desired[index] = frameFromFlat(bendedRig.mul(bendedRig.fromFrame(frame), motion))
            end
        else
            -- Straight, at the rest spacing of the rig.
            local offset = fromStart and distances[#distances] or 0
            for index, distance in ipairs(distances) do
                local along = (distance - offset) * spacing
                desired[index] = {
                    right = target.right,
                    forward = target.forward,
                    up = target.up,
                    position = {
                        x = target.position.x + target.forward.x * along,
                        y = target.position.y + target.forward.y * along,
                        z = target.position.z + target.forward.z * along
                    }
                }
            end
        end

        return desired, target, motion
    end

    local localFrames = {}
    local objectPosition, objectYaw, upAxis
    local continuationCurvePoints = nil

    local function addLocalFrame(right, forward, up, position)
        table.insert(localFrames, {
            X = { x = right.x, y = right.y, z = right.z },
            Y = { x = forward.x, y = forward.y, z = forward.z },
            Z = { x = up.x, y = up.y, z = up.z },
            W = { x = position.x, y = position.y, z = position.z }
        })
    end

    if math.abs(self.rotation.pitch or 0) < 0.0001 and math.abs(self.rotation.roll or 0) < 0.0001 then
        -- A yaw-only mesh keeps its rotation and scale, so the new path is built in this mesh's
        -- own space and joins exactly even under a non-uniform scale.
        local desired, target, motion = buildDesired(frames, 1)
        local center = target.position
        local world = self:getWorldPointFromLocal(center)

        if motion and self:isCurveMode() then
            -- The control points move with the same motion; rolls are read back from the moved frames.
            local moved = {}
            for index, frame in ipairs(self:getCurveFrames()) do
                local m = bendedRig.mul(bendedRig.fromFrame(frame), motion)
                moved[index] = {
                    X = { x = m[1], y = m[2], z = m[3] },
                    Y = { x = m[5], y = m[6], z = m[7] },
                    Z = { x = m[9], y = m[10], z = m[11] },
                    W = { x = m[13] - center.x, y = m[14] - center.y, z = m[15] - center.z }
                }
            end

            continuationCurvePoints = {}
            for index, point in ipairs(bendedMesh.pathPointsFromMatrices(moved, self.pathUpAxis)) do
                local source = self.curvePoints[index]
                local curvePoint = { x = point.x, y = point.y, z = point.z, roll = point.roll }
                if source.dir then
                    curvePoint.dir = { x = moved[index].Y.x, y = moved[index].Y.y, z = moved[index].Y.z }
                    curvePoint.lenIn, curvePoint.lenOut = source.lenIn, source.lenOut
                end
                continuationCurvePoints[index] = curvePoint
            end

            local joined = fromStart and #continuationCurvePoints or 1
            if not continuationCurvePoints[joined].dir then
                local axis = moved[joined].Y
                continuationCurvePoints[joined].dir = { x = axis.x, y = axis.y, z = axis.z }
            end
        end

        objectPosition = { x = world.x, y = world.y, z = world.z }
        objectYaw = self.rotation.yaw or 0
        upAxis = self.pathUpAxis

        for _, frame in ipairs(desired) do
            addLocalFrame(frame.right, frame.forward, frame.up, {
                x = frame.position.x - center.x,
                y = frame.position.y - center.y,
                z = frame.position.z - center.z
            })
        end
    else
        -- A pitched or rolled mesh hands over to a yaw-only one, so `World Z` is the world's up
        -- again; slope and bank move into the path. Exact for a uniform scale.
        local worldFrames = {}
        for index, frame in ipairs(frames) do
            worldFrames[index] = self:pathFrameToWorld(frame)
        end
        local target = fromStart and worldFrames[1] or worldFrames[count]

        local restPoints = self:getRestPoints()
        local restDirection = { x = 0, y = 1, z = 0 }
        if restPoints and #restPoints > 1 then
            restDirection = { x = restPoints[#restPoints].x - restPoints[1].x, y = restPoints[#restPoints].y - restPoints[1].y, z = 0 }
        end

        objectYaw = self.rotation.yaw or 0
        if length3(restDirection) > 0.000001 and length3({ x = target.forward.x, y = target.forward.y, z = 0 }) > 0.000001 then
            objectYaw = math.deg(math.atan2(target.forward.y, target.forward.x) - math.atan2(restDirection.y, restDirection.x))
        end

        local scale = self.scale or { x = 1, y = 1, z = 1 }
        local sx, sy, sz = utils.toNumber(scale.x, 1), utils.toNumber(scale.y, 1), utils.toNumber(scale.z, 1)
        if math.abs(sx) < 0.000001 then sx = 1 end
        if math.abs(sy) < 0.000001 then sy = 1 end
        if math.abs(sz) < 0.000001 then sz = 1 end

        local localForward = rotateYaw(target.forward, -objectYaw)
        local spacing = 1 / math.max(0.000001, length3({ x = localForward.x / sx, y = localForward.y / sy, z = localForward.z / sz }))
        local desired = buildDesired(worldFrames, spacing)

        objectPosition = target.position
        upAxis = 0

        for _, frame in ipairs(desired) do
            local v = rotateYaw({
                x = frame.position.x - objectPosition.x,
                y = frame.position.y - objectPosition.y,
                z = frame.position.z - objectPosition.z
            }, -objectYaw)
            addLocalFrame(rotateYaw(frame.right, -objectYaw), rotateYaw(frame.forward, -objectYaw), rotateYaw(frame.up, -objectYaw),
                { x = v.x / sx, y = v.y / sy, z = v.z / sz })
        end
    end

    local continuationPathPoints = bendedMesh.pathPointsFromMatrices(localFrames, upAxis)
    for index, point in ipairs(continuationPathPoints) do
        if repeatShape then
            point.anchored = self:isPathPointAnchored(index)
        else
            point.anchored = index == 1 or index == #continuationPathPoints
        end
    end

    data.name = utils.generateCopyName(self.object.name)
    data.spawnable.position = { x = objectPosition.x, y = objectPosition.y, z = objectPosition.z, w = 0 }
    data.spawnable.rotation = { roll = 0, pitch = 0, yaw = objectYaw }
    data.spawnable.nodeRef = ""
    data.spawnable.pathLooped = false
    data.spawnable.pathUpAxis = upAxis
    data.spawnable.pathSolver = self.pathSolver
    data.spawnable.importedDeformation = nil
    data.spawnable.deformedBox = nil
    data.spawnable.pathPoints = continuationPathPoints
    data.spawnable.pathMode = PATH_MODE_BONES
    data.spawnable.curvePoints = nil

    if self:isCurveMode() then
        local curvePoints = continuationCurvePoints
        if not curvePoints and not repeatShape then
            -- Two points; the joined one keeps the tangent, so bending the new mesh stays smooth.
            local first, last = localFrames[1], localFrames[#localFrames]
            local joined = fromStart and last or first
            curvePoints = {
                { x = first.W.x, y = first.W.y, z = first.W.z, roll = continuationPathPoints[1].roll },
                { x = last.W.x, y = last.W.y, z = last.W.z, roll = continuationPathPoints[#continuationPathPoints].roll }
            }
            curvePoints[fromStart and 2 or 1].dir = { x = joined.Y.x, y = joined.Y.y, z = joined.Y.z }
        end

        if curvePoints then
            data.spawnable.pathMode = PATH_MODE_CURVE
            data.spawnable.curvePoints = curvePoints
        end
    end

    local newElement = require("modules/classes/editor/spawnableElement"):new(self.object.sUI)
    newElement:load(data)

    local parent = self.object.parent
    local index = utils.indexValue(parent.childs, self.object)
    if index < 1 then
        index = #parent.childs + 1
    elseif not fromStart then
        index = index + 1
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
    if self:isCurveMode() then
        self:syncCurveBones()
    end
    if #self.pathPoints == 0 then
        local defaultPoints = self:getRestPoints()
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

---@param interpolation integer
---@param anchorCount integer
---@return table point
local function interpolateAnchorSpan(interpolation, anchorCount, previousPoint, startPoint, endPoint, nextPoint, t)
    if interpolation == 2 then
        return bezierAutoPathPoint(previousPoint, startPoint, endPoint, nextPoint, t)
    elseif interpolation == 1 and anchorCount >= 3 then
        return catmullRomPathPoint(previousPoint, startPoint, endPoint, nextPoint, t)
    end

    return lerpPathPoint(startPoint, endPoint, t)
end

---Samples one anchor span and returns its cumulative arc length table.
---@return table samples `{ t, length }` pairs, from t = 0 to t = 1.
local function sampleAnchorSpan(interpolation, anchorCount, previousPoint, startPoint, endPoint, nextPoint, sampleCount)
    local samples = { { t = 0, length = 0 } }
    local last = startPoint
    local total = 0

    for index = 1, sampleCount do
        local t = index / sampleCount
        local point = interpolateAnchorSpan(interpolation, anchorCount, previousPoint, startPoint, endPoint, nextPoint, t)
        total = total + length3({ x = point.x - last.x, y = point.y - last.y, z = point.z - last.z })
        samples[index + 1] = { t = t, length = total }
        last = point
    end

    return samples
end

---@param samples table From `sampleAnchorSpan`.
---@param fraction number Share of the span's arc length.
---@return number t
local function spanParameterAtFraction(samples, fraction)
    local total = samples[#samples].length
    if total <= 0.000001 then
        return fraction
    end

    local target = fraction * total
    for index = 2, #samples do
        local previous, current = samples[index - 1], samples[index]
        if current.length >= target then
            local width = current.length - previous.length
            local blend = width > 0.000001 and (target - previous.length) / width or 0
            return previous.t + (current.t - previous.t) * blend
        end
    end

    return 1
end

function bendedMesh:applyPathAlgorithmToNonAnchored()
    self:ensurePathPoints()

    if not self.pathUseAlgorithm or self:isCurveMode() then
        return false
    end

    if #self.pathPoints <= 2 then
        return false
    end

    local interpolation = math.max(0, math.min(math.floor(self.pathInterpolation or 0), #pathInterpolationOptions - 1))
    local alongCurve = self.pathSolver == PATH_SOLVER_CURVE
    local restDistances = alongCurve and self:getRestDistances() or nil
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

            local samples = nil
            if alongCurve then
                samples = sampleAnchorSpan(interpolation, #anchorIndices, previousAnchorPoint, startPoint, endPoint, nextAnchorPoint, span * PATH_CURVE_SAMPLES_PER_BONE)
            end

            for pointIndex = startIndex + 1, endIndex - 1 do
                if not self:isPathPointAnchored(pointIndex) then
                    local t = (pointIndex - startIndex) / span
                    local computed

                    if samples then
                        -- Bones keep the rig's own spacing ratios along the curve.
                        if restDistances then
                            local width = restDistances[endIndex] - restDistances[startIndex]
                            if width > 0.000001 then
                                t = (restDistances[pointIndex] - restDistances[startIndex]) / width
                            end
                        end

                        computed = interpolateAnchorSpan(interpolation, #anchorIndices, previousAnchorPoint, startPoint, endPoint, nextAnchorPoint, spanParameterAtFraction(samples, t))
                        computed.roll = startPoint.roll + (endPoint.roll - startPoint.roll) * t
                    else
                        computed = interpolateAnchorSpan(interpolation, #anchorIndices, previousAnchorPoint, startPoint, endPoint, nextAnchorPoint, t)
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

---Rig of the mesh, or nil while it loads or for a rig that cannot follow a path.
---@return bendedRigData?
function bendedMesh:getRig()
    local data = bendedRig.get(self.spawnData)
    if data and data.linear then
        return data
    end

    return nil
end

---Loads the rig; once it arrives the path is refreshed against the real bind pose.
function bendedMesh:requestRig()
    local path = self.spawnData
    local data = bendedRig.get(path, function (rigData)
        if self.spawnData == path then
            self:onRigReady(rigData)
        end
    end)

    if data then
        self:onRigReady(data)
    end
end

---@param rigData bendedRigData?
function bendedMesh:onRigReady(rigData)
    if not rigData or not rigData.linear then return end

    self._restCache = nil
    self:adoptRigRestPoints(rigData)
    self:applyImportedDeformation(rigData)
    self.pendingAutoFit = true
    self.deformedPreviewSignature = nil
    self:updatePathVisualization()
end

---Bone positions at rest: from the rig once loaded, from the static rig table before that.
---@return table[]? points `{ x, y, z, roll }`, shared; copy before editing.
function bendedMesh:getRestPoints()
    local rigData = self:getRig()
    if rigData then
        return rigData.rest
    end

    if not self._staticRest or self._staticRest.path ~= self.spawnData then
        self._staticRest = { path = self.spawnData, points = cache.getDefaultBendedPathPoints(self.spawnData) }
    end

    return self._staticRest.points
end

---Cumulative rest distance of every bone, or nil when it does not match the path.
---@return number[]?
function bendedMesh:getRestDistances()
    local rigData = self:getRig()
    local count = #(self.pathPoints or {})

    if rigData then
        return #rigData.distances == count and rigData.distances or nil
    end

    local points = self:getRestPoints()
    if not points or #points ~= count then
        return nil
    end

    local distances = { 0 }
    for index = 2, #points do
        local a, b = points[index - 1], points[index]
        distances[index] = distances[index - 1] + length3({ x = b.x - a.x, y = b.y - a.y, z = b.z - a.z })
    end

    return distances
end

---Paths still on the static rig table's defaults move onto the exact rest pose of the rig.
---@param rigData bendedRigData
function bendedMesh:adoptRigRestPoints(rigData)
    local defaults = cache.getDefaultBendedPathPoints(self.spawnData)
    local points = self.pathPoints or {}

    if not defaults or #defaults ~= #points or #points ~= #rigData.rest then return end

    for index, point in ipairs(points) do
        local default = defaults[index]
        if math.abs(point.x - default.x) > 0.001 or math.abs(point.y - default.y) > 0.001 or math.abs(point.z - default.z) > 0.001 then
            return
        end
    end

    for index, point in ipairs(points) do
        local rest = rigData.rest[index]
        point.x, point.y, point.z = rest.x, rest.y, rest.z
    end
end

---Turns a deformation imported from a world node back into path frames: `F = Frest * inverseBind * D`.
---@param rigData bendedRigData
function bendedMesh:applyImportedDeformation(rigData)
    local imported = self.importedDeformation
    if not imported then return end
    self.importedDeformation = nil

    if #imported ~= #rigData.inverseBind or #imported ~= #(self.pathPoints or {}) then return end

    local restFrames = self:buildRestFrames(rigData.rest)
    local matrices = {}
    for index, deformation in ipairs(imported) do
        local frame = bendedRig.mul(bendedRig.mul(bendedRig.fromFrame(restFrames[index]), rigData.inverseBind[index]), deformation)
        matrices[index] = {
            X = { x = frame[1], y = frame[2], z = frame[3] },
            Y = { x = frame[5], y = frame[6], z = frame[7] },
            Z = { x = frame[9], y = frame[10], z = frame[11] },
            W = { x = frame[13], y = frame[14], z = frame[15] }
        }
    end

    local points = bendedMesh.pathPointsFromMatrices(matrices, self.pathUpAxis)
    for index, point in ipairs(points) do
        point.anchored = self.pathPoints[index].anchored
    end
    self.pathPoints = points
end

---@return integer?
function bendedMesh:getMeshBonesQuantity()
    local rigData = bendedRig.get(self.spawnData)
    if rigData then
        return #rigData.inverseBind
    end

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

    local curveMode = self:isCurveMode()
    for index, point in ipairs(controlPoints) do
        local copy = copyPathPoint(point)
        copy.tangent = point.tangent
        table.insert(sampled, copy)
        if not curveMode and self:isPathPointAnchored(index) then
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

---Tangent at a path point. Inner points use their neighbours; ends use the chord, or with
---`smoothEnds` the tangent of the parabola through the three end points.
---@return table direction
local function getPathTangent(points, index, looped, smoothEnds)
    local own = points[index] and points[index].tangent
    if own then
        local direction = normalizeDirection(own)
        if not isDirectionZero(direction) then
            return direction
        end
    end

    local count = #points
    if count <= 1 then
        return { x = 0, y = 1, z = 0 }
    end

    local previousIndex = index - 1
    local nextIndex = index + 1
    if looped then
        if previousIndex < 1 then previousIndex = count end
        if nextIndex > count then nextIndex = 1 end
    end

    local previous = points[previousIndex]
    local nextPoint = points[nextIndex]
    local current = points[index]
    local forward

    if previous and nextPoint then
        forward = { x = nextPoint.x - previous.x, y = nextPoint.y - previous.y, z = nextPoint.z - previous.z }
    else
        if nextPoint then
            forward = { x = nextPoint.x - current.x, y = nextPoint.y - current.y, z = nextPoint.z - current.z }
        else
            forward = { x = current.x - previous.x, y = current.y - previous.y, z = current.z - previous.z }
        end

        if smoothEnds and count >= 3 then
            local p0, p1, p2
            if index == 1 then
                p0, p1, p2 = points[1], points[2], points[3]
            else
                p0, p1, p2 = points[count - 2], points[count - 1], points[count]
            end

            local h1 = length3({ x = p1.x - p0.x, y = p1.y - p0.y, z = p1.z - p0.z })
            local h2 = length3({ x = p2.x - p1.x, y = p2.y - p1.y, z = p2.z - p1.z })

            if h1 > 0.000001 and h2 > 0.000001 then
                local a, b, c
                if index == 1 then
                    a, b, c = -(2 * h1 + h2) / (h1 * (h1 + h2)), (h1 + h2) / (h1 * h2), -h1 / (h2 * (h1 + h2))
                else
                    a, b, c = h2 / (h1 * (h1 + h2)), -(h1 + h2) / (h1 * h2), (h1 + 2 * h2) / (h2 * (h1 + h2))
                end

                local smooth = {
                    x = a * p0.x + b * p1.x + c * p2.x,
                    y = a * p0.y + b * p1.y + c * p2.y,
                    z = a * p0.z + b * p1.z + c * p2.z
                }
                if dot(smooth, forward) > 0 then
                    forward = smooth
                end
            end
        end
    end

    forward = normalizeDirection(forward)
    if isDirectionZero(forward) then
        return { x = 0, y = 1, z = 0 }
    end

    return forward
end

---Frames of a list of path points: tangent forward, up from the up axis, then the point's roll.
---@param points table[]
---@param looped boolean
---@param upAxisIndex integer
---@param smoothEnds boolean
---@return table[] frames `{ position, right, forward, up }`
local function buildPathFrames(points, looped, upAxisIndex, smoothEnds)
    local upHint = getPathUpAxis(upAxisIndex)
    local frames = {}
    local lastRight = nil

    for index, point in ipairs(points) do
        local forward = getPathTangent(points, index, looped, smoothEnds)
        local right, _, up = buildBasisFromForward(forward, upHint)

        if lastRight and dot(right, lastRight) < 0 then
            right = { x = -right.x, y = -right.y, z = -right.z }
            up = { x = -up.x, y = -up.y, z = -up.z }
        end

        local roll = utils.toNumber(point.roll, 0)
        if math.abs(roll) > 0.001 then
            local angle = math.rad(roll)
            right = normalizeDirection(rotateAroundAxis(right, forward, angle))
            up = normalizeDirection(rotateAroundAxis(up, forward, angle))
        end

        local upReference = normalizeDirection({
            x = upHint.x - dot(upHint, forward) * forward.x,
            y = upHint.y - dot(upHint, forward) * forward.y,
            z = upHint.z - dot(upHint, forward) * forward.z
        })
        if not isDirectionZero(upReference) and dot(up, upReference) < 0 then
            right = { x = -right.x, y = -right.y, z = -right.z }
            up = { x = -up.x, y = -up.y, z = -up.z }
        end

        table.insert(frames, {
            position = { x = point.x, y = point.y, z = point.z },
            right = right,
            forward = forward,
            up = up
        })

        lastRight = right
    end

    if #frames == 0 then
        frames = {
            {
                position = { x = 0, y = 0, z = 0 },
                right = { x = 1, y = 0, z = 0 },
                forward = { x = 0, y = 1, z = 0 },
                up = { x = 0, y = 0, z = 1 }
            }
        }
    end

    return frames
end

function bendedMesh:getSampledPathFrames()
    local sampledPoints, looped, sampleInfo = self:getSampledPathPoints()
    local frames = buildPathFrames(sampledPoints, looped, self.pathUpAxis, self.pathSolver == PATH_SOLVER_CURVE)

    for index, frame in ipairs(frames) do
        local info = sampleInfo[index]
        frame.isControlPoint = info and info.isControlPoint == true or false
        frame.controlPointIndex = info and info.controlPointIndex or nil
    end

    return frames
end

---Frames of the bones at rest, built the same way as the path's.
---@param restPoints table[]
---@return table[]
function bendedMesh:buildRestFrames(restPoints)
    return buildPathFrames(restPoints, false, self.pathUpAxis, self.pathSolver == PATH_SOLVER_CURVE)
end

---Per-bone rest correction. `pre = bind * Frest^-1` turns a path frame into the bone's deformation,
---so the rest path gives back the bind pose whatever the rig's axes. `restInverse = Frest^-1`
---maps mesh-space geometry into the bone's frame. `pre` is nil until the rig is loaded.
---@param count integer Path point count.
---@return table[]? corrections
function bendedMesh:getRestCorrections(count)
    local restPoints = self:getRestPoints()
    if not restPoints or #restPoints ~= count or count == 0 then
        return nil
    end

    local rigData = self:getRig()
    local key = table.concat({ tostring(self.spawnData), tostring(rigData ~= nil), tostring(self.pathUpAxis), tostring(self.pathSolver), tostring(count) }, "|")
    if self._restCache and self._restCache.key == key then
        return self._restCache.corrections
    end

    local corrections = {}
    for index, frame in ipairs(self:buildRestFrames(restPoints)) do
        local restInverse = bendedRig.inverse(bendedRig.fromFrame(frame))
        corrections[index] = {
            restInverse = restInverse,
            pre = rigData and bendedRig.mul(rigData.bind[index], restInverse) or nil
        }
    end

    self._restCache = { key = key, corrections = corrections }
    return corrections
end

---Deformation matrices, one per bone, in the node's local space.
---@param updateBox boolean Refit the deformed box as well.
---@return table[] matrices `{ X, Y, Z, W }` Vector4 rows.
function bendedMesh:rebuildMatricesFromPath(updateBox)
    local frames = self:getSampledPathFrames()
    local corrections = self:getRestCorrections(#frames)
    local matrices = {}

    for index, frame in ipairs(frames) do
        local m = bendedRig.fromFrame(frame)
        local pre = corrections and corrections[index].pre
        if pre then
            m = bendedRig.mul(pre, m)
        end

        matrices[index] = {
            X = Vector4.new(m[1], m[2], m[3], 0),
            Y = Vector4.new(m[5], m[6], m[7], 0),
            Z = Vector4.new(m[9], m[10], m[11], 0),
            W = Vector4.new(m[13], m[14], m[15], 1)
        }
    end

    if updateBox then
        self:autoFitDeformedBox(frames)
    end

    return matrices
end

---Length of the path through its bones, and the rig's length at rest.
---@return number length
---@return number? restLength
function bendedMesh:getPathLengths()
    local sampled, looped = self:getSampledPathPoints()
    local length = 0
    for index = 2, #sampled do
        local a, b = sampled[index - 1], sampled[index]
        length = length + length3({ x = b.x - a.x, y = b.y - a.y, z = b.z - a.z })
    end
    if looped and #sampled > 2 then
        local a, b = sampled[#sampled], sampled[1]
        length = length + length3({ x = b.x - a.x, y = b.y - a.y, z = b.z - a.z })
    end

    local distances = self:getRestDistances()
    return length, distances and distances[#distances] or nil
end

local function subtract(a, b)
    return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

local function smoothstep(t)
    return t * t * (3 - 2 * t)
end

---Tangent direction and handle lengths of every curve point. Auto tangents follow the bisector of
---the neighbouring chords; auto ends aim at the next point's handle, like a natural spline.
---@param points table[]
---@param looped boolean
---@return table[] tangents `{ dir, lenIn, lenOut }`
local function getCurveTangents(points, looped)
    local count = #points
    local tangents = {}

    local function neighbour(index)
        if looped then
            return points[(index - 1) % count + 1]
        end
        return points[index]
    end

    for index, point in ipairs(points) do
        local previous = neighbour(index - 1)
        local nextPoint = neighbour(index + 1)
        local chordIn = previous and length3(subtract(point, previous)) or nil
        local chordOut = nextPoint and length3(subtract(nextPoint, point)) or nil
        local dir = point.dir

        if not dir and previous and nextPoint and chordIn > 0.000001 and chordOut > 0.000001 then
            local a = subtract(point, previous)
            local b = subtract(nextPoint, point)
            dir = normalizeDirection({
                x = a.x / chordIn + b.x / chordOut,
                y = a.y / chordIn + b.y / chordOut,
                z = a.z / chordIn + b.z / chordOut
            })
            if isDirectionZero(dir) then dir = nil end
        end

        tangents[index] = {
            dir = dir,
            lenIn = point.lenIn or (chordIn and chordIn / 3) or 0,
            lenOut = point.lenOut or (chordOut and chordOut / 3) or 0
        }
    end

    -- Open ends (and degenerate points) aim at the neighbour's handle.
    for index, point in ipairs(points) do
        if not tangents[index].dir then
            local nextPoint, previous = points[index + 1], points[index - 1]
            local dir
            if nextPoint then
                local handle = nextPoint
                local nextTangent = tangents[index + 1]
                if nextTangent.dir and count > 2 then
                    handle = {
                        x = nextPoint.x - nextTangent.dir.x * nextTangent.lenIn,
                        y = nextPoint.y - nextTangent.dir.y * nextTangent.lenIn,
                        z = nextPoint.z - nextTangent.dir.z * nextTangent.lenIn
                    }
                end
                dir = normalizeDirection(subtract(handle, point))
            elseif previous then
                local handle = previous
                local previousTangent = tangents[index - 1]
                if previousTangent.dir and count > 2 then
                    handle = {
                        x = previous.x + previousTangent.dir.x * previousTangent.lenOut,
                        y = previous.y + previousTangent.dir.y * previousTangent.lenOut,
                        z = previous.z + previousTangent.dir.z * previousTangent.lenOut
                    }
                end
                dir = normalizeDirection(subtract(point, handle))
            end

            if not dir or isDirectionZero(dir) then
                dir = { x = 0, y = 1, z = 0 }
            end
            tangents[index].dir = dir
        end
    end

    return tangents
end

---Cubic Bezier segments between curve points.
---@return table[] segments `{ p0, c0, c1, p1, r0, r1 }`
local function buildCurveSegments(points, looped)
    local tangents = getCurveTangents(points, looped)
    local segments = {}
    local count = #points
    local last = looped and count or count - 1

    for index = 1, last do
        local a, b = points[index], points[index % count + 1]
        local ta, tb = tangents[index], tangents[index % count + 1]
        table.insert(segments, {
            p0 = a,
            c0 = { x = a.x + ta.dir.x * ta.lenOut, y = a.y + ta.dir.y * ta.lenOut, z = a.z + ta.dir.z * ta.lenOut },
            c1 = { x = b.x - tb.dir.x * tb.lenIn, y = b.y - tb.dir.y * tb.lenIn, z = b.z - tb.dir.z * tb.lenIn },
            p1 = b,
            r0 = a.roll or 0,
            r1 = b.roll or 0
        })
    end

    return segments, tangents
end

local function bezierPoint(segment, t)
    return {
        x = cubicBezierScalar(segment.p0.x, segment.c0.x, segment.c1.x, segment.p1.x, t),
        y = cubicBezierScalar(segment.p0.y, segment.c0.y, segment.c1.y, segment.p1.y, t),
        z = cubicBezierScalar(segment.p0.z, segment.c0.z, segment.c1.z, segment.p1.z, t)
    }
end

local function bezierDerivative(segment, t)
    local u = 1 - t
    local function axis(key)
        return 3 * u * u * (segment.c0[key] - segment.p0[key])
            + 6 * u * t * (segment.c1[key] - segment.c0[key])
            + 3 * t * t * (segment.p1[key] - segment.c1[key])
    end

    local d = normalizeDirection({ x = axis("x"), y = axis("y"), z = axis("z") })
    if isDirectionZero(d) then
        d = normalizeDirection(subtract(segment.p1, segment.p0))
    end
    return d
end

---Dense arc-length table over all segments.
---@return table[] samples `{ s, segment, t }`
---@return number length
local function sampleCurveSegments(segments)
    local samples = {}
    local total = 0

    for segmentIndex, segment in ipairs(segments) do
        local previous = segment.p0
        if segmentIndex == 1 then
            table.insert(samples, { s = 0, segment = 1, t = 0 })
        end

        for step = 1, CURVE_SAMPLES_PER_SEGMENT do
            local t = step / CURVE_SAMPLES_PER_SEGMENT
            local point = bezierPoint(segment, t)
            total = total + length3(subtract(point, previous))
            table.insert(samples, { s = total, segment = segmentIndex, t = t })
            previous = point
        end
    end

    return samples, total
end

---Curve position, tangent and roll at arc length `s`. Past the end the curve continues straight.
local function evaluateCurveAt(segments, samples, total, s)
    local function at(segmentIndex, t)
        local segment = segments[segmentIndex]
        local position = bezierPoint(segment, t)
        return position, bezierDerivative(segment, t), segment.r0 + (segment.r1 - segment.r0) * smoothstep(t)
    end

    if s >= total then
        local position, tangent, roll = at(#segments, 1)
        local extra = s - total
        return { x = position.x + tangent.x * extra, y = position.y + tangent.y * extra, z = position.z + tangent.z * extra }, tangent, roll
    end
    if s <= 0 then
        return at(1, 0)
    end

    local low, high = 1, #samples
    while high - low > 1 do
        local middle = math.floor((low + high) / 2)
        if samples[middle].s < s then low = middle else high = middle end
    end

    local a, b = samples[low], samples[high]
    local blend = (b.s - a.s) > 0.000001 and (s - a.s) / (b.s - a.s) or 0
    local ta = a.segment == b.segment and a.t or 0
    return at(b.segment, ta + (b.t - ta) * blend)
end

---@return boolean
function bendedMesh:isCurveMode()
    return self.pathMode == PATH_MODE_CURVE
end

---Rest distances for a bone count, falling back to even spacing.
---@param count integer
---@return number[] distances
function bendedMesh:getRestDistancesFor(count)
    local rigData = self:getRig()
    if rigData and #rigData.distances == count then
        return rigData.distances
    end

    local points = self:getRestPoints()
    local distances = { 0 }
    if points and #points == count then
        for index = 2, #points do
            distances[index] = distances[index - 1] + length3(subtract(points[index], points[index - 1]))
        end
        return distances
    end

    for index = 2, count do
        distances[index] = index - 1
    end
    return distances
end

---Two curve points at the rest ends of the rig, or the anchored bones of the current path.
function bendedMesh:ensureCurvePoints()
    self.curvePoints = self.curvePoints or {}
    if #self.curvePoints >= 2 then return end

    local source = {}
    local hasBones = type(self.pathPoints) == "table" and #self.pathPoints >= 2
    if hasBones then
        for index, point in ipairs(self.pathPoints) do
            if index == 1 or index == #self.pathPoints or point.anchored then
                table.insert(source, point)
            end
        end
    else
        local rest = self:getRestPoints()
        if rest and #rest >= 2 then
            source = { rest[1], rest[#rest] }
        else
            source = { { x = 0, y = 0, z = 0 }, { x = 0, y = self:getMeshBoundLengthAlongDirection({ x = 0, y = 1, z = 0 }), z = 0 } }
        end
    end

    self.curvePoints = {}
    for _, point in ipairs(source) do
        table.insert(self.curvePoints, copyCurvePoint(point))
    end
end

---Places the bones along the curve. Cached on everything the placement depends on.
function bendedMesh:syncCurveBones()
    self:ensureCurvePoints()

    local count = self:getMeshBonesQuantity() or #(self.pathPoints or {})
    if count < 2 then count = 2 end
    local looped = self.pathLooped and #self.curvePoints > 2

    local keyParts = { tostring(self.spawnData), tostring(count), tostring(looped), tostring(self.pathLengthMode), tostring(self:getRig() ~= nil) }
    for _, point in ipairs(self.curvePoints) do
        table.insert(keyParts, string.format("%.5f,%.5f,%.5f,%.4f", point.x, point.y, point.z, point.roll or 0))
        if point.dir then
            table.insert(keyParts, string.format("%.5f,%.5f,%.5f,%s,%s", point.dir.x, point.dir.y, point.dir.z, tostring(point.lenIn), tostring(point.lenOut)))
        end
    end
    local key = table.concat(keyParts, "|")
    if key == self._curveKey and self.pathPoints and #self.pathPoints == count then return end
    self._curveKey = key

    local segments = buildCurveSegments(self.curvePoints, looped)
    local samples, total = sampleCurveSegments(segments)
    local distances = self:getRestDistancesFor(count)
    local restTotal = distances[#distances]
    local keepLength = self.pathLengthMode == LENGTH_MODE_KEEP and not looped

    local bones = {}
    for index = 1, count do
        local s
        if keepLength then
            s = distances[index]
        elseif looped then
            local gap = restTotal / math.max(1, count - 1)
            s = restTotal + gap > 0 and distances[index] / (restTotal + gap) * total or 0
        else
            s = restTotal > 0 and distances[index] / restTotal * total or (index - 1) / (count - 1) * total
        end

        local position, tangent, roll = evaluateCurveAt(segments, samples, total, s)
        bones[index] = {
            x = position.x, y = position.y, z = position.z,
            roll = roll,
            anchored = index == 1 or index == count,
            tangent = tangent
        }
    end

    self.pathPoints = bones
end

---Resolved tangent of every curve point, for the editor and the overlay.
---@return table[]
function bendedMesh:getCurveTangents()
    self:ensureCurvePoints()
    return getCurveTangents(self.curvePoints, self.pathLooped and #self.curvePoints > 2)
end

---Curve length and the rig's rest length.
---@return number length
---@return number? restLength
function bendedMesh:getCurveLength()
    self:ensureCurvePoints()
    local segments = buildCurveSegments(self.curvePoints, self.pathLooped and #self.curvePoints > 2)
    local _, total = sampleCurveSegments(segments)
    local count = self:getMeshBonesQuantity()
    local distances = count and self:getRestDistancesFor(count) or nil
    return total, distances and distances[#distances] or nil
end

---Frame at each curve point, in mesh space.
---@return table[]
function bendedMesh:getCurveFrames()
    local tangents = self:getCurveTangents()
    local frames = {}
    for index, point in ipairs(self.curvePoints) do
        local frame = buildPathFrames({ { x = point.x, y = point.y, z = point.z, roll = point.roll, tangent = tangents[index].dir } }, false, self.pathUpAxis, true)[1]
        frame.isControlPoint = true
        frame.controlPointIndex = index
        frames[index] = frame
    end
    return frames
end

---Switches between the curve and the per-bone editor, keeping the shape.
---@param mode integer
function bendedMesh:setPathMode(mode)
    if mode == self.pathMode then return end

    if mode == PATH_MODE_CURVE then
        self.curvePoints = {}
        self:ensurePathPoints()
        self.pathMode = PATH_MODE_CURVE
        self:ensureCurvePoints()
        self._curveKey = nil
    else
        self:ensurePathPoints()
        self.pathMode = PATH_MODE_BONES
        for _, point in ipairs(self.pathPoints) do
            point.anchored = true
            point.tangent = nil
        end
    end
end

---Heading and slope (degrees) of a direction in mesh space; heading 0 is +Y, positive turns left.
local function directionToAngles(dir)
    return math.deg(math.atan2(-dir.x, dir.y)), math.deg(math.asin(math.max(-1, math.min(1, dir.z))))
end

local function anglesToDirection(heading, slope)
    local h, s = math.rad(heading), math.rad(slope)
    return { x = -math.sin(h) * math.cos(s), y = math.cos(h) * math.cos(s), z = math.sin(s) }
end

---Inserts a curve point on the curve halfway along the segment after `index`.
---@param index integer
function bendedMesh:insertCurvePointAfter(index)
    local looped = self.pathLooped and #self.curvePoints > 2
    local segments = buildCurveSegments(self.curvePoints, looped)
    local segment = segments[index]
    if not segment then return end

    local samples, _ = sampleCurveSegments({ segment })
    local position = evaluateCurveAt({ segment }, samples, samples[#samples].s, samples[#samples].s / 2)
    local a, b = self.curvePoints[index], self.curvePoints[index % #self.curvePoints + 1]
    table.insert(self.curvePoints, index + 1, {
        x = position.x, y = position.y, z = position.z,
        roll = ((a.roll or 0) + (b.roll or 0)) / 2
    })
end

---Appends a curve point past the end, along the end tangent.
function bendedMesh:appendCurvePoint()
    local count = #self.curvePoints
    local last = self.curvePoints[count]
    local tangents = self:getCurveTangents()
    local dir = tangents[count].dir
    local step = length3(subtract(last, self.curvePoints[count - 1] or { x = last.x, y = last.y - 1, z = last.z }))
    if step < 0.01 then step = 1 end

    table.insert(self.curvePoints, {
        x = last.x + dir.x * step, y = last.y + dir.y * step, z = last.z + dir.z * step,
        roll = last.roll or 0
    })
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
            self._pathPreviewAssembling = true
            local ok, err = pcall(self.updatePathVisualization, self)
            self._pathPreviewAssembling = false
            if not ok then error(err) end
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

    if not self._pathPreviewAssembling then
        self._pathPreviewRehost = true
    end

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
    bendedPool.release(self)
    self.deformedPreviewSignature = nil
    mesh.despawn(self)
end

function bendedMesh:update()
    mesh.update(self)
    -- Hosts hold the preview in mesh-local coordinates, so they follow the mesh when it moves.
    self:getPathPreviewHosts():updateTransforms(self.position, self.rotation)
    self:refreshDeformedPreview()
end

---Fingerprint of everything the deformed preview depends on.
---@return string
function bendedMesh:getDeformedPreviewSignature()
    local parts = {
        tostring(self.spawnData), tostring(self.app),
        tostring(self.castShadows), tostring(self.castLocalShadows),
        tostring(self.pathLooped), tostring(self.pathUseAlgorithm),
        tostring(self.pathInterpolation), tostring(self.pathUpAxis),
        tostring(self.pathSolver), tostring(self:getRig() ~= nil)
    }
    local function add(...)
        for _, value in ipairs({ ... }) do
            table.insert(parts, string.format("%.4f", utils.toNumber(value, 0)))
        end
    end

    add(self.position.x, self.position.y, self.position.z)
    add(self.rotation.roll, self.rotation.pitch, self.rotation.yaw)
    add(self.scale.x, self.scale.y, self.scale.z)

    local box = self:getNormalizedDeformedBox()
    add(box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z)

    for _, point in ipairs(self.pathPoints or {}) do
        add(point.x, point.y, point.z, point.roll)
        table.insert(parts, point.anchored and "a" or "f")
    end

    return table.concat(parts, "|")
end

---World-space payload for the placeholder node: path matrices composed with T * R * S.
---@return bendedPoolPayload? payload
---@return string? issue
function bendedMesh:buildDeformedPreviewPayload()
    local matrices = self:rebuildMatricesFromPath(false)
    local bones = self:getMeshBonesQuantity()

    if bones and bones ~= #matrices then
        return nil, string.format("Path has %d points but the mesh has %d bones.", #matrices, bones)
    end

    local quat = self.rotation:ToQuat()
    local scale = self.scale or { x = 1, y = 1, z = 1 }
    local position = self.position

    local function toWorld(v, isPoint)
        local rotated = quat:Transform(Vector4.new(v.x * scale.x, v.y * scale.y, v.z * scale.z, 0))
        if isPoint then
            return rotated.x + position.x, rotated.y + position.y, rotated.z + position.z
        end

        return rotated.x, rotated.y, rotated.z
    end

    local payloadMatrices = {}
    for i, matrix in ipairs(matrices) do
        local xx, xy, xz = toWorld(matrix.X)
        local yx, yy, yz = toWorld(matrix.Y)
        local zx, zy, zz = toWorld(matrix.Z)
        local wx, wy, wz = toWorld(matrix.W, true)

        payloadMatrices[i] = { xx, xy, xz, 0, yx, yy, yz, 0, zx, zy, zz, 0, wx, wy, wz, 1 }
    end

    local box = self:getNormalizedDeformedBox()
    local minimum = { math.huge, math.huge, math.huge }
    local maximum = { -math.huge, -math.huge, -math.huge }
    for _, cx in ipairs({ box.min.x, box.max.x }) do
        for _, cy in ipairs({ box.min.y, box.max.y }) do
            for _, cz in ipairs({ box.min.z, box.max.z }) do
                local corner = { toWorld({ x = cx, y = cy, z = cz }, true) }
                for axis = 1, 3 do
                    minimum[axis] = math.min(minimum[axis], corner[axis])
                    maximum[axis] = math.max(maximum[axis], corner[axis])
                end
            end
        end
    end

    local app = self.app
    if app == nil or app == "" then
        app = "default"
    end

    return {
        mesh = self.spawnData,
        appearance = app,
        matrices = payloadMatrices,
        box = { minimum[1], minimum[2], minimum[3], maximum[1], maximum[2], maximum[3] },
        castShadows = self.shadowCastingModeEnum[self.castShadows + 1],
        castLocalShadows = self.shadowCastingModeEnum[self.castLocalShadows + 1]
    }
end

---Pushes the current deformation to a placeholder node when anything it depends on changed.
function bendedMesh:refreshDeformedPreview()
    local active = self.deformedPreviewEnabled and not self.isAssetPreview and self:getEntity() ~= nil

    if not active then
        if self.deformedPreviewSignature then
            bendedPool.release(self)
            self.deformedPreviewSignature = nil
            self:applyEntityMeshVisibility()
        end
        return
    end

    if self:isCurveMode() then
        self:syncCurveBones()
    end

    local signature = self:getDeformedPreviewSignature()
    if signature == self.deformedPreviewSignature then return end
    self.deformedPreviewSignature = signature

    local payload, issue = self:buildDeformedPreviewPayload()
    self.deformedPreviewIssue = issue

    if not payload then
        bendedPool.release(self)
        self:applyEntityMeshVisibility()
        return
    end

    bendedPool.submit(self, payload)
end

---Hides the undeformed entity mesh while the placeholder shows the deformed one.
function bendedMesh:applyEntityMeshVisibility()
    local entity = self:getEntity()
    if not entity then return end

    local component = entity:FindComponentByName("mesh")
    if component then
        component:Toggle(not bendedPool.isShowing(self))
    end
end

---Called by the pool once the placeholder first displays this mesh.
function bendedMesh:onBendedPreviewShown()
    self:applyEntityMeshVisibility()
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
    self:refreshDeformedPreview()

    local showPreview = (not self.isAssetPreview) and self.pathPreviewEnabled
    if not showPreview then
        -- Despawning the hosts drops every preview component with them, which is cheaper than
        -- hiding them one by one and leaves nothing behind while the preview is off.
        self:getPathPreviewHosts():despawn()
        self.pathPreviewSegmentCount = 0
        self.pathPreviewControlCount = 0
        self.pathPreviewSubdivisionCount = 0
        self.pathPreviewFrameCount = 0
        self.pathPreviewHandleCount = 0
        return
    end

    local segmentThickness = PATH_PREVIEW_LINE_THICKNESS
    local looped = self.pathLooped and #self.pathPoints > 2
    local frames = self:getSampledPathFrames()
    local curveMode = self:isCurveMode()
    local controlFrames = {}
    if curveMode then
        controlFrames = self:getCurveFrames()
    else
        for _, frame in ipairs(frames) do
            if frame.isControlPoint then
                table.insert(controlFrames, frame)
            end
        end
    end
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
    local requiredHandles = curveMode and 2 * #controlFrames or 0
    local requiredComponents = requiredSegments + #self.pathPoints + #controlFrames + requiredHandles + requiredFrameComponents
    self:getPathPreviewHosts():ensure(requiredComponents, self.position, self.rotation)
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

    for _, frame in ipairs(controlFrames) do
        if frame.position then
            local nextIndex = usedControls + 1
            if self:renderPathControlPoint(nextIndex, frame.position) then
                usedControls = nextIndex
            end
        end
    end

    self:hidePathPreviewOverflow("bendPathCtrl", usedControls, previousControlCount)
    self.pathPreviewControlCount = usedControls

    local usedHandles = 0
    if curveMode then
        for index, tangent in ipairs(self:getCurveTangents()) do
            local point = self.curvePoints[index]
            local origin = self:toScaledLocalPoint(point)
            for _, side in ipairs({ { length = -tangent.lenIn }, { length = tangent.lenOut } }) do
                if math.abs(side.length) > 0.001 then
                    local tip = self:toScaledLocalPoint({
                        x = point.x + tangent.dir.x * side.length,
                        y = point.y + tangent.dir.y * side.length,
                        z = point.z + tangent.dir.z * side.length
                    })
                    if self:renderPathPreviewLine("bendPathHandle", usedHandles + 1, origin, tip, point.dir and "orange" or "white", segmentThickness * 0.6) then
                        usedHandles = usedHandles + 1
                    end
                end
            end
        end
    end
    self:hidePathPreviewOverflow("bendPathHandle", usedHandles, self.pathPreviewHandleCount or 0)
    self.pathPreviewHandleCount = usedHandles

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
        for _, frame in ipairs(controlFrames) do
            if usedFrames >= maxFrames then break end
            if frame then
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

            for _, frame in ipairs(controlFrames) do
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

    -- A component added to an attached host never renders; fresh hosts redraw everything while
    -- they assemble, without touching the mesh itself.
    if self._pathPreviewRehost then
        self._pathPreviewRehost = false
        hosts:despawn()
        self.pathPreviewSegmentCount = 0
        self.pathPreviewControlCount = 0
        self.pathPreviewSubdivisionCount = 0
        self.pathPreviewFrameCount = 0
        self.pathPreviewHandleCount = 0
        hosts:ensure(requiredComponents, self.position, self.rotation)
        return
    end

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

    -- Geometry around a bone moves with `Frest^-1 * F`, so each bone carries the mesh box with it.
    local corrections = self:getRestCorrections(#frames)
    local transformed = {}
    for index, frame in ipairs(frames) do
        if corrections then
            local m = bendedRig.mul(corrections[index].restInverse, bendedRig.fromFrame(frame))
            for _, corner in ipairs(corners) do
                local p = bendedRig.transformPoint(m, corner)
                table.insert(transformed, Vector4.new(p.x, p.y, p.z, 1))
            end
        else
            for _, corner in ipairs(corners) do
                table.insert(transformed, transformPointWithFrame(frame, corner))
            end
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

        self:refreshDeformedPreview()
    end

    ImGui.SameLine()
    ImGui.BeginDisabled(#self.apps <= 1)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.SkipPrevious .. "##cyclePreviousBendedAppearance") then
        self:cycleAppearance(-1)
    end
    style.tooltip("Select the previous mesh appearance.")
    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.SkipNext .. "##cycleBendedAppearance") then
        self:cycleAppearance()
    end
    style.tooltip("Select the next mesh appearance.")
    style.pushButtonNoBG(false)
    ImGui.EndDisabled()
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

    style.mutedText("Deformed Preview")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.deformedPreviewEnabled, changed = style.trackedCheckbox(self.object, "##deformedPreviewEnabled", self.deformedPreviewEnabled)
    changedAny = changedAny or changed
    style.tooltip("Show the real deformed mesh through a World Builder placeholder node.\nNeeds Red Hot Tools; otherwise the mesh stays undeformed.")

    if self.deformedPreviewEnabled and not self.isAssetPreview then
        local status = bendedPool.getStatus(self)
        ImGui.SameLine()

        if self.deformedPreviewIssue then
            style.mutedText(IconGlyphs.AlertOutline)
            style.tooltip(self.deformedPreviewIssue)
        elseif status == "active" then
            style.mutedText(IconGlyphs.CheckCircleOutline)
            style.tooltip("Deformed preview active.")
        elseif status == "pending" then
            style.mutedText(IconGlyphs.TimerSandEmpty)
            style.tooltip("Waiting for a placeholder node.")
        else
            style.mutedText(IconGlyphs.AlertOutline)
            style.tooltip(bendedPool.lastReason ~= "" and bendedPool.lastReason or "Deformed preview unavailable; the mesh is shown undeformed.")
        end
    end

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

---Row of one curve point: position, roll, tangent mode, insert and delete.
---@return boolean changed
---@return boolean topologyChanged
function bendedMesh:drawCurvePointEditor(index, point, tangent)
    local changedAny = false
    local topologyChanged = false
    local changed
    local count = #self.curvePoints

    point.x, changed = field.advancedTrackedFloat(self.object, "##curvePointX", point.x, { suffix = " X", width = 60 })
    changedAny = changedAny or changed
    ImGui.SameLine()
    point.y, changed = field.advancedTrackedFloat(self.object, "##curvePointY", point.y, { suffix = " Y", width = 60 })
    changedAny = changedAny or changed
    ImGui.SameLine()
    point.z, changed = field.advancedTrackedFloat(self.object, "##curvePointZ", point.z, { suffix = " Z", width = 60 })
    changedAny = changedAny or changed

    ImGui.SameLine()
    ImGui.Dummy(8 * style.viewSize, 0)
    ImGui.SameLine()
    point.roll, changed = field.advancedTrackedFloat(self.object, "##curvePointRoll", point.roll or 0, { suffix = " Roll" })
    changedAny = changedAny or changed
    style.tooltip("Bank in degrees around the curve. Eased between points.")

    ImGui.SameLine()
    local manual = point.dir ~= nil
    style.pushStyleColor(manual, ImGuiCol.Text, 0.25, 0.62, 0.97, 1.0)
    local _, clicked = style.toggleButton(IconGlyphs.VectorBezier .. "##curveTangentMode", manual)
    style.popStyleColor(manual)
    style.tooltip(manual and "Manual tangent. Click to go back to an automatic one." or "Automatic tangent. Click to set heading, slope and handle lengths by hand.")
    if clicked then
        history.addAction(history.getElementChange(self.object))
        if manual then
            point.dir, point.lenIn, point.lenOut = nil, nil, nil
        else
            point.dir = { x = tangent.dir.x, y = tangent.dir.y, z = tangent.dir.z }
            point.lenIn, point.lenOut = tangent.lenIn, tangent.lenOut
        end
        changedAny = true
    end

    local looped = self.pathLooped and count > 2
    local canInsert = index < count or looped
    ImGui.SameLine()
    ImGui.BeginDisabled(not canInsert)
    if ImGui.Button(IconGlyphs.PlusCircleMultipleOutline) and canInsert then
        history.addAction(history.getElementChange(self.object))
        self:insertCurvePointAfter(index)
        changedAny, topologyChanged = true, true
    end
    ImGui.EndDisabled()
    style.tooltip("Insert a control point on the curve after this one.")

    ImGui.SameLine()
    ImGui.BeginDisabled(count <= 2)
    if style.dangerButton(IconGlyphs.DeleteOutline) and count > 2 then
        history.addAction(history.getElementChange(self.object))
        table.remove(self.curvePoints, index)
        changedAny, topologyChanged = true, true
    end
    ImGui.EndDisabled()
    style.tooltip("Remove this control point.")

    if point.dir and not topologyChanged then
        ImGui.SetCursorPosX(120)
        local heading, slope = directionToAngles(point.dir)
        local headingChanged, slopeChanged
        heading, headingChanged = field.advancedTrackedFloat(self.object, "##curvePointHeading", heading, { suffix = " Heading", width = 96, step = 0.1 })
        style.tooltip("Tangent direction around the mesh's up axis, in degrees. 0 points along +Y, positive turns left.")
        ImGui.SameLine()
        slope, slopeChanged = field.advancedTrackedFloat(self.object, "##curvePointSlope", slope, { suffix = " Slope", width = 84, step = 0.1, min = -89.9, max = 89.9 })
        style.tooltip("Tangent slope in degrees.")
        if headingChanged or slopeChanged then
            point.dir = anglesToDirection(heading, slope)
            changedAny = true
        end

        ImGui.SameLine()
        ImGui.Dummy(8 * style.viewSize, 0)
        ImGui.SameLine()
        point.lenIn, changed = field.advancedTrackedFloat(self.object, "##curvePointLenIn", point.lenIn or tangent.lenIn, { suffix = " In", width = 60, min = 0 })
        changedAny = changedAny or changed
        style.tooltip("Length of the incoming handle. Longer keeps the direction further into the curve.")
        ImGui.SameLine()
        point.lenOut, changed = field.advancedTrackedFloat(self.object, "##curvePointLenOut", point.lenOut or tangent.lenOut, { suffix = " Out", width = 60, min = 0 })
        changedAny = changedAny or changed
        style.tooltip("Length of the outgoing handle.")
    end

    return changedAny, topologyChanged
end

function bendedMesh:drawCurveEditor()
    self:ensurePathPoints()

    local needsUpdate = false
    local topologyChanged = false
    local changed

    style.mutedText("Up Axis")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.pathUpAxis, changed = style.trackedCombo(self.object, "##pathUpAxis", self.pathUpAxis, pathUpAxisOptions, 160, {
        tooltip = "Reference axis for constructing local right/up basis from path direction"
    })
    needsUpdate = needsUpdate or changed

    style.mutedText("Loop Path")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.pathLooped, changed = style.trackedCheckbox(self.object, "##pathLooped", self.pathLooped)
    needsUpdate = needsUpdate or changed

    style.mutedText("Length Mode")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local lengthIndex
    lengthIndex, changed = style.trackedCombo(self.object, "##pathLengthMode", self.pathLengthMode - 1, lengthModeOptions, 180, {
        tooltip = "Fit to Curve spreads the bones over the whole curve; the mesh stretches to its length.\nKeep Rest Length places the bones at the mesh's own spacing from the start; the mesh ends where its length runs out, or carries on straight past the last point."
    })
    if changed then
        self.pathLengthMode = math.max(1, math.min(math.floor(lengthIndex) + 1, #lengthModeOptions))
    end
    needsUpdate = needsUpdate or changed

    ImGui.Dummy(0, 8 * style.viewSize)
    local bones = self:getMeshBonesQuantity()
    style.mutedText("Mesh bones quantity : " .. (bones and tostring(bones) or "Unknown") .. " " .. IconGlyphs.Bone)
    style.tooltip("Bones are placed along the curve automatically.")

    local curveLength, restLength = self:getCurveLength()
    if restLength and restLength > 0.000001 then
        if self.pathLengthMode == LENGTH_MODE_KEEP and not self.pathLooped then
            style.mutedText(string.format("Length : curve %.2f m, mesh %.2f m", curveLength, restLength))
        else
            local stretch = (curveLength / restLength - 1) * 100
            local text = string.format("Length : %.2f m (rest %.2f m, %+.1f%%)", curveLength, restLength, stretch)
            if math.abs(stretch) > 2 then
                style.styledText(IconGlyphs.AlertOutline .. " " .. text, 0xFF4CB8FF)
            else
                style.mutedText(text)
            end
        end
    else
        style.mutedText(string.format("Length : %.2f m", curveLength))
    end
    style.tooltip("Curve length in the mesh's own units (before scale).")

    if bendedRig.get(self.spawnData) and not self:getRig() then
        style.styledTextWrapped(IconGlyphs.AlertOutline .. "  This mesh's bones form a grid rather than a line, so a path cannot drive them correctly.", style.extraMutedColor)
    end

    local tangents = self:getCurveTangents()
    for index, point in ipairs(self.curvePoints) do
        ImGui.PushID("curvePoint" .. index)

        if index == 1 then
            ImGui.Text(IconGlyphs.SourceCommitStart)
        elseif index == #self.curvePoints then
            ImGui.Text(IconGlyphs.SourceCommitEnd)
        else
            ImGui.Text(IconGlyphs.SourceCommit)
        end
        ImGui.SameLine()
        style.mutedText(tostring(index))
        ImGui.SameLine()
        ImGui.SetCursorPosX(120)

        local pointChanged, pointTopology = self:drawCurvePointEditor(index, point, tangents[index])
        needsUpdate = needsUpdate or pointChanged
        topologyChanged = topologyChanged or pointTopology

        ImGui.PopID()
        if pointTopology then break end
    end

    if ImGui.Button(IconGlyphs.PlusCircleOutline .. "##appendCurvePoint") then
        history.addAction(history.getElementChange(self.object))
        self:appendCurvePoint()
        needsUpdate, topologyChanged = true, true
    end
    style.tooltip("Add a control point past the end, along the end tangent.")
    ImGui.Dummy(0, 8 * style.viewSize)

    if needsUpdate then
        self:ensurePathPoints()
        self:autoFitDeformedBox()
        self:refreshArrowScale()
    end
end

function bendedMesh:drawPathEditor()
    style.mutedText("Edit Mode")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local modeIndex, modeChanged = style.trackedCombo(self.object, "##pathMode", self.pathMode - 1, pathModeOptions, 180, {
        tooltip = "Curve: place a few control points, the bones follow the curve.\nBones: edit every bone of the rig, anchoring the ones to keep."
    })
    if modeChanged then
        self:setPathMode(math.max(1, math.min(math.floor(modeIndex) + 1, #pathModeOptions)))
        self:autoFitDeformedBox()
        self:refreshArrowScale()
    end

    if self:isCurveMode() then
        self:drawCurveEditor()
        return
    end

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

    style.mutedText("Bone Placement")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local solverIndex
    solverIndex, changed = style.trackedCombo(self.object, "##pathSolver", self.pathSolver - 1, pathSolverOptions, 180, {
        tooltip = "Along Curve spaces non-anchored bones along the curve with the rig's own spacing, so the mesh does not stretch unevenly, and bends the ends along the curve.\nBy Index places them at even steps of the curve parameter, as older projects did."
    })
    if changed then
        self.pathSolver = math.max(1, math.min(math.floor(solverIndex) + 1, #pathSolverOptions))
        self:applyPathAlgorithmToNonAnchored()
    end
    pathVisualizationNeedsUpdate = pathVisualizationNeedsUpdate or changed

    ImGui.Dummy(0, 8 * style.viewSize)
    style.mutedText("Mesh bones quantity : " .. (meshBonesQuantity and tostring(meshBonesQuantity) or "Unknown") .. " " .. IconGlyphs.Bone)
    style.tooltip("Each bended mesh has a rig with specific number of bones.\nEach deformation point refers to a mesh bone.")

    local pathLength, restLength = self:getPathLengths()
    if restLength and restLength > 0.000001 then
        local stretch = (pathLength / restLength - 1) * 100
        local text = string.format("Length : %.2f m (rest %.2f m, %+.1f%%)", pathLength, restLength, stretch)
        if math.abs(stretch) > 2 then
            style.styledText(IconGlyphs.AlertOutline .. " " .. text, 0xFF4CB8FF)
        else
            style.mutedText(text)
        end
    else
        style.mutedText(string.format("Length : %.2f m", pathLength))
    end
    style.tooltip("Path length through the bones, in the mesh's own units (before scale).\nAway from the rest length, the mesh stretches or squashes.")

    if bendedRig.get(self.spawnData) and not self:getRig() then
        style.styledTextWrapped(IconGlyphs.AlertOutline .. "  This mesh's bones form a grid rather than a line, so a path cannot drive them correctly.", style.extraMutedColor)
    end

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
    if ImGui.Button("Continue From End") and canCreateContinuation then
        self:createContinuationMesh(false)
    end
    style.tooltip("Create a new bended mesh of the same asset joined to the end of this one.")
    ImGui.SameLine()
    if ImGui.Button("Continue From Start") and canCreateContinuation then
        self:createContinuationMesh(true)
    end
    style.tooltip("Create a new bended mesh of the same asset joined to the start of this one.")
    ImGui.EndDisabled()
    ImGui.SameLine()
    self.continuationRepeatShape, _ = style.trackedCheckbox(self.object, "Repeat Curve##continuationRepeatShape", self.continuationRepeatShape)
    style.tooltip("The new mesh repeats this mesh's curve instead of starting straight.")

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
            "Bone Placement",
            "Edit Mode",
            "Length Mode",
            "Mesh bones quantity",
            "Deformed Preview",
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
