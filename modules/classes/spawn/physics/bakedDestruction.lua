local destructionMesh = require("modules/classes/spawn/physics/destructionMesh")
local spawnable = require("modules/classes/spawn/spawnable")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local redExport = require("modules/utils/redExport")
local destructionData = require("modules/utils/destructionData")

---Class for worldBakedDestructionNode
---
---Destruction played back as a baked animation rather than simulated: the node holds the
---intact mesh plus an optional pre-fractured mesh, and plays `numFrames` frames of it at
---`frameRate` when triggered. Derives from worldMeshNode, so it keeps the usual shadow,
---occluder and render layer properties.
---
---The exposed properties are the ones the shipped sectors actually vary; see
---`script/extract_destruction_node_usage.wscript`. Of the 36 surveyed properties, 23 sit on
---a single value in at least 99% of the 4116 placements and are written from
---`constantExport` rather than being editable.
---
---The survey found two distinct populations: 71% of placements have no fractured mesh and
---use the `Debris` preset (vegetation, where the fracture lives inside the one mesh), and
---29% pair an intact mesh with a `*_dst_dynamic` mesh under the `Destructible` preset.
---
---Preset handling and the per mesh defaults note come from [[destructionMesh]], which the
---other two destruction node types share. This one previews no effect: the destruction
---effect only plays when the animation triggers, which never happens in-editor.
---@class bakedDestruction : destructionMesh
---@field public meshFractured string
---@field public meshFracturedAppearance string
---@field public numFrames number
---@field public playOnlyOnce boolean
---@field public restartOnTrigger boolean
---@field public disableCollidersOnTrigger boolean
---@field public filterPreset integer
---@field public destructionEffect string
---@field public audioMetadata string
---@field public damageThreshold number
---@field public damageEndurance number
---@field public forceAutoHideDistance number
local bakedDestruction = setmetatable({}, { __index = destructionMesh })

---Values the game keeps constant across essentially every placement. Written on export, not
---editable. Percentages are the share of the 4116 surveyed nodes using that value.
local constantExport = {
    version = 2,                        -- 100.00%
    isVisibleInGame = 1,                -- 100.00%
    isHostOnly = 0,                     -- 100.00%
    accumulateDamage = 1,               -- 100.00%
    filterDataSource = "Parent",        -- 100.00%
    frameRate = 24,                     -- 100.00%
    removeFromRainMap = 0,              -- 100.00%
    renderSceneLayerMask = "Default",   -- 100.00%
    useMeshNavmeshSettings = 1,         -- 100.00%, which makes navigationSetting advisory
    lodLevelScales = 4294967295,        -- 99.90%
    impulseToDamage = 1,                -- 99.80%
    contactToDamage = 1,                -- 99.80%
    fractureFieldMask = "FF_Default",   -- 99.80%
    occluderAutohideDistanceScale = 255 -- 99.60%
}

function bakedDestruction:new()
	local o = destructionMesh.new(self)

    o.dataType = "Baked Destruction Mesh"
    o.modulePath = "physics/bakedDestruction"
    o.spawnDataPath = "data/spawnables/mesh/bakedDestruction/"
    o.node = "worldBakedDestructionNode"
    o.description = "Places a mesh that breaks by playing a baked destruction animation, rather than simulating it. Optionally swaps to a pre-fractured mesh when triggered."
    o.previewNote = "The intact mesh is previewed. The destruction animation and the fractured mesh are not played in-editor."
    o.icon = IconGlyphs.CubeOffOutline

    o.meshFractured = ""
    o.meshFracturedAppearance = "None"
    o.numFrames = 50
    o.playOnlyOnce = true
    o.restartOnTrigger = false
    o.disableCollidersOnTrigger = true

    o.destructionEffect = ""
    o.audioMetadata = "None"
    o.damageThreshold = 10
    o.damageEndurance = 20
    o.forceAutoHideDistance = 150

    o.destructionEffectSearch = ""
    o.audioMetadataSearch = ""
    o.meshFracturedSearch = ""

    o.fallbackPreset = destructionData.fallbackBakedPreset
    o.defaultsAbsentText = "The base game never places this mesh as baked destruction, so the settings below start from generic defaults. A mesh needs a baked destruction animation for this node to do anything."
    o.defaultsRestoreTooltip = "Restores the settings the base game uses for this mesh, including its fractured mesh."

    setmetatable(o, { __index = self })
   	return o
end

function bakedDestruction:loadSpawnData(data, position, rotation)
    destructionMesh.loadSpawnData(self, data, position, rotation)

    -- A freshly placed asset (or one converted from another mesh type) carries no baked
    -- destruction settings yet, so it starts from how the game uses that mesh.
    if data.numFrames == nil then
        self:applyMeshDefaults(true)
    end
end

---Only the presets the survey saw on this node, rather than the full preset map.
---@return string[]
function bakedDestruction:getPresetNames()
    return destructionData.bakedPresets
end

