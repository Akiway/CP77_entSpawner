local config = require("modules/utils/config")
local utils = require("modules/utils/utils")
local style = require("modules/ui/style")
local settings = require("modules/utils/settings")
local amm = require("modules/utils/ammUtils")
local history = require("modules/utils/history")
local editor = require("modules/utils/editor/editor")
local Cron = require("modules/utils/Cron")
local groupLoadManager = require("modules/utils/pipeline/groupLoadManager")
local entity = require("modules/classes/spawn/entity/entity")
local entityRecordClass = require("modules/classes/spawn/entity/entityRecord")

local types = {
    ["Entity"] = {
        variants = {
            ["Template"] = { class = require("modules/classes/spawn/entity/entityTemplate"), index = 1},
            ["Template (AMM)"] = { class = require("modules/classes/spawn/entity/ammEntity"), index = 2},
            ["Record"] = { class = entityRecordClass, index = 3},
            ["Device"] = { class = require("modules/classes/spawn/entity/device"), index = 4}
        },
        index = 1
    },
    ["Lighting"] = {
        variants = {
            ["Static Light"] = { class = require("modules/classes/spawn/light/light"), index = 1 },
            ["Reflection Probe"] = { class = require("modules/classes/spawn/meta/reflectionProbe"), index = 2 },
            ["Light Channel Area"] = { class = require("modules/classes/spawn/light/lightChannelArea"), index = 3 },
            ["Fog Volume"] = { class = require("modules/classes/spawn/visual/fog"), index = 4 }
        },
        index = 3
    },
    ["Mesh"] = {
        variants = {
            ["Mesh"] = { class = require("modules/classes/spawn/mesh/mesh"), index = 1 },
            ["Rotating Mesh"] = { class = require("modules/classes/spawn/mesh/rotatingMesh"), index = 2 },
            ["Cloth Mesh"] = { class = require("modules/classes/spawn/mesh/clothMesh"), index = 3 },
            ["Dynamic Mesh"] = { class = require("modules/classes/spawn/physics/dynamicMesh"), index = 4 },
            ["Bended Mesh"] = { class = require("modules/classes/spawn/mesh/bendedMesh"), index = 5 },
            ["Proxy Mesh"] = { class = require("modules/classes/spawn/mesh/proxyMesh"), index = 6 }
        },
        index = 2
    },
    ["Collision"] = {
        variants = {
            ["Collision Shape"] = { class = require("modules/classes/spawn/collision/collider"), index = 1 },
            ["Collision Mesh"] = { class = require("modules/classes/spawn/collision/meshCollider"), index = 2 }
        },
        index = 5
    },
    ["Deco"] = {
        variants = {
            ["Particles"] = { class = require("modules/classes/spawn/visual/particle"), index = 2 },
            ["Decals"] = { class = require("modules/classes/spawn/visual/decal"), index = 1 },
            ["Effects"] = { class = require("modules/classes/spawn/visual/effect"), index = 3 },
            ["Static Audio Emitter"] = { class = require("modules/classes/spawn/visual/audio"), index = 4 },
            ["Water Patch"] = { class = require("modules/classes/spawn/visual/waterPatch"), index = 5 }
        },
        index = 4
    },
    ["Meta"] = {
        variants = {
            ["Occluder"] = { class = require("modules/classes/spawn/meta/occluder"), index = 1 },
            ["Static Marker"] = { class = require("modules/classes/spawn/meta/staticMarker"), index = 3 },
            ["Spline Point"] = { class = require("modules/classes/spawn/meta/splineMarker"), index = 4 },
            ["Spline"] = { class = require("modules/classes/spawn/meta/spline"), index = 5 }
        },
        index = 6
    },
    ["Area"] = {
        variants = {
            ["Outline Marker"] = { class = require("modules/classes/spawn/area/outlineMarker"), index = 1 },
            ["Trigger Area"] = { class = require("modules/classes/spawn/area/triggerArea"), index = 2 },
            ["Ambient Area"] = { class = require("modules/classes/spawn/area/ambientArea"), index = 3 },
            ["Kill Area"] = { class = require("modules/classes/spawn/area/killArea"), index = 4 },
            ["Prevention Free"] = { class = require("modules/classes/spawn/area/preventionFree"), index = 5 },
            ["Water Null"] = { class = require("modules/classes/spawn/area/waterNull"), index = 6 },
            ["Conversation Area"] = { class = require("modules/classes/spawn/area/conversationArea"), index = 7 },
            ["Crowd Null Area"] = { class = require("modules/classes/spawn/area/crowdNull"), index = 8 },
            ["Dummy Area"] = { class = require("modules/classes/spawn/area/dummyArea"), index = 9 },
            ["World Boundary"] = { class = require("modules/classes/spawn/area/worldBoundary"), index = 10 }
        },
        index = 7
    },
    ["AI"] = {
        variants = {
            ["AI Spot"] = { class = require("modules/classes/spawn/ai/aiSpot"), index = 1 },
            ["Community"] = { class = require("modules/classes/spawn/ai/communityArea"), index = 2 }
        },
        index = 8
    }
}

local spawnData = {}
local typeNames = {}
local variantNames = {}
local modulePathToSpawnList = {}
local spawnNewVisualizerClassGroups = {}
local spawnNewVisualizerModuleSet = {}
local reflectionProbeModulePath = "meta/reflectionProbe"
local reflectionProbeDefaultLabel = "Reflection Probe - Default"

local AMM = nil

---@class spawnUI
---@field filter string
---@field selectedGroup number
---@field selectedType number
---@field selectedVariant number
---@field spawnedUI? spawnedUI
---@field spawner? spawner
---@field filteredList table
---@field openPopup boolean
---@field popupFilter string
---@field currentPopupVariant string
---@field popupSpawnHit table?
---@field popupData table
---@field dragging boolean
---@field dragData table?
---@field lastSpawnedClass table?
---@field lastSpawnedEntry table?
---@field lastSpawnedIsFavorite boolean
---@field lastSpawnedOptions table?
---@field previewInstance spawnable?
---@field previewTimer number?
---@field hoveredEntry table?
---@field assetPreviewActive boolean
---@field lightSuppressionTargetsCache table?
---@field lightSuppressionTargetsCacheEpoch number
---@field activeLightSuppressionStates table
---@field flashlightSuppressionComponent IComponent?
---@field flashlightSuppressionCaptured boolean
---@field flashlightSuppressionPreviousOverride number?
---@field deviceClassFilterSelectionsByModule table<string, table<string, boolean>>
---@field deviceClassFilterSearchByModule table<string, string>
---@field recordTypeFilterSelectionsByModule table<string, table<string, boolean>>
---@field recordTypeFilterSearchByModule table<string, string>
---@field pathOriginFilterSelectionsByModule table<string, table<string, boolean>>
---@field filteredHierarchyTree table?
---@field hierarchyOpenStateByKey table<string, boolean>
---@field favoritesUI favoritesUI
spawnUI = {
    filter = "",
    popupFilter = "",
    selectedGroup = 0,
    selectedType = 0,
    selectedVariant = 0,
    spawnedUI = nil,
    spawner = nil,
    filteredList = {},
    openPopup = false,
    currentPopupVariant = "",
    popupData = {},
    popupSpawnHit = nil,
    dragging = false,
    dragData = nil,
    lastSpawnedClass = nil,
    lastSpawnedEntry = nil,
    lastSpawnedIsFavorite = false,
    lastSpawnedOptions = nil,
    previewInstance = nil,
    previewTimer = nil,
    hoveredEntry = nil,
    assetPreviewActive = false,
    lightSuppressionTargetsCache = nil,
    lightSuppressionTargetsCacheEpoch = -1,
    activeLightSuppressionStates = {},
    flashlightSuppressionComponent = nil,
    flashlightSuppressionCaptured = false,
    flashlightSuppressionPreviousOverride = nil,
    deviceClassFilterSelectionsByModule = {},
    deviceClassFilterSearchByModule = {},
    recordTypeFilterSelectionsByModule = {},
    recordTypeFilterSearchByModule = {},
    pathOriginFilterSelectionsByModule = {},
    filteredHierarchyTree = nil,
    hierarchyOpenStateByKey = {},
    favoritesUI = require("modules/ui/favoritesUI")
}

---@return string[]
local function getSortedTypeNames()
    local names = utils.getKeys(types)
    table.sort(names, function(a, b) return types[a].index < types[b].index end)
    return names
end

---@param typeName string
---@return string[]
local function getSortedVariantNames(typeName)
    local names = utils.getKeys(types[typeName].variants)
    table.sort(names, function(a, b) return types[typeName].variants[a].index < types[typeName].variants[b].index end)
    return names
end

---@param instance spawnable?
---@return boolean
local function supportsSpawnNewVisualizerDefault(instance)
    return instance
        and instance.previewed ~= nil
        and type(instance.setPreview) == "function"
        and type(instance.drawPreviewCheckbox) == "function"
end

local function rebuildSpawnNewVisualizerClassCatalog()
    local groups = {}
    local moduleSet = {}
    local changed = false

    if type(settings.spawnNewVisualizerEnabledByModule) ~= "table" then
        settings.spawnNewVisualizerEnabledByModule = {}
        changed = true
    end

    for _, typeName in ipairs(getSortedTypeNames()) do
        local entries = {}
        for _, variantName in ipairs(getSortedVariantNames(typeName)) do
            local variant = types[typeName].variants[variantName]
            local instance = variant and variant.class and variant.class:new() or nil

            if supportsSpawnNewVisualizerDefault(instance) then
                local defaultPreviewed = instance.previewed == true
                local modulePath = instance.modulePath

                table.insert(entries, {
                    name = variantName,
                    modulePath = modulePath,
                    defaultPreviewed = defaultPreviewed
                })
                moduleSet[modulePath] = true

                if type(settings.spawnNewVisualizerEnabledByModule[modulePath]) ~= "boolean" then
                    settings.spawnNewVisualizerEnabledByModule[modulePath] = defaultPreviewed
                    changed = true
                end
            end
        end

        if #entries > 0 then
            groups[typeName] = entries
        end
    end

    spawnNewVisualizerClassGroups = groups
    spawnNewVisualizerModuleSet = moduleSet

    if changed then
        settings.save()
    end
end

---@return table[]
function spawnUI.getVisualizerClassGroups()
    local groups = {}

    for _, typeName in ipairs(getSortedTypeNames()) do
        local entries = spawnNewVisualizerClassGroups[typeName]
        if entries and #entries > 0 then
            table.insert(groups, {
                typeName = typeName,
                entries = entries
            })
        end
    end

    return groups
end

---Replaces reflection probe path list with a single generic spawn entry.
---The concrete envprobe can be changed later in node properties.
---@param spawnList table
local function collapseReflectionProbeSpawnList(spawnList)
    if not spawnList or spawnList.modulePath ~= reflectionProbeModulePath then
        return
    end

    local defaultProbePath = ""
    for _, entry in ipairs(spawnList.data or {}) do
        local path = entry and entry.data and entry.data.spawnData or ""
        if type(path) == "string" and path ~= "" then
            defaultProbePath = path
            break
        end
    end

    spawnList.data = {
        {
            data = { spawnData = defaultProbePath },
            lastSpawned = nil,
            name = reflectionProbeDefaultLabel,
            fileName = reflectionProbeDefaultLabel
        }
    }

    -- Keep Spawn New focused on a generic item instead of path-browser behavior.
    spawnList.isPaths = false
