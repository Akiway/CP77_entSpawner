local visualized = require("modules/classes/spawn/visualized")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")
local history = require("modules/utils/history")
local utils = require("modules/utils/utils")
local gameUtils = require("modules/utils/gameUtils")
local field = require("modules/utils/field")
local colorUtil = require("modules/utils/color")
local lcHelper = require("modules/utils/lightChannelHelper")
local lightPreview = require("modules/utils/previewUtils")
local targeting = require("modules/utils/editor/targeting")
local Cron = require("modules/utils/Cron")

local LIGHT_TYPE_POINT = 0
local LIGHT_TYPE_SPOT = 1
local LIGHT_TYPE_AREA = 2

local INNER_ANGLE_BORDER_COLOR = 0xFF98CCE9 -- #e9cc98
local OUTER_ANGLE_BORDER_COLOR = 0xFFAF7838 -- #3878af
local RADIUS_ICON_COLOR = 0xFF5D9645 -- #45965d

local PREVIEW_COLOR_SPOT = "blue"
local PREVIEW_COLOR_SPOT_INNER = "yellow"
local PREVIEW_COLOR_DEFAULT = "yellow"
local PREVIEW_SPOT_CONE_RADIUS_FLOOR_RATIO = 0.03
local PREVIEW_SPOT_INNER_RADIUS_FLOOR_RATIO = 0.05
local PREVIEW_SPOT_INNER_SCALE_MULTIPLIER = 0.05 / 0.03
local PREVIEW_INTENSITY_MIN = 50
local PREVIEW_INTENSITY_MAX = 1000
local PREVIEW_BASE_SCALE_MAX = 0.04
local PREVIEW_BASE_SCALE_MIN = PREVIEW_BASE_SCALE_MAX * (PREVIEW_INTENSITY_MIN / PREVIEW_INTENSITY_MAX)
local PREVIEW_POINT_AREA_BASE_SCALE_MULTIPLIER = 4
local PREVIEW_PRISM_MESH = "base\\spawner\\triangular_prism.mesh"
local PREVIEW_PRISM_THICKNESS_MULTIPLIER = 2
local CAMERA_FOLLOW_HIDE_PREVIEW_SPEED_THRESHOLD = 0.08
local PREVIEW_SIZE_CONFIG = {
    minIntensity = PREVIEW_INTENSITY_MIN,
    maxIntensity = PREVIEW_INTENSITY_MAX,
    minScale = PREVIEW_BASE_SCALE_MIN,
    maxScale = PREVIEW_BASE_SCALE_MAX
}

local COLOR_HEX_BADGE_BG = colorUtil.packAABBGGRR({ 0.09, 0.20, 0.34 }, 0.95)
local COLOR_HEX_BADGE_HOVER = colorUtil.packAABBGGRR({ 0.13, 0.27, 0.45 }, 1.0)
local COLOR_HEX_BADGE_PRESSED = colorUtil.packAABBGGRR({ 0.07, 0.17, 0.29 }, 1.0)

---Class for worldStaticLightNode
---@class light : visualized
---@field public color {r: number, g: number, b: number}
---@field public intensity number
---@field public innerAngle number
---@field public outerAngle number
---@field public radius number
---@field public capsuleLength number
---@field public autoHideDistance number
---@field public flickerStrength number
---@field public flickerPeriod number
---@field public flickerOffset number
---@field public lightType integer
---@field public localShadows boolean
---@field public localShadowsForceStaticsOnly boolean
---@field private lightTypeNames table
---@field private lightTypeIcons table
---@field private lightTypeLabels table
---@field private temperature number
---@field private scaleVolFog number
---@field private useInParticles boolean
---@field private useInTransparents boolean
---@field private ev number
---@field private shadowAngle number
---@field private shadowFadeDistance number
---@field private shadowFadeRange number
---@field private contactShadows number
---@field private contactShadowsTypes table
---@field private maxShadowPropertiesWidth number
---@field private maxBasePropertiesWidth number
---@field private maxFlickerPropertiesWidth number
---@field private maxMiscPropertiesWidth number
---@field private spotCapsule boolean
---@field private softness number
---@field private attenuation number
---@field private clampAttenuation boolean
---@field private attenuationTypes table
---@field private sceneSpecularScale number
---@field private sceneDiffuse boolean
---@field private roughnessBias number
---@field private sourceRadius number
---@field private directional boolean
---@field private lightChannels table
---@field private rayTracedShadowsPlatform integer
---@field private rayTracingLightSourceRadius number
---@field private rayTracingContactShadowRange number
---@field private rayTracingIntensityScale number
---@field private pathTracingLightUsage integer
---@field private pathTracingOverrideScaleGI boolean
---@field private rtxdiShadowStartingDistance number
---@field private rayTracedShadowsPlatforms table
---@field private pathTracingLightUsageTypes table
---@field private maxRayPathTracingPropertiesWidth number
---@field private radiusPreviewed boolean
---@field private colorHexText string
---@field private colorHexEditing boolean
---@field private cameraFollowEnabled boolean
---@field private cameraFollowCronID number?
---@field private cameraFollowVisualizerVisible boolean?
local light = setmetatable({}, { __index = visualized })

function light:new()
	local o = visualized.new(self)

    o.spawnListType = "files"
    o.dataType = "Static Light"
    o.spawnDataPath = "data/spawnables/lights/staticLights/"
    o.modulePath = "light/light"
    o.node = "worldStaticLightNode"
    o.description = "Places a static light"
    o.icon = IconGlyphs.LightbulbOn20

    o.color = { 1, 1, 1 }
    o.intensity = 100
    o.innerAngle = 20
    o.outerAngle = 60
    o.radius = 15
    o.capsuleLength = 1
    o.autoHideDistance = 45
    o.flickerStrength = 0
    o.flickerPeriod = 0.2
    o.flickerOffset = 0
    o.lightType = LIGHT_TYPE_SPOT
    o.localShadows = true
    o.localShadowsForceStaticsOnly = false
    o.lightTypeNames = utils.enumTable("ELightType")
    o.lightTypeIcons = {
        [LIGHT_TYPE_POINT] = IconGlyphs.LightbulbOn20,
        [LIGHT_TYPE_SPOT] = IconGlyphs.TrackLight,
        [LIGHT_TYPE_AREA] = IconGlyphs.CarParkingLights
    }
    o.lightTypeLabels = {
        [LIGHT_TYPE_POINT] = "Point",
        [LIGHT_TYPE_SPOT] = "Spot",
        [LIGHT_TYPE_AREA] = "Area"
    }
    o.temperature = -1
    o.scaleVolFog = 0
    o.useInParticles = true
    o.useInTransparents = true
    o.ev = 0
    o.shadowAngle = -1
    o.shadowFadeDistance = 10
    o.shadowFadeRange = 5
    o.contactShadows = 0
    o.contactShadowsTypes = utils.enumTable("rendContactShadowReciever")
    o.spotCapsule = false
    o.softness = 2
    o.attenuation = 0
    o.attenuationTypes = utils.enumTable("rendLightAttenuation")
    o.sceneSpecularScale = 100
    o.clampAttenuation = false
    o.sceneDiffuse = true
    o.roughnessBias = 0
    o.sourceRadius = 0.05
    o.directional = false
    o.lightChannels = { true, true, true, true, true, true, true, true, true, false, false, false }
    o.rayTracedShadowsPlatform = 0
    o.rayTracingLightSourceRadius = 0
    o.rayTracingContactShadowRange = 0
    o.rayTracingIntensityScale = 1
    o.pathTracingLightUsage = 0
    o.pathTracingOverrideScaleGI = false
    o.rtxdiShadowStartingDistance = 0
    o.rayTracedShadowsPlatforms = utils.enumTable("rendRayTracedShadowsPlatform")
    o.pathTracingLightUsageTypes = utils.enumTable("rendEPathTracingLightUsage")

    o.maxBasePropertiesWidth = nil
    o.maxShadowPropertiesWidth = nil
    o.maxFlickerPropertiesWidth = nil
    o.maxMiscPropertiesWidth = nil
    o.maxRayPathTracingPropertiesWidth = nil

    o.previewColor = "yellow"
    o.previewed = true
    o.radiusPreviewed = false
    o.colorHexText = colorUtil.formatHexRGB(o.color)
    o.colorHexEditing = false
    o.cameraFollowEnabled = false
    o.cameraFollowCronID = nil
    o.cameraFollowVisualizerVisible = nil

    setmetatable(o, { __index = self })
    o:updateLightTypeIcon()
    o:updatePreviewShape()
    	return o
