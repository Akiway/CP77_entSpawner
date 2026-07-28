local mesh = require("modules/classes/spawn/mesh/mesh")
local spawnable = require("modules/classes/spawn/spawnable")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
local Cron = require("modules/utils/Cron")
local destructibleData = require("modules/utils/destructibleData")

---Class for worldInstancedDestructibleMeshNode
---
---The exposed properties are the ones the shipped streamingsectors actually vary; see
---`script/extract_destructible_node_usage.wscript`. Properties the game leaves at one
---value in >99% of its 124k+ placements are written on export from `constantExport`
---instead of being editable, and the collision masks follow from the filter preset.
---@class destructibleMesh : mesh
---@field public simulationType integer
---@field public filterDataSource integer
---@field public startInactive boolean
---@field public turnDynamicOnImpulse boolean
---@field public useAggregate boolean
---@field public enableSelfCollisionInAggregate boolean
---@field public isDestructible boolean
---@field public isPierceable boolean
---@field public filterPreset integer
---@field public damageEndurance number
---@field public fracturingEffect string
---@field public idleEffect string
---@field public forceAutoHideDistance number
---@field private advancedHeaderState boolean
---@field private effectStopCron number?
---@field private hasActiveEffects boolean
---@field private pendingRespawn boolean
local destructibleMesh = setmetatable({}, { __index = mesh })

---Values the game keeps constant across essentially every placement. Written on export,
---not editable. Percentages are the share of the 525629 surveyed nodes using that value.
local constantExport = {
    version = 2,                        -- 100.00%
    isHostOnly = 0,                     -- 100.00%
    removeFromRainMap = 0,              -- 100.00%
    isVisibleInGame = 1,                -- 99.98%
    renderSceneLayerMask = "Default",   -- 99.97%
    lodLevelScales = 4294967295,        -- 99.89%
    accumulateDamage = 1,               -- 99.83%
    useMeshNavmeshSettings = 1,         -- 99.69%, which makes navigationSetting irrelevant
    damageThreshold = 1,                -- 99.39%
    impulseToDamage = 1,                -- 99.36%
    isWorkspot = 0,                     -- 99.24%
    occluderAutohideDistanceScale = 255 -- 98.01%
}

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

-- Effect names used on the preview entity's effect spawner component.
local IDLE_EFFECT_NAME = "idleEffect"
local FRACTURING_EFFECT_NAME = "fracturingEffect"

-- Destroying the entity in the same frame as the stop event leaves the effect playing in
-- the world with nothing left to stop it, so the despawn waits this long. Same delay as
-- the Effects spawnable uses.
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

function destructibleMesh:new()
	local o = mesh.new(self)

    o.dataType = "Destructible Mesh"
    o.modulePath = "physics/destructibleMesh"
    o.spawnDataPath = "data/spawnables/mesh/destructible/"
    o.node = "worldInstancedDestructibleMeshNode"
    o.description = "Places a destructible mesh, from a given .mesh file. Reacts to impulses and can break apart, using the physics data shipped with the mesh."
    o.previewNote = "Destruction itself is not simulated in-editor. The physics body and the idle effect are previewed, and the fracturing effect can be played on demand."
    o.icon = IconGlyphs.CubeOffOutline

    o.simulationType = 2 -- Kinematic
    o.startInactive = false
    o.turnDynamicOnImpulse = true
    o.isDestructible = true
    o.damageEndurance = 10
    o.fracturingEffect = ""
    o.forceAutoHideDistance = 150

    o.filterPreset = 0
    o.filterDataSource = 0 -- Parent
    o.useAggregate = false
    o.enableSelfCollisionInAggregate = false
    o.isPierceable = false
    o.idleEffect = ""

    o.fracturingEffectSearch = ""
    o.idleEffectSearch = ""
    o.filterPresetSearch = ""

    o.simulationTypeEnum = utils.enumTable("physicsSimulationType")
    o.filterDataSourceEnum = utils.enumTable("physicsFilterDataSource")
    if #o.filterDataSourceEnum == 0 then
        o.filterDataSourceEnum = { "Parent", "Collider" }
    end

    o.advancedHeaderState = false
    o.hideGenerate = true
    o.convertTarget = 0

    o.effectStopCron = nil
    o.hasActiveEffects = false
    o.pendingRespawn = false

    setmetatable(o, { __index = self })
   	return o
