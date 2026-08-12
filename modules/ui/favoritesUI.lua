local style = require("modules/ui/style")
local field = require("modules/utils/ui/field")
local utils = require("modules/utils/core/utils")
local settings = require("modules/utils/core/settings")
local input = require("modules/utils/core/input")
local logger = require("modules/utils/core/logger")
local assetFavorites = require("modules/utils/project/assetFavorites")
local favoritesImpex = require("modules/utils/project/favoritesImpex")
local prefabsUI = require("modules/ui/prefabsUI")

local SPAWN_OPTIONS_POPIN_ID = "##assetFavoritesSpawnOptionsPopin"
local IMPORT_POPUP_ID = "##assetFavoritesImport"
local BULK_ADD_POPUP_ID = "##assetFavoritesBulkAdd"
local NO_TAG_GROUP_KEY = "\1noTag"
-- Past this, the favorites list becomes unwieldy; the popup says so before adding.
local BULK_ADD_WARN_THRESHOLD = 500
-- Breathing room between an asset name and its tag icons
local TAG_ICONS_LEFT_MARGIN = 12
-- Import codes grow with the number of favorites they carry, so the paste field
-- needs far more room than the regular name / search inputs
local IMPORT_CODE_MAX_LENGTH = 1024 * 256

-- Asset preview hover tracking. A favorite is listed once per tag it carries, so the
-- same entry is drawn by several rows in one frame: whether its preview should stop
-- can only be decided once every row had its say, not from a single non hovered one.
local hoveredPreviewEntry = nil
local previewEntry = nil

---Spawn New > Favorites sub-tab.
---Favorites are bookmarks to assets of the "All" sub-tab, organized with tags.
---They never carry any configuration, unlike prefabs.
---@class favoritesUI
---@field spawnUI spawnUI?
---@field tagFilterSearch string
---@field filterNewTag string
---@field filterNewTagIcon string
---@field filterNewTagIconSearch string
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
---@field importCode string
---@field importReport favoritesImportReport?
---@field lastAddTags table<string, boolean>
---@field bulkRequest favoriteBulkAddRequest?
---@field openBulkAddPopup boolean
---@field bulkTags table<string, boolean>
---@field bulkTagSearch string
---@field bulkNewTag string
---@field bulkNewTagIcon string
---@field bulkNewTagIconSearch string
local favoritesUI = {
    spawnUI = nil,

    tagFilterSearch = "",
    filterNewTag = "",
    filterNewTagIcon = assetFavorites.defaultTagIcon,
    filterNewTagIconSearch = "",
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

    importCode = "",
    importReport = nil,

    lastAddTags = {},
    bulkRequest = nil,
    openBulkAddPopup = false,
    -- Mirrors lastAddTags while the bulk popup is open.
    bulkTags = {},
    bulkTagSearch = "",
    bulkNewTag = "",
    bulkNewTagIcon = assetFavorites.defaultTagIcon,
    bulkNewTagIconSearch = ""
}

local moduleIconCache = {}
local scheduleFilterSave, flushFilterSave = utils.makeDebouncedSave()

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

    -- Instantiated from the module itself rather than from the spawn list's class: a Spawn
    -- New variant may host several spawnable classes, so its class is not necessarily the
    -- one this module path names.
    local okInstance, instance = pcall(function ()
        return require("modules/classes/spawn/" .. modulePath):new()
    end)

    if okInstance and instance and type(instance.icon) == "string" then
        icon = instance.icon
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

---Whether the list is currently narrowed down, by search text or by tag filter.
---@return boolean
local function isFilterActive()
    if tostring(settings.assetFavoritesFilter or "") ~= "" then
        return true
    end

    for _, isSelected in pairs(settings.assetFavoritesFilterTags or {}) do
        if isSelected then
            return true
        end
    end

    return false
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
    -- (rename / icon / delete) would be unreachable. While filtering they are only noise
    -- though: a result list should hold nothing but results.
    if not isFilterActive() then
        for _, tag in ipairs(assetFavorites.getTagNames()) do
            if not groupsByKey[tag] and (tagUsage[tag] or 0) == 0 then
                groupsByKey[tag] = createTagGroup(tag)
            end
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

