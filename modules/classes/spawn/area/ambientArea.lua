local triggerArea = require("modules/classes/spawn/area/triggerArea")
local area = require("modules/classes/spawn/area/area")
local utils = require("modules/utils/core/utils")
local style = require("modules/ui/style")
local history = require("modules/utils/project/history")
local cache = require("modules/utils/game/cache")
local audioData = require("modules/utils/data/audioData")

---Selector option sets, built once from the cooked metadata merged with what shipped areas use.
---`Reverb` and `MetadataParent` are closed sets in the game data: the engine looks the name up in
---`audioDynamicReverbSettings` / `audioAmbientAreaSettings`, so anything else is silently ignored.
---`Parameters` names are Wwise RTPCs, of which the game knows 544 - far more than the ~100 that
---happen to appear on shipped areas.
local optionCache = {}

---@param key string Vocabulary key in `audioData`.
---@param harvested string[]? Names collected from shipped sector data.
---@return string[] options
local function getOptions(key, harvested)
    if not optionCache[key] then
        optionCache[key] = audioData.getMergedVocabulary(key, harvested)
    end

    return optionCache[key]
end

---Options for one of the three event lists.
---An active event has to loop and be positional to keep playing over the area, exactly like an
---emitter event, so that catalogue is offered alongside the events shipped areas actually use.
---Enter and exit events fire once on a boundary crossing, so only the shipped names are offered.
---@param eventKey "EventsOnActive"|"EventsOnEnter"|"EventsOnExit"
---@return string[] options
local function getEventOptions(eventKey)
    if not optionCache[eventKey] then
        local harvested = cache.staticData.ambientData[eventKey]

        if eventKey == "EventsOnActive" then
            optionCache[eventKey] = audioData.mergeNames(audioData.getEmitterEventNames(), harvested)
        else
            optionCache[eventKey] = audioData.mergeNames(harvested)
        end
    end

    return optionCache[eventKey]
end

---What most shipped interior areas do, measured over 949 of them: 61% ramp `amb_interior`, and the
---modal setup pairs it with `revb_interior_default` at priority 11. Applied as one action, because
---setting the three by hand is the main thing that makes an interior tedious to author.
local INTERIOR_PRESET = {
    parameter = "amb_interior",
    parameterValue = 0.3,
    reverb = "revb_interior_default",
    priority = 11
}

---Four corner events, in the order the engine reads them. Shipped areas either use one `*_quad`
---event four times or a matching `_FL`/`_FR`/`_RR`/`_RL` set.
local QUAD_CORNERS = { "Front left", "Front right", "Rear right", "Rear left" }

---Class for worldAmbientAreaNode
---@class ambientArea : triggerArea
local ambientArea = setmetatable({}, { __index = triggerArea })

---@return table cname
local function cname(value)
    return { ["$type"] = "CName", ["$storage"] = "string", ["$value"] = value or "" }
end

---@return table eventStruct
local function eventStruct(value)
    return { ["$type"] = "audioAudEventStruct", ["event"] = cname(value) }
end

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
    o.quadSearchValues = {}

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
            event["event"]["$value"], eventSearch, _ = style.trackedSearchDropdown("##event", default, event["event"]["$value"], eventSearch, getEventOptions(eventKey), { element = self.object, width = style.getMaxWidth(250) - 30, allowCustom = true })
            self.eventSearchValues[eventKey][index] = eventSearch

            local warning = eventKey == "EventsOnActive" and audioData.getEmitterWarning(event["event"]["$value"]) or nil
            local summary = audioData.describeEvent(event["event"]["$value"])
            if warning then
                ImGui.SameLine()
                style.styledText(IconGlyphs.AlertOutline, style.warnColor)
                style.tooltip(warning)
            elseif summary ~= "" then
                ImGui.SameLine()
                style.mutedText(IconGlyphs.InformationOutline)
                style.tooltip(summary)
            end

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
            table.insert(self.trigger.Settings.Data[eventKey], eventStruct(""))
            table.insert(self.eventSearchValues[eventKey], "")
        end

        ImGui.TreePop()
    end
end

