local mesh = require("modules/classes/spawn/mesh/mesh")
local spawnable = require("modules/classes/spawn/spawnable")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
local rotatingMesh = require("modules/classes/spawn/mesh/rotatingMesh")
local settings = require("modules/utils/settings")

---Class for worldDynamicMeshNode
---@class dynamicMesh : mesh
---@field private startAsleep boolean
---@field private forceAutoHideDistance number
local dynamicMesh = setmetatable({}, { __index = mesh })

function dynamicMesh:new()
	local o = mesh.new(self)

    o.dataType = "Dynamic Mesh"
    o.modulePath = "physics/dynamicMesh"
    o.spawnDataPath = "data/spawnables/mesh/physics/"
    o.node = "worldDynamicMeshNode"
    o.description = "Places a mesh with simulated physics, from a given .mesh file. Not destructible."
    o.icon = IconGlyphs.CubeSend

    o.startAsleep = true
    o.hideGenerate = true
    o.forceAutoHideDistance = 150
    o.convertTarget = 0 -- 0=Static, 1=Rotating

    setmetatable(o, { __index = self })
   	return o
end

function dynamicMesh:onAssemble(entity)
    spawnable.onAssemble(self, entity)
    local component = PhysicalMeshComponent.new()
    component.name = "mesh"
    component.mesh = ResRef.FromString(self.spawnData)
    component.visualScale = Vector3.new(self.scale.x, self.scale.y, self.scale.z)
    component.meshAppearance = self.app

    if not self.isAssetPreview then
        component.simulationType = physicsSimulationType.Dynamic

        local filterData = physicsFilterData.new()
        filterData.preset = "World Dynamic"

        local query = physicsQueryFilter.new()
        query.mask1 = 0
        query.mask2 = 70107400

        local sim = physicsSimulationFilter.new()
        sim.mask1 = 114696
        sim.mask2 = 23627

        filterData.queryFilter = query
        filterData.simulationFilter = sim
        component.filterData = filterData
    end

    entity:AddComponent(component)

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    mesh.assetPreviewAssemble(self, entity)
end

function dynamicMesh:save()
    local data = mesh.save(self)
    data.startAsleep = self.startAsleep
    data.forceAutoHideDistance = self.forceAutoHideDistance or 150

    return data
end