---Popup used to paste a favorites code, opened from the list header row.
local function drawImportPopup()
    if ImGui.IsPopupOpen(IMPORT_POPUP_ID) then
        style.setCursorRelativeAppearing(-5, -5)
    end

    if not ImGui.BeginPopup(IMPORT_POPUP_ID) then return end

    input.updateContext("main")

    style.popupTitle(IconGlyphs.Import, "Import Favorites")

    -- Lines are broken by hand: the popup is sized by the paste field below,
    -- wrapped text would have nothing to wrap against on the first frame.
    style.mutedText("To import shared favorites, paste the favorites code in the field below.")
    ImGui.Spacing()
    style.mutedText("Favorites you already have are kept as they are, they only\ngain the tags they are missing.")
    ImGui.Spacing()
    style.mutedText("To create a code of your own, press the " .. IconGlyphs.CogOutline .. " of a tag row\nand use \"" .. IconGlyphs.Export .. " Export favorites\".")
    ImGui.Spacing()

    style.setNextItemWidth(400)
    favoritesUI.importCode = style.inputTextWithHint("##assetFavoritesImportCode", "Paste the favorites code here...", favoritesUI.importCode, IMPORT_CODE_MAX_LENGTH)

    if style.drawNoBGConditionalButton(favoritesUI.importCode ~= "", IconGlyphs.Close .. "##assetFavoritesImportCodeClear") then
        favoritesUI.importCode = ""
        favoritesUI.importReport = nil
    end

    ImGui.Spacing()

    style.pushGreyedOut(favoritesUI.importCode == "")
    if ImGui.Button(IconGlyphs.Import .. " Import") then
        favoritesUI.importReport = favoritesImpex.import(favoritesUI.importCode)

        -- Keep the code around on failure, so it can be fixed instead of re-pasted
        if not favoritesUI.importReport.err then
            favoritesUI.importCode = ""
        end
    end
    style.popGreyedOut(favoritesUI.importCode == "")

    local report = favoritesUI.importReport
    if report then
        ImGui.Spacing()

        if report.err then
            style.styledText(IconGlyphs.AlertOutline .. " " .. report.err, 0xFF0000FF)
        else
            local summary = string.format("%d added, %d updated, %d skipped", report.imported, report.updated, report.skipped)

            if report.tagsCreated > 0 then
                summary = summary .. string.format(", %d tag(s) created", report.tagsCreated)
            end

            style.mutedText(IconGlyphs.CheckboxMarkedCircleOutline .. " " .. summary)
            style.tooltip("Added: assets the code brought into your favorites.\nUpdated: assets you already had, which gained tags from the code.\nSkipped: assets already favorited with those tags, or entries naming no asset.")
        end
    end

    ImGui.Separator()

    if ImGui.Button(IconGlyphs.CheckboxMarkedCircleOutline .. " Close") then
        ImGui.CloseCurrentPopup()
    end

    ImGui.EndPopup()
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

    style.sameLineWindowRight(25)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Import .. "##assetFavoritesImportOpen") then
        favoritesUI.importCode = ""
        favoritesUI.importReport = nil
        ImGui.OpenPopup(IMPORT_POPUP_ID)
    end
    style.pushButtonNoBG(false)
    style.tooltip("Import favorites")

    drawImportPopup()

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

    if utils.pruneKeys(settings.assetFavoritesFilterTags, utils.toKeySet(assetFavorites.getTagNames())) then
        settings.save()
    end
end

