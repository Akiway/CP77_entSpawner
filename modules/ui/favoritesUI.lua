local style = require("modules/ui/style")
local field = require("modules/utils/field")
local utils = require("modules/utils/utils")
local settings = require("modules/utils/settings")
local input = require("modules/utils/input")
local Cron = require("modules/utils/Cron")
local logger = require("modules/utils/logger")

---@class favoritesUI
---@field spawnUI spawnUI?
---@field newItemCategory string
---@field tagAddFilter string Tag filter for adding new tags
---@field tagFilterFilter string Tag filter for filtering tags
---@field tagMergeFilter string
---@field tagMergeTags table
---@field newTag string
---@field newMergeTag string
---@field tagFilterSize table | {x: number, y: number}
---@field tagMergeSize table | {x: number, y: number}
---@field openPopup boolean
---@field popupItem favorite?
---@field popupItemConflict boolean
---@field openCreatePopup boolean
---@field createItem favorite?
---@field createTargetCategoryName string
---@field categories category[]
local favoritesUI = {
    spawnUI = nil,

    newItemCategory = "",
    newCategoryName = "New Category",
    newCategoryIcon = "EmoticonOutline",
    newCategoryIconSearch = "",
    selectCategorySearch = "",
    tagAddFilter = "",
    tagFilterFilter = "",
    tagMergeFilter = "",
    tagMergeTags = {},
    newTag = "",
    newMergeTag = "",
    tagFilterSize = { x = 0, y = 0 },
    tagMergeSize = { x = 0, y = 0 },

    categories = {},

    openPopup = false,
    popupItem = nil,
    popupItemConflict = false,

    openCreatePopup = false,
    createItem = nil,
    createTargetCategoryName = "",

    favoritesFilterSaveTimer = nil
}

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

local function scheduleFavoritesFilterSave()
    if favoritesUI.favoritesFilterSaveTimer then
        Cron.Halt(favoritesUI.favoritesFilterSaveTimer)
    end

    favoritesUI.favoritesFilterSaveTimer = Cron.After(0.35, function ()
        settings.save()
        favoritesUI.favoritesFilterSaveTimer = nil
    end)
end

local function flushFavoritesFilterSave()
    if favoritesUI.favoritesFilterSaveTimer then
        Cron.Halt(favoritesUI.favoritesFilterSaveTimer)
        favoritesUI.favoritesFilterSaveTimer = nil
    end

    settings.save()
end

local FAVORITES_SPAWN_OPTIONS_POPIN_ID = "##favoritesSpawnOptionsPopin"

local function drawFavoritesSpawnOptionsRow()
    if not favoritesUI.spawnUI then
        return
    end

    favoritesUI.spawnUI.drawTargetGroupSelector()
end

local function drawFavoritesSpawnOptionsPopup()
    if not favoritesUI.spawnUI then
        return
    end

    if ImGui.BeginPopup(FAVORITES_SPAWN_OPTIONS_POPIN_ID) then
        ImGui.PushID("favoritesSpawnOptionsPopin")
        favoritesUI.spawnUI.drawSpawnPosition()
        ImGui.PopID()
        ImGui.EndPopup()
    end
end

---@param spawner spawner
function favoritesUI.init(spawner)
    favoritesUI.spawnUI = spawner.baseUI.spawnUI

    for _, file in pairs(dir("data/favorite")) do
        if file.name:match("^.+(%..+)$") == ".json" then
            local data = config.loadFile("data/favorite/" .. file.name)

            if type(data) ~= "table" or type(data.favorites) ~= "table" then
                quarantineInvalidFavoriteFile(file.name, "missing or malformed favorites data")
            else
                local category = require("modules/classes/favorites/category"):new(favoritesUI)
                category:load(data, file.name)

                if favoritesUI.categories[category.name] then
                    local target = favoritesUI.categories[category.name]
                    local origin = category

                    if #target.favorites < #origin.favorites then
                        target = origin
                        origin = favoritesUI.categories[category.name]
                    end
                    target:merge(origin)

                    -- Merging will remove category.name from the list, so we have to re-add it (Due to identical names)
                    favoritesUI.categories[target.name] = target
                else
                    favoritesUI.categories[category.name] = category
                end
            end
        end
    end
