local style = require("modules/ui/style")
local field = require("modules/utils/ui/field")
local utils = require("modules/utils/core/utils")
local settings = require("modules/utils/core/settings")
local input = require("modules/utils/core/input")
local logger = require("modules/utils/core/logger")
local previewControls = require("modules/utils/preview/previewControls")

-- Icon a category is created with, until it is given one of its own
local DEFAULT_CATEGORY_ICON = "EmoticonOutline"

---@class prefabsUI
---@field spawnUI spawnUI?
---@field newItemCategory string
---@field tagAddFilter string Tag filter for adding new tags
---@field tagFilterFilter string Tag filter for filtering tags
---@field tagMergeFilter string
---@field tagMergeTags table
---@field newItemTags table<string, boolean>
---@field newTag string
---@field newMergeTag string
---@field openPopup boolean
---@field popupItem favorite?
---@field popupItemConflict boolean
---@field openCreatePopup boolean
---@field createItem favorite?
---@field createTargetCategoryName string
---@field categories category[]
local prefabsUI = {
    spawnUI = nil,

    newItemCategory = "",
    newCategoryName = "New Category",
    newCategoryIcon = DEFAULT_CATEGORY_ICON,
    newCategoryIconSearch = "",
    selectCategorySearch = "",
    -- Create row of the category picker. Kept apart from the "Add Category" section above,
    -- so the two never overwrite each other's half typed name.
    selectCategoryNewName = "",
    selectCategoryNewIcon = DEFAULT_CATEGORY_ICON,
    selectCategoryNewIconSearch = "",
    tagAddFilter = "",
    tagFilterFilter = "",
    tagMergeFilter = "",
    tagMergeTags = {},
    newItemTags = {},
    newTag = "",
    newMergeTag = "",

    categories = {},

    openPopup = false,
    popupItem = nil,
    popupItemConflict = false,

    openCreatePopup = false,
    createItem = nil,
    createTargetCategoryName = ""
}

local scheduleFavoritesFilterSave, flushFavoritesFilterSave = utils.makeDebouncedSave()

---@param fileName string
---@param reason string
local function quarantineInvalidFavoriteFile(fileName, reason)
    local sourcePath = "data/favorite/" .. fileName
    local targetPath = string.format("data/favorite/invalid_%d_%s.bak", os.time(), fileName)

    local moved = os.rename(sourcePath, targetPath)
    if moved then
        logger:warn(string.format("[Favorites UI] [%s] Invalid favorite file '%s' (%s). Moved to '%s' for recovery.", settings.mainWindowName, fileName, reason, targetPath))
    else
        logger:error(string.format("[Favorites UI] [%s] Invalid favorite file '%s' (%s). Could not move it; left original file in place.", settings.mainWindowName, fileName, reason))
    end
end

local PREFABS_OPTIONS_POPIN_ID = "##prefabsSpawnOptionsPopin"

---Body of the prefabs options popin.
---The asset preview toggle is a single switch for the whole list: a prefab can hold
---any kind of spawnable, so there is no per-variant setting to bind it to.
local function drawPrefabsOptions()
    style.mutedText("Asset Preview")
    ImGui.SameLine()
    local assetPreviewChanged
    settings.prefabsAssetPreviewEnabled, assetPreviewChanged = ImGui.Checkbox("##prefabsAssetPreview", settings.prefabsAssetPreviewEnabled)
    if assetPreviewChanged then
        settings.save()
    end
    style.tooltip("Preview the prefab when hovered. Is Experimental.\nSingle asset prefabs also follow the per-variant setting of the \"All\" sub-tab.")

    ImGui.SameLine()
    style.mutedText(IconGlyphs.InformationOutline)
    style.tooltip(previewControls.getBindingsTooltip())

    prefabsUI.spawnUI.drawSpawnPosition()
end

---Draws the target group selector plus the options button, on one line.
local function drawPrefabsSpawnOptionsRow()
    if not prefabsUI.spawnUI then
        return
    end

    prefabsUI.spawnUI.drawTargetGroupSelector()
    prefabsUI.spawnUI.drawOptionsButton(
        "##prefabsSpawnOptionsButton",
        PREFABS_OPTIONS_POPIN_ID,
        drawPrefabsOptions,
        "Prefabs options"
    )
end

