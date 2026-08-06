local destructionMesh = require("modules/classes/spawn/physics/destructionMesh")
local spawnable = require("modules/classes/spawn/spawnable")
local visualizer = require("modules/utils/preview/visualizer")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local redExport = require("modules/utils/interop/redExport")
local destructibleData = require("modules/utils/data/destructibleData")

---Class for worldInstancedDestructibleMeshNode
---
---The exposed properties are the ones the shipped streamingsectors actually vary; see
---`script/extract_destructible_node_usage.wscript`. Properties the game leaves at one
---value in >99% of its 124k+ placements are written on export from `constantExport`
---instead of being editable, and the collision masks follow from the filter preset.
---
---Preset handling, the per mesh defaults note and the effect preview come from
---[[destructionMesh]], which the other two destruction node types share.
---@class destructibleMesh : destructionMesh
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
local destructibleMesh = setmetatable({}, { __index = destructionMesh })

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

---Node type groups this class is browsed under when it shares a browser with the other destruction
---classes. Both spawn the same world node; the split only separates the meshes the game actually
---placed here (first entry, with surveyed settings to pre-fill) from the rest, which use defaults.
destructibleMesh.nodeTypeGroups = {
    { label = "Instanced Destructible Mesh", icon = IconGlyphs.GlassFragile },
    { label = "Instanced Destructible Mesh (Generic)", icon = IconGlyphs.DatabaseOffOutline }
}

---Explains the split in the browser's info tooltip, where the two groups otherwise look
---like two different world nodes.
destructibleMesh.nodeTypeGroupsNote =
    "\"" .. destructibleMesh.nodeTypeGroups[1].label .. "\" holds the meshes the base game places as destructibles, " ..
    "which come with its settings pre-filled. \"" .. destructibleMesh.nodeTypeGroups[2].label .. "\" holds every other " ..
    "eligible mesh, which starts from generic defaults. Both place the same node."

---Which of `nodeTypeGroups` a Spawn New entry belongs to.
---@param entry table? Spawn New entry; its `name` is the mesh path.
---@return string label
function destructibleMesh.resolveNodeTypeGroup(entry)
    local groups = destructibleMesh.nodeTypeGroups

    if destructibleData.hasMeshDefaults(entry and entry.name) then
        return groups[1].label
    end

    return groups[2].label
end

-- Effect names used on the preview entity's effect spawner component.
local IDLE_EFFECT_NAME = "idleEffect"
local FRACTURING_EFFECT_NAME = "fracturingEffect"

function destructibleMesh:new()
	local o = destructionMesh.new(self)

    o.dataType = "Instanced Destructible Mesh"
    o.modulePath = "physics/destructibleMesh"
    o.spawnDataPath = "data/spawnables/mesh/destructible/"
    o.node = "worldInstancedDestructibleMeshNode"
    o.description = "Places a destructible mesh, from a given .mesh file. Reacts to impulses and can break apart, using the physics data shipped with the mesh."
    o.previewNote = "Destruction itself is not simulated in-editor. The physics body and the idle effect are previewed, and the fracturing effect can be played on demand."
    o.icon = IconGlyphs.GlassFragile

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

    o.simulationTypeEnum = utils.enumTable("physicsSimulationType")
    o.filterDataSourceEnum = utils.enumTable("physicsFilterDataSource")
    if #o.filterDataSourceEnum == 0 then
        o.filterDataSourceEnum = { "Parent", "Collider" }
    end

    -- The idle effect runs continuously on the intact mesh, so it is previewed live; the
    -- fracturing one only plays on demand, since nothing breaks the mesh in-editor.
    o.effectSlots = {
        { name = IDLE_EFFECT_NAME, autoStart = true, resolve = function (this) return this.idleEffect end },
        { name = FRACTURING_EFFECT_NAME, resolve = function (this) return this.fracturingEffect end }
    }
    o.playableEffectSlot = FRACTURING_EFFECT_NAME

    o.fallbackPreset = destructibleData.fallbackPreset
    o.defaultsAbsentText = "The base game never places this mesh as a destructible, so the settings below start from generic defaults."
    o.defaultsRestoreTooltip = "Restores the settings the base game uses for this mesh."

    setmetatable(o, { __index = self })
   	return o
end

function destructibleMesh:loadSpawnData(data, position, rotation)
    destructionMesh.loadSpawnData(self, data, position, rotation)

    -- A freshly placed asset (or one converted from another mesh type) carries no
    -- destructible settings yet, so it starts from how the game uses that mesh.
    if data.simulationType == nil then
        self:applyMeshDefaults(true)
    end
end

