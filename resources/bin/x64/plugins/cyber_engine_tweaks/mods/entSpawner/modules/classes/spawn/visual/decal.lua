local spawnable = require("modules/classes/spawn/spawnable")
local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local intersection = require("modules/utils/editor/intersection")
local cache = require("modules/utils/game/cache")
local builder = require("modules/utils/game/entityBuilder")
local preview = require("modules/utils/preview/previewUtils")
local utils = require("modules/utils/core/utils")
local colorUtil = require("modules/utils/ui/color")
local history = require("modules/utils/project/history")
local DECAL_VISUALIZER_THICKNESS = 0.025
local diffuseColorScaleNormalization = {
    count = 4,
    fallback = { 1, 1, 1, 1 },
    keys = {
        { "r", "x", "red", "Red" },
        { "g", "y", "green", "Green" },
        { "b", "z", "blue", "Blue" },
        { "a", "w", "alpha", "Alpha" }
    }
}

---Class for worldStaticDecalNode
---@class decal : visualized
---@field private alpha number
---@field private horizontalFlip boolean
---@field private verticalFlip boolean
---@field private autoHideDistance number
---@field private scale {x: number, y: number, z: number}
---@field private diffuseColorScale number[]
---@field private isStretchingEnabled boolean
---@field private orderNo number
---@field private normalThreshold number
---@field private roughnessScale number
---@field private decalRenderMode integer
---@field private decalRenderModes string[]
---@field private surfaceType string
---@field private surfaceTypes string[]
---@field private isTiling boolean
---@field private maxPropertyWidth number
local decal = setmetatable({}, { __index = visualized })

function decal:new()
	local o = visualized.new(self)

    o.spawnListType = "list"
    o.dataType = "Decals"
    o.spawnDataPath = "data/spawnables/visual/decals/"
    o.modulePath = "visual/decal"
    o.node = "worldStaticDecalNode"
    o.description = "Places a decal on the nearest surface, from a given .mi file"
    o.icon = IconGlyphs.StickerOutline

    o.alpha = 1
    o.horizontalFlip = false
    o.verticalFlip = false
    o.autoHideDistance = 150
    o.scale = { x = 1, y = 1, z = 1 }
    o.diffuseColorScale = { 1, 1, 1, 1 }
    o.isStretchingEnabled = false
    o.orderNo = 0
    o.normalThreshold = 1
    o.roughnessScale = 1
    o.decalRenderMode = 0
    o.decalRenderModes = utils.enumTable("EDecalRenderMode")
    o.surfaceType = "ROT_Static"
    o.surfaceTypes = utils.enumTable("ERenderObjectType")

    o.assetPreviewType = "backdrop"
    o.assetPreviewDelay = 0.05
    o.isTiling = false
    o.previewed = false
    o.previewShape = "box"
    o.previewColor = "violet"

    o.maxPropertyWidth = nil

    setmetatable(o, { __index = self })
   	return o
end

function decal:onAssemble(entity)
    if self.isAssetPreview then
        spawnable.onAssemble(self, entity)
    else
        visualized.onAssemble(self, entity)
    end

    local component = entDecalComponent.new()
    ResourceHelper.LoadReferenceResource(component, "material", self.spawnData, true)

    component.alpha = self.alpha
    component.horizontalFlip = self.horizontalFlip
    component.verticalFlip = self.verticalFlip
    component.autoHideDistance = self.autoHideDistance
    component.aspectRatio = 1
    component.isStretchingEnabled = self.isStretchingEnabled
    component.orderNo = self.orderNo
    component.normalThreshold = self.normalThreshold
    component.roughnessScale = self.roughnessScale
    component.decalRenderMode = Enum.new("EDecalRenderMode", self.decalRenderMode)
    component.surfaceType = Enum.new("ERenderObjectType", self.surfaceType)
    component.name = "decal"
    component.visualScale = Vector3.new(self.scale.x, self.scale.y, self.scale.z)

    entity:AddComponent(component)

    self:assetPreviewAssemble(entity)
end

---@param vertical number? 1 for the top left corner (default), -1 for the bottom left one
function decal:getAssetPreviewTextAnchor(vertical)
    local pos = preview.getTopLeft(0.535)
    return utils.addVector(self.position, self.rotation:ToQuat():Transform(Vector4.new(pos, 0, pos * (vertical or 1), 0)))
end

function decal:getAssetPreviewPosition()
    preview.elements["previewFirstLine"]:SetText("Is Tiling: " .. (self.isTiling and "True" or "False"))

    return spawnable.getAssetPreviewPosition(self, 0.5)