---@param spawner spawner
function prefabsUI.init(spawner)
    prefabsUI.spawnUI = spawner.baseUI.spawnUI

    for _, file in pairs(dir("data/favorite")) do
        if file.name:match("^.+(%..+)$") == ".json" then
            local data = config.loadFile("data/favorite/" .. file.name)

            if type(data) ~= "table" or type(data.favorites) ~= "table" then
                quarantineInvalidFavoriteFile(file.name, "missing or malformed favorites data")
            else
                local category = require("modules/classes/prefabs/category"):new(prefabsUI)
                category:load(data, file.name)

                if prefabsUI.categories[category.name] then
                    local target = prefabsUI.categories[category.name]
                    local origin = category

                    if #target.favorites < #origin.favorites then
                        target = origin
                        origin = prefabsUI.categories[category.name]
                    end
                    target:merge(origin)

                    -- Merging will remove category.name from the list, so we have to re-add it (Due to identical names)
                    prefabsUI.categories[target.name] = target
                else
                    prefabsUI.categories[category.name] = category
                end
            end
        end
    end
end

function prefabsUI.updateCategoryName(oldName, newName)
    prefabsUI.categories[newName] = prefabsUI.categories[oldName]
    prefabsUI.categories[oldName] = nil
end

-- `getAllTags` walks every category x favorite x tag and is queried several times per draw pass.
-- Memoized for that pass only: each draw entry point drops it first, so it can never go stale.
local allTagsCache = nil

---Drops the memoized tag list. Called when entering a draw pass, and after any
---edit that can change which tags exist.
function prefabsUI.invalidateTagCache()
    allTagsCache = nil
end

---Sorted list of every tag in use, including the ones staged in an open popup.
---@param filter string? Optional case-insensitive pattern the tags must match.
---@return string[]
function prefabsUI.getAllTags(filter)
    if not allTagsCache then
        local tagSet = {}

        local function collect(tags)
            for tag, _ in pairs(tags or {}) do
                tagSet[tag] = true
            end
        end

        for _, category in pairs(prefabsUI.categories) do
            for _, favorite in pairs(category.favorites) do
                collect(favorite.tags)
            end
        end

        -- Staged items are not in any category yet, but their tags must stay selectable.
        collect(prefabsUI.popupItem and prefabsUI.popupItem.tags)
        collect(prefabsUI.createItem and prefabsUI.createItem.tags)

        allTagsCache = utils.getKeys(tagSet)
        table.sort(allTagsCache)
    end

    if not filter or filter == "" then
        return allTagsCache
    end

    local matched = {}
    for _, tag in ipairs(allTagsCache) do
        if utils.safePatternMatch(tag:lower(), filter:lower()) then
            table.insert(matched, tag)
        end
    end

    return matched
end

---Draws the modern searchable multi-select tag combo (with tag creation) used by the
---create/edit popups. Selection state in `tags` is mutated in place.
---@param tags table<string, boolean>
---@param idScope string Unique id scope, e.g. "editTags" or "createTags"
---@param searchValue string
---@param createValue string
---@return boolean changed
---@return string searchValue
---@return string createValue
function prefabsUI.drawTagSelectorCombo(tags, idScope, searchValue, createValue)
    return prefabsUI.drawTagCombo(idScope, tags, searchValue, {
        allLabel = "No tags",
        options = prefabsUI.getAllTags(),
        comboWidth = 200,
        allowCreate = true,
        createValue = createValue
    })
end

---Draws one searchable tag multi-select combo. Shared by the create/edit popups,
---the merge selector and the search-tag filter, which differ only in these options.
---@param idScope string Unique ImGui id scope.
---@param selections table<string, boolean> Selection state, mutated in place.
---@param searchValue string
---@param opts table
---@return boolean changed
---@return string searchValue
---@return string createValue
function prefabsUI.drawTagCombo(idScope, selections, searchValue, opts)
    return style.drawSearchableMultiSelectCombo({
        comboId = "##" .. idScope .. "Combo",
        previewLabel = style.getMultiSelectPreviewLabel(selections, opts.allLabel, "%d tags selected"),
        searchHint = "Search tag...",
        searchValue = searchValue,
        options = opts.options,
        selections = selections,
        comboWidth = opts.comboWidth * style.viewSize,
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
        showClearSelectionButton = true,
        clearSelectionButtonId = "##" .. idScope .. "ClearSelection",
        clearSelectionTooltip = opts.clearSelectionTooltip or "Clear selected tags",
        showAndFilterToggle = opts.showAndFilterToggle == true,
        andFilterState = settings.favoritesTagsAND,
        andFilterTooltip = "AND filter mode (Leave off for OR filter)",
        onAndFilterChanged = function (nextAndFilter)
            settings.favoritesTagsAND = nextAndFilter
            settings.save()
        end,
        allowCreate = opts.allowCreate == true,
        createHint = IconGlyphs.Plus .. " New tag...",
        createValue = opts.createValue or "",
        createInputId = "##" .. idScope .. "Create",
        createButtonId = "##" .. idScope .. "CreateAdd",
        onCreate = function (name)
            selections[name] = true
            prefabsUI.invalidateTagCache()
        end
    })
