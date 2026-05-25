local utils = require("modules/utils/utils")
local gameUtils = require("modules/utils/gameUtils")
local builder = require("modules/utils/entityBuilder")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")
local field = require("modules/utils/field")
local history = require("modules/utils/history")
local intersection = require("modules/utils/editor/intersection")
local registry = require("modules/utils/nodeRefRegistry")
local editor = require("modules/utils/editor/editor")
local GameSettings = require("modules/utils/GameSettings")
local preview = require("modules/utils/previewUtils")
local logger = require("modules/utils/logger")

---Base class for any object / node that can be spawned
---@class spawnable
---@field public dataType string
---@field public spawnListType string
---@field public spawnListPath string
---@field public modulePath string
---@field public spawnData string
---@field public app string
---@field public position Vector4
---@field public rotation EulerAngles
---@field protected entityID entEntityID
---@field protected entity entEntity?
---@field protected spawned boolean
---@field protected spawning boolean
---@field protected despawning boolean
---@field protected queueRespawn boolean
---@field public primaryRange number
---@field public uk10 integer
---@field public uk11 integer
---@field protected streamingMultiplier number
---@field public isHovered boolean
---@field protected arrowDirection string all|red|green|blue
---@field public object element? The element that is using this spawnable
---@field public node string
---@field public description string
---@field public previewNote string
---@field public icon string
---@field public secondaryIcon string
---@field private rotationRelative boolean
---@field protected outline integer
---@field private spawnedAndCachedCallback function[]
---@field protected spawnGeneration integer
---@field protected currentSpawnToken {generation: integer, entityHash: integer}?
---@field protected nodeRef string
---@field public noExport boolean
---@field private worldNodePropertyWidth number
---@field private streamingPropertyWidth number
---@field private streamingPresetIndex integer
---@field public assetPreviewType string none|backdrop|current_position
---@field public assetPreviewDelay number
---@field public isAssetPreview boolean
---@field private assetPreviewLensDistortion boolean
---@field public streamingRefPointOverride boolean
---@field public streamingRefPoint Vector4
---@field public visualizeStreamingRange boolean
local spawnable = {}
local streamingPresetLabels = {
    "Interior",
    "Street",
    "District",
    "Landscape",
    "To the Moon"
}
local streamingPresetValues = {
    100,
    400,
    1000,
    5000,
    3.4028235e+38 -- Effectively infinite
}
local streamingPresetVersion = 2

function spawnable:new()
	local o = {}

    o.dataType = "Spawnable"
    o.spawnListType = "list"
    o.spawnListPath = "data/spawnables/entity/templates/"
    o.modulePath = "spawnable"
    o.node = "worldEntityNode"
    o.description = ""
    o.previewNote = "---"
    o.icon = ""
    o.secondaryIcon = ""

    o.spawnData = "base\\spawner\\empty_entity.ent"
    o.app = "default"

    o.position = Vector4.new(0, 0, 0, 0)
    o.rotation = EulerAngles.new(0, 0, 0)
    o.entityID = entEntityID.new({hash = 0})
    o.entity = nil
    o.spawned = false
    o.spawning = false
    o.despawning = false
    o.queueRespawn = false
    o.spawnedAndCachedCallback = {}
    o.spawnGeneration = 0
    o.currentSpawnToken = nil
    o.worldNodePropertyWidth = nil
    o.streamingPropertyWidth = nil
    o.streamingPresetIndex = 0

    o.noExport = false
    o.primaryRange = 120
    o.uk10 = 1024
    o.uk11 = 512
    o.streamingMultiplier = 1
    o.nodeRef = ""
    o.streamingRefPointOverride = false
    o.streamingRefPoint = Vector4.new(0, 0, 0, 0)
    o.visualizeStreamingRange = false

    o.isHovered = false
    o.arrowDirection = "none"
    o.rotationRelative = false
    o.outline = 0

    o.assetPreviewType = "none"
    o.assetPreviewDelay = 0.1
    o.isAssetPreview = false
    o.assetPreviewLensDistortion = false

    o.object = object

    self.__index = self
   	return setmetatable(o, self)