---Draws the shared searchable tag multi-select combo, with icons per tag.
---When `opts.allowCreate` is set, the create row also carries an icon selector
---so a new tag is created with its icon in one go. A created tag is selected right
---away, unless `opts.selectOnCreate` says otherwise.
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

    local preview = style.getMultiSelectPreviewLabel(
        selections,
        opts.allLabel or "No tags",
        opts.multiLabel or "%d tags selected",
        function (tag) return assetFavorites.getTagGlyph(tag) .. " " .. tag end
    )

    return style.drawSearchableMultiSelectCombo({
        comboId = "##" .. idScope .. "Combo",
        previewLabel = preview,
        searchHint = IconGlyphs.Magnify .. " Search tag...",
        searchValue = searchValue,
        options = assetFavorites.getTagNames(),
        selections = selections,
        comboWidth = (opts.comboWidth or 200) * style.viewSize,
        searchWidth = 220 * style.viewSize,
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
        createHint = IconGlyphs.Plus .. " New tag...",
        createValue = opts.createValue or "",
        createInputId = "##" .. idScope .. "Create",
        createButtonId = "##" .. idScope .. "CreateAdd",
        createIcon = opts.allowCreate == true and (opts.createIcon or assetFavorites.defaultTagIcon) or nil,
        createIconSearch = opts.createIconSearch or "",
        createIconPickerId = idScope .. "CreateIcon",
        onCreate = function (name, iconKey)
            assetFavorites.createTag(name, iconKey)

            if opts.selectOnCreate ~= false then
                selections[name] = true
            end
        end,
        getOptionLabel = function (option)
            return assetFavorites.getTagGlyph(option) .. " " .. tostring(option)
        end
    })
end

---@param tags table<string, boolean>?
local function pruneAddTags(tags)
    if type(tags) ~= "table" then
        return
    end

    utils.pruneKeys(tags, utils.toKeySet(assetFavorites.getTagNames()))
end

---@param tags table<string, boolean>?
local function rememberAddTags(tags)
    favoritesUI.lastAddTags = utils.deepcopy(tags or {})
    pruneAddTags(favoritesUI.lastAddTags)
end

---@return table<string, boolean>
local function getRememberedAddTags()
    pruneAddTags(favoritesUI.lastAddTags)
    return utils.deepcopy(favoritesUI.lastAddTags or {})
end

---@param entry assetFavoriteEntry
---@return boolean applied
local function applyRememberedAddTags(entry)
    if not entry then
        return false
    end

    local tags = getRememberedAddTags()
    if utils.tableLength(tags) == 0 then
        return false
    end

    entry.tags = tags
    return true
end

---@param oldName string
---@param newName string
local function renameRememberedAddTag(oldName, newName)
    for _, tags in ipairs({ favoritesUI.lastAddTags, favoritesUI.bulkTags }) do
        if type(tags) == "table" and tags[oldName] then
            tags[oldName] = nil
            tags[newName] = true
        end
    end
end

---@param tagName string
local function forgetAddTag(tagName)
    if type(favoritesUI.lastAddTags) == "table" then
        favoritesUI.lastAddTags[tagName] = nil
    end
    if type(favoritesUI.bulkTags) == "table" then
        favoritesUI.bulkTags[tagName] = nil
    end
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
    if applyRememberedAddTags(entry) then
        assetFavorites.save()
    end
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
        isFavorite and IconGlyphs.StarMinusOutline or IconGlyphs.StarPlusOutline,
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

---@class favoriteBulkAddRequest
---@field modulePath string Spawnable module path every item belongs to
---@field items assetFavoriteBulkItem[]
---@field sourceLabel string Where the assets come from, shown in the popup
---@field newCount number Items not favorited yet, resolved when the popup is staged

---Stages the bulk "add to favorites" popup for a set of spawn list entries.
---The popup itself is drawn by `favoritesUI.drawPopups`, so this works from any tab.
---@param modulePath string?
---@param items assetFavoriteBulkItem[]?
---@param sourceLabel string?
---@return boolean staged False when there is nothing to favorite.
function favoritesUI.openBulkAdd(modulePath, items, sourceLabel)
    if type(modulePath) ~= "string" or modulePath == "" or type(items) ~= "table" or #items == 0 then
        return false
    end

    local newCount = 0
    for _, item in ipairs(items) do
        if not assetFavorites.isFavorite(modulePath, item.path) then
            newCount = newCount + 1
        end
    end

    favoritesUI.bulkTags = getRememberedAddTags()

    favoritesUI.bulkRequest = {
        modulePath = modulePath,
        items = items,
        sourceLabel = tostring(sourceLabel or ""),
        newCount = newCount
    }
    favoritesUI.openBulkAddPopup = true
    favoritesUI.bulkTagSearch = ""
    favoritesUI.bulkNewTag = ""
    favoritesUI.bulkNewTagIcon = assetFavorites.defaultTagIcon
    favoritesUI.bulkNewTagIconSearch = ""

    return true
