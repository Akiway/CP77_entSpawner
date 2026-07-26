local style = require("modules/ui/style")
local field = require("modules/utils/field")
local utils = require("modules/utils/utils")
local settings = require("modules/utils/settings")
local input = require("modules/utils/input")
local Cron = require("modules/utils/Cron")
local editor = require("modules/utils/editor/editor")
local logger = require("modules/utils/logger")
local assetFavorites = require("modules/utils/assetFavorites")
local prefabsUI = require("modules/ui/prefabsUI")

local SPAWN_OPTIONS_POPIN_ID = "##assetFavoritesSpawnOptionsPopin"
local NO_TAG_GROUP_KEY = "\1noTag"
-- Breathing room between an asset name and its tag icons
local TAG_ICONS_LEFT_MARGIN = 12

---Spawn New > Favorites sub-tab.
---Favorites are bookmarks to assets of the "All" sub-tab, organized with tags.
---They never carry any configuration, unlike prefabs.
---@class favoritesUI
---@field spawnUI spawnUI?
---@field tagFilterSearch string
---@field editTagSearch string
---@field editNewTag string
---@field editNewTagIcon string
---@field editNewTagIconSearch string
---@field popupEntry assetFavoriteEntry?
---@field openEntryPopup boolean
---@field popupTagName string?
---@field openTagPopup boolean
---@field tagEditName string
---@field tagEditIconSearch string
local favoritesUI = {
    spawnUI = nil,

    tagFilterSearch = "",
    editTagSearch = "",
    editNewTag = "",
    editNewTagIcon = assetFavorites.defaultTagIcon,
    editNewTagIconSearch = "",

    popupEntry = nil,
    openEntryPopup = false,

    popupTagName = nil,
    openTagPopup = false,
    tagEditName = "",
    tagEditIconSearch = "",

    filterSaveTimer = nil
}

local moduleIconCache = {}

---@param spawner spawner
function favoritesUI.init(spawner)
    favoritesUI.spawnUI = spawner.baseUI.spawnUI

    assetFavorites.load()
end

---Reloads favorites from disk, dropping any cached derived state.
function favoritesUI.reload()
    moduleIconCache = {}
    assetFavorites.load()
end

local function scheduleFilterSave()
    if favoritesUI.filterSaveTimer then
        Cron.Halt(favoritesUI.filterSaveTimer)
    end

    favoritesUI.filterSaveTimer = Cron.After(0.35, function ()
        settings.save()
        favoritesUI.filterSaveTimer = nil
    end)
end

local function flushFilterSave()
    if favoritesUI.filterSaveTimer then
        Cron.Halt(favoritesUI.filterSaveTimer)
        favoritesUI.filterSaveTimer = nil
    end

    settings.save()
end

---@param modulePath string
---@return table? spawnList
local function getSpawnList(modulePath)
    if not favoritesUI.spawnUI then
        return nil
    end

    return favoritesUI.spawnUI.getSpawnListByModulePath(modulePath)
end

---Resolves (and caches) the glyph used for one spawnable module.
---@param modulePath string
---@return string
local function getModuleIcon(modulePath)
    if moduleIconCache[modulePath] ~= nil then
        return moduleIconCache[modulePath]
    end

    local icon = ""
    local spawnList = getSpawnList(modulePath)

    if spawnList and spawnList.class then
        local okInstance, instance = pcall(function ()
            return spawnList.class:new()
        end)

        if okInstance and instance and type(instance.icon) == "string" then
            icon = instance.icon
        end
    end

    if icon == "" then
        icon = IconGlyphs.CubeOutline
    end

    moduleIconCache[modulePath] = icon

    return icon
end

---Human readable "Type > Variant" label of the list an asset belongs to.
---@param modulePath string
---@return string
local function getVariantLabel(modulePath)
    if not favoritesUI.spawnUI then
        return modulePath
    end

    return favoritesUI.spawnUI.getVariantLabelByModulePath(modulePath) or modulePath
end

---Tooltip body listing the tags of one favorite.
---@param entry assetFavoriteEntry
---@return string
function favoritesUI.getTagsText(entry)
    local tags = assetFavorites.getEntryTags(entry)

    if #tags == 0 then
        return "No tags"
    end

    return "Tags: " .. table.concat(tags, ", ")
end