end

---@param typeIndex integer?
---@return string
function light:getLightTypeIcon(typeIndex)
    local idx = tonumber(typeIndex) or 0
    return self.lightTypeIcons[idx] or IconGlyphs.LightbulbOn20
end

---@param typeIndex integer?
---@return string
function light:getLightTypeLabel(typeIndex)
    local idx = tonumber(typeIndex) or 0
    return self.lightTypeLabels[idx] or self.lightTypeNames[idx + 1] or ("Type " .. tostring(idx))
end

function light:updateLightTypeIcon()
    self.icon = self:getLightTypeIcon(self.lightType)
    if self.object then
        self.object.icon = self.icon
    end
end

---@return table
function light:getPreviewSpec()
    local pointAreaBaseSize = lightPreview.getIntensityBaseSize(self.intensity, PREVIEW_POINT_AREA_BASE_SCALE_MULTIPLIER, PREVIEW_SIZE_CONFIG)

    if self.lightType == LIGHT_TYPE_AREA then
        local length = math.max(self.capsuleLength, 0)
        if self.spotCapsule then
            local outerPrismBaseThickness = pointAreaBaseSize * PREVIEW_PRISM_THICKNESS_MULTIPLIER
            local outerPrismSize = lightPreview.getSpotPrismSize(
                self.outerAngle,
                outerPrismBaseThickness,
                length,
                PREVIEW_SPOT_INNER_RADIUS_FLOOR_RATIO
            )
            local innerPrismSize = lightPreview.getSpotPrismSize(
                self.innerAngle,
                outerPrismBaseThickness * PREVIEW_SPOT_INNER_SCALE_MULTIPLIER,
                length,
                PREVIEW_SPOT_CONE_RADIUS_FLOOR_RATIO
            )

            return {
                shape = "mesh",
                color = PREVIEW_COLOR_SPOT,
                mesh = PREVIEW_PRISM_MESH,
                meshAppearance = PREVIEW_COLOR_SPOT,
                size = outerPrismSize,
                rotation = { kind = "quat", value = EulerAngles.new(-90, 0, 90):ToQuat() },
                innerMesh = {
                    mesh = PREVIEW_PRISM_MESH,
                    meshAppearance = PREVIEW_COLOR_SPOT_INNER,
                    size = innerPrismSize
                }
            }
        end

        return {
            shape = "capsule",
            color = PREVIEW_COLOR_DEFAULT,
            size = { x = pointAreaBaseSize, y = pointAreaBaseSize, z = length },
            rotation = { kind = "capsule" }
        }
    end

    if self.lightType == LIGHT_TYPE_SPOT then
        local outerSize = lightPreview.getSpotConeSize(
            self.outerAngle,
            lightPreview.getIntensityBaseSize(self.intensity, 1, PREVIEW_SIZE_CONFIG),
            PREVIEW_SPOT_CONE_RADIUS_FLOOR_RATIO
        )
        local innerSize = lightPreview.getSpotConeSize(
            self.innerAngle,
            lightPreview.getIntensityBaseSize(self.intensity, PREVIEW_SPOT_INNER_SCALE_MULTIPLIER, PREVIEW_SIZE_CONFIG),
            PREVIEW_SPOT_INNER_RADIUS_FLOOR_RATIO
        )

        return {
            shape = "cone",
            color = PREVIEW_COLOR_SPOT,
            size = outerSize,
            rotation = { kind = "quat", value = EulerAngles.new(0, 90, 0):ToQuat() },
            innerCone = {
                color = PREVIEW_COLOR_SPOT_INNER,
                size = innerSize
            }
        }
    end

    return {
        shape = "sphere",
        color = PREVIEW_COLOR_DEFAULT,
        size = { x = pointAreaBaseSize, y = pointAreaBaseSize, z = pointAreaBaseSize }
    }
end

function light:updatePreviewShape()
    local spec = self:getPreviewSpec()
    self.previewShape = spec.shape
    self.previewColor = spec.color or PREVIEW_COLOR_DEFAULT
    self.previewMesh = spec.mesh or ""
    self.previewMeshAppearance = spec.meshAppearance
end

---@return { x: number, y: number, z: number }
function light:getRadiusPreviewVisualizerSize()
    local sphereRadius = math.max(self.radius, 0)
    return { x = sphereRadius, y = sphereRadius, z = sphereRadius }
end

---@return boolean
function light:shouldShowRadiusPreview()
    return self.previewed and self.radiusPreviewed
end

---@param entity entEntity?
function light:updateRadiusPreviewVisibility(entity)
    local target = entity or self:getEntity()
    if not target then
        return
    end

    local sphere = target:FindComponentByName("radius_sphere")
    if not sphere then
        return
    end

    visualizer.updateScale(target, self:getRadiusPreviewVisualizerSize(), "radius_sphere")

    local shouldEnable = self:shouldShowRadiusPreview()
    if sphere:IsEnabled() ~= shouldEnable then
        sphere:Toggle(shouldEnable)
    end
end

---@return boolean
function light:isPlayerWalking()
    local player = GetPlayer()
    if not player or type(player.GetVelocity) ~= "function" then
        return false
    end

    local okVelocity, velocity = pcall(function ()
        return player:GetVelocity()
    end)
    if not okVelocity or not velocity then
        return false
    end

    local horizontalSpeedSquared = velocity.x * velocity.x + velocity.y * velocity.y
    return horizontalSpeedSquared > (CAMERA_FOLLOW_HIDE_PREVIEW_SPEED_THRESHOLD * CAMERA_FOLLOW_HIDE_PREVIEW_SPEED_THRESHOLD)
end

---@param entity entEntity?
---@param visible boolean
function light:setPreviewVisibilityForCameraFollow(entity, visible)
    local target = entity or self:getEntity()
    if not target then
        return
    end

    local shouldShowBasePreview = visible and self.previewed
    visualizer.toggleAll(target, shouldShowBasePreview)

    local sphere = target:FindComponentByName("radius_sphere")
    if not sphere then
        return
    end

    local shouldShowRadiusPreview = visible and self:shouldShowRadiusPreview()
    if sphere:IsEnabled() ~= shouldShowRadiusPreview then
        sphere:Toggle(shouldShowRadiusPreview)
    end
end

---@param entity entEntity?
function light:updatePreviewVisibilityForMovement(entity)
    local target = entity or self:getEntity()
    if not target then
        return
    end

    local shouldBeVisible = true
    if self.cameraFollowEnabled then
        shouldBeVisible = not self:isPlayerWalking()
    end

    if self.cameraFollowVisualizerVisible == shouldBeVisible then
        return
    end

    self.cameraFollowVisualizerVisible = shouldBeVisible
    self:setPreviewVisibilityForCameraFollow(target, shouldBeVisible)
end

---@param entity entEntity?
function light:applyPreviewAppearance(entity)
    local target = entity or self:getEntity()
    if not target then
        return
    end

    local spec = self:getPreviewSpec()
    if spec.shape ~= "mesh" then
        return
    end

    local function applyMeshAppearance(componentName, appearance)
        if not appearance then
            return
        end

        local mesh = target:FindComponentByName(componentName)
        if not mesh then
            return
        end

        local currentAppearance = mesh.meshAppearance and mesh.meshAppearance.value or nil
        if currentAppearance ~= appearance then
            mesh.meshAppearance = CName.new(appearance)
            mesh:LoadAppearance()
        end
    end

    applyMeshAppearance("mesh", spec.meshAppearance)
    if spec.innerMesh then
        applyMeshAppearance("mesh_inner", spec.innerMesh.meshAppearance)
    end