end

function favoritesUI.updateCategoryName(oldName, newName)
    favoritesUI.categories[newName] = favoritesUI.categories[oldName]
    favoritesUI.categories[oldName] = nil
end

function favoritesUI.getAllTags(filter)
    local tags = {}

    for _, category in pairs(favoritesUI.categories) do
        for _, favorite in pairs(category.favorites) do
            for tag, _ in pairs(favorite.tags) do
                if (filter == "" or utils.safePatternMatch(tag:lower(), filter:lower())) and not tags[tag] then
                    tags[tag] = true
                end
            end
        end
    end

    if favoritesUI.popupItem then
        for tag, _ in pairs(favoritesUI.popupItem.tags) do
            if (filter == "" or utils.safePatternMatch(tag:lower(), filter:lower())) and not tags[tag] then
                tags[tag] = true
            end
        end
    end

    if favoritesUI.createItem then
        for tag, _ in pairs(favoritesUI.createItem.tags) do
            if (filter == "" or utils.safePatternMatch(tag:lower(), filter:lower())) and not tags[tag] then
                tags[tag] = true
            end
        end
    end

    tags = utils.getKeys(tags)
    table.sort(tags)

    return tags
end

---Builds a stable preview label for a tag multi-select state map.
---@param selections table<string, boolean>?
---@param allLabel string
---@param multiLabelFormat string
---@return string
local function getTagSelectionPreviewLabel(selections, allLabel, multiLabelFormat)
    local selectedTags = {}

    if selections then
        for tag, isSelected in pairs(selections) do
            if isSelected == true then
                table.insert(selectedTags, tostring(tag))
            end
        end
    end

    table.sort(selectedTags, function(a, b)
        return string.lower(a) < string.lower(b)
    end)

    if #selectedTags == 0 then
        return allLabel
    end

    if #selectedTags == 1 then
        return selectedTags[1]
    end

    return string.format(multiLabelFormat, #selectedTags)
end

---Removes selected tag keys that are no longer available in the current tag option list.
---@param selections table<string, boolean>?
---@param options string[]
local function pruneTagSelections(selections, options)
    if not selections then
        return
    end

    local available = {}
    for _, tag in ipairs(options or {}) do
        available[tostring(tag)] = true
    end

    for tag, _ in pairs(selections) do
        if not available[tostring(tag)] then
            selections[tag] = nil
        end
    end
end

---Matches one tag option against the combo search query.
---@param tagName string
---@param filterValue string
---@return boolean
local function matchesTagSelectorOption(tagName, filterValue)
    local searchValue = string.lower(tostring(filterValue or ""))
    if searchValue == "" then
        return true
    end

    return utils.safePatternMatch(string.lower(tostring(tagName or "")), searchValue)
end

---Draws a clear-selection icon button for a tag multi-select filter.
---When the button is clicked, all currently selected tags are cleared.
---@param selections table<string, boolean>?
---@param buttonId string
---@param tooltip string
---@param sameLine boolean?
---@return boolean changed
---@return boolean drawn
local function drawTagClearButton(selections, buttonId, tooltip, sameLine)
    local hasSelection = false
    for _, isSelected in pairs(selections or {}) do
        if isSelected == true then
            hasSelection = true
            break
        end
    end

    if not hasSelection then
        return false, false
    end

    if sameLine then
        ImGui.SameLine()
    end

    local changed = false
    style.pushButtonNoBG(true)
    local clicked = ImGui.Button(IconGlyphs.FilterRemoveOutline .. buttonId)
    style.pushButtonNoBG(false)

    if tooltip ~= "" then
        style.tooltip(tooltip)
    end

    if clicked and selections then
        for key, _ in pairs(selections) do
            selections[key] = nil
        end
        changed = true
    end

    return changed, true
end

---Draws an inline muted field label, aligned to the following widget, then SameLine.
---@param label string
local function drawFieldLabel(label)
    ImGui.AlignTextToFramePadding()
    style.mutedText(label)
    ImGui.SameLine()
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
function favoritesUI.drawTagSelectorCombo(tags, idScope, searchValue, createValue)
    local options = favoritesUI.getAllTags("")
    local preview = getTagSelectionPreviewLabel(tags, "No tags", "%d tags selected")

    local _, screenHeight = GetDisplayResolution()
    local maxPopupHeight = math.max(200 * style.viewSize, math.min(520 * style.viewSize, screenHeight - 16))

    return style.drawSearchableMultiSelectCombo({
        comboId = "##" .. idScope .. "Combo",
        previewLabel = preview,
        searchHint = "Search tag...",
        searchValue = searchValue,
        options = options,
        selections = tags,
        comboWidth = 200 * style.viewSize,
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
        unselectAllTooltip = "Unselect all tags",
        showClearSelectionButton = true,
        clearSelectionButtonId = "##" .. idScope .. "ClearSelection",
        clearSelectionTooltip = "Clear selected tags",
        allowCreate = true,
        createHint = "New tag...",
        createValue = createValue,
        createInputId = "##" .. idScope .. "Create",
        createButtonId = "##" .. idScope .. "CreateAdd",
        matchesOption = function (option, sv)
            return matchesTagSelectorOption(option, sv)
        end
    })
end

---Draws the label prefix for a tag multi-select filter row.
---@param label string
local function drawTagMultiSelectLabel(label)
    drawFieldLabel(label)
end

function favoritesUI.addNewItem(serialized, name, icon)
    favoritesUI.openCreatePopup = true

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

    local favorite = require("modules/classes/favorites/favorite"):new(favoritesUI)
    favorite.data = serialized
    favorite.name = name

    local iconKey = utils.indexValue(IconGlyphs, icon)
    if iconKey == -1 then iconKey = "" end
    favorite.icon = iconKey

    -- Stage the item for creation only. Nothing is written to disk until the user
    -- validates the creation popup; cancelling discards it (see drawCreatePrefabPopup).
    favoritesUI.createItem = favorite
    favoritesUI.createTargetCategoryName = favoritesUI.categories[favoritesUI.newItemCategory] and favoritesUI.newItemCategory or ""
end

function favoritesUI.drawEditFavoritePopup()
    -- Keep popup within the viewport, including after expanding the Tags section.
    if ImGui.IsPopupOpen("##addFavorite") then
        style.setCursorRelativeAppearing(-5, -5)

        local screenWidth, screenHeight = GetDisplayResolution()
        local margin = 8
        local maxWidth = math.max(200, screenWidth - margin * 2)
        local maxHeight = math.max(200, screenHeight - margin * 2)
        local minWidth = math.min(320 * style.viewSize, maxWidth)
        local minHeight = math.min(160 * style.viewSize, maxHeight)
        ImGui.SetNextWindowSizeConstraints(minWidth, minHeight, maxWidth, maxHeight)
    end

    if ImGui.BeginPopup("##addFavorite") then
        input.updateContext("main")

        style.popupTitle(IconGlyphs.CogOutline, "Prefab Settings")

        local noCategory = favoritesUI.popupItem.category == nil

        -- Edit name
        drawFieldLabel("Name")
        style.setNextItemWidth(200)
        if favoritesUI.openPopup then
            favoritesUI.openPopup = false
            ImGui.SetKeyboardFocusHere()
        end
        favoritesUI.popupItem.name, changed = ImGui.InputTextWithHint("##name", "Name...", favoritesUI.popupItem.name, 100)
        if changed then
            favoritesUI.popupItem.data.name = favoritesUI.popupItem.name
            if not noCategory then
                favoritesUI.popupItem.category:save()
            end
        end
        if not noCategory and favoritesUI.popupItem.category:isNameDuplicate(favoritesUI.popupItem.name) then
            style.styledTextWrapped(IconGlyphs.AlertOutline .. " Another prefab with this name already exists in this category. Both will coexist.", style.warnColor)
        end

        -- Select tags
        drawFieldLabel("Tags")
        local tagsChanged
        tagsChanged, favoritesUI.tagAddFilter, favoritesUI.newTag = favoritesUI.drawTagSelectorCombo(favoritesUI.popupItem.tags, "editTags", favoritesUI.tagAddFilter, favoritesUI.newTag)
        if tagsChanged and not noCategory then
            if favoritesUI.popupItem.category.grouped then
                favoritesUI.popupItem.category:loadVirtualGroups()
            end
            favoritesUI.popupItem.category:save()
        end

        -- Select category
        drawFieldLabel("Category")
        local categoryName, changed = favoritesUI.drawSelectCategory(favoritesUI.popupItem.category and favoritesUI.popupItem.category.name or "No Category")
        if changed then
            favoritesUI.newItemCategory = categoryName -- Just use the last selected category
            if favoritesUI.popupItem.category then
                favoritesUI.popupItem.category:removeFavorite(favoritesUI.popupItem)
            end
            favoritesUI.categories[categoryName]:addFavorite(favoritesUI.popupItem)
            favoritesUI.popupItemConflict = favoritesUI.popupItem:checkIsDuplicate()
        end

        if favoritesUI.popupItemConflict then
            ImGui.SameLine()
            style.styledText(IconGlyphs.AlertOutline, 0xFF0000FF)
            style.tooltip("Duplicate Favorite")
        end

        ImGui.Separator()

        -- Close dismisses the popup; edits are saved live so nothing extra is needed here.
        if ImGui.Button(IconGlyphs.CheckboxMarkedCircleOutline .. " Close") then
            favoritesUI.popupItem = nil
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline .. " Delete") then
            if favoritesUI.popupItem.category then
                favoritesUI.popupItem.category:removeFavorite(favoritesUI.popupItem)
            end
            favoritesUI.popupItem = nil
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
    elseif not favoritesUI.openPopup then
        favoritesUI.popupItem = nil
    end

    if favoritesUI.openPopup then
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
function favoritesUI.drawCreatePrefabPopup()
    -- Keep popup within the viewport, including after expanding the Tags section.
    if ImGui.IsPopupOpen("##createPrefab") then
        style.setCursorRelativeAppearing(-5, -5)

        local screenWidth, screenHeight = GetDisplayResolution()
        local margin = 8
        local maxWidth = math.max(200, screenWidth - margin * 2)
        local maxHeight = math.max(200, screenHeight - margin * 2)
        local minWidth = math.min(320 * style.viewSize, maxWidth)
        local minHeight = math.min(160 * style.viewSize, maxHeight)
        ImGui.SetNextWindowSizeConstraints(minWidth, minHeight, maxWidth, maxHeight)
    end

    if ImGui.BeginPopup("##createPrefab") then
        local item = favoritesUI.createItem

        if item then
            input.updateContext("main")

            style.popupTitle(IconGlyphs.Group, "Make Prefab")

            local targetCategory = favoritesUI.categories[favoritesUI.createTargetCategoryName]
            local noCategory = targetCategory == nil

            -- Edit name
            drawFieldLabel("Name")
            style.setNextItemWidth(200)
            if favoritesUI.openCreatePopup then
                favoritesUI.openCreatePopup = false
                ImGui.SetKeyboardFocusHere()
            end
            item.name, _ = ImGui.InputTextWithHint("##name", "Name...", item.name, 100)

            -- Select tags (staged only, no save)
            drawFieldLabel("Tags")
            _, favoritesUI.tagAddFilter, favoritesUI.newTag = favoritesUI.drawTagSelectorCombo(item.tags, "createTags", favoritesUI.tagAddFilter, favoritesUI.newTag)

            -- Select category
            drawFieldLabel("Category")
            local categoryName, changed = favoritesUI.drawSelectCategory(not noCategory and favoritesUI.createTargetCategoryName or "No Category")
            if changed then
                favoritesUI.createTargetCategoryName = categoryName
                favoritesUI.newItemCategory = categoryName -- Remember for next time
                targetCategory = favoritesUI.categories[categoryName]
                noCategory = targetCategory == nil
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
                    favoritesUI.createItem = nil
                    ImGui.CloseCurrentPopup()
                end

                -- Create a separate copy instead, letting both coexist
                ImGui.SameLine()
                if ImGui.Button(IconGlyphs.ContentDuplicate .. " Create Copy") then
                    targetCategory:addFavorite(item)
                    favoritesUI.createItem = nil
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
                    favoritesUI.createItem = nil
                    ImGui.CloseCurrentPopup()
                end
                style.tooltip("Create prefab")
            end

            -- Cancel: discard the staged item, nothing is written to disk
            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.Cancel .. " Cancel") then
                favoritesUI.createItem = nil
                ImGui.CloseCurrentPopup()
            end
            style.tooltip("Cancel")
        end

        ImGui.EndPopup()
    elseif not favoritesUI.openCreatePopup then
        favoritesUI.createItem = nil
    end

    if favoritesUI.openCreatePopup then
        ImGui.OpenPopup("##createPrefab")
    end
