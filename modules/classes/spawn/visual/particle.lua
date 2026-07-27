local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local Cron = require("modules/utils/Cron")
local previewSyncManager = require("modules/utils/previewSyncManager")
local previewTimeline = require("modules/ui/previewTimeline")

---Class for worldStaticParticleNode
---@class particle : visualized
---@field emissionRate number
---@field respawnOnMove boolean
---@field private previewLoop boolean
---@field private previewLoopInterval number
---@field private previewStartDelay number
---@field private previewLoopRestartCron integer?
---@field private previewLoopRestartDelay number
---@field private maxPropertyWidth number
local particle = setmetatable({}, { __index = visualized })

function particle:new()
	local o = visualized.new(self)

    o.spawnListType = "list"
    o.dataType = "Particles"
    o.spawnDataPath = "data/spawnables/visual/particles/"
    o.modulePath = "visual/particle"
    o.node = "worldStaticParticleNode"
    o.description = "Plays a particle system, from a given .particle file"
    o.icon = IconGlyphs.Shimmer

    o.emissionRate = 1
    o.respawnOnMove = false
    o.previewLoop = false
    o.previewLoopInterval = 2
    o.previewStartDelay = 0
    o.previewLoopRestartCron = nil
    o.previewLoopRestartDelay = 0.05
    o.previewColor = "magenta"

    o.assetPreviewType = "position"
    o.assetPreviewDelay = 0.1

    o.maxPropertyWidth = nil

    setmetatable(o, { __index = self })
   	return o
end

function particle:stopPreviewLoop()
    if self.previewLoopRestartCron then
        Cron.Halt(self.previewLoopRestartCron)
        self.previewLoopRestartCron = nil
    end
end

function particle:preparePreviewSyncPlayback()
    if not self:isSpawned() or self.isAssetPreview then
        return
    end

    local entity = self:getEntity()
    if not entity then
        return
    end

    local component = entity:FindComponentByName("particle")
    if not component then
        return
    end

    self:stopPreviewLoop()
    component:Toggle(false)
end

function particle:restartPreviewLoopPlayback()
    if not self:isSpawned() or self.isAssetPreview then
        return
    end

    local entity = self:getEntity()
    if not entity then
        return
    end

    local component = entity:FindComponentByName("particle")
    if not component then
        return
    end

    component:Toggle(false)

    if self.previewLoopRestartCron then
        Cron.Halt(self.previewLoopRestartCron)
        self.previewLoopRestartCron = nil
    end

    -- Delay avoids toggle-off/toggle-on being collapsed in one frame.
    self.previewLoopRestartCron = Cron.After(self.previewLoopRestartDelay, function()
        self.previewLoopRestartCron = nil

        if not self.previewLoop or not self:isSpawned() or self.isAssetPreview then
            return
        end

        local currentEntity = self:getEntity()
        if not currentEntity then
            return
        end

        local currentComponent = currentEntity:FindComponentByName("particle")
        if currentComponent then
            currentComponent:Toggle(true)
        end
    end)
end

function particle:onAssemble(entity)
    visualized.onAssemble(self, entity)

    local component = entParticlesComponent.new()
    ResourceHelper.LoadReferenceResource(component, "particleSystem", self.spawnData, true)
    component.name = "particle"
    component.emissionRate = self.emissionRate
    entity:AddComponent(component)
    previewSyncManager.refreshSpawnable(self)
end

function particle:spawn()
    local particle = self.spawnData
    self.spawnData = "base\\spawner\\empty_entity.ent"

    visualized.spawn(self)
    self.spawnData = particle
    previewSyncManager.registerSpawnable(self)
end

function particle:despawn()
    previewSyncManager.unregisterSpawnable(self)
    self:stopPreviewLoop()
    visualized.despawn(self)
end

function particle:update()
    if not self.respawnOnMove then
        visualized.update(self)
    end
end

function particle:onEdited(edited)
    if self.respawnOnMove and self:isSpawned() and edited then
        self:despawn()
        self:spawn()
    end
end

