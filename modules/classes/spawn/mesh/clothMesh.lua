local mesh = require("modules/classes/spawn/mesh/mesh")
local spawnable = require("modules/classes/spawn/spawnable")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
local rotatingMesh = require("modules/classes/spawn/mesh/rotatingMesh")
local settings = require("modules/utils/settings")

---Class for worldRotatingMeshNode
---@class clothMesh : mesh
---@field private affectedByWind boolean
---@field private collisionType integer
local clothMesh = setmetatable({}, { __index = mesh })

local collisionTypes = { "SPHERE", "BOX", "CONVEX", "TRIMESH", "CAPSULE" }

function clothMesh:new()
	local o = mesh.new(self)

    o.dataType = "Cloth Mesh"
    o.modulePath = "mesh/clothMesh"
    o.spawnDataPath = "data/spawnables/mesh/cloth/"
    o.node = "worldClothMeshNode"
    o.description = "Places a cloth mesh with physics, from a given .mesh file"
    o.previewNote = "Cloth meshes do not have simulated physics in the editor"
    o.icon = IconGlyphs.ReceiptOutline

    o.affectedByWind = false
    o.collisionType = 4
    o.hideGenerate = true
    o.convertTarget = 0

    setmetatable(o, { __index = self })
   	return o
end

function clothMesh:save()
    local data = mesh.save(self)
    data.affectedByWind = self.affectedByWind
    data.collisionType = self.collisionType

    return data
end

