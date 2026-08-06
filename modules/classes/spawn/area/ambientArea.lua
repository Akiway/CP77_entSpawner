local triggerArea = require("modules/classes/spawn/area/triggerArea")
local area = require("modules/classes/spawn/area/area")
local utils = require("modules/utils/core/utils")
local style = require("modules/ui/style")
local history = require("modules/utils/project/history")
local cache = require("modules/utils/game/cache")

---Class for worldAmbientAreaNode
---@class ambientArea : triggerArea
local ambientArea = setmetatable({}, { __index = triggerArea })

function ambientArea:new()
	local o = triggerArea.new(self)

    o.spawnListType = "files"
    o.dataType = "Ambient Area"
    o.spawnDataPath = "data/spawnables/area/ambientArea/"
    o.modulePath = "area/ambientArea"
    o.node = "worldAmbientAreaNode"
    o.description = "Trigger used for modifying the soundstage."
    o.previewNote = "Not previewed in editor."
    o.icon = IconGlyphs.CastAudioVariant

    o.triggerType = "Ambient"
    o.channels = { false, false, false, false, false, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false }
    o.eventSearchValues = {}
    o.reverbSearch = ""
    o.metadataParentSearch = ""
    o.parameterSearchValues = {}

    setmetatable(o, { __index = self })
   	return o
end

function ambientArea:loadSpawnData(data, position, rotation)
    triggerArea.loadSpawnData(self, data, position, rotation)

    if not self.trigger.Settings.Data["MetadataParent"] then
        self.trigger.Settings.Data["MetadataParent"] = {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = ""
        }
    end
end

function ambientArea:drawEvents(eventKey, default)
    self.eventSearchValues = self.eventSearchValues or {}
    self.eventSearchValues[eventKey] = self.eventSearchValues[eventKey] or {}

    if ImGui.TreeNodeEx(eventKey, ImGuiTreeNodeFlags.SpanFullWidth) then
        for index, event in pairs(self.trigger.Settings.Data[eventKey]) do
            ImGui.PushID(tostring(index) .. eventKey)
            local eventSearch = self.eventSearchValues[eventKey][index] or ""
            event["event"]["$value"], eventSearch, _ = style.trackedSearchDropdown("##event", default, event["event"]["$value"], eventSearch, cache.staticData.ambientData[eventKey], { element = self.object, width = style.getMaxWidth(250) - 30 })
            self.eventSearchValues[eventKey][index] = eventSearch

            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.Delete) then
                history.addAction(history.getElementChange(self.object))
                table.remove(self.trigger.Settings.Data[eventKey], index)
                table.remove(self.eventSearchValues[eventKey], index)
            end

            ImGui.PopID()
        end

        if ImGui.Button("+") then
            history.addAction(history.getElementChange(self.object))
            table.insert(self.trigger.Settings.Data[eventKey], {
                ["$type"] = "audioAudEventStruct",
                ["event"] = {
                    ["$type"] = "CName",
                    ["$storage"] = "string",
                    ["$value"] = ""
                }
            })
            table.insert(self.eventSearchValues[eventKey], "")
        end

        ImGui.TreePop()
    end
end

