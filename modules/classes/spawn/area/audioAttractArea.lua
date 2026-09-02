local triggerArea = require("modules/classes/spawn/area/triggerArea")
local area = require("modules/classes/spawn/area/area")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local history = require("modules/utils/project/history")
local registry = require("modules/utils/game/nodeRefRegistry")
local audioData = require("modules/utils/data/audioData")

---Class for worldAudioAttractAreaNode
---
---Gives a staged scene its background chatter: each named preset carries NPC grunts keyed by visual
---tag (Valentinos, MidClass, ...) plus environment sounds, each on its own interval. Shipped nodes
---name one preset and point at the conversation node the scene runs on.
---
---Like the audio signpost, the settings live on the node; the notifier only carries channels, and
---every shipped node listens on `TC_Player`.
---@class audioAttractArea : triggerArea
---@field private soundSettings string[] Preset names, in order
---@field private conversationsRef string NodeRef of the interesting-conversations node
local audioAttractArea = setmetatable({}, { __index = triggerArea })

---@param value string
---@return table cname
local function cname(value)
    return {
        ["$type"] = "CName",
        ["$storage"] = "string",
        ["$value"] = (value and value ~= "") and value or "None"
    }
end

---@param value string
---@return table nodeRef
local function nodeRef(value)
    if value and value ~= "" then
        return { ["$type"] = "NodeRef", ["$storage"] = "string", ["$value"] = value }
    end

    return { ["$type"] = "NodeRef", ["$storage"] = "uint64", ["$value"] = "0" }
end

function audioAttractArea:new()
	local o = triggerArea.new(self)

    o.spawnListType = "files"
    o.dataType = "Audio Attract Area"
    o.spawnDataPath = "data/spawnables/area/audioAttractArea/"
    o.modulePath = "area/audioAttractArea"
    o.node = "worldAudioAttractAreaNode"
    o.description = "Plays NPC grunts and environment sounds around a staged scene."
    o.previewNote = "Not previewed in editor."
    o.icon = IconGlyphs.Magnet

    o.triggerType = "Audio Attract"
    -- TC_Player, the only channel any shipped attract area listens on.
    o.channels = { false, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false }

    o.soundSettings = {}
    o.conversationsRef = ""

    o.soundSettingSearch = {}
    o.maxAttractPropertyWidth = nil

    setmetatable(o, { __index = self })
   	return o
end

function audioAttractArea:loadSpawnData(data, position, rotation)
    triggerArea.loadSpawnData(self, data, position, rotation)

    -- `spawnable.loadSpawnData` assigns tables by reference and its payloads outlive the load
    -- (project cache, clipboard), so two areas would otherwise share one preset list.
    self.soundSettings = utils.deepcopy(self.soundSettings)
    self.soundSettingSearch = {}
end

function audioAttractArea:save()
    local data = triggerArea.save(self)

    data.soundSettings = utils.deepcopy(self.soundSettings)
    data.conversationsRef = self.conversationsRef

    return data
end

function audioAttractArea:drawAudioAttract(changed)
    if changed then
        self.trigger = { ["$type"] = "worldAudioAttractAreaNotifier" }

        return
    end

    if not self.maxAttractPropertyWidth then
        self.maxAttractPropertyWidth = utils.getTextMaxWidth({ "Conversation Node", "Sound Preset" }) + 8 * ImGui.GetStyle().ItemSpacing.x
    end
    local max = self.maxAttractPropertyWidth

    style.mutedText("Conversation Node")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    self.conversationsRef, _ = registry.drawNodeRefSelector(style.getMaxWidth(250) - 30, self.conversationsRef, self.object, true)
    style.tooltip("The Conversation Area whose actors this chatter belongs to.\nShipped nodes always point at one.")

    local presets = audioData.getVocabulary("attractAreas")

    if style.treeNodeWithCount("Sound Presets", #self.soundSettings) then
        for index, _ in ipairs(self.soundSettings) do
            ImGui.PushID(index)

            local value, search, _ = style.trackedSearchDropdown("##preset", "Search preset...", self.soundSettings[index], self.soundSettingSearch[index] or "", presets, {
                element = self.object,
                width = style.getMaxWidth(250) - 30,
                matchContentWidth = true,
                allowCustom = true,
                tooltip = "Named entry in the cooked audio metadata, carrying the grunts and environment sounds."
            })
            self.soundSettings[index] = value
            self.soundSettingSearch[index] = search

            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.Delete) then
                history.addAction(history.getElementChange(self.object))
                table.remove(self.soundSettings, index)
                table.remove(self.soundSettingSearch, index)
                ImGui.PopID()
                break
            end
            style.tooltip("Delete")

            ImGui.PopID()
        end

        if ImGui.Button("+") then
            history.addAction(history.getElementChange(self.object))
            table.insert(self.soundSettings, presets[1] or "")
            table.insert(self.soundSettingSearch, "")
        end

        ImGui.TreePop()
    end
end

function audioAttractArea:getAvailableTriggers()
    return {
        ["Audio Attract"] = audioAttractArea.drawAudioAttract
    }
end

function audioAttractArea:draw()
    -- Only one trigger type applies, so the type combo `triggerArea:draw` would add is skipped.
    area.draw(self)

    if ImGui.TreeNodeEx(self.triggerType, ImGuiTreeNodeFlags.SpanFullWidth) then
        self:drawChannelSelect()
        self:drawAudioAttract(false)
        ImGui.TreePop()
    end
end

function audioAttractArea:export(key, length, markersZOffset)
    local data = triggerArea.export(self, key, length, markersZOffset)
    data.type = "worldAudioAttractAreaNode"

    local settings = {}
    for _, name in ipairs(self.soundSettings) do
        if name ~= "" then
            table.insert(settings, {
                ["$type"] = "worldAudioAttractAreaNodeSettings",
                ["metadataName"] = cname(name)
            })
        end
    end

    data.data.audioAttractSoundSettings = settings
    data.data.interestingConversationsNodeRef = nodeRef(self.conversationsRef)

    return data
end

return audioAttractArea
