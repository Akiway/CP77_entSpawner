local utils = require("modules/utils/core/utils")
local gameUtils = require("modules/utils/game/gameUtils")
local tween = require("modules/tween/tween")
local settings = require("modules/utils/core/settings")
local input = require("modules/utils/core/input")

---@class cameraTransform
---@field position Vector4
---@field rotation EulerAngles

---@class camera
---@field active boolean True while editor camera mode is enabled.
---@field distance number Camera boom distance applied on local Y axis.
---@field xOffset number Horizontal local camera offset used for centered viewport composition.
---@field deltaTime number Frame delta updated externally from `init.lua` on each `onUpdate`.
---@field components string[] Player visual component names temporarily hidden while active.
---@field playerTransform cameraTransform? Player world transform snapshot captured when entering editor mode.
---@field cameraTransform cameraTransform? Current free camera world transform.
---@field preTransitionCameraDistance number Cached distance restored after exit transition.
---@field transitionTween table? Active tween object used when transitioning between camera anchors.
---@field suspendState boolean Reserved suspension flag.
local camera = {
    active = false,
    distance = 3,
    xOffset = 0,
    deltaTime = 0,
    components = {},
    playerTransform = nil,
    cameraTransform = nil,
    preTransitionCameraDistance = 0,
    transitionTween = nil,
    suspendState = false
}

--- Fraction of the current boom distance covered by a single wheel notch, so the wheel keeps the
--- same feel whether the camera is a metre or a hundred metres out.
local WHEEL_ZOOM_STEP_RATIO = 0.1
--- Floor for that step, so the wheel stays usable once the camera is right up against its pivot.
local WHEEL_ZOOM_MIN_STEP = 0.05
--- The shipped `cameraZoomSpeed`, used to normalise the setting into a plain multiplier.
local DEFAULT_ZOOM_SPEED = 2.75

---Fallback boom distance, used when the current one is found to be unusable.
local FALLBACK_DISTANCE = 3

---@param value number
---@return boolean
local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= - math.huge
end

---Pushes the current boom offset to the camera component.
---This is the only thing that moves the camera along its own view axis, so unlike the pan and
---rotate paths (which go through Teleport) nothing else re-applies it.
local function applyBoom()
    GetPlayer():GetFPPCameraComponent():SetLocalPosition(Vector4.new(- camera.xOffset, - camera.distance, 0, 0))
end

---Applies a zoom delta to the camera boom distance and pushes it to the camera component.
---Shared by both zoom bindings (CTRL + hold MMB, and the mouse wheel).
---@param delta number Signed distance change; positive pulls the camera away from its pivot.
local function applyZoom(delta)
    -- A distance that has gone NaN or infinite sticks: every later zoom keeps it that way while pan
    -- and rotate carry on working off cameraTransform, which reads as the zoom being dead for good.
    -- Take the nearest usable value rather than letting one bad frame poison the boom.
    local target = camera.distance + delta
    if not isFinite(target) then
        target = isFinite(camera.distance) and camera.distance or FALLBACK_DISTANCE
    end

    camera.distance = math.max(0.1, target)

    applyBoom()
end

