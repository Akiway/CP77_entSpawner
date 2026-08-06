local utils = require("modules/utils/core/utils")

---Shared elevator (lift) door layout data and geometry.
---Used by both the device spawnable (floor setup) and the editor viewport door helper overlay,
---so the layout families and marker anchors stay in sync between them.
---@class elevatorDoors
local elevatorDoors = {}

---@alias elevatorDoorSide "left"|"right"|"top"|"bottom"
---@alias elevatorDoorLayout table<integer, elevatorDoorSide>

---Door side per door index, keyed by lift family.
---@type table<string, elevatorDoorLayout>
elevatorDoors.LAYOUTS = {
    common = {
        [1] = "left",
        [2] = "right"
    },
    megabuilding = {
        [1] = "right",
        [2] = "bottom",
        [3] = "top"
    },
    commonRiot = {
        [1] = "left",
        [2] = "bottom"
    },
    industrial = {
        [1] = "left",
        [2] = "right"
    },
    construction = {
        [1] = "right",
        [2] = "left"
    }
}

---Optional per-family 2D rotation applied to side mappings before world projection.
---Used to align helper numbering with in-game lift orientation variants.
---@type table<string, "cw"|"ccw">
elevatorDoors.LAYOUT_ROTATIONS = {
    common = "ccw",
    industrial = "cw",
    construction = "ccw"
}

---Resolves the canonical door layout family from entity spawn path text.
---Returns both layout table and a stable family key used for post-layout rotation rules.
---@param spawnData string?
---@return elevatorDoorLayout
---@return string layoutKey
function elevatorDoors.resolveLayout(spawnData)
    local normalized = string.lower(tostring(spawnData or ""))

    if string.find(normalized, "megabuilding", 1, true) then
        return elevatorDoors.LAYOUTS.megabuilding, "megabuilding"
    end

    if string.find(normalized, "common_riot", 1, true) or string.find(normalized, "riot", 1, true) then
        return elevatorDoors.LAYOUTS.commonRiot, "commonRiot"
    end

    if string.find(normalized, "industrial", 1, true) then
        return elevatorDoors.LAYOUTS.industrial, "industrial"
    end

    if string.find(normalized, "construction", 1, true) then
        return elevatorDoors.LAYOUTS.construction, "construction"
    end

    return elevatorDoors.LAYOUTS.common, "common"
end

---Rotates a door side label in screen-planar space.
---`cw` means 90 degrees clockwise; `ccw` means 90 degrees counter-clockwise.
---@param side elevatorDoorSide?
---@param rotation "cw"|"ccw"|nil
---@return elevatorDoorSide?
function elevatorDoors.rotateSide(side, rotation)
    if not side then
        return nil
    end

    if rotation == "cw" then
        local cw = {
            left = "top",
            top = "right",
            right = "bottom",
            bottom = "left"
        }

        return cw[side] or side
    end

    if rotation == "ccw" then
        local ccw = {
            left = "bottom",
            bottom = "right",
            right = "top",
            top = "left"
        }

        return ccw[side] or side
    end

    return side
end

---Resolves the world-space anchor point of one lift door marker.
---Anchors are estimated from the lift AABB envelope and then transformed by lift rotation.
---This is intentionally approximate and can be replaced by per-lift custom local offsets.
---@param lift spawnable
---@param side elevatorDoorSide
---@return Vector4?
function elevatorDoors.getMarkerWorldPosition(lift, side)
    if not lift or not lift.position or not lift.rotation or not lift.getBBox then
        return nil
    end

    local bbox = lift:getBBox()
    if not bbox or not bbox.min or not bbox.max then
        return nil
    end

    local minX = tonumber(bbox.min.x) or -0.5
    local minY = tonumber(bbox.min.y) or -0.5
    local minZ = tonumber(bbox.min.z) or -0.5
    local maxX = tonumber(bbox.max.x) or 0.5
    local maxY = tonumber(bbox.max.y) or 0.5
    local maxZ = tonumber(bbox.max.z) or 0.5

    local sizeX = math.max(0.01, maxX - minX)
    local sizeY = math.max(0.01, maxY - minY)
    local sizeZ = math.max(0.01, maxZ - minZ)

    local padding = math.max(0.15, math.min(1.0, math.max(sizeX, sizeY) * 0.12))
    local localPoint = Vector4.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, minZ + sizeZ * 0.45, 0)

    if side == "left" then
        localPoint.x = minX - padding
    elseif side == "right" then
        localPoint.x = maxX + padding
    elseif side == "top" then
        localPoint.y = maxY + padding
    elseif side == "bottom" then
        localPoint.y = minY - padding
    end

    local worldPoint = lift.rotation:ToQuat():Transform(localPoint)
    return utils.addVector(lift.position, worldPoint)
end

return elevatorDoors