end

function favoritesUI.removeUnusedTags()
    local tags = favoritesUI.getAllTags("")
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

function favoritesUI.drawActiveTagFilters()
    local tags = utils.getKeys(settings.filterTags)
    table.sort(tags)

    if #tags == 0 then
        return false
    end

    local changed = false

    style.mutedText("Active tag filters (" .. #tags .. "):")
    for i, tag in ipairs(tags) do
        ImGui.SameLine()
        ImGui.PushID("activeTagFilter" .. i)
        if ImGui.Button(tag .. " " .. IconGlyphs.Close) then
            settings.filterTags[tag] = nil
            changed = true
        end
        ImGui.PopID()
    end

    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Close .. " Clear##clearActiveTagFilters") then
        settings.filterTags = {}
        changed = true
    end
    style.pushButtonNoBG(false)

    return changed
end

---@param mergeTags table
---@param newTagName string
---@return number
function favoritesUI.getTagMergeAffectedCount(mergeTags, newTagName)
    if newTagName == "" or utils.tableLength(mergeTags) == 0 then
        return 0
    end

    local affected = 0

    for _, category in pairs(favoritesUI.categories) do
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

function favoritesUI.drawAddCategory()
    favoritesUI.newCategoryIcon, favoritesUI.newCategoryIconSearch, _ = field.drawIconSelector("favoritesUI", favoritesUI.newCategoryIcon, favoritesUI.newCategoryIconSearch)

    ImGui.SameLine()

    style.setNextItemWidth(200)
    favoritesUI.newCategoryName, _ = ImGui.InputTextWithHint("##newCategoryName", "Category Name...", favoritesUI.newCategoryName, 100)

    local categoryExists = favoritesUI.categories[favoritesUI.newCategoryName] ~= nil
    if style.drawNoBGConditionalButton(favoritesUI.newCategoryName ~= "", IconGlyphs.Plus, categoryExists) and not categoryExists then
        local category = require("modules/classes/favorites/category"):new(favoritesUI)
        category:setName(favoritesUI.newCategoryName)
        category.icon = favoritesUI.newCategoryIcon
        category:generateFileName()
        category:save()

        favoritesUI.categories[favoritesUI.newCategoryName] = category
        favoritesUI.newCategoryName = "New Category"
        favoritesUI.newCategoryIcon = "EmoticonOutline"
    end
    if categoryExists then
        style.tooltip("Category already exists.")
    end
