local mesh = require("modules/classes/spawn/mesh/mesh")
local spawnable = require("modules/classes/spawn/spawnable")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
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
---@class bakedDestruction : mesh
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
---@field private advancedHeaderState boolean
local bakedDestruction = setmetatable({}, { __index = mesh })

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

---RED-JSON payload for a `raRef` resource reference.
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

function bakedDestruction:new()
	local o = mesh.new(self)

    o.dataType = "Baked Destruction Mesh"
    o.modulePath = "physics/bakedDestruction"
    o.spawnDataPath = "data/spawnables/mesh/bakedDestruction/"
    o.node = "worldBakedDestructionNode"
    o.description = "Places a mesh that breaks by playing a baked destruction animation, rather than simulating it. Optionally swaps to a pre-fractured mesh when triggered."
    o.previewNote = "The intact mesh is previewed. The destruction animation and the fractured mesh are not played in-editor."
    o.icon = IconGlyphs.CubeOffOutline

    o.hideGenerate = true

    o.meshFractured = ""
    o.meshFracturedAppearance = "None"
    o.numFrames = 50
    o.playOnlyOnce = true
    o.restartOnTrigger = false
    o.disableCollidersOnTrigger = true

    o.filterPreset = 0
    o.destructionEffect = ""
    o.audioMetadata = "None"
    o.damageThreshold = 10
    o.damageEndurance = 20
    o.forceAutoHideDistance = 150

    o.filterPresetSearch = ""
    o.destructionEffectSearch = ""
    o.audioMetadataSearch = ""
    o.meshFracturedSearch = ""

    o.advancedHeaderState = false
    o.convertTarget = 0

    setmetatable(o, { __index = self })
   	return o
end

function bakedDestruction:loadSpawnData(data, position, rotation)
    mesh.loadSpawnData(self, data, position, rotation)

    -- `dataType` is serialized and copied straight back by spawnable:loadSpawnData, so it is
    -- re-asserted here; otherwise objects saved under an older name keep displaying it.
    self.dataType = "Baked Destruction Mesh"

    -- A freshly placed asset (or one converted from another mesh type) carries no baked
    -- destruction settings yet, so it starts from how the game uses that mesh.
    if data.numFrames == nil then
        self:applyMeshDefaults(true)
    end
end

---@private
---@return string
function bakedDestruction:getPresetName()
    local names = destructionData.bakedPresets
    return names[self.filterPreset + 1] or names[1] or destructionData.fallbackBakedPreset
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

    if defaults["filterData.preset"] then
        local index = utils.indexValue(destructionData.bakedPresets, defaults["filterData.preset"])
        if index > 0 then
            self.filterPreset = index - 1
        end
    end

    if defaults.playOnlyOnce ~= nil then
        self.playOnlyOnce = toBoolean(defaults.playOnlyOnce)
    end
    if defaults.restartOnTrigger ~= nil then
        self.restartOnTrigger = toBoolean(defaults.restartOnTrigger)
    end
    if defaults.disableCollidersOnTrigger ~= nil then
        self.disableCollidersOnTrigger = toBoolean(defaults.disableCollidersOnTrigger)
    end

    if defaults.occluderType then
        local index = utils.indexValue(self.occluderTypes, defaults.occluderType)
        if index > 0 then
            self.occluderType = index - 1
        end
    end
    if defaults.castLocalShadows then
        local index = utils.indexValue(self.shadowCastingModeEnum, defaults.castLocalShadows)
        if index > 0 then
            self.castLocalShadows = index - 1
        end
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

    if not silent then
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Applied game defaults for this mesh"))
    end

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
        local preset = self:getPresetName()
        local masks = destructionData.getPresetMasks(preset)

        -- The node itself is static until triggered, so the preview body is kinematic.
        component.simulationType = Enum.new("physicsSimulationType", 2)

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

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    mesh.assetPreviewAssemble(self, entity)
end

function bakedDestruction:save()
    local data = mesh.save(self)

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

---Respawns the preview after changing a property that is only applied on assemble.
---@protected
---@param changed boolean
function bakedDestruction:updateFull(changed)
    if changed and self:isSpawned() then self:respawn() end
end