end

function destructibleMesh:loadSpawnData(data, position, rotation)
    mesh.loadSpawnData(self, data, position, rotation)

    -- A freshly placed asset (or one converted from another mesh type) carries no
    -- destructible settings yet, so it starts from how the game uses that mesh.
    if data.simulationType == nil then
        self:applyMeshDefaults(true)
    end
end

---Collision masks of the selected preset. The survey found the masks to be a pure
---function of the preset, so they are never edited by hand.
---@private
---@return table
function destructibleMesh:getMasks()
    return destructibleData.getPresetMasks(self:getPresetName())
end

---@private
---@return string
function destructibleMesh:getPresetName()
    local names = destructibleData.getPresetNames()
    return names[self.filterPreset + 1] or names[1] or destructibleData.fallbackPreset
end

---Applies the settings the game most commonly uses with the current mesh.
---@param silent boolean? Suppresses the toast, used when placing a new asset.
---@return boolean applied
function destructibleMesh:applyMeshDefaults(silent)
    local defaults = destructibleData.getMeshDefaults(self.spawnData)
    if not defaults then
        return false
    end

    if defaults.simulationType then
        local index = utils.indexValue(self.simulationTypeEnum, defaults.simulationType)
        if index > 0 then
            self.simulationType = index - 1
        end
    end

    if defaults.filterDataSource then
        local index = utils.indexValue(self.filterDataSourceEnum, defaults.filterDataSource)
        if index > 0 then
            self.filterDataSource = index - 1
        end
    end

    if defaults["filterData.preset"] then
        local index = utils.indexValue(destructibleData.getPresetNames(), defaults["filterData.preset"])
        if index > 0 then
            self.filterPreset = index - 1
        end
    end

    if defaults.isDestructible ~= nil then
        self.isDestructible = toBoolean(defaults.isDestructible)
    end
    if defaults.startInactive ~= nil then
        self.startInactive = toBoolean(defaults.startInactive)
    end
    if defaults.turnDynamicOnImpulse ~= nil then
        self.turnDynamicOnImpulse = toBoolean(defaults.turnDynamicOnImpulse)
    end

    local endurance = tonumber(defaults.damageEndurance)
    if endurance then
        self.damageEndurance = endurance
    end

    self.fracturingEffect = utils.trimString(defaults.fracturingEffect or "")
    self.idleEffect = utils.trimString(defaults.idleEffect or "")

    if not silent then
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Applied game defaults for this mesh"))
    end

    return true
end

function destructibleMesh:onAssemble(entity)
    spawnable.onAssemble(self, entity)

    local component = PhysicalMeshComponent.new()
    component.name = "mesh"
    component.mesh = ResRef.FromString(self.spawnData)
    component.visualScale = Vector3.new(self.scale.x, self.scale.y, self.scale.z)
    component.meshAppearance = self.app
    component.castLocalShadows = Enum.new("shadowsShadowCastingMode", self.castLocalShadows)
    component.castRayTracedGlobalShadows = Enum.new("shadowsShadowCastingMode", self.castRayTracedGlobalShadows)
    component.castRayTracedLocalShadows = Enum.new("shadowsShadowCastingMode", self.castRayTracedLocalShadows)
    component.castShadows = Enum.new("shadowsShadowCastingMode", self.castShadows)

    if not self.isAssetPreview then
        local masks = self:getMasks()

        component.simulationType = Enum.new("physicsSimulationType", self.simulationType)
        component.startInactive = self.startInactive
        component.filterDataSource = Enum.new("physicsFilterDataSource", self.filterDataSource)

        local filterData = physicsFilterData.new()
        filterData.preset = self:getPresetName()

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

