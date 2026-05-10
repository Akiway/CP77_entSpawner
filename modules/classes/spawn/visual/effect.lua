local visualized = require("modules/classes/spawn/visualized")
local Cron = require("modules/utils/Cron")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")

---Class for worldEffectNode
---@class effect : visualized
---@field private disableCron integer
---@field private previewLoop boolean
---@field private previewLoopInterval number
---@field private previewLoopCron integer?
---@field private previewLoopRestartCron integer?
---@field private maxPropertyWidth number?
local effect = setmetatable({}, { __index = visualized })

function effect:new()
	local o = visualized.new(self)

    o.spawnListType = "list"
    o.dataType = "Effects"
    o.spawnDataPath = "data/spawnables/visual/effects/"
    o.modulePath = "visual/effect"
    o.node = "worldEffectNode"
    o.description = "Plays an effect, from a given .effect file"
    o.icon = IconGlyphs.Creation

    o.previewColor = "brown"
    o.assetPreviewType = "position"
    o.assetPreviewDelay = 0.1

    o.disableCron = nil
    o.previewLoop = false
    o.previewLoopInterval = 2
    o.previewLoopCron = nil
    o.previewLoopRestartCron = nil
    o.maxPropertyWidth = nil

    setmetatable(o, { __index = self })
   	return o
end

function effect:stopPreviewLoop()
    if self.previewLoopCron then
        Cron.Halt(self.previewLoopCron)
        self.previewLoopCron = nil
    end

    if self.previewLoopRestartCron then
        Cron.Halt(self.previewLoopRestartCron)
        self.previewLoopRestartCron = nil
    end
end

function effect:ensurePreviewLoop()
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

function effect:refreshPreviewLoop()
    self:stopPreviewLoop()
    self:ensurePreviewLoop()
end

function effect:restartPreviewLoopPlayback()
    if not self.previewLoop or not self:isSpawned() or self.isAssetPreview then
        return
    end

    local entity = self:getEntity()
    if not entity then
        return
    end

    GameObjectEffectHelper.StopEffectEvent(entity, "effect")

    if self.previewLoopRestartCron then
        Cron.Halt(self.previewLoopRestartCron)
        self.previewLoopRestartCron = nil
    end

    -- Delay avoids stop/start being processed in the same frame.
    self.previewLoopRestartCron = Cron.After(0.05, function()
        self.previewLoopRestartCron = nil

        if not self.previewLoop or not self:isSpawned() or self.isAssetPreview then
            return
        end

        local currentEntity = self:getEntity()
        if not currentEntity then
            return
        end

        GameObjectEffectHelper.StartEffectEvent(currentEntity, "effect", true, worldEffectBlackboard.new())
    end)
end

function effect:onAssemble(entity)
    visualized.onAssemble(self, entity)

    local component = entEffectSpawnerComponent.new()
    component.name = "effect"
    local effect = entEffectDesc.new()
    effect.effect = self.spawnData
    effect.effectName = "effect"
    component.effectDescs = { effect }

    entity:AddComponent(component)

    GameObjectEffectHelper.StartEffectEvent(entity, "effect", true, worldEffectBlackboard.new())
end

function effect:spawn()
    if self.disableCron then
        Cron.Halt(self.disableCron)
        self.disableCron = nil
    end

    local effect = self.spawnData
    self.spawnData = "base\\spawner\\empty_game_object.ent"

    visualized.spawn(self)
    self.spawnData = effect

    self:ensurePreviewLoop()
end

function effect:despawn()
    self:stopPreviewLoop()
    GameObjectEffectHelper.StopEffectEvent(self:getEntity(), "effect")

    -- Needs some time for StopEffectEvent to be sent to the entity
    self.disableCron = Cron.After(0.1, function ()
        visualized.despawn(self)
        self.disableCron = nil
    end)
end

---Calling despawn and spawn on the same frame might lead to issues with the effect not playing due to being stopped then started
function effect:respawn()
    if self:isSpawned() then
        return
    end
    self:spawn()
end

function effect:getVisualizerSize()
    return { x = 0.15, y = 0.15, z = 0.15 }
end

function effect:draw()
    visualized.draw(self)
    local changed

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize", "Preview Loop", "Loop Interval" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    if ImGui.TreeNodeEx("Previewing Options", ImGuiTreeNodeFlags.SpanFullWidth) then
        local previewPropertyWidth = self.maxPropertyWidth + ImGui.GetTreeNodeToLabelSpacing()

        self:drawPreviewCheckbox("Visualize", previewPropertyWidth)

        style.mutedText("Preview Loop")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.previewLoop, changed = style.trackedCheckbox(self.object, "##effectPreviewLoop", self.previewLoop)
        if changed then
            self:refreshPreviewLoop()
            if self.previewLoop then
                self:restartPreviewLoopPlayback()
            end
        end
        style.tooltip("World Builder preview only. Replays this effect in a loop. This setting is never exported.")

        style.mutedText("Loop Interval")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.previewLoopInterval, changed = style.trackedDragFloat(self.object, "##effectPreviewLoopInterval", self.previewLoopInterval, 0.05, 0.1, 120, "%.2f sec", 80)
        if changed then
            self.previewLoopInterval = math.max(self.previewLoopInterval, 0.1)
            self:refreshPreviewLoop()
        end

        ImGui.TreePop()
    end
end

function effect:getProperties()
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

function effect:save()
    local data = visualized.save(self)
    data.previewLoop = self.previewLoop
    data.previewLoopInterval = self.previewLoopInterval

    return data
end

function effect:export()
    local data = visualized.export(self)
    data.type = "worldEffectNode"
    data.data = {
        streamingDistanceOverride = -1,
        effect = {
            DepotPath = {
                ["$storage"] = "string",
                ["$value"] = self.spawnData
            }
        }
    }

    return data
end

return effect