end

---Runs the staged bulk add and reports what it did.
---@param request favoriteBulkAddRequest
local function applyBulkAdd(request)
    local report = assetFavorites.addMany(request.modulePath, request.items, favoritesUI.bulkTags)

    local summary = string.format("%d favorite(s) added", report.added)
    if report.existing > 0 then
        summary = summary .. string.format(", %d already favorited", report.existing)
    end

    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, summary))
    logger:info(string.format(
        "[%s] Bulk favorited \"%s\": %d added, %d already favorited, %d tagged, %d skipped",
        settings.mainWindowName,
        request.sourceLabel,
        report.added,
        report.existing,
        report.tagged,
        report.skipped
    ))
end

---Popup used to favorite a whole set of assets at once, under a shared set of tags.
local function drawBulkAddPopup()
    local request = favoritesUI.bulkRequest
    if not request then return end

    if ImGui.IsPopupOpen(BULK_ADD_POPUP_ID) then
        style.setCursorRelativeAppearing(-5, -5)
    end

    if ImGui.BeginPopup(BULK_ADD_POPUP_ID) then
        input.updateContext("main")

        style.popupTitle(IconGlyphs.StarPlusOutline, "Add to Favorites")

        if request.sourceLabel ~= "" then
            style.fieldLabel("Source")
            ImGui.AlignTextToFramePadding()
            ImGui.Text(request.sourceLabel)
        end

        style.mutedText(string.format("%d asset(s), of which %d not favorited yet", #request.items, request.newCount))

        style.fieldLabel("Tags")
        local tagsChanged
        tagsChanged, favoritesUI.bulkTagSearch, favoritesUI.bulkNewTag, favoritesUI.bulkNewTagIcon, favoritesUI.bulkNewTagIconSearch = drawTagSelectorCombo(
            favoritesUI.bulkTags,
            "assetFavoriteBulkTags",
            favoritesUI.bulkTagSearch,
            {
                allowCreate = true,
                createValue = favoritesUI.bulkNewTag,
                createIcon = favoritesUI.bulkNewTagIcon,
                createIconSearch = favoritesUI.bulkNewTagIconSearch,
                showClearSelectionButton = true
            }
        )
        if tagsChanged then
            rememberAddTags(favoritesUI.bulkTags)
        end
        style.tooltip("Every added asset gets these tags.\nAssets already favorited keep their own tags, and only gain the missing ones.")

        if #request.items > BULK_ADD_WARN_THRESHOLD then
            ImGui.Spacing()
            style.styledText(IconGlyphs.AlertOutline .. " That is a lot of favorites at once.", style.warnColor)
            style.tooltip("Narrow the search down first if you did not mean to favorite the whole list.")
        end

        ImGui.Separator()

        if ImGui.Button(IconGlyphs.StarPlusOutline .. " Add to favorites") then
            applyBulkAdd(request)
            favoritesUI.bulkRequest = nil
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()
        if ImGui.Button(IconGlyphs.Cancel .. " Cancel") then
            favoritesUI.bulkRequest = nil
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    elseif not favoritesUI.openBulkAddPopup then
        favoritesUI.bulkRequest = nil
    end

    if favoritesUI.openBulkAddPopup then
        favoritesUI.openBulkAddPopup = false
        ImGui.OpenPopup(BULK_ADD_POPUP_ID)
    end
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

    -- `modulePath` is what picks the class: the spawn list this favorite belongs to may host
    -- several spawnable classes, in which case its own class is only one of them.
    local spawnEntry = {
        data = entry.data,
        name = entry.path,
        fileName = entry.name,
        modulePath = entry.modulePath
    }

    return favoritesUI.spawnUI.spawnNew(spawnEntry, favoritesUI.spawnUI.resolveEntryClass(spawnList, spawnEntry), false)
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

        style.fieldLabel("Asset")
        ImGui.AlignTextToFramePadding()
        ImGui.Text(entry.name)
        style.tooltip(entry.path)

        style.fieldLabel("Type")
        ImGui.AlignTextToFramePadding()
        style.mutedText(getVariantLabel(entry.modulePath))

        style.fieldLabel("Tags")
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
            rememberAddTags(entry.tags)
            assetFavorites.save()
        end

        ImGui.Separator()

        if ImGui.Button(IconGlyphs.CheckboxMarkedCircleOutline .. " Close") then
            favoritesUI.popupEntry = nil
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.StarMinusOutline .. " Remove from favorites") then
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

---Copies the favorites of one tag to the clipboard as a shareable code.
---@param tagName string
local function exportTagFavorites(tagName)
    local code, count = favoritesImpex.exportTag(tagName)

    if not code then
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Warning, 2500, "No favorite uses this tag"))
        return
    end

    ImGui.SetClipboardText(code)
    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Copied %d favorite(s) to the clipboard", count)))
    logger:info(string.format("[%s] Exported %d favorite(s) of tag \"%s\"", settings.mainWindowName, count, tagName))
