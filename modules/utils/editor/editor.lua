local utils = require("modules/utils/utils")
local input = require("modules/utils/input")
local intersection = require("modules/utils/editor/intersection")
local settings = require("modules/utils/settings")
local visualizer = require("modules/utils/visualizer")
local history = require("modules/utils/history")
local style = require("modules/ui/style")
local projectedWireframe = require("modules/utils/editor/projectedWireframe")

---@class editor
---@field active boolean
---@field camera camera?
---@field baseUI baseUI?
---@field spawnedUI spawnedUI?
---@field spawnUI spawnUI?
---@field suspendState boolean
---@field hoveredArrow string
---@field currentAxis string
---@field originalDiff table?
---@field grab boolean
---@field rotate boolean
---@field scale boolean
---@field dragging boolean
---@field originalPosition Vector4?
---@field originalRotation EulerAngles?
---@field originalScale Vector4?
---@field originalRotationQuat Quaternion?
---@field rotationAxisWorld Vector4?
---@field interface gamestateMachineGameScriptInterface?
---@field depthSelectElements table
---@field depthSelectOpen boolean
---@field depthElementsMaxWidth number
---@field boxSelectActive boolean
---@field boxSelectStart table
---@field freeflyWasActive boolean
local editor = {
    active = false,
    camera = nil,
    baseUI = nil,
    spawnedUI = nil,
    spawnUI = nil,
    suspendState = false,
    hoveredArrow = "none",
    currentAxis = "none",
    originalDiff = {pos = nil, rot = nil, scale = nil},
    dragging = false,
    grab = false,
    rotate = false,
    scale = false,
    originalPosition = nil,
    originalRotation = nil,
    originalScale = nil,
    originalRotationQuat = nil,
    rotationAxisWorld = nil,
    interface = nil,
    depthSelectElements = {},
    depthSelectOpen = false,
    depthElementsMaxWidth = 0,
    boxSelectActive = false,
    boxSelectStart = { x = 0, y = 0 },
    wireframeCacheEpoch = -1,
    wireframeLeafCache = {},
    wireframeBoundsCache = {},
    wireframeMultiLeafCache = nil,

    freeflyWasActive = false
}

---Checks whether the editor viewport currently has keyboard focus.
---@return boolean focused True when the editor is active and the viewport is focused.
function viewportFocused()
    return editor.active and input.context.viewport.focused
end

---Checks whether the editor viewport is currently hovered by the mouse.
---@return boolean hovered True when the editor is active and the viewport is hovered.
function viewportHovered()
    return editor.active and input.context.viewport.hovered
end

---Ends active group-rotation drag state when the current selection is a group.
local function clearGroupRotationDragState()
    local selected = editor.getSelected()
    if selected and selected.endRotationDrag and utils.isA(selected, "positionableGroup") then
        selected:endRotationDrag()
    end
end

---Cancels the current transform operation and restores the original transform snapshot.
---Note: function name keeps the historical typo for compatibility.
function editor.cancleEditingTransform()
    editor.grab = false
    editor.rotate = false
    editor.scale = false

    local element = editor.getSelected()
    if not element or editor.currentAxis == "none" then return end
    editor.currentAxis = "none"
    element:setPosition(editor.originalPosition)
    element:setRotation(editor.originalRotation)
    element:setScale(editor.originalScale, true)

    editor.originalDiff.pos = nil
    editor.originalDiff.rot = nil
    editor.originalDiff.scale = nil
    editor.originalRotationQuat = nil
    editor.rotationAxisWorld = nil
    clearGroupRotationDragState()
    input.trackNumeric(false)
end

---Confirms current interaction by recording edits or selecting under cursor when idle.
---@return boolean handled
local function tryResolveHierarchyPickFromWorld()
    if not editor.spawnedUI
        or type(editor.spawnedUI.isHierarchyPickActive) ~= "function"
        or type(editor.spawnedUI.resolveHierarchyPick) ~= "function"
        or not editor.spawnedUI.isHierarchyPickActive() then
        return false
    end

    local player = GetPlayer()
    if not player then
        return false
    end

    local excludeIds = nil
    local request = editor.spawnedUI.hierarchyPickRequest
    if request and request.ownerId then
        excludeIds = { [request.ownerId] = true }
    end

    local ray = editor.getScreenToWorldRay()
    local origin = player:GetFPPCameraComponent():GetLocalToWorld():GetTranslation()
    local hit = editor.getRaySceneIntersection(ray, origin, excludeIds, true)
    if not hit.hit or not hit.result or not hit.result.position then
        return false
    end

    local hitPosition = hit.result.position
    local worldPickTarget = {
        getPosition = function()
            return hitPosition
        end
    }

    return editor.spawnedUI.resolveHierarchyPick(worldPickTarget)
end

function editor.confirmEditingTransform()
    if not editor.grab and not editor.rotate and not editor.scale and editor.hoveredArrow == "none" and not editor.spawnUI.popupSpawnHit then
        local hierarchyPickActive = editor.spawnedUI
            and type(editor.spawnedUI.isHierarchyPickActive) == "function"
            and editor.spawnedUI.isHierarchyPickActive()

        if hierarchyPickActive then
            tryResolveHierarchyPickFromWorld()
        else
            editor.setTarget()
        end
    end

    if editor.grab or editor.rotate or editor.scale then
        editor.recordChange()
    end

    editor.grab = false
    editor.rotate = false
    editor.scale = false
    editor.currentAxis = "none"
    editor.originalRotationQuat = nil
    editor.rotationAxisWorld = nil
    clearGroupRotationDragState()
    input.trackNumeric(false)
end

