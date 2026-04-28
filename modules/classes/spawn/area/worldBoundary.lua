local area = require("modules/classes/spawn/area/area")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local field = require("modules/utils/field")

local function bumpBoundaryOrientationEpoch(instance)
    local sUI = instance and instance.object and instance.object.sUI
    if not sUI then
        return
    end

    sUI.boundaryOrientationEpoch = (sUI.boundaryOrientationEpoch or 0) + 1
end

---Class for gameWorldBoundaryNode
---@class worldBoundary : area
local worldBoundary = setmetatable({}, { __index = area })

function worldBoundary:new()
	local o = area.new(self)

    o.spawnListType = "files"
    o.dataType = "World Boundary"
    o.spawnDataPath = "data/spawnables/area/worldBoundary/"
    o.modulePath = "area/worldBoundary"
    o.node = "gameWorldBoundaryNode"
    o.description = "Players entering the area will be warned to turn back, and if they leave the area by passing through the red faces, they will be teleported back to where they entered the area."
    o.previewNote = "Does not work in the editor."
    o.icon = IconGlyphs.SelectionRemove
    o.orientation = 0

    setmetatable(o, { __index = self })
   	return o
end

function worldBoundary:loadSpawnData(data, position, rotation)
    area.loadSpawnData(self, data, position, rotation)
end

function worldBoundary:draw()
    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize", "Outline Path", "Orientation" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    local previousOutlinePath = self.outlinePath
    area.draw(self)
    if previousOutlinePath ~= self.outlinePath then
        bumpBoundaryOrientationEpoch(self)
        if self.object and self.object.sUI and self.object.sUI.bumpWireframeEpoch then
            self.object.sUI.bumpWireframeEpoch()
        end
        self:updateOutlineFacePreview(previousOutlinePath)
        self:updateOutlineFacePreview(self.outlinePath, self.orientation)
    end

    style.mutedText("Orientation")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local changed
    local finished
    self.orientation, changed, finished = field.advancedTrackedFloat(self.object, "##boundaryOrientationYaw", self.orientation, {
        step = 0.1,
        min = 0,
        max = 360,
        format = "%.2f",
        width = 120,
        suffix = " Yaw",
        loop = true
    })
    if changed or finished then
        bumpBoundaryOrientationEpoch(self)
        self:updateOutlineFacePreview(nil, self.orientation)
        if self.object and self.object.sUI and self.object.sUI.bumpWireframeEpoch then
            self.object.sUI.bumpWireframeEpoch()
        end
    end
    style.tooltip("Used for red face selection.\nPlayers entering the area will be warned to turn back,\nand if they leave the area by passing through the red faces,\nthey will be teleported back to where they entered the area.")
end

---@private
---@param targetOutlinePath string?
---@param orientationYawOverride number?
function worldBoundary:updateOutlineFacePreview(targetOutlinePath, orientationYawOverride)
    if not self.object or not self.object.sUI or not self.object.sUI.getElementByPath then
        return
    end

    local outlinePath = targetOutlinePath or self.outlinePath
    if not outlinePath or outlinePath == "" then
        return
    end

    local outline = self.object.sUI.getElementByPath(outlinePath)
    if not outline or not outline.childs then
        return
    end

    for _, child in ipairs(outline.childs) do
        if utils.isA(child, "spawnableElement") and child.spawnable and child.spawnable.modulePath == "area/outlineMarker" then
            child.spawnable:refreshBoundaryFacePreview(outline, orientationYawOverride)
        end
    end
end

function worldBoundary:save()
    local data = area.save(self)
    data.orientation = self.orientation

    return data
end

---@protected
---@return Quaternion
function worldBoundary:getOutlineLocalRotationForExport()
    local yaw = tonumber(self.orientation) or 0
    return EulerAngles.new(0, 0, yaw):ToQuat()
end

function worldBoundary:export(key, length, markersZOffset)
    local rotation = self:getOutlineLocalRotationForExport()
    local data = area.export(self, key, length, markersZOffset)

    data.rotation = utils.fromQuaternion(rotation)
    data.type = "gameWorldBoundaryNode"

    return data
end

return worldBoundary