end

---Deletes one tag and drops every piece of UI state referencing it.
---@param tagName string
---@param removeOrphans boolean Also remove the favorites this tag was the only tag of.
---@return number removed Favorites removed along with the tag
local function deleteTagAndCleanup(tagName, removeOrphans)
    local removed = 0

    if removeOrphans then
        removed = assetFavorites.deleteTagWithOrphans(tagName)
    else
        assetFavorites.deleteTag(tagName)
    end

    settings.assetFavoritesFilterTags[tagName] = nil
    settings.save()
    transferGroupOpenState(tagName, nil)
    forgetAddTag(tagName)
    favoritesUI.popupTagName = nil

    if removeOrphans then
        logger:info(string.format("[%s] Deleted tag \"%s\" and %d favorite(s) carrying no other tag", settings.mainWindowName, tagName, removed))
    else
        logger:info(string.format("[%s] Deleted tag \"%s\"", settings.mainWindowName, tagName))
    end

    return removed
end

---Draws the delete button removing the tag together with the favorites it was the
---only tag of. Guarded by a confirm popup: unlike deleting the tag alone, this
---discards favorites, and cannot be undone.
---@param tagName string
local function drawDeleteTagWithFavoritesButton(tagName)
    local orphanCount = assetFavorites.getTagOrphanCount(tagName)

    style.dangerButton(IconGlyphs.DeleteSweepOutline .. " Delete tag + favorites")
    style.tooltip(string.format(
        "Deletes this tag, and removes the %d favorite(s) carrying no other tag.\n" ..
        "Favorites that have other tags are kept, they only lose this one.\n" ..
        "This cannot be undone.",
        orphanCount
    ))

    if not ImGui.BeginPopupContextItem("Delete tag and favorites?", ImGuiPopupFlags.MouseButtonLeft) then
        return
    end

    style.mutedText(string.format("Delete this tag and remove %d favorite(s)?", orphanCount))

    if style.dangerButton(IconGlyphs.DeleteOutline .. " Confirm") then
        local removed = deleteTagAndCleanup(tagName, true)
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Tag deleted, %d favorite(s) removed", removed)))
        ImGui.CloseCurrentPopup()
    end

    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.Cancel .. " Cancel") then
        ImGui.CloseCurrentPopup()
    end

    ImGui.EndPopup()
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
        favoritesUI.tagEditName, _ = style.inputTextWithHint("##tagName", "Tag name...", favoritesUI.tagEditName, 100)

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
            renameRememberedAddTag(tagName, newName)
            favoritesUI.popupTagName = newName
            tagName = newName
        end

        if nameTaken then
            ImGui.SameLine()
            style.styledText(IconGlyphs.AlertOutline, 0xFF0000FF)
            style.tooltip("A tag with this name already exists.")
        end

        local usageCount = assetFavorites.getTagUsageCount(tagName)
        style.mutedText(string.format("Used by %d favorite(s)", usageCount))

        ImGui.Separator()

        if ImGui.Button(IconGlyphs.CheckboxMarkedCircleOutline .. " Close") then
            favoritesUI.popupTagName = nil
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()
        ImGui.BeginDisabled(usageCount == 0)
        if ImGui.Button(IconGlyphs.Export .. " Export favorites") then
            exportTagFavorites(tagName)
        end
        ImGui.EndDisabled()
        if usageCount > 0 then
            style.tooltip("Copies every favorite of this tag to the clipboard, as a code that can be imported from the favorites list.")
        end

        -- Both deletions on their own row: four buttons on one line would widen the popup.
        if style.dangerButton(IconGlyphs.DeleteOutline .. " Delete tag") then
            deleteTagAndCleanup(tagName, false)
            ImGui.CloseCurrentPopup()
        end
        style.tooltip("Removes this tag from every favorite. The favorites themselves are kept.")

        ImGui.SameLine()
        drawDeleteTagWithFavoritesButton(tagName)

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
    drawBulkAddPopup()