---Initializes editor dependencies and registers mouse/keyboard bindings.
---@param spawner spawner Main spawner runtime instance used to resolve UI modules.
function editor.init(spawner)
    editor.baseUI = spawner.baseUI
    editor.spawnedUI = spawner.baseUI.spawnedUI
    editor.spawnUI = spawner.baseUI.spawnUI

    editor.camera = require("modules/utils/editor/camera")

    input.registerMouseAction(ImGuiMouseButton.Right, function()
        editor.cancleEditingTransform()
    end, viewportHovered)
    input.registerMouseAction(ImGuiMouseButton.Left, function ()
        editor.confirmEditingTransform()
    end,
    function ()
        return editor.active and input.context.viewport.hovered
    end)

    input.registerImGuiHotkey({ ImGuiKey.Escape }, function()
        if editor.spawnedUI
            and type(editor.spawnedUI.isHierarchyPickActive) == "function"
            and editor.spawnedUI.isHierarchyPickActive()
            and type(editor.spawnedUI.cancelHierarchyPick) == "function" then
            editor.spawnedUI.cancelHierarchyPick()
            return
        end
        editor.cancleEditingTransform()
    end, viewportHovered)
    input.registerImGuiHotkey({ ImGuiKey.Enter }, function ()
        editor.confirmEditingTransform()
    end,
    function ()
        return editor.active and input.context.viewport.hovered
    end)

    input.registerImGuiHotkey({ ImGuiKey.Tab }, editor.centerCamera, function ()
        return editor.active and (input.context.viewport.focused or input.context.hierarchy.focused)
    end)

    input.registerImGuiHotkey({ ImGuiKey.G }, function ()
        editor.toggleTransform("translate")
    end, viewportHovered)

    input.registerImGuiHotkey({ ImGuiKey.R }, function ()
        if ImGui.IsKeyDown(ImGuiKey.LeftCtrl) then
            return
        end
        editor.toggleTransform("rotate")
    end, viewportHovered)

    input.registerImGuiHotkey({ ImGuiKey.S }, function ()
        editor.toggleTransform("scale")
    end, viewportHovered)

    input.registerImGuiHotkey({ ImGuiKey.X }, function ()
        if not (editor.grab or editor.rotate or editor.scale) then return end

        if ImGui.IsKeyDown(ImGuiKey.LeftShift) and not editor.rotate then
            editor.currentAxis = "yz"
        else
            editor.currentAxis = "x"
        end
        editor.updateArrowColor()
        editor.updateCurrentAxis()
    end, viewportHovered)

    input.registerImGuiHotkey({ ImGuiKey.Y }, function ()
        if not (editor.grab or editor.rotate or editor.scale) then return end

        if ImGui.IsKeyDown(ImGuiKey.LeftShift) and not editor.rotate then
            editor.currentAxis = "xz"
        else
            editor.currentAxis = "y"
        end
        editor.updateArrowColor()
        editor.updateCurrentAxis()
    end, viewportHovered)

    input.registerImGuiHotkey({ ImGuiKey.Z }, function ()
        if not (editor.grab or editor.rotate or editor.scale) then return end

        if ImGui.IsKeyDown(ImGuiKey.LeftShift) and not editor.rotate then
            editor.currentAxis = "xy"
        else
            editor.currentAxis = "z"
        end
        editor.updateArrowColor()
        editor.updateCurrentAxis()
    end, viewportHovered)

    input.registerImGuiHotkey({ ImGuiKey.LeftShift, ImGuiKey.D }, function ()
        local ray = editor.getScreenToWorldRay()
        local hit = editor.getRaySceneIntersection(ray, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), nil, false)

        if #hit.allHits == 0 then
            editor.depthSelectOpen = false
            return
        end

        editor.depthSelectOpen = true
        editor.depthSelectElements = hit.allHits
        table.sort(editor.depthSelectElements, function (a, b)
            return a.distance < b.distance
        end)

        local max = 0
        for _, hit in pairs(editor.depthSelectElements) do
            local x, _ = ImGui.CalcTextSize(string.format("[%.2f m]", hit.distance))
            max = math.max(max, x)
        end

        editor.depthElementsMaxWidth = max
    end, viewportHovered)

    input.registerImGuiHotkey({ ImGuiKey.A, ImGuiKey.LeftShift }, function ()
        editor.baseUI.spawnUI.openPopup = true
    end, viewportHovered)

    input.registerImGuiHotkey({ ImGuiKey.LeftCtrl, ImGuiKey.R }, function ()
        editor.baseUI.spawnUI.repeatLastSpawn()
    end, viewportHovered)

    Observe("LocomotionEventsTransition", "OnUpdate", function(_, _, _, interface)
        editor.interface = interface
    end)
end

---Gets the current editable selection.
---@return positionable? selected Single selected positionable, or multi-select proxy group, or nil.
function editor.getSelected()
    editor.spawnedUI.ensureCache()

    if #editor.spawnedUI.selectedPaths == 0 then return end

    if #editor.spawnedUI.selectedPaths == 1 then
        if editor.spawnedUI.selectedPaths[1].ref:isLocked() then
            return
        end
        if utils.isA(editor.spawnedUI.selectedPaths[1].ref, "positionable") then
            return editor.spawnedUI.selectedPaths[1].ref
        end
    else
        return editor.spawnedUI.multiSelectGroup
    end
end

---Centers the editor camera on the current selection.
function editor.centerCamera()
    if not editor.spawnedUI.selectedPaths[1] and editor.active then return end

    local singleTarget = editor.spawnedUI.selectedPaths[1].ref

    local pos = Vector4.new(singleTarget:getPosition())
    if utils.isA(singleTarget, "spawnableElement") then
        pos = Vector4.new(singleTarget.spawnable:getCenter())
    end

    if utils.distanceVector(pos, singleTarget:getPosition()) > 25 then
        pos = Vector4.new(singleTarget:getPosition())
    end

    local distance
    if #editor.spawnedUI.selectedPaths > 1 then
        pos = Vector4.new(spawnedUI.multiSelectGroup:getPosition())
        distance = editor.camera.distance
    elseif utils.isA(singleTarget, "spawnableElement") then -- Single spawnableElement
        local size = singleTarget.spawnable:getSize()
        distance = math.min(10, math.max(size.x, size.y, size.z, 1) * 2)
    else -- Single positionableGroup
        distance = editor.camera.distance
    end

    pos.z = pos.z - 1.5
    editor.camera.transition(editor.camera.cameraTransform.position, pos, editor.camera.cameraTransform.rotation, editor.camera.cameraTransform.rotation, distance, 0.5)
end

---Removes outline highlight from spawned entries.
---@param onlySelected boolean? When true, clear highlight only for selected paths; otherwise for all paths.
function editor.removeHighlight(onlySelected)
    local paths = onlySelected and editor.spawnedUI.selectedPaths or editor.spawnedUI.paths

    for _, selected in pairs(paths) do
        if utils.isA(selected.ref, "spawnableElement") then
            selected.ref.spawnable:setOutline(0)
        end
    end
end

---Applies outline highlight to all currently selected spawnable elements.
function editor.addHighlightToSelected()
    for _, selected in pairs(editor.spawnedUI.selectedPaths) do
        if utils.isA(selected.ref, "spawnableElement") then
            selected.ref.spawnable:setOutline(settings.outlineColor + 1)
        end
    end
end

