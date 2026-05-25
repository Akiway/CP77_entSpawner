local history = require("modules/utils/history")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")

local appearanceHelper = {}

local GROUPED_APPEARANCES_ID = "groupedAppearances"
local GROUPED_APPEARANCE_SEARCH_HINT = "Search appearance..."

---@param spawnable spawnable?
---@param groupType string
---@return boolean
local function isAppearanceListLoaded(spawnable, groupType)
    if type(spawnable) ~= "table" then
        return false
    end

    if groupType == "Entity" then
        return spawnable.appsLoaded == true
    end

    if groupType == "Mesh" then
        return spawnable.bBoxLoaded == true
    end

    return false
end

---@param spawnable spawnable?
---@return string?
local function getAppearanceGroupType(spawnable)
    if type(spawnable) ~= "table" then
        return nil
    end

    local modulePath = tostring(spawnable.modulePath or "")

    if string.match(modulePath, "^entity/") or type(spawnable.defaultComponentData) == "table" then
        return "Entity"
    end

    if string.find(modulePath, "mesh", 1, true) or type(spawnable.generateCollider) == "function" then
        return "Mesh"
    end

    return nil
end

---@param entries element[]
---@return table[]
local function collectAppearanceGroups(entries)
    local groupsByKey = {}
    local groups = {}

    for _, entry in ipairs(entries) do
        local spawnable = entry and entry.spawnable
        local groupType = getAppearanceGroupType(spawnable)

        if groupType then
            local spawnData = spawnable.spawnData or ""
            local key = groupType .. "|" .. spawnData
            local group = groupsByKey[key]

            if not group then
                group = {
                    key = key,
                    type = groupType,
                    spawnData = spawnData,
                    entries = {}
                }
                groupsByKey[key] = group
                table.insert(groups, group)
            end

            table.insert(group.entries, entry)
        end
    end

    table.sort(groups, function(a, b)
        if a.type == b.type then
            return a.spawnData < b.spawnData
        end

        return a.type < b.type
    end)

    return groups
end