end

---@param tags table<string, boolean>?
local function rememberNewItemTags(tags)
    prefabsUI.newItemTags = utils.deepcopy(tags or {})
end

---@param oldName string
---@param newName string
local function renameRememberedNewItemTag(oldName, newName)
    if type(prefabsUI.newItemTags) == "table" and prefabsUI.newItemTags[oldName] then
        prefabsUI.newItemTags[oldName] = nil
        prefabsUI.newItemTags[newName] = true
    end
end

function prefabsUI.addNewItem(serialized, name, icon)
    prefabsUI.openCreatePopup = true

    -- Null transforms, to make deep comparing for merging possible
    if serialized.modulePath == "modules/classes/editor/spawnableElement" then
        serialized.pos = { x = 0, y = 0, z = 0, w = 0 }
        serialized.spawnable.position = { x = 0, y = 0, z = 0, w = 0 }
        serialized.spawnable.rotation = { roll = 0, pitch = 0, yaw = 0 }
        serialized.spawnable.nodeRef = ""

        -- Do this to account for old bug where during AMM import things would get converted to base entity class
        if serialized.spawnable.modulePath == "entity/entity" then
            serialized.spawnable.modulePath = "entity/entityTemplate"
        end
    elseif serialized.modulePath == "modules/classes/editor/randomizedGroup" then
        serialized.seed = -1
    end
    serialized.visible = true
    serialized.headerOpen = false

    local favorite = require("modules/classes/prefabs/prefab"):new(prefabsUI)
    favorite.data = serialized
    favorite.name = name
    favorite.tags = utils.deepcopy(prefabsUI.newItemTags or {})

    local iconKey = utils.indexValue(IconGlyphs, icon)
    if iconKey == -1 then iconKey = "" end
    favorite.icon = iconKey

    -- Stage the item for creation only. Nothing is written to disk until the user
    -- validates the creation popup; cancelling discards it (see drawCreatePrefabPopup).
    prefabsUI.createItem = favorite
    prefabsUI.createTargetCategoryName = prefabsUI.categories[prefabsUI.newItemCategory] and prefabsUI.newItemCategory or ""
end

