local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local history = require("modules/utils/project/history")
local radiusSphere = require("modules/utils/preview/radiusSphere")

---Every tag CDPR places, measured over 108 shipped nodes: the exploration radio cues and nothing
---else. The field is a plain `CName` so anything can be typed, but a value the audio system does not
---know does nothing at all, which is why the shipped set is offered as a list.
local SHIPPED_TAGS = {
    "exploration_radio",
    "exploration_radio_electro",
    "exploration_radio_hiphop",
    "exploration_radio_jazz",
    "exploration_radio_pop"
}

---Class for worldAudioTagNode
---
---Marks a volume as belonging to an audio context. The radio cues are what the shipped world uses it
---for: standing inside one biases which exploration music the game reaches for.
---@class audioTag : visualized
---@field private radius number
---@field private audioTag string
---@field private audioTagSearch string
---@field private radiusPreviewed boolean
local audioTag = setmetatable({}, { __index = visualized })

function audioTag:new()
	local o = visualized.new(self)

    o.spawnListType = "files"
    o.dataType = "Audio Tag"
    o.spawnDataPath = "data/spawnables/visual/audioTag/"
    o.modulePath = "visual/audioTag"
    o.node = "worldAudioTagNode"
    o.description = "Marks a spherical volume with an audio tag, biasing which exploration music plays inside it."
    o.previewNote = "The tag has no effect in the editor.\nRadius can be previewed at true scale."
    o.icon = IconGlyphs.TagOutline

    -- Shipped nodes use 50 (101 of 108) or 25.
    o.radius = 50
    o.previewColor = "mediumvioletred"
    o.audioTag = SHIPPED_TAGS[1]
    o.audioTagSearch = ""
    o.previewed = true
    o.radiusPreviewed = false

    setmetatable(o, { __index = self })
   	return o
end

function audioTag:save()
    local data = visualized.save(self)

    data.radius = self.radius
    data.radiusPreviewed = self.radiusPreviewed
    data.audioTag = self.audioTag

    return data
end

---@param entity entEntity
function audioTag:onAfterPreviewAssemble(entity)
    visualized.onAfterPreviewAssemble(self, entity)

    radiusSphere.attach(self, entity)
end

---@param entity entEntity
function audioTag:onAfterPreviewScale(entity)
    visualized.onAfterPreviewScale(self, entity)

    radiusSphere.update(self, entity)
end

function audioTag:setPreview(state)
    visualized.setPreview(self, state)

    radiusSphere.update(self)
end

function audioTag:draw()
    visualized.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Radius", "Audio Tag" }) + ImGui.CalcTextSize(IconGlyphs.Square) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    self:drawPreviewCheckbox("Visualize", self.maxPropertyWidth)

    style.drawIconLabelRow(IconGlyphs.SignalDistanceVariant, "Radius")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local change
    self.radius, change = style.trackedDragFloat(self.object, "##radius", self.radius, 0.01, 0, 9999, "%.2f", 80)
    if change then
        self:updateScale()
    end

    radiusSphere.toggleButton(self, history, style)

    style.drawIconLabelRow(IconGlyphs.TagOutline, "Audio Tag")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.audioTagSearch = self.audioTagSearch or ""
    self.audioTag, self.audioTagSearch, _ = style.trackedSearchDropdown("##audioTag", "Search...", self.audioTag, self.audioTagSearch, SHIPPED_TAGS, {
        element = self.object,
        width = 180,
        matchContentWidth = true,
        allowCustom = true,
        tooltip = "Audio context this volume belongs to.\nThe shipped world only ever uses the five exploration radio cues."
    })
end

function audioTag:getArrowSize()
    local max = math.min(math.max(self.radius / 30, 0.6), 0.8)
    return { x = max, y = max, z = max }
end

function audioTag:getVisualizerSize()
    local x = math.min(math.max(self.radius / 125, 0.125), 0.33)

    return { x = x, y = x, z = x }
end

function audioTag:getProperties()
    return self:addNodeProperty(visualized.getProperties(self))
end

function audioTag:export()
    local data = visualized.export(self)
    data.type = "worldAudioTagNode"
    data.data = {
        radius = self.radius,
        audioTag = {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = self.audioTag or ""
        }
    }

    return data
end

return audioTag