---@param entry assetFavoriteEntry
---@return boolean
local function matchesFilters(entry)
    if not utils.matchSearch(entry.path, settings.assetFavoritesFilter) then
        return false
    end

    local tagFilter = settings.assetFavoritesFilterTags
    if utils.tableLength(tagFilter) == 0 then
        return true
    end

    for tag, isSelected in pairs(tagFilter) do
        if isSelected then
            if entry.tags[tag] and not settings.assetFavoritesTagsAND then return true end
            if not entry.tags[tag] and settings.assetFavoritesTagsAND then return false end
        end
    end

    return settings.assetFavoritesTagsAND
end

---Groups the filtered favorites by tag, mirroring how prefab categories are listed.
---Favorites carrying several tags show up in each matching group.
---@param tagName string
---@return table
local function createTagGroup(tagName)
    return {
        key = tagName,
        name = tagName,
        icon = assetFavorites.getTagGlyph(tagName),
        isNoTag = false,
        entries = {}
    }
end

---@return {key: string, name: string, icon: string, isNoTag: boolean, entries: assetFavoriteEntry[]}[]
local function buildTagGroups()
    local groupsByKey = {}
    local noTagEntries = {}
    local tagUsage = {}

    for _, entry in ipairs(assetFavorites.getEntries()) do
        local tags = assetFavorites.getEntryTags(entry)

        for _, tag in ipairs(tags) do
            tagUsage[tag] = (tagUsage[tag] or 0) + 1
        end

        if matchesFilters(entry) then
            if #tags == 0 then
                table.insert(noTagEntries, entry)
            else
                for _, tag in ipairs(tags) do
                    local group = groupsByKey[tag]
                    if not group then
                        group = createTagGroup(tag)
                        groupsByKey[tag] = group
                    end

                    table.insert(group.entries, entry)
                end
            end
        end
    end

    -- Tags nothing is tagged with stay listed, otherwise their settings popup
    -- (rename / icon / delete) would be unreachable.
    for _, tag in ipairs(assetFavorites.getTagNames()) do
        if not groupsByKey[tag] and (tagUsage[tag] or 0) == 0 then
            groupsByKey[tag] = createTagGroup(tag)
        end
    end

    local groups = {}
    for _, group in pairs(groupsByKey) do
        table.insert(groups, group)
    end

    table.sort(groups, function (a, b) return string.lower(a.name) < string.lower(b.name) end)

    if #noTagEntries > 0 then
        table.insert(groups, {
            key = NO_TAG_GROUP_KEY,
            name = assetFavorites.noTagGroupName,
            icon = IconGlyphs.TagOffOutline,
            isNoTag = true,
            entries = noTagEntries
        })
    end

    for _, group in ipairs(groups) do
        table.sort(group.entries, function (a, b)
            if a.name == b.name then
                return a.path < b.path
            end

            return string.lower(a.name) < string.lower(b.name)
        end)
    end

    return groups
end

---@param groupKey string
---@return boolean
local function isGroupOpen(groupKey)
    if type(settings.assetFavoritesGroupOpen) ~= "table" then
        settings.assetFavoritesGroupOpen = {}
    end

    return settings.assetFavoritesGroupOpen[groupKey] == true
end

---@param groupKey string
---@param open boolean
local function setGroupOpen(groupKey, open)
    if type(settings.assetFavoritesGroupOpen) ~= "table" then
        settings.assetFavoritesGroupOpen = {}
    end

    if isGroupOpen(groupKey) == (open == true) then
        return
    end

    -- Closed is the default, so only opened groups are persisted.
    settings.assetFavoritesGroupOpen[groupKey] = open == true or nil
    settings.save()
end

---Opens or closes every tag group at once, with a single settings write.
---@param open boolean
local function setAllGroupsOpen(open)
    if not open then
        settings.assetFavoritesGroupOpen = {}
        settings.save()
        return
    end

    local state = {}
    for _, tag in ipairs(assetFavorites.getTagNames()) do
        state[tag] = true
    end
    state[NO_TAG_GROUP_KEY] = true

    settings.assetFavoritesGroupOpen = state
    settings.save()
end

