local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local logger = require("modules/utils/core/logger")
local element = require("modules/classes/editor/element")

---Class for worldAreaShapeNode
---@class area : visualized
---@field outlinePath string
---@field height number
---@field markers table
---@field protected maxPropertyWidth number
local area = setmetatable({}, { __index = visualized })

---Areas that consume an outline, bucketed by the outline group path they reference, per root element.
---Outline markers notify on every transform change, so this avoids walking the hierarchy per frame
---while one is being dragged. Stamped with the hierarchy cache epoch, like the other path caches.
local outlineConsumerCache = setmetatable({}, { __mode = "k" })

---Which outline an area references is not part of the hierarchy, so picking a different one has to
---invalidate the buckets explicitly.
local outlineConsumerEpoch = 0

function area.invalidateOutlineConsumers()
    outlineConsumerEpoch = outlineConsumerEpoch + 1
end

---@param root element
---@param sUI table
---@return table<string, table[]>
local function getOutlineConsumers(root, sUI)
    if sUI.ensureCache then
        sUI.ensureCache()
    end

    local stamp = string.format("%s:%s", tostring(sUI.cacheEpoch or 0), tostring(outlineConsumerEpoch))
    local cached = outlineConsumerCache[root]

    if cached and cached.stamp == stamp then
        return cached.byPath
    end

    local byPath = {}

    for _, entry in pairs(sUI.paths or {}) do
        local ref = entry.ref
        local spawnable = ref and utils.isA(ref, "spawnableElement") and ref.spawnable or nil

        if spawnable and spawnable.onOutlineChanged and spawnable.outlinePath and spawnable.outlinePath ~= "" then
            if ref.getRootParent and ref:getRootParent() == root then
                local bucket = byPath[spawnable.outlinePath]

                if not bucket then
                    bucket = {}
                    byPath[spawnable.outlinePath] = bucket
                end

                table.insert(bucket, spawnable)
            end
        end
    end

    outlineConsumerCache[root] = { stamp = stamp, byPath = byPath }

    return byPath
end

---Notifies every area referencing an outline group that its geometry changed.
---
---Outline markers are elements of their own, so an area has no way of noticing on its own that one of
---them moved, changed height, or joined/left the group.
---@param object element Element inside the outline group, usually an outline marker.
---@param parentOverride element? Group to notify for, when the marker just left or entered one.
function area.notifyOutlineChanged(object, parentOverride)
    if not object then return end

    local parent = parentOverride or object.parent
    local sUI = object.sUI

    if not parent or not sUI or not parent.getPath then return end

    local path = parent:getPath()
    if not path or path == "" then return end

    local root = object.getRootParent and object:getRootParent() or nil
    if not root then return end

    for _, spawnable in ipairs(getOutlineConsumers(root, sUI)[path] or {}) do
        spawnable:onOutlineChanged()
    end
end

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

function area:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    -- Loading a project, pasting, or undoing an edit can all point this area at a different outline.
    area.invalidateOutlineConsumers()
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

---Called when the referenced outline changed: a different group got picked, or one of its markers
---moved, changed height, or joined/left the group.
---@protected
function area:onOutlineChanged()
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
        element.bumpWireframeEpoch(self.object)
        area.invalidateOutlineConsumers()
        self:onOutlineChanged()
    end
    style.tooltip("Path to the group containing the outline markers.\nMust be contained within the same root group as this area.")
end

function area:getProperties()
    return self:addNodeProperty(visualized.getProperties(self))
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
        logger:warn(string.format("Issue during export: Area outline %s has more than 255 markers. Only the first 255 will be utilized.", self.outlinePath))
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