end

function favoritesUI.drawSelectCategory(categoryName)
    local changed = false

    style.setNextItemWidth(200)

    if (ImGui.BeginCombo("##selectCategory", (favoritesUI.categories[categoryName] and (IconGlyphs[favoritesUI.categories[categoryName].icon] .. " ") or "") .. categoryName)) then
        input.updateContext("main")

        local interiorWidth = 225 - (2 * ImGui.GetStyle().FramePadding.x) - 30
        style.setNextItemWidth(interiorWidth)
        favoritesUI.selectCategorySearch, _ = ImGui.InputTextWithHint("##selectCategorySearch", "Category Name...", favoritesUI.selectCategorySearch, 100)
        local x, _ = ImGui.GetItemRectSize()

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Close) then
            favoritesUI.selectCategorySearch = ""
        end
        style.pushButtonNoBG(false)

        local categories = utils.getKeys(favoritesUI.categories)
        table.sort(categories)

        local xButton, _ = ImGui.GetItemRectSize()
        if ImGui.BeginChild("##list", x + xButton + ImGui.GetStyle().ItemSpacing.x, 115 * style.viewSize) then
            for _, key in pairs(categories) do
                if utils.safePatternMatch(key:lower(), favoritesUI.selectCategorySearch:lower()) and ImGui.Selectable(IconGlyphs[favoritesUI.categories[key].icon] .. " " .. key) then
                    categoryName = key
                    ImGui.CloseCurrentPopup()
                    changed = true
                end
            end

            ImGui.EndChild()
        end

        ImGui.EndCombo()
    end

    return categoryName, changed