---Builds a normalized world-space ray from a screen position.
---@param x number? Screen-space X coordinate in pixels. Defaults to current mouse X.
---@param y number? Screen-space Y coordinate in pixels. Defaults to current mouse Y.
---@return Vector4 ray Normalized world-space ray direction.
function editor.getScreenToWorldRay(x, y)
    if not x or not y then
        x, y = ImGui.GetMousePos()
    end
    local width, height = GetDisplayResolution()
    local _, ray = editor.camera.screenToWorld((x / width * 2) - 1, - ((y / height * 2) - 1))

    return ray:Normalize()
end

---Finds the nearest intersection between a ray and spawned elements or physical world geometry.
---@param ray Vector4 Normalized ray direction.
---@param origin Vector4 Ray origin in world space.
---@param excludeIds table<number, boolean>? Optional lookup table of element IDs to ignore.
---@param usePhysical boolean When true, physical raycast hits can override spawnable hits if closer.
---@return { hit: boolean, isNode: boolean, allHits: table[], result: table? } hitData Result payload including all spawnable hits and chosen hit.
function editor.getRaySceneIntersection(ray, origin, excludeIds, usePhysical)
    local hits = {}

    for _, element in pairs(editor.spawnedUI.paths) do
        if element.ref.visible and not element.ref:isLocked() and utils.isA(element.ref, "spawnableElement") then
            local hit = element.ref.spawnable:calculateIntersection(origin, ray)

            if hit.hit and (not excludeIds or (excludeIds and not excludeIds[element.ref.id])) then
                hit.element = element.ref
                table.insert(hits, hit)
            end
        end
    end

    local raycast = editor.interface:RaycastWithASingleGroup(origin, utils.addVector(origin, utils.multVector(ray, 9999)), "PlayerBlocker")

    if #hits == 0 then
        if raycast:IsValid() then
            return {
                result = {
                    position = Vector4.Vector3To4(raycast.position),
                    normal = Vector4.Vector3To4(raycast.normal)
                },
                isNode = false,
                hit = true,
                allHits = hits
            }
        end

        return { hit = false, isNode = false, allHits = hits }
    end

    table.sort(hits, function (a, b)
        return a.distance < b.distance
    end)

    -- If there is a hit inside the primary hit, use that one instead (To prefer things inside the bbox of the primary hit, can often be the case)
    local bestHitIdx = 1
    while bestHitIdx + 1 <= #hits and intersection.BBoxInsideBBox(hits[bestHitIdx].objectOrigin, hits[bestHitIdx].objectRotation, hits[bestHitIdx].bBox, hits[bestHitIdx + 1].objectOrigin, hits[bestHitIdx + 1].objectRotation, intersection.scaleBBox(hits[bestHitIdx + 1].bBox, Vector4.new(0.85, 0.85, 0.85))) do
        bestHitIdx = bestHitIdx + 1
    end
    bestHitIdx = math.min(bestHitIdx, #hits)

    if raycast:IsValid() and usePhysical then
        local distance = Vector4.Vector3To4(raycast.position):Distance(origin)

        if distance + 0.1 < hits[bestHitIdx].distance or distance < 0.1 then
            return {
                result = {
                    position = Vector4.Vector3To4(raycast.position),
                    normal = Vector4.Vector3To4(raycast.normal)
                },
                isNode = false,
                hit = true,
                allHits = hits
            }
        end
    end

    return {
        result = hits[bestHitIdx],
        isNode = true,
        hit = true,
        allHits = hits
    }
end

---Selects the spawnable element currently under the cursor.
function editor.setTarget()
    local ray = editor.getScreenToWorldRay()
    local hit = editor.getRaySceneIntersection(ray, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), nil, false)
    if not hit.hit or (not hit.isNode and #hit.allHits == 0) then return end -- or not hit.isNode | for now allow selecing through physical objects

    hit = hit.result
    if hit.element:isLocked() then return end

    if not editor.spawnedUI.multiSelectActive() then
        editor.spawnedUI.unselectAll()
    end

    if hit.element.selected then
        hit.element:setSelected(false)
    else
        hit.element:expandAllParents()
        editor.spawnedUI.scrollToSelected = true
        hit.element:setSelected(true)
        editor.spawnedUI.ensureCache()
        editor.addHighlightToSelected()
    end
end

---Updates transform-gizmo arrow highlight for the currently selected spawnable element.
function editor.updateArrowColor()
    local selected = editor.getSelected()

    if not selected or not utils.isA(selected, "spawnableElement") then return end

    visualizer.highlightArrow(selected.spawnable:getEntity(), editor.currentAxis)
end

---Resets cached drag deltas when the active transform axis changes.
function editor.updateCurrentAxis()
    if not editor.grab and not editor.rotate and not editor.scale then return end

    if editor.currentAxis ~= "none" then
        local element = editor.getSelected()
        if not element then return end

        element:setPosition(editor.originalPosition)
        element:setRotation(editor.originalRotation)
        if editor.scale then
            element:setScale(editor.originalScale, false) -- Avoid updating unless necessary, to fix flickering with e.g. colliders
        end

        -- Might remove this, makes things snap to cursor instantly (might be good, might be bad)
        editor.originalDiff.pos = nil
        editor.originalDiff.rot = nil
        editor.originalDiff.scale = nil
        editor.originalRotationQuat = nil
        editor.rotationAxisWorld = nil
        clearGroupRotationDragState()
    end
end

---Starts a transform mode for the current selection.
---@param transformationType "translate"|"rotate"|"scale" Transform mode to activate.
function editor.toggleTransform(transformationType)
    if editor.currentAxis ~= "none" then return end

    local selected = editor.getSelected()

    if selected and utils.isA(selected, "positionable") then
        editor.grab = transformationType == "translate" and true or false
        editor.rotate = transformationType == "rotate" and true or false

        if transformationType == "scale" and not selected.hasScale then
            return
        elseif transformationType == "scale" then
            editor.scale = true
        end

        editor.originalPosition = Vector4.new(selected:getPosition())
        editor.originalRotation = EulerAngles.new(selected:getRotation())
        editor.originalScale = Vector4.new(selected:getScale())
        editor.currentAxis = "all"
        editor.updateArrowColor()
        input.trackNumeric(true)
    end
end

---Records the current transform change into history and finalizes edited state.
function editor.recordChange()
    local element = editor.getSelected()
    local newPosition = Vector4.new(element:getPosition())
    local newRotation = EulerAngles.new(element:getRotation())
    local newScale = Vector4.new(element:getScale())

    element:setPosition(editor.originalPosition)
    element:setRotation(editor.originalRotation)
    element:setScale(editor.originalScale, false)
    if utils.isA(element, "spawnableElement") then
        history.addAction(history.getElementChange(element))
    else
        history.addAction(history.getMultiSelectChange(element.childs))
    end
    element:setPosition(newPosition)
    element:setRotation(newRotation)
    element:setScale(newScale, true)
    element:onEdited()

    editor.originalDiff.pos = nil
    editor.originalDiff.rot = nil
    editor.originalDiff.scale = nil
    editor.originalRotationQuat = nil
    editor.rotationAxisWorld = nil
    clearGroupRotationDragState()
end

---Updates hovered transform arrow based on cursor-to-gizmo intersection tests.
function editor.checkArrow()
    if #editor.spawnedUI.selectedPaths ~= 1 or editor.currentAxis ~= "none" then
        editor.hoveredArrow = "none"
        return
    end

    if ImGui.IsMouseDragging(0, style.draggingThreshold) then
        return
    end

    local selected = editor.spawnedUI.selectedPaths[1].ref.spawnable
    if not selected or not selected:isSpawned() then return end

    local ray = editor.getScreenToWorldRay()
    local arrowWidth = 0.04 * math.max(selected:getArrowSize().x, selected:getArrowSize().y, selected:getArrowSize().z)

    local arrowTransform = selected:getEntity():FindComponentByName("arrows"):GetLocalToWorld()
    local rotation = arrowTransform:GetRotation()
    local position = arrowTransform:GetTranslation()

    local xHit = intersection.getBoxIntersection(GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), ray, position, rotation, {
        min = { x = 0, y = -arrowWidth, z = -arrowWidth },
        max = { x = selected:getArrowSize().x * 2, y = arrowWidth, z = arrowWidth }
    })

    local yHit = intersection.getBoxIntersection(GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), ray, position, rotation, {
        min = { x = -arrowWidth, y = 0, z = -arrowWidth },
        max = { x = arrowWidth, y = selected:getArrowSize().y * 2, z = arrowWidth }
    })

    local zHit = intersection.getBoxIntersection(GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), ray, position, rotation, {
        min = { x = -arrowWidth, y = -arrowWidth, z = 0 },
        max = { x = arrowWidth, y = arrowWidth, z = selected:getArrowSize().z * 2 }
    })

    if zHit.hit then
        editor.hoveredArrow = "z"
    elseif xHit.hit then
        editor.hoveredArrow = "x"
    elseif yHit.hit then
        editor.hoveredArrow = "y"
    else
        editor.hoveredArrow = "none"
    end

    visualizer.highlightArrow(selected:getEntity(), editor.hoveredArrow)