---Applies the setup most shipped interiors use: the `amb_interior` ramp, an interior reverb and the
---priority they sit at. Existing values are left alone, so it fills gaps rather than overwriting.
function ambientArea:applyInteriorPreset()
    local settings = self.trigger.Settings.Data

    local hasParameter = false
    for _, parameter in pairs(settings.Parameters) do
        if parameter["name"] and parameter["name"]["$value"] == INTERIOR_PRESET.parameter then
            hasParameter = true
            break
        end
    end

    if not hasParameter then
        table.insert(settings.Parameters, {
            ["$type"] = "audioAudParameter",
            ["name"] = cname(INTERIOR_PRESET.parameter),
            ["value"] = INTERIOR_PRESET.parameterValue
        })
        table.insert(self.parameterSearchValues, "")
    end

    if settings.Reverb["$value"] == "" or settings.Reverb["$value"] == "None" then
        settings.Reverb["$value"] = INTERIOR_PRESET.reverb
    end

    settings.Priority = INTERIOR_PRESET.priority
end

---The quad emitter struct, created on first use. It is left absent otherwise so the export keeps the
---engine defaults rather than writing a disabled block.
---@return table quadSettings
function ambientArea:ensureQuadSettings()
    local settings = self.trigger.Settings.Data

    if type(settings.quadSettings) ~= "table" then
        settings.quadSettings = {
            ["$type"] = "audioQuadEmitterSettings",
            ["Angle"] = 0,
            ["Enabled"] = false,
            ["Events"] = { ["Elements"] = { eventStruct(""), eventStruct(""), eventStruct(""), eventStruct("") } },
            ["Interleaved"] = false,
            ["Offset"] = { ["$type"] = "Vector3", ["X"] = 0, ["Y"] = 0, ["Z"] = 0 },
            ["Radius"] = 5
        }
    end

    return settings.quadSettings
end