---Spawns through a game object rather than the plain entity the other mesh types use.
---`GameObjectEffectHelper` only accepts a gameObject, and it is the only way to start or
---stop an `entEffectSpawnerComponent`, which has no methods of its own.
---Cancels a pending delayed despawn.
---@private
---@return boolean cancelled
function destructibleMesh:cancelEffectStop()
    if not self.effectStopCron then
        return false
    end

    Cron.Halt(self.effectStopCron)
    self.effectStopCron = nil
    return true
end

function destructibleMesh:spawn()
    -- Hiding and immediately showing again lands here while the delayed despawn is still
    -- pending. The entity is alive but its effects were already stopped, so keep it and
    -- start the idle effect back up instead of leaving a silent preview behind.
    if self:cancelEffectStop() and self:isSpawned() then
        self.pendingRespawn = false

        if self.idleEffect ~= "" then
            toggleEffect(self:getEntity(), IDLE_EFFECT_NAME, true, true)
            self.hasActiveEffects = true
        end

        return
    end

    local mesh = self.spawnData
    self.spawnData = "base\\spawner\\empty_game_object.ent"

    spawnable.spawn(self)
    self.spawnData = mesh
end

---Attaches the idle and fracturing effects to the preview entity. Both are registered on
---one spawner component, the idle one is started right away, the fracturing one waits for
---the play button. Effect descs are baked at assemble time, so changing either resource
---requires a respawn.
---@protected
---@param entity entEntity
function destructibleMesh:assembleEffects(entity)
    if self.isAssetPreview then return end
    if self.idleEffect == "" and self.fracturingEffect == "" then return end

    local descs = {}

    if self.idleEffect ~= "" then
        local desc = entEffectDesc.new()
        desc.effect = self.idleEffect
        desc.effectName = IDLE_EFFECT_NAME
        table.insert(descs, desc)
    end

    if self.fracturingEffect ~= "" then
        local desc = entEffectDesc.new()
        desc.effect = self.fracturingEffect
        desc.effectName = FRACTURING_EFFECT_NAME
        table.insert(descs, desc)
    end

    local component = entEffectSpawnerComponent.new()
    component.name = "effects"
    component.effectDescs = descs
    entity:AddComponent(component)

    if self.idleEffect ~= "" then
        toggleEffect(entity, IDLE_EFFECT_NAME, true, true)
        self.hasActiveEffects = true
    end
end

---Plays the fracturing effect once on the preview entity.
---@return boolean played
function destructibleMesh:playFracturingEffect()
    local entity = self:getEntity()
    if not entity or self.fracturingEffect == "" then
        return false
    end

    -- Restart from the beginning if it is still running from a previous press.
    toggleEffect(entity, FRACTURING_EFFECT_NAME, false)
    toggleEffect(entity, FRACTURING_EFFECT_NAME, true, false)
    self.hasActiveEffects = true

    return true
end

function destructibleMesh:despawn()
    local entity = self:getEntity()

    -- Nothing is playing, so the entity can go right away and hiding stays synchronous.
    if not entity or not self.hasActiveEffects then
        self:cancelEffectStop()
        mesh.despawn(self)
        return
    end

    toggleEffect(entity, IDLE_EFFECT_NAME, false)
    toggleEffect(entity, FRACTURING_EFFECT_NAME, false)
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
function destructibleMesh:respawn()
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

