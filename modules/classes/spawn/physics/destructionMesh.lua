local mesh = require("modules/classes/spawn/mesh/mesh")
local spawnable = require("modules/classes/spawn/spawnable")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
local Cron = require("modules/utils/Cron")
local destructibleData = require("modules/utils/destructibleData")

---Shared base of the three destruction node classes: worldInstancedDestructibleMeshNode,
---worldPhysicalDestructionNode and worldBakedDestructionNode.
---
---All three place a mesh that breaks, all three pre-fill their settings from a per mesh
---survey of the shipped sectors, and all three collide through a named collision filter
---preset. Two of them also preview an effect on the intact mesh. None of that is specific to
---one node type, so it lives here and the subclasses are left with the properties their node
---actually declares.
---
---Nothing spawns this class directly; it has no node and no asset list of its own.
---@class destructionMesh : mesh
---@field protected effectSlots destructionEffectSlot[]
---@field protected playableEffectSlot string?
---@field protected fallbackPreset string
---@field protected filterPreset integer
---@field protected defaultsAbsentText string
---@field protected defaultsRestoreTooltip string
---@field private effectStopCron number?
---@field private hasActiveEffects boolean
---@field private pendingRespawn boolean
local destructionMesh = setmetatable({}, { __index = mesh })

---One effect registered on the preview entity's `entEffectSpawnerComponent`.
---@class destructionEffectSlot
---@field name string Effect name the spawner component registers it under.
---@field resolve fun(self: destructionMesh): string Current resource path, empty when unset.
---@field autoStart boolean? Started as soon as the entity is assembled, and kept running.

-- Destroying the entity in the same frame as the stop event leaves the effect playing in the
-- world with nothing left to stop it, so the despawn waits this long. Same delay as the
-- Effects spawnable uses.
local effectStopDelay = 0.1

---Starts/stops an effect on the preview entity. Wrapped because the helper needs a
---gameObject, and silently doing nothing is better than spamming the log if the preview
---entity ever turns out not to be one.
---@param entity entEntity?
---@param effectName string
---@param start boolean
---@param persist boolean?
local function toggleEffect(entity, effectName, start, persist)
    if not entity then return end

    pcall(function ()
        if start then
            GameObjectEffectHelper.StartEffectEvent(entity, effectName, persist == true, worldEffectBlackboard.new())
        else
            GameObjectEffectHelper.StopEffectEvent(entity, effectName)
        end
    end)
end

function destructionMesh:new()
	local o = mesh.new(self)

    o.dataType = "Destruction Mesh"
    o.modulePath = "physics/destructionMesh"

    -- Every destruction mesh ships the collision its node needs, so there is nothing to
    -- generate from the editor.
    o.hideGenerate = true
    o.convertTarget = 0

    -- Effects the class previews. Empty means it previews none, and then it also spawns
    -- through the plain mesh wrapper instead of a game object.
    o.effectSlots = {}
    o.playableEffectSlot = nil

    o.filterPreset = 0
    o.filterPresetSearch = ""
    o.fallbackPreset = destructibleData.fallbackPreset

    o.advancedHeaderState = false

    o.effectStopCron = nil
    o.hasActiveEffects = false
    o.pendingRespawn = false

    -- Shown by drawMeshDefaultsNote when the survey has nothing for the current mesh. Every
    -- node type words this differently, since what it means to "never place this mesh" is
    -- different for each.
    o.defaultsAbsentText = "The base game never places this mesh on this node, so the settings below start from generic defaults."
    o.defaultsRestoreTooltip = "Restores the settings the base game uses for this mesh."

    setmetatable(o, { __index = self })
   	return o
end

---------------------------------------------------------------------------
-- Collision filter presets
---------------------------------------------------------------------------

---Preset names the class offers, in the order the dropdown lists them.
---@return string[]
function destructionMesh:getPresetNames()
    return {}
end

---@return string
function destructionMesh:getPresetName()
    local names = self:getPresetNames()
    return names[self.filterPreset + 1] or names[1] or self.fallbackPreset
end

---Collision masks of the selected preset. The survey found the masks to be a pure function
---of the preset name, so they are never edited by hand.
---@return table {queryMask1, queryMask2, simulationMask1, simulationMask2}
function destructionMesh:getMasks()
    return destructibleData.getPresetMasks(self:getPresetName())
end

---Builds the physics filter data of a preset onto a component being assembled.
---@protected
---@param component gameObject Component to configure.
---@param preset string
function destructionMesh:applyFilterData(component, preset)
    local masks = destructibleData.getPresetMasks(preset)

    local filterData = physicsFilterData.new()
    filterData.preset = preset

    local query = physicsQueryFilter.new()
    query.mask1 = tonumber(masks.queryMask1) or 0
    query.mask2 = tonumber(masks.queryMask2) or 0

    local sim = physicsSimulationFilter.new()
    sim.mask1 = tonumber(masks.simulationMask1) or 0
    sim.mask2 = tonumber(masks.simulationMask2) or 0

    filterData.queryFilter = query
    filterData.simulationFilter = sim
    component.filterData = filterData
