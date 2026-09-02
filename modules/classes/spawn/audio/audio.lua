local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local cache = require("modules/utils/game/cache")
local audioData = require("modules/utils/data/audioData")
local history = require("modules/utils/project/history")
local radiusSphere = require("modules/utils/preview/radiusSphere")

---Class for worldStaticSoundEmitterNode
---
---The event is `spawnData`, and everything else on the node is tuned around it. Two of those
---settings are derived from the event's own metadata rather than guessed:
--- * `radius` is seeded from the event's attenuation, which is what 79% of shipped emitters do.
--- * a warning is shown for events that will not keep playing here (one-shots, non-positional).
---See `modules/utils/data/audioData.lua` for where that metadata comes from.
---@class sound : visualized
---@field private radius number
---@field private occlusionEnabled boolean
---@field private usePhysicsObstruction boolean
---@field private obstructionChangeTime number
---@field private useDoppler boolean
---@field private emitterMetadataName string
---@field private emitterMetadataSearch string
---@field private radiusPreviewed boolean
local sound = setmetatable({}, { __index = visualized })

function sound:new()
	local o = visualized.new(self)

    o.spawnListType = "list"
    o.dataType = "Sounds"
    o.spawnDataPath = "data/spawnables/audio/sounds/"
    o.modulePath = "audio/audio"
    o.node = "worldStaticSoundEmitterNode"
    o.description = "Plays a sound"
    o.previewNote = "The list holds every event that keeps playing on an emitter.\nRadius is set from the event's own range when you spawn it,\nand can be previewed at true scale."
    o.icon = IconGlyphs.VolumeHigh
    o.entryFilter = "audioTag"
    o.entryNote = "audioRange"

    o.radius = 5
    o.previewColor = "mediumvioletred"
    o.emitterMetadataName = ""
    o.emitterMetadataSearch = ""
    o.occlusionEnabled = true
    o.usePhysicsObstruction = true
    o.obstructionChangeTime = 0.2
    -- Off by default: 3 of 3628 shipped emitters enable doppler, and it only makes sense on an
    -- emitter that moves relative to the listener.
    o.useDoppler = false
    o.previewed = true
    o.radiusPreviewed = false
    o.assetPreviewType = "position"

    setmetatable(o, { __index = self })
   	return o
end

function sound:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    if self.emitterMetadataName == "" then
        if cache.staticData.staticMetadata[self.spawnData] then
            self.emitterMetadataName = cache.staticData.staticMetadata[self.spawnData][1]
        end
    end

    -- Fresh spawns carry no radius, so the event's own attenuation is a far better starting point
    -- than a fixed number. Saved elements always serialize a radius and keep it.
    if data.radius == nil then
        self.radius = audioData.getEventAttenuation(self.spawnData) or self.radius
    end
end

function sound:onAssemble(entity)
    visualized.onAssemble(self, entity)

    -- Needed for sound to play
    local component = gameaudioSoundComponent.new()
    component.name = "sound"
    entity:AddComponent(component)

    entity:QueueEvent(SoundPlayEvent.new ({ soundName = self.spawnData }))
end

function sound:spawn()
    local audio = self.spawnData
    self.spawnData = "base\\spawner\\empty_entity.ent"

    visualized.spawn(self)
    self.spawnData = audio
end

---@param entity entEntity
function sound:onAfterPreviewAssemble(entity)
    visualized.onAfterPreviewAssemble(self, entity)

    radiusSphere.attach(self, entity)
end

---@param entity entEntity
function sound:onAfterPreviewScale(entity)
    visualized.onAfterPreviewScale(self, entity)

    radiusSphere.update(self, entity)
end

function sound:setPreview(state)
    visualized.setPreview(self, state)

    -- Not in `visualizer.toggleAll`'s component list, so it needs settling by hand.
    radiusSphere.update(self)
end

function sound:save()
    local data = visualized.save(self)

    data.radius = self.radius
    data.radiusPreviewed = self.radiusPreviewed
    data.emitterMetadataName = self.emitterMetadataName
    data.occlusionEnabled = self.occlusionEnabled
    data.usePhysicsObstruction = self.usePhysicsObstruction
    data.obstructionChangeTime = self.obstructionChangeTime
    data.useDoppler = self.useDoppler

    return data
end

---Draws the summary line for the selected event, plus a warning when it will not keep playing.
function sound:drawEventInfo()
    local warning = audioData.getEmitterWarning(self.spawnData)

    if warning then
        style.styledText(IconGlyphs.AlertOutline, style.warnColor)
        style.tooltip(warning)
        ImGui.SameLine()
    end

    local summary = audioData.describeEvent(self.spawnData)
    if summary == "" then
        summary = "No metadata for this event"
    end

    style.mutedText(summary)
    if warning then
        style.tooltip(warning)
    end