---@return boolean
function bakedDestruction:hasMeshDefaults()
    return destructionData.hasBakedDefaults(self.spawnData)
end

---Applies the settings the game most commonly uses with the current mesh.
---@param silent boolean? Suppresses the toast, used when placing a new asset.
---@return boolean applied
function bakedDestruction:applyMeshDefaults(silent)
    local defaults = destructionData.getBakedDefaults(self.spawnData)
    if not defaults then
        return false
    end

    self.numFrames = tonumber(defaults.numFrames) or self.numFrames

    self.filterPreset = utils.enumIndex(self:getPresetNames(), defaults["filterData.preset"], self.filterPreset)
    self.occluderType = utils.enumIndex(self.occluderTypes, defaults.occluderType, self.occluderType)
    self.castLocalShadows = utils.enumIndex(self.shadowCastingModeEnum, defaults.castLocalShadows, self.castLocalShadows)

    if defaults.playOnlyOnce ~= nil then
        self.playOnlyOnce = utils.toBoolean(defaults.playOnlyOnce)
    end
    if defaults.restartOnTrigger ~= nil then
        self.restartOnTrigger = utils.toBoolean(defaults.restartOnTrigger)
    end
    if defaults.disableCollidersOnTrigger ~= nil then
        self.disableCollidersOnTrigger = utils.toBoolean(defaults.disableCollidersOnTrigger)
    end

    self.meshFractured = utils.trimString(defaults.meshFractured or "")
    self.meshFracturedAppearance = utils.trimString(defaults.meshFracturedAppearance or "None")
    if self.meshFracturedAppearance == "" then
        self.meshFracturedAppearance = "None"
    end

    self.destructionEffect = utils.trimString(defaults.destructionEffect or "")

    self.audioMetadata = utils.trimString(defaults.audioMetadata or "None")
    if self.audioMetadata == "" then
        self.audioMetadata = "None"
    end

    self:reportMeshDefaultsApplied(silent)

    return true
end

function bakedDestruction:onAssemble(entity)
    spawnable.onAssemble(self, entity)

    -- The runtime component is entBakedDestructionComponent, which derives from
    -- entPhysicalMeshComponent. Nothing plays the baked animation in-editor, so the intact
    -- body renders identically through the physical mesh component used elsewhere.
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
        -- The node itself is static until triggered, so the preview body is kinematic.
        component.simulationType = Enum.new("physicsSimulationType", 2)

        self:applyFilterData(component, self:getPresetName())
    end

    entity:AddComponent(component)

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    destructionMesh.assetPreviewAssemble(self, entity)
end

function bakedDestruction:save()
    local data = destructionMesh.save(self)

    data.meshFractured = self.meshFractured
    data.meshFracturedAppearance = self.meshFracturedAppearance
    data.numFrames = self.numFrames
    data.playOnlyOnce = self.playOnlyOnce
    data.restartOnTrigger = self.restartOnTrigger
    data.disableCollidersOnTrigger = self.disableCollidersOnTrigger

    data.filterPreset = self.filterPreset
    data.destructionEffect = self.destructionEffect
    data.audioMetadata = self.audioMetadata
    data.damageThreshold = self.damageThreshold
    data.damageEndurance = self.damageEndurance
    data.forceAutoHideDistance = self.forceAutoHideDistance

    return data
end