---Enables or disables editor camera mode.
---When enabled, this hides the player mesh, switches scene tier, and starts free camera control.
---When disabled, this restores player components and teleports back to the stored player transform
---(or tween-transitions first when very far away).
---@param state boolean Target active state (`true` to enable, `false` to disable).
function camera.toggle(state)
    if not Game.GetPlayer() then return end

    if not camera.playerTransform then
        camera.playerTransform = { position = GetPlayer():GetWorldPosition(), rotation = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetRotation() }
        camera.cameraTransform = { position = GetPlayer():GetWorldPosition(), rotation = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetRotation() }
    end

    if state == camera.active then return end

    camera.active = state

    -- The wheel probe is only drawn while the camera is live, so the offset it was left on says
    -- nothing about the wheel now. Start the next poll from a fresh baseline.
    input.resetMouseWheel()

    if camera.active and camera.transitionTween then
        -- Re-entering editor mode while the exit transition is still flying home. That tween is
        -- winding the boom down to zero and, because its completion branch only restores the
        -- distance when the camera is inactive, letting it finish would strand the camera at the
        -- player with no way back out. Drop it and take the distance it was saved with.
        camera.transitionTween = nil
        if camera.preTransitionCameraDistance > 0 then
            camera.distance = camera.preTransitionCameraDistance
        end
    end

    if camera.active then
        if Vector4.Distance(GetPlayer():GetWorldPosition(), camera.cameraTransform.position) > 50 then
            camera.cameraTransform.position = GetPlayer():GetWorldPosition()
        end

        Game.GetPlayer():GetFPPCameraComponent():SetLocalPosition(Vector4.new(- camera.xOffset, - camera.distance, 0, 0))
        gameUtils.setSceneTier(4)

        for _, component in pairs(GetPlayer():GetComponents()) do
            if component:IsA("entIVisualComponent") and component:IsEnabled() then
                table.insert(camera.components, component.name.value)
                component:Toggle(false)
            end
        end

        camera.playerTransform.position = GetPlayer():GetWorldPosition()
        camera.playerTransform.rotation = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetRotation()

        GetPlayer():GetFPPCameraComponent().pitchMax = camera.cameraTransform.rotation.pitch
        GetPlayer():GetFPPCameraComponent().pitchMin = camera.cameraTransform.rotation.pitch

        camera.update()
    else
        camera.cameraTransform.position = GetPlayer():GetWorldPosition()

        local distance = Vector4.Distance(GetPlayer():GetWorldPosition(), camera.playerTransform.position)
        if distance > 50 then
            camera.transition(camera.cameraTransform.position, camera.playerTransform.position, camera.cameraTransform.rotation, camera.playerTransform.rotation, 0, distance / 50)
            camera.preTransitionCameraDistance = camera.distance
        else
            GetPlayer():GetFPPCameraComponent():SetLocalPosition(Vector4.new(0.0, 0, 0, 0))
            gameUtils.setSceneTier(1)

            for _, component in pairs(camera.components) do
                local instance = GetPlayer():FindComponentByName(component)
                if instance then
                    instance:Toggle(true)
                end
            end

            camera.components = {}
            camera.transitionTween = nil

            Game.GetTeleportationFacility():Teleport(GetPlayer(), camera.playerTransform.position, camera.playerTransform.rotation)
            GetPlayer():GetFPPCameraComponent().pitchMax = camera.playerTransform.rotation.pitch
            GetPlayer():GetFPPCameraComponent().pitchMin = camera.playerTransform.rotation.pitch
        end
    end

    GetPlayer():DisableCameraBobbing(camera.active)
end