---Draws the expand all / collapse all row shown above the favorites list.
local function drawExpandCollapseRow()
    local hasGroups = assetFavorites.getCount() > 0 or #assetFavorites.getTagNames() > 0

    style.drawExpandCollapseButtons(
        "assetFavoritesList",
        function () setAllGroupsOpen(true) end,
        function () setAllGroupsOpen(false) end,
        {
            disabled = not hasGroups,
            expandTooltip = "Expand all tags",
            collapseTooltip = "Collapse all tags"
        }
    )

    ImGui.Separator()
end

---Moves the persisted open state of one tag group to another key.
---@param oldKey string
---@param newKey string?
local function transferGroupOpenState(oldKey, newKey)
    if type(settings.assetFavoritesGroupOpen) ~= "table" then
        return
    end

    if settings.assetFavoritesGroupOpen[oldKey] == nil then
        return
    end

    settings.assetFavoritesGroupOpen[oldKey] = nil
    if newKey then
        settings.assetFavoritesGroupOpen[newKey] = true
    end
    settings.save()
end

---Removes tag filter selections whose tag no longer exists.
local function pruneTagFilterSelections()
    if type(settings.assetFavoritesFilterTags) ~= "table" then
        settings.assetFavoritesFilterTags = {}
        return
    end

    local changed = false
    for tag, _ in pairs(settings.assetFavoritesFilterTags) do
        if not assetFavorites.hasTag(tag) then
            settings.assetFavoritesFilterTags[tag] = nil
            changed = true
        end
    end

    if changed then
        settings.save()
    end
end

---@param tagName string
---@param searchValue string
---@return boolean
local function matchesTagOption(tagName, searchValue)
    local search = string.lower(tostring(searchValue or ""))
    if search == "" then
        return true
    end

    return utils.safePatternMatch(string.lower(tostring(tagName or "")), search)
end