end

---@param entity entEntity?
function light:applyPreviewShapeRotation(entity)
    local target = entity or self:getEntity()
    if not target then
        return
    end

    local spec = self:getPreviewSpec()
    local rotation = spec.rotation
    if not rotation then
        return
    end

    if spec.shape == "cone" and rotation.kind == "quat" then
        for _, coneName in ipairs({ "cone", "cone_inner" }) do
            local cone = target:FindComponentByName(coneName)
            if cone then
                cone:SetLocalOrientation(rotation.value)
            end
        end
        return
    end

    if spec.shape == "mesh" and rotation.kind == "quat" then
        for _, meshName in ipairs({ "mesh", "mesh_inner" }) do
            local mesh = target:FindComponentByName(meshName)
            if mesh then
                mesh:SetLocalOrientation(rotation.value)
            end
        end
        return
    end

    if spec.shape ~= "capsule" or rotation.kind ~= "capsule" then
        return
    end

    local rollFix = EulerAngles.new(90, 0, 0)
    local rollFixQuat = rollFix:ToQuat()
    local rollFixFlippedQuat = EulerAngles.new(90, 0, 180):ToQuat()
    local halfHeight = spec.size.z / 2
    local topOffset = rollFixQuat:Transform(Vector4.new(0, 0, halfHeight, 0))
    local bottomOffset = rollFixQuat:Transform(Vector4.new(0, 0, -halfHeight, 0))

    local body = target:FindComponentByName("capsule_body")
    if body then
        body:SetLocalOrientation(rollFixQuat)
    end

    local top = target:FindComponentByName("capsule_top")
    if top then
        top:SetLocalOrientation(rollFixQuat)
        top:SetLocalPosition(topOffset)
    end

    local bottom = target:FindComponentByName("capsule_bottom")
    if bottom then
        bottom:SetLocalOrientation(rollFixFlippedQuat)
        bottom:SetLocalPosition(bottomOffset)
    end
end

---@param angle number?
---@return number
local function normalizeAngleDeg(angle)
    local value = tonumber(angle) or 0
    value = value % 360
    if value > 180 then
        value = value - 360
    end
    return value
end

---@param rotationLike any
---@return EulerAngles?
local function toEulerAnglesSafe(rotationLike)
    if not rotationLike then
        return nil
    end

    if rotationLike.roll ~= nil and rotationLike.pitch ~= nil and rotationLike.yaw ~= nil then
        return EulerAngles.new(rotationLike.roll, rotationLike.pitch, rotationLike.yaw)
    end

    local okEuler, euler = pcall(function ()
        if type(rotationLike.ToEulerAngles) == "function" then
            return rotationLike:ToEulerAngles()
        end
        return nil
    end)
    if okEuler and euler then
        return euler
    end

    return nil
end

---@param entity entEntity?
function light:updateArrowVisibilityForCameraFollow(entity)
    local target = entity or self:getEntity()
    if not target then
        return
    end

    if self.cameraFollowEnabled then
        visualizer.showArrows(target, false)
        return
    end

    local showArrows = self.isHovered == true
    if self.object and self.object.visualizerState ~= nil then
        showArrows = self.object.visualizerState == true
    end

    visualizer.showArrows(target, showArrows)
end

function light:teleportPlayerToLightCameraAligned()
    local player = GetPlayer()
    if not player or not self.position then
        return false
    end

    local targetPlayerPosition = Vector4.new(self.position)
    local playerPosition = player:GetWorldPosition()
    local camera = player:GetFPPCameraComponent()
    if playerPosition and camera then
        local cameraTransform = camera:GetLocalToWorld()
        if cameraTransform then
            local cameraPosition = cameraTransform:GetTranslation()
            if cameraPosition then
                local cameraOffset = utils.subVector(cameraPosition, playerPosition)
                targetPlayerPosition = utils.subVector(targetPlayerPosition, cameraOffset)
            end
        end
    end

    local targetPitch = self.rotation and self.rotation.pitch or 0
    local targetYaw = self.rotation and self.rotation.yaw or 0

    local cameraPitchOffset = 0
    local cameraYawOffset = 0
    if camera then
        local cameraTransform = camera:GetLocalToWorld()
        if cameraTransform then
            local cameraEuler = toEulerAnglesSafe(cameraTransform:GetRotation())
            local playerEuler = toEulerAnglesSafe(player:GetWorldOrientation())
            if cameraEuler and playerEuler then
                cameraPitchOffset = normalizeAngleDeg(cameraEuler.pitch - playerEuler.pitch)
                cameraYawOffset = normalizeAngleDeg(cameraEuler.yaw - playerEuler.yaw)
            end
        end
    end

    local playerOrientation = EulerAngles.new(0, targetPitch - cameraPitchOffset, targetYaw - cameraYawOffset)

    gameUtils.teleportPlayer(targetPlayerPosition, playerOrientation)
end

---@return Vector4?, EulerAngles?
function light:getCameraFollowTransform()
    local player = GetPlayer()
    if not player then
        return nil, nil
    end

    local camera = player:GetFPPCameraComponent()
    if not camera then
        return nil, nil
    end

    local cameraTransform = camera:GetLocalToWorld()
    if not cameraTransform then
        return nil, nil
    end

    local cameraPosition = cameraTransform:GetTranslation()
    local cameraRotation = cameraTransform:GetRotation()
    local cameraForward = cameraRotation and cameraRotation:GetForward() or nil
    if not cameraPosition or not cameraForward then
        return nil, nil
    end

    local targetPosition = utils.addVector(cameraPosition, cameraForward)
    local targetRotation = targeting.getLookAtRotation(self.rotation, cameraPosition, targetPosition)
    if not targetRotation and cameraRotation then
        targetRotation = toEulerAnglesSafe(cameraRotation)
    end

    return cameraPosition, targetRotation
end

---@return boolean updated
function light:applyCameraFollowTransform()
    local cameraPosition, cameraRotation = self:getCameraFollowTransform()
    if not cameraPosition or not cameraRotation then
        return false
    end

    self.position = Vector4.new(cameraPosition)
    self.rotation = EulerAngles.new(cameraRotation)
    self:update()
    self:updateArrowVisibilityForCameraFollow()
    self:updatePreviewVisibilityForMovement()

    if self.object and self.object.sUI and self.object.sUI.bumpWireframeEpoch then
        self.object.sUI.bumpWireframeEpoch()
    end

    return true
end

function light:stopCameraFollowUpdater()
    if self.cameraFollowCronID then
        Cron.Halt(self.cameraFollowCronID)
        self.cameraFollowCronID = nil
    end
end

function light:startCameraFollowUpdater()
    if not self.cameraFollowEnabled or self.cameraFollowCronID then
        return
    end

    self.cameraFollowCronID = Cron.OnUpdate(function ()
        if not self.cameraFollowEnabled or not self:isSpawned() then
            return
        end

        self:applyCameraFollowTransform()
    end)
end

---@param enabled boolean
function light:setCameraFollowEnabled(enabled)
    self.cameraFollowEnabled = enabled == true
    self.cameraFollowVisualizerVisible = nil

    if self.cameraFollowEnabled and self.object and self.object.sUI
        and type(self.object.sUI.cancelHierarchyPick) == "function"
        and type(self.object.sUI.isHierarchyPickActive) == "function"
        and self.object.sUI.isHierarchyPickActive(self.object) then
        self.object.sUI.cancelHierarchyPick(self.object)
    end

    if not self.cameraFollowEnabled then
        self:stopCameraFollowUpdater()
        self:updateArrowVisibilityForCameraFollow()
        self:updatePreviewVisibilityForMovement()
        return
    end

    if self:isSpawned() then
        self:applyCameraFollowTransform()
        self:updateArrowVisibilityForCameraFollow()
        self:startCameraFollowUpdater()
    end
