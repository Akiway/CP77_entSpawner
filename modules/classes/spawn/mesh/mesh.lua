local spawnable = require("modules/classes/spawn/spawnable")
local builder = require("modules/utils/entityBuilder")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local cache = require("modules/utils/cache")
local visualizer = require("modules/utils/visualizer")
local history = require("modules/utils/history")
local intersection = require("modules/utils/editor/intersection")
local Cron = require("modules/utils/Cron")
local preview = require("modules/utils/previewUtils")
local settings = require("modules/utils/settings")
local appearanceHelper = require("modules/utils/appearanceHelper")

---Static mesh spawnable implementation.
---Handles resource-driven mesh appearance loading, editor UI, preview rendering,
---mesh-type conversion, collider generation helpers, and export serialization.

local colliderShapeTypes = { "Box", "Capsule", "Sphere", "ConvexMesh", "BV4TriangleMesh" }
local clothListPath = "data/spawnables/mesh/cloth/paths.txt"
local bendedListPath = "data/spawnables/mesh/bended/paths_bended.txt"
local dynamicListPath = "data/spawnables/mesh/physics/paths_filtered_mesh.txt"

-- Supported module targets for single-item and grouped conversion.
local conversionTargets = {
    { modulePath = "mesh/mesh", icon = IconGlyphs.CubeOutline, text = "Static Mesh", plural = "static meshes" },
    { modulePath = "mesh/bendedMesh", icon = IconGlyphs.SineWave, text = "Bended Mesh", plural = "bended meshes" },
    { modulePath = "mesh/rotatingMesh", icon = IconGlyphs.FormatRotate90, text = "Rotating Mesh", plural = "rotating meshes" },
    { modulePath = "mesh/clothMesh", icon = IconGlyphs.ReceiptOutline, text = "Cloth Mesh", plural = "cloth meshes" },
    { modulePath = "physics/dynamicMesh", icon = IconGlyphs.CubeSend, text = "Dynamic Mesh", plural = "dynamic meshes" },
    { modulePath = "mesh/proxyMesh", icon = IconGlyphs.BoxShadow, text = "Proxy Mesh", plural = "proxy meshes" }
}

---@param target table
---@param stableId string?
---@return string
local function getConversionTargetLabel(target, stableId)
    local label = style.resolveActionLabelNoIconOnly(target.icon, target.text, stableId)
    return label
end

-- Explicit conversion pairs that are known to drop subtype-specific properties.
local lossyConversionPairs = {
    ["mesh/bendedMesh>mesh/mesh"] = true,
    ["mesh/bendedMesh>mesh/rotatingMesh"] = true,
    ["mesh/bendedMesh>mesh/clothMesh"] = true,
    ["mesh/bendedMesh>physics/dynamicMesh"] = true,
    ["mesh/bendedMesh>mesh/proxyMesh"] = true,
    ["mesh/rotatingMesh>mesh/bendedMesh"] = true,
    ["mesh/rotatingMesh>mesh/mesh"] = true,
    ["mesh/rotatingMesh>mesh/clothMesh"] = true,
    ["mesh/rotatingMesh>physics/dynamicMesh"] = true,
    ["mesh/rotatingMesh>mesh/proxyMesh"] = true,
    ["mesh/clothMesh>mesh/bendedMesh"] = true,
    ["mesh/clothMesh>mesh/mesh"] = true,
    ["mesh/clothMesh>mesh/rotatingMesh"] = true,
    ["mesh/clothMesh>physics/dynamicMesh"] = true,
    ["mesh/clothMesh>mesh/proxyMesh"] = true,
    ["physics/dynamicMesh>mesh/bendedMesh"] = true,
    ["physics/dynamicMesh>mesh/mesh"] = true,
    ["physics/dynamicMesh>mesh/rotatingMesh"] = true,
    ["physics/dynamicMesh>mesh/clothMesh"] = true,
    ["physics/dynamicMesh>mesh/proxyMesh"] = true,
    ["mesh/proxyMesh>mesh/mesh"] = true,
    ["mesh/proxyMesh>mesh/bendedMesh"] = true,
    ["mesh/proxyMesh>mesh/rotatingMesh"] = true,
    ["mesh/proxyMesh>mesh/clothMesh"] = true,
    ["mesh/proxyMesh>physics/dynamicMesh"] = true
}

---Class for worldMeshNode
---@class mesh : spawnable
---@field public apps table
---@field public appIndex integer
---@field protected appSearch string
---@field public scale {x: number, y: number, z: number}
---@field protected occluderType integer
---@field protected occluderTypes table
---@field protected hasOccluder boolean|table
---@field protected windImpulseEnabled boolean
---@field protected castLocalShadows integer
---@field protected castRayTracedGlobalShadows integer
---@field protected castRayTracedLocalShadows integer
---@field protected castShadows integer
---@field protected shadowCastingModeEnum table
---@field protected shadowHeaderState boolean
---@field protected maxShadowPropertiesWidth number?
---@field public bBox table {min: Vector4, max: Vector4}
---@field public hideGenerate boolean
---@field public colliderShapeTypeIndex integer
---@field public colliderShapeHashIndex integer
---@field public colliderShapeSectorHashIndex integer
---@field private bBoxLoaded boolean
---@field private assetStartTime number
---@field protected maxPropertyWidth number?
---@field protected convertTarget integer
---@field public assetPreviewType string
---@field public assetPreviewDelay number
---@field protected uk10 integer
local mesh = setmetatable({}, { __index = spawnable })

