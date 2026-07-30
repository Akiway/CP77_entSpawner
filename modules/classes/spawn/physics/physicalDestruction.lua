local mesh = require("modules/classes/spawn/mesh/mesh")
local spawnable = require("modules/classes/spawn/spawnable")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
local Cron = require("modules/utils/Cron")
local destructionData = require("modules/utils/destructionData")

---Class for worldPhysicalDestructionNode
---
---Chunk based destruction: the mesh carries a fracture hierarchy and the node describes how
---it breaks. Unlike worldInstancedDestructibleMeshNode this node derives straight from
---worldNode, so it has no shadow, occluder or render layer properties at all, and it places
---exactly one mesh instead of a cooked instance buffer.
---
---The exposed properties are the ones the shipped sectors actually vary; see
---`script/extract_destruction_node_usage.wscript`. Of the 41 surveyed properties, 20 sit on
---a single value in at least 99% of the 19539 placements and are written from
---`constantExport` rather than being editable. Collision masks follow from the filter preset
---name, so they are never edited by hand.
---@class physicalDestruction : mesh
---@field public simulationType integer
---@field public startInactive boolean
---@field public turnDynamicOnImpulse boolean
---@field public markEdgeChunks boolean
---@field public buildConvexForClusters boolean
---@field public damageThreshold number
---@field public damageEndurance number
---@field public bondEndurance number
---@field public accumulateDamage boolean
---@field public impulseToDamage number
---@field public contactToDamage number
---@field public impulsePropagationFactor number
---@field public impulseDiminishingFactor number
---@field public debrisTimeout boolean
---@field public debrisTimeoutMin number
---@field public debrisTimeoutMax number
---@field public visualsRemain boolean
---@field public fractureFieldMask integer
---@field public audioMetadata string
---@field public navmeshImpact integer
---@field public forceAutoHideDistance number
---@field public levels {preset: string, fracturingEffect: string}[]
---@field private advancedHeaderState boolean
---@field private levelsHeaderState boolean
---@field private effectStopCron number?
---@field private hasActiveEffects boolean
---@field private pendingRespawn boolean
local physicalDestruction = setmetatable({}, { __index = mesh })

---Values the game keeps constant across essentially every placement. Written on export, not
---editable. Percentages are the share of the 19539 surveyed nodes using that value.
local constantExport = {
    isVisibleInGame = 1,                    -- 100.00%
    isHostOnly = 0,                         -- 100.00%
    forceLODLevel = -1,                     -- 100.00%
    useMeshNavmeshSettings = 1,             -- 100.00%, which makes navigationSetting advisory
    systemsToNotifyFlags = 15               -- 100.00%
}

---Same, for the nested physicsDestructionParams block.
local constantDestructionParams = {
    enableImpulseDamage = 1,                -- 100.00%
    maxContactImpulseRatio = 1,             -- 100.00%
    debrisInstantRemovalThreshold = 0,      -- 100.00%
    debrisTimeoutThreshold = 0,             -- 100.00%
    fadeOutTime = 0,                        -- 100.00%
    maxAngularVelocity = -1,                -- 100.00%
    debrisDestructible = 0,                 -- 99.90%
    supportDamage = 0,                      -- 99.80%
    impulseChildPropagationFactor = 1,      -- 99.60%
    breakBonds = 0,                         -- 99.50%
    useAggregatesForClusters = 0,           -- 99.30%
    debrisMaxSeparation = 50                -- 99.10%
}

---`physicsFractureFieldType` is a bitfield, and RED-JSON stores it as the comma separated
---member list. These are the five combinations the game actually uses, so a plain dropdown
---covers real usage without building a checkbox matrix for 64 bits.
local fractureFieldMasks = {
    "FF_Default",                                                       -- 95.5%
    "FF_Locomotion",                                                    -- 4.0%
    "FF_Default, FF_FractureFieldGameEffect, FF_FractureFieldComponent", -- 0.3%
    "FF_Default, FF_FractureFieldGameEffect",                            -- 0.2%
    "FF_Default, FF_FractureFieldComponent"                              -- 0.1%
}

-- Effect name used on the preview entity's effect spawner component. The node stores one
-- fracturing effect per destruction level; the preview plays the first one that is set.
local FRACTURING_EFFECT_NAME = "fracturingEffect"

-- Destroying the entity in the same frame as the stop event leaves the effect playing with
-- nothing left to stop it, so the despawn waits this long.
local effectStopDelay = 0.1

-- Levels used when a mesh has no surveyed layout. 3 is what 80% of the game's nodes use.
local defaultLevelCount = 3