end

function light:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    self.roughnessBias = math.min(math.max(math.floor(self.roughnessBias), -127), 127) -- Fix for incorrect clamping before
    self.scaleVolFog = math.floor(self.scaleVolFog)
    self.sceneSpecularScale = math.floor(self.sceneSpecularScale)
    self:updateLightTypeIcon()
    self:updatePreviewShape()
    self.colorHexText = colorUtil.formatHexRGB(self.color)
    self.colorHexEditing = false
    self.cameraFollowEnabled = data.cameraFollowEnabled == true
    self:stopCameraFollowUpdater()
end

---@param entity entEntity
function light:onAfterPreviewAssemble(entity)
    local spec = self:getPreviewSpec()
    local addedExtraShape = false

    visualizer.addSphere(entity, self:getRadiusPreviewVisualizerSize(), "ghostwhite", "radius_sphere")

    if spec.innerCone then
        visualizer.addCone(entity, spec.innerCone.size, spec.innerCone.color, "cone_inner")
        addedExtraShape = true
    end

    if spec.innerMesh then
        visualizer.addMesh(entity, spec.innerMesh.size, spec.innerMesh.mesh, spec.innerMesh.meshAppearance, "mesh_inner")
        addedExtraShape = true
    end

    if addedExtraShape then
        -- Ensure newly created secondary preview shapes follow global preview visibility.
        visualizer.toggleAll(entity, self.previewed)
    end

    self:applyPreviewAppearance(entity)
    self:applyPreviewShapeRotation(entity)
    self:updateArrowVisibilityForCameraFollow(entity)
    self:updateRadiusPreviewVisibility(entity)
    self:updatePreviewVisibilityForMovement(entity)
end

---@param entity entEntity
function light:onAfterPreviewScale(entity)
    local spec = self:getPreviewSpec()

    if spec.innerCone then
        visualizer.updateScale(entity, spec.innerCone.size, "cone_inner")
    end
    if spec.innerMesh then
        visualizer.updateScale(entity, spec.innerMesh.size, "mesh_inner")
    end

    self:applyPreviewAppearance(entity)
    self:applyPreviewShapeRotation(entity)
    self:updateArrowVisibilityForCameraFollow(entity)
    self:updateRadiusPreviewVisibility(entity)
    self:updatePreviewVisibilityForMovement(entity)
end

function light:onAssemble(entity)
    self:updatePreviewShape()
    visualized.onAssemble(self, entity)

    local component = gameLightComponent.new()
    component.name = "light"
    component.color = Color.new({ Red = math.floor(self.color[1] * 255), Green = math.floor(self.color[2] * 255), Blue = math.floor(self.color[3] * 255), Alpha = 255 })
    component.intensity = self.intensity
    component.turnOnByDefault = true
    component.innerAngle = self.innerAngle
    component.outerAngle = self.outerAngle
    component.radius = self.radius
    component.capsuleLength = self.capsuleLength
    component.autoHideDistance = self.autoHideDistance
    component:SetFlickerParams(self.flickerStrength, self.flickerPeriod, self.flickerOffset)
    component.type = Enum.new("ELightType", self.lightType)
    component.enableLocalShadows = self.localShadows
    component.enableLocalShadowsForceStaticsOnly = self.localShadowsForceStaticsOnly
    component.temperature = self.temperature
    component.scaleVolFog = self.scaleVolFog
    component.useInParticles = self.useInParticles
    component.useInTransparents = self.useInTransparents
    component.EV = self.ev
    component.shadowAngle = self.shadowAngle
    component.shadowFadeDistance = self.shadowFadeDistance
    component.shadowFadeRange = self.shadowFadeRange
    component.contactShadows = Enum.new("rendContactShadowReciever", self.contactShadows)
    component.spotCapsule = self.spotCapsule
    component.softness = self.softness
    component.attenuation = Enum.new("rendLightAttenuation", self.attenuation)
    component.clampAttenuation = self.clampAttenuation
    component.sceneSpecularScale = self.sceneSpecularScale
    component.sceneDiffuse = self.sceneDiffuse
    component.roughnessBias = self.roughnessBias
    component.sourceRadius = self.sourceRadius
    component.directional = self.directional
    component.rayTracedShadowsPlatform = Enum.new("rendRayTracedShadowsPlatform", self.rayTracedShadowsPlatform)
    component.rayTracingLightSourceRadius = self.rayTracingLightSourceRadius
    component.rayTracingContactShadowRange = self.rayTracingContactShadowRange
    component.rayTracingIntensityScale = self.rayTracingIntensityScale
    component.pathTracingLightUsage = Enum.new("rendEPathTracingLightUsage", self.pathTracingLightUsage)
    component.pathTracingOverrideScaleGI = self.pathTracingOverrideScaleGI
    component.rtxdiShadowStartingDistance = self.rtxdiShadowStartingDistance

    entity:AddComponent(component)
    self:updateArrowVisibilityForCameraFollow(entity)

    if self.cameraFollowEnabled then
        self:applyCameraFollowTransform()
        self:startCameraFollowUpdater()
    end
end

function light:despawn()
    self.cameraFollowVisualizerVisible = nil
    self:stopCameraFollowUpdater()
    visualized.despawn(self)
end

function light:save()
    local data = visualized.save(self)

    data.color = { self.color[1], self.color[2], self.color[3] }
    data.intensity = self.intensity
    data.innerAngle = self.innerAngle
    data.outerAngle = self.outerAngle
    data.radius = self.radius
    data.capsuleLength = self.capsuleLength
    data.autoHideDistance = self.autoHideDistance
    data.flickerStrength = self.flickerStrength
    data.flickerPeriod = self.flickerPeriod
    data.flickerOffset = self.flickerOffset
    data.lightType = self.lightType
    data.temperature = self.temperature
    data.scaleVolFog = self.scaleVolFog
    data.useInParticles = self.useInParticles
    data.useInTransparents = self.useInTransparents
    data.ev = self.ev
    data.shadowAngle = self.shadowAngle
    data.shadowFadeDistance = self.shadowFadeDistance
    data.shadowFadeRange = self.shadowFadeRange
    data.contactShadows = self.contactShadows
    data.spotCapsule = self.spotCapsule
    data.softness = self.softness
    data.attenuation = self.attenuation
    data.clampAttenuation = self.clampAttenuation
    data.sceneSpecularScale = self.sceneSpecularScale
    data.sceneDiffuse = self.sceneDiffuse
    data.roughnessBias = self.roughnessBias
    data.localShadows = self.localShadows
    data.localShadowsForceStaticsOnly = self.localShadowsForceStaticsOnly
    data.sourceRadius = self.sourceRadius
    data.directional = self.directional
    data.rayTracedShadowsPlatform = self.rayTracedShadowsPlatform
    data.rayTracingLightSourceRadius = self.rayTracingLightSourceRadius
    data.rayTracingContactShadowRange = self.rayTracingContactShadowRange
    data.rayTracingIntensityScale = self.rayTracingIntensityScale
    data.pathTracingLightUsage = self.pathTracingLightUsage
    data.pathTracingOverrideScaleGI = self.pathTracingOverrideScaleGI
    data.rtxdiShadowStartingDistance = self.rtxdiShadowStartingDistance
    data.lightChannels = utils.deepcopy(self.lightChannels)
    data.radiusPreviewed = self.radiusPreviewed
    data.cameraFollowEnabled = self.cameraFollowEnabled

    return data
end