end

---Computes cursor movement relative to a world position in camera-relative space.
---@param position Vector4 World-space pivot point used for the reference plane.
---@return Vector4 relativeDelta Camera-relative delta from pivot to cursor-plane hit.
function editor.getScreenRelativeToPoint(position)
    local cam = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation()
    local normal = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetRotation():GetForward()
    normal.x = -normal.x
    normal.y = -normal.y
    normal.z = -normal.z

    local hit = intersection.getPlaneIntersection(cam, editor.getScreenToWorldRay(), position, normal)
    local dir = utils.subVector(hit.position, position)

    local diff = Quaternion.MulInverse(EulerAngles.new(0, 0, 0):ToQuat(), GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetRotation():ToQuat())

    return diff:Transform(dir)
end

---Applies live translation/rotation/scale updates while the current transform interaction is active.
function editor.updateDrag()
    local dragging = ImGui.IsMouseDragging(0, style.draggingThreshold) and not (editor.grab or editor.rotate or editor.scale)
    if dragging then
        if editor.hoveredArrow ~= "none" then
            editor.currentAxis = editor.hoveredArrow
        end
    elseif not editor.grab and not editor.rotate and not editor.scale then
        if editor.currentAxis ~= "none" then
            editor.recordChange()
        end

        editor.currentAxis = "none"
    end

    if editor.currentAxis == "none" then return end

    ---@type positionable
    local selected = editor.getSelected()

    if not selected then
        editor.currentAxis = "none"
        return
    end

    local rotation = selected:getRotation()
    local position = selected:getPosition()
    local scale = selected:getScale()

    local axis = {
        x = { mult = 0, dir = rotation:GetRight() },
        y = { mult = 0, dir = rotation:GetForward() },
        z = { mult = 0, dir = rotation:GetUp() },
    }

    if editor.currentAxis:find("x") then
        axis.x.mult = 1
    end
    if editor.currentAxis:find("y") then
        axis.y.mult = 1
    end
    if editor.currentAxis:find("z") then
        axis.z.mult = 1
    end

    if editor.currentAxis == "all" and editor.scale then
        axis.x.mult = 1
        axis.y.mult = 1
        axis.z.mult = 1
    end

    local offset = Vector4.new(0, 0, 0, 0)
    for key, data in pairs(axis) do
        if data.mult ~= 0 then
            local t, _ = intersection.getTClosestToRay(position, data.dir, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), editor.getScreenToWorldRay())
            offset[key] = t
        end
    end

    local diff = rotation:ToQuat():Transform(offset)

    if not editor.originalDiff.pos then
        editor.originalDiff.pos = diff

        editor.originalPosition = Vector4.new(position)
        editor.originalRotation = EulerAngles.new(rotation)
        editor.originalScale = Vector4.new(scale)
    end

    if editor.grab or dragging then
        selected:setPositionDelta(Vector4.new(diff.x - editor.originalDiff.pos.x, diff.y - editor.originalDiff.pos.y, diff.z - editor.originalDiff.pos.z))
    elseif editor.rotate then
        local dir = editor.getScreenRelativeToPoint(position):Normalize()
        local angle = math.atan2(dir.z, dir.x) * 180 / math.pi

        if not editor.originalDiff.rot then
            editor.originalDiff.rot = angle
            editor.originalRotationQuat = editor.originalRotation:ToQuat()
            if selected.beginRotationDrag and utils.isA(selected, "positionableGroup") then
                selected:beginRotationDrag()
            end

            if axis.x.mult == 1 and axis.y.mult == 0 and axis.z.mult == 0 then
                editor.rotationAxisWorld = editor.originalRotationQuat:GetRight():Normalize()
            elseif axis.x.mult == 0 and axis.y.mult == 1 and axis.z.mult == 0 then
                editor.rotationAxisWorld = editor.originalRotationQuat:GetForward():Normalize()
            elseif axis.x.mult == 0 and axis.y.mult == 0 and axis.z.mult == 1 then
                editor.rotationAxisWorld = editor.originalRotationQuat:GetUp():Normalize()
            else
                editor.rotationAxisWorld = nil
            end
        end

        local angleDelta = angle - editor.originalDiff.rot + input.getNumeric(0)

        if editor.rotationAxisWorld and editor.originalRotationQuat then
            local stepQuat = Quaternion.SetAxisAngle(editor.rotationAxisWorld, Deg2Rad(angleDelta))
            local targetQuat = Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](stepQuat, editor.originalRotationQuat)
            if selected.applyRotationDrag and utils.isA(selected, "positionableGroup") then
                selected:applyRotationDrag(stepQuat, targetQuat, targetQuat:ToEulerAngles())
            else
                selected:setRotation(targetQuat:ToEulerAngles())
            end
        else
            local original = EulerAngles.new(editor.originalRotation)
            original.pitch = original.pitch + angleDelta * axis.x.mult
            original.roll = original.roll + angleDelta * axis.y.mult
            original.yaw = original.yaw + angleDelta * axis.z.mult

            selected:setRotation(original)
        end
    elseif editor.scale then
        local distance = Vector4.Length(editor.getScreenRelativeToPoint(position))

        if not editor.originalDiff.scale then
            editor.originalDiff.scale = distance
        end

        local original = Vector4.new(editor.originalScale)
        original.x = (original.x * (axis.x.mult == 1 and input.getNumeric(1) or 1)) + (distance - editor.originalDiff.scale) * axis.x.mult
        original.y = (original.y * (axis.y.mult == 1 and input.getNumeric(1) or 1)) + (distance - editor.originalDiff.scale) * axis.y.mult
        original.z = (original.z * (axis.z.mult == 1 and input.getNumeric(1) or 1)) + (distance - editor.originalDiff.scale) * axis.z.mult

        selected:setScale(original, false)
    end