function prefabsUI.drawEditFavoritePopup()
    prefabsUI.invalidateTagCache()

    -- Keep popup within the viewport, including after expanding the Tags section.
    style.constrainPopupToViewport("##addFavorite")

    if ImGui.BeginPopup("##addFavorite") then
        input.updateContext("main")

        style.popupTitle(IconGlyphs.CogOutline, "Prefab Settings")

        local noCategory = prefabsUI.popupItem.category == nil

        -- Edit name
        style.fieldLabel("Name")
        style.setNextItemWidth(200)
        if prefabsUI.openPopup then
            prefabsUI.openPopup = false
            ImGui.SetKeyboardFocusHere()
        end
        prefabsUI.popupItem.name, changed = style.inputTextWithHint("##name", "Name...", prefabsUI.popupItem.name, 100)
        if changed then
            prefabsUI.popupItem.data.name = prefabsUI.popupItem.name
            if not noCategory then
                prefabsUI.popupItem.category:save()
            end
        end
        if not noCategory and prefabsUI.popupItem.category:isNameDuplicate(prefabsUI.popupItem.name) then
            style.styledTextWrapped(IconGlyphs.AlertOutline .. " Another prefab with this name already exists in this category. Both will coexist.", style.warnColor)
        end

        -- Select tags
        style.fieldLabel("Tags")
        local tagsChanged
        tagsChanged, prefabsUI.tagAddFilter, prefabsUI.newTag = prefabsUI.drawTagSelectorCombo(prefabsUI.popupItem.tags, "editTags", prefabsUI.tagAddFilter, prefabsUI.newTag)
        if tagsChanged then
            rememberNewItemTags(prefabsUI.popupItem.tags)

            if not noCategory then
                if prefabsUI.popupItem.category.grouped then
                    prefabsUI.popupItem.category:loadVirtualGroups()
                end
                prefabsUI.popupItem.category:save()
            end
        end

        -- Select category
        style.fieldLabel("Category")
        local categoryName, changed = prefabsUI.drawSelectCategory(prefabsUI.popupItem.category and prefabsUI.popupItem.category.name or "No Category")
        if changed then
            prefabsUI.newItemCategory = categoryName -- Just use the last selected category
            if prefabsUI.popupItem.category then
                prefabsUI.popupItem.category:removeFavorite(prefabsUI.popupItem)
            end
            prefabsUI.categories[categoryName]:addFavorite(prefabsUI.popupItem)
            prefabsUI.popupItemConflict = prefabsUI.popupItem:checkIsDuplicate()
        end

        if prefabsUI.popupItemConflict then
            ImGui.SameLine()
            style.styledText(IconGlyphs.AlertOutline, 0xFF0000FF)
            style.tooltip("Duplicate prefab")
        end

        ImGui.Separator()

        -- Close dismisses the popup; edits are saved live so nothing extra is needed here.
        if ImGui.Button(IconGlyphs.CheckboxMarkedCircleOutline .. " Close") then
            prefabsUI.popupItem = nil
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline .. " Delete") then
            if prefabsUI.popupItem.category then
                prefabsUI.popupItem.category:removeFavorite(prefabsUI.popupItem)
            end
            prefabsUI.popupItem = nil
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
    elseif not prefabsUI.openPopup then
        prefabsUI.popupItem = nil
    end

    if prefabsUI.openPopup then
        ImGui.OpenPopup("##addFavorite")
    end
end

---Finds an existing favorite in a category by exact name.
---@param category category
---@param name string
---@return favorite?
local function findFavoriteByName(category, name)
    for _, favorite in pairs(category.favorites) do
        if favorite.name == name then
            return favorite
        end
    end

    return nil
end

