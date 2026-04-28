local utils = require("modules/utils/utils")
local EPSILON = 0.00001

local intersection = {}

---@alias axisAlignedBBox { min: {x: number, y: number, z: number}, max: {x: number, y: number, z: number} }
---@alias raycastHit { hit: boolean, position: Vector4, distance: number, normal: Vector4 }

---Reverses special-case bbox scaling for assets that are post-adjusted during intersection tests.
---@param path string Resource path used to resolve special scaling overrides.
---@param initialScale Vector4 Original object scale before any intersection-specific overrides.
---@param bbox axisAlignedBBox Bounding box that was previously scaled for intersection checks.
---@return axisAlignedBBox unscaledBBox Bounding box restored toward original dimensions when unscale is enabled.
function intersection.unscaleBBox(path, initialScale, bbox)
    local scale, unscale = intersection.getResourcePathScalingFactor(path, initialScale)
    if not unscale then return bbox end

    return {
        min = {
            x = bbox.min.x / scale.x,
            y = bbox.min.y / scale.y,
            z = bbox.min.z / scale.z
        },
        max = {
            x = bbox.max.x / scale.x,
            y = bbox.max.y / scale.y,
            z = bbox.max.z / scale.z
        }
    }
end

---Scales each axis of a bounding box by the provided scale vector.
---@param bbox axisAlignedBBox Source axis-aligned bounding box.
---@param scale Vector4 Per-axis scale multiplier.
---@return axisAlignedBBox scaledBBox Scaled bounding box.
function intersection.scaleBBox(bbox, scale)
    return {
        min = {
            x = bbox.min.x * scale.x,
            y = bbox.min.y * scale.y,
            z = bbox.min.z * scale.z
        },
        max = {
            x = bbox.max.x * scale.x,
            y = bbox.max.y * scale.y,
            z = bbox.max.z * scale.z
        }
    }
end

---Resolves path-specific bbox scale compensation used by picking/drop-to-surface logic.
---Special cases cover assets with known oversized/undersized mesh bounds (vegetation, AMM shuttle, FX).
---@param path string Resource path used for hardcoded scale heuristics.
---@param initalScale Vector4 Current object scale (parameter name kept for backward compatibility).
---@return Vector4 scaleFactor Per-axis bbox factor to apply for intersection checks.
---@return boolean shouldUnscale True when `unscaleBBox` should be applied for accurate drop-to-surface placement.
function intersection.getResourcePathScalingFactor(path, initalScale)
    if string.match(path, "base\\environment\\vegetation\\palms\\") or string.match(path, "yucca") then
        return Vector4.new(0.175, 0.175, 0.7, 0), false
    end

    if (string.match(path, "base\\environment\\vegetation\\") or string.match(path, "[^s]tree")) and not (string.match(path, "base\\environment\\vegetation\\debris") or string.match(path, "base\\environment\\vegetation\\grass\\lawn")) then
        return Vector4.new(0.35, 0.35, 0.7, 0), false
    end

    if path == "base\\amm_props\\mesh\\props\\shuttle.mesh" or path == "base\\amm_props\\mesh\\props\\shuttle_platform.mesh" then
        return Vector4.new(21 / 20000, 26 / 20000, 165 / 80000, 0), false
    end

    if string.match(path, "\\fx\\") then
        return Vector4.new(0, 0, 0, 0), false
    end

    local newScale = Vector4.new(1, 1, 1, 0)
    if initalScale.x > 0.1 then
        newScale.x = 0.95
    end
    if initalScale.y > 0.1 then
        newScale.y = 0.95
    end
    if initalScale.z > 0.1 then
        newScale.z = 0.95
    end

    return newScale, true
end

---Ensures each bbox axis has a minimal non-zero thickness to avoid degenerate ray math.
---@param bBox axisAlignedBBox Bounding box to normalize for intersection safety.
---@return axisAlignedBBox clampedBBox Deep-copied bbox with tiny axes widened.
local function clampBBox(bBox)
    bBox = utils.deepcopy(bBox)

    local scale = Vector4.new(bBox.max.x - bBox.min.x, bBox.max.y - bBox.min.y, bBox.max.z - bBox.min.z, 0)

    local axis = { "x", "y", "z" }

    for _, axisName in pairs(axis) do
        if math.abs(scale[axisName]) < 0.01 then
            bBox.min[axisName] = bBox.min[axisName] - 0.005
            bBox.max[axisName] = bBox.max[axisName] + 0.005
        end
    end

    return bBox
end