---@param element element
---@param entries element[]?
---@return string
local function buildSelectionSignature(element, entries)
    local sUI = element and element.sUI
    if type(sUI) ~= "table" or type(sUI.selectedPaths) ~= "table" then
        local parts = { "entries", tostring(type(entries) == "table" and #entries or 0) }
        if type(entries) == "table" then
            for _, entry in ipairs(entries) do
                parts[#parts + 1] = tostring(entry and entry.id or 0)
            end
        end
        return table.concat(parts, ":")
    end

    local parts = {
        tostring(#sUI.selectedPaths),
        tostring(sUI.cacheEpoch or 0)
    }

    for _, selected in ipairs(sUI.selectedPaths) do
        parts[#parts + 1] = tostring(selected and selected.ref and selected.ref.id or 0)
    end

    return table.concat(parts, ":")
end

---@param element element
---@param fallbackEntries element[]
---@return table[]
local function collectAppearanceGroupsFromSelection(element, fallbackEntries)
    local sUI = element and element.sUI

    if type(sUI) ~= "table" or type(sUI.selectedPaths) ~= "table" or type(sUI.getRoots) ~= "function" then
        return collectAppearanceGroups(fallbackEntries or {})
    end

    local roots = sUI.getRoots(sUI.selectedPaths)
    local selectedEntries = {}
    local selectedById = {}

    for _, root in pairs(roots) do
        local rootRef = root and root.ref

        if rootRef and not rootRef:isLocked() and not selectedById[rootRef.id] then
            selectedById[rootRef.id] = true
            table.insert(selectedEntries, rootRef)
        end

        if rootRef and type(rootRef.getPathsRecursive) == "function" then
            for _, pathEntry in pairs(rootRef:getPathsRecursive(true)) do
                local ref = pathEntry and pathEntry.ref
                if ref and not ref:isLocked() and not selectedById[ref.id] then
                    selectedById[ref.id] = true
                    table.insert(selectedEntries, ref)
                end
            end
        end
    end

    return collectAppearanceGroups(selectedEntries)
end

---@param element element
---@param entries element[]
---@param groupedData table
---@return table[]
local function getCachedAppearanceGroups(element, entries, groupedData)
    local signature = buildSelectionSignature(element, entries)
    local groupCache = groupedData.groupCache

    if groupCache and groupCache.signature == signature then
        return groupCache.groups
    end

    local groups = collectAppearanceGroupsFromSelection(element, entries)
    groupedData.groupCache = {
        signature = signature,
        groups = groups
    }

    local activeSelectors = {}
    for _, group in ipairs(groups) do
        activeSelectors[group.key] = true
    end

    for key, _ in pairs(groupedData.selectors) do
        if not activeSelectors[key] then
            groupedData.selectors[key] = nil
        end
    end

    if type(groupedData.selectorSearches) == "table" then
        for key, _ in pairs(groupedData.selectorSearches) do
            if not activeSelectors[key] then
                groupedData.selectorSearches[key] = nil
            end
        end
    end

    return groups
end

---@param group table
---@return table, string, boolean
local function getGroupDisplayState(group)
    local apps = nil
    local currentApp = nil
    local hasLoaded = false

    for _, entry in ipairs(group.entries) do
        local spawnable = entry and entry.spawnable

        if type(spawnable) == "table" then
            if currentApp == nil and type(spawnable.app) == "string" then
                currentApp = spawnable.app
            end

            if isAppearanceListLoaded(spawnable, group.type) then
                hasLoaded = true
            end

            if apps == nil and type(spawnable.apps) == "table" and #spawnable.apps > 0 then
                apps = spawnable.apps
            end
        end
    end

    return apps or {}, currentApp or "default", hasLoaded
end

---@param group table
---@return string
local function getGroupIcon(group)
    for _, entry in ipairs(group.entries or {}) do
        local spawnable = entry and entry.spawnable
        local icon = spawnable and spawnable.icon
        if type(icon) == "string" and icon ~= "" then
            return icon
        end
    end

    if group.type == "Entity" then
        return IconGlyphs.AlphaEBoxOutline
    elseif group.type == "Mesh" then
        return IconGlyphs.CubeOutline
    end

    return IconGlyphs.InformationOutline
end

---@param group table
---@param selectedApp string
---@return number
local function applyAppearanceToGroup(group, selectedApp)
    if not selectedApp or selectedApp == "" then
        return 0
    end

    local changedEntries = {}

    for _, entry in ipairs(group.entries) do
        local spawnable = entry and entry.spawnable
        if spawnable and spawnable.app ~= selectedApp then
            table.insert(changedEntries, entry)
        end
    end

    if #changedEntries == 0 then
        return 0
    end

    history.addAction(history.getMultiSelectChange(changedEntries))

    local nApplied = 0

    for _, entry in ipairs(changedEntries) do
        local spawnable = entry and entry.spawnable

        if spawnable then
            spawnable.app = selectedApp

            if type(spawnable.apps) == "table" then
                local appIndex = utils.indexValue(spawnable.apps, selectedApp)
                if appIndex > 0 then
                    spawnable.appIndex = appIndex - 1
                end
            end

            if group.type == "Entity" then
                spawnable.defaultComponentData = {}

                if spawnable:getEntity() then
                    spawnable:respawn()
                end
            elseif group.type == "Mesh" then
                local entity = spawnable:getEntity()

                if entity then
                    local component = entity:FindComponentByName("mesh")
                    if component then
                        component.meshAppearance = CName.new(spawnable.app)
                        component:LoadAppearance()
                    end

                    if spawnable.setOutline then
                        spawnable:setOutline(spawnable.outline or 0)
                    end
                end
            end

            nApplied = nApplied + 1
        end
    end

    return nApplied
end

---@param spawnable spawnable
---@return table
function appearanceHelper.getGroupedProperties(spawnable)
    return {
        name = "Appearances",
        id = GROUPED_APPEARANCES_ID,
        data = {
            selectors = {},
            selectorSearches = {}
        },
        draw = function(element, entries)
            local groupedData = element.groupOperationData[GROUPED_APPEARANCES_ID]

            if not groupedData then
                groupedData = {
                    selectors = {},
                    selectorSearches = {}
                }
                element.groupOperationData[GROUPED_APPEARANCES_ID] = groupedData
            elseif not groupedData.selectors then
                groupedData.selectors = {}
            end

            if not groupedData.selectorSearches then
                groupedData.selectorSearches = {}
            end

            local groups = getCachedAppearanceGroups(element, entries, groupedData)

            if #groups == 0 then
                style.mutedText("No matching entity or mesh entries in selection.")
                return
            end

            for _, group in ipairs(groups) do
                local apps, currentApp, hasLoaded = getGroupDisplayState(group)
                local appCount = #apps
                local fullPath = tostring(group.spawnData or "")
                if fullPath == "" then
                    fullPath = "Unknown asset"
                end
                local hasBackslashes = string.find(fullPath, "\\", 1, true) ~= nil
                local pathLabel = utils.shortenPath(fullPath, 190 * style.viewSize, hasBackslashes)
                local label = string.format("%s %s", getGroupIcon(group), pathLabel)

                style.mutedText(label)
                style.tooltip(fullPath)

                ImGui.SameLine()
                ImGui.SetCursorPosX(255 * style.viewSize)
                style.mutedText(string.format("(%s)", #group.entries))

                ImGui.SameLine()
                ImGui.SetCursorPosX(280 * style.viewSize)
                ImGui.PushID(group.key)
                local comboWidth = 160 * style.viewSize

                if appCount == 0 then
                    style.pushGreyedOut(true)
                    local loading = { hasLoaded and "No Apps" or "Loading..." }
                    ImGui.SetNextItemWidth(comboWidth)
                    ImGui.Combo("##groupAppearance", 0, loading, 1)
                    style.popGreyedOut(true)
                    style.tooltip(hasLoaded and "No appearances available for this asset." or "Appearances are loading for this asset.")
                else
                    local selectedApp = groupedData.selectors[group.key]
                    local selectedIndex = utils.indexValue(apps, selectedApp)

                    if selectedIndex < 0 then
                        local currentIndex = utils.indexValue(apps, currentApp)
                        if currentIndex > 0 then
                            selectedApp = apps[currentIndex]
                        else
                            selectedApp = apps[1]
                        end
                    end

                    local searchValue = groupedData.selectorSearches[group.key] or ""
                    selectedApp, searchValue, _ = style.trackedSearchDropdown(
                        "##groupAppearance",
                        GROUPED_APPEARANCE_SEARCH_HINT,
                        selectedApp,
                        searchValue,
                        apps,
                        {
                            width = comboWidth / style.viewSize,
                            matchContentWidth = true
                        }
                    )
                    groupedData.selectors[group.key] = selectedApp
                    groupedData.selectorSearches[group.key] = searchValue
                    style.tooltip("Select an appearance to apply to all matching selected entries.")

                    ImGui.SameLine()
                    if ImGui.Button("Apply") then
                        local nApplied = applyAppearanceToGroup(group, selectedApp)
                        local toastType = nApplied > 0 and ImGui.ToastType.Success or ImGui.ToastType.Warning
                        local message = nApplied > 0
                            and string.format("Applied appearance '%s' to %s %s entries", selectedApp, nApplied, string.lower(group.type))
                            or string.format("No %s entries were updated", string.lower(group.type))

                        ImGui.ShowToast(ImGui.Toast.new(
                            toastType,
                            2500,
                            message
                        ))
                    end
                end

                ImGui.PopID()
            end
        end,
        entries = { spawnable.object }
    }
end

return appearanceHelper