end

---Right aligned cog button of a list row (entry or tag group).
---@param yOffset number Vertical nudge applied before drawing, in pixels.
---@param tooltip string
---@param onClick fun()
local function drawRowCogButton(yOffset, tooltip, onClick)
    local settingsX, _ = ImGui.CalcTextSize(IconGlyphs.CogOutline)

    style.setCursorRightAligned(settingsX + ImGui.GetStyle().ItemSpacing.x, yOffset)

    ImGui.SetNextItemAllowOverlap()
    if ImGui.Button(IconGlyphs.CogOutline) then
        onClick()
    end
    style.tooltip(tooltip)
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
    else
        spawnUI.handleRowDrag({ data = entry.data, name = entry.name }, function ()
            spawnFavorite(entry)
        end)
    end

    if ImGui.BeginPopupContextItem("##assetFavoriteContext", ImGuiPopupFlags.MouseButtonRight) then
        if spawnList and ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.Group, "Save as prefab", "assetFavoriteSavePrefab")) then
            local prefabEntry = { data = entry.data, name = entry.path, fileName = entry.name, modulePath = entry.modulePath }
            spawnUI.savePrefabFromEntry(prefabEntry, spawnUI.resolveEntryClass(spawnList, prefabEntry))
        end

        favoritesUI.drawContextMenuItem(entry.modulePath, entry.path, entry.name, entry.data, "Row")

        ImGui.Separator()

        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ContentCopy, "Copy path", "assetFavoriteCopyPath")) then
            ImGui.SetClipboardText(entry.path)
        end

        ImGui.EndPopup()
    end

    -- Asset preview, using the spawn list the favorite belongs to.
    -- Stopping it is left to `drawMain`, once every row of the entry has been drawn.
    if spawnList and ImGui.IsItemHovered() and settings.assetPreviewEnabled[entry.modulePath] then
        hoveredPreviewEntry = entry
        spawnUI.handleAssetPreviewHovered(entry, false, spawnList)
    end

    context.row = context.row + 1

    ImGui.SameLine()
    style.pushListRowContent()

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
    drawRowCogButton(1 * style.viewSize, "Favorite settings", function ()
        favoritesUI.openEntrySettings(entry)
    end)

    style.popListRowContent(1)

    ImGui.PopID()
end

---Stages the tag settings popup for one tag.
---The popup itself is drawn by `favoritesUI.drawPopups`.
---@param tagName string
local function openTagSettings(tagName)
    favoritesUI.openTagPopup = true
    favoritesUI.popupTagName = tagName
    favoritesUI.tagEditName = tagName
    favoritesUI.tagEditIconSearch = ""