---Update the light parameters without respawning (Color, Intensity, Angles, Radius, Flicker)
---@protected
function light:updateParameters()
    local entity = self:getEntity()

    if not entity then return end

    local comp = entity:FindComponentByName("light")
    comp:SetColor(Color.new({ Red = math.floor(self.color[1] * 255), Green = math.floor(self.color[2] * 255), Blue = math.floor(self.color[3] * 255) }))
    comp:SetIntensity(math.floor(self.intensity))
    comp:SetAngles(self.innerAngle, self.outerAngle)
    comp:SetRadius(self.radius)
    comp:SetFlickerParams(self.flickerStrength, self.flickerPeriod, self.flickerOffset)
end

function light:setPreview(state)
    self.cameraFollowVisualizerVisible = nil
    visualized.setPreview(self, state)
    self:updateRadiusPreviewVisibility()
    self:updatePreviewVisibilityForMovement()
end

function light:updateScale()
    visualized.updateScale(self)
end

---Respawn the light to update parameters, if changed
---@param changed boolean
---@protected
function light:updateFull(changed)
    self:updatePreviewShape()
    if changed and self:isSpawned() then self:respawn() end
end

---@param lightRef light
---@param changed boolean
---@param shouldUpdateScale boolean?
local function applyRuntimeParameterChange(lightRef, changed, shouldUpdateScale)
    if not changed then
        return
    end

    if shouldUpdateScale then
        lightRef:updateScale()
    end

    lightRef:updateParameters()
end