---Creates a new static mesh spawnable with mesh-specific defaults.
---@return mesh
function mesh:new()
	local o = spawnable.new(self)

    o.spawnListType = "list"
    o.dataType = "Static Mesh"
    o.spawnDataPath = "data/spawnables/mesh/all/"
    o.modulePath = "mesh/mesh"
    o.node = "worldMeshNode"
    o.description = "Places a static mesh, from a given .mesh file. This will not have any collision, but has an option to generate a fitting collider"
    o.icon = IconGlyphs.CubeOutline

    o.apps = {}
    o.appIndex = 0
    o.appSearch = ""
    o.scale = { x = 1, y = 1, z = 1 }

    o.occluderType = 0
    o.occluderTypes = utils.enumTable("visWorldOccluderType")
    o.hasOccluder = false
    o.windImpulseEnabled = true

    o.castLocalShadows = 0
    o.castRayTracedGlobalShadows = 0
    o.castRayTracedLocalShadows = 0
    o.castShadows = 0
    o.shadowCastingModeEnum = utils.enumTable("shadowsShadowCastingMode")
    o.shadowHeaderState = false
    o.maxShadowPropertiesWidth = nil

    o.bBox = { min = Vector4.new(-0.5, -0.5, -0.5, 0), max = Vector4.new( 0.5, 0.5, 0.5, 0) }
    o.bBoxLoaded = false

    o.colliderShapeTypeIndex = 0
    o.colliderShapeHashIndex = 0
    o.colliderShapeSectorHashIndex = 0
    o.hideGenerate = false
    o.maxPropertyWidth = nil
    o.convertTarget = 0

    o.assetPreviewType = "backdrop"
    o.assetPreviewDelay = 0.1
    o.assetStartTime = 0

    o.uk10 = 1040

    setmetatable(o, { __index = self })
   	return o
end

---Loads appearance names, bounding box and occluder support for the current mesh.
---Uses cached metadata when available and falls back to async resource loading.
---@protected
---@param forceRefresh boolean? Clears cached values before loading when true.
function mesh:loadMeshResourceData(forceRefresh)
    if forceRefresh then
        cache.removeValue(self.spawnData .. "_apps")
        self.apps = {}
        self.appIndex = 0
        self.bBoxLoaded = false
    end

    cache.tryGetMeshResource(self.spawnData)
    .notFound(function (task)
        self.bBox.max = Vector4.new(0.5, 0.5, 0.5, 0) -- Temp values, so that onAssemble//updateScale can work
        self.bBox.min = Vector4.new(-0.5, -0.5, -0.5, 0)
        self.apps = {}

        builder.registerLoadResource(self.spawnData, function (resource)
            for _, appearance in ipairs(resource.appearances) do
                table.insert(self.apps, appearance.name.value)
            end

            self.bBox.min = resource.boundingBox.Min
            self.bBox.max = resource.boundingBox.Max
            local entity = self:getEntity()
            if entity then
                visualizer.updateScale(entity, self:getArrowSize(), "arrows")
            end

            local occluder = false
            for _, param in pairs(resource.parameters) do
                if param:IsA("meshMeshParamOccluderData") then
                    occluder = true
                    break
                end
            end

            -- Save to cache
            cache.addMeshResource(self.spawnData, {
                apps = self.apps,
                bBoxMax = utils.fromVector(self.bBox.max),
                bBoxMin = utils.fromVector(self.bBox.min),
                occluder = occluder
            })

            task:taskCompleted()

            if self:isSpawned() and self.isAssetPreview then
                self:assetPreviewSetPosition()
            end
        end)
    end)
    .found(function ()
        local cachedResource = cache.getMeshResource(self.spawnData)
        if not cachedResource then
            return
        end

        local previousApp = self.app
        self.apps = cachedResource.apps
        self.bBox.max = cachedResource.bBoxMax
        self.bBox.min = cachedResource.bBoxMin
        self.appIndex = math.max(utils.indexValue(self.apps, self.app) - 1, 0)
        self.hasOccluder = cachedResource.occluder
        self.bBoxLoaded = true

        if utils.indexValue(self.apps, self.app) - 1 < 0 then
            self.app = self.apps[1] or "default"
        end

        if self.app ~= previousApp then
            local entity = self:getEntity()
            if entity then
                local meshComponent = entity:FindComponentByName("mesh")
                if meshComponent then
                    meshComponent.meshAppearance = CName.new(self.app)
                    meshComponent:LoadAppearance()
                    self:setOutline(self.outline)
                end
            end
        end
    end)
end

---Forces a fresh appearance/resource lookup for the current mesh path.
function mesh:reloadAppearances()
    if not self.spawnData or self.spawnData == "" then
        return
    end

    self:loadMeshResourceData(true)
end

---Selects the next appearance in the loaded list, wrapping at the end.
---@return boolean changed
function mesh:cycleAppearance()
    local appCount = #(self.apps or {})
    if appCount <= 1 then
        return false
    end

    local currentIndex = utils.indexValue(self.apps, self.app)
    if type(currentIndex) ~= "number" or currentIndex < 1 or currentIndex > appCount then
        currentIndex = 0
    end

    local nextIndex = (currentIndex % appCount) + 1
    local nextApp = self.apps[nextIndex]
    if not nextApp or nextApp == self.app then
        return false
    end

    if self.object then
        history.addAction(history.getElementChange(self.object))
    end

    self.app = nextApp
    self.appIndex = nextIndex - 1

    local entity = self:getEntity()
    if entity then
        local component = entity:FindComponentByName("mesh")
        if component then
            component.meshAppearance = CName.new(self.app)
            component:LoadAppearance()
            self:setOutline(self.outline)
        end
    end

    return true
end

---Loads serialized spawnable data and immediately warms mesh metadata.
---@param data table
---@param position Vector4
---@param rotation EulerAngles
function mesh:loadSpawnData(data, position, rotation)
    spawnable.loadSpawnData(self, data, position, rotation)
    self.appSearch = self.appSearch or ""
    self.appSearch = utils.stripNonASCII(self.appSearch)
    self:loadMeshResourceData(false)
end