end

---@param group table
local function drawGroupSideButtons(group)
    if group.isNoTag then return end

    drawRowCogButton(2 * (ImGui.GetFontSize() / 15), "Tag settings", function ()
        openTagSettings(group.name)
    end)
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

    -- Right click is a shortcut to the settings button of the row. The untagged group has none.
    if not group.isNoTag and ImGui.IsItemClicked(ImGuiMouseButton.Right) then
        openTagSettings(group.name)
    end

    context.row = context.row + 1

    ImGui.SameLine()
    style.pushListRowContent()

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
    ImGui.Text(group.name)

    ImGui.SameLine()
    ImGui.AlignTextToFramePadding()
    style.mutedText(string.format("(%d)", #group.entries))

    ImGui.SameLine()
    drawGroupSideButtons(group)

    style.popListRowContent(1)

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
    local groups = buildTagGroups()

    hoveredPreviewEntry = nil

    local hasVisibleEntry = false
    for _, group in ipairs(groups) do
        if #group.entries > 0 then
            hasVisibleEntry = true
            break
        end
    end

    prefabsUI.drawRowTable(
        "assetFavorites",
        function (context)
            for _, group in ipairs(groups) do
                context.depth = 0
                drawGroup(group, context)
            end
        end,
        function ()
            if assetFavorites.getCount() == 0 then
                style.mutedText("No favorites yet. Right click an asset in the \"All\" sub-tab and pick \"Add to favorites\".")
            elseif not hasVisibleEntry then
                style.mutedText("No favorite matches the current filters.")
            end
        end
    )

    -- The mouse left every row the previewed favorite is listed on
    if hoveredPreviewEntry then
        previewEntry = hoveredPreviewEntry
    elseif previewEntry then
        local spawnUI = favoritesUI.spawnUI

        if spawnUI.hoveredEntry == previewEntry and (spawnUI.previewInstance or spawnUI.previewTimer) then
            spawnUI.hoveredEntry = nil
            spawnUI.stopActiveAssetPreview()
        end

        previewEntry = nil
    end
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

    local filterChanged, filterCleared
    settings.assetFavoritesFilter, filterChanged, filterCleared = style.drawSearchFilterRow("##assetFavoritesFilter", settings.assetFavoritesFilter)
    if filterCleared then
        flushFilterSave()
    elseif filterChanged then
        scheduleFilterSave()
    end

    style.sameLineWindowRight(25)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload .. "##assetFavoritesReload") then
        favoritesUI.reload()
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reload favorites from disk")

    style.fieldLabel("Search Tags")

    -- A tag created here is left unselected on purpose: selecting a brand new tag as filter
    -- would only empty the list. It is created so it can be assigned to favorites afterwards.
    local tagsChanged, nextTagSearch, nextNewTag, nextNewTagIcon, nextNewTagIconSearch = drawTagSelectorCombo(
        settings.assetFavoritesFilterTags,
        "assetFavoritesSearchTags",
        favoritesUI.tagFilterSearch,
        {
            allLabel = "All tags",
            comboWidth = 160,
            showAndFilterToggle = true,
            showClearSelectionButton = true,
            unselectAllTooltip = "Unselect all tags (default behavior: show all)",
            allowCreate = true,
            selectOnCreate = false,
            createValue = favoritesUI.filterNewTag,
            createIcon = favoritesUI.filterNewTagIcon,
            createIconSearch = favoritesUI.filterNewTagIconSearch
        }
    )
    favoritesUI.tagFilterSearch = nextTagSearch
    favoritesUI.filterNewTag = nextNewTag
    favoritesUI.filterNewTagIcon = nextNewTagIcon
    favoritesUI.filterNewTagIconSearch = nextNewTagIconSearch
    if tagsChanged then
        settings.save()
    end

    style.spacedSeparator()

    drawExpandCollapseRow()

    favoritesUI.drawMain()
end

return favoritesUI