end

function spawnable:onAssemble(entity)
    visualizer.attachArrows(entity, self:getArrowSize(), self.isHovered, self.arrowDirection)
end

function spawnable:onAttached(entity)
    self.spawned = true
    self.spawning = false

    for _, callback in ipairs(self.spawnedAndCachedCallback) do
        callback(entity)
    end

    if self.despawning then
        self.despawning = false
        self:despawn()
    end

    if self.queueRespawn then
        self.queueRespawn = false
        self:respawn()
    end
end

function spawnable:registerSpawnedAndAttachedCallback(callback)
    table.insert(self.spawnedAndCachedCallback, callback)
end

---Returns a snapshot token that identifies the current spawn lifetime.
---@return {generation: integer, entityHash: integer}?
function spawnable:getSpawnLifetimeToken()
    if type(self.currentSpawnToken) ~= "table" then
        return nil
    end

    return {
        generation = self.currentSpawnToken.generation,
        entityHash = self.currentSpawnToken.entityHash
    }
end

---Checks whether the provided token still matches the currently active spawn lifetime.
---@param token {generation: integer, entityHash: integer}?
---@param entity entEntity?
---@return boolean
function spawnable:isSpawnLifetimeTokenCurrent(token, entity)
    if type(token) ~= "table" or type(self.currentSpawnToken) ~= "table" then
        return false
    end

    if token.generation ~= self.currentSpawnToken.generation then
        return false
    end

    if token.entityHash ~= self.currentSpawnToken.entityHash then
        return false
    end

    if entity ~= nil then
        local okEntityId, entityId = pcall(function ()
            return entity:GetEntityID()
        end)

        if okEntityId and entityId and entityId.hash and entityId.hash ~= token.entityHash then
            return false
        end
    end

    return true
end

---Spawns the spawnable if not spawned already, must register a callback for entityAssemble which calls onAssemble
---@param ignoreSpawning boolean? If true, spawn call will be issued even if already spawning
function spawnable:spawn(ignoreSpawning)
    if self:isSpawned() or (self.spawning and not ignoreSpawning) then
        return false
    end

    local templatePath = type(self.spawnData) == "string" and self.spawnData or ""
    if utils.trimString(templatePath) == "" then
        logger:warn(string.format("Refused to spawn \"%s\": empty template path", tostring(self.dataType or "unknown")))
        return false
    end

    local spec = StaticEntitySpec.new()
    spec.templatePath = templatePath
    spec.position = self.position
    spec.orientation = self.rotation:ToQuat()
    spec.attached = true
    spec.appearanceName = self.app
    local spawnedId = Game.GetStaticEntitySystem():SpawnEntity(spec)
    if not spawnedId or not spawnedId.hash or spawnedId.hash == 0 then
        self.spawning = false
        self.spawned = false
        logger:warn(string.format("Failed to spawn template path \"%s\" (%s)", templatePath, tostring(self.dataType or "unknown")))
        return false
    end

    self.entityID = spawnedId
    self.spawnGeneration = self.spawnGeneration + 1
    local token = {
        generation = self.spawnGeneration,
        entityHash = self.entityID.hash
    }
    self.currentSpawnToken = token
    self.spawning = true

    builder.registerAssembleCallback(self.entityID, function (entity)
        if not self:isSpawnLifetimeTokenCurrent(token, entity) then return end
        self.entity = entity
        self:onAssemble(entity)
    end)

    builder.registerAttachCallback(self.entityID, function (entity)
        if not self:isSpawnLifetimeTokenCurrent(token, entity) then return end
        self:onAttached(entity)
    end)

    return true
end

---@return boolean
function spawnable:isSpawned()
    return self.spawned
end

function spawnable:despawn()
    local entity = self:getEntity()
    if entity then
        Game.GetStaticEntitySystem():DespawnEntity(self.entityID)
    end
    self.spawned = false
    self.entity = nil

    if self.spawning then
        self.despawning = true
    end
end