---Draws the deferred prefab/favorite creation popup opened from addNewItem.
---Unlike the edit popup, nothing is written to disk until the user validates.
---Cancelling (button or click-away) discards the staged item, so nothing happens.
---When the entered name already matches a prefab in the target category, the user
---can either overwrite that prefab or create a separate copy.
function prefabsUI.drawCreatePrefabPopup()
    prefabsUI.invalidateTagCache()

    -- Keep popup within the viewport, including after expanding the Tags section.
    style.constrainPopupToViewport("##createPrefab")

    if ImGui.BeginPopup("##createPrefab") then
        local item = prefabsUI.createItem

        if item then
            input.updateContext("main")

            style.popupTitle(IconGlyphs.Group, "Save as Prefab")

            local targetCategory = prefabsUI.categories[prefabsUI.createTargetCategoryName]
            local noCategory = targetCategory == nil

            -- Edit name
            style.fieldLabel("Name")
            style.setNextItemWidth(200)
            if prefabsUI.openCreatePopup then
                prefabsUI.openCreatePopup = false
                ImGui.SetKeyboardFocusHere()
            end
            item.name, _ = style.inputTextWithHint("##name", "Name...", item.name, 100)

            -- Select category
            style.fieldLabel("Category")
            local categoryName, changed = prefabsUI.drawSelectCategory(not noCategory and prefabsUI.createTargetCategoryName or "No Category")
            if changed then
                prefabsUI.createTargetCategoryName = categoryName
                prefabsUI.newItemCategory = categoryName -- Remember for next time
                targetCategory = prefabsUI.categories[categoryName]
                noCategory = targetCategory == nil
            end

            -- Select tags (staged only, no save)
            style.fieldLabel("Tags")
            local tagsChanged
            tagsChanged, prefabsUI.tagAddFilter, prefabsUI.newTag = prefabsUI.drawTagSelectorCombo(item.tags, "createTags", prefabsUI.tagAddFilter, prefabsUI.newTag)
            if tagsChanged then
                rememberNewItemTags(item.tags)
            end

            -- Detect a name collision within the target category (overwrite candidate)
            local existing = nil
            if not noCategory then
                existing = findFavoriteByName(targetCategory, item.name)
            end

            if existing then
                style.styledTextWrapped(IconGlyphs.AlertOutline .. " A prefab named '" .. item.name .. "' already exists in this category.", style.warnColor)
            end

            ImGui.Separator()

            if existing then
                -- Overwrite the existing prefab in place, keeping its category slot
                if style.warnButton(IconGlyphs.ContentSaveOutline .. " Overwrite", { tooltip = "Overwrite the existing prefab in this category" }) then
                    existing.data = item.data
                    existing.tags = item.tags
                    existing.icon = item.icon
                    existing.assetCount = nil
                    existing.category:save()
                    if existing.category.grouped then
                        existing.category:loadVirtualGroups()
                    end
                    prefabsUI.createItem = nil
                    ImGui.CloseCurrentPopup()
                end

                -- Create a separate copy instead, letting both coexist
                ImGui.SameLine()
                if ImGui.Button(IconGlyphs.ContentDuplicate .. " Create Copy") then
                    targetCategory:addFavorite(item)
                    prefabsUI.createItem = nil
                    ImGui.CloseCurrentPopup()
                end
                style.tooltip("Create a separate prefab anyway (both will coexist)")
            elseif noCategory then
                -- No category selected yet: greyed-out create with a hint on hover
                style.pushGreyedOut(true)
                ImGui.Button(IconGlyphs.CheckCircleOutline .. " Create")
                style.popGreyedOut(true)
                style.tooltip("Please assign a category before creating this prefab.")
            else
                if style.successButton(IconGlyphs.CheckCircleOutline .. " Create") then
                    targetCategory:addFavorite(item)
                    prefabsUI.createItem = nil
                    ImGui.CloseCurrentPopup()
                end
                style.tooltip("Create prefab")
            end

            -- Cancel: discard the staged item, nothing is written to disk
            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.Cancel .. " Cancel") then
                prefabsUI.createItem = nil
                ImGui.CloseCurrentPopup()
            end
            style.tooltip("Cancel")
        end

        ImGui.EndPopup()
    elseif not prefabsUI.openCreatePopup then
        prefabsUI.createItem = nil
    end

    if prefabsUI.openCreatePopup then
        ImGui.OpenPopup("##createPrefab")
    end
end

function prefabsUI.removeUnusedTags()
    local tags = prefabsUI.getAllTags("")
    local changed = false

    for tag, _ in pairs(settings.filterTags) do
        if not utils.has_value(tags, tag) then
            settings.filterTags[tag] = nil
            changed = true
        end
    end

    if changed then
        settings.save()
    end
end

---@param mergeTags table
---@param newTagName string
---@return number
function prefabsUI.getTagMergeAffectedCount(mergeTags, newTagName)
    if newTagName == "" or utils.tableLength(mergeTags) == 0 then
        return 0
    end

    local affected = 0

    for _, category in pairs(prefabsUI.categories) do
        for _, favorite in pairs(category.favorites) do
            for tag, _ in pairs(favorite.tags) do
                if mergeTags[tag] and tag ~= newTagName then
                    affected = affected + 1
                    break
                end
            end
        end
    end

    return affected
end

---Creates a category and writes it to disk. Refuses names that are empty or already taken,
---so no caller can end up with two categories answering to the same name.
---@param name string
---@param iconKey string? Icon glyph key, e.g. `EmoticonOutline`.
---@return category? category nil when the name was refused.
function prefabsUI.createCategory(name, iconKey)
    name = utils.trimString(name or "")

    if name == "" or prefabsUI.categories[name] then
        return nil
    end

    local category = require("modules/classes/prefabs/category"):new(prefabsUI)
    category:setName(name)
    category.icon = tostring(iconKey or "")
    category:generateFileName()
    category:save()

    prefabsUI.categories[name] = category

    return category
end