end

function decal:assetPreviewAssemble(entity)
    if not self.isAssetPreview then return end

    local size = preview.getBackplaneSize(0.535)
    local component = entMeshComponent.new()
    component.name = "backdrop"
    component.mesh = ResRef.FromString("base\\spawner\\base_grid.w2mesh")
    component.visualScale = Vector3.new(size, size, size)
    component:SetLocalOrientation(EulerAngles.new(0, 90, 180):ToQuat())
    entity:AddComponent(component)

    local lightBlocker = entMeshComponent.new()
    lightBlocker.name = "lightBlocker"
    lightBlocker.mesh = ResRef.FromString("engine\\meshes\\editor\\sphere.w2mesh")
    lightBlocker.visualScale = Vector3.new(1.65, 1.65, 1.65)
    lightBlocker:SetLocalPosition(Vector4.new(0, 0.75, 0, 0))
    entity:AddComponent(lightBlocker)

    preview.addLight(entity, 6, 0.75, 1)

    local decal = entity:FindComponentByName("decal")
    decal.visualScale = Vector3.new(0.5, 0.5, 0.5)
    decal:SetLocalOrientation(EulerAngles.new(0, 90, 180):ToQuat())

    preview.elements["previewFirstLine"]:SetVisible(true)
end

function decal:spawn()
    local decal = self.spawnData
    self.spawnData = "base\\spawner\\empty_entity.ent"

    spawnable.spawn(self)
    self.spawnData = decal

    cache.tryGet(self.spawnData .. "_tiling")
    .notFound(function (task)
        builder.registerLoadResource(self.spawnData, function(resource)
            local tiling = false

            for _, param in ipairs(resource.params) do
                if param.name.value == "MaterialTiling" then
                    tiling = true
                    break
                end
            end

            cache.addValue(self.spawnData .. "_tiling", tiling)

            task:taskCompleted()
        end)
    end)
    .found(function ()
        self.isTiling = cache.getValue(self.spawnData .. "_tiling")
    end)
end

function decal:loadSpawnData(data, position, rotation)
    spawnable.loadSpawnData(self, data, position, rotation)
    self.diffuseColorScale = colorUtil.normalizeChannels(self.diffuseColorScale, diffuseColorScaleNormalization)
    self.isStretchingEnabled = self.isStretchingEnabled ~= false and self.isStretchingEnabled ~= 0
end

function decal:save()
    self.diffuseColorScale = colorUtil.normalizeChannels(self.diffuseColorScale, diffuseColorScaleNormalization)

    local data = visualized.save(self)
    data.alpha = self.alpha
    data.horizontalFlip = self.horizontalFlip
    data.verticalFlip = self.verticalFlip
    data.autoHideDistance = self.autoHideDistance
    data.scale = { x = self.scale.x, y = self.scale.y, z = self.scale.z }
    data.isStretchingEnabled = self.isStretchingEnabled
    data.orderNo = self.orderNo
    data.normalThreshold = self.normalThreshold
    data.roughnessScale = self.roughnessScale
    data.decalRenderMode = self.decalRenderMode
    data.surfaceType = self.surfaceType
    data.diffuseColorScale = {
        self.diffuseColorScale[1],
        self.diffuseColorScale[2],
        self.diffuseColorScale[3],
        self.diffuseColorScale[4]
    }

    return data
end

function decal:getSize()
    return { x = self.scale.x, y = self.scale.y, z = DECAL_VISUALIZER_THICKNESS * math.abs(self.scale.z) }
end

function decal:getVisualizerSize()
    local size = self:getSize()
    return {
        x = math.abs(size.x) / 2,
        y = math.abs(size.y) / 2,
        z = math.abs(size.z) / 2
    }
end

function decal:getBBox()
    return {
        min = { x = -math.abs(self.scale.x) / 2, y = -math.abs(self.scale.y) / 2, z = -0.05 },
        max = { x = math.abs(self.scale.x) / 2, y = math.abs(self.scale.y) / 2, z = 0.05 }
    }
end

