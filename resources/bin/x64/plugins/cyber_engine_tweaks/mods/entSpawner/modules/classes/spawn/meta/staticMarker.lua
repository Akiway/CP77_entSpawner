local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local settings = require("modules/utils/core/settings")
local history = require("modules/utils/project/history")
local projectedWireframe = require("modules/utils/editor/projectedWireframe")

local markerAppearances = { "default", "yellow", "pink", "blue" }
local markerAppearanceLabels = { "Default", "Yellow", "Pink", "Blue" }

-- Values of settings.staticMarkerNameMode
local nameModes = { elementName = 0, simplifiedNodeRef = 1, fullNodeRef = 2 }

local propertyNames = {
    "Visualize position",
    "Marker Color",
    "Show Name",
    "Quest Marker"
}

---Class for worldStaticMarkerNode
---@class staticMarker : visualized
---@field private questMarker boolean
---@field private markerAppearance string
---@field private showName boolean
---@field private previewMesh string
---@field private intersectionMultiplier number
---@field private previewed boolean
local staticMarker = setmetatable({}, { __index = visualized })

function staticMarker:new()
	local o = visualized.new(self)

    o.spawnListType = "files"
    o.dataType = "Static Marker"
    o.spawnDataPath = "data/spawnables/meta/staticMarker/"
    o.modulePath = "meta/staticMarker"
    o.node = "worldStaticMarkerNode"
    o.description = "Places a static marker node. Useful if you need a NodeRef as a reference point. Usually best placed in an AlwaysLoaded Sector."
    o.icon = IconGlyphs.MapMarker

    o.previewed = true
    o.previewShape = "mesh"
    o.previewMesh = "base\\environment\\ld_kit\\marker.mesh"
    o.previewMeshAppearance = "default"
    o.intersectionMultiplier = 0.3 / 0.005

    o.questMarker = false
    o.markerAppearance = "default"
    o.showName = settings.staticMarkerShowName == true
    o.wantsViewportOverlayWhenUnspawned = true
    o.maxPropertyWidth = nil

    o.streamingMultiplier = 20
    o.primaryRange = 500

    setmetatable(o, { __index = self })
   	return o
end

function staticMarker:save()
    local data = visualized.save(self)
    data.questMarker = self.questMarker
    data.markerAppearance = self.markerAppearance
    data.showName = self.showName

    return data
end

function staticMarker:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    -- Legacy key
    if data.showName == nil and data.showNodeRef ~= nil then
        self.showName = data.showNodeRef == true
    end

    if not utils.indexValue(markerAppearances, self.markerAppearance) then
        self.markerAppearance = "default"
    end
    self.previewMeshAppearance = self.markerAppearance
end

function staticMarker:applyMarkerAppearance()
    local entity = self:getEntity()
    if not entity then return end

    local mesh = entity:FindComponentByName("mesh")
    if mesh then
        mesh.meshAppearance = CName.new(self.markerAppearance)
        mesh:LoadAppearance()
    end
end

function staticMarker:getSize()
    return { x = 0.1, y = 0.1, z = 0.6 }
end

function staticMarker:getBBox()
    return {
        min = { x = -0.075, y = -0.075, z = 0 },
        max = { x = 0.075, y = 0.075, z = self:getSize().z }
    }
end

-- Needed for dropToSurface, uses this and size to get bbox
function staticMarker:getCenter()
    local position = Vector4.new(self.position.x, self.position.y, self.position.z, 1)
    position.z = position.z + self:getSize().z / 2

    return position
end

function staticMarker:getVisualizerSize()
    return { x = 0.005, y = 0.005, z = 0.005 }
end

function staticMarker:draw()
    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth(propertyNames) + 4 * ImGui.GetStyle().ItemSpacing.x
    end

    self:drawPreviewCheckbox("Visualize position", self.maxPropertyWidth)

    local appearanceIndex = (utils.indexValue(markerAppearances, self.markerAppearance) or 1) - 1
    style.mutedText("Marker Color")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local changed
    appearanceIndex, changed = style.trackedCombo(self.object, "##markerAppearance", appearanceIndex, markerAppearanceLabels, 100)
    if changed then
        self.markerAppearance = markerAppearances[appearanceIndex + 1]
        self.previewMeshAppearance = self.markerAppearance
        self:applyMarkerAppearance()
    end

    style.mutedText("Show Name")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.showName, _ = style.trackedCheckbox(self.object, "##showName", self.showName)
    style.tooltip("Display a label in the viewport.\nIts content and the default for new markers are set in Settings > Visualizers.")

    style.mutedText("Quest Marker")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.questMarker, _ = style.trackedCheckbox(self.object, "##questMarker", self.questMarker)
end

function staticMarker:wantsViewportOverlay()
    return self.object ~= nil and self.showName == true
end

---Viewport marker colors for the current "Wireframe color style".
---@return integer markerColor
---@return integer labelColor
local function getOverlayThemeColors()
    if settings.wireframeColorStyle == 2 then
        -- Lighter blue with black text.
        return 0xFFFF9900, 0xFF000000
    end

    -- Darker blue with white text.
    return 0xFFA35200, 0xFFDCD8D1
end

---Viewport label text, as picked by settings.staticMarkerNameMode.
---@return string
function staticMarker:getDisplayName()
    local mode = settings.staticMarkerNameMode

    if mode == nameModes.elementName then
        return self.object.name
    end

    if self.nodeRef == "" then
        return "<empty>"
    end

    if mode == nameModes.simplifiedNodeRef then
        return self.nodeRef:match("#.*$") or self.nodeRef
    end

    return self.nodeRef
end

function staticMarker:drawViewportOverlay(screen, drawList)
    if not self:wantsViewportOverlay() then return end

    local markerColor, labelColor = getOverlayThemeColors()

    projectedWireframe.drawWorldMarker(drawList, screen, self.position, {
        color = markerColor,
        labelColor = labelColor,
        text = self:getDisplayName(),
        radius = 6 * style.viewSize,
        innerRadius = 2.5 * style.viewSize,
        badgeOffsetY = -15 * style.viewSize,
        fontRatio = 0.8,
        clampToScreen = false
    })
end

function staticMarker:getProperties()
    return self:addNodeProperty(visualized.getProperties(self))
end

---@param entries element[]
---@param state boolean
local function setShowNameForEntries(entries, state)
    local changed = {}

    for _, entry in ipairs(entries) do
        if entry.spawnable and entry.spawnable.node == "worldStaticMarkerNode" and entry.spawnable.showName ~= state then
            table.insert(changed, entry)
        end
    end

    if #changed == 0 then return end

    history.addAction(history.getMultiSelectChange(changed))

    for _, entry in ipairs(changed) do
        entry.spawnable.showName = state
    end
end

function staticMarker:getGroupedProperties()
    local properties = visualized.getGroupedProperties(self)
    local drawVisualization = properties["visualization"].draw

    properties["visualization"].draw = function(element, entries)
        drawVisualization(element, entries)

        ImGui.Text("Static Marker Name")
        ImGui.SameLine()
        ImGui.PushID("staticMarkerName")

        if ImGui.Button("Off") then
            setShowNameForEntries(entries, false)
        end

        ImGui.SameLine()

        if ImGui.Button("On") then
            setShowNameForEntries(entries, true)
        end

        ImGui.PopID()
    end

    return properties
end

function staticMarker:export()
    local data = visualized.export(self)
    data.type = "worldStaticMarkerNode"
    data.data = {}

    if self.questMarker then
        data.data = {
            ["data"] = {
                ["Data"] = {
                    ["$type"] = "worldQuestMarker"
                }
            }
        }
    end

    return data
end

return staticMarker