---`utils.enumTable` orders members by their numeric value, and NavGenNavmeshImpact does not
---start at Blocking, so the default index has to be looked up rather than assumed to be 0.
---@param enumValues string[]
---@return integer
local function getDefaultNavmeshImpactIndex(enumValues)
    local index = utils.indexValue(enumValues, "Blocking")
    if index == -1 then
        return 0
    end

    return math.max(index - 1, 0)
end

---@param value any
---@return boolean
local function toBoolean(value)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end
    local text = utils.trimString(value or ""):lower()
    return text == "true" or text == "1"
end

---Starts/stops an effect on the preview entity. Wrapped because the helper needs a
---gameObject, and silently doing nothing beats spamming the log if the preview entity ever
---turns out not to be one.
---@param entity entEntity?
---@param start boolean
local function toggleEffect(entity, start)
    if not entity then return end

    pcall(function ()
        if start then
            GameObjectEffectHelper.StartEffectEvent(entity, FRACTURING_EFFECT_NAME, false, worldEffectBlackboard.new())
        else
            GameObjectEffectHelper.StopEffectEvent(entity, FRACTURING_EFFECT_NAME)
        end
    end)
end

---RED-JSON payload for a `raRef:worldEffect` resource reference.
---@param path string
---@return table
local function exportResourceRef(path)
    return {
        ["Flags"] = "Soft",
        ["DepotPath"] = {
            ["$type"] = "ResourcePath",
            ["$storage"] = "string",
            ["$value"] = path
        }
    }
end

---RED-JSON payload for a handle to a physicsFilterData built from a preset name.
---@param preset string
---@return table
local function exportFilterData(preset)
    local masks = destructionData.getPresetMasks(preset)

    return {
        ["Data"] = {
            ["$type"] = "physicsFilterData",
            ["preset"] = {
                ["$type"] = "CName",
                ["$storage"] = "string",
                ["$value"] = preset
            },
            ["queryFilter"] = {
                ["$type"] = "physicsQueryFilter",
                ["mask1"] = masks.queryMask1,
                ["mask2"] = masks.queryMask2
            },
            ["simulationFilter"] = {
                ["$type"] = "physicsSimulationFilter",
                ["mask1"] = masks.simulationMask1,
                ["mask2"] = masks.simulationMask2
            }
        }
    }
end

function physicalDestruction:new()
	local o = mesh.new(self)

    o.dataType = "Physical Destruction Mesh"
    o.modulePath = "physics/physicalDestruction"
    o.spawnDataPath = "data/spawnables/mesh/physicalDestruction/"
    o.node = "worldPhysicalDestructionNode"
    o.description = "Places a chunk based destructible mesh, from a given .mesh file. Breaks apart along the fracture hierarchy baked into the mesh, level by level."
    o.previewNote = "Destruction itself is not simulated in-editor. The physics body of the intact mesh is previewed, and the fracturing effect can be played on demand."
    o.icon = IconGlyphs.CubeUnfolded

    -- The node derives from worldNode, not worldMeshNode: no shadow casting modes, no
    -- occluder, no render scene layer mask, no wind impulse. Clearing this also keeps
    -- loadMeshResourceData from turning the occluder row back on for a mesh that has one.
    o.hasMeshNodeFlags = false
    -- The mesh ships its own destruction collision, so there is nothing to generate.
    o.hideGenerate = true

    o.simulationType = 2 -- Kinematic, 82.3%
    o.startInactive = false
    o.turnDynamicOnImpulse = true
    o.markEdgeChunks = false
    o.buildConvexForClusters = false

    o.damageThreshold = 1
    o.damageEndurance = 10
    o.bondEndurance = 20
    o.accumulateDamage = true
    o.impulseToDamage = 1
    o.contactToDamage = 10
    o.impulsePropagationFactor = 0
    o.impulseDiminishingFactor = 0

    o.debrisTimeout = true
    o.debrisTimeoutMin = 3
    o.debrisTimeoutMax = 5
    o.visualsRemain = true

    o.fractureFieldMask = 0
    o.audioMetadata = "None"
    o.forceAutoHideDistance = 150

    o.levels = {}

    o.simulationTypeEnum = utils.enumTable("physicsSimulationType")
    o.navmeshImpactEnum = utils.enumTable("NavGenNavmeshImpact")
    if #o.navmeshImpactEnum == 0 then
        -- Ordered by numeric value, matching what enumTable would have produced.
        o.navmeshImpactEnum = { "Walkable", "Ignored", "Blocking", "Road", "Stairs", "Drones", "Terrain" }
    end
    o.navmeshImpact = getDefaultNavmeshImpactIndex(o.navmeshImpactEnum) -- Blocking, 93.4%

    o.audioMetadataSearch = ""
    o.levelPresetSearch = {}
    o.levelEffectSearch = {}

    o.advancedHeaderState = false
    o.levelsHeaderState = false
    o.convertTarget = 0

    o.effectStopCron = nil
    o.hasActiveEffects = false
    o.pendingRespawn = false

    setmetatable(o, { __index = self })
   	return o
