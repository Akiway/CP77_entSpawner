local visualized = require("modules/classes/spawn/visualized")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")
local history = require("modules/utils/history")
local utils = require("modules/utils/utils")
local field = require("modules/utils/field")
local lcHelper = require("modules/utils/lightChannelHelper")

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
local PREVIEW_PRISM_MESH = "base\\spawner\\triangular_prism.w2mesh"
local PREVIEW_PRISM_THICKNESS_MULTIPLIER = 2

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
---@field private lightTypeNames table
---@field private lightTypeOptions table
---@field private lightTypeIcons table
---@field private lightTypeLabels table
---@field private temperature number
---@field private scaleVolFog number
---@field private useInParticles boolean
---@field private useInTransparents boolean
---@field private ev number
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
    o.lightTypeNames = utils.enumTable("ELightType")
    o.lightTypeOptions = {}
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
    o.maxLightChannelsWidth = nil
    o.maxRayPathTracingPropertiesWidth = nil

    o.previewColor = "yellow"
    o.previewed = true
    o.radiusPreviewed = false

    setmetatable(o, { __index = self })
    o:rebuildLightTypeOptions()
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

function light:rebuildLightTypeOptions()
    self.lightTypeOptions = {}
    local maxEnumIndex = math.max(#(self.lightTypeNames or {}) - 1, LIGHT_TYPE_AREA)
    for idx = 0, maxEnumIndex do
        self.lightTypeOptions[idx + 1] = string.format("%s %s", self:getLightTypeIcon(idx), self:getLightTypeLabel(idx))
    end
end

function light:updateLightTypeIcon()
    self.icon = self:getLightTypeIcon(self.lightType)
    if self.object then
        self.object.icon = self.icon
    end
end

---@return table
function light:getPreviewSpec()
    local pointAreaBaseSize = self:getIntensityPreviewBaseSize(PREVIEW_POINT_AREA_BASE_SCALE_MULTIPLIER)

    if self.lightType == LIGHT_TYPE_AREA then
        local length = math.max(self.capsuleLength, 0)
        if self.spotCapsule then
            local prismThickness = pointAreaBaseSize * PREVIEW_PRISM_THICKNESS_MULTIPLIER
            return {
                shape = "mesh",
                color = PREVIEW_COLOR_DEFAULT,
                mesh = PREVIEW_PRISM_MESH,
                meshAppearance = PREVIEW_COLOR_DEFAULT,
                size = { x = prismThickness, y = length, z = prismThickness },
                rotation = { kind = "quat", value = EulerAngles.new(-90, 0, 90):ToQuat() }
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
        local outerSize = self:getSpotConeVisualizerSize(self.outerAngle, self:getIntensityPreviewBaseSize(1), PREVIEW_SPOT_CONE_RADIUS_FLOOR_RATIO)
        local innerSize = self:getSpotConeVisualizerSize(
            self.innerAngle,
            self:getIntensityPreviewBaseSize(PREVIEW_SPOT_INNER_SCALE_MULTIPLIER),
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
function light:hasRadiusProperty()
    return self.lightType == LIGHT_TYPE_SPOT or self.lightType == LIGHT_TYPE_AREA
end

---@return { x: number, y: number, z: number }
function light:getRadiusPreviewVisualizerSize()
    local sphereRadius = math.max(self.radius, 0)
    return { x = sphereRadius, y = sphereRadius, z = sphereRadius }
end

---@return boolean
function light:shouldShowRadiusPreview()
    return self.previewed and self.radiusPreviewed and self:hasRadiusProperty()
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

---@param multiplier number?
---@return number
function light:getIntensityPreviewBaseSize(multiplier)
    local range = math.max(PREVIEW_INTENSITY_MAX - PREVIEW_INTENSITY_MIN, 1)
    local clampedIntensity = math.max(math.min(self.intensity, PREVIEW_INTENSITY_MAX), PREVIEW_INTENSITY_MIN)
    local normalizedIntensity = (clampedIntensity - PREVIEW_INTENSITY_MIN) / range
    local baseSize = PREVIEW_BASE_SCALE_MIN + normalizedIntensity * (PREVIEW_BASE_SCALE_MAX - PREVIEW_BASE_SCALE_MIN)

    return baseSize * (multiplier or 1)
end

---@param angle number
---@param size number
---@param radiusFloorRatio number
---@return { x: number, y: number, z: number }
function light:getSpotConeVisualizerSize(angle, size, radiusFloorRatio)
    local clampedAngle = math.max(math.min(angle, 170), 0.1)
    local halfAngleRadians = math.rad(clampedAngle * 0.5)
    -- cone.mesh is centered and spans roughly 1.5 units across its main axis.
    local coneRadiusScale = size * 1.5 * math.tan(halfAngleRadians)
    coneRadiusScale = math.max(math.min(coneRadiusScale, size * 8), size * radiusFloorRatio)

    return { x = coneRadiusScale, y = coneRadiusScale, z = size }
end

---@return { x: number, y: number, z: number }
function light:getOuterSpotConeVisualizerSize()
    local spec = self:getPreviewSpec()
    if spec.innerCone then
        return spec.size
    end

    return self:getSpotConeVisualizerSize(self.outerAngle, self:getIntensityPreviewBaseSize(1), PREVIEW_SPOT_CONE_RADIUS_FLOOR_RATIO)
end

---@return { x: number, y: number, z: number }
function light:getInnerSpotConeVisualizerSize()
    local spec = self:getPreviewSpec()
    if spec.innerCone then
        return spec.innerCone.size
    end

    return self:getSpotConeVisualizerSize(
        self.innerAngle,
        self:getIntensityPreviewBaseSize(PREVIEW_SPOT_INNER_SCALE_MULTIPLIER),
        PREVIEW_SPOT_INNER_RADIUS_FLOOR_RATIO
    )
end

---@param entity entEntity?
function light:applyPreviewAppearance(entity)
    local target = entity or self:getEntity()
    if not target then
        return
    end

    local spec = self:getPreviewSpec()
    if spec.shape ~= "mesh" or not spec.meshAppearance then
        return
    end

    local mesh = target:FindComponentByName("mesh")
    if not mesh then
        return
    end

    local currentAppearance = mesh.meshAppearance and mesh.meshAppearance.value or nil
    if currentAppearance ~= spec.meshAppearance then
        mesh.meshAppearance = CName.new(spec.meshAppearance)
        mesh:LoadAppearance()
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
        local mesh = target:FindComponentByName("mesh")
        if mesh then
            mesh:SetLocalOrientation(rotation.value)
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

function light:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    self.roughnessBias = math.min(math.max(math.floor(self.roughnessBias), -127), 127) -- Fix for incorrect clamping before
    self.scaleVolFog = math.floor(self.scaleVolFog)
    self.sceneSpecularScale = math.floor(self.sceneSpecularScale)
    self:rebuildLightTypeOptions()
    self:updateLightTypeIcon()
    self:updatePreviewShape()
end

---@param entity entEntity
function light:onAfterPreviewAssemble(entity)
    local spec = self:getPreviewSpec()

    if self:hasRadiusProperty() then
        visualizer.addSphere(entity, self:getRadiusPreviewVisualizerSize(), "ghostwhite", "radius_sphere")
    end

    if spec.innerCone then
        visualizer.addCone(entity, spec.innerCone.size, spec.innerCone.color, "cone_inner")
        -- Ensure the newly created inner cone follows the current global preview visibility.
        visualizer.toggleAll(entity, self.previewed)
    end

    self:applyPreviewAppearance(entity)
    self:applyPreviewShapeRotation(entity)
    self:updateRadiusPreviewVisibility(entity)
end

---@param entity entEntity
function light:onAfterPreviewScale(entity)
    local spec = self:getPreviewSpec()

    if spec.innerCone then
        visualizer.updateScale(entity, spec.innerCone.size, "cone_inner")
    end

    self:applyPreviewAppearance(entity)
    self:applyPreviewShapeRotation(entity)
    self:updateRadiusPreviewVisibility(entity)
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
    component.temperature = self.temperature
    component.scaleVolFog = self.scaleVolFog
    component.useInParticles = self.useInParticles
    component.useInTransparents = self.useInTransparents
    component.EV = self.ev
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
    visualized.setPreview(self, state)
    self:updateRadiusPreviewVisibility()
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

function light:draw()
    visualized.draw(self)

    if not self.maxBasePropertiesWidth then
        self.maxBasePropertiesWidth = utils.getTextMaxWidth({ "Visualize", "Light Type", "Intensity", "Color", "Angles", "Radius", "Spot Capsule", "Softness" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    self:drawPreviewCheckbox("Visualize", self.maxBasePropertiesWidth)

    style.mutedText("Light Type")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxBasePropertiesWidth)
    self.lightType, changed = style.trackedCombo(self.object, "##type", self.lightType, self.lightTypeOptions)
    if changed then
        self:updateLightTypeIcon()
    end
    self:updateFull(changed)

    style.mutedText("Color")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxBasePropertiesWidth)
    local colorFlags = ImGuiColorEditFlags and ImGuiColorEditFlags.NoInputs or nil
    self.color, changed = style.trackedColor(self.object, "##color", self.color, 60, colorFlags)
    if changed then
        self:updateParameters()
    end

    style.mutedText("Intensity")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxBasePropertiesWidth)
    self.intensity, changed, _ = field.advancedTrackedFloat(self.object, "##intensity", self.intensity, {
        step = 1,
        min = 0,
        max = 9999,
        format = "%.1f",
        width = 50
    })
    if changed then
        self:updateScale()
        self:updateParameters()
    end

    if self.lightType == LIGHT_TYPE_AREA then
        style.mutedText("Spot Capsule")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxBasePropertiesWidth)
        self.spotCapsule, changed = style.trackedCheckbox(self.object, "##spotCapsule", self.spotCapsule)
        self:updateFull(changed)
    end

    if self.lightType == LIGHT_TYPE_SPOT or (self.lightType == LIGHT_TYPE_AREA and self.spotCapsule) then
        style.mutedText("Angles")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxBasePropertiesWidth)
        local innerIconY = ImGui.GetCursorPosY()
        ImGui.SetCursorPosY(innerIconY + 4 * style.viewSize)
        style.styledText(IconGlyphs.Cone, INNER_ANGLE_BORDER_COLOR)
        ImGui.SameLine()
        ImGui.SetCursorPosY(innerIconY)
        self.innerAngle, changed, finished = style.trackedDragFloat(self.object, "##inner", self.innerAngle, 0.1, 0, 9999, "%.1f Inner", 105)
        style.tooltip("Inner angle of the light, visualized by the yellow cone\nThe area between inner and outer angles is where the light intensity falls off")
        if changed then
            if self.lightType == LIGHT_TYPE_SPOT then
                self:updateScale()
            end
            self:updateParameters()
        end
        if self.lightType == LIGHT_TYPE_AREA then
            self:updateFull(finished)
        end

        ImGui.SameLine()
        ImGui.Dummy(0, 8 * style.viewSize)
        ImGui.SameLine()
        local outerIconY = ImGui.GetCursorPosY()
        ImGui.SetCursorPosY(outerIconY + 1 * style.viewSize)
        style.styledText(IconGlyphs.Cone, OUTER_ANGLE_BORDER_COLOR)
        ImGui.SameLine()
        ImGui.SetCursorPosY(outerIconY)
        self.outerAngle, changed, finished = style.trackedDragFloat(self.object, "##outer", self.outerAngle, 0.1, 0, 9999, "%.1f Outer", 105)
        style.tooltip("Outer angle of the light, visualized by the blue cone\nThe area between inner and outer angles is where the light intensity falls off")
        if changed then
            if self.lightType == LIGHT_TYPE_SPOT then
                self:updateScale()
            end
            self:updateParameters()
        end
        if self.lightType == LIGHT_TYPE_AREA then
            self:updateFull(finished)
        end

        style.mutedText("Softness")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxBasePropertiesWidth)
        self.softness, _, finished = style.trackedDragFloat(self.object, "##softness", self.softness, 0.05, 0, 9999, "%.2f", 90)
        style.tooltip("Softens the transition near the cone edge")
        self:updateFull(finished)
    end
    if self.lightType == LIGHT_TYPE_SPOT or self.lightType == LIGHT_TYPE_AREA then
        style.mutedText("Radius")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxBasePropertiesWidth)
        local radiusIconY = ImGui.GetCursorPosY()
        ImGui.SetCursorPosY(radiusIconY + 4 * style.viewSize)
        style.styledText(IconGlyphs.RadiusOutline, RADIUS_ICON_COLOR)
        ImGui.SameLine()
        ImGui.SetCursorPosY(radiusIconY)
        self.radius, changed = style.trackedDragFloat(self.object, "##radius", self.radius, 0.25, 0, 9999, "%.1f", 90)
        if changed then
            self:updateParameters()
            self:updateRadiusPreviewVisibility()
        end
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
    end
    if self.lightType == LIGHT_TYPE_AREA then
        style.mutedText("Capsule Length")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxBasePropertiesWidth)
        self.capsuleLength, changed, finished = style.trackedDragFloat(self.object, "##capsuleLength", self.capsuleLength, 0.05, 0, 9999, "%.2f", 90)
        self:updateFull(finished)
        if changed then
            self:updateScale()
        end
    end

    if ImGui.TreeNodeEx("Shadow Settings") then
        if not self.maxShadowPropertiesWidth then
            self.maxShadowPropertiesWidth = utils.getTextMaxWidth({ "Contact Shadows", "Local Shadows", "Shadow Fade Distance", "Shadow Fade Range" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
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
        end

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
        if changed then
            self:updateParameters()
        end

        style.mutedText("Flicker Strength")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxFlickerPropertiesWidth)
        self.flickerStrength, changed = style.trackedDragFloat(self.object, "##flickerStrength", self.flickerStrength, 0.01, 0, 9999, "%.2f", 85)
        if changed then
            self:updateParameters()
        end

        style.mutedText("Flicker Offset")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxFlickerPropertiesWidth)
        self.flickerOffset, changed = style.trackedDragFloat(self.object, "##flickerOffset", self.flickerOffset, 0.01, 0, 9999, "%.2f", 85)
        if changed then
            self:updateParameters()
        end

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Light Channels") then
        self.lightChannels = style.drawLightChannelsSelector(self.object, self.lightChannels)
        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Misc. Settings") then
        if not self.maxShadowPropertiesWidth then
            self.maxShadowPropertiesWidth = utils.getTextMaxWidth({ "Directional", "Use in particles", "Use in transparents", "Scale Vol. Fog", "Auto Hide Distance", "EV", "Attenuation Mode", "Clamp Attenuation", "Specular Scale", "Scene Diffuse", "Roughness Bias", "Source Radius" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        end

        style.mutedText("Use in particles")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.useInParticles, changed = style.trackedCheckbox(self.object, "##useInParticles", self.useInParticles)
        self:updateFull(changed)

        style.mutedText("Use in transparents")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.useInTransparents, changed = style.trackedCheckbox(self.object, "##useInTransparents", self.useInTransparents)
        self:updateFull(changed)

        style.mutedText("Scale Vol. Fog")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.scaleVolFog, _, finished = style.trackedSliderInt(self.object, "##scaleVolFog", self.scaleVolFog, 0, 255, 110)
        self:updateFull(finished)

        style.mutedText("Scene Diffuse")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.sceneDiffuse, changed = style.trackedCheckbox(self.object, "##sceneDiffuse", self.sceneDiffuse)
        self:updateFull(changed)

        style.mutedText("Specular Scale")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.sceneSpecularScale, _, finished = style.trackedSliderInt(self.object, "##sceneSpecularScale", self.sceneSpecularScale, 0, 255, 110)
        self:updateFull(finished)

        style.mutedText("Roughness Bias")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.roughnessBias, _, finished = style.trackedSliderInt(self.object, "##roughnessBias", self.roughnessBias, -127, 127, 110)
        self:updateFull(finished)

        style.mutedText("Source Radius")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.sourceRadius, _, finished = style.trackedDragFloat(self.object, "##sourceRadius", self.sourceRadius, 0.0025, 0, 9999, "%.3f", 110)
        self:updateFull(finished)

        style.mutedText("Auto Hide Distance")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.autoHideDistance, _, finished = style.trackedDragFloat(self.object, "##autoHideDistance", self.autoHideDistance, 0.05, 0, 9999, "%.1f", 110)
        self:updateFull(finished)
        ImGui.SameLine()
        local distance = utils.distanceVector(self.position, GetPlayer():GetWorldPosition())
        style.styledText(IconGlyphs.AxisArrowInfo, distance > self.autoHideDistance and 0xFF0000FF or 0xFF00FF00)
        style.tooltip(string.format("Distance to node position: %.2f", distance))

        style.mutedText("EV")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.ev, _, finished = style.trackedDragFloat(self.object, "##ev", self.ev, 0.1, 0, 9999, "%.1f", 110)
        self:updateFull(finished)

        style.mutedText("Attenuation Mode")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.attenuation, changed = style.trackedCombo(self.object, "##attenuation", self.attenuation, self.attenuationTypes, 110)
        self:updateFull(changed)

        style.mutedText("Clamp Attenuation")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.clampAttenuation, changed = style.trackedCheckbox(self.object, "##clampAttenuation", self.clampAttenuation)
        self:updateFull(changed)

        style.mutedText("Directional")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
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

    ImGui.PopItemWidth()
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