function light:draw()
    visualized.draw(self)
    local changed, finished

    if not self.maxBasePropertiesWidth then
        self.maxBasePropertiesWidth = utils.getTextMaxWidth({
            string.format("%s %s", IconGlyphs.Cone, "Inner Angle"),
            string.format("%s %s", IconGlyphs.Cone, "Outer Angle"),
            string.format("%s %s", IconGlyphs.FormatLineWeight, "Softness"),
            string.format("%s %s", IconGlyphs.Pill, "Capsule Length"),
            string.format("%s %s", IconGlyphs.CircleHalfFull, "Spot Capsule")
        }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    local lightTypeChanged = false
    local lightTypeTabWidth = 95 * style.viewSize
    local lightTypes = { LIGHT_TYPE_POINT, LIGHT_TYPE_SPOT, LIGHT_TYPE_AREA }
    for index, typeIndex in ipairs(lightTypes) do
        if index > 1 then
            ImGui.SameLine()
        end

        local selected = self.lightType == typeIndex
        local clicked = style.switchTabButton(
            string.format("%s %s##lightTypeTab%d", self:getLightTypeIcon(typeIndex), self:getLightTypeLabel(typeIndex), typeIndex),
            selected,
            lightTypeTabWidth,
            0
        )

        if clicked and self.lightType ~= typeIndex then
            if self.object then
                history.addAction(history.getElementChange(self.object))
            end
            self.lightType = typeIndex
            lightTypeChanged = true
        end
    end

    if lightTypeChanged then
        self:updateLightTypeIcon()
    end
    self:updateFull(lightTypeChanged)

    ImGui.Spacing()

    local colorPopupId = "##lightColorPickerMain" .. tostring(self.object and self.object.id or "")
    local swatchSize = 142 * style.viewSize
    local swatchRoundness = 14 * style.viewSize
    local hexInputWidth = 96
    local hexInputBottomOffset = 10 * style.viewSize
    
    ImGui.Dummy(0, 2 * style.viewSize)

    ImGui.BeginGroup()
    local swatchLocalX = ImGui.GetCursorPosX()
    local swatchLocalY = ImGui.GetCursorPosY()
    local swatchX, swatchY = ImGui.GetCursorScreenPos()
    local swatchMaxX = swatchX + swatchSize
    local swatchMaxY = swatchY + swatchSize
    local hexInputScreenX = swatchX + 10 * style.viewSize
    local hexInputScreenY = swatchY + swatchSize - ImGui.GetFrameHeight() - hexInputBottomOffset
    local hexInputScreenW = hexInputWidth * style.viewSize
    local hexInputScreenH = ImGui.GetFrameHeight()

    ImGui.Dummy(swatchSize, swatchSize)
    local drawList = ImGui.GetWindowDrawList()
    ImGui.ImDrawListAddRectFilled(
        drawList,
        swatchX,
        swatchY,
        swatchX + swatchSize,
        swatchY + swatchSize,
        colorUtil.packAABBGGRR(self.color, 1.0),
        swatchRoundness
    )

    local afterSwatchY = swatchLocalY + swatchSize
    local hexText = colorUtil.formatHexRGB(self.color)
    if not self.colorHexEditing and self.colorHexText ~= hexText then
        self.colorHexText = hexText
    end

    local hexInputY = swatchLocalY + swatchSize - ImGui.GetFrameHeight() - hexInputBottomOffset
    ImGui.SetCursorPos(swatchLocalX + 10 * style.viewSize, hexInputY)
    ImGui.PushStyleColor(ImGuiCol.FrameBg, COLOR_HEX_BADGE_BG)
    ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, COLOR_HEX_BADGE_HOVER)
    ImGui.PushStyleColor(ImGuiCol.FrameBgActive, COLOR_HEX_BADGE_PRESSED)
    self.colorHexText, changed, finished = style.trackedTextField(self.object, "##lightColorHexInput", self.colorHexText or hexText, "#RRGGBB", hexInputWidth)
    self.colorHexEditing = ImGui.IsItemActive()
    ImGui.PopStyleColor(3)
    if changed then
        self.colorHexText = (self.colorHexText or ""):upper()
        local parsedColor = colorUtil.parseHexRGB(self.colorHexText)
        if parsedColor then
            self.color = parsedColor
            applyRuntimeParameterChange(self, true, false)
        end
    end
    if finished then
        self.colorHexEditing = false
        local parsedColor = colorUtil.parseHexRGB(self.colorHexText)
        if parsedColor then
            self.color = parsedColor
            self.colorHexText = colorUtil.formatHexRGB(self.color)
            applyRuntimeParameterChange(self, true, false)
        else
            self.colorHexText = colorUtil.formatHexRGB(self.color)
        end
    end

    local colorPopupOpen = ImGui.IsPopupOpen(colorPopupId)
    local hoveringSwatch = ImGui.IsMouseHoveringRect(swatchX, swatchY, swatchMaxX, swatchMaxY)
    local hoveringHexInput = ImGui.IsMouseHoveringRect(
        hexInputScreenX,
        hexInputScreenY,
        hexInputScreenX + hexInputScreenW,
        hexInputScreenY + hexInputScreenH
    )
    if not colorPopupOpen and hoveringSwatch and not hoveringHexInput then
        if ImGui.IsMouseClicked(0) then
            ImGui.OpenPopup(colorPopupId)
        end
        ImGui.BeginTooltip()
        ImGui.PushStyleColor(ImGuiCol.Text, style.regularColor)
        ImGui.Text(colorUtil.formatPreviewTooltip(self.color))
        ImGui.PopStyleColor()
        ImGui.EndTooltip()
    end

    ImGui.SetCursorPos(swatchLocalX, afterSwatchY)
    ImGui.EndGroup()

    ImGui.SameLine()
    ImGui.Dummy(2 * style.viewSize, 0)

    ImGui.SameLine()
    ImGui.BeginGroup()

    ImGui.Dummy(0, 8 * style.viewSize)

    style.mutedText("Visualize")
    ImGui.SameLine()
    self.previewed, changed = style.trackedCheckbox(self.object, "##visualizeInline", self.previewed)
    if changed then
        self:setPreview(self.previewed)
    end

    ImGui.Dummy(0, 4 * style.viewSize)

    local currentCursorY = ImGui.GetCursorPosY()
    ImGui.SetCursorPosY(currentCursorY + 2 * style.viewSize)
    style.mutedText(IconGlyphs.WeatherSunny)
    ImGui.SameLine()
    ImGui.SetCursorPosY(currentCursorY)
    style.mutedText("Intensity")
    self.intensity, changed, _ = field.advancedTrackedFloat(self.object, "##intensity", self.intensity, {
        step = 1,
        min = 0,
        format = "%.1f",
        width = 80
    })
    applyRuntimeParameterChange(self, changed, true)

    ImGui.Dummy(0, 4 * style.viewSize)

    currentCursorY = ImGui.GetCursorPosY()
    ImGui.SetCursorPosY(currentCursorY + 2 * style.viewSize)
    style.styledText(IconGlyphs.RadiusOutline, RADIUS_ICON_COLOR)
    ImGui.SameLine()
    ImGui.SetCursorPosY(currentCursorY)
    style.mutedText("Radius")
    self.radius, changed, finished = style.trackedDragFloat(self.object, "##radius", self.radius, 0.25, 0, 9999, "%.1fm", 60)
    applyRuntimeParameterChange(self, changed, false)
    if changed then
        self:updateRadiusPreviewVisibility()
    end
    self:updateFull(finished)
    style.tooltip("How far the light source emitts light, visualized by the green sphere")

    ImGui.SameLine()
    ImGui.BeginDisabled(not self.previewed)
    local newRadiusPreviewed, toggled = style.toggleButton(IconGlyphs.HospitalMarker .. "##radiusPreview", self.radiusPreviewed)
    ImGui.EndDisabled()
    if toggled then
        if self.object then
            history.addAction(history.getElementChange(self.object))
        end
        self.radiusPreviewed = newRadiusPreviewed
        self:updateRadiusPreviewVisibility()
    end

    style.tooltip(
        (not self.previewed and "Enable global visualization to edit radius preview")
            or (self.radiusPreviewed and "Disable radius preview sphere" or "Enable radius preview sphere")
    )
    ImGui.EndGroup()

    if ImGui.BeginPopup(colorPopupId) then
        self.color, changed = style.trackedColorPicker(self.object, "##lightMainColorPicker", self.color)
        if changed then
            applyRuntimeParameterChange(self, true, false)
            self.colorHexText = colorUtil.formatHexRGB(self.color)
        end
        ImGui.EndPopup()
    end
    
    ImGui.Dummy(0, 8 * style.viewSize)
    
    if self.lightType == LIGHT_TYPE_AREA then
        style.drawIconLabelRow(IconGlyphs.Pill, "Capsule Length", { fieldX = self.maxBasePropertiesWidth })
        ImGui.SameLine()
        self.capsuleLength, changed, finished = style.trackedDragFloat(self.object, "##capsuleLength", self.capsuleLength, 0.05, 0, 9999, "%.2fm", 60)
        self:updateFull(finished)
        if changed then
            self:updateScale()
        end
        
        style.drawIconLabelRow(IconGlyphs.CircleHalfFull, "Spot Capsule", { fieldX = self.maxBasePropertiesWidth })
        ImGui.SameLine()
        self.spotCapsule, changed = style.trackedCheckbox(self.object, "##spotCapsule", self.spotCapsule)
        self:updateFull(changed)
    end

    if self.lightType == LIGHT_TYPE_SPOT or (self.lightType == LIGHT_TYPE_AREA and self.spotCapsule) then
        style.drawIconLabelRow(IconGlyphs.Cone, "Inner Angle", { iconColor = INNER_ANGLE_BORDER_COLOR, fieldX = self.maxBasePropertiesWidth })
        ImGui.SameLine()
        self.innerAngle, changed, finished = style.trackedDragFloat(self.object, "##inner", self.innerAngle, 0.1, 0, 360, "%.1f°", 60)
        style.tooltip("Inner angle of the light, visualized by the yellow cone\nThe area between inner and outer angles is where the light intensity falls off")
        applyRuntimeParameterChange(
            self,
            changed,
            self.lightType == LIGHT_TYPE_SPOT or (self.lightType == LIGHT_TYPE_AREA and self.spotCapsule)
        )
        if self.lightType == LIGHT_TYPE_AREA then
            self:updateFull(finished)
        end

        style.drawIconLabelRow(IconGlyphs.Cone, "Outer Angle", { iconColor = OUTER_ANGLE_BORDER_COLOR, fieldX = self.maxBasePropertiesWidth })
        ImGui.SameLine()
        self.outerAngle, changed, finished = style.trackedDragFloat(self.object, "##outer", self.outerAngle, 0.1, 0, 360, "%.1f°", 60)
        style.tooltip("Outer angle of the light, visualized by the blue cone\nThe area between inner and outer angles is where the light intensity falls off")
        applyRuntimeParameterChange(
            self,
            changed,
            self.lightType == LIGHT_TYPE_SPOT or (self.lightType == LIGHT_TYPE_AREA and self.spotCapsule)
        )
        if self.lightType == LIGHT_TYPE_AREA then
            self:updateFull(finished)
        end

        style.drawIconLabelRow(IconGlyphs.FormatLineWeight, "Softness", { fieldX = self.maxBasePropertiesWidth })
        ImGui.SameLine()
        self.softness, _, finished = style.trackedDragFloat(self.object, "##softness", self.softness, 0.05, 0, 9999, "%.2f", 60)
        style.tooltip("Softens the transition between both angles")
        self:updateFull(finished)
    end
    
    ImGui.Dummy(0, 4 * style.viewSize)
    
    local rotationTargetingDisabled = self.object == nil or self.object:isLocked() or self.object.rotationLocked
    local targetingDisabledByCameraFollow = self.cameraFollowEnabled == true

    -- Aim At ACTIONS
    if self.lightType == LIGHT_TYPE_SPOT or (self.lightType == LIGHT_TYPE_AREA and self.spotCapsule) then
        style.sectionHeaderStart("Direct the light")
            local hasHierarchyPicker = self.object and self.object.sUI
                and type(self.object.sUI.beginHierarchyPick) == "function"
                and type(self.object.sUI.cancelHierarchyPick) == "function"
                and type(self.object.sUI.isHierarchyPickActive) == "function"
            local hierarchyPickActive = hasHierarchyPicker and self.object.sUI.isHierarchyPickActive(self.object)
            local directTargetingDisabled = rotationTargetingDisabled or targetingDisabledByCameraFollow
            local hierarchyPickDisabled = not hasHierarchyPicker or directTargetingDisabled

            ImGui.BeginDisabled(directTargetingDisabled)
            if ImGui.Button(IconGlyphs.TargetAccount .. " Aim at Player##lightAimAtPlayer") then
                local player = GetPlayer()
                if player then
                    targeting.aimElementAtWorldPosition(self.object, player:GetWorldPosition())
                end
            end
            ImGui.EndDisabled()
            if targetingDisabledByCameraFollow then
                style.tooltip("Disable Follow Camera to target the player manually.")
            elseif rotationTargetingDisabled and self.object and self.object.rotationLocked then
                style.tooltip("Unlock rotation to target the player.")
            else
                style.tooltip("Rotate this light to point at the player's current world position.")
            end

            ImGui.SameLine()

            ImGui.BeginDisabled(hierarchyPickDisabled)
            local hierarchyButtonLabel = hierarchyPickActive and " Cancel Target Pick" or " Aim at Element"
            local hierarchyButtonClicked = false
            if hierarchyPickActive then
                hierarchyButtonClicked = style.successButton(IconGlyphs.Target .. hierarchyButtonLabel .. "##lightHierarchyTargetPick")
            else
                hierarchyButtonClicked = ImGui.Button(IconGlyphs.Target .. hierarchyButtonLabel .. "##lightHierarchyTargetPick")
            end
            if hierarchyButtonClicked then
                if hierarchyPickActive then
                    self.object.sUI.cancelHierarchyPick(self.object)
                else
                    local sourceElement = self.object
                    self.object.sUI.beginHierarchyPick(sourceElement, function(targetElement)
                        if not targeting.canAimElementAtElement(sourceElement, targetElement) then
                            return false
                        end

                        -- Completing the pick should not depend on whether rotation changed.
                        targeting.aimElementAtElement(sourceElement, targetElement)
                        return true
                    end, {
                        allowOwner = false,
                        canPick = function(targetElement)
                            return targeting.canAimElementAtElement(sourceElement, targetElement)
                        end,
                        restoreOwnerSelection = true
                    })
                end
            end
            ImGui.EndDisabled()
            if targetingDisabledByCameraFollow then
                style.tooltip("Disable Follow Camera to use hierarchy targeting.")
            elseif hierarchyPickDisabled and self.object and self.object.rotationLocked then
                style.tooltip("Unlock rotation to use hierarchy targeting.")
            elseif hierarchyPickActive then
                style.tooltip("Click an element in the hierarchy or click anywhere in the 3D world to aim this light.\nPress Esc or click this button again to cancel.")
            else
                style.tooltip("Pick a hierarchy element or click in the 3D world to rotate this light toward that target.")
            end
        style.sectionHeaderEnd(false)
    end

    style.sectionHeaderStart("Be the light")
        local cameraFollowToggleDisabled = rotationTargetingDisabled and not self.cameraFollowEnabled
        ImGui.BeginDisabled(cameraFollowToggleDisabled)
        local newCameraFollowEnabled, cameraFollowChanged = style.toggleButton(
            IconGlyphs.CameraLockOutline .. " Follow Camera##lightCameraFollow",
            self.cameraFollowEnabled
        )
        ImGui.EndDisabled()
        if cameraFollowChanged then
            if self.object then
                history.addAction(history.getElementChange(self.object))
            end
            self:setCameraFollowEnabled(newCameraFollowEnabled)
        end
        if cameraFollowToggleDisabled and self.object and self.object.rotationLocked then
            style.tooltip("Unlock rotation to enable camera follow.")
        elseif self.cameraFollowEnabled then
            style.tooltip("Light follows player camera position and direction.\nDisable to keep the current transform.")
        else
            style.tooltip("Attach this light to the player camera and align direction to camera view.")
        end

        ImGui.SameLine()

        local teleportDisabledByEditor = self.object and self.object.sUI and self.object.sUI.spawner.editor.active == true or false
        if style.warnButton(IconGlyphs.RunFast .. "##lightTeleportCameraAligned", {
            tooltip = "Teleport player so camera position and look direction match this light.",
            disabled = teleportDisabledByEditor,
            disabledTooltip = "Teleportation disabled while in 3D-Editor mode"
        }) then
            self:teleportPlayerToLightCameraAligned()
        end
    style.sectionHeaderEnd(false)
    
    ImGui.Dummy(0, 4 * style.viewSize)

    -- Other Settings
    if ImGui.TreeNodeEx("Shadow Settings") then
        if not self.maxShadowPropertiesWidth then
            self.maxShadowPropertiesWidth = utils.getTextMaxWidth({ "Contact Shadows", "Local Shadows", "Local Shadows (Statics Only)", "Shadow Angle", "Shadow Fade Distance", "Shadow Fade Range" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        end

        style.mutedText("Contact Shadows")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.contactShadows, changed = style.trackedCombo(self.object, "##contactShadows", self.contactShadows, self.contactShadowsTypes)
        self:updateFull(changed)

        if self.lightType == LIGHT_TYPE_SPOT or self.lightType == LIGHT_TYPE_AREA then
            style.mutedText("Local Shadows")
            ImGui.SameLine()
            ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
            self.localShadows, changed = style.trackedCheckbox(self.object, "##localShadows", self.localShadows)
            self:updateFull(changed)

            style.mutedText("Local Shadows (Statics Only)")
            ImGui.SameLine()
            ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
            ImGui.BeginDisabled(not self.localShadows)
            self.localShadowsForceStaticsOnly, changed = style.trackedCheckbox(self.object, "##localShadowsForceStaticsOnly", self.localShadowsForceStaticsOnly)
            ImGui.EndDisabled()
            self:updateFull(changed)
        end

        style.mutedText("Shadow Angle")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.shadowAngle, _, finished = style.trackedDragFloat(self.object, "##shadowAngle", self.shadowAngle, 0.01, -1, 9999, "%.2f", 75)
        self:updateFull(finished)

        style.mutedText("Shadow Fade Distance")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.shadowFadeDistance, _, finished = style.trackedDragFloat(self.object, "##shadowFadeDistance", self.shadowFadeDistance, 0.01, 0, 9999, "%.1f", 75)
        self:updateFull(finished)

        style.mutedText("Shadow Fade Range")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.shadowFadeRange, _, finished = style.trackedDragFloat(self.object, "##shadowFadeRange", self.shadowFadeRange, 0.01, 0, 9999, "%.1f", 75)
        self:updateFull(finished)

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Flicker Settings") then
        if not self.maxFlickerPropertiesWidth then
            self.maxFlickerPropertiesWidth = utils.getTextMaxWidth({ "Flicker Period", "Flicker Strength", "Flicker Offset" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        end

        style.mutedText("Flicker Period")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxFlickerPropertiesWidth)
        self.flickerPeriod, changed = style.trackedDragFloat(self.object, "##flickerPeriod", self.flickerPeriod, 0.01, 0.05, 9999, "%.2f", 85)
        applyRuntimeParameterChange(self, changed, false)

        style.mutedText("Flicker Strength")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxFlickerPropertiesWidth)
        self.flickerStrength, changed = style.trackedDragFloat(self.object, "##flickerStrength", self.flickerStrength, 0.01, 0, 9999, "%.2f", 85)
        applyRuntimeParameterChange(self, changed, false)

        style.mutedText("Flicker Offset")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxFlickerPropertiesWidth)
        self.flickerOffset, changed = style.trackedDragFloat(self.object, "##flickerOffset", self.flickerOffset, 0.01, 0, 9999, "%.2f", 85)
        applyRuntimeParameterChange(self, changed, false)

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Light Channels") then
        self.lightChannels = style.drawLightChannelsSelector(self.object, self.lightChannels)
        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Misc. Settings") then
        if not self.maxMiscPropertiesWidth then
            self.maxMiscPropertiesWidth = utils.getTextMaxWidth({ "Directional", "Use in particles", "Use in transparents", "Scale Vol. Fog", "Auto Hide Distance", "EV", "Attenuation Mode", "Clamp Attenuation", "Specular Scale", "Scene Diffuse", "Roughness Bias", "Source Radius" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        end

        style.mutedText("Use in particles")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.useInParticles, changed = style.trackedCheckbox(self.object, "##useInParticles", self.useInParticles)
        self:updateFull(changed)

        style.mutedText("Use in transparents")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.useInTransparents, changed = style.trackedCheckbox(self.object, "##useInTransparents", self.useInTransparents)
        self:updateFull(changed)

        style.mutedText("Scale Vol. Fog")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.scaleVolFog, _, finished = style.trackedSliderInt(self.object, "##scaleVolFog", self.scaleVolFog, 0, 255, 110)
        self:updateFull(finished)

        style.mutedText("Scene Diffuse")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.sceneDiffuse, changed = style.trackedCheckbox(self.object, "##sceneDiffuse", self.sceneDiffuse)
        self:updateFull(changed)

        style.mutedText("Specular Scale")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.sceneSpecularScale, _, finished = style.trackedSliderInt(self.object, "##sceneSpecularScale", self.sceneSpecularScale, 0, 255, 110)
        self:updateFull(finished)

        style.mutedText("Roughness Bias")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.roughnessBias, _, finished = style.trackedSliderInt(self.object, "##roughnessBias", self.roughnessBias, -127, 127, 110)
        self:updateFull(finished)

        style.mutedText("Source Radius")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.sourceRadius, _, finished = style.trackedDragFloat(self.object, "##sourceRadius", self.sourceRadius, 0.0025, 0, 9999, "%.3f", 110)
        self:updateFull(finished)

        style.mutedText("Auto Hide Distance")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.autoHideDistance, _, finished = style.trackedDragFloat(self.object, "##autoHideDistance", self.autoHideDistance, 0.05, 0, 9999, "%.1f", 110)
        self:updateFull(finished)
        ImGui.SameLine()
        local distance = utils.distanceVector(self.position, GetPlayer():GetWorldPosition())
        style.styledText(IconGlyphs.AxisArrowInfo, distance > self.autoHideDistance and 0xFF0000FF or 0xFF00FF00)
        style.tooltip(string.format("Distance to node position: %.2f", distance))

        style.mutedText("EV")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.ev, _, finished = style.trackedDragFloat(self.object, "##ev", self.ev, 0.1, 0, 9999, "%.1f", 110)
        self:updateFull(finished)

        style.mutedText("Attenuation Mode")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.attenuation, changed = style.trackedCombo(self.object, "##attenuation", self.attenuation, self.attenuationTypes, 110)
        self:updateFull(changed)

        style.mutedText("Clamp Attenuation")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.clampAttenuation, changed = style.trackedCheckbox(self.object, "##clampAttenuation", self.clampAttenuation)
        self:updateFull(changed)

        style.mutedText("Directional")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.directional, changed = style.trackedCheckbox(self.object, "##directional", self.directional)
        self:updateFull(changed)

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Ray/Path Tracing Settings") then
        if not self.maxRayPathTracingPropertiesWidth then
            self.maxRayPathTracingPropertiesWidth = utils.getTextMaxWidth({
                "Ray Traced Shadows Platform",
                "RT Light Source Radius",
                "RT Contact Shadow Range",
                "RT Intensity Scale",
                "Path Tracing Light Usage",
                "PT Override Scale GI",
                "RTXDI Shadow Start Distance"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        end

        style.mutedText("Ray Traced Shadows Platform")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxRayPathTracingPropertiesWidth)
        self.rayTracedShadowsPlatform, changed = style.trackedCombo(
            self.object,
            "##rayTracedShadowsPlatform",
            self.rayTracedShadowsPlatform,
            self.rayTracedShadowsPlatforms,
            175
        )
        self:updateFull(changed)

        style.mutedText("RT Light Source Radius")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxRayPathTracingPropertiesWidth)
        self.rayTracingLightSourceRadius, _, finished = style.trackedDragFloat(
            self.object,
            "##rayTracingLightSourceRadius",
            self.rayTracingLightSourceRadius,
            0.005,
            0,
            9999,
            "%.3f",
            120
        )
        self:updateFull(finished)

        style.mutedText("RT Contact Shadow Range")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxRayPathTracingPropertiesWidth)
        self.rayTracingContactShadowRange, _, finished = style.trackedDragFloat(
            self.object,
            "##rayTracingContactShadowRange",
            self.rayTracingContactShadowRange,
            0.05,
            0,
            9999,
            "%.2f",
            120
        )
        self:updateFull(finished)

        style.mutedText("RT Intensity Scale")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxRayPathTracingPropertiesWidth)
        self.rayTracingIntensityScale, _, finished = style.trackedDragFloat(
            self.object,
            "##rayTracingIntensityScale",
            self.rayTracingIntensityScale,
            0.01,
            0,
            9999,
            "%.2f",
            120
        )
        self:updateFull(finished)

        style.mutedText("Path Tracing Light Usage")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxRayPathTracingPropertiesWidth)
        self.pathTracingLightUsage, changed = style.trackedCombo(
            self.object,
            "##pathTracingLightUsage",
            self.pathTracingLightUsage,
            self.pathTracingLightUsageTypes,
            175
        )
        self:updateFull(changed)

        style.mutedText("PT Override Scale GI")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxRayPathTracingPropertiesWidth)
        self.pathTracingOverrideScaleGI, changed = style.trackedCheckbox(self.object, "##pathTracingOverrideScaleGI", self.pathTracingOverrideScaleGI)
        self:updateFull(changed)

        style.mutedText("RTXDI Shadow Start Distance")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxRayPathTracingPropertiesWidth)
        self.rtxdiShadowStartingDistance, _, finished = style.trackedDragFloat(
            self.object,
            "##rtxdiShadowStartingDistance",
            self.rtxdiShadowStartingDistance,
            0.05,
            0,
            9999,
            "%.2f",
            120
        )
        self:updateFull(finished)

        ImGui.TreePop()
    end