---Ordered by how often the game uses each preset, so the common choices sit at the top.
---@return string[]
function destructibleMesh:getPresetNames()
    return destructibleData.getPresetNames()
end

---@return boolean
function destructibleMesh:hasMeshDefaults()
    return destructibleData.hasMeshDefaults(self.spawnData)
end

---Applies the settings the game most commonly uses with the current mesh.
---@param silent boolean? Suppresses the toast, used when placing a new asset.
---@return boolean applied
function destructibleMesh:applyMeshDefaults(silent)
    local defaults = destructibleData.getMeshDefaults(self.spawnData)
    if not defaults then
        return false
    end

    self.simulationType = utils.enumIndex(self.simulationTypeEnum, defaults.simulationType, self.simulationType)
    self.filterDataSource = utils.enumIndex(self.filterDataSourceEnum, defaults.filterDataSource, self.filterDataSource)
    self.filterPreset = utils.enumIndex(self:getPresetNames(), defaults["filterData.preset"], self.filterPreset)

    if defaults.isDestructible ~= nil then
        self.isDestructible = utils.toBoolean(defaults.isDestructible)
    end
    if defaults.startInactive ~= nil then
        self.startInactive = utils.toBoolean(defaults.startInactive)
    end
    if defaults.turnDynamicOnImpulse ~= nil then
        self.turnDynamicOnImpulse = utils.toBoolean(defaults.turnDynamicOnImpulse)
    end

    self.damageEndurance = tonumber(defaults.damageEndurance) or self.damageEndurance

    self.fracturingEffect = utils.trimString(defaults.fracturingEffect or "")
    self.idleEffect = utils.trimString(defaults.idleEffect or "")

    self:reportMeshDefaultsApplied(silent)

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
        component.simulationType = Enum.new("physicsSimulationType", self.simulationType)
        component.startInactive = self.startInactive
        component.filterDataSource = Enum.new("physicsFilterDataSource", self.filterDataSource)

        self:applyFilterData(component, self:getPresetName())
    end

    entity:AddComponent(component)

    self:assembleEffects(entity)

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    destructionMesh.assetPreviewAssemble(self, entity)
end

function destructibleMesh:save()
    local data = destructionMesh.save(self)

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

function destructibleMesh:draw()
    local calculateMaxWidth = not self.maxPropertyWidth

    destructionMesh.draw(self)

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

    self:drawPresetSelector("Collision behaviour.")

    local previousFracturingEffect = self.fracturingEffect
    self.fracturingEffect = self:drawResourceSelector(
        "Fracturing Effect",
        "##fracturingEffect",
        self.fracturingEffect,
        "fracturingEffectSearch",
        destructibleData.getAllEffects(),
        "Search or type a path...",
        "Effect played when the mesh breaks.\nEvery .effect in the game is listed, and any other path can be typed in."
    )
    -- The effect descs are baked when the entity is assembled, so a new resource needs a
    -- respawn before it can be played.
    self:updateFull(self.fracturingEffect ~= previousFracturingEffect)

    self:drawPlayEffectButton(
        "Select a fracturing effect first.",
        "Plays the effect once on the preview. The mesh itself does not break, destruction is not simulated in-editor."
    )

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
        self.idleEffect = self:drawResourceSelector(
            "Idle Effect",
            "##idleEffect",
            self.idleEffect,
            "idleEffectSearch",
            destructibleData.getAllEffects(),
            "Search or type a path...",
            "Effect played continuously while the mesh is intact, e.g. a flame or steam. Previewed live.\nEvery .effect in the game is listed, and any other path can be typed in."
        )
        self:updateFull(self.idleEffect ~= previousIdleEffect)

        ImGui.TreePop()
    end

    self:drawConversionSelector("##destructibleMeshConverterType", "Lossy Conversion##destructibleMeshSingle")
end

function destructibleMesh:export()
    local data = destructionMesh.export(self)
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

    utils.combineHashTable(data.data, constantExport)

    data.data.filterData = redExport.filterData(self:getPresetName(), self:getMasks())

    if self.fracturingEffect ~= "" then
        data.data.fracturingEffect = redExport.resourceRef(self.fracturingEffect)
    end
    if self.idleEffect ~= "" then
        data.data.idleEffect = redExport.resourceRef(self.idleEffect)
    end

    -- useMeshNavmeshSettings is always on, so navigationSetting is never read. It is still
    -- written with the value the game uses, to keep the node consistent when inspected.
    data.data.navigationSetting = redExport.navigationSetting("Blocking")

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
                    ["Type"] = "WolvenKit.RED4.Archive.Buffer.CookedInstanceTransformsBuffer, WolvenKit.RED4",
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