end

local function getFavoritesRowHeight(padding)
    return ImGui.GetFrameHeight() + (padding - style.viewSize) * 2
end

function favoritesUI.pushRow(context)
    ImGui.TableNextRow(ImGuiTableRowFlags.None, getFavoritesRowHeight(context.padding))
    if context.row % 2 == 0 then
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.2, 0.2, 0.2, 0.3)
    else
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.3, 0.3, 0.3, 0.3)
    end

    ImGui.TableNextColumn()
end

function favoritesUI.drawMain()
    local cellPadding = 3 * style.viewSize
    local _, y = ImGui.GetContentRegionAvail()
    y = math.max(y, 300 * style.viewSize)
    local nRows = math.floor(y / getFavoritesRowHeight(cellPadding))

    local context = {
        row = 0,
        depth = 0,
        padding = cellPadding
    }

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, 7.5 * style.viewSize, cellPadding)
    ImGui.PushStyleVar(ImGuiStyleVar.ScrollbarSize, 12 * style.viewSize)

    if ImGui.BeginChild("##favoritesList", -1, y, false) then
        if ImGui.BeginTable("##favoritesListTable", 1, ImGuiTableFlags.ScrollX or ImGuiTableFlags.NoHostExtendX) then
            local keys = utils.getKeys(favoritesUI.categories)
            table.sort(keys)

            for _, key in pairs(keys) do
                context.depth = 0
                favoritesUI.categories[key]:draw(context)
            end

            if context.row < nRows then
                for i = context.row, nRows - 1 do
                    favoritesUI.pushRow(context)
                    context.row = context.row + 1
                end
            end

            ImGui.EndTable()
        end
        ImGui.EndChild()
    end

    ImGui.PopStyleVar(2)