---Tests whether one oriented bounding box is inside another.
---Current implementation checks transformed `min` and `max` corners of the inner box against the outer OBB.
---@param outerOrigin Vector4 Outer box world origin.
---@param outerRotation EulerAngles Outer box world rotation.
---@param outerBox axisAlignedBBox Outer local-space bounds.
---@param innerOrigin Vector4 Inner box world origin.
---@param innerRotation EulerAngles Inner box world rotation.
---@param innerBox axisAlignedBBox Inner local-space bounds.
---@return boolean isInside True when tested inner corners are inside the outer box.
function intersection.BBoxInsideBBox(outerOrigin, outerRotation, outerBox, innerOrigin, innerRotation, innerBox)
    innerBox = clampBBox(innerBox)
    outerBox = clampBBox(outerBox)

    local min = utils.addVector(innerOrigin, innerRotation:ToQuat():Transform(ToVector4(innerBox.min)))
    local max = utils.addVector(innerOrigin, innerRotation:ToQuat():Transform(ToVector4(innerBox.max)))

    return intersection.pointInsideBox(min, outerOrigin, outerRotation, outerBox) and intersection.pointInsideBox(max, outerOrigin, outerRotation, outerBox)
end

---Checks whether a world-space point lies inside an oriented bounding box.
---@param point Vector4 Point in world space.
---@param boxOrigin Vector4 Box origin in world space.
---@param boxRotation EulerAngles Box orientation in world space.
---@param box axisAlignedBBox Box local-space min/max bounds (expected clamped).
---@return boolean inside True when point projection is within all local axis ranges.
function intersection.pointInsideBox(point, boxOrigin, boxRotation, box)
    local matrix = Matrix.BuiltRTS(boxRotation, boxOrigin, Vector4.new(1, 1, 1, 0))

    local delta = utils.subVector(point, boxOrigin)

    local axis = {
        ["x"] = matrix:GetAxisX(),
        ["y"] = matrix:GetAxisY(),
        ["z"] = matrix:GetAxisZ()
    }

    for axisName, axisDirection in pairs(axis) do
        local e = axisDirection:Dot(delta) -- Distance of ray origin to box origin along the box's x/y/z axis

        if e < box.min[axisName] or e > box.max[axisName] then
            return false
        end
    end

    return true
end

---Computes candidate face normals for a hit position on an oriented bounding box.
---@param boxOrigin Vector4 Box origin in world space.
---@param boxRotation EulerAngles Box orientation in world space.
---@param box axisAlignedBBox Box local-space bounds (expected clamped).
---@param hitPosition Vector4 World-space hit position on/near box surface.
---@return Vector4[] normals Candidate outward normals for touching faces (can contain multiple normals on edges/corners).
function intersection.getBoxIntersectionNormals(boxOrigin, boxRotation, box, hitPosition)
    local matrix = Matrix.BuiltRTS(boxRotation, boxOrigin, Vector4.new(1, 1, 1, 0))

    local delta = utils.subVector(hitPosition, boxOrigin)

    local axis = {
        ["x"] = matrix:GetAxisX(),
        ["y"] = matrix:GetAxisY(),
        ["z"] = matrix:GetAxisZ()
    }

    local normals = {}

    for axisName, axisDirection in pairs(axis) do
        local e = axisDirection:Dot(delta) -- Distance of ray origin to box origin along the box's x/y/z axis

        if e < box.min[axisName] + EPSILON * 10 then -- For some reason needs higher epsilon, especially for y-axis
            table.insert(normals, utils.multVector(axisDirection, -1))
        end

        if e > box.max[axisName] - EPSILON * 10 then
            table.insert(normals, axisDirection)
        end
    end

    return normals
end

--https://github.com/opengl-tutorials/ogl/blob/master/misc05_picking/misc05_picking_custom.cpp
---Performs ray-vs-OBB intersection and returns the closest forward hit.
---@param rayOrigin Vector4 Ray origin in world space.
---@param ray Vector4 Ray direction (normalization not required; normalized internally for hit position).
---@param boxOrigin Vector4 OBB origin in world space.
---@param boxRotation EulerAngles OBB orientation in world space.
---@param box axisAlignedBBox OBB local-space bounds.
---@return raycastHit hitResult Hit data with point, distance parameter `t`, and approximated face normal.
function intersection.getBoxIntersection(rayOrigin, ray, boxOrigin, boxRotation, box)
    box = clampBBox(box)

    local matrix = Matrix.BuiltRTS(boxRotation, boxOrigin, Vector4.new(1, 1, 1, 0))

    local tMin = 0
    local tMax = math.huge

    local delta = utils.subVector(boxOrigin, rayOrigin)

    local axis = {
        ["x"] = matrix:GetAxisX(),
        ["y"] = matrix:GetAxisY(),
        ["z"] = matrix:GetAxisZ()
    }

    for axisName, axisDirection in pairs(axis) do
        local e = axisDirection:Dot(delta) -- Distance of ray origin to box origin along the box's x/y/z axis
        local f = ray:Dot(axisDirection) -- Scale t value based on rotation of the box axis relative to ray, since shallower angle would mean bigger t

        if math.abs(f) > EPSILON then
            local t1 = (e + box.min[axisName]) / f
            local t2 = (e + box.max[axisName]) / f

            if t1 > t2 then
                t1, t2 = t2, t1
            end

            if t2 < tMax then
                tMax = t2
            end

            if t1 > tMin then
                tMin = t1
            end

            if tMin > tMax then
                return { hit = false, position = Vector4.new(0, 0, 0, 0), distance = 0, normal = Vector4.new(0, 0, 0, 0) }
            end
        elseif -e + box.min[axisName] > 0 or -e + box.max[axisName] < 0 then  -- TODO: Fix eddgecase of ray being parallel to box axis, not working if bbox is offcenter (E.g. 0,0,0;1,1,1)
            return { hit = false, position = Vector4.new(0, 0, 0, 0), distance = 0, normal = Vector4.new(0, 0, 0, 0) }
        end
    end

    local position = utils.addVector(rayOrigin, utils.multVector(ray:Normalize(), tMin))
    local normal = intersection.getBoxIntersectionNormals(boxOrigin, boxRotation, box, position)[1] or Vector4.new(0, 0, 0, 0)

    return { hit = true, position = position, normal = normal, distance = tMin }