end

---Returns a point in front of the camera, adjusted to editor viewport center when active.
---@param distance number Forward distance in meters.
---@return Vector4 worldPosition Target point in world space.
---@return Vector4 relativeForward Unadjusted camera-space forward vector returned by `camera.screenToWorld`.
function editor.getForward(distance)
    local forward = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetRotation():GetForward()
    local relativeForward = Vector4.new(0, 1, 0, 0)

    if editor.active then
        local screenWidth, _ = GetDisplayResolution()
        local viewportStart = settings.editorDockLeft and settings.editorWidth or 0
        local x = viewportStart + ((screenWidth - settings.editorWidth) / 2)

        relativeForward, adjusted = editor.camera.screenToWorld((x / screenWidth * 2) - 1, 0)
        adjusted = adjusted:Normalize()
        distance = distance / math.cos(math.rad(Vector4.GetAngleBetween(forward, adjusted)))
        forward = adjusted
    end

    local position = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation()

    return utils.addVector(position, utils.multVector(forward, distance)), relativeForward
end

---Draws the depth-selection popup used to choose between overlapping hits.
function editor.drawDepthSelect()
    if not editor.active or not editor.depthSelectOpen then return end

    local x, y = ImGui.GetMousePos()
    ImGui.SetNextWindowPos(x + 10 * style.viewSize, y + 10 * style.viewSize, ImGuiCond.Appearing)

    ImGui.PushStyleColor(ImGuiCol.TitleBgActive, 0, 0, 0, 1)
    editor.depthSelectOpen = ImGui.Begin("Depth Selection", true, ImGuiWindowFlags.NoResize + ImGuiWindowFlags.AlwaysAutoResize + ImGuiWindowFlags.NoCollapse)
    editor.depthSelectOpen = editor.depthSelectOpen and ImGui.IsWindowFocused(ImGuiHoveredFlags.ChildWindows)
    ImGui.PopStyleColor()

    if editor.depthSelectOpen then
        for _, hit in pairs(editor.depthSelectElements) do
            style.mutedText(string.format("[%.2f m]", hit.distance))

            ImGui.SameLine(editor.depthElementsMaxWidth + 10 * style.viewSize)

            ImGui.BeginDisabled(hit.element:isLocked())
            if ImGui.Selectable(hit.element.name, false) then
                editor.spawnedUI.unselectAll()
                hit.element:setSelected(true)
                editor.depthSelectOpen = false
                editor.spawnedUI.scrollToSelected = true
            end
            ImGui.EndDisabled()
        end

        ImGui.End()
    end
end

---Calculates all eight world-space corners of a spawnable bounding box.
---@param entry spawnable Spawnable entry whose local bounding box is transformed to world space.
---@return Vector4[] corners World-space corner points.
local function calculateSpawnableCorners(entry)
    local bBox = entry:getBBox()

    local corners = {
        Vector4.new(bBox.min.x, bBox.min.y, bBox.min.z, 1),
        Vector4.new(bBox.min.x, bBox.min.y, bBox.max.z, 1),
        Vector4.new(bBox.min.x, bBox.max.y, bBox.min.z, 1),
        Vector4.new(bBox.min.x, bBox.max.y, bBox.max.z, 1),
        Vector4.new(bBox.max.x, bBox.min.y, bBox.min.z, 1),
        Vector4.new(bBox.max.x, bBox.min.y, bBox.max.z, 1),
        Vector4.new(bBox.max.x, bBox.max.y, bBox.min.z, 1),
        Vector4.new(bBox.max.x, bBox.max.y, bBox.max.z, 1)
    }

    for key, corner in pairs(corners) do
        corners[key] = utils.addVector(entry.position, entry.rotation:ToQuat():Transform(corner))
    end

    return corners
end

---Checks whether a numeric value is finite and not NaN.
---@param value number? Value to validate.
---@return boolean isFiniteValue True when value is a finite number.
local function isFinite(value)
    return value ~= nil and value == value and value > -math.huge and value < math.huge
end

---Invalidates wireframe caches when spawned UI cache epoch changes.
local function refreshWireframeCaches()
    local cacheEpoch = editor.spawnedUI and editor.spawnedUI.cacheEpoch or -1
    if editor.wireframeCacheEpoch == cacheEpoch then
        return
    end

    editor.wireframeCacheEpoch = cacheEpoch
    editor.wireframeLeafCache = {}
    editor.wireframeBoundsCache = {}
    editor.wireframeMultiLeafCache = nil
end