function prefabsUI.drawAddCategory()
    prefabsUI.newCategoryIcon, prefabsUI.newCategoryIconSearch, _ = field.drawIconSelector("prefabsUI", prefabsUI.newCategoryIcon, prefabsUI.newCategoryIconSearch)

    ImGui.SameLine()

    style.setNextItemWidth(200)
    prefabsUI.newCategoryName, _ = style.inputTextWithHint("##newCategoryName", "Category Name...", prefabsUI.newCategoryName, 100)

    local categoryExists = prefabsUI.categories[prefabsUI.newCategoryName] ~= nil
    if style.drawNoBGConditionalButton(prefabsUI.newCategoryName ~= "", IconGlyphs.Plus, categoryExists) and not categoryExists then
        if prefabsUI.createCategory(prefabsUI.newCategoryName, prefabsUI.newCategoryIcon) then
            prefabsUI.newCategoryName = "New Category"
            prefabsUI.newCategoryIcon = DEFAULT_CATEGORY_ICON
        end
    end
    if categoryExists then
        style.tooltip("Category already exists.")
    end
end

---Label of one category in the selector: its icon, when it has a resolvable one, then its name.
---Also used for values that name no category (the "No Category" placeholder, a merge target).
---@param categoryName string
---@return string
local function getCategoryLabel(categoryName)
    local category = prefabsUI.categories[categoryName]
    local glyph = category and IconGlyphs[category.icon] or nil

    if not glyph then
        return tostring(categoryName)
    end

    return glyph .. " " .. tostring(categoryName)
end

---Category picker, drawn with the same searchable combo as the tag selectors, in single
---select mode. The selection map is rebuilt every frame from the passed name, so the
---component stays the only owner of the picking logic.
---A category can also be created from the popup, icon included, and is picked right away.
---@param categoryName string Currently selected category, or a placeholder naming none.
---@return string categoryName
---@return boolean changed
function prefabsUI.drawSelectCategory(categoryName)
    categoryName = tostring(categoryName or "")

    local categories = utils.getKeys(prefabsUI.categories)
    table.sort(categories)

    local selections = { [categoryName] = true }

    -- The create input is only read back after the combo draws, so the conflict is resolved
    -- against what was typed last frame. The button cannot be clicked the frame it is typed
    -- in, and `createCategory` refuses a taken name anyway.
    local pendingName = utils.trimString(prefabsUI.selectCategoryNewName or "")
    local nameTaken = pendingName ~= "" and prefabsUI.categories[pendingName] ~= nil

    local changed, nextSearch, nextCreateName, nextCreateIcon, nextCreateIconSearch = style.drawSearchableMultiSelectCombo({
        comboId = "##selectCategory",
        previewLabel = getCategoryLabel(categoryName),
        singleSelect = true,
        searchHint = "Search category...",
        searchValue = prefabsUI.selectCategorySearch,
        options = categories,
        selections = selections,
        comboWidth = 200 * style.viewSize,
        searchWidth = 220 * style.viewSize,
        emptyText = "No category available",
        noMatchText = "No matching categories",
        searchInputId = "##selectCategorySearch",
        searchClearButtonId = "##selectCategorySearchClear",
        optionIdPrefix = "##selectCategoryOption",
        allowCreate = true,
        createHint = IconGlyphs.Plus .. " New category...",
        createValue = prefabsUI.selectCategoryNewName,
        createInputId = "##selectCategoryCreate",
        createButtonId = "##selectCategoryCreateAdd",
        createIcon = prefabsUI.selectCategoryNewIcon,
        createIconSearch = prefabsUI.selectCategoryNewIconSearch,
        createIconPickerId = "selectCategoryCreate",
        createDisabled = nameTaken,
        createTooltip = nameTaken and "Category already exists." or "Create this category and select it",
        onCreate = function (name, iconKey)
            local created = prefabsUI.createCategory(name, iconKey)
            if not created then return end

            -- Creating from the picker is how the user names the category they are assigning to.
            for key, _ in pairs(selections) do
                selections[key] = nil
            end
            selections[created.name] = true
        end,
        getOptionLabel = function (option)
            return getCategoryLabel(option)
        end
    })

    -- The name is cleared by the component once it created something; the icon stays on the
    -- last picked one, like the tag selectors do.
    prefabsUI.selectCategorySearch = nextSearch
    prefabsUI.selectCategoryNewName = nextCreateName
    prefabsUI.selectCategoryNewIcon = nextCreateIcon
    prefabsUI.selectCategoryNewIconSearch = nextCreateIconSearch

    if not changed then
        return categoryName, false
    end

    -- Only an existing category counts as a pick: a refused creation leaves the selection
    -- where it was, and callers index `categories` with whatever comes back.
    for key, isSelected in pairs(selections) do
        if isSelected and prefabsUI.categories[key] and key ~= categoryName then
            return key, true
        end
    end

    return categoryName, false