end

function favoritesUI.drawMergeTags()
    local mergeTagOptions = favoritesUI.getAllTags("")
    pruneTagSelections(favoritesUI.tagMergeTags, mergeTagOptions)
    local mergePreview = getTagSelectionPreviewLabel(favoritesUI.tagMergeTags, "No tags selected", "%d tags selected")

    local _, screenHeight = GetDisplayResolution()
    local maxPopupHeight = math.max(200 * style.viewSize, math.min(520 * style.viewSize, screenHeight - 16))

    drawTagMultiSelectLabel("Tags to rename / merge")

    local _, nextMergeSearch = style.drawSearchableMultiSelectCombo({
        comboId = "##tagMergeFilterCombo",
        previewLabel = mergePreview,
        searchHint = "Search tag...",
        searchValue = favoritesUI.tagMergeFilter,
        options = mergeTagOptions,
        selections = favoritesUI.tagMergeTags,
        comboWidth = 160 * style.viewSize,
        searchWidth = 220 * style.viewSize,
        maxPopupHeight = maxPopupHeight,
        emptyText = "No tags available",
        noMatchText = "No matching tags",
        searchInputId = "##tagMergeSearch",
        searchClearButtonId = "##tagMergeSearchClear",
        selectAllButtonId = "##tagMergeSelectAll",
        unselectAllButtonId = "##tagMergeUnselectAll",
        optionIdPrefix = "##tagMergeOption",
        selectAllTooltip = "Select all tags",
        unselectAllTooltip = "Unselect all tags",
        matchesOption = function (option, searchValue)
            return matchesTagSelectorOption(option, searchValue)
        end
    })
    favoritesUI.tagMergeFilter = nextMergeSearch

    drawTagClearButton(
        favoritesUI.tagMergeTags,
        "##tagMergeSelectionClear",
        "Clear selected tags to rename/merge",
        true
    )

    style.mutedText("New tag name")
    ImGui.SameLine()
    style.setNextItemWidth(200)
    favoritesUI.newMergeTag, _ = ImGui.InputTextWithHint("##newMergeTag", "New tag name...", favoritesUI.newMergeTag, 15)

    local selectedTagCount = utils.tableLength(favoritesUI.tagMergeTags)
    local affectedCount = favoritesUI.getTagMergeAffectedCount(favoritesUI.tagMergeTags, favoritesUI.newMergeTag)
    style.mutedText("Selected tags: " .. selectedTagCount .. " | Affected prefabs: " .. affectedCount)

    local canApply = favoritesUI.newMergeTag ~= "" and selectedTagCount > 0 and affectedCount > 0

    ImGui.SameLine()
    style.pushButtonNoBG(true)
    style.pushGreyedOut(not canApply)
    local clicked = ImGui.Button(IconGlyphs.CheckCircleOutline)
    style.popGreyedOut(not canApply)
    style.pushButtonNoBG(false)

    if clicked and canApply then
        local changedAnyCategory = false
        for _, category in pairs(favoritesUI.categories) do
            changedAnyCategory = category:renameTags(favoritesUI.tagMergeTags, favoritesUI.newMergeTag) or changedAnyCategory
        end

        -- Keep active search-tag filters aligned with the merge target so merged entries stay visible.
        local changedFilterTags = false
        if changedAnyCategory then
            for oldTag, _ in pairs(favoritesUI.tagMergeTags) do
                if oldTag ~= favoritesUI.newMergeTag and settings.filterTags[oldTag] then
                    settings.filterTags[oldTag] = nil
                    settings.filterTags[favoritesUI.newMergeTag] = true
                    changedFilterTags = true
                end
            end
        end

        -- Run cleanup immediately so stale tags do not hide entries until the next frame.
        favoritesUI.removeUnusedTags()

        if changedFilterTags then
            settings.save()
        end

        favoritesUI.newMergeTag = ""
        favoritesUI.tagMergeTags = {}
    end

    if not canApply then
        style.tooltip("Select at least one source tag and enter a new name that affects favorites.")
    end