---Per-frame camera update tick.
---Handles transition tween updates, free-camera mouse controls, player teleport syncing, and scene tier.
---`camera.deltaTime` must be kept current by the runtime update loop.
function camera.update()
    if not GetPlayer() then return end

    if camera.transitionTween then
        local done = camera.transitionTween:update(camera.deltaTime)

        if done then
            camera.transitionTween = nil

            if not camera.active then
                for _, component in pairs(camera.components) do
                    GetPlayer():FindComponentByName(component):Toggle(true)
                end
                gameUtils.setSceneTier(1)

                GetPlayer():GetFPPCameraComponent().pitchMax = camera.playerTransform.rotation.pitch
                GetPlayer():GetFPPCameraComponent().pitchMin = camera.playerTransform.rotation.pitch

                camera.distance = camera.preTransitionCameraDistance
            end
        else
            camera.cameraTransform.position = Vector4.new(camera.transitionTween.subject.x, camera.transitionTween.subject.y, camera.transitionTween.subject.z, 0)
            camera.distance = camera.transitionTween.subject.distance

            GetPlayer():GetFPPCameraComponent():SetLocalPosition(Vector4.new(0, - camera.distance, 0, 0))
            Game.GetTeleportationFacility():Teleport(GetPlayer(), camera.cameraTransform.position, EulerAngles.new(0, 0, camera.transitionTween.subject.yaw))
            return
        end
    end

    if not camera.active then return end

    if ImGui.IsMouseDragging(ImGuiMouseButton.Middle, 0) then
        local x, y = ImGui.GetMouseDragDelta(ImGuiMouseButton.Middle, 0)
        ImGui.ResetMouseDragDelta(ImGuiMouseButton.Middle)

        local distanceMultiplier = math.max(1, (camera.distance / 10))

        if ImGui.IsKeyDown(ImGuiKey.LeftShift) then
            camera.cameraTransform.position = utils.addVector(camera.cameraTransform.position, utils.multVector(camera.cameraTransform.rotation:GetUp(), (y / (1 / settings.cameraMovementSpeed * 4)) * camera.deltaTime  * distanceMultiplier))
            camera.cameraTransform.position = utils.subVector(camera.cameraTransform.position, utils.multVector(camera.cameraTransform.rotation:GetRight(), (x / (1 / settings.cameraMovementSpeed * 4)) * camera.deltaTime  * distanceMultiplier))
        elseif ImGui.IsKeyDown(ImGuiKey.LeftCtrl) then
            applyZoom((y / (1 / settings.cameraZoomSpeed * 2.75)) * camera.deltaTime * distanceMultiplier)
        else
            camera.cameraTransform.rotation.yaw = camera.cameraTransform.rotation.yaw - (x / (1 / settings.cameraRotateSpeed * 0.4)) * camera.deltaTime
            camera.cameraTransform.rotation.pitch = camera.cameraTransform.rotation.pitch - (y / (1 / settings.cameraRotateSpeed * 0.4)) * camera.deltaTime
            GetPlayer():GetFPPCameraComponent().pitchMax = camera.cameraTransform.rotation.pitch
            GetPlayer():GetFPPCameraComponent().pitchMin = camera.cameraTransform.rotation.pitch
        end
    end

    -- Secondary zoom binding. Unlike the drag above this arrives in discrete notches rather than as
    -- a per frame rate, so it is not scaled by deltaTime. The probe window is only submitted while
    -- the editor camera is live, and only picks the wheel up over the bare viewport.
    local notches = input.pollMouseWheel()
    if notches ~= 0 then
        local step = math.max(WHEEL_ZOOM_MIN_STEP, camera.distance * WHEEL_ZOOM_STEP_RATIO)
        applyZoom(notches * step * (settings.cameraZoomSpeed / DEFAULT_ZOOM_SPEED))
    end

    -- Re-assert the boom every frame rather than only when a zoom input changes it. The one other
    -- per frame write is camera.updateXOffset, which runs from inside the main window's Begin and is
    -- therefore skipped whenever that window is collapsed or closed. Without this, anything game
    -- side that resets the camera component's local offset stays reset, and zoom looks dead while
    -- pan and rotate keep working.
    applyBoom()

    Game.GetTeleportationFacility():Teleport(GetPlayer(), camera.cameraTransform.position, camera.cameraTransform.rotation)
    Game.GetStatPoolsSystem():RequestSettingStatPoolValue(GetPlayer():GetEntityID(), gamedataStatPoolType.Health, 100, nil)
    gameUtils.setSceneTier(4)
end

---Resets editor camera transform to the player transform captured when editor mode was entered.
---Only works while camera mode is active and a baseline transform has been captured.
---@return boolean reset `true` when reset was applied, `false` when reset is unavailable.
function camera.resetPosition()
    if not camera.active or not GetPlayer() or not camera.playerTransform then
        return false
    end

    camera.transitionTween = nil
    camera.cameraTransform.position = Vector4.new(camera.playerTransform.position)
    camera.cameraTransform.rotation = EulerAngles.new(camera.playerTransform.rotation.roll, camera.playerTransform.rotation.pitch, camera.playerTransform.rotation.yaw)

    GetPlayer():GetFPPCameraComponent():SetLocalPosition(Vector4.new(- camera.xOffset, - camera.distance, 0, 0))
    GetPlayer():GetFPPCameraComponent().pitchMax = camera.cameraTransform.rotation.pitch
    GetPlayer():GetFPPCameraComponent().pitchMin = camera.cameraTransform.rotation.pitch
    Game.GetTeleportationFacility():Teleport(GetPlayer(), camera.cameraTransform.position, camera.cameraTransform.rotation)
    gameUtils.setSceneTier(4)

    return true
end