end

---Height of one list row, shared with any list reusing `prefabsUI.pushRow`.
---@param padding number
---@return number
function prefabsUI.getRowHeight(padding)
    return ImGui.GetFrameHeight() + (padding - style.viewSize) * 2
end

function prefabsUI.pushRow(context)
    ImGui.TableNextRow(ImGuiTableRowFlags.None, prefabsUI.getRowHeight(context.padding))
    if context.row % 2 == 0 then
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.2, 0.2, 0.2, 0.3)
    else
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.3, 0.3, 0.3, 0.3)
    end

    ImGui.TableNextColumn()
end

---Applies an open state to one category and, when grouped, to its tag sub-groups.
---@param category category
---@param open boolean
local function setCategoryOpenRecursive(category, open)
    category.headerOpen = open

    for _, group in pairs(category.virtualGroups or {}) do
        setCategoryOpenRecursive(group, open)
    end
end

---@param open boolean
local function setAllCategoriesOpen(open)
    for _, category in pairs(prefabsUI.categories) do
        setCategoryOpenRecursive(category, open)
    end
end

---Draws the expand all / collapse all row shown above the prefabs list.
function prefabsUI.drawExpandCollapseRow()
    style.drawExpandCollapseButtons(
        "prefabsList",
        function () setAllCategoriesOpen(true) end,
        function () setAllCategoriesOpen(false) end,
        {
            disabled = next(prefabsUI.categories) == nil,
            expandTooltip = "Expand all categories",
            collapseTooltip = "Collapse all categories"
        }
    )

    ImGui.Separator()
end

---Draws the striped-row list shell shared by the Prefabs and Favorites lists:
---scroll child, single-column table, caller-provided rows, then filler rows so the
---striping covers the whole area.
---@param idScope string Unique ImGui id scope of the child + table.
---@param drawRows fun(context: table) Draws the actual rows, advancing `context.row`.
---@param drawEmptyState fun()? Drawn above the table, before any row.
function prefabsUI.drawRowTable(idScope, drawRows, drawEmptyState)
    local cellPadding = 3 * style.viewSize
    local _, y = ImGui.GetContentRegionAvail()
    y = math.max(y, 300 * style.viewSize)
    local nRows = math.floor(y / prefabsUI.getRowHeight(cellPadding))

    local context = {
        row = 0,
        depth = 0,
        padding = cellPadding
    }

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, 7.5 * style.viewSize, cellPadding)
    ImGui.PushStyleVar(ImGuiStyleVar.ScrollbarSize, 12 * style.viewSize)

    if ImGui.BeginChild("##" .. idScope .. "List", -1, y, false) then
        if drawEmptyState then
            drawEmptyState()
        end

        if ImGui.BeginTable("##" .. idScope .. "ListTable", 1, ImGuiTableFlags.ScrollX or ImGuiTableFlags.NoHostExtendX) then
            drawRows(context)

            while context.row < nRows do
                prefabsUI.pushRow(context)
                context.row = context.row + 1
            end

            ImGui.EndTable()
        end
        ImGui.EndChild()
    end

    ImGui.PopStyleVar(2)
end

function prefabsUI.drawMain()
    prefabsUI.drawRowTable("favorites", function (context)
        local keys = utils.getKeys(prefabsUI.categories)
        table.sort(keys)

        for _, key in pairs(keys) do
            context.depth = 0
            prefabsUI.categories[key]:draw(context)
        end
    end)
end

