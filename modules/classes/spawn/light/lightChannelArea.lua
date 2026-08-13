local area = require("modules/classes/spawn/area/area")
local utils = require("modules/utils/core/utils")
local style = require("modules/ui/style")
local lcHelper = require("modules/utils/ui/lightChannelHelper")
local lightChannelVolume = require("modules/utils/preview/lightChannelVolume")

---Class for worldLightChannelVolumeNode
---@class lightChannelArea : area
---@field lightChannels boolean[]
---@field volumePreviewed boolean
---@field private volumeSignature string?
---@field private volumeBounds table?
---@field private volumeRebuilding boolean
---@field private markerCache table?
local lightChannelArea = setmetatable({}, { __index = area })

---@param markers table[]
---@param height number
---@param position Vector4
---@param channels boolean[]
---@param enabled boolean
---@return string
local function buildSignature(markers, height, position, channels, enabled)
    local parts = {
        enabled and "1" or "0",
        string.format("%.3f", height or 0),
        string.format("%.3f|%.3f|%.3f", position.x, position.y, position.z)
    }

    for _, state in ipairs(channels) do
        table.insert(parts, state and "1" or "0")
    end

    for _, marker in ipairs(markers) do
        table.insert(parts, string.format("%.3f|%.3f|%.3f", marker.x, marker.y, marker.z))
    end

    return table.concat(parts, ";")
end

function lightChannelArea:new()
	local o = area.new(self)

    o.spawnListType = "files"
    o.dataType = "Light Channel Area"
    o.spawnDataPath = "data/spawnables/lights/lightChannelArea/"
    o.modulePath = "light/lightChannelArea"
    o.node = "worldLightChannelVolumeNode"
    o.description = "Limits light with the corresponding light channel to the specified area."
    o.previewNote = "Previewed with an entLightChannelComponent, the entity side equivalent of the node.\nLighting inside the editor reacts to it, but it is not the node itself, so the ingame result can differ."
    o.icon = IconGlyphs.LightbulbAutoOutline

    o.lightChannels = { true, true, true, true, true, true, true, true, true, false, false, false }
    o.volumePreviewed = true

    o.volumeSignature = nil
    o.volumeBounds = nil
    o.volumeRebuilding = false
    o.markerCache = nil

    setmetatable(o, { __index = self })
   	return o
end

---Live outline geometry.
---
---`self.markers` is only filled while saving, so it is of no use for a preview that has to follow the
---markers as they get dragged around. Reading them from the hierarchy is not free though, and both
---area and marker transforms bump the wireframe epoch, so the result is cached against it.
---@protected
---@return table[] markers, number height
function lightChannelArea:getVolumeGeometry()
    local sUI = self.object and self.object.sUI or nil
    local stamp = string.format("%s:%s", tostring(sUI and sUI.cacheEpoch or 0), tostring(sUI and sUI.wireframeEpoch or 0))

    if self.markerCache and self.markerCache.stamp == stamp then
        return self.markerCache.markers, self.markerCache.height
    end

    local markers, height = self:getMarkersData()
    self.markerCache = { stamp = stamp, markers = markers, height = height }

    return markers, height
end

---World space bounds of the volume, used to pick the lights a change can reach.
---@protected
---@param markers table[]
---@param height number
---@return table? bounds `{min, max}`, or nil when there is no volume.
function lightChannelArea:getVolumeBounds(markers, height)
    if #markers < 3 or not height or height <= 0 then return nil end

    local min = { x = math.huge, y = math.huge, z = math.huge }
    local max = { x = -math.huge, y = -math.huge, z = -math.huge }

    for _, marker in ipairs(markers) do
        min.x, max.x = math.min(min.x, marker.x), math.max(max.x, marker.x)
        min.y, max.y = math.min(min.y, marker.y), math.max(max.y, marker.y)
        min.z, max.z = math.min(min.z, marker.z), math.max(max.z, marker.z + height)
    end

    return { min = min, max = max }
end