---Instantly moves the free camera to a world position, without a transition.
---This is the editor camera counterpart of `gameUtils.teleportPlayer`: the position lands on the
---camera pivot, so the eye ends up the current boom distance behind it, looking at the target.
---@param position Vector4 Target world position for the camera pivot.
---@param rotationLike any? Optional target rotation; the current camera rotation is kept when omitted.
---@param distance number? Optional boom distance to apply, for example `0` to put the eye on the target itself.
---@return boolean moved `true` when the camera was moved, `false` when camera mode is not usable.
function camera.teleportTo(position, rotationLike, distance)
    if not camera.active or not position or not GetPlayer() or not camera.cameraTransform then
        return false
    end

    -- A running transition rewrites cameraTransform every frame from its own tween subject, so
    -- leaving it in place would drag the camera straight back off the target.
    camera.transitionTween = nil

    camera.cameraTransform.position = Vector4.new(position)

    local rotation = gameUtils.toEulerAnglesSafe(rotationLike)
    if rotation then
        camera.cameraTransform.rotation = EulerAngles.new(rotation.roll or 0, rotation.pitch or 0, rotation.yaw or 0)
    end

    if isFinite(distance) and distance >= 0 then
        camera.distance = distance
    end

    GetPlayer():GetFPPCameraComponent().pitchMax = camera.cameraTransform.rotation.pitch
    GetPlayer():GetFPPCameraComponent().pitchMin = camera.cameraTransform.rotation.pitch

    applyBoom()
    Game.GetTeleportationFacility():Teleport(GetPlayer(), camera.cameraTransform.position, camera.cameraTransform.rotation)
    gameUtils.setSceneTier(4)

    return true
end

---Updates horizontal camera offset so the editor viewport center maps to world center ray.
---Used by docked UI layouts where the viewport center is not screen center.
---@param adjustedCenterX number Normalized horizontal viewport center in NDC space (typically `[-1, 1]`).
function camera.updateXOffset(adjustedCenterX)
    if not camera.active then return end

    local centerDir, _ = camera.screenToWorld(adjustedCenterX, 0)
    camera.xOffset = ((1 / centerDir.y) * camera.distance) * centerDir.x

    GetPlayer():GetFPPCameraComponent():SetLocalPosition(Vector4.new(- camera.xOffset, - camera.distance, 0, 0))
end

---Starts a camera transition tween between two world anchors.
---Interpolates position, yaw, and camera distance over `duration` using `inOutQuad`.
---Note: pitch/roll in `fromRot` and `toRot` are not interpolated by this tween.
---@param fromPos Vector4 Transition start world position.
---@param toPos Vector4 Transition end world position.
---@param fromRot EulerAngles Transition start rotation (yaw is used).
---@param toRot EulerAngles Transition end rotation (yaw is used).
---@param toDistance number Target camera distance at end of transition.
---@param duration number Transition duration in seconds.
function camera.transition(fromPos, toPos, fromRot, toRot, toDistance, duration)
    camera.transitionTween = tween.new(duration,
    { x = fromPos.x, y = fromPos.y, z = fromPos.z, yaw = fromRot.yaw, distance = camera.distance },
    { x = toPos.x, y = toPos.y, z = toPos.z, yaw = toRot.yaw, distance = toDistance },
    tween.easing.inOutQuad)
end

---Converts normalized screen coordinates to camera-space and world-space forward directions.
---Input coordinates use normalized device convention where center is `(0, 0)`,
---left/right are `-1/1`, and top/bottom are `1/-1`.
---@param x number Normalized horizontal screen coordinate.
---@param y number Normalized vertical screen coordinate.
---@return Vector4 relativeDirection Direction in camera-relative space (not normalized).
---@return Vector4 worldDirection Direction rotated into world space (not normalized).
function camera.screenToWorld(x, y)
    local cameraRotation = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetRotation()
    local pov = Game.GetPlayer():GetFPPCameraComponent():GetFOV()
    local width, height = GetDisplayResolution()

    local vertical = EulerAngles.new(0, pov / 2, 0):GetForward()
    local vecRelative = Vector4.new(vertical.z * (width / height) * x, vertical.y * 1, vertical.z * y, 0)

    local vecGlobal = Vector4.RotateAxis(vecRelative, Vector4.new(1, 0, 0, 0), math.rad(cameraRotation.pitch))
    vecGlobal = Vector4.RotateAxis(vecGlobal, Vector4.new(0, 0, 1, 0), math.rad(cameraRotation.yaw))

    return vecRelative, vecGlobal
end

---Projects a world-space point into normalized screen coordinates.
---@param position Vector4
---@return number x Normalized X coordinate in range approximately `[-1, 1]`.
---@return number y Normalized Y coordinate in range approximately `[-1, 1]`.
function camera.worldToScreen(position)
    local res = Game.GetCameraSystem():ProjectPoint(position)

    return res.x, res.y
end

return camera