end

function sound:draw()
    visualized.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Radius", "Occlusion", "Physics Obstruction", "Obstruction Fade Time", "Use Doppler", "Emitter Metadata Name" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    self:drawEventInfo()
    self:drawPreviewCheckbox("Visualize", self.maxPropertyWidth)

    style.mutedText("Radius")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.radius, change = style.trackedDragFloat(self.object, "##radius", self.radius, 0.01, 0, 9999, "%.2f", 80)
    if change then
        self:updateScale()
    end

    radiusSphere.toggleButton(self, history, style)

    local attenuation = audioData.getEventAttenuation(self.spawnData)
    if attenuation then
        local matched = math.abs(self.radius - attenuation) < 0.005

        ImGui.SameLine()
        style.pushGreyedOut(matched)
        if ImGui.Button(IconGlyphs.ArrowCollapseHorizontal) and not matched then
            history.addAction(history.getElementChange(self.object))
            self.radius = attenuation
            self:updateScale()
        end
        style.popGreyedOut(matched)
        style.tooltip(string.format("Match the event's own attenuation range (%.2fm).\nShipped emitters do exactly this in 79%% of cases.", attenuation))
    end

    style.mutedText("Occlusion")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.occlusionEnabled, _ = style.trackedCheckbox(self.object, "##occlusionEnabled", self.occlusionEnabled)
    style.tooltip("Muffle the sound when geometry sits between it and the listener.")

    style.mutedText("Physics Obstruction")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.usePhysicsObstruction, _ = style.trackedCheckbox(self.object, "##usePhysicsObstruction", self.usePhysicsObstruction)
    style.tooltip("Muffle the sound when a physics body sits between it and the listener.")

    style.mutedText("Obstruction Fade Time")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.obstructionChangeTime, _ = style.trackedDragFloat(self.object, "##obstructionChangeTime", self.obstructionChangeTime, 0.01, 0, 10, "%.2f", 80)
    style.tooltip("Seconds the muffling takes to fade in and out.\nShipped emitters use 0.2 to 0.5.")

    style.mutedText("Use Doppler")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.useDoppler, _ = style.trackedCheckbox(self.object, "##useDoppler", self.useDoppler)
    style.tooltip("Pitch-shift with listener movement.\nOnly meaningful for an emitter that moves; shipped static emitters almost never enable it.")

    style.mutedText("Emitter Metadata Name")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.emitterMetadataSearch = self.emitterMetadataSearch or ""
    self.emitterMetadataName, self.emitterMetadataSearch, change = style.trackedSearchDropdown("##emitterMetadataName", "Search...", self.emitterMetadataName, self.emitterMetadataSearch, audioData.getEmitterMetadataNames(), {
        element = self.object,
        width = style.getMaxWidth(250),
        matchContentWidth = true,
        allowCustom = true,
        optionDisplayFn = audioData.getEmitterMetadataLabel,
        optionTooltipFn = audioData.getEmitterMetadataTooltip
    })
    style.tooltip("Named acoustics preset applied to this emitter.\nThe 'ignore_Nm' presets stop occlusion being applied within N metres, so the sound is not muffled up close.")
end

function sound:getArrowSize()
    local max = math.min(math.max(self.radius / 30, 0.6), 0.8)
    return { x = max, y = max, z = max }
end

function sound:getVisualizerSize()
    local x = math.min(math.max(self.radius / 125, 0.125), 0.33)

    return { x = x, y = x, z = x }
end

function sound:getProperties()
    return self:addNodeProperty(visualized.getProperties(self))
end

function sound:export()
    local data = visualized.export(self)
    data.type = "worldStaticSoundEmitterNode"
    data.data = {
        occlusionEnabled = self.occlusionEnabled and 1 or 0,
        radius = self.radius,
        usePhysicsObstruction = self.usePhysicsObstruction and 1 or 0,
        obstructionChangeTime = self.obstructionChangeTime,
        useDoppler = self.useDoppler and 1 or 0,
        Settings = {
            ["Data"] = {
                ["$type"] = "audioAmbientAreaSettings",
                ["EventsOnActive"] = {
                    {
                        ["$type"] = "audioAudEventStruct",
                        ["event"] = {
                            ["$type"] = "CName",
                            ["$storage"] = "string",
                            ["$value"] = self.spawnData
                        }
                    }
                },
            }
        },
        ["emitterMetadataName"] = {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = self.emitterMetadataName or ""
        }
    }

    return data
end

return sound