---Explains where the baked destruction settings come from, and offers to restore them.
---@private
function bakedDestruction:drawMeshDefaultsNote()
    local hasDefaults = destructionData.hasBakedDefaults(self.spawnData)

    ImGui.Dummy(0, 8 * style.viewSize)

    if hasDefaults then
        style.styledTextWrapped("The settings below were filled in from how the base game places this mesh.", style.mutedColor)
    else
        style.styledTextWrapped("The base game never places this mesh as baked destruction, so the settings below start from generic defaults. A mesh needs a baked destruction animation for this node to do anything.", style.mutedColor)
    end

    style.pushGreyedOut(not hasDefaults)
    if ImGui.Button("Reset to game defaults##bakedDestructionDefaults") and hasDefaults then
        history.addAction(history.getElementChange(self.object))
        self:applyMeshDefaults(false)
        self:updateFull(true)
    end
    style.popGreyedOut(not hasDefaults)

    if hasDefaults then
        style.tooltip("Restores the settings the base game uses for this mesh, including its fractured mesh.")
    else
        style.tooltip("No recorded usage for this mesh, nothing to restore.", ImGuiHoveredFlags.AllowWhenDisabled)
    end

    ImGui.Dummy(0, 4 * style.viewSize)
    ImGui.Spacing()
end

---Draws one resource row backed by a surveyed list, allowing any typed path.
---@private
---@param label string
---@param id string
---@param value string
---@param searchKey string
---@param options string[]
---@param hint string
---@param tooltip string
---@return string
function bakedDestruction:drawResourceSelector(label, id, value, searchKey, options, hint, tooltip)
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
            -- The listed values are the ones the game itself uses, but anything can be
            -- typed in, including resources added by mods.
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

function bakedDestruction:draw()
    local calculateMaxWidth = not self.maxPropertyWidth

    mesh.draw(self)

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

    style.mutedText("Collision Preset")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local presetNames = destructionData.bakedPresets
    self.filterPreset = math.max(0, math.min(self.filterPreset, #presetNames - 1))
    local selectedPreset = presetNames[self.filterPreset + 1] or destructionData.fallbackBakedPreset
    local presetChanged
    selectedPreset, self.filterPresetSearch, presetChanged = style.trackedSearchDropdown(
        "##filterPreset",
        "Search preset...",
        selectedPreset,
        self.filterPresetSearch or "",
        presetNames,
        {
            element = self.object,
            width = 200,
            matchContentWidth = true,
            tooltip = "Collision behaviour. The game uses Debris for the meshes that fracture in place and Destructible for the ones that swap to a fractured mesh."
        }
    )
    if presetChanged then
        self.filterPreset = math.max(utils.indexValue(presetNames, selectedPreset) - 1, 0)
        self:updateFull(true)
    end

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
    local masks = destructionData.getPresetMasks(self:getPresetName())

    local data = mesh.export(self)
    data.type = "worldBakedDestructionNode"

    data.data.forceAutoHideDistance = self.forceAutoHideDistance
    data.data.numFrames = self.numFrames
    data.data.playOnlyOnce = self.playOnlyOnce and 1 or 0
    data.data.restartOnTrigger = self.restartOnTrigger and 1 or 0
    data.data.disableCollidersOnTrigger = self.disableCollidersOnTrigger and 1 or 0
    data.data.damageThreshold = self.damageThreshold
    data.data.damageEndurance = self.damageEndurance

    data.data.meshFracturedAppearance = {
        ["$type"] = "CName",
        ["$storage"] = "string",
        ["$value"] = self.meshFracturedAppearance == "" and "None" or self.meshFracturedAppearance
    }
    data.data.audioMetadata = {
        ["$type"] = "CName",
        ["$storage"] = "string",
        ["$value"] = self.audioMetadata == "" and "None" or self.audioMetadata
    }

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

    if self.meshFractured ~= "" then
        data.data.meshFractured = exportResourceRef(self.meshFractured)
    end
    if self.destructionEffect ~= "" then
        data.data.destructionEffect = exportResourceRef(self.destructionEffect)
    end

    -- useMeshNavmeshSettings is always on, so navigationSetting is never read. It is still
    -- written with the value the game uses, to keep the node consistent when inspected.
    data.data.navigationSetting = {
        ["$type"] = "NavGenNavigationSetting",
        ["navmeshImpact"] = "Blocking"
    }

    return data
end

return bakedDestruction