function spawnable:respawn()
    self:despawn()
    self:spawn()
end

---@param target string
---@return boolean converted
function spawnable:convertSpawnableTo(target)
    if not self.object then return false end

    local data = self.object:serialize()
    if not data or not data.spawnable then return false end

    data.spawnable.modulePath = target
    self.object:load(data, self.object.silent)

    return true
end

---Update the position and rotation of the spawnable
function spawnable:update()
    if not self:isSpawned() then return end

    local entity = self:getEntity()

    if not entity then return end

    local transform = entity:GetWorldTransform()
    transform:SetPosition(self.position)
    transform:SetOrientationEuler(self.rotation)
    entity:SetWorldTransform(transform)
end

---@param finished boolean
---@param delta Vector4
function spawnable:updateScale(finished, delta) end

function spawnable:onParentChanged(newParent) end

function spawnable:onObjectRemoved() end

function spawnable:setOutline(color)
    if not self:isSpawned() then return end

    self.outline = color
    utils.sendOutlineEvent(self:getEntity(), color)
end

---Called when one of the control UI widgets is released
function spawnable:onEdited(edited) end

---@return entEntity?
function spawnable:getEntity()
    local liveEntity = Game.GetStaticEntitySystem():GetEntity(self.entityID)
    if liveEntity then
        return liveEntity
    end

    if self.entity then
        local okEntityId, entityId = pcall(function ()
            return self.entity:GetEntityID()
        end)

        if okEntityId and entityId and entityId.hash and self.entityID and entityId.hash == self.entityID.hash then
            return self.entity
        end
    end

    return nil
end

--- Generate valid name from given name / path
---@param name string
---@return string newName The generated/sanitized name
function spawnable:generateName(name)
    if string.find(name, "\\") then
        name = name:match("\\[^\\]*$") -- Everything after last \
    end
    name = name:gsub(".ent", ""):gsub("\\", "_") -- Remove .ent, replace \ by _
    return utils.createFileName(name)
end

---Return the spawnable data for internal object format saving
---@return table {modulePath, position, rotation, spawnData, dataType, app}
function spawnable:save()
    return {
        modulePath = self.modulePath,
        position = { x = self.position.x, y = self.position.y, z = self.position.z, w = 0 },
        rotation = { roll = self.rotation.roll, pitch = self.rotation.pitch, yaw = self.rotation.yaw },
        spawnData = self.spawnData,
        dataType = self.dataType,
        app = self.app,
        rotationRelative = self.rotationRelative,
        primaryRange = self.primaryRange,
        uk10 = self.uk10,
        uk11 = self.uk11,
        nodeRef = self.nodeRef,
        streamingRefPointOverride = self.streamingRefPointOverride,
        streamingRefPoint = utils.fromVector(self.streamingRefPoint),
        visualizeStreamingRange = self.visualizeStreamingRange,
        streamingPresetIndex = self.streamingPresetIndex,
        streamingPresetVersion = streamingPresetVersion
    }
end

function spawnable:draw() end

---Optional per-class transform UI visibility contract consumed by positionable UI.
---Return nil to use defaults.
---@return table?
function spawnable:getTransformUIConfig()
    return nil
end