---@param selections table<string, boolean>?
---@param allLabel string
---@param multiLabelFormat string
---@return string
local function getTagSelectionPreviewLabel(selections, allLabel, multiLabelFormat)
    local selected = {}

    for tag, isSelected in pairs(selections or {}) do
        if isSelected == true then
            table.insert(selected, tostring(tag))
        end
    end

    table.sort(selected, function (a, b) return string.lower(a) < string.lower(b) end)

    if #selected == 0 then
        return allLabel
    end

    if #selected == 1 then
        return assetFavorites.getTagGlyph(selected[1]) .. " " .. selected[1]
    end

    return string.format(multiLabelFormat, #selected)
end

---Draws the shared searchable tag multi-select combo, with icons per tag.
---When `opts.allowCreate` is set, the create row also carries an icon selector
---so a new tag is created with its icon in one go.
---@param selections table<string, boolean>
---@param idScope string
---@param searchValue string
---@param opts table?
---@return boolean changed
---@return string searchValue
---@return string createValue
---@return string createIcon
---@return string createIconSearch
local function drawTagSelectorCombo(selections, idScope, searchValue, opts)
    opts = opts or {}

    local options = assetFavorites.getTagNames()
    local preview = getTagSelectionPreviewLabel(selections, opts.allLabel or "No tags", opts.multiLabel or "%d tags selected")
    local _, screenHeight = GetDisplayResolution()
    local maxPopupHeight = math.max(200 * style.viewSize, math.min(520 * style.viewSize, screenHeight - 16))

    return style.drawSearchableMultiSelectCombo({
        comboId = "##" .. idScope .. "Combo",
        previewLabel = preview,
        searchHint = "Search tag...",
        searchValue = searchValue,
        options = options,
        selections = selections,
        comboWidth = (opts.comboWidth or 200) * style.viewSize,
        searchWidth = 220 * style.viewSize,
        maxPopupHeight = maxPopupHeight,
        emptyText = "No tags available",
        noMatchText = "No matching tags",
        searchInputId = "##" .. idScope .. "Search",
        searchClearButtonId = "##" .. idScope .. "SearchClear",
        selectAllButtonId = "##" .. idScope .. "SelectAll",
        unselectAllButtonId = "##" .. idScope .. "UnselectAll",
        optionIdPrefix = "##" .. idScope .. "Option",
        selectAllTooltip = "Select all tags",
        unselectAllTooltip = opts.unselectAllTooltip or "Unselect all tags",
        showClearSelectionButton = opts.showClearSelectionButton == true,
        clearSelectionButtonId = "##" .. idScope .. "ClearSelection",
        clearSelectionTooltip = "Clear selected tags",
        showAndFilterToggle = opts.showAndFilterToggle == true,
        andFilterState = settings.assetFavoritesTagsAND,
        andFilterTooltip = "AND filter mode (Leave off for OR filter)",
        onAndFilterChanged = function (nextAndFilter)
            settings.assetFavoritesTagsAND = nextAndFilter
            settings.save()
        end,
        allowCreate = opts.allowCreate == true,
        createHint = "New tag...",
        createValue = opts.createValue or "",
        createInputId = "##" .. idScope .. "Create",
        createButtonId = "##" .. idScope .. "CreateAdd",
        createIcon = opts.allowCreate == true and (opts.createIcon or assetFavorites.defaultTagIcon) or nil,
        createIconSearch = opts.createIconSearch or "",
        createIconPickerId = idScope .. "CreateIcon",
        onCreate = function (name, iconKey)
            assetFavorites.createTag(name, iconKey)
            selections[name] = true
        end,
        getOptionLabel = function (option)
            return assetFavorites.getTagGlyph(option) .. " " .. tostring(option)
        end,
        matchesOption = function (option, search)
            return matchesTagOption(option, search)
        end
    })
end

---@param label string
local function drawFieldLabel(label)
    ImGui.AlignTextToFramePadding()
    style.mutedText(label)
    ImGui.SameLine()
end

---Stages the favorite settings popup for one entry.
---The popup itself is drawn by `favoritesUI.drawPopups`, so this works from any tab.
---@param entry assetFavoriteEntry
function favoritesUI.openEntrySettings(entry)
    favoritesUI.openEntryPopup = true
    favoritesUI.popupEntry = entry
    favoritesUI.editTagSearch = ""
    favoritesUI.editNewTag = ""
    favoritesUI.editNewTagIcon = assetFavorites.defaultTagIcon
    favoritesUI.editNewTagIconSearch = ""
end

---Marks an asset as favorite / removes it, from any context menu.
---Adding opens the settings popup right away so tags can be assigned on the spot.
---@param modulePath string
---@param path string
---@param name string?
---@param data table?
---@return boolean isFavoriteNow
function favoritesUI.toggleFavorite(modulePath, path, name, data)
    if assetFavorites.isFavorite(modulePath, path) then
        assetFavorites.remove(modulePath, path)
        logger:info(string.format("[%s] Removed \"%s\" from favorites", settings.mainWindowName, tostring(path)))
        return false
    end

    local entry = assetFavorites.add(modulePath, path, name, data)
    if not entry then
        return false
    end

    logger:info(string.format("[%s] Added \"%s\" to favorites", settings.mainWindowName, tostring(path)))
    favoritesUI.openEntrySettings(entry)

    return true
end

---Draws the "Add to favorites" / "Remove from favorites" context menu item.
---@param modulePath string?
---@param path string?
---@param name string?
---@param data table?
---@param idSuffix string?
---@return boolean clicked
function favoritesUI.drawContextMenuItem(modulePath, path, name, data, idSuffix)
    if type(modulePath) ~= "string" or modulePath == "" or type(path) ~= "string" or path == "" then
        return false
    end

    local isFavorite = assetFavorites.isFavorite(modulePath, path)
    local label, hiddenText = style.resolveActionLabelNoIconOnly(
        IconGlyphs.StarBoxOutline,
        isFavorite and "Remove from favorites" or "Add to favorites",
        "assetFavoriteToggle" .. tostring(idSuffix or ""),
        nil,
        true
    )

    local clicked = ImGui.MenuItem(label)
    style.tooltipActionLabel(hiddenText)

    if clicked then
        favoritesUI.toggleFavorite(modulePath, path, name, data)
    end

    return clicked
end

---Spawns one favorite, reusing the regular Spawn New pipeline.
---@param entry assetFavoriteEntry
---@return any
local function spawnFavorite(entry)
    local spawnList = getSpawnList(entry.modulePath)

    if not spawnList then
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Warning, 2500, "Cannot spawn: unknown asset type"))
        logger:warn(string.format("[Asset Favorites] No spawn list found for module path \"%s\"", tostring(entry.modulePath)))
        return nil
    end

    return favoritesUI.spawnUI.spawnNew({
        data = entry.data,
        name = entry.path,
        fileName = entry.name
    }, spawnList.class, false)
end