end

---Performs ray-vs-sphere intersection and returns the nearest forward hit.
---@param rayOrigin Vector4 Ray origin in world space.
---@param ray Vector4 Ray direction vector.
---@param sphereOrigin Vector4 Sphere center in world space.
---@param sphereRadius number Sphere radius.
---@return raycastHit hitResult Hit data with point, distance parameter `t`, and outward normal.
function intersection.getSphereIntersection(rayOrigin, ray, sphereOrigin, sphereRadius)
    local delta = utils.subVector(sphereOrigin, rayOrigin)

    local a = ray:Dot(ray)
    local b = 2 * ray:Dot(delta)
    local c = delta:Dot(delta) - sphereRadius * sphereRadius
    local discriminant = b * b - 4 * a * c

    if discriminant < 0 then
        return { hit = false, position = Vector4.new(0, 0, 0, 0), distance = 0, normal = Vector4.new(0, 0, 0, 0) }
    else
        local t = - (-b - math.sqrt(discriminant)) / (2 * a)

        if t < 0 then
            return { hit = false, position = Vector4.new(0, 0, 0, 0), distance = 0, normal = Vector4.new(0, 0, 0, 0) }
        end

        local position = utils.addVector(rayOrigin, utils.multVector(ray:Normalize(), t))
        return { hit = true, position = position, distance = t, normal = utils.subVector(position, sphereOrigin):Normalize() }
    end
end

---Performs ray-vs-plane intersection.
---@param rayOrigin Vector4 Ray origin in world space.
---@param ray Vector4 Ray direction vector.
---@param planeOrigin Vector4 Any point on the plane.
---@param planeNormal Vector4 Plane normal vector.
---@return { hit: boolean, position: Vector4, distance: number } hitResult Plane hit data (`distance` is ray parameter `t`).
function intersection.getPlaneIntersection(rayOrigin, ray, planeOrigin, planeNormal)
    local angle = planeNormal:Dot(ray)

    if (math.abs(angle) > EPSILON) then
        local originToPlane = utils.subVector(planeOrigin, rayOrigin)
        local t = originToPlane:Dot(planeNormal) / angle
        return { hit = true, position = utils.addVector(rayOrigin, utils.multVector(ray:Normalize(), t)), distance = t }
    end

    return { hit = false, position = Vector4.new(0, 0, 0, 0), distance = 0 }
end

--https://underdisc.net/blog/6_gizmos/index.html
---Finds closest-approach parameters between two infinite rays/lines.
---@param aRayOrigin Vector4 First ray origin.
---@param aRayDirection Vector4 First ray direction.
---@param bRayOrigin Vector4 Second ray origin.
---@param bRayDirection Vector4 Second ray direction.
---@return number ta Parameter on ray A at closest approach.
---@return number tb Parameter on ray B at closest approach.
function intersection.getTClosestToRay(aRayOrigin, aRayDirection, bRayOrigin, bRayDirection)
    local originDirection = utils.subVector(aRayOrigin, bRayOrigin)
    local ab = aRayDirection:Dot(bRayDirection)
    local aOrigin = aRayDirection:Dot(originDirection)
    local bOrigin = bRayDirection:Dot(originDirection)
    local denom = 1.0 - ab * ab

    if math.abs(denom) < EPSILON then
        return 0, 0
    end

    local ta = (-aOrigin + ab * bOrigin) / denom
    local tb = ab * ta + bOrigin

    return ta, tb
end

return intersection