function spawnable:getProperties()
    local properties =  {}

    table.insert(properties, {
        id = "worldNode",
        name = "World Node",
        defaultHeader = false,
        draw = function()
            if not self.worldNodePropertyWidth then
                self.worldNodePropertyWidth = utils.getTextMaxWidth({ "Asset Path", "Node Ref" }) + ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
            end

            local entry = self.nodeRef ~= "" and registry.refs[self.object:getRootParent().name] and registry.refs[self.object:getRootParent().name][self.nodeRef]
            local refDuplicate = entry and (entry.path ~= self.object:getPath() or entry.duplicate)
            local assetPath = self.spawnData or ""

            style.mutedText("Asset Path")
            ImGui.SameLine()
            ImGui.SetCursorPosX(self.worldNodePropertyWidth)
            style.pushButtonNoBG(true)
            if ImGui.Button(IconGlyphs.ContentCopy .. "##copyAssetPath") then
                ImGui.SetClipboardText(assetPath)
                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Copied asset path to clipboard"))
            end
            style.pushButtonNoBG(false)
            style.tooltip("Copy asset path to clipboard")
            ImGui.SameLine()
            ImGui.Text(utils.shortenPath(assetPath, style.getMaxWidth(250), true))
            style.tooltip(assetPath)

            style.mutedText("Node Ref")
            ImGui.SameLine()
            ImGui.SetCursorPosX(self.worldNodePropertyWidth)
            local nodeRefValue, nodeRefChanged, _ = style.trackedTextField(self.object, "##noderef", self.nodeRef, "$/#foobar", style.getMaxWidth(250) - 30 - (refDuplicate and 25 or 0))
            self.nodeRef = nodeRefValue
            if nodeRefChanged then
                logger:info(string.format("NodeRef for %s changed to \"%s\"", self.object:getPath(), self.nodeRef))
                logger:warn(string.format("NodeRef for %s changed to \"%s\"", self.object:getPath(), self.nodeRef))
                logger:error(string.format("NodeRef for %s changed to \"%s\"", self.object:getPath(), self.nodeRef))
                registry.invalidate()
            end
            style.pushButtonNoBG(true)
            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.ReloadAlert) then
                local generated = registry.generate(self.object)

                if generated ~= self.nodeRef then
                    history.addAction(history.getElementChange(self.object))
                    self.nodeRef = generated
                    registry.invalidate()
                end
            end
            style.pushButtonNoBG(false)
            style.tooltip("Generate a unique NodeRef for this object")

            if refDuplicate then
                ImGui.SameLine()
                style.styledText(IconGlyphs.AlertOutline, 0xFF0000FF)
                style.tooltip("NodeRef is already in use elsewhere")
            end
            if ImGui.TreeNodeEx("Streaming Distance", ImGuiTreeNodeFlags.SpanFullWidth) then
                if not self.streamingPropertyWidth then
                    self.streamingPropertyWidth = utils.getTextMaxWidth({ "Visualize", "Distance Preset", "Streaming Distance", "Auto-Set Multiplier", "Custom Reference Point", "Streaming Ref. Point" }) + ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
                end

                style.mutedText("Visualize")
                ImGui.SameLine()
                ImGui.SetCursorPosX(self.streamingPropertyWidth)
                self.visualizeStreamingRange, _ = style.trackedCheckbox(self.object, "##visualizeStreamingRange", self.visualizeStreamingRange)

                style.mutedText("Distance Preset")
                ImGui.SameLine()
                ImGui.SetCursorPosX(self.streamingPropertyWidth)
                ImGui.SetNextItemWidth(140 * style.viewSize)
                self.streamingPresetIndex = ImGui.Combo("##streamingDistancePreset", self.streamingPresetIndex, streamingPresetLabels, #streamingPresetLabels)
                style.tooltip("Quickly set Streaming Distance to a common value.\n- Interior | 100: Small rooms and indoor props loaded only when close.\n- Street | 400: Regular city assets visible from nearby streets.\n- District | 1000: Medium-large city chunks visible across a wider district area.\n- Landscape | 5000: Large outdoor landmarks visible from far away.\n- To the Moon | infinite: Keep visible from anywhere; use only for very important assets.")
                ImGui.SameLine()
                if ImGui.Button("Apply##streamingDistancePreset") then
                    history.addAction(history.getElementChange(self.object))
                    self.primaryRange = streamingPresetValues[(self.streamingPresetIndex or 0) + 1] or self.primaryRange
                end
                style.tooltip("Apply the selected preset to Streaming Distance.")

                style.mutedText("Streaming Distance")
                ImGui.SameLine()
                ImGui.SetCursorPosX(self.streamingPropertyWidth)
                self.primaryRange, _, _ = field.advancedTrackedFloat(self.object, "##primaryRange", self.primaryRange, {
                    step = 0.1,
                    min = 0,
                    max = 3.4028235e+38,
                    format = "%.1f",
                    width = 90
                })
                ImGui.SameLine()
                local distance = utils.distanceVector(self:getStreamingReferencePoint(), GetPlayer():GetWorldPosition())
                style.styledText(IconGlyphs.AxisArrowInfo, distance > self.primaryRange and 0xFF0000FF or 0xFF00FF00)
                style.tooltip(string.format("Distance to from %s: %.2f", self.streamingRefPointOverride and "reference point" or "node position", distance))

                style.mutedText("Auto-Set Multiplier")
                ImGui.SameLine()
                ImGui.SetCursorPosX(self.streamingPropertyWidth)
                ImGui.SetNextItemWidth(90 * style.viewSize)
                self.streamingMultiplier, _ = ImGui.DragFloat("##autoSetMultiplier", self.streamingMultiplier, 0.01, 0, 50, "x%.2f")
                style.tooltip("Multiplier for streaming values, when using \"Auto-Set\"")

                ImGui.SameLine()

                if ImGui.Button("Auto-Set") then
                    history.addAction(history.getElementChange(self.object))
                    local values = self:calculateStreamingValues(self.streamingMultiplier)

                    self.primaryRange = values.primary
                end

                style.mutedText("Custom Reference Point")
                ImGui.SameLine()
                ImGui.SetCursorPosX(self.streamingPropertyWidth)
                self.streamingRefPointOverride, _ = ImGui.Checkbox("##streamingRefPointOverride", self.streamingRefPointOverride)
                style.tooltip("When enabled, streaming distance uses the custom point below.\nWhen disabled, it uses node's position.\nUse this if you want this asset to be visible from a specific, distant location.")

                if self.streamingRefPointOverride then
                    style.mutedText("Streaming Ref. Point")
                    ImGui.SameLine()
                    ImGui.SetCursorPosX(self.streamingPropertyWidth)
                    self.streamingRefPoint.x, _, _ = style.trackedDragFloat(self.object, "##streamingRefPointX", self.streamingRefPoint.x, 0.05, -99999, 99999, "%.2f X", 75)
                    ImGui.SameLine()
                    self.streamingRefPoint.y, _, _ = style.trackedDragFloat(self.object, "##streamingRefPointY", self.streamingRefPoint.y, 0.05, -99999, 99999, "%.2f Y", 75)
                    ImGui.SameLine()
                    self.streamingRefPoint.z, _, _ = style.trackedDragFloat(self.object, "##steamingRefPoinZ", self.streamingRefPoint.z, 0.05, -99999, 99999, "%.2f Z", 75)
                    ImGui.SameLine()
                    if style.drawNoBGConditionalButton(true, IconGlyphs.AccountArrowLeftOutline) then
                        history.addAction(history.getElementChange(self.object))
                        self.streamingRefPoint = gameUtils.getPlayerPosition(editor.active)
                    end
                    style.tooltip("Set the streaming reference point to the player position")
                end

                ImGui.TreePop()
            end
        end
    })

    return properties