---Returns and caches leaf spawnable elements for a group.
---@param group positionableGroup Group whose leaf nodes should be collected.
---@return spawnableElement[] leafs Cached list of leaf spawnable elements.
local function getGroupLeafsCached(group)
    local cacheEpoch = editor.spawnedUI and editor.spawnedUI.cacheEpoch or -1
    local cached = editor.wireframeLeafCache[group.id]
    if cached and cached.cacheEpoch == cacheEpoch then
        return cached.leafs
    end

    local leafs = group:getPositionableLeafs()
    editor.wireframeLeafCache[group.id] = {
        cacheEpoch = cacheEpoch,
        leafs = leafs
    }

    return leafs
end

---Appends source leaf elements into a target array.
---@param target spawnableElement[] Destination array to mutate.
---@param source spawnableElement[] Source array to append.
local function appendLeafs(target, source)
    for _, leaf in ipairs(source) do
        table.insert(target, leaf)
    end
end

---Compares two numbers with epsilon tolerance.
---@param a number? First value.
---@param b number? Second value.
---@return boolean equal True when both values are equal within epsilon.
local function almostEqual(a, b)
    if a == b then return true end
    if not a or not b then return false end
    return math.abs(a - b) <= 0.0001
end

---Builds group-local min/max bounds from world-space leaf bounding boxes.
---@param leafs spawnableElement[] Leaf spawnable elements used to compute aggregate bounds.
---@param origin Vector4 Group origin in world space.
---@param groupQuat Quaternion Group orientation in world space.
---@return Vector4? minLocal Local-space minimum corner, or nil when bounds cannot be computed.
---@return Vector4? maxLocal Local-space maximum corner, or nil when bounds cannot be computed.
---@return Quaternion? resolvedQuat Same group quaternion when bounds are valid.
local function getLocalBoundsFromLeafs(leafs, origin, groupQuat)
    local minLocal = Vector4.new(math.huge, math.huge, math.huge, 0)
    local maxLocal = Vector4.new(-math.huge, -math.huge, -math.huge, 0)
    local anyCorner = false

    for _, leaf in pairs(leafs) do
        local spawnable = leaf.spawnable
        local bbox = spawnable and spawnable.getBBox and spawnable:getBBox() or nil
        local leafPos = leaf:getPosition()
        local leafQuat = leaf:getRotation():ToQuat()

        if bbox and leafPos and leafQuat then
            local corners = {
                Vector4.new(bbox.min.x, bbox.min.y, bbox.min.z, 0),
                Vector4.new(bbox.min.x, bbox.min.y, bbox.max.z, 0),
                Vector4.new(bbox.min.x, bbox.max.y, bbox.min.z, 0),
                Vector4.new(bbox.min.x, bbox.max.y, bbox.max.z, 0),
                Vector4.new(bbox.max.x, bbox.min.y, bbox.min.z, 0),
                Vector4.new(bbox.max.x, bbox.min.y, bbox.max.z, 0),
                Vector4.new(bbox.max.x, bbox.max.y, bbox.min.z, 0),
                Vector4.new(bbox.max.x, bbox.max.y, bbox.max.z, 0)
            }

            for _, corner in ipairs(corners) do
                local worldPoint = utils.addVector(leafPos, leafQuat:Transform(corner))
                local localPoint = groupQuat:TransformInverse(utils.subVector(worldPoint, origin))

                if isFinite(localPoint.x) and isFinite(localPoint.y) and isFinite(localPoint.z) then
                    minLocal = Vector4.new(math.min(minLocal.x, localPoint.x), math.min(minLocal.y, localPoint.y), math.min(minLocal.z, localPoint.z), 0)
                    maxLocal = Vector4.new(math.max(maxLocal.x, localPoint.x), math.max(maxLocal.y, localPoint.y), math.max(maxLocal.z, localPoint.z), 0)
                    anyCorner = true
                end
            end
        end
    end

    if not anyCorner then
        return nil, nil, nil
    end

    return minLocal, maxLocal, groupQuat
end

---Collects group targets that should render oriented bounds overlays.
---@return table[] targets Overlay target records with `cacheKey`, `origin`, `quat`, and `leafs`.
local function getOverlayTargets()
    refreshWireframeCaches()

    local selectedGroupRoots = {}
    if #editor.spawnedUI.selectedPaths > 1 then
        for _, entry in pairs(editor.spawnedUI.getRoots(editor.spawnedUI.selectedPaths)) do
            if entry.ref and utils.isA(entry.ref, "positionableGroup") then
                table.insert(selectedGroupRoots, entry.ref)
            end
        end
    end

    if #selectedGroupRoots > 1 then
        local multi = editor.spawnedUI.multiSelectGroup
        multi.childs = {}
        local signatureParts = {}
        for _, group in ipairs(selectedGroupRoots) do
            table.insert(multi.childs, group)
            table.insert(signatureParts, tostring(group.id))
        end

        local cacheEpoch = editor.spawnedUI and editor.spawnedUI.cacheEpoch or -1
        local signature = table.concat(signatureParts, ";")
        local leafs
        if editor.wireframeMultiLeafCache and editor.wireframeMultiLeafCache.cacheEpoch == cacheEpoch and editor.wireframeMultiLeafCache.signature == signature then
            leafs = editor.wireframeMultiLeafCache.leafs
        else
            leafs = {}
            for _, group in ipairs(selectedGroupRoots) do
                appendLeafs(leafs, getGroupLeafsCached(group))
            end
            editor.wireframeMultiLeafCache = {
                cacheEpoch = cacheEpoch,
                signature = signature,
                leafs = leafs
            }
        end

        return {
            {
                cacheKey = "multi",
                origin = multi:getPosition(),
                quat = multi:getRotation():ToQuat(),
                leafs = leafs
            }
        }
    end

    local targets = {}
    local seen = {}

---Adds a group overlay target once, skipping root/ineligible groups.
---@param group positionableGroup? Candidate group to include.
    local function addGroupTarget(group)
        if not group or group.parent == nil or seen[group.id] then
            return
        end

        seen[group.id] = true
        table.insert(targets, {
            cacheKey = tostring(group.id),
            origin = group:getPosition(),
            quat = group:getRotation():ToQuat(),
            leafs = getGroupLeafsCached(group)
        })
    end

    for _, selected in ipairs(editor.spawnedUI.selectedPaths) do
        if selected.ref and utils.isA(selected.ref, "positionableGroup") then
            addGroupTarget(selected.ref)
        end
    end

    for _, hovered in ipairs(editor.spawnedUI.hoveredEntries or {}) do
        if hovered and hovered.hovered and utils.isA(hovered, "positionableGroup") then
            addGroupTarget(hovered)
        end
    end

    return targets
