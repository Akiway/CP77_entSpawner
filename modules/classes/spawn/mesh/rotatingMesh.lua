local mesh = require("modules/classes/spawn/mesh/mesh")
local spawnable = require("modules/classes/spawn/spawnable")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local Cron = require("modules/utils/Cron")
local history = require("modules/utils/history")
local settings = require("modules/utils/settings")

---Class for worldRotatingMeshNode
---@class rotatingMesh : mesh
---@field public duration number
---@field public axis integer
---@field public reverse boolean
---@field private axisTypes table
---@field private cronID number
local rotatingMesh = setmetatable({}, { __index = mesh })

function rotatingMesh:new()
	local o = mesh.new(self)

    o.spawnListType = "list"
    o.dataType = "Rotating Mesh"
    o.modulePath = "mesh/rotatingMesh"
    o.node = "worldRotatingMeshNode"
    o.description = "Places a static mesh, from a given .mesh file, and rotates it around a given axis"
    o.icon = IconGlyphs.FormatRotate90

    o.duration = 5
    o.axis = 0
    o.reverse = false
    o.axisTypes = utils.enumTable("gameTransformAnimation_RotateOnAxisAxis")
    o.hideGenerate = true
    o.convertTarget = 0

    o.cronID = nil

    setmetatable(o, { __index = self })
   	return o
end

function rotatingMesh:onAssemble(entity)
    mesh.onAssemble(self, entity)

    if self.isAssetPreview then return end

    self.cronID = Cron.OnUpdate(function ()
        local entity = self:getEntity()

        if not entity then return end

        local rotation = ((Cron.time % self.duration) / self.duration) * 360
        if self.reverse then rotation = -rotation end

        local transform = entity:GetWorldTransform()
        transform:SetPosition(self.position)

        local angle = EulerAngles.new(0, 0, rotation)
        if self.axis == 0 then
            angle = EulerAngles.new(0, rotation, 0)
        elseif self.axis == 1 then
            angle = EulerAngles.new(rotation, 0, 0)
        end

        entity:FindComponentByName("mesh"):SetLocalOrientation(angle:ToQuat())
    end)
end

function rotatingMesh:despawn()
    if self.cronID then
        Cron.Halt(self.cronID)
        self.cronID = nil
    end

    mesh.despawn(self)
end

function rotatingMesh:save()
    local data = mesh.save(self)
    data.duration = self.duration
    data.axis = self.axis
    data.reverse = self.reverse

    return data
end

function rotatingMesh:draw()
    mesh.draw(self)

    style.mutedText("Duration")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.duration = style.trackedDragFloat(self.object, "##duration", self.duration, 0.01, 0.01, 9999, "%.2f Seconds", 95)

    style.mutedText("Axis")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.axis = style.trackedCombo(self.object, "##axis", self.axis, self.axisTypes, 95)

    style.mutedText("Reverse")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.reverse = style.trackedCheckbox(self.object, "##reverse", self.reverse)

    style.mutedText("Convert to")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local options = { IconGlyphs.CubeOutline .. " Static Mesh" }
    local convertActions = { "static" }

    if self:canConvertToClothMesh() then
        table.insert(options, IconGlyphs.ReceiptOutline .. " Cloth Mesh")
        table.insert(convertActions, "cloth")
    end

    if self:canConvertToDynamicMesh() then
        table.insert(options, IconGlyphs.CubeSend .. " Dynamic Mesh")
        table.insert(convertActions, "dynamic")
    end

    self.convertTarget = math.max(0, math.min(self.convertTarget, #options - 1))
    self.convertTarget, _ = style.trackedCombo(self.object, "##rotatingMeshConverterType", self.convertTarget, options, 150)
    style.tooltip("Select the mesh type to convert into")

    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth + 150 * style.viewSize + ImGui.GetStyle().ItemSpacing.x)
    style.pushButtonNoBG(false)
    if ImGui.Button("Convert") then
        if settings.skipLossyConversionWarning then
            history.addAction(history.getElementChange(self.object))
            local target = convertActions[self.convertTarget + 1]
            if target == "cloth" then
                self:convertToClothMesh()
            elseif target == "dynamic" then
                self:convertToDynamicMesh()
            else
                self:convertToStaticMesh()
            end
        else
            ImGui.OpenPopup("Lossy Conversion##rotatingMeshSingle")
        end
    end

    if ImGui.BeginPopupModal("Lossy Conversion##rotatingMeshSingle", true, ImGuiWindowFlags.AlwaysAutoResize) then
        style.mutedText("Warning")
        ImGui.Text("This conversion is lossy.")
        ImGui.Text("Rotating mesh specific properties will be removed.")
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
            if target == "cloth" then
                self:convertToClothMesh()
            elseif target == "dynamic" then
                self:convertToDynamicMesh()
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

function rotatingMesh:convertToStaticMesh()
    -- Ensure current rotating logic is stopped
    self:despawn()

    -- Create a mesh instance to get default values
    local meshInstance = mesh:new()

    -- Change this object's metatable so it now inherits from mesh instead of rotatingMesh
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

    -- Remove rotating-mesh-specific properties
    self.duration = nil
    self.axis = nil
    self.reverse = nil
    self.axisTypes = nil
    self.cronID = nil
    self.hideGenerate = nil
    self.convertTarget = 0

    -- Respawn as a static mesh
    self:respawn()
end

function rotatingMesh:export()
    local data = mesh.export(self)
    data.type = "worldRotatingMeshNode"
    data.data.fullRotationTime = self.duration
    data.data.reverseDirection = self.reverse and 1 or 0
    data.data.rotationAxis = self.axisTypes[self.axis + 1]

    return data
end

function rotatingMesh:getProperties()
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

function rotatingMesh:getGroupedProperties()
    return spawnable.getGroupedProperties(self)
end

return rotatingMesh