end

function light:getProperties()
    local properties = visualized.getProperties(self)
    table.insert(properties, {
        id = self.node,
        name = self.dataType,
        defaultHeader = true,
        draw = function()
            self:draw()
        end
    })
    return properties
end

function light:getGroupedProperties()
    local properties = visualized.getGroupedProperties(self)

    properties["lcGrouped"] = lcHelper.getGroupedProperties(self)

    return properties
end

function light:getVisualizerSize()
    return self:getPreviewSpec().size
end

function light:getSize()
    return { x = 0.02, y = 0.2, z = 0.2 }
end

function light:getBBox()
    return {
        min = { x = -0.01, y = -0.01, z = -0.1 },
        max = { x = 0.01, y = 0.01, z = 0.1 }
    }
end

function light:export()
    local data = visualized.export(self)
    data.type = "worldStaticLightNode"

    data.data = {
        autoHideDistance = self.autoHideDistance,
        capsuleLength = self.capsuleLength,
        color = {
            ["Red"] = math.floor(self.color[1] * 255),
            ["Green"] = math.floor(self.color[2] * 255),
            ["Blue"] = math.floor(self.color[3] * 255),
            ["Alpha"] = 255
        },
        enableLocalShadows = self.localShadows and 1 or 0,
        enableLocalShadowsForceStaticsOnly = self.localShadowsForceStaticsOnly and 1 or 0,
        flicker = {
            ["flickerPeriod"] = self.flickerPeriod,
            ["flickerStrength"] = self.flickerStrength,
            ["positionOffset"] = self.flickerOffset
        },
        innerAngle = self.innerAngle,
        intensity = self.intensity,
        outerAngle = self.outerAngle,
        radius = self.radius,
        type = self.lightTypeNames[self.lightType + 1],
        allowDistantLight = 0,
        lightChannel = utils.buildBitfieldString(self.lightChannels, style.lightChannelEnum),
        scaleVolFog = self.scaleVolFog,
        useInParticles = self.useInParticles and 1 or 0,
        useInTransparents = self.useInTransparents and 1 or 0,
        EV = self.ev,
        shadowAngle = self.shadowAngle,
        shadowFadeDistance = self.shadowFadeDistance,
        shadowFadeRange = self.shadowFadeRange,
        contactShadows = self.contactShadowsTypes[self.contactShadows + 1],
        spotCapsule = self.spotCapsule and 1 or 0,
        softness = self.softness,
        attenuation = self.attenuationTypes[self.attenuation + 1],
        clampAttenuation = self.clampAttenuation and 1 or 0,
        sceneSpecularScale = self.sceneSpecularScale,
        sceneDiffuse = self.sceneDiffuse and 1 or 0,
        roughnessBias = self.roughnessBias,
        sourceRadius = self.sourceRadius,
        directional = self.directional and 1 or 0,
        rayTracedShadowsPlatform = self.rayTracedShadowsPlatforms[self.rayTracedShadowsPlatform + 1],
        rayTracingLightSourceRadius = self.rayTracingLightSourceRadius,
        rayTracingContactShadowRange = self.rayTracingContactShadowRange,
        rayTracingIntensityScale = self.rayTracingIntensityScale,
        pathTracingLightUsage = self.pathTracingLightUsageTypes[self.pathTracingLightUsage + 1],
        pathTracingOverrideScaleGI = self.pathTracingOverrideScaleGI and 1 or 0,
        rtxdiShadowStartingDistance = self.rtxdiShadowStartingDistance
    }

    return data
end

return light
