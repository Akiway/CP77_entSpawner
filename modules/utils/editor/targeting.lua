local history = require("modules/utils/project/history")
local utils = require("modules/utils/core/utils")

---@class editorTargeting
local targeting = {}

---Normalize a direction vector and discard near-zero magnitudes.
---@param vec Vector4?
---@return Vector4?
function targeting.normalizeDirection(vec)
    if not vec then
        return nil
    end

    local length = vec:Length()
    if length <= 0.00001 then
        return nil
    end

    return Vector4.new(vec.x / length, vec.y / length, vec.z / length, 0)
end

---Resolve an element aiming position (center preferred, then position).
---@param targetElement element?
---@return Vector4?
function targeting.getTargetPosition(targetElement)
    if not targetElement then
        return nil
    end

    if type(targetElement.getCenter) == "function" then
        local center = targetElement:getCenter()
        if center then
            return center
        end
    end

    if type(targetElement.getPosition) == "function" then
        return targetElement:getPosition()
    end

    return nil
end

---Compute a look-at rotation from source transform to target world position.
---@param currentRotation EulerAngles?
---@param sourcePosition Vector4?
---@param targetPosition Vector4?
---@return EulerAngles?
function targeting.getLookAtRotation(currentRotation, sourcePosition, targetPosition)
    if not currentRotation or not sourcePosition or not targetPosition then
        return nil
    end

    local toTarget = utils.subVector(targetPosition, sourcePosition)
    local targetForward = targeting.normalizeDirection(toTarget)
    if not targetForward then
        return nil
    end

    local currentForward = targeting.normalizeDirection(currentRotation:GetForward())
    if not currentForward then
        local fallback = toTarget:ToRotation()
        return EulerAngles.new(0, fallback.pitch, fallback.yaw)
    end

    local dot = math.max(-1, math.min(1, currentForward:Dot(targetForward)))
    if dot > 0.999999 then
        return EulerAngles.new(currentRotation.roll, currentRotation.pitch, currentRotation.yaw)
    end

    local axis = currentForward:Cross(targetForward)
    if axis:Length() <= 0.00001 then
        axis = currentRotation:GetUp():Cross(targetForward)
    end
    if axis:Length() <= 0.00001 then
        axis = Vector4.new(0, 0, 1, 0):Cross(targetForward)
    end
    if axis:Length() <= 0.00001 then
        return nil
    end

    local rotationQuat = currentRotation:ToQuat()
    local localAxis = rotationQuat:TransformInverse(axis:Normalize()):Normalize()
    local deltaQuat = Quaternion.SetAxisAngle(localAxis, math.acos(dot))
    local targetQuat = utils.multQuat(rotationQuat, deltaQuat)

    return targetQuat:ToEulerAngles()
end

---Compare Euler angles using an absolute per-axis epsilon.
---@param a EulerAngles?
---@param b EulerAngles?
---@param epsilon number?
---@return boolean
function targeting.eulerNearlyEqual(a, b, epsilon)
    if not a or not b then
        return false
    end

    local threshold = epsilon or 0.001
    return math.abs(a.roll - b.roll) <= threshold
        and math.abs(a.pitch - b.pitch) <= threshold
        and math.abs(a.yaw - b.yaw) <= threshold
end

---Validate whether an element can be targeted by another element.
---@param sourceElement spawnableElement?
---@param targetElement element?
---@param options table?
---@return boolean
function targeting.canAimElementAtElement(sourceElement, targetElement, options)
    if not sourceElement or not targetElement then
        return false
    end

    local allowSelf = options and options.allowSelf
    if not allowSelf and sourceElement == targetElement then
        return false
    end

    return targeting.getTargetPosition(targetElement) ~= nil
end

---Aim an element at a world position and apply rotation changes when needed.
---@param sourceElement spawnableElement?
---@param targetPosition Vector4?
---@param options table?
---@return boolean changed
function targeting.aimElementAtWorldPosition(sourceElement, targetPosition, options)
    if not sourceElement or not targetPosition then
        return false
    end

    if sourceElement.isLocked and sourceElement:isLocked() then
        return false
    end
    if sourceElement.rotationLocked then
        return false
    end
    if type(sourceElement.getPosition) ~= "function"
        or type(sourceElement.getRotation) ~= "function"
        or type(sourceElement.setRotation) ~= "function" then
        return false
    end

    local sourcePosition = sourceElement:getPosition()
    local sourceRotation = sourceElement:getRotation()
    local targetRotation = targeting.getLookAtRotation(sourceRotation, sourcePosition, targetPosition)
    if not targetRotation or targeting.eulerNearlyEqual(sourceRotation, targetRotation, options and options.epsilon) then
        return false
    end

    if options == nil or options.recordHistory ~= false then
        history.addAction(history.getElementChange(sourceElement))
    end
    sourceElement:setRotation(targetRotation)
    if type(sourceElement.onEdited) == "function" then
        sourceElement:onEdited()
    end

    return true
end

---Aim an element at another element's resolved target position.
---@param sourceElement spawnableElement?
---@param targetElement element?
---@param options table?
---@return boolean changed
function targeting.aimElementAtElement(sourceElement, targetElement, options)
    if not targeting.canAimElementAtElement(sourceElement, targetElement, options) then
        return false
    end

    return targeting.aimElementAtWorldPosition(sourceElement, targeting.getTargetPosition(targetElement), options)
end

return targeting