end

function physicalDestruction:loadSpawnData(data, position, rotation)
    mesh.loadSpawnData(self, data, position, rotation)

    -- `dataType` is serialized and copied straight back by spawnable:loadSpawnData, so it is
    -- re-asserted here; otherwise objects saved under an older name keep displaying it.
    self.dataType = "Physical Destruction Mesh"

    -- A freshly placed asset (or one converted from another mesh type) carries no
    -- destruction settings yet, so it starts from how the game uses that mesh.
    if data.simulationType == nil then
        self:applyMeshDefaults(true)
    end

    if #self.levels == 0 then
        self:setLevelCount(defaultLevelCount)
    end
end

---Grows or shrinks the level list, keeping existing entries.
---@param count integer
function physicalDestruction:setLevelCount(count)
    count = math.max(1, math.min(math.floor(count or 0), 8))

    while #self.levels > count do
        table.remove(self.levels)
    end
    while #self.levels < count do
        table.insert(self.levels, {
            preset = destructionData.fallbackPhysicalPreset,
            fracturingEffect = ""
        })
    end
end

---Applies the settings the game most commonly uses with the current mesh.
---@param silent boolean? Suppresses the toast, used when placing a new asset.
---@return boolean applied
function physicalDestruction:applyMeshDefaults(silent)
    local defaults = destructionData.getPhysicalDefaults(self.spawnData)
    if not defaults then
        return false
    end

    local function enumIndex(list, value, fallback)
        if value == nil then return fallback end
        local index = utils.indexValue(list, value)
        if index > 0 then
            return index - 1
        end
        return fallback
    end

    local function number(value, fallback)
        return tonumber(value) or fallback
    end

    self.simulationType = enumIndex(self.simulationTypeEnum, defaults["destructionParams.simulationType"], self.simulationType)
    self.navmeshImpact = enumIndex(self.navmeshImpactEnum, defaults["navigationSetting.navmeshImpact"], self.navmeshImpact)
    self.fractureFieldMask = enumIndex(fractureFieldMasks, defaults["destructionParams.fractureFieldMask"], self.fractureFieldMask)

    self.audioMetadata = utils.trimString(defaults.audioMetadata or "None")
    if self.audioMetadata == "" then
        self.audioMetadata = "None"
    end

    self.forceAutoHideDistance = number(defaults.forceAutoHideDistance, self.forceAutoHideDistance)
    self.damageThreshold = number(defaults["destructionParams.damageThreshold"], self.damageThreshold)
    self.damageEndurance = number(defaults["destructionParams.damageEndurance"], self.damageEndurance)
    self.bondEndurance = number(defaults["destructionParams.bondEndurance"], self.bondEndurance)
    self.impulseToDamage = number(defaults["destructionParams.impulseToDamage"], self.impulseToDamage)
    self.contactToDamage = number(defaults["destructionParams.contactToDamage"], self.contactToDamage)
    self.impulsePropagationFactor = number(defaults["destructionParams.impulsePropagationFactor"], self.impulsePropagationFactor)
    self.impulseDiminishingFactor = number(defaults["destructionParams.impulseDiminishingFactor"], self.impulseDiminishingFactor)
    self.debrisTimeoutMin = number(defaults["destructionParams.debrisTimeoutMin"], self.debrisTimeoutMin)
    self.debrisTimeoutMax = number(defaults["destructionParams.debrisTimeoutMax"], self.debrisTimeoutMax)

    if defaults["destructionParams.turnDynamicOnImpulse"] ~= nil then
        self.turnDynamicOnImpulse = toBoolean(defaults["destructionParams.turnDynamicOnImpulse"])
    end
    if defaults["destructionParams.markEdgeChunks"] ~= nil then
        self.markEdgeChunks = toBoolean(defaults["destructionParams.markEdgeChunks"])
    end
    if defaults["destructionParams.buildConvexForClusters"] ~= nil then
        self.buildConvexForClusters = toBoolean(defaults["destructionParams.buildConvexForClusters"])
    end
    if defaults["destructionParams.accumulateDamage"] ~= nil then
        self.accumulateDamage = toBoolean(defaults["destructionParams.accumulateDamage"])
    end
    if defaults["destructionParams.debrisTimeout"] ~= nil then
        self.debrisTimeout = toBoolean(defaults["destructionParams.debrisTimeout"])
    end
    if defaults["destructionParams.visualsRemain"] ~= nil then
        self.visualsRemain = toBoolean(defaults["destructionParams.visualsRemain"])
    end

    -- The level count is not a free choice: it follows the fracture hierarchy baked into
    -- the mesh, so it comes from the survey rather than being kept from before.
    local levels = destructionData.getPhysicalLevels(self.spawnData)
    if levels then
        self.levels = {}
        for _, level in ipairs(levels) do
            table.insert(self.levels, {
                preset = level.preset,
                fracturingEffect = level.fracturingEffect
            })
        end
    end

    if not silent then
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Applied game defaults for this mesh"))
    end

    return true
