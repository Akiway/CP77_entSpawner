local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")

---Class for worldAreaShapeNode
---@class area : visualized
---@field outlinePath string
---@field height number
---@field markers table
---@field protected maxPropertyWidth number
local area = setmetatable({}, { __index = visualized })

function area:new()
	local o = visualized.new(self)

    o.spawnListType = "files"
    o.dataType = "Area"
    o.spawnDataPath = "data/spawnables/area/area/"
    o.modulePath = "area/area"
    o.node = "worldAreaShapeNode"
    o.description = "Base type for all area type nodes. Position is irrelevant, as the actual position is determined by the outline markers."
    o.icon = IconGlyphs.Select

    o.previewed = true
    o.previewColor = "cyan"
    o.outlinePath = ""

    -- Only used for saved data, to have easier access to it during export
    o.height = 0
    o.markers = {}

    o.maxPropertyWidth = nil

    setmetatable(o, { __index = self })
   	return o
end

function area:spawn()
    self.rotation = EulerAngles.new(0, 0, 0)
    visualized.spawn(self)
end

function area:update()
    self.rotation = EulerAngles.new(0, 0, 0)
    visualized.update(self)
end

function area:getTransformUIConfig()
    return {
        showRotation = false
    }
end

function area:getMarkersData()
    local markers = {}
    local height = 0

    local paths = self:loadOutlinePaths()

    if utils.indexValue(paths, self.outlinePath) ~= -1 then
        local sUI = self.object and self.object.sUI or nil
        local outline = sUI and sUI.getElementByPath and sUI.getElementByPath(self.outlinePath) or nil

        if outline and outline.childs then
            for _, child in ipairs(outline.childs) do
                local spawnable = child and child.spawnable or nil
                if utils.isA(child, "spawnableElement") and spawnable and spawnable.modulePath == "area/outlineMarker" then
                    if spawnable.position then
                        table.insert(markers, utils.fromVector(spawnable.position))
                    end
                    height = tonumber(spawnable.height) or height
                end
            end
        end
    end

    return markers, height
end

function area:save()
    local data = visualized.save(self)

    data.outlinePath = self.outlinePath
    data.markers, data.height = self:getMarkersData()

    return data
end

function area:loadOutlinePaths()
    local paths = {}
    local object = self.object
    local sUI = object and object.sUI or nil
    if not object or not sUI then
        return paths
    end

    if sUI.ensureCache then
        sUI.ensureCache()
    end

    local ownRoot = object.getRootParent and object:getRootParent() or nil
    if not ownRoot then
        return paths
    end

    for _, container in pairs(sUI.containerPaths or {}) do
        if container and container.ref and container.ref.getRootParent and container.ref:getRootParent() == ownRoot then
            local nMarkers = 0
            for _, child in pairs(container.ref.childs or {}) do
                local spawnable = child and child.spawnable or nil
                if utils.isA(child, "spawnableElement") and spawnable and spawnable.modulePath == "area/outlineMarker" then
                    nMarkers = nMarkers + 1
                end

                if nMarkers == 3 then
                    if container.path and container.path ~= "" then
                        table.insert(paths, container.path)
                    end
                    break
                end
            end
        end
    end

    return paths
end

function area:getMarkersCenter()
    local markers = self.markers
    local center = Vector4.new(0, 0, 0, 0)
    local nMarkers = math.max(1, #markers)

	for _, position in ipairs(markers) do
		center = utils.addVector(center, ToVector4(position))
	end

    return Vector4.new(center.x / nMarkers, center.y / nMarkers, center.z / nMarkers, 0)
end

function area:draw()
    visualized.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize", "Outline Path" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    self:drawPreviewCheckbox("Visualize", self.maxPropertyWidth)

    local paths = self:loadOutlinePaths()
    table.insert(paths, 1, "None")

    local index = math.max(1, utils.indexValue(paths, self.outlinePath))

    style.mutedText("Outline Path")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local idx, changed = style.trackedCombo(self.object, "##outlinePath", index - 1, paths, 225)
    if changed then
        self.outlinePath = paths[idx + 1]
        if self.object and self.object.sUI and self.object.sUI.bumpWireframeEpoch then
            self.object.sUI.bumpWireframeEpoch()
        end
    end
    style.tooltip("Path to the group containing the outline markers.\nMust be contained within the same root group as this area.")
end

function area:getProperties()
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

---@protected
---@return Quaternion?
function area:getOutlineLocalRotationForExport()
    return nil
end

function area:export(_, _, markersZOffset)
    local data = visualized.export(self)
    data.type = "worldAreaShapeNode"
    data.data = {}
    local markers = self.markers
    local outlineLocalRotation = self:getOutlineLocalRotationForExport()

    if #markers == 0 then
        local issues = self.object.sUI.spawner.baseUI.exportUI.exportIssues
        table.insert(issues.noOutlineMarkers, self.object.name)

        return data
    end

    if #markers > 255 then
        print(string.format("[entSpawner] Issue during export: Area outline %s has more than 255 markers. Only the first 255 will be utilized.", self.outlinePath))
    end

    -- Grab center
    local center = self:getMarkersCenter()
    data.position = utils.fromVector(center)

    local buffer = utils.intToHex(math.min(255, #markers))
    buffer = buffer .. "000000"

    for idx, marker in ipairs(markers) do
        if idx <= 255 then
            local diff = utils.subVector(ToVector4(marker), center)
            if outlineLocalRotation and outlineLocalRotation.TransformInverse then
                -- Outline points are stored as local coords in the node. Convert world-space
                -- marker offsets into the node's local frame when a rotation is provided.
                diff = outlineLocalRotation:TransformInverse(diff)
            end

            buffer = buffer .. utils.floatToHex(diff.x)
            buffer = buffer .. utils.floatToHex(diff.y)
            buffer = buffer .. utils.floatToHex(diff.z + (markersZOffset or 0))
            buffer = buffer .. utils.floatToHex(1)
        end
    end

    buffer = buffer .. utils.floatToHex(self.height)

    data.data["outline"] = {
        ["Data"] = {
            ["$type"] = "AreaShapeOutline",
            ["buffer"] = utils.hexToBase64(buffer),
        }
    }

    return data
end

return area
