local config = require("modules/utils/config")

---@class settingsData
---@field public spawnPos integer
---@field public spawnDist number
---@field public posSteps number
---@field public precisionMultiplier number
---@field public coarsePrecisionMultiplier number
---@field public rotSteps number
---@field public rotationShiftClickStep number
---@field public applyRotationWhenDropped boolean Default "Apply Rotation When Dropped" state for newly created elements.
---@field public despawnOnReload boolean
---@field public deleteConfirm boolean
---@field public moveCloneToParent integer
---@field public spawnUIOnlyNames boolean
---@field public spawnUIHierarchyTree boolean
---@field public colliderColor integer
---@field public selectedType string
---@field public lastVariants table
---@field public spawnUIFilter string
---@field public savedUIFilter string
---@field public windowStates table
---@field public editorBottomSize integer
---@field public gizmoOnHover boolean
---@field public gizmoOnSelected boolean
---@field public arrowScaleWithDistance boolean
---@field public arrowSizeMultiplier number
---@field public outlineSelected boolean
---@field public selectedVisualizersEnabled boolean
---@field public outlineColor integer
---@field public editorWidth integer
---@field public mainWindowWidth integer
---@field public mainWindowHeight integer
---@field public resetSpawnPopupSearch boolean
---@field public spawnAtCursor boolean
---@field public defaultAISpotNPC string
---@field public defaultAISpotAppearance string
---@field public defaultAISpotSpeed number
---@field public defaultSplineCurveQuality number
---@field public nodeRefPrefix string
---@field public cacheExclusions table
---@field public assetPreviewEnabled table
---@field public prefabsAssetPreviewEnabled boolean Master switch for hover previews in the Prefabs sub-tab.
---@field public prefabPreviewMaxAssets number
---@field public spawnNewVisualizerEnabledByModule table<string, boolean>
---@field public filterTags table
---@field public favoritesFilter string
---@field public favoritesTagsAND boolean
---@field public favoritesGroupingState table
---@field public assetFavoritesFilter string
---@field public assetFavoritesFilterTags table
---@field public assetFavoritesTagsAND boolean
---@field public assetFavoritesGroupOpen table
---@field public mainWindowName string
---@field public draggingThreshold number
---@field public ignoreHiddenDuringExport boolean
---@field public cameraMovementSpeed number
---@field public cameraRotateSpeed number
---@field public cameraZoomSpeed number
---@field public setLoadedGroupAsSpawnNew boolean
---@field public groupLoadSpeedPreset integer
---@field public exportGroupsHeight number
---@field public exportTemplatesHeight number
---@field public skipLossyConversionWarning boolean
---@field public skipTemplateDeleteConfirm boolean
---@field public editorDockLeft boolean
---@field public groupWireframeEnabled boolean
---@field public wireframeColorStyle integer
---@field public spawnedUIPerfEnabled boolean
---@field public spawnedUIPerfShowPanel boolean
---@field public colorPickerStyle integer
---@field public rhtAddonReplacerMode string
---@field public rhtAddonMeshTargetType string
---@field public previewTimelineDockBottom boolean
---@field public previewTimelineDockHeight number
---@field public previewTimelineZoom number
---@field public previewTimelineSnapEnabled boolean
---@field public previewTimelineSnapSec number
---@field public actionLabelDisplayMode integer
---@field public stickyRowsEnabled boolean
---@field public speedUnit integer
---@field public speedTimelineDockBottom boolean
---@field public speedTimelineDockHeight number
---@field public speedTimelineZoom number
---@field public speedTimelineSnapEnabled boolean
---@field public speedTimelineSnapMeters number
---@field public defaultColliderMaterial integer
---@field public defaultGroupProject table? Default project tag ({name, icon, color}) assigned to new groups, or nil for none.
---@field public defaultStreamingPreset integer Default streaming distance preset index (0 = Interior) for new spawnables.
---@field public defaultExportFormat integer Default export XL format (0 = JSON, 1 = YAML).
---@field public previewBindings table<string, string> ImGuiKey names bound to the asset preview controls, keyed by action id. Empty until first resolved from the game language.
local settingsData = {
    spawnPos = 1,
    spawnDist = 4,
    posSteps = 0.002,
    precisionMultiplier = 0.2,
    coarsePrecisionMultiplier = 5,
    rotSteps = 0.050,
    rotationShiftClickStep = 90,
    applyRotationWhenDropped = true,
    despawnOnReload = true,
    deleteConfirm = true,
    moveCloneToParent = 2,
    spawnUIOnlyNames = false,
    spawnUIHierarchyTree = false,
    colliderColor = 0,
    selectedType = "Entity",
    lastVariants = { Entity = "Template", Lighting = "Static Light", Mesh = "Mesh", Collision = "Collision Shape", ["Deco"] = "Particles", ["Meta"] = "Occluder", ["Area"] = "Outline Marker", ["AI"] = "AI Spot" },
    spawnUIFilter = "",
    savedUIFilter = "",
    windowStates = {},
    editorBottomSize = 200,
    gizmoOnHover = true,
    gizmoOnSelected = true,
    arrowScaleWithDistance = true,
    arrowSizeMultiplier = 1.0,
    outlineSelected = true,
    selectedVisualizersEnabled = true,
    outlineColor = 0,
    editorWidth = 0,
    mainWindowWidth = 0,
    mainWindowHeight = 0,
    resetSpawnPopupSearch = true,
    spawnAtCursor = true,
    defaultAISpotNPC = "Character.Judy",
    defaultAISpotAppearance = "default",
    defaultAISpotSpeed = 3,
    defaultSplineCurveQuality = 12,
    nodeRefPrefix = "mod",
    cacheExclusions = {},
    assetPreviewEnabled = {},
    prefabsAssetPreviewEnabled = true,
    prefabPreviewMaxAssets = 300,
    spawnNewVisualizerEnabledByModule = {},
    mainWindowName = "World Builder",
    draggingThreshold = 5,
    ignoreHiddenDuringExport = false,
    cameraMovementSpeed = 4,
    cameraRotateSpeed = 0.4,
    cameraZoomSpeed = 2.75,
    setLoadedGroupAsSpawnNew = false,
    groupLoadSpeedPreset = 1,
    exportGroupsHeight = 260,
    exportTemplatesHeight = 160,
    skipLossyConversionWarning = false,
    skipTemplateDeleteConfirm = false,
    editorDockLeft = false,
    groupWireframeEnabled = false,
    wireframeColorStyle = 1,
    spawnedUIPerfEnabled = false,
    spawnedUIPerfShowPanel = false,
    colorPickerStyle = 2,
    rhtAddonReplacerMode = "clone",
    rhtAddonMeshTargetType = "Auto",
    previewTimelineDockBottom = false,
    previewTimelineDockHeight = 320,
    previewTimelineZoom = 90,
    previewTimelineSnapEnabled = true,
    previewTimelineSnapSec = 0.1,
    actionLabelDisplayMode = 2,
    stickyRowsEnabled = true,
    speedUnit = 1,
    speedTimelineDockBottom = false,
    speedTimelineDockHeight = 300,
    speedTimelineZoom = 12, -- pixels per meter
    speedTimelineSnapEnabled = true,
    speedTimelineSnapMeters = 0.5,

    filterTags = {},
    favoritesFilter = "",
    favoritesTagsAND = false,
    favoritesGroupingState = {},

    assetFavoritesFilter = "",
    assetFavoritesFilterTags = {},
    assetFavoritesTagsAND = false,
    assetFavoritesGroupOpen = {},

    defaultColliderMaterial = 12,
    -- defaultGroupProject is intentionally omitted (nil) so "none" is the default.
    defaultStreamingPreset = 0, -- Interior
    defaultExportFormat = 0, -- JSON

    -- Resolved from the game language on first use, see previewControls.getBindings
    previewBindings = {},
}

local settingsFNs = {}

function settingsFNs.load()
    config.tryCreateConfig("data/config.json", settingsData)

    local data = config.loadFile("data/config.json")
    if data.gizmoOnHover == nil and data.gizmoActive ~= nil then
        data.gizmoOnHover = data.gizmoActive
        data.gizmoActive = nil
        config.saveFile("data/config.json", data)
    end

    if data.cacheExlusions ~= nil then
        local hasNewValue = type(data.cacheExclusions) == "table" and next(data.cacheExclusions) ~= nil
        if not hasNewValue then
            data.cacheExclusions = data.cacheExlusions
        end

        data.cacheExlusions = nil
        config.saveFile("data/config.json", data)
    end

    data.tabSizes = nil
    settingsData.tabSizes = nil

    config.backwardComp("data/config.json", settingsData)

    data = config.loadFile("data/config.json")
    data.tabSizes = nil
    data.headerState = nil
    for k, v in pairs(data) do
        settingsData[k] = v
    end
end

function settingsFNs.save()
    config.saveFile("data/config.json", settingsData)
end

local settings = {
    load = settingsFNs.load,
    save = settingsFNs.save
}

settings = setmetatable(settings, {
    __index = settingsData,
    __newindex = settingsData
})

return settings