end

function favoritesUI.draw()
    favoritesUI.removeUnusedTags()

    local changed = false

    if favoritesUI.drawActiveTagFilters() then
        settings.save()
    end

    drawFavoritesSpawnOptionsRow()

    if ImGui.TreeNodeEx("Add Category", ImGuiTreeNodeFlags.SpanFullWidth) then
        favoritesUI.drawAddCategory()

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Rename Tags", ImGuiTreeNodeFlags.SpanFullWidth) then
        favoritesUI.drawMergeTags()

        ImGui.TreePop()
    end

    style.spacedSeparator()

    ImGui.SetNextItemWidth(300 * style.viewSize)
    settings.favoritesFilter, changed = ImGui.InputTextWithHint("##filter", "Search by name... (Supports pattern matching)", settings.favoritesFilter, 100)
    if changed then
        scheduleFavoritesFilterSave()
    end

    if style.drawNoBGConditionalButton(settings.favoritesFilter ~= "", IconGlyphs.Close) then
        settings.favoritesFilter = ""
        flushFavoritesFilterSave()
    end

    ImGui.SameLine()
    style.mutedText(IconGlyphs.InformationOutline)
    style.tooltip("Supports custom search query syntax:\n- | (OR), includes any terms including the word after the |\n- ! (NOT), excludes any terms including the word after the !\n- & (AND), terms must include the word after the &\n- E.g. table|chair!poor&low to match any terms that include 'table' or 'chair', but not 'poor', and must include 'low'")

    local compactButtonWidth = 25 * style.viewSize
    local controlsCount = 2
    local controlsWidth = compactButtonWidth * controlsCount + ImGui.GetStyle().ItemSpacing.x * (controlsCount - 1)

    ImGui.SameLine()
    ImGui.SetCursorPosX(ImGui.GetWindowWidth() - controlsWidth)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload) then
        favoritesUI.categories = {}
        favoritesUI.init(favoritesUI.spawnUI.spawner)
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reload favorites from disk")

    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.CogOutline .. "##favoritesSpawnOptionsButton") then
        ImGui.OpenPopup(FAVORITES_SPAWN_OPTIONS_POPIN_ID)
    end
    style.pushButtonNoBG(false)
    style.tooltip("Favorites spawn options")

    drawFavoritesSpawnOptionsPopup()

    local searchTagOptions = favoritesUI.getAllTags("")
    pruneTagSelections(settings.filterTags, searchTagOptions)
    local searchTagPreview = getTagSelectionPreviewLabel(settings.filterTags, "All tags", "%d tags selected")
    local _, screenHeight = GetDisplayResolution()
    local maxPopupHeight = math.max(200 * style.viewSize, math.min(520 * style.viewSize, screenHeight - 16))

    drawTagMultiSelectLabel("Search Tags")

    local tagsChanged, nextTagSearch = style.drawSearchableMultiSelectCombo({
        comboId = "##searchTagsFilterCombo",
        previewLabel = searchTagPreview,
        searchHint = "Search tag...",
        searchValue = favoritesUI.tagFilterFilter,
        options = searchTagOptions,
        selections = settings.filterTags,
        comboWidth = 160 * style.viewSize,
        searchWidth = 220 * style.viewSize,
        maxPopupHeight = maxPopupHeight,
        emptyText = "No tags available",
        noMatchText = "No matching tags",
        searchInputId = "##searchTagsFilterSearch",
        searchClearButtonId = "##searchTagsFilterSearchClear",
        selectAllButtonId = "##searchTagsSelectAll",
        unselectAllButtonId = "##searchTagsUnselectAll",
        optionIdPrefix = "##searchTagsOption",
        selectAllTooltip = "Select all tags",
        unselectAllTooltip = "Unselect all tags (default behavior: show all)",
        showAndFilterToggle = true,
        andFilterState = settings.favoritesTagsAND,
        andFilterTooltip = "AND filter mode (Leave off for OR filter)",
        onAndFilterChanged = function (nextAndFilter)
            settings.favoritesTagsAND = nextAndFilter
            settings.save()
        end,
        matchesOption = function (option, searchValue)
            return matchesTagSelectorOption(option, searchValue)
        end
    })
    favoritesUI.tagFilterFilter = nextTagSearch
    local searchTagSelectionChanged = drawTagClearButton(
        settings.filterTags,
        "##searchTagsSelectionClear",
        "Clear selected tag filters",
        true
    )
    if tagsChanged or searchTagSelectionChanged then
        settings.save()
    end

    style.spacedSeparator()

    favoritesUI.drawMain()
end

return favoritesUI