---Popup used to edit the tags of one favorite.
local function drawEntryPopup()
    local entry = favoritesUI.popupEntry
    if not entry then return end

    local popupId = "##assetFavoriteSettings"

    if ImGui.IsPopupOpen(popupId) then
        style.setCursorRelativeAppearing(-5, -5)
    end

    if ImGui.BeginPopup(popupId) then
        input.updateContext("main")

        style.popupTitle(IconGlyphs.StarBoxOutline, "Favorite Settings")

        drawFieldLabel("Asset")
        ImGui.AlignTextToFramePadding()
        ImGui.Text(entry.name)
        style.tooltip(entry.path)

        drawFieldLabel("Type")
        ImGui.AlignTextToFramePadding()
        style.mutedText(getVariantLabel(entry.modulePath))

        drawFieldLabel("Tags")
        local tagsChanged
        tagsChanged, favoritesUI.editTagSearch, favoritesUI.editNewTag, favoritesUI.editNewTagIcon, favoritesUI.editNewTagIconSearch = drawTagSelectorCombo(
            entry.tags,
            "assetFavoriteEditTags",
            favoritesUI.editTagSearch,
            {
                allowCreate = true,
                createValue = favoritesUI.editNewTag,
                createIcon = favoritesUI.editNewTagIcon,
                createIconSearch = favoritesUI.editNewTagIconSearch,
                showClearSelectionButton = true
            }
        )
        if tagsChanged then
            assetFavorites.save()
        end

        ImGui.Separator()

        if ImGui.Button(IconGlyphs.CheckboxMarkedCircleOutline .. " Close") then
            favoritesUI.popupEntry = nil
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.StarBoxOutline .. " Remove from favorites") then
            favoritesUI.toggleFavorite(entry.modulePath, entry.path)
            favoritesUI.popupEntry = nil
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    elseif not favoritesUI.openEntryPopup then
        favoritesUI.popupEntry = nil
    end

    if favoritesUI.openEntryPopup then
        favoritesUI.openEntryPopup = false
        ImGui.OpenPopup(popupId)
    end
end

---Popup used to rename / re-icon / delete one tag.
local function drawTagPopup()
    local tagName = favoritesUI.popupTagName
    if not tagName then return end

    local popupId = "##assetFavoriteTagSettings"

    if ImGui.IsPopupOpen(popupId) then
        style.setCursorRelativeAppearing(-5, -5)
    end

    if ImGui.BeginPopup(popupId) then
        input.updateContext("main")

        style.popupTitle(IconGlyphs.TagOutline, "Tag Settings")

        local iconKey, iconSearch, iconChanged = field.drawIconSelector(
            "assetFavoriteTag:" .. tagName,
            assetFavorites.getTagIconKey(tagName),
            favoritesUI.tagEditIconSearch
        )
        favoritesUI.tagEditIconSearch = iconSearch
        if iconChanged then
            assetFavorites.setTagIcon(tagName, iconKey)
        end

        ImGui.SameLine()

        style.setNextItemWidth(200)
        favoritesUI.tagEditName, _ = ImGui.InputTextWithHint("##tagName", "Tag name...", favoritesUI.tagEditName, 100)

        local newName = utils.trimString(favoritesUI.tagEditName)
        local nameTaken = newName ~= tagName and assetFavorites.hasTag(newName)

        if ImGui.IsItemDeactivatedAfterEdit() and newName ~= "" and newName ~= tagName and not nameTaken then
            assetFavorites.renameTag(tagName, newName)

            if settings.assetFavoritesFilterTags[tagName] then
                settings.assetFavoritesFilterTags[tagName] = nil
                settings.assetFavoritesFilterTags[newName] = true
                settings.save()
            end

            transferGroupOpenState(tagName, newName)
            favoritesUI.popupTagName = newName
            tagName = newName
        end

        if nameTaken then
            ImGui.SameLine()
            style.styledText(IconGlyphs.AlertOutline, 0xFF0000FF)
            style.tooltip("A tag with this name already exists.")
        end

        style.mutedText(string.format("Used by %d favorite(s)", assetFavorites.getTagUsageCount(tagName)))

        ImGui.Separator()

        if ImGui.Button(IconGlyphs.CheckboxMarkedCircleOutline .. " Close") then
            favoritesUI.popupTagName = nil
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline .. " Delete tag") then
            assetFavorites.deleteTag(tagName)
            settings.assetFavoritesFilterTags[tagName] = nil
            settings.save()
            transferGroupOpenState(tagName, nil)
            favoritesUI.popupTagName = nil
            ImGui.CloseCurrentPopup()
        end
        style.tooltip("Removes this tag from every favorite. The favorites themselves are kept.")

        ImGui.EndPopup()
    elseif not favoritesUI.openTagPopup then
        favoritesUI.popupTagName = nil
    end

    if favoritesUI.openTagPopup then
        favoritesUI.openTagPopup = false
        ImGui.OpenPopup(popupId)
    end