end

---Returns cached group-local bounds for an overlay target.
---@param target table Overlay target record containing `cacheKey`, `origin`, `quat`, and `leafs`.
---@return Vector4? minLocal Cached or computed local minimum corner.
---@return Vector4? maxLocal Cached or computed local maximum corner.
---@return Quaternion? groupQuat Target orientation used for drawing.
local function getCachedLocalBounds(target)
    if not target.origin or not target.quat then
        return nil, nil, nil
    end

    local cacheEpoch = editor.spawnedUI and editor.spawnedUI.cacheEpoch or -1
    local wireframeEpoch = editor.spawnedUI and editor.spawnedUI.wireframeEpoch or 0
    local cache = editor.wireframeBoundsCache[target.cacheKey]

    if cache
        and cache.cacheEpoch == cacheEpoch
        and cache.wireframeEpoch == wireframeEpoch
        and cache.leafCount == #target.leafs
        and almostEqual(cache.originX, target.origin.x)
        and almostEqual(cache.originY, target.origin.y)
        and almostEqual(cache.originZ, target.origin.z)
        and almostEqual(cache.quatI, target.quat.i)
        and almostEqual(cache.quatJ, target.quat.j)
        and almostEqual(cache.quatK, target.quat.k)
        and almostEqual(cache.quatR, target.quat.r) then
        return cache.minLocal, cache.maxLocal, target.quat
    end

    local minLocal, maxLocal, groupQuat = getLocalBoundsFromLeafs(target.leafs, target.origin, target.quat)
    if not minLocal or not maxLocal or not groupQuat then
        return nil, nil, nil
    end

    editor.wireframeBoundsCache[target.cacheKey] = {
        cacheEpoch = cacheEpoch,
        wireframeEpoch = wireframeEpoch,
        leafCount = #target.leafs,
        originX = target.origin.x,
        originY = target.origin.y,
        originZ = target.origin.z,
        quatI = target.quat.i,
        quatJ = target.quat.j,
        quatK = target.quat.k,
        quatR = target.quat.r,
        minLocal = minLocal,
        maxLocal = maxLocal
    }

    return minLocal, maxLocal, groupQuat
end

---Resolves wireframe theme colors for group overlays.
---@return number frontColor Color for visible/front edges.
---@return number backColor Color for occluded/back edges.
---@return number labelColor Color for distance/label text.
local function getGroupWireframeThemeColors()
    local wireframeColorStyle = settings.wireframeColorStyle or 1
    if wireframeColorStyle == 2 then
        -- Lighter blue wireframe with black text.
        return 0xFFFF7F00, 0x55FF7F00, 0xFF000000
    end

    -- Darker blue wireframe with white text.
    return 0xFF992D00, 0x55992D00, 0xFFDCD8D1
end

---Draws an oriented group bounds wireframe overlay.
---@param target table Overlay target with transform and leaf metadata.
---@param screen table Screen projection helper returned by `projectedWireframe.beginOverlay`.
---@param drawList table ImGui draw list for overlay rendering.
local function drawGroupBounds(target, screen, drawList)
    local minLocal, maxLocal, groupQuat = getCachedLocalBounds(target)
    if not minLocal or not maxLocal or not groupQuat then return end

    local origin = target.origin
    if not origin then return end
    local frontColor, backColor, labelColor = getGroupWireframeThemeColors()

    projectedWireframe.drawOrientedBox(
        drawList,
        screen,
        origin,
        groupQuat,
        minLocal,
        maxLocal,
        {
            frontColor = frontColor,
            backColor = backColor,
            frontThickness = 1.5 * style.viewSize,
            backThickness = 1.2 * style.viewSize,
            fadeNear = 45,
            fadeFar = 175,
            fadeLimit = 0.8,
            originColor = frontColor,
            labelColor = labelColor
        }
    )
end

---Draws bounds overlays for selected or hovered groups when enabled.
local function drawHoveredGroupBounds()
    if not editor.active or not editor.camera then return end
    if not settings.groupWireframeEnabled then return end
    editor.spawnedUI.ensureCache()

    local targets = getOverlayTargets()
    if #targets == 0 then return end

    local screen, drawList = projectedWireframe.beginOverlay("##groupBoundsOverlay")
    if not screen then return end

    for _, target in ipairs(targets) do
        drawGroupBounds(target, screen, drawList)
    end
    projectedWireframe.endOverlay()
end

---Collects spawnables that expose a streaming range visualization.
---@return table[] targets Array of `{ range, refPoint }` records.
local function getStreamingRangeTargets()
    editor.spawnedUI.ensureCache()

    local targets = {}
    for _, entry in ipairs(editor.spawnedUI.paths) do
        local element = entry.ref
        if element
            and element.visible
            and not element.hiddenByParent
            and utils.isA(element, "spawnableElement")
            and element.spawnable
            and element.spawnable.visualizeStreamingRange
            and element.spawnable:isSpawned() then
            local spawnable = element.spawnable
            local range = tonumber(spawnable.primaryRange) or 0
            local refPoint = spawnable:getStreamingReferencePoint()

            if refPoint and range > 0 then
                table.insert(targets, {
                    range = range,
                    refPoint = refPoint
                })
            end
        end
    end

    return targets
end

---Checks whether a point lies inside an axis-aligned streaming range box.
---@param point Vector4 Point to test.
---@param center Vector4 Center of the streaming box.
---@param range number Half-extent applied on all axes.
---@return boolean inside True when point lies inside the box bounds.
local function isInsideStreamingBox(point, center, range)
    return point.x >= (center.x - range) and point.x <= (center.x + range)
        and point.y >= (center.y - range) and point.y <= (center.y + range)
        and point.z >= (center.z - range) and point.z <= (center.z + range)
end

---Resolves streaming-range colors based on whether the player is inside the range.
---@param inside boolean True when the player is inside the streaming range.
---@return number color Wireframe edge color.
---@return number labelColor Label color used by overlay text.
local function getStreamingWireframeThemeColors(inside)
    local wireframeColorStyle = settings.wireframeColorStyle or 1
    if wireframeColorStyle == 2 then
        return inside and 0xFF50FF50 or 0xFF5050FF, 0xFF000000
    end

    return inside and style.successColor or 0xFF0000B2, 0xFFDCD8D1
end