function decal:calculateIntersection(origin, ray)
    if not self:getEntity() then
        return { hit = false }
    end

    local scaleFactor = 0.8

    local scaledBBox = {
        min = {  x = -math.abs(self.scale.x) * scaleFactor / 2, y = -math.abs(self.scale.y) * scaleFactor / 2, z = -math.abs(self.scale.y) * 0.05 / 2 },
        max = {  x = math.abs(self.scale.x) * scaleFactor / 2, y = math.abs(self.scale.y) * scaleFactor / 2, z = math.abs(self.scale.y) * 0.05 / 2 }
    }

    local result = intersection.getBoxIntersection(origin, ray, self.position, self.rotation, scaledBBox)

    return {
        hit = result.hit,
        position = result.position,
        unscaledHit = result.position,
        collisionType = "bbox",
        distance = result.distance,
        bBox = scaledBBox,
        objectOrigin = self.position,
        objectRotation = self.rotation,
        normal = result.normal
    }
end

function decal:updateScale()
    local entity = self:getEntity()
    if not entity then return end

    local component = entity:FindComponentByName("decal")
    if component then
        component.visualScale = Vector3.new(self.scale.x, self.scale.y, self.scale.z)

        if component:IsEnabled() then
            component:Toggle(false)
            component:Toggle(true)
        end
    end

    visualized.updateScale(self)

    self:setOutline(self.outline)
end

---Respawn the decal to update parameters, if changed
---@param changed boolean
---@protected
function decal:updateFull(changed)
    if changed and self:isSpawned() then self:respawn() end
end