end

function spawnable:getGroupedProperties()
    local properties = {}

	properties["streamingProperties"] = {
		name = "World Node",
        id = "worldNode",
		data = {
            multiplier = 1,
            presetIndex = 0,
            maxPropertyWidth = nil
        },
		draw = function(element, entries)
            if not element.groupOperationData["streamingProperties"].maxPropertyWidth then
                element.groupOperationData["streamingProperties"].maxPropertyWidth = utils.getTextMaxWidth({ "Streaming Distances", "Distances Multiplier", "Distance Preset", "NodeRef's", "Custom Reference Point", "Streaming Ref. Point" }) + ImGui.GetStyle().ItemSpacing.x * 4 + ImGui.GetCursorPosX()
            end

            style.mutedText("NodeRef's")
            ImGui.SameLine()
            ImGui.SetCursorPosX(element.groupOperationData["streamingProperties"].maxPropertyWidth)
            if ImGui.Button("Auto-Generate") then
                history.addAction(history.getMultiSelectChange(entries))

                for _, entry in ipairs(entries) do
                    local generated = registry.generate(entry.spawnable.object)
                    entry.spawnable.nodeRef = generated
                end
                registry.invalidate()

                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Auto-Generated NodeRef's for %s nodes", #entries)))
            end

            if ImGui.TreeNodeEx("Streaming Distances", ImGuiTreeNodeFlags.SpanFullWidth) then
                style.mutedText("Distance Preset")
                ImGui.SameLine()
                ImGui.SetCursorPosX(element.groupOperationData["streamingProperties"].maxPropertyWidth)
                ImGui.SetNextItemWidth(140 * style.viewSize)
                element.groupOperationData["streamingProperties"].presetIndex = ImGui.Combo("##groupStreamingDistancePreset", element.groupOperationData["streamingProperties"].presetIndex, streamingPresetLabels, #streamingPresetLabels)
                style.tooltip("Quickly set Streaming Distance to a common value.\n- Interior | 100: Small rooms and indoor props loaded only when close.\n- Street | 400: Regular city assets visible from nearby streets.\n- District | 1000: Medium-large city chunks visible across a wider district area.\n- Landscape | 5000: Large outdoor landmarks visible from far away.\n- To the Moon | infinite: Keep visible from anywhere; use only for very important assets.")
                ImGui.SameLine()
                if ImGui.Button("Apply##groupStreamingDistancePreset") then
                    history.addAction(history.getMultiSelectChange(entries))

                    local preset = streamingPresetValues[(element.groupOperationData["streamingProperties"].presetIndex or 0) + 1]
                    for _, entry in ipairs(entries) do
                        entry.spawnable.primaryRange = preset or entry.spawnable.primaryRange
                        entry.spawnable.streamingPresetIndex = element.groupOperationData["streamingProperties"].presetIndex or entry.spawnable.streamingPresetIndex
                    end

                    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Applied streaming distance preset to %s nodes", #entries)))
                end
                style.tooltip("Apply the selected preset to Streaming Distance.")

                style.mutedText("Distances Multiplier")
                ImGui.SetNextItemWidth(80 * style.viewSize)
                ImGui.SameLine()
                ImGui.SetCursorPosX(element.groupOperationData["streamingProperties"].maxPropertyWidth)
                element.groupOperationData["streamingProperties"].multiplier, _ = ImGui.DragFloat("##groupStreamingDistancesMultiplier", element.groupOperationData["streamingProperties"].multiplier, 0.01, 0, 50, "x%.2f")
                style.tooltip("Multiplier for streaming values, when using \"Auto-Set\"")
                ImGui.SameLine()
                if ImGui.Button("Auto-Set") then
                    history.addAction(history.getMultiSelectChange(entries))

                    for _, entry in ipairs(entries) do
                        local values = entry.spawnable:calculateStreamingValues(element.groupOperationData["streamingProperties"].multiplier * entry.spawnable.streamingMultiplier)

                        entry.spawnable.primaryRange = values.primary
                    end

                    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Auto-Set streaming distance for %s nodes", #entries)))
                end

                style.mutedText("Custom Reference Point")
                ImGui.SameLine()
                ImGui.SetCursorPosX(element.groupOperationData["streamingProperties"].maxPropertyWidth)
                if ImGui.Button("On") then
                    history.addAction(history.getMultiSelectChange(entries))

                    for _, entry in ipairs(entries) do
                        entry.spawnable.streamingRefPointOverride = true
                    end

                    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("[On] Enabled custom reference point for %s nodes", #entries)))
                end
                ImGui.SameLine()
                if ImGui.Button("Off") then
                    history.addAction(history.getMultiSelectChange(entries))

                    for _, entry in ipairs(entries) do
                        entry.spawnable.streamingRefPointOverride = false
                    end

                    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("[Off] Disabled custom reference point for %s nodes", #entries)))
                end

                style.mutedText("Streaming Ref. Point")
                ImGui.SameLine()
                ImGui.SetCursorPosX(element.groupOperationData["streamingProperties"].maxPropertyWidth)
                if ImGui.Button("To Player Position") then
                    history.addAction(history.getMultiSelectChange(entries))

                    for _, entry in ipairs(entries) do
                        entry.spawnable.streamingRefPoint = gameUtils.getPlayerPosition(editor.active)
                    end

                    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Set Streaming Ref. Point to player position for %s nodes", #entries)))
                end

                ImGui.TreePop()
            end
		end,
		entries = { self.object }
	}

    return properties
end

---Returns the world position of the top left corner, which shall act as anchor for any HUD text of the asset preview
function spawnable:getAssetPreviewTextAnchor()
    return self.position
end

--Should be called once getAssetPreviewTextAnchor will return the correct position (BBOX loaded)
function spawnable:setAssetPreviewTextPostition()
    if not preview.elements["previewFirstLine"] then return end

    local x, y = editor.camera.worldToScreen(self:getAssetPreviewTextAnchor())

    local width, height = GetDisplayResolution()
    local factor = width / 2560
    local rx, ry = (x + 1) * width / 2, (- y + 1) * height / 2

    ry = ry + 20 * factor
    rx = rx + 20 * factor

    preview.elements["previewFirstLine"]:SetTranslation(rx, ry)
    preview.elements["previewSecondLine"]:SetTranslation(rx, ry + 40 * factor)
    preview.elements["previewThirdLine"]:SetTranslation(rx, ry + 80 * factor)
end

---Position where the asset preview should be spawned, the actual entity position
---@protected
---@param distance number?
function spawnable:getAssetPreviewPosition(distance)
    if self.assetPreviewType == "backdrop" then
        return editor.getForward((distance or 1) * (68 / GetPlayer():GetFPPCameraComponent():GetFOV()))
    end
    return self.position
end

--Attach any custom components needed
function spawnable:assetPreviewAssemble(entity)
end

--Assumes entity is fully spawned and BBOX is loaded, set to proper position. Called each frame.
function spawnable:assetPreviewSetPosition()
    self.position = self:getAssetPreviewPosition()
    self:update()
end

---Asset preview can be either not enabled, use the current position, or a backdrop (Must be implemented by the object)
---@param state boolean
function spawnable:assetPreview(state)
    self.isAssetPreview = true
    if self.assetPreviewType == "none" then return end

    if state then
        -- Needed, to avoid text being off due to screen curvature effect
        if self.assetPreviewType == "backdrop" and editor.active then
            self.assetPreviewLensDistortion = GameSettings.Get("/accessibility/interface/LensDistortionOverride")
            GameSettings.Set("/accessibility/interface/LensDistortionOverride", true)
        end
        if self.assetPreviewType == "backdrop" then
            self.position = utils.addVector(GetPlayer():GetWorldPosition(), Vector4.new(0, 0, -50, 0))
        end
        -- Only move into position once bbox is loaded, see first assetPreviewSetPosition call
        self:spawn()
        self:registerSpawnedAndAttachedCallback(function ()
            self:assetPreviewSetPosition()
            self:setAssetPreviewTextPostition()
        end)
    else
        if self.assetPreviewType == "backdrop" and preview.elements["previewFirstLine"] then
            preview.elements["previewFirstLine"]:SetVisible(false)
            preview.elements["previewSecondLine"]:SetVisible(false)
            preview.elements["previewThirdLine"]:SetVisible(false)
            if editor.active then GameSettings.Set("/accessibility/interface/LensDistortionOverride", self.assetPreviewLensDistortion) end
        end
        self:despawn()
    end
end

---Gets the actual physical size of the spawnable, usually BBOX
---@return table {x, y, z}
function spawnable:getSize()
    return { x = 1, y = 1, z = 1 }
end

function spawnable:getBBox()
    local size = self:getSize()
    return {
        min = { x = -size.x / 2, y = -size.y / 2, z = -size.z / 2 },
        max = { x = size.x / 2, y = size.y / 2, z = size.z / 2 }
    }
end

function spawnable:getArrowSize()
    local size = self:getSize()
    local max = math.min(math.max(size.x, size.y, size.z, 0.75) * 0.4, 1)
    return { x = max, y = max, z = max }
end

function spawnable:getCenter()
    return self.position
end

---Returns the active streaming reference point (node position or overridden reference point)
---@return Vector4
function spawnable:getStreamingReferencePoint()
    if self.streamingRefPointOverride then
        return self.streamingRefPoint
    end

    return self.position
end

function spawnable:calculateIntersection(origin, ray)
    local bbox = self:getBBox()

    if not self:getEntity() then
        return { hit = false }
    end

    local result = intersection.getBoxIntersection(origin, ray, self.position, self.rotation, bbox)

    return {
        hit = result.hit,
        position = result.position,
        unscaledHit = result.position, -- Hit result of intersection test with unmodified bbox, for more accurate drop to surface
        collisionType = "bbox",
        distance = result.distance,
        bBox = bbox,
        objectOrigin = self.position,
        objectRotation = self.rotation,
        normal = result.normal
    }
end

---Calculates the streaming distance values for the spawnable based on getSize()
---@param multiplier number
---@return table {primary, secondary, uk10, uk11}
function spawnable:calculateStreamingValues(multiplier)
    -- TODO: Maybe make the multiplier scale non-linearly, so small things get boosted less than big things
    -- multiplier = math.min(1, math.max(0, falloffRange * math.log(math.max(0, maxAxis + minSize))))
    local scale = self:getSize()

    local primary = math.max(math.max(scale.x, scale.y, scale.z) * multiplier * 60, 25)
    primary = math.min(primary, 200 * multiplier)
    local secondary = primary * 1.2

    return { primary = primary, secondary = secondary, uk10 = self.uk10, uk11 = self.uk11 }
end

---Load data blob, position and rotation for spawning
---@param data table
---@param position Vector4
---@param rotation EulerAngles
function spawnable:loadSpawnData(data, position, rotation)
    for key, value in pairs(data) do
        if self[key] ~= nil then
            self[key] = value
        end
    end

    self.position = position
    self.rotation = rotation
    self.rotationRelative = data.rotationRelative or false
    self.primaryRange = data.primaryRange or 100
    local presetIndex = data.streamingPresetIndex or self.streamingPresetIndex or 0
    local presetVersion = data.streamingPresetVersion or 1
    if presetVersion < streamingPresetVersion and presetIndex >= 2 then
        presetIndex = presetIndex + 1
    end
    self.streamingPresetIndex = math.min(presetIndex, #streamingPresetLabels - 1)
    self.uk10 = data.uk10 or self.uk10
    self.uk11 = data.uk11 or self.uk11

    self.streamingRefPointOverride = data.streamingRefPointOverride or false
    self.streamingRefPoint = data.streamingRefPoint and utils.getVector(data.streamingRefPoint) or Vector4.new(0, 0, 0, 0)
end

---Export the spawnable for WScript import, using same structure for `data` as JSON formated node
---@param key integer Index of the object in the group
---@param length integer Amount of objects in the group
---@return table {position, rotation, scale, type, data}
function spawnable:export(key, length)
    return {
        position = utils.fromVector(self.position),
        streamingRefPoint = utils.fromVector(self:getStreamingReferencePoint()),
        rotation = utils.fromQuaternion(self.rotation:ToQuat()),
        scale = { x = 1, y = 1, z = 1 },
        primaryRange = self.primaryRange,
        secondaryRange = self.primaryRange * 0.85,
        uk10 = self.uk10,
        uk11 = self.uk11,
        nodeRef = self.nodeRef,
        type = "worldEntityNode",
        name = "[" .. self.dataType .. "] " .. self.object.name,
        data = {
            entityTemplate = {
                DepotPath = {
                    ["$type"] = "ResourcePath",
                    ["$storage"] = "string",
                    ["$value"] = self.spawnData
                }
            },
            appearanceName = {
                ["$type"] = "CName",
                ["$storage"] = "string",
                ["$value"] = self.app
            }
        }
    }
end

return spawnable