function dynamicMesh:draw()
    local calculateMaxWidth = not self.maxPropertyWidth

    mesh.draw(self)

    if calculateMaxWidth then
        self.maxPropertyWidth = math.max(self.maxPropertyWidth, utils.getTextMaxWidth({ "Start Asleep", "Auto Hide Distance" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX())
    end

    style.mutedText("Start Asleep")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.startAsleep = style.trackedCheckbox(self.object, "##startAsleep", self.startAsleep)

    style.mutedText("Auto Hide Distance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.forceAutoHideDistance = style.trackedDragFloat(self.object, "##forceAutoHideDistance", self.forceAutoHideDistance, 0.1, 0, 1000, "%.1f")
    
    style.mutedText("Convert to")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)

    local options = {
        IconGlyphs.CubeOutline .. " Static Mesh",
        IconGlyphs.FormatRotate90 .. " Rotating Mesh"
    }
    local convertActions = { "static", "rotating" }

    if self:canConvertToClothMesh() then
        table.insert(options, IconGlyphs.ReceiptOutline .. " Cloth Mesh")
        table.insert(convertActions, "cloth")
    end

    self.convertTarget = math.max(0, math.min(self.convertTarget, #options - 1))
    self.convertTarget, _ = style.trackedCombo(self.object, "##converterType", self.convertTarget, options, 150)
    style.tooltip("Select the mesh type to convert into")
        
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth + 150 * style.viewSize + ImGui.GetStyle().ItemSpacing.x)
    style.pushButtonNoBG(false)
    if ImGui.Button("Convert") then
        if settings.skipLossyConversionWarning then
            history.addAction(history.getElementChange(self.object))
            local target = convertActions[self.convertTarget + 1]
            if target == "rotating" then
                self:convertToRotatingMesh()
            elseif target == "cloth" then
                self:convertToClothMesh()
            else
                self:convertToStaticMesh()
            end
        else
            ImGui.OpenPopup("Lossy Conversion##dynamicMeshSingle")
        end
    end

    if ImGui.BeginPopupModal("Lossy Conversion##dynamicMeshSingle", true, ImGuiWindowFlags.AlwaysAutoResize) then
        style.mutedText("Warning")
        ImGui.Text("This conversion is lossy.")
        ImGui.Text("Dynamic mesh specific properties will be removed.")
        ImGui.Text("Do you want to continue?")
        ImGui.Dummy(0, 8 * style.viewSize)
        local skipWarning, changed = ImGui.Checkbox("Do not ask again", settings.skipLossyConversionWarning)
        if changed then
            settings.skipLossyConversionWarning = skipWarning
            settings.save()
        end
        ImGui.Dummy(0, 8 * style.viewSize)

        if ImGui.Button("Convert") then
            history.addAction(history.getElementChange(self.object))
            local target = convertActions[self.convertTarget + 1]
            if target == "rotating" then
                self:convertToRotatingMesh()
            elseif target == "cloth" then
                self:convertToClothMesh()
            else
                self:convertToStaticMesh()
            end
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()
        if ImGui.Button("Cancel") then
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end
end

function dynamicMesh:convertToRotatingMesh()
    -- Ensure current dynamic mesh is despawned
    self:despawn()

    -- Create a rotating mesh instance to get default values
    local rotInstance = rotatingMesh:new()

    -- Change this object's metatable so it now inherits from rotatingMesh
    setmetatable(self, { __index = rotatingMesh })

    -- Update properties to reflect it's now a rotating mesh
    self.dataType = rotInstance.dataType
    self.modulePath = rotInstance.modulePath
    self.node = rotInstance.node
    self.description = rotInstance.description
    self.icon = rotInstance.icon

    -- Apply rotating-specific defaults
    self.duration = rotInstance.duration
    self.axis = rotInstance.axis
    self.reverse = rotInstance.reverse
    self.axisTypes = rotInstance.axisTypes
    self.cronID = rotInstance.cronID
    self.hideGenerate = rotInstance.hideGenerate

    -- Update the element's icon as well
    if self.object then
        self.object.icon = self.icon
    end

    -- Remove dynamic-mesh-specific properties
    self.startAsleep = nil
    self.forceAutoHideDistance = nil
    self.convertTarget = 0

    -- Respawn with the new rotating mesh properties
    self:respawn()
end

function dynamicMesh:convertToStaticMesh()
	-- Create a mesh instance to get default values
	local meshInstance = mesh:new()
	
	-- Change this object's metatable so it now inherits from mesh instead of dynamicMesh
	setmetatable(self, { __index = mesh })
	
	-- Update properties to reflect it's now a static mesh
	self.dataType = meshInstance.dataType
	self.modulePath = meshInstance.modulePath
	self.node = meshInstance.node
	self.description = meshInstance.description
	self.icon = meshInstance.icon
	
	-- Update the element's icon as well
	if self.object then
		self.object.icon = self.icon
	end
	
	-- Remove dynamic-mesh-specific properties
	self.startAsleep = nil
	self.forceAutoHideDistance = nil
	self.hideGenerate = nil
    self.convertTarget = 0
	
	-- Respawn with the new static mesh properties
	self:respawn()
end

function dynamicMesh:getProperties()
    local properties = spawnable.getProperties(self)
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

function dynamicMesh:getGroupedProperties()
    return spawnable.getGroupedProperties(self)
end

function dynamicMesh:export()
    local data = mesh.export(self)
    data.type = "worldDynamicMeshNode"
    data.data.startAsleep = self.startAsleep and 1 or 0
    data.data.forceAutoHideDistance = self.forceAutoHideDistance

    return data
end

return dynamicMesh