---Quad emitters place four corner sources around the area instead of one at its centre - crowds,
---wind, rain and foliage. CDPR authored the four corner events on plenty of shipped areas, but
---`Enabled` is false on every one of them: 0 enabled out of ~4,900 ambient areas sampled across
---~19% of the shipped sectors (every interior, quest and always sector included), 0 out of ~13,000
---static sound emitters, and 0 of the 11 cooked metadata presets. So the corner events below match
---what CDPR authored, but nothing in the game ships with the emitter switched on.
function ambientArea:drawQuadSettings()
    local quad = self.trigger.Settings.Data.quadSettings
    local enabled = type(quad) == "table" and quad.Enabled == true

    local open = style.treeNodeWithNote("Quad Emitter", enabled and "(on)" or "")
    style.tooltip("Play four corner sources around the area rather than one in the middle.\nShipped areas author corner events for crowds, wind, rain and foliage, but not one of\nthem ships with Enabled ticked - so this switch is untested against vanilla behaviour.")
    if not open then return end

    quad = self:ensureQuadSettings()

    local max = utils.getTextMaxWidth({ "Enabled", "Radius", "Angle", "Interleaved", "Front right" }) + 8 * ImGui.GetStyle().ItemSpacing.x

    style.mutedText("Enabled")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    quad.Enabled, _ = style.trackedCheckbox(self.object, "##quadEnabled", quad.Enabled == true)
    style.tooltip("No shipped ambient area or static emitter has this ticked, even the ones that have\nall four corner events filled in. Verify in game that it does what you expect.")

    style.mutedText("Radius")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    quad.Radius, _ = style.trackedDragFloat(self.object, "##quadRadius", quad.Radius, 0.01, 0, 9999, "%.2f", 75)
    style.tooltip("How far the four corners sit from the centre. Shipped areas use 1 to 6.")

    style.mutedText("Angle")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    quad.Angle, _ = style.trackedDragFloat(self.object, "##quadAngle", quad.Angle, 0.1, -360, 360, "%.1f", 75)
    style.tooltip("Rotates the four corners around the centre.\nMost shipped areas leave this at 0, a few use 90, 145 or 250.")

    style.mutedText("Interleaved")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    quad.Interleaved, _ = style.trackedCheckbox(self.object, "##quadInterleaved", quad.Interleaved == true)

    self.quadSearchValues = self.quadSearchValues or {}

    for index, corner in ipairs(QUAD_CORNERS) do
        local element = quad.Events.Elements[index]
        if element then
            ImGui.PushID("quadEvent" .. index)
            style.mutedText(corner)
            ImGui.SameLine()
            ImGui.SetCursorPosX(max)

            local search = self.quadSearchValues[index] or ""
            element["event"]["$value"], search, _ = style.trackedSearchDropdown("##quadEvent", "Search...", element["event"]["$value"], search, getEventOptions("EventsOnActive"), { element = self.object, width = style.getMaxWidth(250) - 30, allowCustom = true })
            self.quadSearchValues[index] = search

            local summary = audioData.describeEvent(element["event"]["$value"])
            if summary ~= "" then
                ImGui.SameLine()
                style.mutedText(IconGlyphs.InformationOutline)
                style.tooltip(summary)
            end

            -- Shipped areas either repeat one `*_quad` event or use a matching corner set, so
            -- copying the first corner outward is the common case.
            if index == 1 then
                ImGui.SameLine()
                if ImGui.Button(IconGlyphs.ContentCopy) then
                    history.addAction(history.getElementChange(self.object))
                    for other = 2, #QUAD_CORNERS do
                        quad.Events.Elements[other]["event"]["$value"] = element["event"]["$value"]
                    end
                end
                style.tooltip("Copy this event to the other three corners")
            end

            ImGui.PopID()
        end
    end

    ImGui.TreePop()
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

    local max = utils.getTextMaxWidth({"Outer Distance", "Priority", "Reverb", "Vertical Outer Distance", "Metadata Parent"}) + 8 * ImGui.GetStyle().ItemSpacing.x

    if ImGui.Button("Interior defaults") then
        history.addAction(history.getElementChange(self.object))
        self:applyInteriorPreset()
    end
    style.tooltip(string.format(
        "Fill in what most shipped interiors do:\n  %s = %s\n  Reverb = %s\n  Priority = %d\nExisting values are kept.",
        INTERIOR_PRESET.parameter, tostring(INTERIOR_PRESET.parameterValue), INTERIOR_PRESET.reverb, INTERIOR_PRESET.priority))

    style.mutedText("Priority")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    self.trigger.Settings.Data.Priority, changed = style.trackedDragInt(self.object, "##Priority", self.trigger.Settings.Data.Priority, 0, 9999, 75)
    if changed then
        self.trigger.Settings.Data.Priority = math.floor(self.trigger.Settings.Data.Priority)
    end
    style.tooltip("Which area wins where several overlap.\nShipped areas only ever use 0 to 12, so the default of 16 deliberately beats all of them.")

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
    self.trigger.Settings.Data.Reverb["$value"], self.reverbSearch, _ = style.trackedSearchDropdown("##reverb", "Search...", self.trigger.Settings.Data.Reverb["$value"], self.reverbSearch, getOptions("reverbs", cache.staticData.ambientData.reverb), { element = self.object, width = style.getMaxWidth(250), allowCustom = true })
    style.tooltip("Reverb applied inside the area.\nThese are base names: the engine appends a size suffix at runtime, so one name covers the small, medium and large variants.")

    style.mutedText("Metadata Parent")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    self.metadataParentSearch = self.metadataParentSearch or ""
    self.trigger.Settings.Data.MetadataParent["$value"], self.metadataParentSearch, _ = style.trackedSearchDropdown("##metadataParent", "Search...", self.trigger.Settings.Data.MetadataParent["$value"], self.metadataParentSearch, getOptions("ambientAreaPresets", cache.staticData.ambientMetadataAll), { element = self.object, width = style.getMaxWidth(250), allowCustom = true })
    style.tooltip("Inherit a shipped interior preset - room, office, corridor, staircase, elevator.\nOne field gets you a correct interior without setting reverb and parameters by hand.")

    self:drawEvents("EventsOnActive", "amb_int_roomtone_office_med_01_aircon")
    self:drawEvents("EventsOnEnter", "mus_e3_amb_silent")
    self:drawEvents("EventsOnExit", "mus_e3_amb_megabuilding")
    self:drawQuadSettings()

    local parametersOpen = ImGui.TreeNodeEx("Parameters", ImGuiTreeNodeFlags.SpanFullWidth)
    style.tooltip("Wwise parameters ramped while the player is inside the area.\nThis is how most shipped areas do their work: 'amb_interior' at 1 is what tells the game it is indoors.")

    if parametersOpen then
        self.parameterSearchValues = self.parameterSearchValues or {}
        for index, parameter in pairs(self.trigger.Settings.Data["Parameters"]) do
            ImGui.PushID(tostring(index) .. "parameter")
            local parameterSearch = self.parameterSearchValues[index] or ""
            parameter["name"]["$value"], parameterSearch, _ = style.trackedSearchDropdown("##parameter", "Search...", parameter["name"]["$value"], parameterSearch, getOptions("gameParameters", cache.staticData.ambientData.parameters), { element = self.object, width = style.getMaxWidth(250) - 120, allowCustom = true })
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