end

---Draws the favorite / tag settings popups.
---Called outside of the sub-tab so favorites added from the "All" or "Spawned" tab
---still get their settings popup.
function favoritesUI.drawPopups()
    drawEntryPopup()
    drawTagPopup()
end

---Right aligned settings button of one favorite.
---@param entry assetFavoriteEntry
local function drawEntrySideButtons(entry)
    local settingsX, _ = ImGui.CalcTextSize(IconGlyphs.CogOutline)
    local totalX = settingsX + ImGui.GetStyle().ItemSpacing.x
    local scrollBarAddition = ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0
    local cursorX = ImGui.GetWindowWidth() - totalX - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()

    ImGui.SetCursorPosX(cursorX)
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 1 * style.viewSize)

    ImGui.SetNextItemAllowOverlap()
    if ImGui.Button(IconGlyphs.CogOutline) then
        favoritesUI.openEntrySettings(entry)
    end
    style.tooltip("Favorite settings")
end

---@param entry assetFavoriteEntry
---@param context table
local function drawEntry(entry, context)
    prefabsUI.pushRow(context)

    ImGui.PushID(context.row)

    ImGui.SetCursorPosX(context.depth * 17 * style.viewSize)
    ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 4 * style.viewSize, context.padding * 2 + style.viewSize)

    local spawnUI = favoritesUI.spawnUI
    local spawnList = getSpawnList(entry.modulePath)

    if ImGui.Selectable("##assetFavorite" .. context.row, false, ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowOverlap) then
        spawnFavorite(entry)
    elseif ImGui.IsMouseDragging(0, style.draggingThreshold) and not spawnUI.dragging and ImGui.IsItemHovered() then
        spawnUI.dragging = true
        spawnUI.dragData = { data = entry.data, name = entry.name }
    elseif not ImGui.IsMouseDragging(0, style.draggingThreshold) and spawnUI.dragging then
        if not ImGui.IsItemHovered() then
            local ray = editor.getScreenToWorldRay()
            spawnUI.popupSpawnHit = editor.getRaySceneIntersection(ray, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), nil, true)

            spawnFavorite(entry)
        end

        spawnUI.dragging = false
        spawnUI.dragData = nil
        spawnUI.popupSpawnHit = nil
    end

    if ImGui.BeginPopupContextItem("##assetFavoriteContext", ImGuiPopupFlags.MouseButtonRight) then
        if spawnList and ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.Group, "Save as prefab", "assetFavoriteSavePrefab")) then
            spawnUI.savePrefabFromEntry({ data = entry.data, name = entry.path, fileName = entry.name }, spawnList.class)
        end

        favoritesUI.drawContextMenuItem(entry.modulePath, entry.path, entry.name, entry.data, "Row")

        ImGui.Separator()

        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ContentCopy, "Copy path", "assetFavoriteCopyPath")) then
            ImGui.SetClipboardText(entry.path)
        end

        ImGui.EndPopup()
    end

    -- Asset preview, using the spawn list the favorite belongs to
    if spawnList and ImGui.IsItemHovered() and settings.assetPreviewEnabled[entry.modulePath] then
        spawnUI.handleAssetPreviewHovered(entry, false, spawnList)
    elseif spawnUI.hoveredEntry == entry and (spawnUI.previewInstance or spawnUI.previewTimer) then
        spawnUI.hoveredEntry = nil
        spawnUI.stopActiveAssetPreview()
    end

    context.row = context.row + 1

    ImGui.SameLine()
    ImGui.PushStyleColor(ImGuiCol.Button, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.2)
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
    ImGui.PushStyleVar(ImGuiStyleVar.ButtonTextAlign, 0.5, 0.5)
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 1 * style.viewSize)

    ImGui.SetNextItemAllowOverlap()
    ImGui.AlignTextToFramePadding()
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 2 * style.viewSize)
    ImGui.Text(getModuleIcon(entry.modulePath))

    ImGui.SameLine()
    ImGui.AlignTextToFramePadding()
    ImGui.SetNextItemAllowOverlap()
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 1 * style.viewSize)
    ImGui.Text(entry.name)
    style.tooltip(string.format("%s\n%s\n%s", entry.path, getVariantLabel(entry.modulePath), favoritesUI.getTagsText(entry)))

    local tags = assetFavorites.getEntryTags(entry)
    if #tags > 0 then
        ImGui.SameLine()
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() + TAG_ICONS_LEFT_MARGIN * style.viewSize)
        ImGui.AlignTextToFramePadding()
        ImGui.SetNextItemAllowOverlap()

        local glyphs = {}
        for _, tag in ipairs(tags) do
            table.insert(glyphs, assetFavorites.getTagGlyph(tag))
        end

        style.mutedText(table.concat(glyphs, " "))
        style.tooltip(favoritesUI.getTagsText(entry))
    end

    ImGui.SameLine()
    drawEntrySideButtons(entry)

    ImGui.PopStyleColor(2)
    ImGui.PopStyleVar(3)

    ImGui.PopID()