---Creates and attaches the runtime mesh component to the spawned entity.
---@param entity entEntity
function mesh:onAssemble(entity)
    spawnable.onAssemble(self, entity)
    local component = entMeshComponent.new()
    component.name = "mesh"
    component.mesh = ResRef.FromString(self.spawnData)
    component.visualScale = Vector3.new(self.scale.x, self.scale.y, self.scale.z)
    component.meshAppearance = self.app
    component.castLocalShadows = Enum.new("shadowsShadowCastingMode", self.castLocalShadows)
    component.castRayTracedGlobalShadows = Enum.new("shadowsShadowCastingMode", self.castRayTracedGlobalShadows)
    component.castRayTracedLocalShadows = Enum.new("shadowsShadowCastingMode", self.castRayTracedLocalShadows)
    component.castShadows = Enum.new("shadowsShadowCastingMode", self.castShadows)

    entity:AddComponent(component)

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")

    self:assetPreviewAssemble(entity)
end

---Returns world-space anchor for the preview text overlay.
---@return Vector4
function mesh:getAssetPreviewTextAnchor()
    local pos = preview.getTopLeft(0.8)
    return utils.addVector(self.position, self.rotation:ToQuat():Transform(Vector4.new(pos, 0, pos, 0)))
end

---Updates mesh preview transform/appearance and returns preview spawn position.
---@return Vector4
function mesh:getAssetPreviewPosition()
    local position, forward = spawnable.getAssetPreviewPosition(self, 0.75)

    local entity = self:getEntity()
    if not entity then
        return position
    end

    local mesh = entity:FindComponentByName("mesh")
    if not mesh then
        return position
    end

    if not self.bBox or not self.bBox.min or not self.bBox.max then
        return position
    end

    -- Scale mesh to fit
    local extents = { self.bBox.max.x - self.bBox.min.x, self.bBox.max.y - self.bBox.min.y, self.bBox.max.z - self.bBox.min.z }
    local maxExtent = math.max(table.unpack(extents))
    if maxExtent <= 0 then
        maxExtent = 1
    end
    local factor = 0.275 / maxExtent

    self.scale = { x = factor, y = factor, z = factor }
    mesh.visualScale = Vector3.new(factor, factor, factor)

    -- Calculate rotation and cycle app
    local rotation = (((Cron.time - self.assetStartTime) % 4) / 4) * 360
    local apps = self.apps or {}
    if #apps > 0 then
        local app = math.floor((((Cron.time - self.assetStartTime) % (#apps)) / (#apps)) * #apps)
        if app ~= self.appIndex then
            self.appIndex = app
            self.app = apps[self.appIndex + 1] or "default"
            mesh.meshAppearance = CName.new(self.app)
            mesh:LoadAppearance()
        end
    end

    mesh:SetLocalOrientation(EulerAngles.new(0, 7.5, rotation):ToQuat())

    -- Adjust for offcenter bbox, and adjust for rotation
    local diff = utils.subVector(self.position, self:getCenter())
    diff = self.rotation:ToQuat():TransformInverse(diff)
    diff = Vector4.RotateAxis(diff, Vector4.new(0, 0, 1, 0), Deg2Rad(rotation))

    -- Adjust for x offset in editor mode
    diff = utils.addVector(diff, utils.multVector(forward, 0.275))

    if extents[3] < maxExtent * 0.1 then
        diff.z = diff.z - 0.075
    end

    mesh:SetLocalPosition(diff)

    if preview.elements and preview.elements["previewFirstLine"] and preview.elements["previewSecondLine"] then
        preview.elements["previewFirstLine"]:SetText("Appearance: " .. self.app)
        preview.elements["previewSecondLine"]:SetText(("Size: X=%.2fm Y=%.2fm Z=%.2fm"):format(extents[1], extents[2], extents[3]))
    end

    return position
end

---Builds the preview-only backdrop and lights around the mesh component.
---@param entity entEntity
function mesh:assetPreviewAssemble(entity)
    if not self.isAssetPreview then return end

    local size = preview.getBackplaneSize(0.8)
    local component = entMeshComponent.new()
    component.name = "backdrop"
    component.mesh = ResRef.FromString("base\\spawner\\base_grid.w2mesh")
    component.visualScale = Vector3.new(size, size, size)
    component.renderingPlane = ERenderingPlane.RPl_Weapon
    component:SetLocalOrientation(EulerAngles.new(0, 90, 180):ToQuat())
    entity:AddComponent(component)
    preview.addLight(entity, 7.55, 0.75, 1)

    local lightBlocker = entMeshComponent.new()
    lightBlocker.name = "lightBlocker"
    lightBlocker.mesh = ResRef.FromString("engine\\meshes\\editor\\sphere.w2mesh")
    lightBlocker.visualScale = Vector3.new(1.65, 1.65, 1.65)
    lightBlocker:SetLocalPosition(Vector4.new(0, 0.75, 0, 0))
    entity:AddComponent(lightBlocker)

    preview.addLight(entity, 7.55, 0.75, 1)

    local mesh = entity:FindComponentByName("mesh")
    mesh.renderingPlane = ERenderingPlane.RPl_Weapon

    preview.elements["previewFirstLine"]:SetVisible(true)
    preview.elements["previewSecondLine"]:SetVisible(true)
    self.assetStartTime = Cron.time
end

---Spawns through an empty wrapper entity and assembles mesh components manually.
---This avoids relying on direct `.mesh` spawning behavior for world mesh nodes.
function mesh:spawn()
    local mesh = self.spawnData
    self.spawnData = "base\\spawner\\empty_entity.ent"

    spawnable.spawn(self)
    self.spawnData = mesh
end

---Serializes mesh-specific editor state on top of the base spawnable payload.
---@return table
function mesh:save()
    local data = spawnable.save(self)

    data.scale = { x = self.scale.x, y = self.scale.y, z = self.scale.z }
    data.castLocalShadows = self.castLocalShadows
    data.castRayTracedGlobalShadows = self.castRayTracedGlobalShadows
    data.castRayTracedLocalShadows = self.castRayTracedLocalShadows
    data.castShadows = self.castShadows
    data.occluderType = self.occluderType
    data.windImpulseEnabled = self.windImpulseEnabled

    return data
end

---Applies current scale to the runtime mesh component and refreshes gizmos.
---@protected
function mesh:updateScale()
    local entity = self:getEntity()
    if not entity then return end

    local component = entity:FindComponentByName("mesh")
    component.visualScale = Vector3.new(self.scale.x, self.scale.y, self.scale.z)

    component:Toggle(false)
    component:Toggle(true)

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    self:setOutline(self.outline)
end

---Applies shadow-related editor properties to the runtime mesh component.
---@protected
---@param changed boolean
function mesh:updateShadowSettings(changed)
    if not changed then return end

    local entity = self:getEntity()
    if not entity then return end

    local component = entity:FindComponentByName("mesh")
    component.castLocalShadows = Enum.new("shadowsShadowCastingMode", self.castLocalShadows)
    component.castRayTracedGlobalShadows = Enum.new("shadowsShadowCastingMode", self.castRayTracedGlobalShadows)
    component.castRayTracedLocalShadows = Enum.new("shadowsShadowCastingMode", self.castRayTracedLocalShadows)
    component.castShadows = Enum.new("shadowsShadowCastingMode", self.castShadows)

    component:Toggle(false)
    component:Toggle(true)
end

---Returns mesh dimensions based on bounding box and current scale.
---@return table
function mesh:getSize()
    return utils.getBoxSize(self.bBox, self.scale)
end

---Returns the scaled local-space bounding box.
---@return table
function mesh:getBBox()
    return utils.getScaledBBox(self.bBox, self.scale)
end

---Returns the world-space center of the scaled and rotated bounding box.
---@return Vector4
function mesh:getCenter()
    return utils.getBoxCenter(self.bBox, self.scale, self.rotation, self.position)
end

---Performs ray-vs-bounding-box intersection used for selection/manipulation.
---Also returns an unscaled hit point for tools that need raw mesh-space context.
---@param origin Vector4
---@param ray Vector4
---@return table
function mesh:calculateIntersection(origin, ray)
    return intersection.getSpawnableBBoxIntersection(self, origin, ray)
end

---Draws the single-node mesh inspector UI.
---Includes appearance selection, collider generation, occluder/shadow settings,
---and mesh subtype conversion controls.
function mesh:draw()
    spawnable.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Appearance", "Collider", "Occluder", "Enable Wind Impulse" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    style.pushGreyedOut(#self.apps <= 1)

    local list = self.apps

    if #self.apps == 0 then
        list = {"No apps"}
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
        "##app",
        "Search appearance...",
        selectedApp,
        self.appSearch,
        list,
        {
            element = self.object,
            width = 160,
            matchContentWidth = true,
            tooltip = "Select the mesh appearance"
        }
    )
    if changed and #self.apps > 0 then
        self.app = selectedApp
        self.appIndex = math.max(utils.indexValue(self.apps, self.app) - 1, 0)

        local entity = self:getEntity()

        if entity then
            entity:FindComponentByName("mesh").meshAppearance = CName.new(self.app)
            entity:FindComponentByName("mesh"):LoadAppearance()

            self:setOutline(self.outline)
        end
    end
    ImGui.SameLine()
    ImGui.BeginDisabled(#self.apps <= 1)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.SkipNext .. "##cycleMeshAppearance") then
        self:cycleAppearance()
    end
    style.pushButtonNoBG(false)
    ImGui.EndDisabled()
    style.tooltip("Select the next mesh appearance. Wraps to the first appearance at the end of the list.")
    style.popGreyedOut(#self.apps <= 1)
    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload .. "##reloadMeshAppearanceList") then
        self:reloadAppearances()
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reload appearance list for this asset and refresh cached data.")

    if not self.hideGenerate then
        self:drawColliderSelector()
    end

    if self.hasOccluder then
        style.mutedText("Occluder")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.occluderType, _ = style.trackedCombo(self.object, "##occluderType", self.occluderType, self.occluderTypes, 110)
    end

    style.mutedText("Enable Wind Impulse")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.windImpulseEnabled, _ = style.trackedCheckbox(self.object, "##windImpulseEnabled", self.windImpulseEnabled)
    style.tooltip("Enable wind impulse for this mesh, not previewed.")

    self.shadowHeaderState = ImGui.TreeNodeEx("Shadow Settings")

    if self.shadowHeaderState then
        if not self.maxShadowPropertiesWidth then
            self.maxShadowPropertiesWidth = utils.getTextMaxWidth({ "Cast Local Shadows", "Cast RT Global Shadows", "Cast RT Local Shadows", "Cast Shadows" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        end

        style.mutedText("Cast Local Shadows")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.castLocalShadows, changed = style.trackedCombo(self.object, "##castLocalShadows", self.castLocalShadows, self.shadowCastingModeEnum)
        self:updateShadowSettings(changed)

        style.mutedText("Cast RT Global Shadows")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.castRayTracedGlobalShadows, changed = style.trackedCombo(self.object, "##castRayTracedGlobalShadows", self.castRayTracedGlobalShadows, self.shadowCastingModeEnum)
        self:updateShadowSettings(changed)

        style.mutedText("Cast RT Local Shadows")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.castRayTracedLocalShadows, changed = style.trackedCombo(self.object, "##castRayTracedLocalShadows", self.castRayTracedLocalShadows, self.shadowCastingModeEnum)
        self:updateShadowSettings(changed)

        style.mutedText("Cast Shadows")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxShadowPropertiesWidth)
        self.castShadows, changed = style.trackedCombo(self.object, "##castShadows", self.castShadows, self.shadowCastingModeEnum)
        self:updateShadowSettings(changed)

        ImGui.TreePop()
    end
    
    if self.node == "worldMeshNode" then
        self:drawConversionSelector("##meshConverterType", "Lossy Conversion##meshSingle")
    end
end

function mesh:drawColliderSelector()
    style.mutedText("Collider")
    
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    ImGui.SetNextItemWidth(160 * style.viewSize)
    local nextColliderShapeTypeIndex, colliderShapeTypeIndexChanged = ImGui.Combo("##colliderShapeType", self.colliderShapeTypeIndex, colliderShapeTypes, #colliderShapeTypes)
    style.comboValueTooltip(nextColliderShapeTypeIndex, colliderShapeTypes)
    if colliderShapeTypeIndexChanged then
        self.colliderShapeTypeIndex = nextColliderShapeTypeIndex
        self.colliderShapeHashIndex = 0
        self.colliderShapeSectorHashIndex = 0
    end

    -----------------------------------------------------
    --- Simple collider shapes
    -----------------------------------------------------
    if nextColliderShapeTypeIndex ~= 3 and nextColliderShapeTypeIndex ~= 4 then
        ImGui.SameLine()
        if ImGui.Button("Generate") then
            self:generateCollider()
        end
        return
    end

    -----------------------------------------------------
    --- Complex collider shapes
    -----------------------------------------------------
    local meshCollisionShapeHashes = cache.getMeshCollisionShapeHashes(self.spawnData, colliderShapeTypes[nextColliderShapeTypeIndex + 1])
    if changed then
        self.colliderShapeHashIndex = 0
        self.colliderShapeSectorHashIndex = 0
    end

    if #meshCollisionShapeHashes == 0 then
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        style.drawIconLabelRow(IconGlyphs.Alert, nil, {iconColor = style.warnColor, fieldX = ImGui.CalcTextSize(IconGlyphs.Alert) + ImGui.GetStyle().ItemSpacing.x})
        ImGui.SameLine()
        style.mutedText(colliderShapeTypes[nextColliderShapeTypeIndex + 1] .. " shapes not found")
    else
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        style.mutedText("Shape Hash")
        
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        ImGui.SetNextItemWidth(160 * style.viewSize)
        local nextColliderShapeHashIndex, colliderShapeHashIndexChanged = ImGui.Combo(
            "##colliderShapeHash",
            self.colliderShapeHashIndex,
            meshCollisionShapeHashes,
            #meshCollisionShapeHashes
        )
        style.comboValueTooltip(nextColliderShapeHashIndex, meshCollisionShapeHashes)
        if colliderShapeHashIndexChanged then
            self.colliderShapeHashIndex = nextColliderShapeHashIndex
            self.colliderShapeSectorHashIndex = 0
        end

        local meshCollisionShapeSectorHashes = cache.getCollisionShapeSectorsHashes(meshCollisionShapeHashes[nextColliderShapeHashIndex + 1])
        if #meshCollisionShapeSectorHashes == 0 then
            ImGui.SetCursorPosX(self.maxPropertyWidth)
            style.drawIconLabelRow(IconGlyphs.Alert, nil, {iconColor = style.warnColor, fieldX = ImGui.CalcTextSize(IconGlyphs.Alert) + ImGui.GetStyle().ItemSpacing.x})
            ImGui.SameLine()
            style.mutedText("Shape sectors not found")
        else
            ImGui.SetCursorPosX(self.maxPropertyWidth)
            style.mutedText("Shape Sector Hash")

            ImGui.SetCursorPosX(self.maxPropertyWidth)
            ImGui.SetNextItemWidth(160 * style.viewSize)
            local nextColliderShapeSectorHashIndex, colliderShapeSectorHashIndexChanged = ImGui.Combo(
                "##colliderShapeSectorHash",
                self.colliderShapeSectorHashIndex,
                meshCollisionShapeSectorHashes,
                #meshCollisionShapeSectorHashes
            )
            style.comboValueTooltip(nextColliderShapeSectorHashIndex, meshCollisionShapeSectorHashes)
            if colliderShapeSectorHashIndexChanged then
                self.colliderShapeSectorHashIndex = nextColliderShapeSectorHashIndex
            end

            ImGui.SameLine()
            if ImGui.Button("Generate") then
                self:generateCollider()
            end
        end
    end

    ImGui.Spacing()
end

---Builds single-selection property groups for the editor sidebar.
---@return table
function mesh:getProperties()
    return self:addNodeProperty(spawnable.getProperties(self))
end

---Checks whether current mesh asset supports conversion to the target subtype.
---Some targets are constrained by curated path allowlists.
---@param targetModulePath string
---@return boolean
function mesh:isMeshConversionAllowed(targetModulePath)
    if targetModulePath == self.modulePath then
        return false
    end

    if targetModulePath == "mesh/clothMesh" then
        return cache.isSpawnDataInSet(self.spawnData, clothListPath)
    end

    if targetModulePath == "mesh/bendedMesh" then
        return cache.isSpawnDataInSet(self.spawnData, bendedListPath)
    end

    if targetModulePath == "physics/dynamicMesh" then
        return cache.isSpawnDataInSet(self.spawnData, dynamicListPath)
    end

    return true
end

---Returns conversion labels and target module paths filtered for this mesh.
---@return table, table
function mesh:getConversionTargets()
    local options = {}
    local actions = {}

    for _, target in ipairs(conversionTargets) do
        if self:isMeshConversionAllowed(target.modulePath) then
            table.insert(options, getConversionTargetLabel(target, "meshConvertTarget:" .. tostring(target.modulePath)))
            table.insert(actions, target.modulePath)
        end
    end

    return options, actions
end

---Checks whether converting from current module to target is lossy.
---@param targetModulePath string
---@return boolean
function mesh:isLossyConversion(targetModulePath)
    return lossyConversionPairs[self.modulePath .. ">" .. targetModulePath] == true
end

---Checks whether converting between two explicit module paths is lossy.
---@param fromModulePath string
---@param targetModulePath string
---@return boolean
function mesh:isLossyConversionFrom(fromModulePath, targetModulePath)
    return lossyConversionPairs[fromModulePath .. ">" .. targetModulePath] == true
end

---Converts this spawnable to another mesh subtype module.
---@param targetModulePath string
---@param skipHistory boolean?
function mesh:convertToModule(targetModulePath, skipHistory)
    if not targetModulePath then return end

    if not skipHistory then
        history.addAction(history.getElementChange(self.object))
    end
    self.convertTarget = 0
    self:convertSpawnableTo(targetModulePath)
end

---Draws single-entry conversion UI with optional lossy conversion warning.
---@param comboId string?
---@param popupId string?
function mesh:drawConversionSelector(comboId, popupId)
    local options, actions = self:getConversionTargets()
    if #options == 0 then return end

    comboId = comboId or "##meshConverterType"
    popupId = popupId or "Lossy Conversion##meshConversion"

    style.mutedText("Convert to")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.convertTarget = math.max(0, math.min(self.convertTarget, #options - 1))
    self.convertTarget, _ = style.trackedCombo(self.object, comboId, self.convertTarget, options, 150, {
        tooltip = "Select the mesh type to convert into"
    })

    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth + 150 * style.viewSize + ImGui.GetStyle().ItemSpacing.x)
    style.pushButtonNoBG(false)
    if ImGui.Button("Convert") then
        local target = actions[self.convertTarget + 1]
        if target and self:isLossyConversion(target) and not settings.skipLossyConversionWarning then
            ImGui.OpenPopup(popupId)
        else
            self:convertToModule(target)
        end
    end

    if ImGui.BeginPopupModal(popupId, true, ImGuiWindowFlags.AlwaysAutoResize) then
        style.mutedText("Warning")
        ImGui.Text("This conversion is lossy.")
        style.mutedText("Type-specific properties will be removed.")
        ImGui.Text("Do you want to continue?")
        ImGui.Dummy(0, 8 * style.viewSize)
        local skipWarning, changed = ImGui.Checkbox("Do not ask again", settings.skipLossyConversionWarning)
        if changed then
            settings.skipLossyConversionWarning = skipWarning
            settings.save()
        end
        ImGui.Dummy(0, 8 * style.viewSize)

        if ImGui.Button("Convert") then
            local target = actions[self.convertTarget + 1]
            self:convertToModule(target)
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()
        if ImGui.Button("Cancel") then
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end
end

---Builds grouped-operation property entries for multi-selection editing.
---Includes grouped appearance updates, subtype conversion and collider creation.
---@return table
function mesh:getGroupedProperties()
    local properties = spawnable.getGroupedProperties(self)

    properties["groupedAppearances"] = appearanceHelper.getGroupedProperties(self)

    -- Group conversion tool: convert all selected mesh subtypes at once.
    properties["meshConverter"] = {
        name = "Mesh",
        id = "meshConverter",
        data = {
            fromIndex = 0,
            toIndex = 0,
            pendingFromModulePath = nil,
            pendingTargetModulePath = nil
        },
        draw = function(element, entries)
            local converterData = element.groupOperationData["meshConverter"]
            local availableFromTypes = {}
            local availableFromCounts = {}
            local targetDefsByPath = {}
            for _, target in ipairs(conversionTargets) do
                targetDefsByPath[target.modulePath] = target
            end

            for _, target in ipairs(conversionTargets) do
                availableFromCounts[target.modulePath] = 0
            end

            for _, entry in ipairs(entries) do
                local spawnableEntry = entry.spawnable
                if spawnableEntry and availableFromCounts[spawnableEntry.modulePath] ~= nil then
                    availableFromCounts[spawnableEntry.modulePath] = availableFromCounts[spawnableEntry.modulePath] + 1
                end
            end

            for _, target in ipairs(conversionTargets) do
                if availableFromCounts[target.modulePath] and availableFromCounts[target.modulePath] > 0 then
                    table.insert(availableFromTypes, target.modulePath)
                end
            end

            if #availableFromTypes == 0 then return end

            converterData.fromIndex = math.max(0, math.min(converterData.fromIndex, #availableFromTypes - 1))
            local fromOptions = {}
            for _, modulePath in ipairs(availableFromTypes) do
                table.insert(fromOptions, getConversionTargetLabel(targetDefsByPath[modulePath], "groupMeshFrom:" .. tostring(modulePath)))
            end

            local lineStartX = ImGui.GetCursorPosX()
            local relationLabelX = lineStartX + ImGui.CalcTextSize("Convert") + 4
            local allLabelWidth = ImGui.CalcTextSize("all")
            local toLabelWidth = ImGui.CalcTextSize("to")
            local relationWidth = math.max(allLabelWidth, toLabelWidth) + ImGui.GetStyle().ItemSpacing.x
            local selectorX = relationLabelX + relationWidth
            local selectorWidth = 165 * style.viewSize

            style.mutedText("Convert")
            ImGui.SameLine()
            ImGui.SetCursorPosX(relationLabelX)
            style.mutedText("all")
            ImGui.SameLine()
            ImGui.SetCursorPosX(selectorX)
            ImGui.SetNextItemWidth(selectorWidth)
            local fromIndex, fromChanged = ImGui.Combo("##groupMeshConvertFrom", converterData.fromIndex, fromOptions, #fromOptions)
            style.comboValueTooltip(fromIndex, fromOptions)
            if fromChanged then
                converterData.fromIndex = fromIndex
                converterData.toIndex = 0
            end

            local fromModulePath = availableFromTypes[converterData.fromIndex + 1]
            local toOptions = {}
            local toModulePaths = {}

            for _, target in ipairs(conversionTargets) do
                if target.modulePath ~= fromModulePath then
                    local hasConvertibleEntry = false
                    for _, entry in ipairs(entries) do
                        local spawnableEntry = entry.spawnable
                        if spawnableEntry and spawnableEntry.modulePath == fromModulePath and spawnableEntry:isMeshConversionAllowed(target.modulePath) then
                            hasConvertibleEntry = true
                            break
                        end
                    end

                    if hasConvertibleEntry then
                        table.insert(toOptions, getConversionTargetLabel(target, "groupMeshTo:" .. tostring(target.modulePath)))
                        table.insert(toModulePaths, target.modulePath)
                    end
                end
            end

            if #toOptions == 0 then
                return
            end

            ImGui.SetCursorPosX(relationLabelX)
            style.mutedText("to")
            ImGui.SameLine()
            ImGui.SetCursorPosX(selectorX)
            ImGui.SetNextItemWidth(selectorWidth)
            converterData.toIndex = math.max(0, math.min(converterData.toIndex, #toOptions - 1))
            converterData.toIndex, _ = ImGui.Combo("##groupMeshConvertTo", converterData.toIndex, toOptions, #toOptions)
            style.comboValueTooltip(converterData.toIndex, toOptions)
            local targetModulePath = toModulePaths[converterData.toIndex + 1]

            local function applyGroupConversion(sourceModulePath, targetPath)
                history.addAction(history.getMultiSelectChange(entries))

                local nApplied = 0
                for _, entry in ipairs(entries) do
                    local spawnableEntry = entry.spawnable
                    if spawnableEntry and spawnableEntry.modulePath == sourceModulePath and spawnableEntry:isMeshConversionAllowed(targetPath) then
                        spawnableEntry:convertToModule(targetPath, true)
                        nApplied = nApplied + 1
                    end
                end

                local sourcePlural = targetDefsByPath[sourceModulePath] and targetDefsByPath[sourceModulePath].plural or "mesh entries"
                local targetPlural = targetDefsByPath[targetPath] and targetDefsByPath[targetPath].plural or "mesh entries"
                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Converted %s %s to %s", nApplied, sourcePlural, targetPlural)))
            end

            ImGui.SameLine()
            if ImGui.Button("Convert") then
                if self:isLossyConversionFrom(fromModulePath, targetModulePath) and not settings.skipLossyConversionWarning then
                    converterData.pendingFromModulePath = fromModulePath
                    converterData.pendingTargetModulePath = targetModulePath
                    ImGui.OpenPopup("Lossy Conversion##groupMeshConverter")
                else
                    applyGroupConversion(fromModulePath, targetModulePath)
                end
            end
            style.tooltip("Convert selected mesh subtype entries to the selected target type")

            if ImGui.BeginPopupModal("Lossy Conversion##groupMeshConverter", true, ImGuiWindowFlags.AlwaysAutoResize) then
                local pendingFromModulePath = converterData.pendingFromModulePath
                local pendingTargetModulePath = converterData.pendingTargetModulePath
                local nPending = 0

                if pendingFromModulePath and pendingTargetModulePath then
                    for _, entry in ipairs(entries) do
                        local spawnableEntry = entry.spawnable
                        if spawnableEntry and spawnableEntry.modulePath == pendingFromModulePath and spawnableEntry:isMeshConversionAllowed(pendingTargetModulePath) then
                            nPending = nPending + 1
                        end
                    end
                end

                style.mutedText("Warning")
                ImGui.Text("This conversion is lossy.")
                style.mutedText("Type-specific properties will be removed.")
                ImGui.Text(string.format("Affected entries: %d", nPending))
                ImGui.Text("Do you want to continue?")
                ImGui.Dummy(0, 8 * style.viewSize)
                local skipWarning, changed = ImGui.Checkbox("Do not ask again", settings.skipLossyConversionWarning)
                if changed then
                    settings.skipLossyConversionWarning = skipWarning
                    settings.save()
                end
                ImGui.Dummy(0, 8 * style.viewSize)

                if ImGui.Button("Convert") then
                    if pendingFromModulePath and pendingTargetModulePath then
                        applyGroupConversion(pendingFromModulePath, pendingTargetModulePath)
                    end
                    converterData.pendingFromModulePath = nil
                    converterData.pendingTargetModulePath = nil
                    ImGui.CloseCurrentPopup()
                end

                ImGui.SameLine()
                if ImGui.Button("Cancel") then
                    converterData.pendingFromModulePath = nil
                    converterData.pendingTargetModulePath = nil
                    ImGui.CloseCurrentPopup()
                end

                ImGui.EndPopup()
            end
        end,
        entries = { self.object }
    }

    if self.hideGenerate then return properties end

    -- Group collider generation tool for selected static mesh entries.
    properties["mesh"] = {
		name = "Static Mesh",
        id = "mesh",
		data = {
            shape = 0
        },
		draw = function(element, entries)
            style.mutedText("Collider Shape")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(110 * style.viewSize)
            element.groupOperationData["mesh"].shape, _ = ImGui.Combo("##colliderShape", element.groupOperationData["mesh"].shape, colliderShapeTypes, 3)
            style.comboValueTooltip(element.groupOperationData["mesh"].shape, colliderShapeTypes)

            ImGui.SameLine()

            if ImGui.Button("Generate") then
                local selectedEntries = {}
                local nApplied = 0
                local sourceEntries = entries

                for _, entry in ipairs(sourceEntries) do
                    if entry and entry.parent and entry.spawnable and entry.spawnable.node == self.node then
                        table.insert(selectedEntries, entry)
                    end
                end

                local changeAction = nil
                local actions = {}

                if #selectedEntries > 0 then
                    changeAction = history.getMultiSelectChange(selectedEntries)
                end

                for _, entry in ipairs(selectedEntries) do
                    entry.spawnable.colliderShapeTypeIndex = element.groupOperationData["mesh"].shape
                    local action = entry.spawnable:generateCollider(true)
                    if action then
                        table.insert(actions, action)
                        nApplied = nApplied + 1
                    end
                end

                if changeAction and #actions > 0 then
                    history.addAction({
                        undo = function ()
                            for i = #actions, 1, -1 do
                                actions[i].undo()
                            end
                            changeAction.undo()
                        end,
                        redo = function ()
                            changeAction.redo()
                            for _, action in ipairs(actions) do
                                action.redo()
                            end
                        end
                    })
                end

                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Generated colliders for %s nodes", nApplied)))
            end
            style.tooltip("Generate Colliders for all selected meshes.")
        end,
		entries = { self.object }
	}

    return properties
end

---Generates a collider sibling and wraps mesh + collider in a new group.
---Returns a history action so callers can compose grouped undo/redo behavior.
---@protected
---@param skipHistory? boolean
---@return table?
function mesh:generateCollider(skipHistory)
    if not self.object or not self.object.parent or self.object:isLocked() then
        return nil
    end

    local parent = self.object.parent
    local index = utils.indexValue(parent.childs, self.object) + 1
    if index < 1 then
        index = #parent.childs + 1
    end

    local group = require("modules/classes/editor/positionableGroup"):new(self.object.sUI)
    group.name = self.object.name .. "_grouped"
    group:setParent(parent, index)
    local insertGroup = history.getInsert({ group })

    local pos = Vector4.new(self.position.x, self.position.y, self.position.z, 0)
    local rotation = EulerAngles.new(self.rotation.roll, self.rotation.pitch, self.rotation.yaw)
    
    local collider = nil
    local data = nil
    if self.colliderShapeTypeIndex ~= 3 and self.colliderShapeTypeIndex ~= 4 then
        collider = require("modules/classes/spawn/collision/collider"):new()

        local x = (self.bBox.max.x - self.bBox.min.x) * self.scale.x
        local y = (self.bBox.max.y - self.bBox.min.y) * self.scale.y
        local z = (self.bBox.max.z - self.bBox.min.z) * self.scale.z

        local offset = Vector4.new((self.bBox.min.x * self.scale.x) + x / 2, (self.bBox.min.y * self.scale.y) + y / 2, (self.bBox.min.z * self.scale.z) + z / 2, 0)
        offset = self.rotation:ToQuat():Transform(offset)
        pos = Game['OperatorAdd;Vector4Vector4;Vector4'](pos, offset)

        local radius = math.max(x, y) / 2
        local height = z - radius * 2
        if self.colliderShapeTypeIndex == 1 then
            if x > z or y > z then
                radius = z / 2
                height = math.max(x, y) - radius * 2
                rotation.roll = rotation.roll + 90

                if y > x then
                    rotation.yaw = rotation.yaw + 90
                end
            end
        end

        data = {
            extents = { x = x / 2, y = y / 2, z = z / 2 },
            radius = radius,
            height = height,
            shape = self.colliderShapeTypeIndex
        }
    else
        collider = require("modules/classes/spawn/collision/meshCollider"):new()

        local shapeType = colliderShapeTypes[self.colliderShapeTypeIndex + 1]

        local meshCollisionShapeHashes = cache.getMeshCollisionShapeHashes(self.spawnData, shapeType)
        if #meshCollisionShapeHashes == 0 then
            return nil
        end

        local shapeHash = meshCollisionShapeHashes[self.colliderShapeHashIndex + 1]
        local shapeSectorsHashes = cache.getCollisionShapeSectorsHashes(shapeHash)
        if #shapeSectorsHashes == 0 then
            return nil
        end

        local shapeSectorHash = shapeSectorsHashes[self.colliderShapeSectorHashIndex + 1]

        data = {
            spawnData = shapeSectorHash .. " " .. shapeHash .. " " .. shapeType,
            scale = { x = self.scale.x, y = self.scale.y, z = self.scale.z },
        }
    end

    collider:loadSpawnData(data, pos, rotation)

    local colliderElement = require("modules/classes/editor/spawnableElement"):new(self.object.sUI)
    colliderElement:load({
        name = self.object.name .. "_collider",
        spawnable = collider:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    colliderElement:setParent(group)
    local insertCollider = history.getInsert({ colliderElement })

    local remove = history.getRemove({ self.object })
    self.object:setParent(group)
    local insert = history.getInsert({ self.object })
    local move = history.getMove(remove, insert)

    local action = {
        undo = function ()
            move.undo()
            insertCollider.undo()
            insertGroup.undo()
        end,
        redo = function ()
            insertGroup.redo()
            history.spawnedUI.cachePaths()
            insertCollider.redo()
            move.redo()
        end
    }

    if not skipHistory then
        history.addAction(action)
    end

    self.object.headerOpen = false
    return action
end

---Exports this spawnable to world-node JSON payload used by external tooling.
---@return table
function mesh:export()
    local app = self.app
    if app == "" then
        app = "default"
    end

    local data = spawnable.export(self)
    data.type = "worldMeshNode"
    data.scale = self.scale
    data.data = {
        mesh = {
            DepotPath = {
                ["$storage"] = "string",
                ["$value"] = self.spawnData
            },
        },
        meshAppearance = {
            ["$storage"] = "string",
            ["$value"] = app
        },
        castLocalShadows = self.shadowCastingModeEnum[self.castLocalShadows + 1],
        castRayTracedGlobalShadows = self.shadowCastingModeEnum[self.castRayTracedGlobalShadows + 1],
        castRayTracedLocalShadows = self.shadowCastingModeEnum[self.castRayTracedLocalShadows + 1],
        castShadows = self.shadowCastingModeEnum[self.castShadows + 1],
        occluderType = self.occluderTypes[self.occluderType + 1],
        windImpulseEnabled = self.windImpulseEnabled and 1 or 0
    }

    return data
end

return mesh