end

---The fracturing effect the preview plays: the first one any level defines.
---@return string
function physicalDestruction:getPreviewEffect()
    for _, level in ipairs(self.levels) do
        local path = utils.trimString(level.fracturingEffect or "")
        if path ~= "" then
            return path
        end
    end
    return ""
end

function physicalDestruction:onAssemble(entity)
    spawnable.onAssemble(self, entity)

    -- The runtime component for this node is entPhysicalDestructionComponent, but nothing
    -- simulates destruction in-editor, so the intact body renders identically through the
    -- physical mesh component the other physics mesh types already use.
    local component = PhysicalMeshComponent.new()
    component.name = "mesh"
    component.mesh = ResRef.FromString(self.spawnData)
    component.visualScale = Vector3.new(self.scale.x, self.scale.y, self.scale.z)
    component.meshAppearance = self.app

    if not self.isAssetPreview then
        component.simulationType = Enum.new("physicsSimulationType", self.simulationType)
        component.startInactive = self.startInactive

        -- Level 0 is the intact body, so its filter data is what the preview collides with.
        local preset = self.levels[1] and self.levels[1].preset or destructionData.fallbackPhysicalPreset
        local masks = destructionData.getPresetMasks(preset)

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

    entity:AddComponent(component)

    self:assembleEffects(entity)

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    mesh.assetPreviewAssemble(self, entity)
end

---Cancels a pending delayed despawn.
---@private
---@return boolean cancelled
function physicalDestruction:cancelEffectStop()
    if not self.effectStopCron then
        return false
    end

    Cron.Halt(self.effectStopCron)
    self.effectStopCron = nil
    return true
end

---Spawns through a game object rather than the plain entity the other mesh types use.
---`GameObjectEffectHelper` only accepts a gameObject, and it is the only way to drive an
---`entEffectSpawnerComponent`, which has no methods of its own.
function physicalDestruction:spawn()
    -- Hiding and immediately showing again lands here while the delayed despawn is still
    -- pending. The entity is alive, so keep it rather than leaving a stale preview behind.
    if self:cancelEffectStop() and self:isSpawned() then
        self.pendingRespawn = false
        return
    end

    local meshPath = self.spawnData
    self.spawnData = "base\\spawner\\empty_game_object.ent"

    spawnable.spawn(self)
    self.spawnData = meshPath
end

---Registers the fracturing effect on the preview entity, stopped. Effect descs are baked at
---assemble time, so changing the resource requires a respawn.
---@protected
---@param entity entEntity
function physicalDestruction:assembleEffects(entity)
    if self.isAssetPreview then return end

    local effect = self:getPreviewEffect()
    if effect == "" then return end

    local desc = entEffectDesc.new()
    desc.effect = effect
    desc.effectName = FRACTURING_EFFECT_NAME

    local component = entEffectSpawnerComponent.new()
    component.name = "effects"
    component.effectDescs = { desc }
    entity:AddComponent(component)
end

---Plays the fracturing effect once on the preview entity.
---@return boolean played
function physicalDestruction:playFracturingEffect()
    local entity = self:getEntity()
    if not entity or self:getPreviewEffect() == "" then
        return false
    end

    -- Restart from the beginning if it is still running from a previous press.
    toggleEffect(entity, false)
    toggleEffect(entity, true)
    self.hasActiveEffects = true

    return true
end

function physicalDestruction:despawn()
    local entity = self:getEntity()

    -- Nothing is playing, so the entity can go right away and hiding stays synchronous.
    if not entity or not self.hasActiveEffects then
        self:cancelEffectStop()
        mesh.despawn(self)
        return
    end

    toggleEffect(entity, false)
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

