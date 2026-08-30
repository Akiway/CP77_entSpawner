local visualized = require("modules/classes/spawn/visualized")
local visualizer = require("modules/utils/preview/visualizer")
local style = require("modules/ui/style")
local history = require("modules/utils/project/history")
local utils = require("modules/utils/core/utils")
local gameUtils = require("modules/utils/game/gameUtils")
local field = require("modules/utils/ui/field")
local colorUtil = require("modules/utils/ui/color")
local settings = require("modules/utils/core/settings")
local lcHelper = require("modules/utils/ui/lightChannelHelper")
local lightPreview = require("modules/utils/preview/previewUtils")
local targeting = require("modules/utils/editor/targeting")
local iesProfiles = require("modules/utils/data/iesProfiles")
local Cron = require("modules/utils/vendor/Cron")

local LIGHT_TYPE_POINT = 0
local LIGHT_TYPE_SPOT = 1
local LIGHT_TYPE_AREA = 2

local AREA_SHAPE_SPHERE = 0
local AREA_SHAPE_CAPSULE = 1

local SHADOW_SOFTNESS_MODE_DEFAULT = 2
local DEFAULT_STATIC_LIGHT_COLOR = { 1, 0.99595707654953, 0.6502890586853 }

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
local PHOTOMODE_PLAYER_RECORD_ID = "Character.Player_Puppet_Photomode"
local PREVIEW_SIZE_CONFIG = {
    minIntensity = PREVIEW_INTENSITY_MIN,
    maxIntensity = PREVIEW_INTENSITY_MAX,
    minScale = PREVIEW_BASE_SCALE_MIN,
    maxScale = PREVIEW_BASE_SCALE_MAX
}

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
---@field private unit integer
---@field private temperature number
---@field private scaleVolFog number
---@field private scaleGI number
---@field private scaleEnvProbes number
---@field private useInParticles boolean
---@field private useInTransparents boolean
---@field private ev number
---@field private shadowAngle number
---@field private shadowRadius number
---@field private shadowSoftnessMode integer
---@field private shadowFadeDistance number
---@field private shadowFadeRange number
---@field private contactShadows number
---@field private contactShadowsTypes table
---@field private maxShadowPropertiesWidth number
---@field private maxBasePropertiesWidth number
---@field private maxFlickerPropertiesWidth number
---@field private maxMiscPropertiesWidth number
---@field private spotCapsule boolean
---@field private areaShape integer
---@field private areaTwoSided boolean
---@field private areaRectSideA number
---@field private areaRectSideB number
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
---@field private lightGroup integer
---@field private envColorGroup integer
---@field private colorGroupSaturation number
---@field private portalAngleCutoff number
---@field private allowDistantLight boolean
---@field private rayTracedShadowsPlatform integer
---@field private rayTracingLightSourceRadius number
---@field private rayTracingContactShadowRange number
---@field private rayTracingIntensityScale number
---@field private pathTracingLightUsage integer
---@field private pathTracingOverrideScaleGI boolean
---@field private rtxdiShadowStartingDistance number
---@field private iesProfile string
---@field private iesProfileSearch string
---@field private rayTracedShadowsPlatforms table
---@field private pathTracingLightUsageTypes table
---@field private lightUnitTypes table
---@field private areaShapeTypes table
---@field private shadowSoftnessModes table
---@field private lightGroupTypes table
---@field private envColorGroupTypes table
---@field private maxRayPathTracingPropertiesWidth number
---@field private maxGroupPropertiesWidth number
---@field private maxAreaPropertiesWidth number
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

    -- Disabled while a Spawn New asset preview runs, so already placed lights and their
    -- visualizers do not contaminate the previewed asset. `light` itself is only
    -- suppressed for camera-following lights (see spawnUI.setAssetPreviewActive).
    o.previewSuppressedComponents = {
        light = "light",
        visualizers = {
            "box",
            "sphere",
            "cone",
            "cone_inner",
            "capsule_body",
            "capsule_top",
            "capsule_bottom",
            "mesh",
            "mesh_inner",
            "radius_sphere",
            "arrows"
        }
    }

    o.color = colorUtil.normalizeRGB(settings.defaultLightColor, DEFAULT_STATIC_LIGHT_COLOR)
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
    o.lightTypeIcons = {}
    o.lightTypeLabels = {}
    for _, typeOption in ipairs(style.lightTypeOptions) do
        o.lightTypeIcons[typeOption.index] = typeOption.icon
        o.lightTypeLabels[typeOption.index] = typeOption.label
    end
    -- Defaults below match the engine defaults of worldStaticLightNode / entLightComponent, so
    -- setting them explicitly does not change how a light looks compared to leaving them untouched.
    o.unit = 0
    o.temperature = -1
    o.scaleVolFog = 0
    o.scaleGI = 100
    o.scaleEnvProbes = 100
    o.useInParticles = true
    o.useInTransparents = true
    o.ev = 0
    o.shadowAngle = -1
    o.shadowRadius = -1
    o.shadowSoftnessMode = SHADOW_SOFTNESS_MODE_DEFAULT
    o.shadowFadeDistance = 10
    o.shadowFadeRange = 5
    o.contactShadows = 0
    o.contactShadowsTypes = utils.enumTable("rendContactShadowReciever")
    o.spotCapsule = false
    o.areaShape = AREA_SHAPE_CAPSULE
    o.areaTwoSided = true
    o.areaRectSideA = 1
    o.areaRectSideB = 1
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
    o.lightGroup = 0
    o.envColorGroup = 0
    o.colorGroupSaturation = 100
    o.portalAngleCutoff = 0
    -- Engine default is `true`, but every light exported by WB so far shipped with distant lights
    -- disabled, so keeping `false` avoids silently changing already saved objects on re-export.
    o.allowDistantLight = false
    o.rayTracedShadowsPlatform = 0
    o.rayTracingLightSourceRadius = 0
    o.rayTracingContactShadowRange = 0
    o.rayTracingIntensityScale = 1
    o.pathTracingLightUsage = 0
    o.pathTracingOverrideScaleGI = false
    o.rtxdiShadowStartingDistance = 0
    o.iesProfile = ""
    o.iesProfileSearch = ""
    o.rayTracedShadowsPlatforms = utils.enumTable("rendRayTracedShadowsPlatform")
    o.pathTracingLightUsageTypes = utils.enumTable("rendEPathTracingLightUsage")
    o.lightUnitTypes = utils.enumTable("ELightUnit")
    o.areaShapeTypes = utils.enumTable("EAreaLightShape")
    o.shadowSoftnessModes = utils.enumTable("ELightShadowSoftnessMode")
    o.lightGroupTypes = utils.enumTable("rendLightGroup")
    o.envColorGroupTypes = utils.enumTable("EEnvColorGroup")

    o.maxBasePropertiesWidth = nil
    o.maxShadowPropertiesWidth = nil
    o.maxFlickerPropertiesWidth = nil
    o.maxMiscPropertiesWidth = nil
    o.maxRayPathTracingPropertiesWidth = nil
    o.maxGroupPropertiesWidth = nil
    o.maxAreaPropertiesWidth = nil

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

        if self.areaShape == AREA_SHAPE_SPHERE then
            return {
                shape = "sphere",
                color = PREVIEW_COLOR_DEFAULT,
                size = { x = pointAreaBaseSize, y = pointAreaBaseSize, z = pointAreaBaseSize }
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

---@return boolean
local function isPhotoModeActive()
    local ok, active = pcall(function ()
        local blackboardDefs = Game.GetAllBlackboardDefs()
        local blackboard = Game.GetBlackboardSystem():Get(blackboardDefs.PhotoMode)
        return blackboard and blackboard:GetBool(blackboardDefs.PhotoMode.IsActive)
    end)

    return ok and active == true
end

---@param entity any
---@return Vector4?
local function getEntityWorldPosition(entity)
    if not entity or type(entity.GetWorldPosition) ~= "function" then
        return nil
    end

    local ok, position = pcall(function ()
        return entity:GetWorldPosition()
    end)

    return ok and position or nil
end

---@param entity any
---@return boolean
local function isPhotoModePlayerPuppet(entity)
    if not entity or type(entity.GetRecordID) ~= "function" then
        return false
    end

    local okRecord, recordID = pcall(function ()
        return entity:GetRecordID()
    end)

    if not okRecord or not recordID then
        return false
    end

    local okValue, value = pcall(function ()
        return recordID.value
    end)

    if okValue and value == PHOTOMODE_PLAYER_RECORD_ID then
        return true
    end

    local okText, text = pcall(function ()
        return tostring(recordID)
    end)

    return okText and text == PHOTOMODE_PLAYER_RECORD_ID
end

---@param handle any
---@return any
local function resolveEntityHandle(handle)
    if getEntityWorldPosition(handle) then
        return handle
    end

    if handle and type(handle.Get) == "function" then
        local ok, entity = pcall(function ()
            return handle:Get()
        end)

        if ok and getEntityWorldPosition(entity) then
            return entity
        end
    end

    local okValue, entity = pcall(function ()
        return handle and handle.value or nil
    end)

    if okValue and getEntityWorldPosition(entity) then
        return entity
    end

    return nil
end

---@return any
local function getLocalPlayerControlledObject()
    local ok, entity = pcall(function ()
        local playerSystem = Game.GetPlayerSystem()
        return playerSystem and playerSystem:GetLocalPlayerControlledGameObject()
    end)

    return ok and resolveEntityHandle(entity) or nil
end

---@param player any
---@return Vector4?
local function getPhotoModePlayerPosition(player)
    if not player or not isPhotoModeActive() then
        return nil
    end

    local controlledEntity = getLocalPlayerControlledObject()
    local controlledPosition = getEntityWorldPosition(controlledEntity)
    if controlledPosition and isPhotoModePlayerPuppet(controlledEntity) then
        return controlledPosition
    end

    local fallbackPosition = controlledPosition

    if type(player.GetComponents) ~= "function" then
        return fallbackPosition
    end

    local okComponents, components = pcall(function ()
        return player:GetComponents()
    end)

    if not okComponents or not components then
        return fallbackPosition
    end

    for _, component in pairs(components) do
        local okIsPhotoComponent, isPhotoComponent = pcall(function ()
            return component and type(component.IsA) == "function" and component:IsA("PhotoModePlayerEntityComponent")
        end)

        if okIsPhotoComponent and isPhotoComponent then
            for _, fieldName in ipairs({ "fakePuppet", "currentPuppet" }) do
                local okField, handle = pcall(function ()
                    return component[fieldName]
                end)
                local entity = okField and resolveEntityHandle(handle) or nil
                local position = getEntityWorldPosition(entity)

                if position then
                    if isPhotoModePlayerPuppet(entity) then
                        return position
                    end

                    fallbackPosition = fallbackPosition or position
                end
            end
        end
    end

    return fallbackPosition
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
    if showArrows then
        visualizer.setArrowScale(target, self:getScaledArrowSize())
    end
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
            local cameraEuler = gameUtils.toEulerAnglesSafe(cameraTransform:GetRotation())
            local playerEuler = gameUtils.toEulerAnglesSafe(player:GetWorldOrientation())
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
        targetRotation = gameUtils.toEulerAnglesSafe(cameraRotation)
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
    self.scaleGI = math.floor(self.scaleGI)
    self.scaleEnvProbes = math.floor(self.scaleEnvProbes)
    self.colorGroupSaturation = math.floor(self.colorGroupSaturation)
    self.portalAngleCutoff = math.floor(self.portalAngleCutoff)
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
    component.unit = Enum.new("ELightUnit", self.unit)
    component.enableLocalShadows = self.localShadows
    component.enableLocalShadowsForceStaticsOnly = self.localShadowsForceStaticsOnly
    component.temperature = self.temperature
    component.scaleVolFog = self.scaleVolFog
    component.scaleGI = self.scaleGI
    component.scaleEnvProbes = self.scaleEnvProbes
    component.useInParticles = self.useInParticles
    component.useInTransparents = self.useInTransparents
    component.EV = self.ev
    component.shadowAngle = self.shadowAngle
    component.shadowRadius = self.shadowRadius
    component.shadowSoftnessMode = Enum.new("ELightShadowSoftnessMode", self.shadowSoftnessMode)
    component.shadowFadeDistance = self.shadowFadeDistance
    component.shadowFadeRange = self.shadowFadeRange
    component.contactShadows = Enum.new("rendContactShadowReciever", self.contactShadows)
    component.spotCapsule = self.spotCapsule
    component.areaShape = Enum.new("EAreaLightShape", self.areaShape)
    component.areaTwoSided = self.areaTwoSided
    component.areaRectSideA = self.areaRectSideA
    component.areaRectSideB = self.areaRectSideB
    component.softness = self.softness
    component.attenuation = Enum.new("rendLightAttenuation", self.attenuation)
    component.clampAttenuation = self.clampAttenuation
    component.sceneSpecularScale = self.sceneSpecularScale
    component.sceneDiffuse = self.sceneDiffuse
    component.roughnessBias = self.roughnessBias
    component.sourceRadius = self.sourceRadius
    component.directional = self.directional
    component.group = Enum.new("rendLightGroup", self.lightGroup)
    component.envColorGroup = Enum.new("EEnvColorGroup", self.envColorGroup)
    component.colorGroupSaturation = self.colorGroupSaturation
    component.portalAngleCutoff = self.portalAngleCutoff
    component.allowDistantLight = self.allowDistantLight
    component.rayTracedShadowsPlatform = Enum.new("rendRayTracedShadowsPlatform", self.rayTracedShadowsPlatform)
    component.rayTracingLightSourceRadius = self.rayTracingLightSourceRadius
    component.rayTracingContactShadowRange = self.rayTracingContactShadowRange
    component.rayTracingIntensityScale = self.rayTracingIntensityScale
    component.pathTracingLightUsage = Enum.new("rendEPathTracingLightUsage", self.pathTracingLightUsage)
    component.pathTracingOverrideScaleGI = self.pathTracingOverrideScaleGI
    component.rtxdiShadowStartingDistance = self.rtxdiShadowStartingDistance
    if self.iesProfile and self.iesProfile ~= "" then
        component.iesProfile = ResRef.FromString(self.iesProfile)
    end

    -- `lightChannel` is a bitfield, which CET only converts from a number, see `lcHelper.getMask`
    component.lightChannel = lcHelper.getMask(self.lightChannels)

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
    data.unit = self.unit
    data.temperature = self.temperature
    data.scaleVolFog = self.scaleVolFog
    data.scaleGI = self.scaleGI
    data.scaleEnvProbes = self.scaleEnvProbes
    data.useInParticles = self.useInParticles
    data.useInTransparents = self.useInTransparents
    data.ev = self.ev
    data.shadowAngle = self.shadowAngle
    data.shadowRadius = self.shadowRadius
    data.shadowSoftnessMode = self.shadowSoftnessMode
    data.shadowFadeDistance = self.shadowFadeDistance
    data.shadowFadeRange = self.shadowFadeRange
    data.contactShadows = self.contactShadows
    data.spotCapsule = self.spotCapsule
    data.areaShape = self.areaShape
    data.areaTwoSided = self.areaTwoSided
    data.areaRectSideA = self.areaRectSideA
    data.areaRectSideB = self.areaRectSideB
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
    data.lightGroup = self.lightGroup
    data.envColorGroup = self.envColorGroup
    data.colorGroupSaturation = self.colorGroupSaturation
    data.portalAngleCutoff = self.portalAngleCutoff
    data.allowDistantLight = self.allowDistantLight
    data.rayTracedShadowsPlatform = self.rayTracedShadowsPlatform
    data.rayTracingLightSourceRadius = self.rayTracingLightSourceRadius
    data.rayTracingContactShadowRange = self.rayTracingContactShadowRange
    data.rayTracingIntensityScale = self.rayTracingIntensityScale
    data.pathTracingLightUsage = self.pathTracingLightUsage
    data.pathTracingOverrideScaleGI = self.pathTracingOverrideScaleGI
    data.rtxdiShadowStartingDistance = self.rtxdiShadowStartingDistance
    data.iesProfile = self.iesProfile
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
    if not comp then return end

    comp:SetColor(Color.new({ Red = math.floor(self.color[1] * 255), Green = math.floor(self.color[2] * 255), Blue = math.floor(self.color[3] * 255) }))
    comp:SetIntensity(math.floor(self.intensity))
    comp:SetAngles(self.innerAngle, self.outerAngle)
    comp:SetRadius(self.radius)
    comp:SetFlickerParams(self.flickerStrength, self.flickerPeriod, self.flickerOffset)
end

---Called by the light channel editor, for single as well as grouped edits.
---
---The channel mask has no runtime setter, and the render side reads it off the component when that
---registers, so the light is respawned to apply it - the same as every other light property without a
---setter. This is what lets a light react to a light channel area while both are being edited.
function light:onLightChannelsChanged()
    self:updateFull(true)
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
        local typeLabel, hiddenTypeText = style.resolveActionLabel(
            self:getLightTypeIcon(typeIndex),
            self:getLightTypeLabel(typeIndex),
            "lightTypeTab" .. tostring(typeIndex),
            nil,
            true
        )
        local clicked = style.switchTabButton(
            typeLabel,
            selected,
            lightTypeTabWidth,
            0
        )
        style.tooltipActionLabel(hiddenTypeText)

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

    ImGui.Dummy(0, 2 * style.viewSize)

    self.colorHexText, self.colorHexEditing, changed, finished = style.drawLightColorSwatch(
        self.object,
        colorPopupId,
        "##lightColorHexInput",
        self.color,
        self.colorHexText,
        self.colorHexEditing
    )
    if changed then
        self.colorHexText = (self.colorHexText or ""):upper()
        local parsedColor = colorUtil.parseHexRGB(self.colorHexText)
        if parsedColor then
            self.color = parsedColor
            applyRuntimeParameterChange(self, true, false)
        end
    end
    if finished then
        local parsedColor = colorUtil.parseHexRGB(self.colorHexText)
        if parsedColor then
            self.color = parsedColor
            self.colorHexText = colorUtil.formatHexRGB(self.color)
            applyRuntimeParameterChange(self, true, false)
        else
            self.colorHexText = colorUtil.formatHexRGB(self.color)
        end
    end

    ImGui.SameLine()
    ImGui.Dummy(2 * style.viewSize, 0)

    ImGui.SameLine()
    ImGui.BeginGroup()

    ImGui.Dummy(0, 8 * style.viewSize)

    self:drawPreviewCheckbox("Visualize")

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
    style.styledText(IconGlyphs.RadiusOutline, style.lightRadiusIconColor)
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
        style.drawIconLabelRow(IconGlyphs.Cone, "Inner Angle", { iconColor = style.lightInnerAngleColor, fieldX = self.maxBasePropertiesWidth })
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

        style.drawIconLabelRow(IconGlyphs.Cone, "Outer Angle", { iconColor = style.lightOuterAngleColor, fieldX = self.maxBasePropertiesWidth })
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

    style.mutedText("IES Profile")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxBasePropertiesWidth)
    local iesProfileList = iesProfiles.getSelectable()
    local iesProfilePrevious = self.iesProfile
    local iesProfileChanged
    self.iesProfile, self.iesProfileSearch, iesProfileChanged = style.trackedSearchDropdown(
        "##iesProfile",
        "Search IES profile...",
        self.iesProfile,
        self.iesProfileSearch,
        iesProfileList,
        {
            element = self.object,
            width = 200,
            matchContentWidth = true,
            optionDisplayFn = function(optionText)
                return iesProfiles.displayName(optionText)
            end,
            tooltip = "IES light projection profile applied to this light"
        }
    )
    if iesProfileChanged and self.iesProfile ~= iesProfilePrevious then
        self:updateFull(true)
    end

    ImGui.SameLine()
    ImGui.BeginDisabled(#iesProfiles.get() == 0)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.SkipNext .. "##cycleIESProfile") then
        local nextProfile, cycled = iesProfiles.getNext(self.iesProfile)
        if cycled then
            if self.object then
                history.addAction(history.getElementChange(self.object))
            end
            self.iesProfile = nextProfile
            self:updateFull(true)
        end
    end
    style.pushButtonNoBG(false)
    ImGui.EndDisabled()
    style.tooltip("Select the next IES profile. Wraps around, including 'None'.")

    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload .. "##reloadIESProfiles") then
        iesProfiles.reload()
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reload the IES profile list from disk.")

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
            local aimAtPlayerLabel, aimAtPlayerHiddenText = style.resolveActionLabel(IconGlyphs.TargetAccount, "Aim at Player", "lightAimAtPlayer", nil, true)
            if ImGui.Button(aimAtPlayerLabel) then
                local player = GetPlayer()
                local targetPosition = getPhotoModePlayerPosition(player) or getEntityWorldPosition(player)
                if targetPosition then
                    targeting.aimElementAtWorldPosition(self.object, targetPosition)
                end
            end
            ImGui.EndDisabled()
            if targetingDisabledByCameraFollow then
                local tooltipText = "Disable Follow Camera to target the player manually."
                if aimAtPlayerHiddenText then
                    style.tooltipActionLabel(aimAtPlayerHiddenText, aimAtPlayerHiddenText .. "\n" .. tooltipText)
                else
                    style.tooltip(tooltipText)
                end
            elseif rotationTargetingDisabled and self.object and self.object.rotationLocked then
                local tooltipText = "Unlock rotation to target the player."
                if aimAtPlayerHiddenText then
                    style.tooltipActionLabel(aimAtPlayerHiddenText, aimAtPlayerHiddenText .. "\n" .. tooltipText)
                else
                    style.tooltip(tooltipText)
                end
            else
                local tooltipText = "Rotate this light to point at the player's current world position."
                if aimAtPlayerHiddenText then
                    style.tooltipActionLabel(aimAtPlayerHiddenText, aimAtPlayerHiddenText .. "\n" .. tooltipText)
                else
                    style.tooltip(tooltipText)
                end
            end

            ImGui.SameLine()

            ImGui.BeginDisabled(hierarchyPickDisabled)
            local hierarchyButtonText = hierarchyPickActive and "Cancel Target Pick" or "Aim at Element"
            local hierarchyLabel, hierarchyHiddenText = style.resolveActionLabel(IconGlyphs.Target, hierarchyButtonText, "lightHierarchyTargetPick", nil, true)
            local hierarchyButtonClicked = false
            if hierarchyPickActive then
                hierarchyButtonClicked = style.successButton(hierarchyLabel)
            else
                hierarchyButtonClicked = ImGui.Button(hierarchyLabel)
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
                local tooltipText = "Disable Follow Camera to use hierarchy targeting."
                if hierarchyHiddenText then
                    style.tooltipActionLabel(hierarchyHiddenText, hierarchyHiddenText .. "\n" .. tooltipText)
                else
                    style.tooltip(tooltipText)
                end
            elseif hierarchyPickDisabled and self.object and self.object.rotationLocked then
                local tooltipText = "Unlock rotation to use hierarchy targeting."
                if hierarchyHiddenText then
                    style.tooltipActionLabel(hierarchyHiddenText, hierarchyHiddenText .. "\n" .. tooltipText)
                else
                    style.tooltip(tooltipText)
                end
            elseif hierarchyPickActive then
                local tooltipText = "Click an element in the hierarchy or click anywhere in the 3D world to aim this light.\nPress Esc or click this button again to cancel."
                if hierarchyHiddenText then
                    style.tooltipActionLabel(hierarchyHiddenText, hierarchyHiddenText .. "\n" .. tooltipText)
                else
                    style.tooltip(tooltipText)
                end
            else
                local tooltipText = "Pick a hierarchy element or click in the 3D world to rotate this light toward that target."
                if hierarchyHiddenText then
                    style.tooltipActionLabel(hierarchyHiddenText, hierarchyHiddenText .. "\n" .. tooltipText)
                else
                    style.tooltip(tooltipText)
                end
            end
        style.sectionHeaderEnd(false)
    end

    style.sectionHeaderStart("Be the light")
        local cameraFollowToggleDisabled = rotationTargetingDisabled and not self.cameraFollowEnabled
        ImGui.BeginDisabled(cameraFollowToggleDisabled)
        local followCameraLabel, followCameraHiddenText = style.resolveActionLabel(IconGlyphs.CameraLockOutline, "Follow Camera", "lightCameraFollow", nil, true)
        local newCameraFollowEnabled, cameraFollowChanged = style.toggleButton(
            followCameraLabel,
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
            local tooltipText = "Unlock rotation to enable camera follow."
            if followCameraHiddenText then
                style.tooltipActionLabel(followCameraHiddenText, followCameraHiddenText .. "\n" .. tooltipText)
            else
                style.tooltip(tooltipText)
            end
        elseif self.cameraFollowEnabled then
            local tooltipText = "Light follows player camera position and direction.\nDisable to keep the current transform."
            if followCameraHiddenText then
                style.tooltipActionLabel(followCameraHiddenText, followCameraHiddenText .. "\n" .. tooltipText)
            else
                style.tooltip(tooltipText)
            end
        else
            local tooltipText = "Attach this light to the player camera and align direction to camera view."
            if followCameraHiddenText then
                style.tooltipActionLabel(followCameraHiddenText, followCameraHiddenText .. "\n" .. tooltipText)
            else
                style.tooltip(tooltipText)
            end
        end

        ImGui.SameLine()

        local teleportDisabledByEditor = self.object and self.object.sUI and self.object.sUI.spawner.editor.active == true or false
        local teleportDisabled = teleportDisabledByEditor or self.cameraFollowEnabled == true
        if style.warnButton(IconGlyphs.RunFast .. "##lightTeleportCameraAligned", {
            tooltip = "Teleport player so camera position and look direction match this light.",
            disabled = teleportDisabled,
            disabledTooltip = teleportDisabledByEditor and "Teleportation disabled while in 3D-Editor mode" or "Disable Follow Camera to teleport to this light"
        }) then
            self:teleportPlayerToLightCameraAligned()
        end
    style.sectionHeaderEnd(false)
    
    ImGui.Dummy(0, 4 * style.viewSize)

    -- Other Settings
    if ImGui.TreeNodeEx("Shadow Settings") then
        if not self.maxShadowPropertiesWidth then
            self.maxShadowPropertiesWidth = utils.getTextMaxWidth({ "Contact Shadows", "Local Shadows", "Local Shadows (Statics Only)", "Shadow Angle", "Shadow Radius", "Shadow Softness Mode", "Shadow Fade Distance", "Shadow Fade Range" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
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
        style.tooltip("-1 lets the engine derive the angle from the light itself")
        self:updateFull(finished)

        style.mutedText("Shadow Radius")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.shadowRadius, _, finished = style.trackedDragFloat(self.object, "##shadowRadius", self.shadowRadius, 0.01, -1, 9999, "%.2f", 75)
        style.tooltip("Radius of the shadow casting source\n-1 lets the engine derive it from the light itself")
        self:updateFull(finished)

        style.mutedText("Shadow Softness Mode")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.shadowSoftnessMode, changed = style.trackedCombo(self.object, "##shadowSoftnessMode", self.shadowSoftnessMode, self.shadowSoftnessModes, 130)
        self:updateFull(changed)

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
        local channelsChanged
        self.lightChannels, channelsChanged = style.drawLightChannelsSelector(self.object, self.lightChannels)

        if channelsChanged then
            self:onLightChannelsChanged()
        end

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Group Settings") then
        if not self.maxGroupPropertiesWidth then
            self.maxGroupPropertiesWidth = utils.getTextMaxWidth({ "Light Group", "Env. Color Group", "Color Group Saturation" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        end

        style.mutedText("Light Group")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxGroupPropertiesWidth)
        self.lightGroup, changed = style.trackedCombo(self.object, "##lightGroup", self.lightGroup, self.lightGroupTypes, 130, {
            tooltip = "Render group this light belongs to, used to toggle sets of lights together"
        })
        self:updateFull(changed)

        style.mutedText("Env. Color Group")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxGroupPropertiesWidth)
        self.envColorGroup, changed = style.trackedCombo(self.object, "##envColorGroup", self.envColorGroup, self.envColorGroupTypes, 130, {
            tooltip = "Environment color group, letting the weather/environment system tint this light"
        })
        self:updateFull(changed)

        style.mutedText("Color Group Saturation")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxGroupPropertiesWidth)
        self.colorGroupSaturation, _, finished = style.trackedSliderInt(self.object, "##colorGroupSaturation", self.colorGroupSaturation, 0, 255, 110)
        style.tooltip("How strongly the environment color group tints this light")
        self:updateFull(finished)

        ImGui.TreePop()
    end

    -- Emitter geometry only the Area light type makes use of, the main panel keeps the two
    -- properties that get adjusted often (Capsule Length and Spot Capsule).
    if self.lightType == LIGHT_TYPE_AREA and ImGui.TreeNodeEx("Area Settings") then
        if not self.maxAreaPropertiesWidth then
            self.maxAreaPropertiesWidth = utils.getTextMaxWidth({ "Area Shape", "Two Sided", "Rect Side A", "Rect Side B" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        end

        style.mutedText("Area Shape")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxAreaPropertiesWidth)
        self.areaShape, changed = style.trackedCombo(self.object, "##areaShape", self.areaShape, self.areaShapeTypes, 130, {
            tooltip = "Shape of the emitting surface\nCapsule uses Capsule Length and Source Radius\nSphere uses only Source Radius"
        })
        self:updateFull(changed)

        style.mutedText("Two Sided")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxAreaPropertiesWidth)
        self.areaTwoSided, changed = style.trackedCheckbox(self.object, "##areaTwoSided", self.areaTwoSided)
        style.tooltip("Emit light from both sides of the area light instead of the facing side only")
        self:updateFull(changed)

        style.mutedText("Rect Side A")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxAreaPropertiesWidth)
        self.areaRectSideA, _, finished = style.trackedDragFloat(self.object, "##areaRectSideA", self.areaRectSideA, 0.05, 0, 9999, "%.2fm", 75)
        style.tooltip("Width of the rectangular emitter")
        self:updateFull(finished)

        style.mutedText("Rect Side B")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxAreaPropertiesWidth)
        self.areaRectSideB, _, finished = style.trackedDragFloat(self.object, "##areaRectSideB", self.areaRectSideB, 0.05, 0, 9999, "%.2fm", 75)
        style.tooltip("Height of the rectangular emitter")
        self:updateFull(finished)

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Misc. Settings") then
        if not self.maxMiscPropertiesWidth then
            self.maxMiscPropertiesWidth = utils.getTextMaxWidth({ "Directional", "Use in particles", "Use in transparents", "Scale Vol. Fog", "Scale GI", "Scale Env. Probes", "Auto Hide Distance", "EV", "Intensity Unit", "Temperature", "Attenuation Mode", "Clamp Attenuation", "Specular Scale", "Scene Diffuse", "Roughness Bias", "Source Radius", "Portal Angle Cutoff", "Allow Distant Light" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        end

        style.mutedText("Intensity Unit")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.unit, changed = style.trackedCombo(self.object, "##unit", self.unit, self.lightUnitTypes, 110, {
            tooltip = "Unit the intensity value is interpreted in"
        })
        self:updateFull(changed)

        style.mutedText("Temperature")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.temperature, _, finished = style.trackedDragFloat(self.object, "##temperature", self.temperature, 10, -1, 20000, "%.0fK", 110)
        style.tooltip("Color temperature in Kelvin, tinting the light color\n-1 disables it and uses the light color as is")
        self:updateFull(finished)

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

        style.mutedText("Scale GI")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.scaleGI, _, finished = style.trackedSliderInt(self.object, "##scaleGI", self.scaleGI, 0, 255, 110)
        style.tooltip("Scales how much this light contributes to global illumination")
        self:updateFull(finished)

        style.mutedText("Scale Env. Probes")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.scaleEnvProbes, _, finished = style.trackedSliderInt(self.object, "##scaleEnvProbes", self.scaleEnvProbes, 0, 255, 110)
        style.tooltip("Scales how much this light contributes to environment probes")
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

        style.mutedText("Portal Angle Cutoff")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.portalAngleCutoff, _, finished = style.trackedSliderInt(self.object, "##portalAngleCutoff", self.portalAngleCutoff, 0, 255, 110)
        style.tooltip("Angle at which the light stops shining through portals")
        self:updateFull(finished)

        style.mutedText("Allow Distant Light")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxMiscPropertiesWidth)
        self.allowDistantLight, changed = style.trackedCheckbox(self.object, "##allowDistantLight", self.allowDistantLight)
        style.tooltip("Let this light be picked up by the distant lights system\nwhich keeps it visible past the auto hide distance")
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
    return self:addNodeProperty(visualized.getProperties(self))
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
        unit = self.lightUnitTypes[self.unit + 1],
        temperature = self.temperature,
        allowDistantLight = self.allowDistantLight and 1 or 0,
        lightChannel = utils.buildBitfieldString(self.lightChannels, style.lightChannelEnum),
        group = self.lightGroupTypes[self.lightGroup + 1],
        envColorGroup = self.envColorGroupTypes[self.envColorGroup + 1],
        colorGroupSaturation = self.colorGroupSaturation,
        portalAngleCutoff = self.portalAngleCutoff,
        scaleVolFog = self.scaleVolFog,
        scaleGI = self.scaleGI,
        scaleEnvProbes = self.scaleEnvProbes,
        useInParticles = self.useInParticles and 1 or 0,
        useInTransparents = self.useInTransparents and 1 or 0,
        EV = self.ev,
        shadowAngle = self.shadowAngle,
        shadowRadius = self.shadowRadius,
        shadowSoftnessMode = self.shadowSoftnessModes[self.shadowSoftnessMode + 1],
        shadowFadeDistance = self.shadowFadeDistance,
        shadowFadeRange = self.shadowFadeRange,
        contactShadows = self.contactShadowsTypes[self.contactShadows + 1],
        spotCapsule = self.spotCapsule and 1 or 0,
        areaShape = self.areaShapeTypes[self.areaShape + 1],
        areaTwoSided = self.areaTwoSided and 1 or 0,
        areaRectSideA = self.areaRectSideA,
        areaRectSideB = self.areaRectSideB,
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

    if self.iesProfile and self.iesProfile ~= "" then
        data.data.iesProfile = iesProfiles.exportRef(self.iesProfile)
    end

    return data
end

return light
