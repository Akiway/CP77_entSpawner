local config = require("modules/utils/config")

---@class settingsData
---@field public spawnPos integer
---@field public spawnDist number
---@field public posSteps number
---@field public precisionMultiplier number
---@field public coarsePrecisionMultiplier number
---@field public rotSteps number
---@field public rotationShiftClickStep number
---@field public despawnOnReload boolean
---@field public headerState boolean
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
---@field public outlineSelected boolean
---@field public selectedVisualizersEnabled boolean
---@field public outlineColor integer
---@field public editorWidth integer
---@field public resetSpawnPopupSearch boolean
---@field public spawnAtCursor boolean
---@field public defaultAISpotNPC string
---@field public defaultAISpotAppearance string
---@field public tabSizes table
---@field public defaultAISpotSpeed number
---@field public defaultSplineCurveQuality number
---@field public nodeRefPrefix string
---@field public cacheExclusions table
---@field public assetPreviewEnabled table
---@field public spawnNewVisualizerEnabledByModule table<string, boolean>
---@field public filterTags table
---@field public favoritesFilter string
---@field public favoritesTagsAND boolean
---@field public favoritesGroupingState table
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
local settingsData = {
    spawnPos = 1,
    spawnDist = 4,
    posSteps = 0.002,
    precisionMultiplier = 0.2,
    coarsePrecisionMultiplier = 5,
    rotSteps = 0.050,
    rotationShiftClickStep = 90,
    despawnOnReload = true,
    headerState = true,
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
    outlineSelected = true,
    selectedVisualizersEnabled = true,
    outlineColor = 0,
    editorWidth = 0,
    resetSpawnPopupSearch = true,
    spawnAtCursor = true,
    defaultAISpotNPC = "Character.Judy",
    defaultAISpotAppearance = "default",
    defaultAISpotSpeed = 3,
    defaultSplineCurveQuality = 12,
    nodeRefPrefix = "mod",
    cacheExclusions = {},
    assetPreviewEnabled = {},
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

    filterTags = {},
    favoritesFilter = "",
    favoritesTagsAND = false,
    favoritesGroupingState = {},
    defaultColliderMaterial = 12,

    tabSizes = {}
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

    config.backwardComp("data/config.json", settingsData)

    data = config.loadFile("data/config.json")
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