---The despawn is delayed while an effect is stopping, so the respawn has to wait for it
---instead of spawning into a still-alive entity.
function physicalDestruction:respawn()
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

function physicalDestruction:save()
    local data = mesh.save(self)

    data.simulationType = self.simulationType
    data.startInactive = self.startInactive
    data.turnDynamicOnImpulse = self.turnDynamicOnImpulse
    data.markEdgeChunks = self.markEdgeChunks
    data.buildConvexForClusters = self.buildConvexForClusters

    data.damageThreshold = self.damageThreshold
    data.damageEndurance = self.damageEndurance
    data.bondEndurance = self.bondEndurance
    data.accumulateDamage = self.accumulateDamage
    data.impulseToDamage = self.impulseToDamage
    data.contactToDamage = self.contactToDamage
    data.impulsePropagationFactor = self.impulsePropagationFactor
    data.impulseDiminishingFactor = self.impulseDiminishingFactor

    data.debrisTimeout = self.debrisTimeout
    data.debrisTimeoutMin = self.debrisTimeoutMin
    data.debrisTimeoutMax = self.debrisTimeoutMax
    data.visualsRemain = self.visualsRemain

    data.fractureFieldMask = self.fractureFieldMask
    data.audioMetadata = self.audioMetadata
    data.navmeshImpact = self.navmeshImpact
    data.forceAutoHideDistance = self.forceAutoHideDistance

    data.levels = {}
    for _, level in ipairs(self.levels) do
        table.insert(data.levels, { preset = level.preset, fracturingEffect = level.fracturingEffect })
    end

    return data
end

---Respawns the preview after changing a property that is only applied on assemble.
---@protected
---@param changed boolean
function physicalDestruction:updateFull(changed)
    if changed and self:isSpawned() then self:respawn() end
end

---Explains where the destruction settings come from, and offers to restore them.
---@private
function physicalDestruction:drawMeshDefaultsNote()
    local hasDefaults = destructionData.hasPhysicalDefaults(self.spawnData)

    ImGui.Dummy(0, 8 * style.viewSize)

    if hasDefaults then
        style.styledTextWrapped("The settings below were filled in from how the base game places this mesh.", style.mutedColor)
    else
        style.styledTextWrapped("The base game never places this mesh as physical destruction, so the settings below start from generic defaults.", style.mutedColor)
    end

    style.pushGreyedOut(not hasDefaults)
    if ImGui.Button("Reset to game defaults##physicalDestructionDefaults") and hasDefaults then
        history.addAction(history.getElementChange(self.object))
        self:applyMeshDefaults(false)
        self:updateFull(true)
    end
    style.popGreyedOut(not hasDefaults)

    if hasDefaults then
        style.tooltip("Restores the settings the base game uses for this mesh, including its destruction levels.")
    else
        style.tooltip("No recorded usage for this mesh, nothing to restore.", ImGuiHoveredFlags.AllowWhenDisabled)
    end

    ImGui.Dummy(0, 4 * style.viewSize)
    ImGui.Spacing()
end