end

---------------------------------------------------------------------------
-- Per mesh defaults
---------------------------------------------------------------------------

---Whether the survey holds settings for the current mesh.
---@return boolean
function destructionMesh:hasMeshDefaults()
    return false
end

---Applies the settings the game most commonly uses with the current mesh.
---@param silent boolean? Suppresses the toast, used when placing a new asset.
---@return boolean applied
function destructionMesh:applyMeshDefaults(silent)
    return false
end

---Toast shown by the "Reset to game defaults" button. Subclasses call this at the end of
---their `applyMeshDefaults`, so the wording stays the same across node types.
---@protected
---@param silent boolean?
function destructionMesh:reportMeshDefaultsApplied(silent)
    if silent then return end

    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Applied game defaults for this mesh"))
end

---------------------------------------------------------------------------
-- Effect preview
---------------------------------------------------------------------------

---Whether the class previews any effect at all. Decides both whether effects are assembled
---and whether the preview needs to be a game object.
---@return boolean
function destructionMesh:usesEffectPreview()
    return #self.effectSlots > 0
end

---@protected
---@param slot destructionEffectSlot
---@return string
function destructionMesh:getEffectPath(slot)
    return utils.trimString(slot.resolve(self) or "")
end

---Path of the effect the "Play fracturing effect" button drives, empty when unset.
---@return string
function destructionMesh:getPlayableEffectPath()
    for _, slot in ipairs(self.effectSlots) do
        if slot.name == self.playableEffectSlot then
            return self:getEffectPath(slot)
        end
    end

    return ""
end

---Attaches every set effect to the preview entity, and starts the ones flagged `autoStart`.
---Effect descs are baked at assemble time, so changing a resource requires a respawn.
---@protected
---@param entity entEntity
function destructionMesh:assembleEffects(entity)
    if self.isAssetPreview then return end

    local descs = {}
    local toStart = {}

    for _, slot in ipairs(self.effectSlots) do
        local path = self:getEffectPath(slot)
        if path ~= "" then
            local desc = entEffectDesc.new()
            desc.effect = path
            desc.effectName = slot.name
            table.insert(descs, desc)

            if slot.autoStart then
                table.insert(toStart, slot.name)
            end
        end
    end

    if #descs == 0 then return end

    local component = entEffectSpawnerComponent.new()
    component.name = "effects"
    component.effectDescs = descs
    entity:AddComponent(component)

    for _, name in ipairs(toStart) do
        toggleEffect(entity, name, true, true)
        self.hasActiveEffects = true
    end
end

---Restarts the always-on effects on an entity that is still alive. Only reached when a
---pending delayed despawn was cancelled, which already stopped them.
---@private
function destructionMesh:restartAutoStartEffects()
    local entity = self:getEntity()

    for _, slot in ipairs(self.effectSlots) do
        if slot.autoStart and self:getEffectPath(slot) ~= "" then
            toggleEffect(entity, slot.name, true, true)
            self.hasActiveEffects = true
        end
    end
end

---Plays the playable effect once on the preview entity.
---@return boolean played
function destructionMesh:playFracturingEffect()
    local entity = self:getEntity()
    if not entity or not self.playableEffectSlot or self:getPlayableEffectPath() == "" then
        return false
    end

    -- Restart from the beginning if it is still running from a previous press.
    toggleEffect(entity, self.playableEffectSlot, false)
    toggleEffect(entity, self.playableEffectSlot, true, false)
    self.hasActiveEffects = true

    return true
end

---Cancels a pending delayed despawn.
---@private
---@return boolean cancelled
function destructionMesh:cancelEffectStop()
    if not self.effectStopCron then
        return false
    end

    Cron.Halt(self.effectStopCron)
    self.effectStopCron = nil
    return true
end

---Spawns through a game object rather than the plain entity the other mesh types use.
---`GameObjectEffectHelper` only accepts a gameObject, and it is the only way to start or stop
---an `entEffectSpawnerComponent`, which has no methods of its own. Classes that preview no
---effect keep the plain wrapper.
function destructionMesh:spawn()
    if not self:usesEffectPreview() then
        mesh.spawn(self)
        return
    end

    -- Hiding and immediately showing again lands here while the delayed despawn is still
    -- pending. The entity is alive but its effects were already stopped, so keep it and start
    -- the always-on ones back up instead of leaving a silent preview behind.
    if self:cancelEffectStop() and self:isSpawned() then
        self.pendingRespawn = false
        self:restartAutoStartEffects()
        return
    end

    local meshPath = self.spawnData
    self.spawnData = "base\\spawner\\empty_game_object.ent"

    spawnable.spawn(self)
    self.spawnData = meshPath
end