function prefabsUI.drawMergeTags()
    local mergeTagOptions = prefabsUI.getAllTags()
    utils.pruneKeys(prefabsUI.tagMergeTags, utils.toKeySet(mergeTagOptions))

    style.fieldLabel("Tags to rename / merge")

    local _, nextMergeSearch = prefabsUI.drawTagCombo("tagMerge", prefabsUI.tagMergeTags, prefabsUI.tagMergeFilter, {
        allLabel = "No tags selected",
        options = mergeTagOptions,
        comboWidth = 160,
        clearSelectionTooltip = "Clear selected tags to rename/merge"
    })
    prefabsUI.tagMergeFilter = nextMergeSearch

    style.mutedText("New tag name")
    ImGui.SameLine()
    style.setNextItemWidth(200)
    prefabsUI.newMergeTag, _ = style.inputTextWithHint("##newMergeTag", "New tag name...", prefabsUI.newMergeTag, 15)

    local selectedTagCount = utils.tableLength(prefabsUI.tagMergeTags)
    local affectedCount = prefabsUI.getTagMergeAffectedCount(prefabsUI.tagMergeTags, prefabsUI.newMergeTag)
    style.mutedText("Selected tags: " .. selectedTagCount .. " | Affected prefabs: " .. affectedCount)

    local canApply = prefabsUI.newMergeTag ~= "" and selectedTagCount > 0 and affectedCount > 0

    ImGui.SameLine()
    style.pushButtonNoBG(true)
    style.pushGreyedOut(not canApply)
    local clicked = ImGui.Button(IconGlyphs.CheckCircleOutline)
    style.popGreyedOut(not canApply)
    style.pushButtonNoBG(false)

    if clicked and canApply then
        local changedAnyCategory = false
        for _, category in pairs(prefabsUI.categories) do
            changedAnyCategory = category:renameTags(prefabsUI.tagMergeTags, prefabsUI.newMergeTag) or changedAnyCategory
        end

        -- Keep active search-tag filters aligned with the merge target so merged entries stay visible.
        local changedFilterTags = false
        if changedAnyCategory then
            for oldTag, _ in pairs(prefabsUI.tagMergeTags) do
                if oldTag ~= prefabsUI.newMergeTag and settings.filterTags[oldTag] then
                    settings.filterTags[oldTag] = nil
                    settings.filterTags[prefabsUI.newMergeTag] = true
                    changedFilterTags = true
                end
                if oldTag ~= prefabsUI.newMergeTag then
                    renameRememberedNewItemTag(oldTag, prefabsUI.newMergeTag)
                end
            end
        end

        -- Run cleanup immediately so stale tags do not hide entries until the next frame.
        prefabsUI.invalidateTagCache()
        prefabsUI.removeUnusedTags()

        if changedFilterTags then
            settings.save()
        end

        prefabsUI.newMergeTag = ""
        prefabsUI.tagMergeTags = {}
    end

    if not canApply then
        style.tooltip("Select at least one source tag and enter a new name that affects prefabs.")
    end
end

function prefabsUI.draw()
    prefabsUI.invalidateTagCache()
    prefabsUI.removeUnusedTags()

    drawPrefabsSpawnOptionsRow()

    if ImGui.TreeNodeEx("Add Category", ImGuiTreeNodeFlags.SpanFullWidth) then
        prefabsUI.drawAddCategory()

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Rename Tags", ImGuiTreeNodeFlags.SpanFullWidth) then
        prefabsUI.drawMergeTags()

        ImGui.TreePop()
    end

    style.spacedSeparator()

    local filterChanged, filterCleared
    settings.favoritesFilter, filterChanged, filterCleared = style.drawSearchFilterRow("##filter", settings.favoritesFilter)
    if filterCleared then
        flushFavoritesFilterSave()
    elseif filterChanged then
        scheduleFavoritesFilterSave()
    end

    style.sameLineWindowRight(25)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload) then
        prefabsUI.categories = {}
        prefabsUI.invalidateTagCache()
        prefabsUI.init(prefabsUI.spawnUI.spawner)
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reload prefabs from disk")

    local searchTagOptions = prefabsUI.getAllTags()
    utils.pruneKeys(settings.filterTags, utils.toKeySet(searchTagOptions))

    style.fieldLabel("Search Tags")

    local tagsChanged, nextTagSearch = prefabsUI.drawTagCombo("searchTags", settings.filterTags, prefabsUI.tagFilterFilter, {
        allLabel = "All tags",
        options = searchTagOptions,
        comboWidth = 160,
        unselectAllTooltip = "Unselect all tags (default behavior: show all)",
        clearSelectionTooltip = "Clear selected tag filters",
        showAndFilterToggle = true
    })
    prefabsUI.tagFilterFilter = nextTagSearch
    if tagsChanged then
        settings.save()
    end

    style.spacedSeparator()

    prefabsUI.drawExpandCollapseRow()

    prefabsUI.drawMain()
end

return prefabsUI