---Draws the per level preset and fracturing effect rows.
---@private
function physicalDestruction:drawLevels()
    style.styledTextWrapped("One entry per level of the mesh's fracture hierarchy. The count has to match what the mesh was baked with, so it is filled in from the survey.", style.mutedColor)

    local presetNames = destructionData.physicalPresets
    local effects = destructionData.getAllEffects()

    for index, level in ipairs(self.levels) do
        ImGui.PushID("physicalDestructionLevel" .. tostring(index))

        style.mutedText("Level " .. tostring(index - 1))

        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.levelPresetSearch[index] = self.levelPresetSearch[index] or ""
        local preset, presetSearch, presetChanged = style.trackedSearchDropdown(
            "##levelPreset",
            "Search preset...",
            level.preset,
            self.levelPresetSearch[index],
            presetNames,
            {
                element = self.object,
                width = 180,
                matchContentWidth = true,
                tooltip = "Collision behaviour of the pieces at this level. Level 0 is the intact mesh."
            }
        )
        self.levelPresetSearch[index] = presetSearch
        if presetChanged then
            level.preset = preset
            self:updateFull(index == 1)
        end

        style.mutedText("Effect " .. tostring(index - 1))
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.levelEffectSearch[index] = self.levelEffectSearch[index] or ""
        local effect, effectSearch, effectChanged = style.trackedSearchDropdown(
            "##levelEffect",
            "Search or type a path...",
            level.fracturingEffect,
            self.levelEffectSearch[index],
            effects,
            {
                element = self.object,
                width = 220,
                matchContentWidth = true,
                -- The listed effects are the ones the game uses, but any .effect can be
                -- typed in, including ones added by mods.
                allowCustom = true,
                optionExistsFn = function (optionText)
                    return utils.indexValue(effects, utils.trimString(optionText)) ~= -1
                end,
                tooltip = "Effect played when this level breaks.\nEvery .effect in the game is listed, and any other path can be typed in."
            }
        )
        self.levelEffectSearch[index] = effectSearch
        if effectChanged then
            local previous = self:getPreviewEffect()
            level.fracturingEffect = effect
            -- The effect descs are baked on assemble, so a new resource needs a respawn.
            self:updateFull(self:getPreviewEffect() ~= previous)
        end

        ImGui.PopID()
        ImGui.Spacing()
    end

    ImGui.SetCursorPosX(self.maxPropertyWidth)
    if ImGui.Button(IconGlyphs.Plus .. "##addPhysicalDestructionLevel") then
        history.addAction(history.getElementChange(self.object))
        self:setLevelCount(#self.levels + 1)
    end
    style.tooltip("Add a destruction level.")

    ImGui.SameLine()
    local canRemove = #self.levels > 1
    style.pushGreyedOut(not canRemove)
    if ImGui.Button(IconGlyphs.Minus .. "##removePhysicalDestructionLevel") and canRemove then
        history.addAction(history.getElementChange(self.object))
        self:setLevelCount(#self.levels - 1)
    end
    style.popGreyedOut(not canRemove)
    style.tooltip("Remove the deepest destruction level.", ImGuiHoveredFlags.AllowWhenDisabled)
end

function physicalDestruction:draw()
    local calculateMaxWidth = not self.maxPropertyWidth

    mesh.draw(self)

    if calculateMaxWidth then
        self.maxPropertyWidth = math.max(self.maxPropertyWidth, utils.getTextMaxWidth({
            "Auto Hide Distance", "Turn Dynamic On Impulse", "Damage Endurance", "Bond Endurance",
            "Impulse Propagation", "Impulse Diminishing", "Debris Timeout Max", "Audio Metadata"
        }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX())
    end

    local changed

    style.mutedText("Auto Hide Distance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.forceAutoHideDistance = style.trackedDragFloat(self.object, "##forceAutoHideDistance", self.forceAutoHideDistance, 0.1, 0, 1000, "%.1f")
    style.tooltip("Distance at which the mesh stops rendering. 0 lets the game decide, which is what it does for 82% of these nodes.")

    -- Everything from here down is destruction specific and gets pre-filled from the per
    -- mesh survey, so it is explained once instead of in every tooltip.
    self:drawMeshDefaultsNote()

    style.mutedText("Simulation Type")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    -- Helper text goes through the combo's own tooltip: a second style.tooltip call would
    -- open a separate tooltip window on top of it.
    self.simulationType, changed = style.trackedCombo(self.object, "##simulationType", self.simulationType, self.simulationTypeEnum, 110, {
        tooltip = "Kinematic keeps the mesh in place until something hits it, Static never moves at all. The game uses Kinematic for 82% of these nodes and Static for 17%."
    })
    self:updateFull(changed)

    style.mutedText("Start Inactive")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.startInactive, changed = style.trackedCheckbox(self.object, "##startInactive", self.startInactive)
    style.tooltip("Keeps the physics body asleep until something interacts with it.")
    self:updateFull(changed)

    style.mutedText("Turn Dynamic On Impulse")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.turnDynamicOnImpulse = style.trackedCheckbox(self.object, "##turnDynamicOnImpulse", self.turnDynamicOnImpulse)
    style.tooltip("Switches a kinematic body to dynamic once it gets hit, so the whole object can be knocked around instead of only breaking.")

    style.mutedText("Damage Threshold")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.damageThreshold = style.trackedDragFloat(self.object, "##damageThreshold", self.damageThreshold, 0.1, 0, 10000, "%.2f")
    style.tooltip("Damage below this is ignored entirely. The game uses 1 for 98% of these nodes.")

    style.mutedText("Damage Endurance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.damageEndurance = style.trackedDragFloat(self.object, "##damageEndurance", self.damageEndurance, 0.1, 0, 10000, "%.2f")
    style.tooltip("How much damage a chunk takes before it breaks off. The game mostly uses 10, 1 or 30.")

    style.mutedText("Bond Endurance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.bondEndurance = style.trackedDragFloat(self.object, "##bondEndurance", self.bondEndurance, 0.1, 0, 10000, "%.2f")
    style.tooltip("How much damage the bonds between chunks take before they let go. The game mostly uses 20, and 1000 to make a piece effectively unbreakable.")

    style.mutedText("Audio Metadata")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local audioSets = destructionData.getAllAudioMetadata()
    local audio, audioSearch, audioChanged = style.trackedSearchDropdown(
        "##audioMetadata",
        "Search or type a name...",
        self.audioMetadata,
        self.audioMetadataSearch or "",
        audioSets,
        {
            element = self.object,
            width = 220,
            matchContentWidth = true,
            allowCustom = true,
            optionExistsFn = function (optionText)
                return utils.indexValue(audioSets, utils.trimString(optionText)) ~= -1
            end,
            tooltip = "Sound set played while the mesh breaks. Not previewed.\nThe list holds every set seen on a destruction node, and any other name can be typed in."
        }
    )
    self.audioMetadataSearch = audioSearch
    if audioChanged then
        self.audioMetadata = audio
    end

    self.levelsHeaderState = ImGui.TreeNodeEx("Destruction Levels (" .. tostring(#self.levels) .. ")")
    if self.levelsHeaderState then
        self:drawLevels()
        ImGui.TreePop()
    end

    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local previewEffect = self:getPreviewEffect()
    local disabled = previewEffect == "" or not self:isSpawned()
    style.pushGreyedOut(disabled)
    if ImGui.Button(IconGlyphs.Play .. " Play fracturing effect##playFracturingEffect") and not disabled then
        self:playFracturingEffect()
    end
    style.popGreyedOut(disabled)
    if previewEffect == "" then
        style.tooltip("Set a fracturing effect on one of the destruction levels first.", ImGuiHoveredFlags.AllowWhenDisabled)
    else
        style.tooltip("Plays the first effect any level defines, once, on the preview. The mesh itself does not break, destruction is not simulated in-editor.", ImGuiHoveredFlags.AllowWhenDisabled)
    end

    self.advancedHeaderState = ImGui.TreeNodeEx("Advanced")

    if self.advancedHeaderState then
        style.mutedText("Accumulate Damage")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.accumulateDamage = style.trackedCheckbox(self.object, "##accumulateDamage", self.accumulateDamage)
        style.tooltip("Adds damage up over time instead of needing one big hit.")

        style.mutedText("Impulse To Damage")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.impulseToDamage = style.trackedDragFloat(self.object, "##impulseToDamage", self.impulseToDamage, 0.01, 0, 100, "%.3f")
        style.tooltip("How much damage an impulse converts to. The game uses 1 for 99% of these nodes.")

        style.mutedText("Contact To Damage")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.contactToDamage = style.trackedDragFloat(self.object, "##contactToDamage", self.contactToDamage, 0.1, 0, 1000, "%.2f")
        style.tooltip("How much damage a sustained contact converts to. The game mostly uses 10 or 15.")

        style.mutedText("Impulse Propagation")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.impulsePropagationFactor = style.trackedDragFloat(self.object, "##impulsePropagationFactor", self.impulsePropagationFactor, 0.001, 0, 1, "%.4f")
        style.tooltip("How much of an impulse carries to neighbouring chunks. Authored per mesh, so the value from the survey is usually the one you want.")

        style.mutedText("Impulse Diminishing")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.impulseDiminishingFactor = style.trackedDragFloat(self.object, "##impulseDiminishingFactor", self.impulseDiminishingFactor, 0.001, 0, 1, "%.4f")
        style.tooltip("How quickly a propagating impulse fades. Authored per mesh alongside Impulse Propagation.")

        style.mutedText("Mark Edge Chunks")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.markEdgeChunks = style.trackedCheckbox(self.object, "##markEdgeChunks", self.markEdgeChunks)
        style.tooltip("Treats chunks on the outside of the mesh differently, used on 13% of these nodes.")

        style.mutedText("Convex For Clusters")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.buildConvexForClusters = style.trackedCheckbox(self.object, "##buildConvexForClusters", self.buildConvexForClusters)
        style.tooltip("Builds a simpler convex collider for grouped pieces instead of using their real shape.")

        style.mutedText("Visuals Remain")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.visualsRemain = style.trackedCheckbox(self.object, "##visualsRemain", self.visualsRemain)
        style.tooltip("Leaves the broken pieces visible instead of removing them once they settle.")

        style.mutedText("Debris Timeout")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.debrisTimeout = style.trackedCheckbox(self.object, "##debrisTimeout", self.debrisTimeout)
        style.tooltip("Removes debris after a while, picking a random lifetime between the two values below.")

        ImGui.BeginDisabled(not self.debrisTimeout)
        style.mutedText("Debris Timeout Min")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.debrisTimeoutMin = style.trackedDragFloat(self.object, "##debrisTimeoutMin", self.debrisTimeoutMin, 0.1, 0, 1000, "%.1f")

        style.mutedText("Debris Timeout Max")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.debrisTimeoutMax = style.trackedDragFloat(self.object, "##debrisTimeoutMax", self.debrisTimeoutMax, 0.1, 0, 1000, "%.1f")
        ImGui.EndDisabled()

        style.mutedText("Fracture Field Mask")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.fractureFieldMask = style.trackedCombo(self.object, "##fractureFieldMask", self.fractureFieldMask, fractureFieldMasks, 240, {
            tooltip = "Which fracture field sources can break this mesh. FF_Default covers 96% of the game's nodes, FF_Locomotion lets NPCs and the player break it by walking into it."
        })

        style.mutedText("Navmesh Impact")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.navmeshImpact = style.trackedCombo(self.object, "##navmeshImpact", self.navmeshImpact, self.navmeshImpactEnum, 110, {
            tooltip = "How the mesh affects navigation. Only advisory: the node always takes its navmesh settings from the mesh instead."
        })

        ImGui.TreePop()
    end

    self:drawConversionSelector("##physicalDestructionConverterType", "Lossy Conversion##physicalDestructionSingle")
end

function physicalDestruction:export()
    local data = mesh.export(self)
    data.type = "worldPhysicalDestructionNode"

    -- worldPhysicalDestructionNode derives from worldNode, so none of the worldMeshNode
    -- rendering flags mesh.export writes exist on it.
    data.data.castLocalShadows = nil
    data.data.castRayTracedGlobalShadows = nil
    data.data.castRayTracedLocalShadows = nil
    data.data.castShadows = nil
    data.data.occluderType = nil
    data.data.windImpulseEnabled = nil

    data.data.forceAutoHideDistance = self.forceAutoHideDistance
    data.data.audioMetadata = {
        ["$type"] = "CName",
        ["$storage"] = "string",
        ["$value"] = self.audioMetadata == "" and "None" or self.audioMetadata
    }

    for key, value in pairs(constantExport) do
        data.data[key] = value
    end

    local params = {
        ["$type"] = "physicsDestructionParams",
        ["simulationType"] = self.simulationTypeEnum[self.simulationType + 1] or "Kinematic",
        ["startInactive"] = self.startInactive and 1 or 0,
        ["turnDynamicOnImpulse"] = self.turnDynamicOnImpulse and 1 or 0,
        ["markEdgeChunks"] = self.markEdgeChunks and 1 or 0,
        ["buildConvexForClusters"] = self.buildConvexForClusters and 1 or 0,
        ["damageThreshold"] = self.damageThreshold,
        ["damageEndurance"] = self.damageEndurance,
        ["bondEndurance"] = self.bondEndurance,
        ["accumulateDamage"] = self.accumulateDamage and 1 or 0,
        ["impulseToDamage"] = self.impulseToDamage,
        ["contactToDamage"] = self.contactToDamage,
        ["impulsePropagationFactor"] = self.impulsePropagationFactor,
        ["impulseDiminishingFactor"] = self.impulseDiminishingFactor,
        ["debrisTimeout"] = self.debrisTimeout and 1 or 0,
        ["debrisTimeoutMin"] = self.debrisTimeoutMin,
        ["debrisTimeoutMax"] = self.debrisTimeoutMax,
        ["visualsRemain"] = self.visualsRemain and 1 or 0,
        ["fractureFieldMask"] = fractureFieldMasks[self.fractureFieldMask + 1] or "FF_Default"
    }

    for key, value in pairs(constantDestructionParams) do
        params[key] = value
    end

    data.data.destructionParams = params

    -- One entry per level of the mesh's fracture hierarchy.
    local levels = {}
    for _, level in ipairs(self.levels) do
        local entry = {
            ["$type"] = "physicsDestructionLevelData",
            ["filterData"] = exportFilterData(level.preset)
        }

        local effect = utils.trimString(level.fracturingEffect or "")
        if effect ~= "" then
            entry["fracturingEffect"] = exportResourceRef(effect)
        end

        table.insert(levels, entry)
    end
    data.data.destructionLevelData = levels

    -- useMeshNavmeshSettings is always on, so navigationSetting is never read. It is still
    -- written with the chosen value, to keep the node consistent when inspected.
    data.data.navigationSetting = {
        ["$type"] = "NavGenNavigationSetting",
        ["navmeshImpact"] = self.navmeshImpactEnum[self.navmeshImpact + 1] or "Blocking"
    }

    return data
end

return physicalDestruction