function decal:draw()
    spawnable.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize outline", "Alpha", "Vertical Flip", "Horizontal Flip", "Stretching Enabled", "Auto Hide Distance", "Order No", "Normal Threshold", "Roughness Scale", "Render Mode", "Surface Type", "Diffuse Color Scale" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    self:drawPreviewCheckbox("Visualize outline", self.maxPropertyWidth)

    style.mutedText("Alpha")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.alpha, changed, deactivatedAfterEdit = style.trackedDragFloat(self.object, "##alpha", self.alpha, 0.01, 0, 100, "%.2f", 85)
    self:updateFull(deactivatedAfterEdit)

    style.mutedText("Vertical Flip")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.verticalFlip, changed = style.trackedCheckbox(self.object, "##verticalFlip", self.verticalFlip)
    self:updateFull(ImGui.IsItemDeactivatedAfterEdit())

    style.mutedText("Horizontal Flip")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.horizontalFlip, changed = style.trackedCheckbox(self.object, "##horizontalFlip", self.horizontalFlip)
    self:updateFull(ImGui.IsItemDeactivatedAfterEdit())

    style.mutedText("Stretching Enabled")
    style.tooltip("If enabled, the decal will stretch to fit the surface it is projected onto.")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.isStretchingEnabled, changed = style.trackedCheckbox(self.object, "##isStretchingEnabled", self.isStretchingEnabled)
    self:updateFull(changed)

    style.mutedText("Auto Hide Distance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.autoHideDistance = style.trackedDragFloat(self.object, "##autoHideDistance", self.autoHideDistance, 0.05, 0, 9999, "%.2f", 85)

    style.mutedText("Order No")
    style.tooltip("Sort order for overlapping decals. Higher numbers draw on top.")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.orderNo, _, deactivatedAfterEdit = style.trackedDragInt(self.object, "##orderNo", self.orderNo, 0, 65535, 85)
    self:updateFull(deactivatedAfterEdit)

    style.mutedText("Normal Threshold")
    style.tooltip("Maximum angle, in degrees, between the decal and a surface for it to project onto it.")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.normalThreshold, _, deactivatedAfterEdit = style.trackedDragFloat(self.object, "##normalThreshold", self.normalThreshold, 0.05, 0, 90, "%.2f", 85)
    self:updateFull(deactivatedAfterEdit)

    style.mutedText("Roughness Scale")
    style.tooltip("Multiplier applied to the roughness of the surface underneath the decal.")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.roughnessScale, _, deactivatedAfterEdit = style.trackedDragFloat(self.object, "##roughnessScale", self.roughnessScale, 0.01, 0, 100, "%.2f", 85)
    self:updateFull(deactivatedAfterEdit)

    style.mutedText("Render Mode")
    style.tooltip("Which surfaces the decal draws on.\nDRM_AllStatic: world geometry such as ground, walls and props.\nDRM_ObjectType: only meshes of the type set in Surface Type, such as Road, Vehicle or Character.\nDRM_AllDynamic: entities such as vehicles and bodies.\nDRM_All: almost unused in vanilla, and did not draw in testing.")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.decalRenderMode, changed = style.trackedCombo(self.object, "##decalRenderMode", self.decalRenderMode, self.decalRenderModes, 130)
    self:updateFull(changed)

    if self.decalRenderModes[self.decalRenderMode + 1] == "DRM_ObjectType" then
        style.mutedText("Surface Type")
        style.tooltip("The decal draws only on meshes whose render object type matches this.\nThe type is set in the .mesh file: vehicles are ROT_Vehicle, characters ROT_Character, most world meshes ROT_Static.")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.surfaceType, changed = style.enumCombo(self.object, "##surfaceType", self.surfaceTypes, self.surfaceType, nil, 130)
        self:updateFull(changed)
    end

    style.mutedText("Diffuse Color Scale")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.diffuseColorScale, _, _ = style.trackedColorAlpha(self.object, "##diffuseColorScale", self.diffuseColorScale, 60)
    ImGui.SameLine()
    style.styledText(IconGlyphs.AlertOutline, style.warnColor)
    style.tooltip("Export only.\nWB preview does not support diffuseColorScale for decals.")
end

function decal:getProperties()
    return self:addNodeProperty(spawnable.getProperties(self))
end

function decal:getGroupedProperties()
    local properties = visualized.getGroupedProperties(self)

    properties["decalProperties"] = {
        name = "Decal",
        id = "decal",
        data = {
            alpha = 1,
            diffuseColorScale = { 1, 1, 1, 1 },
            maxPropertyWidth = nil
        },
        draw = function (element, entries)
            local data = element.groupOperationData["decalProperties"]

            if not data.maxPropertyWidth then
                data.maxPropertyWidth = utils.getTextMaxWidth({ "Alpha", "Diffuse Color Scale" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
            end

            style.mutedText("Alpha")
            ImGui.SameLine()
            ImGui.SetCursorPosX(data.maxPropertyWidth)
            data.alpha = style.trackedDragFloat(nil, "##groupDecalAlpha", data.alpha, 0.01, 0, 100, "%.2f", 85)
            ImGui.SameLine()
            if ImGui.Button("Apply##groupDecalAlpha") then
                history.addAction(history.getMultiSelectChange(entries))

                for _, entry in ipairs(entries) do
                    entry.spawnable.alpha = data.alpha
                    entry.spawnable:updateFull(true)
                end

                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Applied alpha to %s decals", #entries)))
            end
            style.tooltip("Set Alpha on every decal in the group.")

            style.mutedText("Diffuse Color Scale")
            ImGui.SameLine()
            ImGui.SetCursorPosX(data.maxPropertyWidth)
            data.diffuseColorScale = style.trackedColorAlpha(nil, "##groupDecalDiffuseColorScale", data.diffuseColorScale, 60)
            ImGui.SameLine()
            if ImGui.Button("Apply##groupDecalDiffuseColorScale") then
                history.addAction(history.getMultiSelectChange(entries))

                -- A fresh table per decal: one shared table would alias every decal to the widget.
                for _, entry in ipairs(entries) do
                    entry.spawnable.diffuseColorScale = {
                        data.diffuseColorScale[1],
                        data.diffuseColorScale[2],
                        data.diffuseColorScale[3],
                        data.diffuseColorScale[4]
                    }
                end

                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Applied diffuse color scale to %s decals", #entries)))
            end
            style.tooltip("Set Diffuse Color Scale on every decal in the group.\nExport only, WB preview does not show it.")
        end,
        entries = { self.object }
    }

    return properties
end

function decal:export()
    self.diffuseColorScale = colorUtil.normalizeChannels(self.diffuseColorScale, diffuseColorScaleNormalization)

    local data = spawnable.export(self)
    data.type = "worldStaticDecalNode"
    data.scale = self.scale
    data.data = {
        alpha = self.alpha,
        autoHideDistance = self.autoHideDistance,
        diffuseColorScale = {
            Red = self.diffuseColorScale[1],
            Green = self.diffuseColorScale[2],
            Blue = self.diffuseColorScale[3],
            Alpha = self.diffuseColorScale[4]
        },
        horizontalFlip = self.horizontalFlip and 1 or 0,
        verticalFlip = self.verticalFlip and 1 or 0,
        isStretchingEnabled = self.isStretchingEnabled and 1 or 0,
        orderNo = self.orderNo,
        normalThreshold = self.normalThreshold,
        roughnessScale = self.roughnessScale,
        decalRenderMode = self.decalRenderModes[self.decalRenderMode + 1],
        surfaceType = self.surfaceType,
        material = {
            DepotPath = {
                ["$storage"] = "string",
                ["$value"] = self.spawnData
            }
        }
    }

    return data
end

return decal