function particle:onParentChanged()
    if self:isSpawned() then
        previewSyncManager.refreshSpawnable(self)
    end
end

function particle:save()
    local data = visualized.save(self)
    data.emissionRate = self.emissionRate
    data.respawnOnMove = self.respawnOnMove
    data.previewLoop = self.previewLoop
    data.previewLoopInterval = self.previewLoopInterval
    data.previewStartDelay = self.previewStartDelay

    return data
end

function particle:getVisualizerSize()
    return { x = 0.15, y = 0.15, z = 0.15 }
end

function particle:draw()
    visualized.draw(self)
    local changed

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Emission Rate", "Respawn on Move", "Preview Loop", "Loop Interval", "Start Delay" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    style.mutedText("Emission Rate")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.emissionRate, changed = style.trackedDragFloat(self.object, "##emissionRate", self.emissionRate, 0.01, 0, 9999, "%.2f", 80)
    if changed then
        self.emissionRate = math.max(self.emissionRate, 0)

        local entity = self:getEntity()
        if entity then
            local component = entity:FindComponentByName("particle")
            component.emissionRate = self.emissionRate
        end
    end

    style.mutedText("Respawn on Move")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.respawnOnMove, _ = style.trackedCheckbox(self.object, "##respawnOnMove", self.respawnOnMove)
    style.tooltip("Respawns the particle system when the object is moved. Use this when the particle system does not move, or only parts of it")

    if ImGui.TreeNodeEx("Previewing Options", ImGuiTreeNodeFlags.SpanFullWidth) then
        local previewPropertyWidth = self.maxPropertyWidth + ImGui.GetTreeNodeToLabelSpacing()

        self:drawPreviewCheckbox("Visualize", previewPropertyWidth)

        style.mutedText("Preview Loop")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.previewLoop, changed = style.trackedCheckbox(self.object, "##particlePreviewLoop", self.previewLoop)
        if changed then
            previewSyncManager.refreshSpawnable(self)
            if not self.previewLoop then
                self:stopPreviewLoop()
            else
                previewSyncManager.syncSpawnableDomain(self)
            end
        end
        style.tooltip("World Builder preview only. Replays this particle in a loop. This setting is never exported.")

        style.mutedText("Loop Interval")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.previewLoopInterval, changed = style.trackedDragFloat(self.object, "##particlePreviewLoopInterval", self.previewLoopInterval, 0.05, 0.1, 120, "%.2f sec", 80)
        if changed then
            self.previewLoopInterval = math.max(self.previewLoopInterval, 0.1)
            previewSyncManager.refreshSpawnable(self)
        end

        style.mutedText("Start Delay")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.previewStartDelay, changed = style.trackedDragFloat(self.object, "##particlePreviewStartDelay", self.previewStartDelay, 0.05, 0, 120, "%.2f sec", 80)
        if changed then
            self.previewStartDelay = math.max(self.previewStartDelay, 0)
            previewSyncManager.refreshSpawnable(self)
        end

        local openTimelineLabel, openTimelineHiddenText = style.resolveActionLabel(IconGlyphs.ChartTimeline, "Open Preview Timeline", "particlePreviewTimelineOpen", nil, true)
        if ImGui.Button(openTimelineLabel) then
            previewTimeline.openForSpawnable(self)
        end
        if openTimelineHiddenText then
            style.tooltipActionLabel(openTimelineHiddenText, openTimelineHiddenText .. "\nOpen Preview Timeline focused on this particle's synchronization domain.")
        else
            style.tooltip("Open Preview Timeline focused on this particle's synchronization domain.")
        end

        ImGui.TreePop()
    end
end

function particle:getProperties()
    return self:addNodeProperty(visualized.getProperties(self))
end

function particle:export()
    local data = visualized.export(self)
    data.type = "worldStaticParticleNode"
    data.data = {
        emissionRate = self.emissionRate,
        forcedAutoHideDistance = -1,
        forcedAutoHideRange = -1,
        particleSystem = {
            DepotPath = {
                ["$storage"] = "string",
                ["$value"] = self.spawnData
            }
        }
    }

    return data
end

return particle