end

---@param group table
local function drawGroupSideButtons(group)
    if group.isNoTag then return end

    local settingsX, _ = ImGui.CalcTextSize(IconGlyphs.CogOutline)
    local totalX = settingsX + ImGui.GetStyle().ItemSpacing.x
    local scrollBarAddition = ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0
    local cursorX = ImGui.GetWindowWidth() - totalX - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()

    ImGui.SetCursorPosX(cursorX)
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 2 * (ImGui.GetFontSize() / 15))

    ImGui.SetNextItemAllowOverlap()
    if ImGui.Button(IconGlyphs.CogOutline) then
        favoritesUI.openTagPopup = true
        favoritesUI.popupTagName = group.name
        favoritesUI.tagEditName = group.name
        favoritesUI.tagEditIconSearch = ""
    end
    style.tooltip("Tag settings")
end

---@param group table
---@param context table
local function drawGroup(group, context)
    prefabsUI.pushRow(context)

    ImGui.PushID(context.row)

    ImGui.SetCursorPosX(context.depth * 17 * style.viewSize)
    ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 4 * style.viewSize, context.padding * 2 + style.viewSize)

    local open = isGroupOpen(group.key)

    local newState = ImGui.Selectable("##assetFavoriteGroup" .. context.row, open, ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowOverlap)
    if newState ~= open then
        open = newState
        setGroupOpen(group.key, open)
    end
    context.row = context.row + 1

    ImGui.SameLine()
    ImGui.PushStyleColor(ImGuiCol.Button, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.2)
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
    ImGui.PushStyleVar(ImGuiStyleVar.ButtonTextAlign, 0.5, 0.5)
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 1 * style.viewSize)

    ImGui.SetNextItemAllowOverlap()
    if ImGui.Button(open and IconGlyphs.MenuDownOutline or IconGlyphs.MenuRightOutline) then
        open = not open
        setGroupOpen(group.key, open)
    end

    ImGui.SameLine()
    ImGui.AlignTextToFramePadding()
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 2 * style.viewSize)
    ImGui.Text(group.icon)

    ImGui.SameLine()
    ImGui.AlignTextToFramePadding()
    ImGui.SetNextItemAllowOverlap()
    ImGui.Text(string.format("%s (%d)", group.name, #group.entries))

    ImGui.SameLine()
    drawGroupSideButtons(group)

    ImGui.PopStyleColor(2)
    ImGui.PopStyleVar(3)

    ImGui.PopID()

    if not open then return end

    context.depth = context.depth + 1
    for _, entry in ipairs(group.entries) do
        drawEntry(entry, context)
    end
    context.depth = context.depth - 1
end

---Draws the favorites list, using the same table / row layout as the prefabs list.
function favoritesUI.drawMain()
    local cellPadding = 3 * style.viewSize
    local _, y = ImGui.GetContentRegionAvail()
    y = math.max(y, 300 * style.viewSize)
    local nRows = math.floor(y / prefabsUI.getRowHeight(cellPadding))

    local context = {
        row = 0,
        depth = 0,
        padding = cellPadding
    }

    local groups = buildTagGroups()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, 7.5 * style.viewSize, cellPadding)
    ImGui.PushStyleVar(ImGuiStyleVar.ScrollbarSize, 12 * style.viewSize)

    local hasVisibleEntry = false
    for _, group in ipairs(groups) do
        if #group.entries > 0 then
            hasVisibleEntry = true
            break
        end
    end

    if ImGui.BeginChild("##assetFavoritesList", -1, y, false) then
        if assetFavorites.getCount() == 0 then
            style.mutedText("No favorites yet. Right click an asset in the \"All\" sub-tab and pick \"Add to favorites\".")
        elseif not hasVisibleEntry then
            style.mutedText("No favorite matches the current filters.")
        end

        if ImGui.BeginTable("##assetFavoritesListTable", 1, ImGuiTableFlags.ScrollX or ImGuiTableFlags.NoHostExtendX) then
            for _, group in ipairs(groups) do
                context.depth = 0
                drawGroup(group, context)
            end

            if context.row < nRows then
                for _ = context.row, nRows - 1 do
                    prefabsUI.pushRow(context)
                    context.row = context.row + 1
                end
            end

            ImGui.EndTable()
        end
        ImGui.EndChild()
    end

    ImGui.PopStyleVar(2)
end

---Draws the target group selector plus the options button, on one line.
local function drawSpawnOptionsRow()
    favoritesUI.spawnUI.drawTargetGroupSelector()
    favoritesUI.spawnUI.drawOptionsButton(
        "##assetFavoritesSpawnOptionsButton",
        SPAWN_OPTIONS_POPIN_ID,
        favoritesUI.spawnUI.drawSpawnPosition,
        "Favorites options"
    )
end

function favoritesUI.draw()
    if not favoritesUI.spawnUI then return end

    if type(settings.assetFavoritesFilterTags) ~= "table" then
        settings.assetFavoritesFilterTags = {}
    end
    if type(settings.assetFavoritesFilter) ~= "string" then
        settings.assetFavoritesFilter = ""
    end
    pruneTagFilterSelections()

    style.styledTextWrapped(
        "Favorites are shortcuts to assets you use often. Unlike prefabs they store no configuration, only a reference to the asset itself. " ..
        "Mark any asset as favorite from the \"All\" sub-tab or from the \"Spawned\" tab context menu, then organize them with tags.",
        style.mutedColor
    )

    style.spacedSeparator()

    drawSpawnOptionsRow()

    style.spacedSeparator()

    ImGui.SetNextItemWidth(300 * style.viewSize)
    local filterChanged
    settings.assetFavoritesFilter, filterChanged = ImGui.InputTextWithHint("##assetFavoritesFilter", "Search by name... (Supports pattern matching)", settings.assetFavoritesFilter, 100)
    if filterChanged then
        scheduleFilterSave()
    end

    if style.drawNoBGConditionalButton(settings.assetFavoritesFilter ~= "", IconGlyphs.Close) then
        settings.assetFavoritesFilter = ""
        flushFilterSave()
    end

    ImGui.SameLine()
    style.mutedText(IconGlyphs.InformationOutline)
    style.tooltip("Supports custom search query syntax:\n- | (OR), includes any terms including the word after the |\n- ! (NOT), excludes any terms including the word after the !\n- & (AND), terms must include the word after the &\n- E.g. table|chair!poor&low to match any terms that include 'table' or 'chair', but not 'poor', and must include 'low'")

    ImGui.SameLine()
    ImGui.SetCursorPosX(ImGui.GetWindowWidth() - 25 * style.viewSize)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload .. "##assetFavoritesReload") then
        favoritesUI.reload()
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reload favorites from disk")

    drawFieldLabel("Search Tags")

    local tagsChanged, nextTagSearch = drawTagSelectorCombo(
        settings.assetFavoritesFilterTags,
        "assetFavoritesSearchTags",
        favoritesUI.tagFilterSearch,
        {
            allLabel = "All tags",
            comboWidth = 160,
            showAndFilterToggle = true,
            showClearSelectionButton = true,
            unselectAllTooltip = "Unselect all tags (default behavior: show all)"
        }
    )
    favoritesUI.tagFilterSearch = nextTagSearch
    if tagsChanged then
        settings.save()
    end

    style.spacedSeparator()

    drawExpandCollapseRow()

    favoritesUI.drawMain()
end

return favoritesUI