end

---Loads the spawn data (Either list of e.g. paths, or exported object files) for each data variant
---@param spawner spawner
function spawnUI.loadSpawnData(spawner)
    typeNames = {}
    variantNames = {}
    spawnData = {}
    modulePathToSpawnList = {}
    spawnUI.deviceClassFilterSelectionsByModule = {}
    spawnUI.deviceClassFilterSearchByModule = {}
    spawnUI.recordTypeFilterSelectionsByModule = {}
    spawnUI.recordTypeFilterSearchByModule = {}
    spawnUI.pathOriginFilterSelectionsByModule = {}
    spawnUI.filteredHierarchyTree = nil
    spawnUI.hierarchyOpenStateByKey = {}

    AMM = GetMod("AppearanceMenuMod")
    spawnUI.spawnedUI = spawner.baseUI.spawnedUI
    spawnUI.spawner = spawner
    spawnUI.filter = tostring(settings.spawnUIFilter or "")

    for dataName, dataType in pairs(types) do
        spawnData[dataName] = {}

        for variantName, variant in pairs(dataType.variants) do
            local variantInstance = variant.class:new()
            local info = { node = variantInstance.node, description = variantInstance.description, previewNote = variantInstance.previewNote }
            local isPaths = variantInstance.spawnListType == "list"
            local loadSpawnDataFn = isPaths and config.loadLists or config.loadFiles
            local spawnList = {
                data = loadSpawnDataFn(variantInstance.spawnDataPath),
                class = variant.class,
                modulePath = variantInstance.modulePath,
                info = info,
                isPaths = isPaths,
                assetPreviewDelay = variantInstance.assetPreviewDelay,
                assetPreviewType = variantInstance.assetPreviewType
            }
            collapseReflectionProbeSpawnList(spawnList)
            spawnData[dataName][variantName] = spawnList
            modulePathToSpawnList[variantInstance.modulePath] = spawnList

            if settings.assetPreviewEnabled[variantInstance.modulePath] == nil then
                settings.assetPreviewEnabled[variantInstance.modulePath] = true
                settings.save()
            end
        end
    end

    rebuildSpawnNewVisualizerClassCatalog()

    typeNames = getSortedTypeNames()

    spawnUI.selectedType = math.max(utils.indexValue(typeNames, settings.selectedType) - 1, 0)

    variantNames = getSortedVariantNames(typeNames[spawnUI.selectedType + 1])

    spawnUI.selectedVariant = math.max(utils.indexValue(variantNames, settings.lastVariants[settings.selectedType]) - 1, 0)

    spawnUI.refresh()
end

---Returns a table containing the currently active spawnables list, each entry being structured as {data: String|table, name: String, lastSpawned: table}
---@return table
function spawnUI.getActiveSpawnList()
    return spawnData[typeNames[spawnUI.selectedType + 1]][variantNames[spawnUI.selectedVariant + 1]]
end

local deviceClassFilterListByModulePath = {
    ["entity/entityTemplate"] = true,
    ["entity/device"] = true
}

local recordTypeFilterListByModulePath = {
    ["entity/entityRecord"] = true
}

local pathOriginTagInfoByKey = {
    base = { label = "Base game", tag = "Base", color = 0xFF00A6B2 },
    plDlc = {
        label = "PL DLC",
        tag = "DLC",
        color = 0xFF0808A9,
        tooltip = "Phantom Liberty DLC\nUsing these assets means the player will require the DLC for your mod."
    },
    modded = {
        label = "Modded",
        tag = "Mod",
        color = 0xFFA55987,
        tooltip = "Only assets with starting path 'mod/' or 'mods/' are recognized as modded."
     }
}

local pathOriginFilterOptionOrder = {
    { key = "base", checkboxIdSuffix = "Base" },
    { key = "plDlc", checkboxIdSuffix = "PlDlc" },
    { key = "modded", checkboxIdSuffix = "Modded" }
}

---Returns whether a filter is supported by the active spawn list module.
---@param spawnList table?
---@param moduleSupportMap table<string, boolean>
---@return boolean
local function supportsFilterForModule(spawnList, moduleSupportMap)
    return spawnList ~= nil and moduleSupportMap[spawnList.modulePath] == true
end

---Resolves the effective device class name for a list entry.
---Delegates the actual source/fallback logic to entity-domain helpers.
---@param entry table
---@param spawnList table
---@return string
local function getEntryDeviceClassName(entry, spawnList)
    return entity.resolveDeviceClassNameForEntry(entry, spawnList.modulePath)
end

---Returns whether the path origin filter should be shown for the active variant.
---@param spawnList table?
---@return boolean
local function supportsPathOriginFilter(spawnList)
    return spawnList ~= nil and spawnList.isPaths == true
end

---Gets or lazily creates the per-module Content Origin checkbox state map.
---All options default to checked.
---@param spawnList table?
---@return table<string, boolean>?
local function getPathOriginFilterSelections(spawnList)
    if not supportsPathOriginFilter(spawnList) then
        return nil
    end

    local modulePath = spawnList.modulePath
    local selections = spawnUI.pathOriginFilterSelectionsByModule[modulePath]
    if not selections then
        selections = {
            base = true,
            plDlc = true,
            modded = true
        }
        spawnUI.pathOriginFilterSelectionsByModule[modulePath] = selections
    end

    return selections
end

---Gets or lazily creates the per-module multi-select state map for a filter.
---@param spawnList table?
---@param moduleSupportMap table<string, boolean>
---@param selectionsByModule table<string, table<string, boolean>>
---@return table<string, boolean>?
local function getFilterSelectionsForModule(spawnList, moduleSupportMap, selectionsByModule)
    if not supportsFilterForModule(spawnList, moduleSupportMap) then
        return nil
    end

    local modulePath = spawnList.modulePath
    local selections = selectionsByModule[modulePath]
    if not selections then
        selections = {}
        selectionsByModule[modulePath] = selections
    end

    return selections
end

---Gets the per-module search text used inside a filter popin.
---Returns an empty string when unsupported or uninitialized.
---@param spawnList table?
---@param moduleSupportMap table<string, boolean>
---@param searchByModule table<string, string>
---@return string
local function getFilterSearchForModule(spawnList, moduleSupportMap, searchByModule)
    if not supportsFilterForModule(spawnList, moduleSupportMap) then
        return ""
    end

    local modulePath = spawnList.modulePath
    local searchValue = searchByModule[modulePath]
    if type(searchValue) ~= "string" then
        searchValue = ""
        searchByModule[modulePath] = searchValue
    end

    return searchValue
end

---Sets the per-module search text used inside a filter popin.
---@param spawnList table?
---@param moduleSupportMap table<string, boolean>
---@param searchByModule table<string, string>
---@param value string
local function setFilterSearchForModule(spawnList, moduleSupportMap, searchByModule, value)
    if not supportsFilterForModule(spawnList, moduleSupportMap) then
        return
    end

    searchByModule[spawnList.modulePath] = tostring(value or "")
end

---Gets the current Device Class selection state for the active module.
---@param spawnList table?
---@return table<string, boolean>?
local function getDeviceClassFilterSelections(spawnList)
    return getFilterSelectionsForModule(
        spawnList,
        deviceClassFilterListByModulePath,
        spawnUI.deviceClassFilterSelectionsByModule
    )
end

---Gets the current Record Type selection state for the active module.
---@param spawnList table?
---@return table<string, boolean>?
local function getRecordTypeFilterSelections(spawnList)
    return getFilterSelectionsForModule(
        spawnList,
        recordTypeFilterListByModulePath,
        spawnUI.recordTypeFilterSelectionsByModule
    )
end

---Returns true when at least one option is selected in a filter map.
---@param selections table<string, boolean>?
---@return boolean
local function hasSelectedFilterOption(selections)
    if not selections then
        return false
    end

    for _, isSelected in pairs(selections) do
        if isSelected then
            return true
        end
    end

    return false
end

---Builds the selector preview label from current selection state.
---Shows "all" label when none are selected, item label for one, count label otherwise.
---@param selections table<string, boolean>?
---@param allLabel string
---@param multiLabelFormat string
---@return string
local function getFilterPreviewLabel(selections, allLabel, multiLabelFormat)
    local selectedCount = 0
    local singleSelectedKey = ""

    if selections then
        for key, isSelected in pairs(selections) do
            if isSelected then
                selectedCount = selectedCount + 1
                singleSelectedKey = key
            end
        end
    end

    if selectedCount == 0 then
        return allLabel
    end

    if selectedCount == 1 then
        return singleSelectedKey
    end

    return string.format(multiLabelFormat, selectedCount)
end

---Draws a clear-selection icon button for one multi-select filter map.
---Returns whether selection changed.
---@param selections table<string, boolean>?
---@param buttonId string
---@param tooltip string
---@param sameLine boolean?
---@return boolean changed
local function drawMultiSelectClearButton(selections, buttonId, tooltip, sameLine)
    if not hasSelectedFilterOption(selections) then
        return false
    end

    if sameLine then
        ImGui.SameLine()
    end

    style.pushButtonNoBG(true)
    local clicked = ImGui.Button(IconGlyphs.FilterRemoveOutline .. buttonId)
    style.pushButtonNoBG(false)

    if tooltip ~= "" then
        style.tooltip(tooltip)
    end

    if clicked then
        for key, _ in pairs(selections) do
            selections[key] = nil
        end
        return true
    end

    return false
end

---@param spawnList table
---@param entry table
---@return string
local function getEntrySearchName(spawnList, entry)
    if spawnList.isPaths and settings.spawnUIOnlyNames then
        return entry.fileName or entry.name or ""
    end

    return entry.name or ""
end

---@param spawnList table
---@param entry table
---@return boolean
local function matchesSearchFilter(spawnList, entry)
    if spawnUI.filter == "" then
        return true
    end

    return utils.matchSearch(getEntrySearchName(spawnList, entry), spawnUI.filter)
end

---Returns the asset path used for path-origin matching and tagging.
---@param entry table
---@param spawnList table?
---@return string
local function getEntryAssetPath(entry, spawnList)
    if not entry then
        return ""
    end

    if spawnList and spawnList.isPaths and entry.data and type(entry.data.spawnData) == "string" then
        return entry.data.spawnData
    end

    if type(entry.name) == "string" then
        return entry.name
    end

    return ""
end