---Creates or refreshes the light channel volume on the spawned entity.
---@protected
---@param entity entEntity? Defaults to the spawned entity.
---@param force boolean? Rebuild even when nothing changed, used right after assembling.
function lightChannelArea:applyVolume(entity, force)
    entity = entity or self:getEntity()
    if not entity or not lightChannelVolume.isSupported() then return end

    local markers, height = self:getVolumeGeometry()
    local signature = buildSignature(markers, height, self.position, self.lightChannels, self.volumePreviewed)

    if not force and signature == self.volumeSignature then return end
    self.volumeSignature = signature

    local shape = nil
    if self.volumePreviewed then
        -- Vertices are component local, and the node's volume is anchored to the markers rather than to
        -- the node, so the shape is rebuilt around the entity position whenever either side moves.
        shape = lightChannelVolume.buildPrismShape(markers, height, self.position)
    end

    lightChannelVolume.apply(entity, shape, self.lightChannels, self.volumePreviewed)
    self.volumeBounds = self:getVolumeBounds(markers, height) or self.volumeBounds

    -- A light picks up the volumes it sits in when its own component registers, and nothing tells it
    -- about one that changed afterwards, so the lights this volume covers get re-registered - once the
    -- volume is up to date, which is why this hangs off assembling rather than off the edit itself.
    if force then
        lightChannelVolume.scheduleLightRefresh(self.object, self.lightChannels, self.volumeBounds)
    end
end

function lightChannelArea:despawn()
    local hadVolume = self.volumeSignature ~= nil
    local bounds = self.volumeBounds

    self.volumeSignature = nil
    area.despawn(self)

    -- The volume went away with the entity, so the lights it was restricting have to let go of it -
    -- unless this is the despawn half of a rebuild, where the assemble that follows queues the refresh
    -- itself. Queueing here too runs the lights twice whenever assembling outlasts the debounce.
    if hadVolume and not self.volumeRebuilding then
        lightChannelVolume.scheduleLightRefresh(self.object, self.lightChannels, bounds)
    end
end

function lightChannelArea:respawn()
    self.volumeRebuilding = true
    area.respawn(self)
    self.volumeRebuilding = false
end

---Queues the rebuild that commits an edit to the volume.
---
---Called from every point that changes what the volume looks like. `onAssemble` deliberately does not
---go through here: it is what a queued rebuild ends up running, so queueing from it would loop.
---@protected
---@param live boolean? Also update the live component right away. Only worth it for an edit that is
---dragged, where the rebuild is a settle: for a one-shot edit it just commits the same change twice,
---once now and once out of the rebuild, which reads as the volume updating twice.
function lightChannelArea:refreshVolume(live)
    if live then
        self:applyVolume()
    end

    lightChannelVolume.scheduleVolumeRebuild(self)
end

function lightChannelArea:onAssemble(entity)
    area.onAssemble(self, entity)

    self:applyVolume(entity, true)
end

function lightChannelArea:update()
    area.update(self)

    self:refreshVolume(true)
end

function lightChannelArea:onOutlineChanged()
    self:refreshVolume(true)
end

---Called by the light channel editor, for single as well as grouped edits.
function lightChannelArea:onLightChannelsChanged()
    self:refreshVolume(false)
end

function lightChannelArea:save()
    local data = area.save(self)

    data.lightChannels = utils.deepcopy(self.lightChannels)
    data.volumePreviewed = self.volumePreviewed

    return data
end

function lightChannelArea:getGroupedProperties()
    local properties = area.getGroupedProperties(self)

    properties["lcGrouped"] = lcHelper.getGroupedProperties(self)

    return properties
end

function lightChannelArea:export()
    local data = area.export(self, 0, 0, -0.01)
    data.type = "worldLightChannelVolumeNode"

    data.data.channels = utils.buildBitfieldString(self.lightChannels, style.lightChannelEnum)

    return data
end

function lightChannelArea:draw()
    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize", "Outline Path", "Light Volume" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    area.draw(self)

    style.mutedText("Light Volume")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)

    local previewed, changed = style.toggleButton(IconGlyphs.CubeOutline .. "##volumePreviewed", self.volumePreviewed)
    if changed then
        self.volumePreviewed = previewed
        -- Switching it off applies live, so the restriction lifts on the click rather than on the rebuild.
        self:refreshVolume(not previewed)
    end
    style.tooltip("Apply the light channels to the editor lighting, using the outline as the volume.\nTurn off to keep the node as an outline only.")

    if ImGui.TreeNodeEx("Light Channels") then
        local channelsChanged
        self.lightChannels, channelsChanged = style.drawLightChannelsSelector(self.object, self.lightChannels)

        if channelsChanged then
            self:onLightChannelsChanged()
        end

        ImGui.TreePop()
    end
end

return lightChannelArea
