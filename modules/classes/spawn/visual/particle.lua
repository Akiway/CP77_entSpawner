local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local Cron = require("modules/utils/Cron")

---Class for worldStaticParticleNode
---@class particle : visualized
---@field emissionRate number
---@field respawnOnMove boolean
---@field private previewLoop boolean
---@field private previewLoopInterval number
---@field private previewLoopCron integer?
---@field private previewLoopRestartCron integer?
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
    o.previewLoopCron = nil
    o.previewLoopRestartCron = nil
    o.previewColor = "magenta"

    o.assetPreviewType = "position"
    o.assetPreviewDelay = 0.1

    o.maxPropertyWidth = nil

    setmetatable(o, { __index = self })
   	return o
end

function particle:stopPreviewLoop()
    if self.previewLoopCron then
        Cron.Halt(self.previewLoopCron)
        self.previewLoopCron = nil
    end

    if self.previewLoopRestartCron then
        Cron.Halt(self.previewLoopRestartCron)
        self.previewLoopRestartCron = nil
    end
end

function particle:ensurePreviewLoop()
    if self.previewLoopCron then
        return
    end

    if not self.previewLoop or self.previewLoopInterval <= 0 then
        return
    end

    self.previewLoopCron = Cron.Every(self.previewLoopInterval, function()
        self:restartPreviewLoopPlayback()
    end)
end

function particle:refreshPreviewLoop()
    self:stopPreviewLoop()
    self:ensurePreviewLoop()
end

function particle:restartPreviewLoopPlayback()
    if not self.previewLoop or not self:isSpawned() or self.isAssetPreview then
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
    self.previewLoopRestartCron = Cron.After(0.05, function()
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
end

function particle:spawn()
    local particle = self.spawnData
    self.spawnData = "base\\spawner\\empty_entity.ent"

    visualized.spawn(self)
    self.spawnData = particle

    self:ensurePreviewLoop()
end

function particle:despawn()
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

function particle:save()
    local data = visualized.save(self)
    data.emissionRate = self.emissionRate
    data.respawnOnMove = self.respawnOnMove
    data.previewLoop = self.previewLoop
    data.previewLoopInterval = self.previewLoopInterval

    return data
end

function particle:getVisualizerSize()
    return { x = 0.15, y = 0.15, z = 0.15 }
end

function particle:draw()
    visualized.draw(self)
    local changed

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Emission Rate", "Respawn on Move", "Preview Loop", "Loop Interval" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
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
            self:refreshPreviewLoop()
            if self.previewLoop then
                self:restartPreviewLoopPlayback()
            end
        end
        style.tooltip("World Builder preview only. Replays this particle in a loop. This setting is never exported.")

        style.mutedText("Loop Interval")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.previewLoopInterval, changed = style.trackedDragFloat(self.object, "##particlePreviewLoopInterval", self.previewLoopInterval, 0.05, 0.1, 120, "%.2f sec", 80)
        if changed then
            self.previewLoopInterval = math.max(self.previewLoopInterval, 0.1)
            self:refreshPreviewLoop()
        end

        ImGui.TreePop()
    end
end

function particle:getProperties()
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