function destructionMesh:despawn()
    local entity = self:getEntity()

    -- Nothing is playing, so the entity can go right away and hiding stays synchronous.
    if not entity or not self.hasActiveEffects then
        self:cancelEffectStop()
        mesh.despawn(self)
        return
    end

    for _, slot in ipairs(self.effectSlots) do
        toggleEffect(entity, slot.name, false)
    end
    self.hasActiveEffects = false

    self:cancelEffectStop()
    self.effectStopCron = Cron.After(effectStopDelay, function ()
        self.effectStopCron = nil
        mesh.despawn(self)

        if self.pendingRespawn then
            self.pendingRespawn = false
            self:spawn()
        end
    end)
end

---The despawn is delayed while effects are stopping, so the respawn has to wait for it
---instead of spawning into a still-alive entity.
function destructionMesh:respawn()
    if self.spawning then
        self.queueRespawn = true
        return
    end

    if not self:isSpawned() then
        self:spawn()
        return
    end

    self:despawn()

    if self.effectStopCron then
        self.pendingRespawn = true
    else
        self:spawn()
    end
end

---Respawns the preview after changing a property that is only applied on assemble.
---@protected
---@param changed boolean
function destructionMesh:updateFull(changed)
    if changed and self:isSpawned() then self:respawn() end
end

---------------------------------------------------------------------------
-- Shared UI rows
---------------------------------------------------------------------------

---Explains where the destruction settings come from, and offers to restore them.
---Drawn once above the node specific properties.
---@protected
function destructionMesh:drawMeshDefaultsNote()
    local hasDefaults = self:hasMeshDefaults()

    ImGui.Dummy(0, 8 * style.viewSize)

    if hasDefaults then
        style.styledTextWrapped("The settings below were filled in from how the base game places this mesh.", style.mutedColor)
    else
        style.styledTextWrapped(self.defaultsAbsentText, style.mutedColor)
    end

    style.pushGreyedOut(not hasDefaults)
    if ImGui.Button("Reset to game defaults##" .. self.modulePath) and hasDefaults then
        history.addAction(history.getElementChange(self.object))
        self:applyMeshDefaults(false)
        self:updateFull(true)
    end
    style.popGreyedOut(not hasDefaults)

    if hasDefaults then
        style.tooltip(self.defaultsRestoreTooltip)
    else
        style.tooltip("No recorded usage for this mesh, nothing to restore.", ImGuiHoveredFlags.AllowWhenDisabled)
    end

    ImGui.Dummy(0, 4 * style.viewSize)
    ImGui.Spacing()
end

---Draws one resource row backed by a surveyed list, allowing any typed value.
---@protected
---@param label string
---@param id string
---@param value string
---@param searchKey string Field on `self` holding the row's search text.
---@param options string[]
---@param hint string
---@param tooltip string
---@return string value Unchanged unless the user picked or typed something.
function destructionMesh:drawResourceSelector(label, id, value, searchKey, options, hint, tooltip)
    style.mutedText(label)
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)

    self[searchKey] = self[searchKey] or ""

    local selected, search, changed = style.trackedSearchDropdown(
        id,
        hint,
        value,
        self[searchKey],
        options,
        {
            element = self.object,
            width = 220,
            matchContentWidth = true,
            -- The listed values are the ones the game itself uses, but anything can be typed
            -- in, including resources added by mods.
            allowCustom = true,
            optionExistsFn = function (optionText)
                return utils.indexValue(options, utils.trimString(optionText)) ~= -1
            end,
            tooltip = tooltip
        }
    )
    self[searchKey] = search

    if changed then
        return selected
    end

    return value
end

---Draws the collision preset dropdown, and respawns the preview when it changes.
---@protected
---@param tooltip string
---@param width number?
function destructionMesh:drawPresetSelector(tooltip, width)
    style.mutedText("Collision Preset")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)

    local presetNames = self:getPresetNames()
    self.filterPreset = math.max(0, math.min(self.filterPreset, #presetNames - 1))

    local selected = presetNames[self.filterPreset + 1] or self.fallbackPreset
    local changed
    selected, self.filterPresetSearch, changed = style.trackedSearchDropdown(
        "##filterPreset",
        "Search preset...",
        selected,
        self.filterPresetSearch or "",
        presetNames,
        {
            element = self.object,
            width = width or 220,
            matchContentWidth = true,
            tooltip = tooltip
        }
    )

    if changed then
        self.filterPreset = math.max(utils.indexValue(presetNames, selected) - 1, 0)
        self:updateFull(true)
    end
end

---Draws the button that plays the playable effect once on the preview.
---@protected
---@param emptyTooltip string Shown when no effect is set, explaining how to set one.
---@param tooltip string
function destructionMesh:drawPlayEffectButton(emptyTooltip, tooltip)
    ImGui.SetCursorPosX(self.maxPropertyWidth)

    local effect = self:getPlayableEffectPath()
    local disabled = effect == "" or not self:isSpawned()

    style.pushGreyedOut(disabled)
    if ImGui.Button(IconGlyphs.Play .. " Play fracturing effect##playFracturingEffect") and not disabled then
        self:playFracturingEffect()
    end
    style.popGreyedOut(disabled)

    style.tooltip(effect == "" and emptyTooltip or tooltip, ImGuiHoveredFlags.AllowWhenDisabled)
end

return destructionMesh