function bakedDestruction:draw()
    local calculateMaxWidth = not self.maxPropertyWidth

    destructionMesh.draw(self)

    if calculateMaxWidth then
        self.maxPropertyWidth = math.max(self.maxPropertyWidth, utils.getTextMaxWidth({
            "Auto Hide Distance", "Disable Colliders On Trigger", "Fractured Appearance",
            "Destruction Effect", "Collision Preset", "Audio Metadata", "Animation Frames"
        }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX())
    end

    local changed

    style.mutedText("Auto Hide Distance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.forceAutoHideDistance = style.trackedDragFloat(self.object, "##forceAutoHideDistance", self.forceAutoHideDistance, 0.1, 0, 1000, "%.1f")
    style.tooltip("Distance at which the mesh stops rendering. 0 lets the game decide.\nThe base game computes this per placement, so it is not filled in from the survey.")

    -- Everything from here down is baked destruction specific and gets pre-filled from the
    -- per mesh survey, so it is explained once instead of in every tooltip.
    self:drawMeshDefaultsNote()

    local previousFractured = self.meshFractured
    self.meshFractured = self:drawResourceSelector(
        "Fractured Mesh",
        "##meshFractured",
        self.meshFractured,
        "meshFracturedSearch",
        destructionData.getFracturedMeshOptions(),
        "Search or type a path...",
        "Pre-fractured mesh swapped in when the destruction triggers. Leave empty to keep the intact mesh, which is what the game does for 71% of these nodes.\nThe list holds the fractured meshes the game uses, any other .mesh path can be typed in."
    )
    self:updateFull(self.meshFractured ~= previousFractured)

    local _, ambiguous = destructionData.getFracturedMesh(self.spawnData)
    if ambiguous and self.meshFractured ~= "" then
        style.styledTextWrapped("The base game pairs this mesh with several different fractured meshes, so the one filled in above is only the most common choice.", style.mutedColor)
    end

    style.mutedText("Fractured Appearance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.meshFracturedAppearance = style.trackedTextField(self.object, "##meshFracturedAppearance", self.meshFracturedAppearance, "None", 220)
    style.tooltip("Appearance used on the fractured mesh. \"None\" keeps its default, which is what the game uses for 96% of these nodes.")

    style.mutedText("Animation Frames")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.numFrames = style.trackedDragFloat(self.object, "##numFrames", self.numFrames, 1, 1, 1000, "%.0f")
    style.tooltip("Length of the baked destruction animation, in frames. Played back at 24 fps, which the game never changes.\nThis has to match what the mesh was baked with; the survey value is the one to use.")

    self:drawPresetSelector(
        "Collision behaviour. The game uses Debris for the meshes that fracture in place and Destructible for the ones that swap to a fractured mesh.",
        200
    )

    self.destructionEffect = self:drawResourceSelector(
        "Destruction Effect",
        "##destructionEffect",
        self.destructionEffect,
        "destructionEffectSearch",
        destructionData.getAllEffects(),
        "Search or type a path...",
        "Effect played when the destruction triggers. Not previewed.\nEvery .effect in the game is listed, and any other path can be typed in."
    )

    self.audioMetadata = self:drawResourceSelector(
        "Audio Metadata",
        "##audioMetadata",
        self.audioMetadata,
        "audioMetadataSearch",
        destructionData.getAllAudioMetadata(),
        "Search or type a name...",
        "Sound set played when the destruction triggers. Not previewed.\nThe list holds every set seen on a destruction node, and any other name can be typed in."
    )

    self.advancedHeaderState = ImGui.TreeNodeEx("Advanced")

    if self.advancedHeaderState then
        style.mutedText("Play Only Once")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.playOnlyOnce = style.trackedCheckbox(self.object, "##playOnlyOnce", self.playOnlyOnce)
        style.tooltip("Plays the animation a single time and leaves the mesh in its final state.")

        style.mutedText("Restart On Trigger")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.restartOnTrigger = style.trackedCheckbox(self.object, "##restartOnTrigger", self.restartOnTrigger)
        style.tooltip("Starts the animation over when triggered again instead of ignoring the second trigger.")

        style.mutedText("Disable Colliders On Trigger")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.disableCollidersOnTrigger = style.trackedCheckbox(self.object, "##disableCollidersOnTrigger", self.disableCollidersOnTrigger)
        style.tooltip("Drops the collision as soon as the animation starts, so nothing collides with a mesh that is visually falling apart.")

        style.mutedText("Damage Threshold")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.damageThreshold = style.trackedDragFloat(self.object, "##damageThreshold", self.damageThreshold, 0.1, 0, 10000, "%.2f")
        style.tooltip("Damage below this is ignored entirely. The game uses 10 for 99% of these nodes.")

        style.mutedText("Damage Endurance")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.damageEndurance = style.trackedDragFloat(self.object, "##damageEndurance", self.damageEndurance, 0.1, 0, 10000, "%.2f")
        style.tooltip("How much damage the mesh takes before the animation triggers. The game uses 20 for 99% of these nodes.")

        ImGui.TreePop()
    end

    self:drawConversionSelector("##bakedDestructionConverterType", "Lossy Conversion##bakedDestructionSingle")
end

function bakedDestruction:export()
    local data = destructionMesh.export(self)
    data.type = "worldBakedDestructionNode"

    data.data.forceAutoHideDistance = self.forceAutoHideDistance
    data.data.numFrames = self.numFrames
    data.data.playOnlyOnce = self.playOnlyOnce and 1 or 0
    data.data.restartOnTrigger = self.restartOnTrigger and 1 or 0
    data.data.disableCollidersOnTrigger = self.disableCollidersOnTrigger and 1 or 0
    data.data.damageThreshold = self.damageThreshold
    data.data.damageEndurance = self.damageEndurance

    data.data.meshFracturedAppearance = redExport.cName(self.meshFracturedAppearance)
    data.data.audioMetadata = redExport.cName(self.audioMetadata)

    utils.combineHashTable(data.data, constantExport)

    data.data.filterData = redExport.filterData(self:getPresetName(), self:getMasks())

    if self.meshFractured ~= "" then
        data.data.meshFractured = redExport.resourceRef(self.meshFractured)
    end
    if self.destructionEffect ~= "" then
        data.data.destructionEffect = redExport.resourceRef(self.destructionEffect)
    end

    -- useMeshNavmeshSettings is always on, so navigationSetting is never read. It is still
    -- written with the value the game uses, to keep the node consistent when inspected.
    data.data.navigationSetting = redExport.navigationSetting("Blocking")

    return data
end

return bakedDestruction