---Draws streaming-range overlays for eligible spawned elements.
local function drawSpawnableStreamingRanges()
    if not editor.camera or not editor.spawnedUI or not GetPlayer() then return end

    local targets = getStreamingRangeTargets()
    if #targets == 0 then return end

    local screen, drawList = projectedWireframe.beginOverlay("##streamingRangeOverlay")
    if not screen then return end

    local playerPos = GetPlayer():GetWorldPosition()
    local identityQuat = EulerAngles.new(0, 0, 0):ToQuat()

    for _, target in ipairs(targets) do
        local inside = isInsideStreamingBox(playerPos, target.refPoint, target.range)
        local color, labelColor = getStreamingWireframeThemeColors(inside)

        projectedWireframe.drawOrientedBox(
            drawList,
            screen,
            target.refPoint,
            identityQuat,
            Vector4.new(-target.range, -target.range, -target.range, 0),
            Vector4.new(target.range, target.range, target.range, 0),
            {
                frontColor = color,
                backColor = inside and 0x5500FF00 or 0x550000FF,
                frontThickness = 1.5 * style.viewSize,
                backThickness = 1.2 * style.viewSize,
                fadeNear = 45,
                fadeFar = 175,
                fadeLimit = 0.8,
                originColor = color,
                labelColor = labelColor,
                originDistance = utils.distanceVector(playerPos, target.refPoint)
            }
        )
    end

    projectedWireframe.endOverlay()
end

---Handles Ctrl+drag box selection in the viewport and draws selection rectangle.
function editor.handleBoxSelect()
    if not editor.active then return end

    local x, y = ImGui.GetMousePos()
    if ImGui.IsKeyDown(ImGuiKey.LeftCtrl) and ImGui.IsMouseDragging(0, style.draggingThreshold) and not editor.boxSelectActive and input.context.viewport.hovered then
        editor.boxSelectActive = true
        editor.boxSelectStart = { x = x, y = y }
        editor.spawnedUI.unselectAll()
    elseif not ImGui.IsMouseDragging(0, style.draggingThreshold) and editor.boxSelectActive then
        editor.boxSelectActive = false

        local width, height = GetDisplayResolution()
        local min = { x = math.min(editor.boxSelectStart.x, x), y = math.min(editor.boxSelectStart.y, y) }
        local max = { x = math.max(editor.boxSelectStart.x, x), y = math.max(editor.boxSelectStart.y, y) }

        for _, element in pairs(editor.spawnedUI.paths) do
            if element.ref.visible and not element.ref.hiddenByParent and not element.ref:isLocked() and utils.isA(element.ref, "spawnableElement") then
                local inside = true
                for _, corner in pairs(calculateSpawnableCorners(element.ref.spawnable)) do
                    local xCorner, yCorner = editor.camera.worldToScreen(corner)
                    xCorner, yCorner = (xCorner + 1) * width / 2, (- yCorner + 1) * height / 2

                    if xCorner < min.x or xCorner > max.x or yCorner < min.y or yCorner > max.y then
                        inside = false
                        break
                    end
                end

                if inside then
                    element.ref:setSelected(true)
                end
            end
        end
    end

    if editor.boxSelectActive then
        ImGui.SetNextWindowPos(math.min(editor.boxSelectStart.x, x), math.min(editor.boxSelectStart.y, y), ImGuiCond.Always)
        ImGui.SetNextWindowSize(math.abs(x - editor.boxSelectStart.x), math.abs(y - editor.boxSelectStart.y))

        ImGui.PushStyleVar(ImGuiStyleVar.WindowMinSize, 0, 0)
        ImGui.PushStyleColor(ImGuiCol.WindowBg, 0, 0, 0, 0.1)
        editor.boxSelectActive = ImGui.Begin("##boxSelect", ImGuiWindowFlags.NoResize + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoCollapse)
        ImGui.PopStyleColor()
        ImGui.PopStyleVar()
    end
end

---Per-frame editor update/draw entrypoint invoked from the main draw loop.
function editor.onDraw()
    if editor.spawnedUI and editor.spawnedUI.updateModifierState then
        editor.spawnedUI.updateModifierState()
    end

    if editor.camera then
        editor.camera.update()
    end

    drawHoveredGroupBounds()
    drawSpawnableStreamingRanges()

    if editor.active and input.context.viewport.hovered then
        editor.checkArrow()
        editor.updateDrag()
        editor.drawDepthSelect()
        editor.handleBoxSelect()
    end
end

---Temporarily suspends or resumes editor mode when overlay visibility changes.
---@param state boolean? Desired suspend state (`true` resumes editor if it was suspended).
function editor.suspend(state)
    if editor.active and not state and not editor.suspendState then
        editor.suspendState = true
        editor.toggle(false)
    elseif not editor.active and state and editor.suspendState then
        editor.suspendState = false
        editor.toggle(true)
    end
end

---Toggles editor mode and applies related side effects (camera, freefly, player modifiers).
---@param state boolean? Desired editor active state.
function editor.toggle(state)
    local freefly = GetMod("freefly")

    if freefly then
        if state and freefly.runtimeData.active then
            freefly.runtimeData.active = false
            freefly.logic.toggleFlight(freefly, freefly.runtimeData.active)
            editor.freeflyWasActive = true
        elseif not state and editor.freeflyWasActive then
            freefly.runtimeData.active = true
            freefly.logic.toggleFlight(freefly, freefly.runtimeData.active)
            editor.freeflyWasActive = false
        end
    end

    editor.active = state
    editor.camera.toggle(state)
    editor.baseUI.loadTabSize = true

    if not state then
        editor.baseUI.restoreWindowPosition = true
        editor.removeHighlight(false)
        editor.currentAxis = "none"
        editor.hoveredArrow = "none"
        editor.grab = false
        Game.GetStatsSystem():RemoveModifier(GetPlayer():GetEntityID(), RPGManager.CreateStatModifier(gamedataStatType.KnockdownImmunity, gameStatModifierType.Additive, 1))
        Game.GetStatsSystem():RemoveModifier(GetPlayer():GetEntityID(), RPGManager.CreateStatModifier(gamedataStatType.CanBreatheUnderwater, gameStatModifierType.Additive, 1))
    else
        Game.GetStatsSystem():AddModifier(GetPlayer():GetEntityID(), RPGManager.CreateStatModifier(gamedataStatType.KnockdownImmunity, gameStatModifierType.Additive, 1))
        Game.GetStatsSystem():AddModifier(GetPlayer():GetEntityID(), RPGManager.CreateStatModifier(gamedataStatType.CanBreatheUnderwater, gameStatModifierType.Additive, 1))
        if settings.outlineSelected then
            editor.addHighlightToSelected()
        end
    end
end

return editor