function ambientArea:drawAmbient(changed)
    if changed then
        self.trigger = {
            ["$type"] = "audioAmbientAreaNotifier",
            ["Settings"] = {
                ["Data"] = {
                    ["$type"] = "audioAmbientAreaSettings",
                    ["EventsOnActive"] = {},
                    ["EventsOnEnter"] = {},
                    ["EventsOnExit"] = {},
                    ["outerDistance"] = 10,
                    ["Parameters"] = {},
                    ["Priority"] = 16,
                    ["Reverb"] = {
                        ["$type"] = "CName",
                        ["$storage"] = "string",
                        ["$value"] = ""
                    },
                    ["verticalOuterDistance"] = 1,
                    ["isMusic"] = false,
                    ["MetadataParent"] = {
                        ["$type"] = "CName",
                        ["$storage"] = "string",
                        ["$value"] = ""
                    }
                }
            }
        }

        return
    end

    local max = utils.getTextMaxWidth({"Outer Distance", "Priority", "Reverb", "Vertical Outer Distance", "Is Music", "Metadata Parent"}) + 8 * ImGui.GetStyle().ItemSpacing.x

    style.mutedText("Priority")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    self.trigger.Settings.Data.Priority, changed = style.trackedDragInt(self.object, "##Priority", self.trigger.Settings.Data.Priority, 0, 9999, 75)
    if changed then
        self.trigger.Settings.Data.Priority = math.floor(self.trigger.Settings.Data.Priority)
    end

    style.mutedText("Outer Distance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    self.trigger.Settings.Data.outerDistance, _ = style.trackedDragFloat(self.object, "##outerDistance", self.trigger.Settings.Data.outerDistance, 0.01, 0, 9999, "%.2f", 75)

    style.mutedText("Vertical Outer Distance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    self.trigger.Settings.Data.verticalOuterDistance, _ = style.trackedDragFloat(self.object, "##verticalOuterDistance", self.trigger.Settings.Data.verticalOuterDistance, 0.01, 0, 9999, "%.2f", 75)

    style.mutedText("Reverb")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    self.reverbSearch = self.reverbSearch or ""
    self.trigger.Settings.Data.Reverb["$value"], self.reverbSearch, _ = style.trackedSearchDropdown("##reverb", "Search...", self.trigger.Settings.Data.Reverb["$value"], self.reverbSearch, cache.staticData.ambientData.reverb, { element = self.object, width = style.getMaxWidth(250) })

    style.mutedText("Metadata Parent")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    self.metadataParentSearch = self.metadataParentSearch or ""
    self.trigger.Settings.Data.MetadataParent["$value"], self.metadataParentSearch, _ = style.trackedSearchDropdown("##metadataParent", "Search...", self.trigger.Settings.Data.MetadataParent["$value"], self.metadataParentSearch, cache.staticData.ambientMetadataAll, { element = self.object, width = style.getMaxWidth(250) })

    style.mutedText("Is Music")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    self.trigger.Settings.Data.isMusic, _ = style.trackedCheckbox(self.object, "##isMusic", self.trigger.Settings.Data.isMusic)

    self:drawEvents("EventsOnActive", "amb_int_roomtone_office_med_01_aircon")
    self:drawEvents("EventsOnEnter", "mus_e3_amb_silent")
    self:drawEvents("EventsOnExit", "mus_e3_amb_megabuilding")

    if ImGui.TreeNodeEx("Parameters", ImGuiTreeNodeFlags.SpanFullWidth) then
        self.parameterSearchValues = self.parameterSearchValues or {}
        for index, parameter in pairs(self.trigger.Settings.Data["Parameters"]) do
            ImGui.PushID(tostring(index) .. "parameter")
            local parameterSearch = self.parameterSearchValues[index] or ""
            parameter["name"]["$value"], parameterSearch, _ = style.trackedSearchDropdown("##parameter", "Search...", parameter["name"]["$value"], parameterSearch, cache.staticData.ambientData.parameters, { element = self.object, width = style.getMaxWidth(250) - 120 })
            self.parameterSearchValues[index] = parameterSearch
            ImGui.SameLine()
            parameter["value"], _ = style.trackedDragFloat(self.object, "##value", parameter["value"], 0.01, 0, 1, "%.2f", 75)

            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.Delete) then
                history.addAction(history.getElementChange(self.object))
                table.remove(self.trigger.Settings.Data["Parameters"], index)
                table.remove(self.parameterSearchValues, index)
            end

            ImGui.PopID()
        end

        if ImGui.Button("+") then
            history.addAction(history.getElementChange(self.object))
            table.insert(self.trigger.Settings.Data["Parameters"], {
                ["$type"] = "audioAudParameter",
                ["name"] = {
                    ["$type"] = "CName",
                    ["$storage"] ="string",
                    ["$value"] = "amb_interior"
                },
                ["value"] = 1
            })
            table.insert(self.parameterSearchValues, "")
        end

        ImGui.TreePop()
    end
end

function ambientArea:getAvailableTriggers()
    return {
        ["Ambient"] = ambientArea.drawAmbient
    }
end

function ambientArea:draw()
    area.draw(self)

    if ImGui.TreeNodeEx(self.triggerType, ImGuiTreeNodeFlags.SpanFullWidth) then
        self:drawChannelSelect()
        self:drawAmbient(false)
        ImGui.TreePop()
    end
end

function ambientArea:export()
    local data = triggerArea.export(self)
    data.type = "worldAmbientAreaNode"

    return data
end

return ambientArea