---Normalizes one asset path for hierarchy splitting.
---Converts slashes to `\` and trims surrounding whitespace.
---@param path string?
---@return string
local function normalizeHierarchyAssetPath(path)
    return utils.normalizePath(path, { separator = "backslash" })
end

---Splits an asset path into non-empty hierarchy segments.
---@param path string?
---@return string[] segments
---@return string normalizedPath
local function splitHierarchyAssetPath(path)
    local normalizedPath = normalizeHierarchyAssetPath(path)
    local segments = {}

    for segment in normalizedPath:gmatch("[^\\]+") do
        if segment ~= "" then
            table.insert(segments, segment)
        end
    end

    return segments, normalizedPath
end

---Creates one hierarchy tree node used by Spawn New path-tree rendering.
---@param label string
---@param key string
---@return table
local function createHierarchyTreeNode(label, key)
    return {
        label = label,
        key = key,
        children = {},
        childOrder = {},
        entries = {}
    }
end

---Resolves a normalized path origin key from the first segment of a path.
---Supported roots: `base`, `ep1`, `mod`, `mods`.
---@param path string
---@return string?
local function getPathOriginKeyFromPath(path)
    local normalizedPath = utils.normalizePath(path, { separator = "backslash" })
    if normalizedPath == "" then
        return nil
    end

    local firstSegment = normalizedPath:match("^([^\\]+)")
    if not firstSegment then
        return nil
    end

    local segment = string.lower(firstSegment)
    if segment == "base" then
        return "base"
    end

    if segment == "ep1" then
        return "plDlc"
    end

    if segment == "mod" or segment == "mods" then
        return "modded"
    end

    return nil
end

---Gets the path origin key for one search-list entry.
---@param entry table
---@param spawnList table?
---@return string?
local function getEntryPathOriginKey(entry, spawnList)
    if not supportsPathOriginFilter(spawnList) then
        return nil
    end

    return getPathOriginKeyFromPath(getEntryAssetPath(entry, spawnList))
end

---Returns true when the content-origin filter should actively constrain results.
---@param selections table<string, boolean>?
---@return boolean
local function isPathOriginFilterEnabled(selections)
    if not selections then
        return false
    end

    return not (selections.base == true and selections.plDlc == true and selections.modded == true)
end

---Gets tag display metadata for one search-list entry origin.
---@param entry table
---@param spawnList table?
---@return table?
local function getEntryPathOriginTagInfo(entry, spawnList)
    local originKey = getEntryPathOriginKey(entry, spawnList)
    if not originKey then
        return nil
    end

    return pathOriginTagInfoByKey[originKey]
end

---Applies selector-popin search matching to an option label.
---@param optionName string
---@param filterValue string
---@return boolean
local function matchesSelectorOptionFilter(optionName, filterValue)
    local searchValue = string.lower(tostring(filterValue or ""))
    if searchValue == "" then
        return true
    end

    return utils.safePatternMatch(string.lower(tostring(optionName or "")), searchValue)
end

---Collects all currently available option keys for a filter from the active spawn list.
---@param spawnList table
---@param resolveKey fun(entry: table, spawnList: table): string
---@return table<string, boolean>
local function collectAvailableFilterKeys(spawnList, resolveKey)
    local availableKeys = {}

    for _, entry in ipairs(spawnList.data) do
        local key = tostring(resolveKey(entry, spawnList) or "")
        if key ~= "" then
            availableKeys[key] = true
        end
    end

    return availableKeys
end

---Removes selected keys that no longer exist in the available option set.
---@param selections table<string, boolean>?
---@param availableKeys table<string, boolean>
local function pruneUnavailableFilterSelections(selections, availableKeys)
    if not selections then
        return
    end

    for key, _ in pairs(selections) do
        if not availableKeys[key] then
            selections[key] = nil
        end
    end
end

---@class SpawnDeviceClassFilterOption
---@field className string
---@field icon string
---@field count number

---Builds Device Class filter options (icon + label + count) for the active list.
---@param spawnList table
---@return SpawnDeviceClassFilterOption[]
local function getDeviceClassFilterOptions(spawnList)
    local optionsByClassName = {}

    for _, entry in ipairs(spawnList.data) do
        local className = getEntryDeviceClassName(entry, spawnList)
        if className ~= "" then
            local option = optionsByClassName[className]
            if not option then
                option = {
                    className = className,
                    icon = entity.getDeviceSecondaryIcon(className),
                    count = 0
                }
                optionsByClassName[className] = option
            end

            if matchesSearchFilter(spawnList, entry) then
                option.count = option.count + 1
            end
        end
    end

    local options = {}
    for _, option in pairs(optionsByClassName) do
        if option.count > 0 then
            table.insert(options, option)
        end
    end

    table.sort(options, function(a, b)
        return string.lower(a.className) < string.lower(b.className)
    end)

    return options
end

---Extracts a record type prefix for one entry (for example `AttachableObject`).
---@param entry table
---@param _spawnList table
---@return string
local function getEntryRecordTypePrefix(entry, _spawnList)
    if not entry then
        return ""
    end

    local spawnData = entry.data and entry.data.spawnData or nil
    return entityRecordClass.getTypePrefix(spawnData)
end

---@class SpawnRecordTypeFilterOption
---@field typeName string
---@field icon string
---@field count number

---Builds Record Type filter options (icon + label + count) for the active list.
---@param spawnList table
---@return SpawnRecordTypeFilterOption[]
local function getRecordTypeFilterOptions(spawnList)
    local optionsByType = {}

    for _, entry in ipairs(spawnList.data) do
        local typeName = getEntryRecordTypePrefix(entry, spawnList)
        if typeName ~= "" then
            local option = optionsByType[typeName]
            if not option then
                option = {
                    typeName = typeName,
                    icon = IconGlyphs.AlphaRBoxOutline,
                    count = 0
                }
                optionsByType[typeName] = option
            end

            if matchesSearchFilter(spawnList, entry) then
                option.count = option.count + 1
            end
        end
    end

    local options = {}
    for _, option in pairs(optionsByType) do
        if option.count > 0 then
            table.insert(options, option)
        end
    end

    table.sort(options, function(a, b)
        return string.lower(a.typeName) < string.lower(b.typeName)
    end)

    return options
end

---Resolves the secondary icon displayed between the main icon and entry label in search results.
---Only device/template entries with a known class icon return a value.
---@param entry table
---@param spawnList table
---@return string
local function getSearchResultSecondaryIcon(entry, spawnList)
    if not entry or not spawnList then
        return ""
    end

    local className = getEntryDeviceClassName(entry, spawnList)
    if className == "" then
        return ""
    end

    return entity.getDeviceSecondaryIcon(className)
end

---Formats a search result label while reserving width for an optional secondary icon prefix.
---@param text string
---@param width number
---@param secondaryIcon string?
---@return string
local function formatSearchResultButtonText(text, width, secondaryIcon)
    local icon = tostring(secondaryIcon or "")
    if icon == "" then
        return utils.shortenPath(text, width, true)
    end

    local iconPrefix = icon .. " "
    local iconWidth, _ = ImGui.CalcTextSize(iconPrefix)
    local contentWidth = math.max(1, width - iconWidth)

    return iconPrefix .. utils.shortenPath(text, contentWidth, true)
end

local PATH_ORIGIN_TAG_TEXT_COLOR = style.regularColor

---Draws a non-clickable rounded tag chip styled like a compact button.
---@param tagInfo table?
local function drawPathOriginTagChip(tagInfo)
    if not tagInfo then
        return
    end

    local label = tostring(tagInfo.tag or "")
    if label == "" then
        return
    end

    local scale = style.viewSize or 1
    local textWidth, textHeight = ImGui.CalcTextSize(label)
    local frameHeight = ImGui.GetFrameHeight()
    local paddingX = 7 * scale
    local chipWidth = math.max(textWidth + (paddingX * 2), 34 * scale)
    local chipX, chipY = ImGui.GetCursorScreenPos()
    local drawList = ImGui.GetWindowDrawList()
    local cornerRadius = 6 * scale
    local borderSize = math.max(1, math.floor(1 * scale))
    local borderColor = 0xCC000000

    ImGui.ImDrawListAddRectFilled(
        drawList,
        chipX,
        chipY,
        chipX + chipWidth,
        chipY + frameHeight,
        borderColor,
        cornerRadius
    )

    ImGui.ImDrawListAddRectFilled(
        drawList,
        chipX + borderSize,
        chipY + borderSize,
        chipX + chipWidth - borderSize,
        chipY + frameHeight - borderSize,
        tagInfo.color,
        math.max(0, cornerRadius - borderSize)
    )

    local textX = chipX + math.floor((chipWidth - textWidth) / 2)
    local textY = chipY + math.floor((frameHeight - textHeight) / 2)
    ImGui.ImDrawListAddText(drawList, ImGui.GetFontSize(), textX, textY, PATH_ORIGIN_TAG_TEXT_COLOR, label)

    ImGui.Dummy(chipWidth, frameHeight)
end

---Persists Spawn New search text only when it actually changed.
local function saveSpawnUIFilterIfChanged()
    local nextFilter = tostring(spawnUI.filter or "")
    if settings.spawnUIFilter == nextFilter then
        return
    end

    settings.spawnUIFilter = nextFilter
    settings.save()
end

---Builds a cached hierarchy tree from current filtered path results.
---Tree folders map to path segments; leaves map to filtered spawn entries.
function spawnUI.rebuildHierarchyTree()
    local activeSpawnList = spawnUI.getActiveSpawnList()
    if not activeSpawnList or not activeSpawnList.isPaths then
        spawnUI.filteredHierarchyTree = nil
        return
    end

    local root = createHierarchyTreeNode("", "__root__:" .. tostring(activeSpawnList.modulePath or ""))

    for _, entry in ipairs(spawnUI.filteredList) do
        local segments, normalizedPath = splitHierarchyAssetPath(getEntryAssetPath(entry, activeSpawnList))
        local node = root

        if #segments == 0 then
            local fallbackLabel = tostring(entry.fileName or entry.name or "")
            table.insert(root.entries, {
                entry = entry,
                label = fallbackLabel,
                sortKey = string.lower(fallbackLabel),
                pathKey = fallbackLabel
            })
        else
            for idx = 1, #segments - 1 do
                local segment = segments[idx]
                local child = node.children[segment]
                if not child then
                    local childKey = node.key .. "\\" .. segment
                    child = createHierarchyTreeNode(segment, childKey)
                    node.children[segment] = child
                    table.insert(node.childOrder, segment)
                end

                node = child
            end

            local leafLabel = segments[#segments]
            table.insert(node.entries, {
                entry = entry,
                label = leafLabel,
                sortKey = string.lower(leafLabel),
                pathKey = normalizedPath ~= "" and normalizedPath or tostring(entry.name or leafLabel)
            })
        end
    end

    local function sortHierarchyTreeNode(nodeRef)
        table.sort(nodeRef.childOrder, function(a, b)
            local aLower = string.lower(a)
            local bLower = string.lower(b)
            if aLower == bLower then
                return a < b
            end

            return aLower < bLower
        end)

        table.sort(nodeRef.entries, function(a, b)
            if a.sortKey == b.sortKey then
                return tostring(a.pathKey or "") < tostring(b.pathKey or "")
            end

            return a.sortKey < b.sortKey
        end)

        for _, childKey in ipairs(nodeRef.childOrder) do
            sortHierarchyTreeNode(nodeRef.children[childKey])
        end
    end

    sortHierarchyTreeNode(root)
    spawnUI.filteredHierarchyTree = root
end

---Regenerate the filteredList based on the active filter and the currently selected active spawn list
function spawnUI.updateFilter()

    local activeSpawnList = spawnUI.getActiveSpawnList()
    local classSelections = getDeviceClassFilterSelections(activeSpawnList)
    if classSelections then
        local availableClassKeys = collectAvailableFilterKeys(activeSpawnList, getEntryDeviceClassName)
        pruneUnavailableFilterSelections(classSelections, availableClassKeys)
    end
    local classFilterEnabled = hasSelectedFilterOption(classSelections)

    local recordTypeSelections = getRecordTypeFilterSelections(activeSpawnList)
    if recordTypeSelections then
        local availableRecordTypeKeys = collectAvailableFilterKeys(activeSpawnList, getEntryRecordTypePrefix)
        pruneUnavailableFilterSelections(recordTypeSelections, availableRecordTypeKeys)
    end
    local recordTypeFilterEnabled = hasSelectedFilterOption(recordTypeSelections)

    local pathOriginSelections = getPathOriginFilterSelections(activeSpawnList)
    local pathOriginFilterEnabled = isPathOriginFilterEnabled(pathOriginSelections)
    local hasSelectedPathOrigin = hasSelectedFilterOption(pathOriginSelections)

    if spawnUI.filter == "" and not classFilterEnabled and not recordTypeFilterEnabled and not pathOriginFilterEnabled then
        spawnUI.filteredList = activeSpawnList.data
        spawnUI.rebuildHierarchyTree()
        return
    end

    spawnUI.filteredList = {}
    for _, data in ipairs(activeSpawnList.data) do
        if matchesSearchFilter(activeSpawnList, data) then
            local include = true

            if classFilterEnabled then
                local className = getEntryDeviceClassName(data, activeSpawnList)
                include = className ~= "" and classSelections[className] == true
            end

            if include and recordTypeFilterEnabled then
                local recordTypeName = getEntryRecordTypePrefix(data, activeSpawnList)
                include = recordTypeName ~= "" and recordTypeSelections[recordTypeName] == true
            end

            if include and pathOriginFilterEnabled then
                local originKey = getEntryPathOriginKey(data, activeSpawnList)
                if hasSelectedPathOrigin then
                    include = originKey ~= nil and pathOriginSelections[originKey] == true
                else
                    include = originKey == nil
                end
            end

            if include then
                table.insert(spawnUI.filteredList, data)
            end
        end
    end

    spawnUI.rebuildHierarchyTree()
end

---Draws the Device Class Name multi-select filter selector for entity template/device variants.
---@return boolean changed
function spawnUI.drawDeviceClassFilterSelector()
    local activeSpawnList = spawnUI.getActiveSpawnList()
    if not supportsFilterForModule(activeSpawnList, deviceClassFilterListByModulePath) then
        return false
    end

    local selections = getDeviceClassFilterSelections(activeSpawnList)
    local previewLabel = getFilterPreviewLabel(selections, "All classes", "%d classes selected")
    local popupSearch = getFilterSearchForModule(
        activeSpawnList,
        deviceClassFilterListByModulePath,
        spawnUI.deviceClassFilterSearchByModule
    )
    local _, screenHeight = GetDisplayResolution()
    local maxPopupHeight = math.max(200 * style.viewSize, math.min(520 * style.viewSize, screenHeight - 16))
    local changed = false

    ImGui.AlignTextToFramePadding()
    style.mutedText("Device Class Name")
    ImGui.SameLine()

    local comboChanged, nextPopupSearch = style.drawSearchableMultiSelectCombo({
        comboId = "##deviceClassFilterCombo",
        previewLabel = previewLabel,
        searchHint = "Search class name...",
        searchValue = popupSearch,
        getOptions = function ()
            return getDeviceClassFilterOptions(activeSpawnList)
        end,
        selections = selections,
        comboWidth = 260 * style.viewSize,
        searchWidth = 220 * style.viewSize,
        maxPopupHeight = maxPopupHeight,
        emptyText = "No class names available",
        noMatchText = "No matching class names",
        searchInputId = "##deviceClassFilterSearch",
        searchClearButtonId = "##deviceClassFilterSearchClear",
        selectAllButtonId = "##deviceClassSelectAll",
        unselectAllButtonId = "##deviceClassUnselectAll",
        optionIdPrefix = "##deviceClassOption",
        selectAllTooltip = "Select all class names",
        unselectAllTooltip = "Unselect all class names (default behavior: show all)",
        getOptionKey = function (option)
            return option.className
        end,
        getOptionLabel = function (option)
            local labelIcon = option.icon ~= "" and (option.icon .. " ") or ""
            return string.format("%s%s (%d)", labelIcon, option.className, option.count)
        end,
        matchesOption = function (option, searchValue)
            return matchesSelectorOptionFilter(option.className, searchValue)
        end
    })
    if comboChanged then
        changed = true
    end

    if nextPopupSearch ~= popupSearch then
        setFilterSearchForModule(
            activeSpawnList,
            deviceClassFilterListByModulePath,
            spawnUI.deviceClassFilterSearchByModule,
            nextPopupSearch
        )
    end

    local clearChanged = drawMultiSelectClearButton(
        selections,
        "##deviceClassFilterSelectionClear",
        "Clear selected class-name filters",
        true
    )
    if clearChanged then
        changed = true
    end

    return changed
end

---Draws the Record Type multi-select filter selector for entity record variants.
---@return boolean changed
function spawnUI.drawRecordTypeFilterSelector()
    local activeSpawnList = spawnUI.getActiveSpawnList()
    if not supportsFilterForModule(activeSpawnList, recordTypeFilterListByModulePath) then
        return false
    end

    local selections = getRecordTypeFilterSelections(activeSpawnList)
    local previewLabel = getFilterPreviewLabel(selections, "All record types", "%d record types selected")
    local popupSearch = getFilterSearchForModule(
        activeSpawnList,
        recordTypeFilterListByModulePath,
        spawnUI.recordTypeFilterSearchByModule
    )
    local _, screenHeight = GetDisplayResolution()
    local maxPopupHeight = math.max(200 * style.viewSize, math.min(520 * style.viewSize, screenHeight - 16))
    local changed = false

    ImGui.AlignTextToFramePadding()
    style.mutedText("Record type")
    ImGui.SameLine()

    local comboChanged, nextPopupSearch = style.drawSearchableMultiSelectCombo({
        comboId = "##recordTypeFilterCombo",
        previewLabel = previewLabel,
        searchHint = "Search record type...",
        searchValue = popupSearch,
        getOptions = function ()
            return getRecordTypeFilterOptions(activeSpawnList)
        end,
        selections = selections,
        comboWidth = 200 * style.viewSize,
        searchWidth = 220 * style.viewSize,
        maxPopupHeight = maxPopupHeight,
        emptyText = "No record types available",
        noMatchText = "No matching record types",
        searchInputId = "##recordTypeFilterSearch",
        searchClearButtonId = "##recordTypeFilterSearchClear",
        selectAllButtonId = "##recordTypeSelectAll",
        unselectAllButtonId = "##recordTypeUnselectAll",
        optionIdPrefix = "##recordTypeOption",
        selectAllTooltip = "Select all record types",
        unselectAllTooltip = "Unselect all record types (default behavior: show all)",
        getOptionKey = function (option)
            return option.typeName
        end,
        getOptionLabel = function (option)
            local labelIcon = option.icon ~= "" and (option.icon .. " ") or ""
            return string.format("%s%s (%d)", labelIcon, option.typeName, option.count)
        end,
        matchesOption = function (option, searchValue)
            return matchesSelectorOptionFilter(option.typeName, searchValue)
        end
    })
    if comboChanged then
        changed = true
    end

    if nextPopupSearch ~= popupSearch then
        setFilterSearchForModule(
            activeSpawnList,
            recordTypeFilterListByModulePath,
            spawnUI.recordTypeFilterSearchByModule,
            nextPopupSearch
        )
    end

    local clearChanged = drawMultiSelectClearButton(
        selections,
        "##recordTypeFilterSelectionClear",
        "Clear selected record-type filters",
        true
    )
    if clearChanged then
        changed = true
    end

    return changed
end

---Draws the Content Origin filter as 3 inline checkboxes for path-based variants.
---@return boolean changed
function spawnUI.drawPathOriginFilterSelector()
    local activeSpawnList = spawnUI.getActiveSpawnList()
    if not supportsPathOriginFilter(activeSpawnList) then
        return false
    end

    local selections = getPathOriginFilterSelections(activeSpawnList)
    local changed = false

    ImGui.AlignTextToFramePadding()
    style.mutedText("Asset origin")
    style.tooltip("Filter entries based on where they come from.\nThis is determined by the starting path of the asset, for example 'base/' or 'mod/'.\nChecking all options will show all entries, while unchecking all will show only entries that don't match any known origin.")
    for _, option in ipairs(pathOriginFilterOptionOrder) do
        ImGui.SameLine()

        local optionChanged = false
        local tagInfo = pathOriginTagInfoByKey[option.key]
        selections[option.key], optionChanged = ImGui.Checkbox(
            tagInfo.label .. "##pathOrigin" .. option.checkboxIdSuffix,
            selections[option.key] == true
        )
        if tostring(tagInfo.tooltip or "") ~= "" then
            style.tooltip(tagInfo.tooltip)
        end

        if optionChanged then
            changed = true
        end
    end

    return changed
end

---Refresh the filtering and sorting
function spawnUI.refresh()
    spawnUI.updateFilter()

    if settings.spawnUIOnlyNames and spawnUI.getActiveSpawnList().isPaths then
        table.sort(spawnUI.filteredList, function(a, b) return a.fileName < b.fileName end)
    else
        table.sort(spawnUI.filteredList, function(a, b) return a.name < b.name end)
    end
end

---Applies and persists the selected category, then refreshes variant list and results.
function spawnUI.updateCategory()
    settings.selectedType = typeNames[spawnUI.selectedType + 1]
    settings.save()

    variantNames = getSortedVariantNames(typeNames[spawnUI.selectedType + 1])

    spawnUI.selectedVariant = math.max(utils.indexValue(variantNames, settings.lastVariants[settings.selectedType]) - 1, 0)

    spawnUI.refresh()
end

---Applies and persists the selected variant, then refreshes results.
function spawnUI.updateVariant()
    settings.lastVariants[settings.selectedType] = variantNames[spawnUI.selectedVariant + 1]
    settings.save()

    spawnUI.refresh()
end

---Selects a spawn type and variant by display names.
---Returns false when either name is unknown.
---@param typeName string
---@param variantName string
---@return boolean
function spawnUI.selectTypeAndVariant(typeName, variantName)
    if not types[typeName] or not types[typeName].variants[variantName] then
        return false
    end

    local typeIndex = utils.indexValue(typeNames, typeName)
    if typeIndex < 1 then
        return false
    end

    spawnUI.selectedType = typeIndex - 1
    spawnUI.updateCategory()

    local variantIndex = utils.indexValue(variantNames, variantName)
    if variantIndex < 1 then
        return false
    end

    spawnUI.selectedVariant = variantIndex - 1
    spawnUI.updateVariant()

    return true
end

local LIGHT_MODULE_PATH = "light/light"
local DEFAULT_HOVER_PREVIEW_DEBOUNCE_SECONDS = 0.1
local LIGHT_VISUALIZER_COMPONENT_NAMES = {
    "box",
    "sphere",
    "cone",
    "cone_inner",
    "capsule_body",
    "capsule_top",
    "capsule_bottom",
    "mesh",
    "mesh_inner",
    "radius_sphere",
    "arrows"
}

---@param component IComponent?
---@return boolean
local function getComponentEnabledState(component)
    if not component then
        return false
    end

    local okEnabled, isEnabled = pcall(function ()
        return component:IsEnabled()
    end)

    return okEnabled and isEnabled == true
end

---@param component IComponent?
---@param enabled boolean
local function setComponentEnabled(component, enabled)
    if not component then
        return
    end

    if getComponentEnabledState(component) == enabled then
        return
    end

    pcall(function ()
        component:Toggle(enabled)
    end)
end

---Returns the `flashlight` mod logic table when available.
---Uses nil-safe checks because this integration is optional.
---@return table?
local function getExternalFlashlightLogic()
    local flashlightMod = GetMod("flashlight")
    if not flashlightMod or not flashlightMod.logic then
        return nil
    end

    return flashlightMod.logic
end

---Returns the external flashlight light component if it can be resolved safely.
---Falls back to `nil` when the mod is missing, unloaded, or errors.
---@return IComponent?
local function getExternalFlashlightComponent()
    local flashlightLogic = getExternalFlashlightLogic()
    if not flashlightLogic or type(flashlightLogic.getComponent) ~= "function" then
        return nil
    end

    local okComponent, component = pcall(flashlightLogic.getComponent)
    if not okComponent then
        return nil
    end

    return component
end

---Suppresses light contribution from the external flashlight mod while preview is active.
---Primary path sets `brightnessOverride = 0` in flashlight logic, matching how the mod computes light.
---A component-level `SetStrength(0)` call is kept as defensive fallback.
local function suppressExternalFlashlightDuringPreview()
    local flashlightLogic = getExternalFlashlightLogic()
    if flashlightLogic then
        if not spawnUI.flashlightSuppressionCaptured then
            spawnUI.flashlightSuppressionCaptured = true
            spawnUI.flashlightSuppressionPreviousOverride = flashlightLogic.brightnessOverride
        end

        flashlightLogic.brightnessOverride = 0
    end

    local component = spawnUI.flashlightSuppressionComponent
    if not component then
        component = getExternalFlashlightComponent()
    end

    if not component then
        spawnUI.flashlightSuppressionComponent = nil
        return
    end

    local okSuppressed = pcall(function ()
        component:SetStrength(0)
    end)

    if okSuppressed then
        spawnUI.flashlightSuppressionComponent = component
    else
        spawnUI.flashlightSuppressionComponent = nil
    end
end

---Restores external flashlight state after preview is hidden.
---Only restores `brightnessOverride` if WB captured an original value when suppression began.
local function restoreExternalFlashlightAfterPreview()
    local flashlightLogic = getExternalFlashlightLogic()
    if flashlightLogic and spawnUI.flashlightSuppressionCaptured then
        flashlightLogic.brightnessOverride = spawnUI.flashlightSuppressionPreviousOverride
    end

    spawnUI.flashlightSuppressionComponent = nil
    spawnUI.flashlightSuppressionCaptured = false
    spawnUI.flashlightSuppressionPreviousOverride = nil
end

---@return table
local function buildLightSuppressionTargets()
    local targets = {}
    if not spawnUI.spawnedUI or not spawnUI.spawnedUI.root then
        return targets
    end

    for _, entry in ipairs(spawnUI.spawnedUI.root:getPathsRecursive(true)) do
        local ref = entry.ref
        if utils.isA(ref, "spawnableElement") and ref.spawnable and ref.spawnable.modulePath == LIGHT_MODULE_PATH then
            local entity = ref.spawnable:getEntity()
            if entity then
                local target = {
                    spawnable = ref.spawnable,
                    lightComponent = entity:FindComponentByName("light"),
                    visualizerComponents = {}
                }

                for _, componentName in ipairs(LIGHT_VISUALIZER_COMPONENT_NAMES) do
                    local component = entity:FindComponentByName(componentName)
                    if component then
                        table.insert(target.visualizerComponents, component)
                    end
                end

                table.insert(targets, target)
            end
        end
    end

    return targets
end

---@return table
function spawnUI.getLightSuppressionTargets()
    local epoch = -1
    if spawnUI.spawnedUI then
        epoch = spawnUI.spawnedUI.cacheEpoch or -1
    end

    if not spawnUI.lightSuppressionTargetsCache or spawnUI.lightSuppressionTargetsCacheEpoch ~= epoch then
        spawnUI.lightSuppressionTargetsCache = buildLightSuppressionTargets()
        spawnUI.lightSuppressionTargetsCacheEpoch = epoch
    end

    return spawnUI.lightSuppressionTargetsCache
end

---@param state boolean
function spawnUI.setAssetPreviewActive(state)
    local shouldBeActive = state == true
    if spawnUI.assetPreviewActive == shouldBeActive then
        return
    end

    spawnUI.assetPreviewActive = shouldBeActive

    if shouldBeActive then
        spawnUI.activeLightSuppressionStates = {}
        spawnUI.flashlightSuppressionComponent = nil
        spawnUI.flashlightSuppressionCaptured = false
        spawnUI.flashlightSuppressionPreviousOverride = nil

        for _, target in ipairs(spawnUI.getLightSuppressionTargets()) do
            local stateEntry = {
                target = target,
                lightSuppressed = false,
                lightWasEnabled = false,
                visualizerWasEnabled = {}
            }

            if target.lightComponent and target.spawnable and target.spawnable.cameraFollowEnabled == true then
                stateEntry.lightSuppressed = true
                stateEntry.lightWasEnabled = getComponentEnabledState(target.lightComponent)
                if stateEntry.lightWasEnabled then
                    setComponentEnabled(target.lightComponent, false)
                end
            end

            for idx, component in ipairs(target.visualizerComponents) do
                local wasEnabled = getComponentEnabledState(component)
                stateEntry.visualizerWasEnabled[idx] = wasEnabled
                if wasEnabled then
                    setComponentEnabled(component, false)
                end
            end

            table.insert(spawnUI.activeLightSuppressionStates, stateEntry)
        end

        suppressExternalFlashlightDuringPreview()

        return
    end

    for _, stateEntry in ipairs(spawnUI.activeLightSuppressionStates) do
        local target = stateEntry.target
        if stateEntry.lightSuppressed and target.lightComponent then
            setComponentEnabled(target.lightComponent, stateEntry.lightWasEnabled)
        end

        for idx, component in ipairs(target.visualizerComponents) do
            local wasEnabled = stateEntry.visualizerWasEnabled[idx]
            if wasEnabled ~= nil then
                setComponentEnabled(component, wasEnabled)
            end
        end
    end

    spawnUI.activeLightSuppressionStates = {}
    restoreExternalFlashlightAfterPreview()
end

---Stops pending hover preview timers and disables the active preview instance.
function spawnUI.stopActiveAssetPreview()
    if spawnUI.previewTimer then
        Cron.Halt(spawnUI.previewTimer)
        spawnUI.previewTimer = nil
    end

    if spawnUI.previewInstance then
        spawnUI.previewInstance:assetPreview(false)
    end

    spawnUI.setAssetPreviewActive(false)
end

---@param entry table|favorite
---@param isFavorite boolean
function spawnUI.handleAssetPreviewHovered(entry, isFavorite)
    if spawnUI.hoveredEntry ~= entry then
        spawnUI.stopActiveAssetPreview()

        spawnUI.hoveredEntry = entry

        local activeSpawnList = spawnUI.getActiveSpawnList()
        local assetPreviewType = activeSpawnList.assetPreviewType
        local assetPreviewDelay = activeSpawnList.assetPreviewDelay
        if isFavorite then
            -- If its favorite, then entry is just the favorite instance
            if entry.data.modulePath ~= "modules/classes/editor/spawnableElement" then
                assetPreviewType = "none"
            else
                assetPreviewDelay = modulePathToSpawnList[entry.data.spawnable.modulePath].assetPreviewDelay
                assetPreviewType = modulePathToSpawnList[entry.data.spawnable.modulePath].assetPreviewType
            end
        end

        if assetPreviewType == "none" then return end

        local previewDelay = assetPreviewDelay or DEFAULT_HOVER_PREVIEW_DEBOUNCE_SECONDS
        spawnUI.previewTimer = Cron.After(previewDelay, function ()
            spawnUI.previewTimer = nil
            if not spawnUI.hoveredEntry then return end

            local data = utils.deepcopy(entry.data)
            if isFavorite then
                spawnUI.previewInstance = require("modules/classes/spawn/" .. data.spawnable.modulePath):new()
                data = data.spawnable
            else
                spawnUI.previewInstance = activeSpawnList.class:new()
                data.modulePath = spawnUI.previewInstance.modulePath
            end

            local pos, _ = spawnUI.getSpawnNewPosition()
            local rot = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetRotation()
            rot.yaw = rot.yaw - 180
            rot.pitch = -rot.pitch
            spawnUI.previewInstance:loadSpawnData(data, pos, rot)

            spawnUI.previewInstance:assetPreview(true)
            spawnUI.setAssetPreviewActive(true)
        end)
    end
end

---Runs per-frame maintenance for asset previews.
function spawnUI.updateAssetPreview()
    if spawnUI.assetPreviewActive then
        suppressExternalFlashlightDuringPreview()
    end

    if spawnUI.previewInstance and spawnUI.previewInstance:isSpawned() then
        spawnUI.previewInstance:assetPreviewSetPosition()
    end
end

---Draws spawn-position controls and returns the alignment X coordinate.
---@return number
function spawnUI.drawSpawnPosition()
    style.mutedText("Spawn position")
    ImGui.SameLine()
    local x = ImGui.GetCursorPosX()
    ImGui.PushItemWidth(100 * style.viewSize)
    local pos, changed = ImGui.Combo("##spawnPos", settings.spawnPos - 1, { "At selected", "Screen center" }, 2)
    settings.spawnPos = pos + 1
    if changed then settings.save() end
    if settings.spawnPos == 1 then
        style.tooltip("Spawn the new object at the position of the selected object(s), if none are selected, it will spawn in front of the player")
    else
        style.tooltip("Spawn position is relative to the camera position and orientation.")
    end

    ImGui.SameLine()

    style.mutedText(IconGlyphs.InformationOutline)
    style.tooltip("To spawn an object under the cursor, either:\n - Use the Shift-A menu while in editor mode\n - Drag and drop an object from the list to the desired position on the screen.")

    return x
end

---Draws a small drag-follow window while dragging an entry.
function spawnUI.drawDragWindow()
    if not spawnUI.dragging then return end

    ImGui.SetMouseCursor(ImGuiMouseCursor.Hand)

    local x, y = ImGui.GetMousePos()
    ImGui.SetNextWindowPos(x + 10 * style.viewSize, y + 10 * style.viewSize, ImGuiCond.Always)
    if ImGui.Begin("##drag", ImGuiWindowFlags.NoResize + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoBackground + ImGuiWindowFlags.AlwaysAutoResize) then
        ImGui.Text(spawnUI.dragData.name)
        ImGui.End()
    end
end

---Draws one interactive search-result row.
---Used by both the classic flat list and the hierarchy tree leaves.
---@param entry table
---@param activeSpawnList table
---@param xSpace number
---@param buttonTextOverride string?
---@param showFullPathTooltip boolean?
local function drawSpawnResultEntryRow(entry, activeSpawnList, xSpace, buttonTextOverride, showFullPathTooltip)
    local pushedButtonStyle = false
    local forcePathTooltip = showFullPathTooltip == true

    ImGui.PushID(entry.name)

    if entry.lastSpawned ~= nil then
        ImGui.PushStyleColor(ImGuiCol.Button, 0xff009933)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0xff009900)
        pushedButtonStyle = true
    end

    if entry.lastSpawned ~= nil and entry.lastSpawned.parent == nil then entry.lastSpawned = nil end

    if entry.lastSpawned ~= nil then
        if ImGui.Button("Despawn") then
            history.addAction(history.getRemove({ entry.lastSpawned }))
            entry.lastSpawned:remove()
            entry.lastSpawned = nil
        end
        ImGui.SameLine()
    end

    local buttonText = buttonTextOverride or entry.name
    if not buttonTextOverride and activeSpawnList.isPaths and settings.spawnUIOnlyNames then
        buttonText = utils.getFileName(entry.name)
    end

    local originTagInfo = getEntryPathOriginTagInfo(entry, activeSpawnList)
    if originTagInfo and entry.lastSpawned == nil then
        drawPathOriginTagChip(originTagInfo)
        ImGui.SameLine()
    end

    local secondaryIcon = getSearchResultSecondaryIcon(entry, activeSpawnList)
    local buttonWidth = xSpace - ImGui.GetCursorPosX()
    local buttonLabel = formatSearchResultButtonText(buttonText, buttonWidth, secondaryIcon)

    local clicked = ImGui.Button(buttonLabel) and not ImGui.IsMouseDragging(0, style.draggingThreshold)

    if clicked then
        local class = activeSpawnList.class
        entry.lastSpawned = spawnUI.spawnNew(entry, class, false)
    elseif ImGui.IsMouseDragging(0, style.draggingThreshold) and not spawnUI.dragging and ImGui.IsItemHovered() then
        spawnUI.dragging = true
        spawnUI.dragData = entry
    elseif not ImGui.IsMouseDragging(0, style.draggingThreshold) and spawnUI.dragging then
        if not ImGui.IsItemHovered() then
            local ray = editor.getScreenToWorldRay()
            spawnUI.popupSpawnHit = editor.getRaySceneIntersection(ray, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), nil, true)

            local class = activeSpawnList.class
            spawnUI.dragData.lastSpawned = spawnUI.spawnNew(spawnUI.dragData, class, false)
        end

        spawnUI.dragging = false
        spawnUI.dragData = nil
        spawnUI.popupSpawnHit = nil
    end
    if ImGui.IsItemClicked(ImGuiMouseButton.Middle) then
        ImGui.SetClipboardText(entry.name)
    end
    if ImGui.IsItemHovered() and settings.assetPreviewEnabled[activeSpawnList.modulePath] then
        spawnUI.handleAssetPreviewHovered(entry, false)
    elseif spawnUI.hoveredEntry == entry and (spawnUI.previewInstance or spawnUI.previewTimer) then
        spawnUI.hoveredEntry = nil
        spawnUI.stopActiveAssetPreview()
    end

    if settings.spawnUIOnlyNames or forcePathTooltip then
        style.tooltip(entry.name)
    end

    if ImGui.BeginPopupContextItem("##spawnNewContext", ImGuiPopupFlags.MouseButtonRight) then
        if ImGui.MenuItem(IconGlyphs.Group .. " Make Favorite") then
            local new = require("modules/classes/editor/spawnableElement"):new(spawnUI.spawnedUI)
            local data = utils.deepcopy(entry.data)
            data.modulePath = activeSpawnList.class:new().modulePath
            data.position = { x = 0, y = 0, z = 0, w = 0 }
            data.rotation = { roll = 0, pitch = 0, yaw = 0 }

            new:load({
                name = utils.getFileName(entry.name),
                modulePath = new.modulePath,
                spawnable = data
            })

            spawnUI.favoritesUI.addNewItem(new:serialize(), new.name, new.icon)
        end

        ImGui.EndPopup()
    end

    if pushedButtonStyle then
        ImGui.PopStyleColor(2)
    end

    ImGui.PopID()
end

---Draws classic flat search results with clipper-based virtualization.
---@param activeSpawnList table
---@param xSpace number
local function drawFlatSpawnResults(activeSpawnList, xSpace)
    local clipper = ImGuiListClipper.new()
    clipper:Begin(#spawnUI.filteredList, -1)

    while (clipper:Step()) do
        for i = clipper.DisplayStart + 1, clipper.DisplayEnd, 1 do
            drawSpawnResultEntryRow(spawnUI.filteredList[i], activeSpawnList, xSpace)
        end
    end
end

---Returns the only child folder when a node contains exactly one folder and no assets.
---@param node table
---@return table?
local function getSingleFolderOnlyChild(node)
    if #node.entries ~= 0 then
        return nil
    end

    if #node.childOrder ~= 1 then
        return nil
    end

    return node.children[node.childOrder[1]]
end

---Expands the linear single-child folder chain below `node`.
---@param node table
local function expandSingleChildFolderChain(node)
    local current = node
    while current do
        local child = getSingleFolderOnlyChild(current)
        if not child then
            break
        end

        spawnUI.hierarchyOpenStateByKey[child.key] = true
        current = child
    end
end

---Recursively assigns open-state for every folder node under `node`.
---@param node table
---@param isOpen boolean
local function setHierarchyNodeOpenStateRecursive(node, isOpen)
    for _, childKey in ipairs(node.childOrder) do
        local child = node.children[childKey]
        spawnUI.hierarchyOpenStateByKey[child.key] = isOpen
        setHierarchyNodeOpenStateRecursive(child, isOpen)
    end
end

---Draws expand/collapse icon buttons at the top of hierarchy search results.
---@param hierarchyRoot table
local function drawHierarchyResultControls(hierarchyRoot)
    local hasFolders = #hierarchyRoot.childOrder > 0
    local expandIcon = IconGlyphs.ExpandAllOutline or IconGlyphs.ArrowExpandAll or IconGlyphs.ExpandAll or "+"
    local collapseIcon = IconGlyphs.CollapseAllOutline or IconGlyphs.ArrowCollapseAll or IconGlyphs.CollapseAll or "-"

    ImGui.BeginDisabled(not hasFolders)

    style.pushButtonNoBG(true)
    if ImGui.Button(expandIcon .. "##spawnHierarchyExpandAll") then
        setHierarchyNodeOpenStateRecursive(hierarchyRoot, true)
    end
    style.pushButtonNoBG(false)
    style.tooltip("Expand all folders")

    ImGui.SameLine()

    style.pushButtonNoBG(true)
    if ImGui.Button(collapseIcon .. "##spawnHierarchyCollapseAll") then
        setHierarchyNodeOpenStateRecursive(hierarchyRoot, false)
    end
    style.pushButtonNoBG(false)
    style.tooltip("Collapse all folders")

    ImGui.EndDisabled()
    ImGui.Separator()
end

---Recursively draws one hierarchy folder node and its children/leaves.
---@param node table
---@param activeSpawnList table
---@param xSpace number
local function drawHierarchySpawnResultNode(node, activeSpawnList, xSpace)
    if node.label == "" then
        for _, childKey in ipairs(node.childOrder) do
            drawHierarchySpawnResultNode(node.children[childKey], activeSpawnList, xSpace)
        end

        for _, leaf in ipairs(node.entries) do
            drawSpawnResultEntryRow(leaf.entry, activeSpawnList, xSpace, leaf.label, true)
        end
        return
    end

    local requestedOpenState = spawnUI.hierarchyOpenStateByKey[node.key]
    if requestedOpenState ~= nil then
        ImGui.SetNextItemOpen(requestedOpenState, ImGuiCond.Always)
    end

    local nodeLabel = string.format("%s##spawnResultHierarchyNode:%s", node.label, node.key)
    local open = ImGui.TreeNodeEx(nodeLabel, ImGuiTreeNodeFlags.SpanFullWidth)
    local toggledOpen = ImGui.IsItemToggledOpen()
    if toggledOpen then
        spawnUI.hierarchyOpenStateByKey[node.key] = open
        if open then
            expandSingleChildFolderChain(node)
        end
    elseif requestedOpenState == nil then
        spawnUI.hierarchyOpenStateByKey[node.key] = open
    end

    if not open then
        return
    end

    for _, childKey in ipairs(node.childOrder) do
        drawHierarchySpawnResultNode(node.children[childKey], activeSpawnList, xSpace)
    end

    for _, leaf in ipairs(node.entries) do
        drawSpawnResultEntryRow(leaf.entry, activeSpawnList, xSpace, leaf.label, true)
    end

    ImGui.TreePop()
end

---Draws hierarchy-based path results from the cached `filteredHierarchyTree`.
---@param activeSpawnList table
---@param xSpace number
local function drawHierarchySpawnResults(activeSpawnList, xSpace)
    if not spawnUI.filteredHierarchyTree then
        spawnUI.rebuildHierarchyTree()
    end

    local hierarchyRoot = spawnUI.filteredHierarchyTree
    if not hierarchyRoot then
        drawFlatSpawnResults(activeSpawnList, xSpace)
        return
    end

    if #spawnUI.filteredList == 0 then
        return
    end

    drawHierarchyResultControls(hierarchyRoot)
    drawHierarchySpawnResultNode(hierarchyRoot, activeSpawnList, xSpace)
end

---Draws the fallback action when no path entries match the search text.
function spawnUI.drawNoMatch()
    if #spawnUI.filteredList ~= 0 or not spawnUI.getActiveSpawnList().isPaths then return end

    style.mutedText("No match found...")
    style.mutedText(("Spawn \"%s\" anyways?"):format(spawnUI.filter))

    if ImGui.Button("Spawn") then
        local class = spawnUI.getActiveSpawnList().class
        spawnUI.spawnNew({
            data = { spawnData = spawnUI.filter }, lastSpawned = nil, name = spawnUI.filter, fileName = spawnUI.filter
        }, class, false)
    end
end

---Draws Spawn New options for display mode, preview mode, and spawn placement.
function spawnUI.drawOptions()
    local activeList = spawnUI.getActiveSpawnList()
    if activeList.isPaths then
        style.mutedText("Strip paths")
        ImGui.SameLine()
        local stripPathsChanged
        settings.spawnUIOnlyNames, stripPathsChanged = ImGui.Checkbox("##strip", settings.spawnUIOnlyNames)
        if stripPathsChanged then
            spawnUI.refresh()
        end
        style.tooltip("Only show the name of the file, without the full path")
    end

    if activeList.assetPreviewType ~= "none" then
        style.mutedText("Asset Preview")
        ImGui.SameLine()
        local assetPreviewChanged
        settings.assetPreviewEnabled[activeList.modulePath], assetPreviewChanged = ImGui.Checkbox("##assetPreview", settings.assetPreviewEnabled[activeList.modulePath])
        if assetPreviewChanged then
            settings.save()
        end
        style.tooltip("Preview the asset when hovered. Is Experimental.")
        if activeList.assetPreviewType == "backdrop" then
            ImGui.SameLine()
            style.mutedText(IconGlyphs.Checkerboard)
            style.tooltip("Asset gets previewed with a backdrop")
        else
            ImGui.SameLine()
            style.mutedText(IconGlyphs.AxisArrowInfo)
            style.tooltip("Asset gets previewed at the same position it would spawn in")
        end
    end

    spawnUI.drawSpawnPosition()
end

local SPAWN_NEW_OPTIONS_POPIN_ID = "##spawnNewOptionsPopin"

---Draws right-aligned search-row controls (hierarchy toggle + options popin).
---@param activeSpawnList table
local function drawSpawnNewSearchRowControls(activeSpawnList)
    local compactButtonWidth = 25 * style.viewSize
    local controlsCount = activeSpawnList.isPaths and 2 or 1
    local spacingX = ImGui.GetStyle().ItemSpacing.x
    local controlsWidth = compactButtonWidth * controlsCount + spacingX * (controlsCount - 1)

    ImGui.SameLine()
    ImGui.SetCursorPosX(ImGui.GetWindowWidth() - controlsWidth)

    if activeSpawnList.isPaths then
        local hierarchyTreeChanged
        settings.spawnUIHierarchyTree, hierarchyTreeChanged = style.toggleButton(
            IconGlyphs.FileTreeOutline .. "##hierarchyTreeToggle",
            settings.spawnUIHierarchyTree
        )
        if hierarchyTreeChanged then
            settings.save()
        end
        style.tooltip("Toggle hierarchy tree results")

        ImGui.SameLine()
    end

    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.CogOutline .. "##spawnNewOptionsButton") then
        ImGui.OpenPopup(SPAWN_NEW_OPTIONS_POPIN_ID)
    end
    style.pushButtonNoBG(false)
    style.tooltip("Options")

    if ImGui.BeginPopup(SPAWN_NEW_OPTIONS_POPIN_ID) then
        ImGui.PushID("spawnNewOptionsPopin")
        spawnUI.drawOptions()
        ImGui.PopID()
        ImGui.EndPopup()
    end
end

---Draws the target group selector used for new spawns.
function spawnUI.drawTargetGroupSelector()
    local groups = { "Root" }
	for _, group in pairs(spawnUI.spawnedUI.containerPaths) do
		table.insert(groups, group.path)
	end

    if spawnUI.selectedGroup >= #groups then
        spawnUI.selectedGroup = 0
    end

    ImGui.BeginGroup()
    style.drawIconLabelRow(IconGlyphs.PlusBoxOutline, "Target group")
    --style.mutedText(IconGlyphs.PlusBoxOutline .. " Target group")
    ImGui.SameLine()
	ImGui.PushItemWidth(200 * style.viewSize)
	spawnUI.selectedGroup = ImGui.Combo("##newSpawnGroup", spawnUI.selectedGroup, groups, #groups)
    ImGui.EndGroup()
    style.tooltip("Automatically place any newly spawned object into the selected group.\nPress CTRL-N in \"Spawned\" tab to set this selector to the currently selected group.")
	ImGui.PopItemWidth()
end

---Draws the full "All" tab, including filters, list, and quick actions.
function spawnUI.drawAll()
    spawnUI.drawTargetGroupSelector()

    style.spacedSeparator()

    ImGui.PushItemWidth(120 * style.viewSize)
	local typeChanged
	spawnUI.selectedType, typeChanged = ImGui.Combo("Object type", spawnUI.selectedType, typeNames, #typeNames)
    if typeChanged then
        spawnUI.updateCategory()
    end

    ImGui.SameLine()

	local variantChanged
	spawnUI.selectedVariant, variantChanged = ImGui.Combo("Object variant", spawnUI.selectedVariant, variantNames, #variantNames)
    if variantChanged then
        spawnUI.updateVariant()
    end
    style.spawnableInfo(spawnUI.getActiveSpawnList().info)

	ImGui.PopItemWidth()

    if variantNames[spawnUI.selectedVariant + 1] == "Template (AMM)" then
        ImGui.SameLine()

        style.pushGreyedOut(not AMM)
        if not amm.importing then
            if ImGui.Button("Generate AMM Props") and AMM then
                amm.generateProps(spawnUI, AMM, spawnUI.spawner)
            end
            style.tooltip("Generate files for spawning, from current list of AMM props")
        else
            ImGui.ProgressBar(amm.progress / amm.total, 200, 30, string.format("%.2f%%", (amm.progress / amm.total) * 100))
        end

        style.popGreyedOut(not AMM)
    end

    style.spacedSeparator()

    ImGui.SetNextItemWidth(300 * style.viewSize)
    local filterChanged
    spawnUI.filter, filterChanged = ImGui.InputTextWithHint('##Filter', 'Search by name... (Supports pattern matching)', spawnUI.filter, 500)
    if filterChanged then
        saveSpawnUIFilterIfChanged()
        spawnUI.updateFilter()
    end

    if spawnUI.filter ~= '' then
        ImGui.SameLine()

        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Close) then
            spawnUI.filter = ''
            saveSpawnUIFilterIfChanged()
            spawnUI.updateFilter()
        end
        style.pushButtonNoBG(false)
    end

    ImGui.SameLine()
    style.mutedText(IconGlyphs.InformationOutline)
    style.tooltip("Supports custom search query syntax:\n- | (OR), includes any terms including the word after the |\n- ! (NOT), excludes any terms including the word after the !\n- & (AND), terms must include the word after the &\n- E.g. table|chair!poor&low to match any terms that include 'table' or 'chair', but not 'poor', and must include 'low'")

    local activeSpawnList = spawnUI.getActiveSpawnList()
    drawSpawnNewSearchRowControls(activeSpawnList)

    local extraFilterChanged = false
    if spawnUI.drawPathOriginFilterSelector() then
        extraFilterChanged = true
    end
    if spawnUI.drawDeviceClassFilterSelector() then
        extraFilterChanged = true
    end
    if spawnUI.drawRecordTypeFilterSelector() then
        extraFilterChanged = true
    end
    if extraFilterChanged then
        spawnUI.updateFilter()
    end

    style.spacedSeparator()

    ImGui.BeginChild("list")

    local xSpace, _ = ImGui.GetItemRectSize() - 2 * ImGui.GetStyle().WindowPadding.x - (ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0)

    spawnUI.drawNoMatch()

    local useHierarchyTree = settings.spawnUIHierarchyTree and activeSpawnList.isPaths
    if useHierarchyTree then
        drawHierarchySpawnResults(activeSpawnList, xSpace)
    else
        drawFlatSpawnResults(activeSpawnList, xSpace)
    end

    if #spawnUI.filteredList == 0 then
        spawnUI.stopActiveAssetPreview()
    end

    ImGui.EndChild()
end

---Draws the Spawn UI tab bar and delegates per-tab content.
function spawnUI.draw()
    spawnUI.drawDragWindow()
    spawnUI.updateAssetPreview()
    groupLoadManager.drawProgress(style)

    if ImGui.BeginTabBar("##spawnUITabbar", ImGuiTabItemFlags.NoTooltip) then
        if ImGui.BeginTabItem(string.format("%s All", IconGlyphs.TextBoxSearchOutline)) then
            spawnUI.drawAll()
            ImGui.EndTabItem()
        end
        if ImGui.BeginTabItem(string.format("%s Favorites", IconGlyphs.HeartBoxOutline)) then
            spawnUI.favoritesUI.draw()
            ImGui.EndTabItem()
        end
        ImGui.EndTabBar()
    end
end

---Handles Spawn UI being hidden by clearing active preview state.
function spawnUI.hidden()
    if not spawnUI.previewInstance and not spawnUI.previewTimer and not spawnUI.assetPreviewActive then return end

    spawnUI.hoveredEntry = nil
    spawnUI.stopActiveAssetPreview()
end

---Computes default spawn transform using current settings and selection.
---@return Vector4
---@return EulerAngles
function spawnUI.getSpawnNewPosition()
    if not GetPlayer() then
        return Vector4.new(0, 0, 0, 0), EulerAngles.new(0, 0, 0)
    end

    local rot = EulerAngles.new(0, 0, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetRotation().yaw + 180)
    local pos = GetPlayer():GetWorldPosition()
    local forward = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetAxisY()

    if editor.active then
        pos = GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation()
        pos.z = pos.z + forward.z * settings.spawnDist
    end
    pos.x = pos.x + forward.x * settings.spawnDist
    pos.y = pos.y + forward.y * settings.spawnDist

    if settings.spawnPos == 1 then
        if #spawnUI.spawnedUI.selectedPaths == 1 and utils.isA(spawnUI.spawnedUI.selectedPaths[1].ref, "spawnableElement") then
            pos = spawnUI.spawnedUI.selectedPaths[1].ref:getPosition()
            rot = spawnUI.spawnedUI.selectedPaths[1].ref:getRotation()
        elseif #spawnUI.spawnedUI.selectedPaths > 1 then
            pos = spawnUI.spawnedUI.multiSelectGroup:getPosition()
            rot = spawnUI.spawnedUI.multiSelectGroup:getDirection("forward"):ToRotation()
        end
    end

    return pos, rot
end

---@param data table?
---@return boolean
local function isFavoriteGroupData(data)
    if not data then return false end

    if data.modulePath == "modules/classes/editor/positionableGroup" then
        return true
    end

    if data.modulePath == "modules/classes/editor/randomizedGroup" then
        return true
    end

    if data.type == "group" then
        return true
    end

    if data.childs ~= nil then
        local isSpawnableElement = data.modulePath == "modules/classes/editor/spawnableElement"
            or data.type == "object"
            or data.type == "element"
            or data.spawnable ~= nil

        return not isSpawnableElement
    end

    return false
end

---@param data table?
local function applySpawnNewVisualizerDefault(data)
    if type(data) ~= "table" then
        return
    end

    local modulePath = data.modulePath
    if not modulePath or spawnNewVisualizerModuleSet[modulePath] ~= true then
        return
    end

    local defaults = settings.spawnNewVisualizerEnabledByModule
    if type(defaults) ~= "table" then
        return
    end

    local defaultPreviewed = defaults[modulePath]
    if type(defaultPreviewed) == "boolean" then
        data.previewed = defaultPreviewed
    end
end

---Spawns a new entry (or favorite/group) and records history metadata.
---@param entry table|favorite
---@param class table
---@param isFavorite boolean
---@param options table?
---@return any
function spawnUI.spawnNew(entry, class, isFavorite, options)
    if groupLoadManager.isActive() then
        return nil
    end

    options = options or {}
    local loadHidden = isFavorite and options.loadHidden == true

    spawnUI.lastSpawnedClass = class
    spawnUI.lastSpawnedEntry = entry
    spawnUI.lastSpawnedIsFavorite = isFavorite
    spawnUI.lastSpawnedOptions = {
        loadHidden = loadHidden
    }

    -- Cleanup preview
    spawnUI.stopActiveAssetPreview()

    local parent = spawnUI.spawnedUI.root
    if spawnUI.selectedGroup ~= 0 and spawnUI.spawnedUI.containerPaths[spawnUI.selectedGroup] then
        parent = spawnUI.spawnedUI.containerPaths[spawnUI.selectedGroup].ref
    end

    local new = require("modules/classes/editor/spawnableElement"):new(spawnUI.spawnedUI)
    local pos, rot = spawnUI.getSpawnNewPosition()

    local snap = spawnUI.popupSpawnHit and spawnUI.popupSpawnHit.hit
    if snap then
        pos = spawnUI.popupSpawnHit.result.position
        local target = spawnUI.popupSpawnHit.result.normal
        local current = Vector4.new(0, 0, 1, 0)
        local axis = current:Cross(target)
        local angle = Vector4.GetAngleBetween(current, target)

        if math.abs(angle) < 0.1 then
            rot = EulerAngles.new(0, 0, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetRotation().yaw + 180)
        else
            rot = Quaternion.SetAxisAngle(axis:Normalize(), math.rad(angle)):ToEulerAngles()
        end
    end

    local favoriteIsGroup = isFavorite and isFavoriteGroupData(entry.data)
    local data = favoriteIsGroup and entry.data or utils.deepcopy(entry.data)

    if favoriteIsGroup then
        groupLoadManager.start({
            spawner = spawnUI.spawner,
            data = data,
            targetParent = parent,
            clearLocks = true,
            selectLoaded = not loadHidden,
            loadHidden = loadHidden,
            initialPosition = pos,
            initialRotation = rot
        })

        return nil
    end

    if isFavorite then
        -- Favorites should always load unlocked so initial placement is never blocked.
        utils.clearLockStateRecursive(data)
    end

    if not isFavorite then
        data.modulePath = class:new().modulePath
        applySpawnNewVisualizerDefault(data)
        data.position = { x = pos.x, y = pos.y, z = pos.z, w = 0 }
        data.rotation = { roll = rot.roll, pitch = rot.pitch, yaw = rot.yaw }
    end

    if isFavorite then
        ---@type positionable
        new = require(entry.data.modulePath):new(spawnUI.spawnedUI)
        data.visible = false

        new:load(data, true) -- Load without spawning
        new:setPosition(pos)
        new:setRotation(rot)
        new:setSilent(false)
        if not loadHidden then
            new:setVisible(true, true) -- Now spawn, but dont record in history
        end
    else
        new:load({
            name = utils.getFileName(entry.name),
            modulePath = new.modulePath,
            spawnable = data
        })
    end

    if utils.isA(new, "spawnableElement") and new.spawnable.bBoxLoaded == nil and snap then -- Bbox is immediately available
        local adjustedPos = utils.addVector(spawnUI.popupSpawnHit.result.position, utils.multVector(spawnUI.popupSpawnHit.result.normal, math.abs(new.spawnable:getBBox().min.z)))
        Cron.After(0.1, function ()
            new:setPosition(adjustedPos)
        end)
    end

    new:setParent(parent)
    new.selected = true
    spawnUI.spawnedUI.unselectAll()

    if utils.isA(new, "spawnableElement") and snap and new.spawnable.bBoxLoaded ~= nil then
        local position = spawnUI.popupSpawnHit.result.position
        local normal = spawnUI.popupSpawnHit.result.normal

        Cron.Every(0.05, function (timer)
            if new.spawnable.bBoxLoaded and new.spawnable:getEntity() then
                Cron.After(0.1, function ()
                    local adjustedPos = utils.addVector(position, utils.multVector(normal, math.abs(new.spawnable:getBBox().min.z)))
                    new:setPosition(adjustedPos)
                    history.addAction(history.getInsert({ new }))
                end)

                timer:Halt()
            end
        end)
    else
        history.addAction(history.getInsert({ new }))
    end

    return new
end

---Repeats the last successful spawn operation using cached context.
function spawnUI.repeatLastSpawn()
    if not spawnUI.lastSpawnedClass or not spawnUI.lastSpawnedEntry then return end

    local ray = editor.getScreenToWorldRay()
    spawnUI.popupSpawnHit = editor.getRaySceneIntersection(ray, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), nil,  true)

    spawnUI.spawnNew(spawnUI.lastSpawnedEntry, spawnUI.lastSpawnedClass, spawnUI.lastSpawnedIsFavorite, spawnUI.lastSpawnedOptions)
    spawnUI.spawnedUI.cachePaths()
    spawnUI.popupSpawnHit = nil
end

---Builds popup search results for a specific type/variant.
---@param typeName string
---@param variantName string
function spawnUI.loadPopupData(typeName, variantName)
    local data = {}

    for _, entry in pairs(spawnData[typeName][variantName].data) do
        if utils.matchSearch(entry.name, spawnUI.popupFilter) then
            table.insert(data, entry)
        end
    end

    spawnUI.popupData = data
end

---Draws one popup variant submenu and handles spawn selection clicks.
---@param typeName string
---@param variantName string
function spawnUI.drawPopupVariant(typeName, variantName)
    local _, screenHeight = GetDisplayResolution()
    local popupSpawnList = spawnData[typeName][variantName]

    if spawnUI.currentPopupVariant ~= variantName then
        ImGui.SetKeyboardFocusHere()
        spawnUI.loadPopupData(typeName, variantName)
        spawnUI.currentPopupVariant = variantName
    end
    local popupFilterChanged
    spawnUI.popupFilter, popupFilterChanged = ImGui.InputTextWithHint('##Filter', 'Search...', spawnUI.popupFilter, 75)
    local xSpace, _ = ImGui.GetItemRectSize()
    if popupFilterChanged then
        spawnUI.loadPopupData(typeName, variantName)
    end

    if spawnUI.popupFilter ~= '' then
        ImGui.SameLine()

        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Close) then
            spawnUI.popupFilter = ''
            spawnUI.loadPopupData(typeName, variantName)
        end
        style.pushButtonNoBG(false)
        local x, _ = ImGui.GetItemRectSize()
        xSpace = xSpace + x + ImGui.GetStyle().ItemSpacing.x
    end

    if spawnUI.popupFilter ~= "" or #popupSpawnList.data < 100 then
        local y = #spawnUI.popupData * ImGui.GetFrameHeightWithSpacing()

        if ImGui.BeginChild("##list", xSpace, math.max(math.min(y, screenHeight / 2), 1)) then
            local clipper = ImGuiListClipper.new()
            clipper:Begin(#spawnUI.popupData, -1)

            while (clipper:Step()) do
                for i = clipper.DisplayStart + 1, clipper.DisplayEnd, 1 do
                    ImGui.PushID(spawnUI.popupData[i].name)
                    local secondaryIcon = getSearchResultSecondaryIcon(spawnUI.popupData[i], popupSpawnList)
                    local popupButtonText = formatSearchResultButtonText(
                        spawnUI.popupData[i].name,
                        xSpace - ImGui.GetStyle().ItemSpacing.x * 3,
                        secondaryIcon
                    )

                    if ImGui.Button(popupButtonText) then
                        if settings.spawnAtCursor then
                            if not spawnUI.popupSpawnHit then
                                local ray = editor.getScreenToWorldRay()
                                spawnUI.popupSpawnHit = editor.getRaySceneIntersection(ray, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), nil, true)
                            end
                        else
                            spawnUI.popupSpawnHit = nil
                        end
                        local class = popupSpawnList.class
                        spawnUI.popupData[i].lastSpawned = spawnUI.spawnNew(spawnUI.popupData[i], class, false)
                        ImGui.CloseCurrentPopup()
                    end
                    if ImGui.IsItemClicked(ImGuiMouseButton.Middle) then
                        ImGui.SetClipboardText(spawnUI.popupData[i].name)
                    end

                    ImGui.PopID()
                end
            end
            ImGui.EndChild()
        end
    end
end

---Draws and manages the quick spawn popup.
function spawnUI.drawPopup()
    local x, y = ImGui.GetMousePos()
    ImGui.SetNextWindowPos(x + 10 * style.viewSize, y - 4 * ImGui.GetFrameHeight(), ImGuiCond.Appearing)

    if ImGui.BeginPopup("##spawnNew") then
        local x, _ = ImGui.CalcTextSize("Reset search") + ImGui.GetStyle().ItemSpacing.x

        if not settings.spawnAtCursor then
           x = spawnUI.drawSpawnPosition()
        end
        ImGui.Text("At cursor")
        ImGui.SameLine()
        ImGui.SetCursorPosX(x)
        local spawnAtCursorChanged
        settings.spawnAtCursor, spawnAtCursorChanged = ImGui.Checkbox("##cursor", settings.spawnAtCursor)
        if spawnAtCursorChanged then settings.save() end
        style.tooltip("Spawn the object under the cursor.")

        ImGui.Text("Strip paths")
        ImGui.SameLine()
        ImGui.SetCursorPosX(x)
        local stripPathsChanged
        settings.spawnUIOnlyNames, stripPathsChanged = ImGui.Checkbox("##strip", settings.spawnUIOnlyNames)
        if stripPathsChanged then settings.save() end
        style.tooltip("Only show the name of the file, without the full path")

        ImGui.Text("Reset search")
        ImGui.SameLine()
        ImGui.SetCursorPosX(x)
        local resetSearchChanged
        settings.resetSpawnPopupSearch, resetSearchChanged = ImGui.Checkbox("##reset", settings.resetSpawnPopupSearch)
        if resetSearchChanged then settings.save() end
        style.tooltip("Resets the search when spawning something or closing the popup")

        ImGui.Separator()

        for _, typeName in pairs(typeNames) do
            if ImGui.BeginMenu(typeName) then
                local variantKeys = getSortedVariantNames(typeName)

                for _, variantName in pairs(variantKeys) do
                    if ImGui.BeginMenu(variantName) then
                        spawnUI.drawPopupVariant(typeName, variantName)
                        ImGui.EndMenu()
                    end
                end
                ImGui.EndMenu()
            end
        end

        ImGui.EndPopup()
    else
        spawnUI.popupSpawnHit = nil
    end

    if spawnUI.openPopup then
        spawnUI.openPopup = false
        spawnUI.currentPopupVariant = ""
        if settings.resetSpawnPopupSearch then
            spawnUI.popupFilter = ""
        end

        if settings.spawnAtCursor then
            local ray = editor.getScreenToWorldRay()
            spawnUI.popupSpawnHit = editor.getRaySceneIntersection(ray, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), nil, true)
        else
            spawnUI.popupSpawnHit = nil
        end

        ImGui.OpenPopup("##spawnNew")
    end

    spawnUI.favoritesUI.drawEditFavoritePopup()
end

return spawnUI
