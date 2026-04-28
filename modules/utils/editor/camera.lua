local utils = require("modules/utils/utils")
local gameUtils = require("modules/utils/gameUtils")
local tween = require("modules/tween/tween")
local settings = require("modules/utils/settings")

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
            camera.distance = camera.distance + (y / (1 / settings.cameraZoomSpeed * 2.75)) * camera.deltaTime * distanceMultiplier
            camera.distance = math.max(0.1, camera.distance)

            GetPlayer():GetFPPCameraComponent():SetLocalPosition(Vector4.new(0, - camera.distance, 0, 0))
        else
            camera.cameraTransform.rotation.yaw = camera.cameraTransform.rotation.yaw - (x / (1 / settings.cameraRotateSpeed * 0.4)) * camera.deltaTime
            camera.cameraTransform.rotation.pitch = camera.cameraTransform.rotation.pitch - (y / (1 / settings.cameraRotateSpeed * 0.4)) * camera.deltaTime
            GetPlayer():GetFPPCameraComponent().pitchMax = camera.cameraTransform.rotation.pitch
            GetPlayer():GetFPPCameraComponent().pitchMin = camera.cameraTransform.rotation.pitch
        end
    end

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