function destructibleMesh:save()
    local data = mesh.save(self)

    data.simulationType = self.simulationType
    data.startInactive = self.startInactive
    data.turnDynamicOnImpulse = self.turnDynamicOnImpulse
    data.isDestructible = self.isDestructible
    data.damageEndurance = self.damageEndurance
    data.fracturingEffect = self.fracturingEffect
    data.forceAutoHideDistance = self.forceAutoHideDistance

    data.filterPreset = self.filterPreset
    data.filterDataSource = self.filterDataSource
    data.useAggregate = self.useAggregate
    data.enableSelfCollisionInAggregate = self.enableSelfCollisionInAggregate
    data.isPierceable = self.isPierceable
    data.idleEffect = self.idleEffect

    return data
end

---Respawns the preview after changing a property that is only applied on assemble.
---@protected
---@param changed boolean
function destructibleMesh:updateFull(changed)
    if changed and self:isSpawned() then self:respawn() end
end

---Draws one effect resource row backed by a surveyed effect list.
---@private
---@param label string
---@param id string
---@param value string
---@param searchKey string
---@param options string[]
---@param tooltip string
---@return string path
function destructibleMesh:drawEffectSelector(label, id, value, searchKey, options, tooltip)
    style.mutedText(label)
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)

    self[searchKey] = self[searchKey] or ""

    local selected, search, changed = style.trackedSearchDropdown(
        id,
        "Search effect or type a path...",
        value,
        self[searchKey],
        options,
        {
            element = self.object,
            width = 220,
            matchContentWidth = true,
            -- The listed effects are the ones the game itself uses, but any .effect can be
            -- typed in, including ones added by mods.
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

---Explains where the destructible settings come from, and offers to restore them.
---Drawn once above the destructible specific properties.
---@private
function destructibleMesh:drawMeshDefaultsNote()
    local hasDefaults = destructibleData.hasMeshDefaults(self.spawnData)

    ImGui.Dummy(0, 8 * style.viewSize)

    if hasDefaults then
        style.styledTextWrapped("The settings below were filled in from how the base game places this mesh.", style.mutedColor)
    else
        style.styledTextWrapped("The base game never places this mesh as a destructible, so the settings below start from generic defaults.", style.mutedColor)
    end

    style.pushGreyedOut(not hasDefaults)
    if ImGui.Button("Reset to game defaults##destructibleDefaults") and hasDefaults then
        history.addAction(history.getElementChange(self.object))
        self:applyMeshDefaults(false)
        self:updateFull(true)
    end
    style.popGreyedOut(not hasDefaults)

    if hasDefaults then
        style.tooltip("Restores the settings the base game uses for this mesh.")
    else
        style.tooltip("No recorded usage for this mesh, nothing to restore.", ImGuiHoveredFlags.AllowWhenDisabled)
    end

    ImGui.Dummy(0, 4 * style.viewSize)

    ImGui.Spacing()
end

function destructibleMesh:draw()
    local calculateMaxWidth = not self.maxPropertyWidth

    mesh.draw(self)

    if calculateMaxWidth then
        self.maxPropertyWidth = math.max(self.maxPropertyWidth, utils.getTextMaxWidth({
            "Auto Hide Distance", "Turn Dynamic On Impulse", "Damage Endurance", "Collision Preset", "Fracturing Effect"
        }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX())
    end

    local changed

    style.mutedText("Auto Hide Distance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.forceAutoHideDistance = style.trackedDragFloat(self.object, "##forceAutoHideDistance", self.forceAutoHideDistance, 0.1, 0, 1000, "%.1f")

    -- Everything from here down is destructible specific and gets pre-filled from the
    -- per mesh survey, so it is explained once instead of in every tooltip.
    self:drawMeshDefaultsNote()

    style.mutedText("Simulation Type")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    -- The helper text goes through the combo's own tooltip: a second style.tooltip call
    -- would open a separate tooltip window on top of it.
    self.simulationType, changed = style.trackedCombo(self.object, "##simulationType", self.simulationType, self.simulationTypeEnum, 110, {
        tooltip = "Kinematic keeps the mesh in place until something hits it, Dynamic lets it move right away."
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
    style.tooltip("Switches a kinematic body to dynamic once it gets hit.")

    style.mutedText("Is Destructible")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.isDestructible = style.trackedCheckbox(self.object, "##isDestructible", self.isDestructible)
    style.tooltip("Lets the mesh break apart when it takes enough damage.")

    style.mutedText("Damage Endurance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.damageEndurance = style.trackedDragFloat(self.object, "##damageEndurance", self.damageEndurance, 0.1, 0, 10000, "%.2f")
    style.tooltip("How much damage the mesh takes before breaking. The game mostly uses 1, 5, 10 or 30.")

    style.mutedText("Collision Preset")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local presetNames = destructibleData.getPresetNames()
    self.filterPreset = math.max(0, math.min(self.filterPreset, #presetNames - 1))
    local selectedPreset = presetNames[self.filterPreset + 1] or destructibleData.fallbackPreset
    local presetChanged
    selectedPreset, self.filterPresetSearch, presetChanged = style.trackedSearchDropdown(
        "##filterPreset",
        "Search preset...",
        selectedPreset,
        self.filterPresetSearch or "",
        presetNames,
        {
            element = self.object,
            width = 220,
            matchContentWidth = true,
            tooltip = "Collision behaviour."
        }
    )
    if presetChanged then
        self.filterPreset = math.max(utils.indexValue(presetNames, selectedPreset) - 1, 0)
        self:updateFull(true)
    end

    local previousFracturingEffect = self.fracturingEffect
    self.fracturingEffect = self:drawEffectSelector(
        "Fracturing Effect",
        "##fracturingEffect",
        self.fracturingEffect,
        "fracturingEffectSearch",
        destructibleData.getFracturingEffects(),
        "Effect played when the mesh breaks.\nThe list holds the effects the game uses for destruction, any other .effect path can be typed in."
    )
    -- The effect descs are baked when the entity is assembled, so a new resource needs a
    -- respawn before it can be played.
    self:updateFull(self.fracturingEffect ~= previousFracturingEffect)

    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local disabled = self.fracturingEffect == "" or not self:isSpawned()
    style.pushGreyedOut(disabled)
    if ImGui.Button(IconGlyphs.Play .. " Play fracturing effect##playFracturingEffect") and not disabled then
        self:playFracturingEffect()
    end
    style.popGreyedOut(disabled)
    if self.fracturingEffect == "" then
        style.tooltip("Select a fracturing effect first.", ImGuiHoveredFlags.AllowWhenDisabled)
    else
        style.tooltip("Plays the effect once on the preview. The mesh itself does not break, destruction is not simulated in-editor.", ImGuiHoveredFlags.AllowWhenDisabled)
    end

    self.advancedHeaderState = ImGui.TreeNodeEx("Advanced")

    if self.advancedHeaderState then
        style.mutedText("Filter Data Source")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.filterDataSource, changed = style.trackedCombo(self.object, "##filterDataSource", self.filterDataSource, self.filterDataSourceEnum, 110, {
            tooltip = "Parent uses the collision preset above, Collider uses the filter data baked into the mesh."
        })
        self:updateFull(changed)

        style.mutedText("Use Aggregate")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.useAggregate = style.trackedCheckbox(self.object, "##useAggregate", self.useAggregate)
        style.tooltip("Groups the broken pieces into one physics aggregate.")

        ImGui.BeginDisabled(not self.useAggregate)
        style.mutedText("Self Collision In Aggregate")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.enableSelfCollisionInAggregate = style.trackedCheckbox(self.object, "##enableSelfCollisionInAggregate", self.enableSelfCollisionInAggregate)
        ImGui.EndDisabled()

        style.mutedText("Is Pierceable")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.isPierceable = style.trackedCheckbox(self.object, "##isPierceable", self.isPierceable)
        style.tooltip("Lets bullets pass through the mesh.")

        local previousIdleEffect = self.idleEffect
        self.idleEffect = self:drawEffectSelector(
            "Idle Effect",
            "##idleEffect",
            self.idleEffect,
            "idleEffectSearch",
            destructibleData.getIdleEffects(),
            "Effect played continuously while the mesh is intact, e.g. a flame or steam. Previewed live.\nThe list holds the effects the game uses as idle effects, any other .effect path can be typed in."
        )
        self:updateFull(self.idleEffect ~= previousIdleEffect)

        ImGui.TreePop()
    end

    self:drawConversionSelector("##destructibleMeshConverterType", "Lossy Conversion##destructibleMeshSingle")
end

function destructibleMesh:export()
    local masks = self:getMasks()

    local data = mesh.export(self)
    data.type = "worldInstancedDestructibleMeshNode"

    data.data.forceAutoHideDistance = self.forceAutoHideDistance
    data.data.simulationType = self.simulationTypeEnum[self.simulationType + 1] or "Kinematic"
    data.data.filterDataSource = self.filterDataSourceEnum[self.filterDataSource + 1] or "Parent"
    data.data.startInactive = self.startInactive and 1 or 0
    data.data.turnDynamicOnImpulse = self.turnDynamicOnImpulse and 1 or 0
    data.data.useAggregate = self.useAggregate and 1 or 0
    data.data.enableSelfCollisionInAggregate = self.enableSelfCollisionInAggregate and 1 or 0
    data.data.isDestructible = self.isDestructible and 1 or 0
    data.data.isPierceable = self.isPierceable and 1 or 0
    data.data.damageEndurance = self.damageEndurance

    for key, value in pairs(constantExport) do
        data.data[key] = value
    end

    data.data.filterData = {
        ["Data"] = {
            ["$type"] = "physicsFilterData",
            ["preset"] = {
                ["$type"] = "CName",
                ["$storage"] = "string",
                ["$value"] = self:getPresetName()
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

    if self.fracturingEffect ~= "" then
        data.data.fracturingEffect = exportResourceRef(self.fracturingEffect)
    end
    if self.idleEffect ~= "" then
        data.data.idleEffect = exportResourceRef(self.idleEffect)
    end

    -- useMeshNavmeshSettings is always on, so navigationSetting is never read. It is still
    -- written with the value the game uses, to keep the node consistent when inspected.
    data.data.navigationSetting = {
        ["$type"] = "NavGenNavigationSetting",
        ["navmeshImpact"] = "Blocking"
    }

    -- The node renders one entry per cooked instance transform, relative to the node
    -- transform. World Builder places a single instance, so the buffer holds one identity
    -- transform. `instanceTransforms` stays empty, matching cooked sectors.
    data.data.cookedInstanceTransforms = {
        ["$type"] = "worldTransformBuffer",
        ["startIndex"] = 0,
        ["numElements"] = 1,
        ["sharedDataBuffer"] = {
            ["Data"] = {
                ["$type"] = "worldSharedDataBuffer",
                ["buffer"] = {
                    ["BufferId"] = utils.nextExportBufferId("CookedInstanceTransformsBuffer"),
                    ["Flags"] = 4063232,
                    ["Type"] = "WolvenKit.RED4.Archive.Buffer.CookedInstanceTransformsBuffer, WolvenKit.RED4, Version=8.19.1.0, Culture=neutral, PublicKeyToken=null",
                    ["Data"] = {
                        ["Transforms"] = {
                            {
                                ["$type"] = "Transform",
                                ["position"] = {
                                    ["$type"] = "Vector4",
                                    ["X"] = 0,
                                    ["Y"] = 0,
                                    ["Z"] = 0,
                                    ["W"] = 0
                                },
                                ["orientation"] = {
                                    ["$type"] = "Quaternion",
                                    ["i"] = 0,
                                    ["j"] = 0,
                                    ["k"] = 0,
                                    ["r"] = 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return data
end

return destructibleMesh