function clothMesh:draw()
    local calculateMaxWidth = not self.maxPropertyWidth

    mesh.draw(self)

    if calculateMaxWidth then
        self.maxPropertyWidth = math.max(self.maxPropertyWidth, utils.getTextMaxWidth({ "Affected By Wind", "Collision Mask" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX())
    end

    style.mutedText("Affected By Wind")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.affectedByWind = style.trackedCheckbox(self.object, "##affectedByWind", self.affectedByWind)

    style.mutedText("Collision Mask")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.collisionType = style.trackedCombo(self.object, "##collisionMask", self.collisionType, collisionTypes)

    ImGui.PopItemWidth()

    style.mutedText("Convert to")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local options = {
        IconGlyphs.CubeOutline .. " Static Mesh",
        IconGlyphs.FormatRotate90 .. " Rotating Mesh"
    }
    self.convertTarget, _ = style.trackedCombo(self.object, "##clothConverterType", self.convertTarget, options, 150)
    style.tooltip("Select the mesh type to convert into")

    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth + 150 * style.viewSize + ImGui.GetStyle().ItemSpacing.x)
    style.pushButtonNoBG(false)
    if ImGui.Button("Convert") then
        if settings.skipLossyConversionWarning then
            history.addAction(history.getElementChange(self.object))
            if self.convertTarget == 1 then
                self:convertToRotatingMesh()
            else
                self:convertToStaticMesh()
            end
        else
            ImGui.OpenPopup("Lossy Conversion##clothMeshSingle")
        end
    end

    if ImGui.BeginPopupModal("Lossy Conversion##clothMeshSingle", true, ImGuiWindowFlags.AlwaysAutoResize) then
        style.mutedText("Warning")
        ImGui.Text("This conversion is lossy.")
        ImGui.Text("Cloth mesh specific properties will be removed.")
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
            if self.convertTarget == 1 then
                self:convertToRotatingMesh()
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

function clothMesh:convertToStaticMesh()
	-- Create a mesh instance to get default values
	local meshInstance = mesh:new()
	
	-- Change this object's metatable so it now inherits from mesh instead of clothMesh
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
	
	-- Remove cloth-mesh-specific properties
	self.affectedByWind = nil
	self.collisionType = nil
	self.hideGenerate = nil
    self.convertTarget = 0
	
	-- Respawn with the new static mesh properties
	self:respawn()
end

function clothMesh:convertToRotatingMesh()
    -- Ensure current cloth mesh is despawned
    self:despawn()

    -- Create rotating mesh defaults
    local rotInstance = rotatingMesh:new()

    -- Change metatable to rotatingMesh
    setmetatable(self, { __index = rotatingMesh })

    -- Update properties
    self.dataType = rotInstance.dataType
    self.modulePath = rotInstance.modulePath
    self.node = rotInstance.node
    self.description = rotInstance.description
    self.icon = rotInstance.icon

    -- Apply rotating defaults
    self.duration = rotInstance.duration
    self.axis = rotInstance.axis
    self.reverse = rotInstance.reverse
    self.axisTypes = rotInstance.axisTypes
    self.cronID = rotInstance.cronID
    self.hideGenerate = rotInstance.hideGenerate

    if self.object then
        self.object.icon = self.icon
    end

    -- Remove cloth-specific properties
    self.affectedByWind = nil
    self.collisionType = nil
    self.hideGenerate = nil
    self.convertTarget = 0

    -- Respawn as rotating mesh
    self:respawn()
end

function clothMesh:export()
    local data = mesh.export(self)
    data.type = "worldClothMeshNode"
    data.data.affectedByWind = self.affectedByWind and 1 or 0
    data.data.collisionMask = collisionTypes[self.collisionType + 1]

    return data
end

function clothMesh:getProperties()
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

function clothMesh:getGroupedProperties()
    local properties = spawnable.getGroupedProperties(self)

    properties["clothMesh"] = {
        name = "Cloth Mesh",
        id = "clothMesh",
        data = {
            convertTarget = 0
        },
        draw = function(element, entries)
            style.mutedText("Convert all to")
            ImGui.SameLine()
            ImGui.SetCursorPosX(200 * style.viewSize)
            local options = {
                IconGlyphs.CubeOutline .. " Static Mesh",
                IconGlyphs.FormatRotate90 .. " Rotating Mesh"
            }
            ImGui.SetNextItemWidth(150 * style.viewSize)
            element.groupOperationData["clothMesh"].convertTarget, _ = ImGui.Combo("##groupClothMeshConvertTarget", element.groupOperationData["clothMesh"].convertTarget, options, #options)
            style.tooltip("Select the mesh type to convert all cloth mesh(es) into")

            ImGui.SameLine()
            if ImGui.Button("Convert") then
                if settings.skipLossyConversionWarning then
                    history.addAction(history.getMultiSelectChange(entries))
                    local nApplied = 0
                    local convertToRotating = element.groupOperationData["clothMesh"].convertTarget == 1

                    for _, entry in ipairs(entries) do
                        if entry.spawnable.node == "worldClothMeshNode" then
                            if convertToRotating then
                                entry.spawnable:convertToRotatingMesh()
                            else
                                entry.spawnable:convertToStaticMesh()
                            end
                            nApplied = nApplied + 1
                        end
                    end

                    local targetName = convertToRotating and "rotating meshes" or "static meshes"
                    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Converted %s cloth meshes to %s", nApplied, targetName)))
                else
                    ImGui.OpenPopup("Lossy Conversion##clothMeshGroup")
                end
            end

            if ImGui.BeginPopupModal("Lossy Conversion##clothMeshGroup", true, ImGuiWindowFlags.AlwaysAutoResize) then
                local nPending = 0
                for _, entry in ipairs(entries) do
                    if entry.spawnable.node == "worldClothMeshNode" then
                        nPending = nPending + 1
                    end
                end

                style.mutedText("Warning")
                ImGui.Text("This conversion is lossy.")
                ImGui.Text("Cloth mesh specific properties will be removed.")
                ImGui.Text(string.format("Affected cloth mesh(es): %d", nPending))
                ImGui.Text("Do you want to continue?")
                ImGui.Dummy(0, 8 * style.viewSize)
                local skipWarning, changed = ImGui.Checkbox("Do not ask again", settings.skipLossyConversionWarning)
                if changed then
                    settings.skipLossyConversionWarning = skipWarning
                    settings.save()
                end
                ImGui.Dummy(0, 8 * style.viewSize)

                if ImGui.Button("Convert") then
                    history.addAction(history.getMultiSelectChange(entries))
                    local nApplied = 0
                    local convertToRotating = element.groupOperationData["clothMesh"].convertTarget == 1

                    for _, entry in ipairs(entries) do
                        if entry.spawnable.node == "worldClothMeshNode" then
                            if convertToRotating then
                                entry.spawnable:convertToRotatingMesh()
                            else
                                entry.spawnable:convertToStaticMesh()
                            end
                            nApplied = nApplied + 1
                        end
                    end

                    local targetName = convertToRotating and "rotating meshes" or "static meshes"
                    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Converted %s cloth meshes to %s", nApplied, targetName)))
                    ImGui.CloseCurrentPopup()
                end

                ImGui.SameLine()
                if ImGui.Button("Cancel") then
                    ImGui.CloseCurrentPopup()
                end

                ImGui.EndPopup()
            end
        end
    }

    return properties
end

return clothMesh
