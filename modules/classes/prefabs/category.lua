local utils = require("modules/utils/utils")
local field = require("modules/utils/field")
local style = require("modules/ui/style")
local config = require("modules/utils/config")
local settings = require("modules/utils/settings")
local input = require("modules/utils/input")
local logger = require("modules/utils/logger")
local assetFavorites = require("modules/utils/assetFavorites")

local SPAWNABLE_ELEMENT_MODULE_PATH = "modules/classes/editor/spawnableElement"

---@class category
---@field name string
---@field icon string
---@field headerOpen boolean
---@field favorites favorite[]
---@field grouped boolean
---@field prefabsUI prefabsUI
---@field fileName string
---@field openPopup boolean
---@field editName string
---@field changeIconSearch string
---@field mergeCategorySearch string
---@field isVirtualGroup boolean
---@field virtualGroupTags string[]
---@field virtualGroups category[]
---@field virtualGroupPath string
---@field numFavoritesFiltered number
---@field root category?
local category = {}

---@param value any
---@return boolean
local function asBool(value)
	return value == true
end

---@return table
local function getAllGroupingStates()
	if type(settings.favoritesGroupingState) ~= "table" then
		settings.favoritesGroupingState = {}
	end

	return settings.favoritesGroupingState
end

---@param fileName string
---@param create boolean?
---@return table?
local function getGroupingState(fileName, create)
	if fileName == nil or fileName == "" then
		return nil
	end

	local allStates = getAllGroupingStates()
	local state = allStates[fileName]
	if state == nil and create then
		state = {
			grouped = false,
			virtualGroups = {}
		}
		allStates[fileName] = state
	end

	if type(state) ~= "table" then
		return nil
	end

	if type(state.virtualGroups) ~= "table" then
		state.virtualGroups = {}
	end

	return state
end

---@param fileName string
---@param virtualPath string?
---@return boolean
local function getGroupedState(fileName, virtualPath)
	local state = getGroupingState(fileName, false)
	if not state then
		return false
	end

	if virtualPath and virtualPath ~= "" then
		return asBool(state.virtualGroups[virtualPath])
	end

	return asBool(state.grouped)
end

---@param fileName string
---@param virtualPath string?
---@param grouped boolean
local function setGroupedState(fileName, virtualPath, grouped)
	local state = getGroupingState(fileName, true)
	if not state then
		return
	end

	local nextValue = grouped == true
	local changed = false

	if virtualPath and virtualPath ~= "" then
		if asBool(state.virtualGroups[virtualPath]) ~= nextValue then
			state.virtualGroups[virtualPath] = nextValue
			changed = true
		end
	else
		if asBool(state.grouped) ~= nextValue then
			state.grouped = nextValue
			changed = true
		end
	end

	if changed then
		settings.save()
	end
end

---@param fileName string
local function clearGroupedState(fileName)
	local allStates = getAllGroupingStates()
	if allStates[fileName] ~= nil then
		allStates[fileName] = nil
		settings.save()
	end
end

---@param fUI prefabsUI
---@return category
function category:new(fUI)
	local o = {}

	o.name = "New Category"
	o.icon = ""
	o.headerOpen = false
	o.favorites = {}
	o.grouped = false

    o.prefabsUI = fUI
	o.fileName = ""
	o.openPopup = false
	o.editName = ""
	o.changeIconSearch = ""
	o.mergeCategorySearch = "Merge Target"

	o.isVirtualGroup = false
	o.virtualGroupPath = ""
	o.virtualGroupTags = {}
	o.virtualGroups = {}
	o.numFavoritesFiltered = 0
	o.root = nil

	self.__index = self
   	return setmetatable(o, self)
end

---Loads the data from a given table, containing the same data as exported during save()
function category:load(data, fileName)
	self:setName(data.name)
	self.headerOpen = false
    self.icon = data.icon
	self.fileName = fileName
	self.grouped = false

	self.isVirtualGroup = data.isVirtualGroup or false
	self.virtualGroupPath = data.virtualGroupPath or ""
	self.virtualGroupTags = data.virtualGroupTags or {}
	self.virtualGroups = {}
	self.root = data.root

	if self.isVirtualGroup then
		self.favorites = data.favorites
		self.grouped = getGroupedState(self.fileName, self.virtualGroupPath)
	else
		self.grouped = getGroupedState(self.fileName, nil)
		for _, favoriteData in pairs(data.favorites) do
			local favorite = require("modules/classes/prefabs/prefab"):new(self.prefabsUI)
			favorite:load(favoriteData)
			-- Loading from disk should not trigger a save of unchanged data.
			self:addFavorite(favorite, false)
		end
	end

	if self.grouped then
		self:loadVirtualGroups()
	end
end

function category:setName(name)
	self.name = name
	self.editName = name
end

function category:generateFileName()
	self.fileName = utils.createFileName(self.name) .. "_" .. tostring(os.time()) .. ".json"
end

---@param favorite favorite
---@param persist boolean? Defaults to true. Pass false for bulk-load paths that should not write to disk.
function category:addFavorite(favorite, persist)
	table.insert(self.favorites, favorite)
	favorite:setCategory(self.root or self)

	if persist ~= false then
		self:save()

		if self.grouped then
			self:loadVirtualGroups()
		end
	end
end

function category:removeFavorite(favorite)
	for key, data in pairs(self.favorites) do
		if data == favorite then
			table.remove(self.favorites, key)
			break
		end
	end

	self:save()

	if self.grouped then
		self:loadVirtualGroups()
	end
end

function category:isNameDuplicate(name)
	local found = 0

	for _, favorite in pairs(self.favorites) do
		if favorite.name == name and found < 2 then
			found = found + 1
			if found == 2 then
				return true
			end
		end
	end

	return false
end

function category:renameTags(tags, newName)
	local changed = false

	for _, favorite in pairs(self.favorites) do
		local toRename = {}

		for tag, _ in pairs(favorite.tags) do
			if tags[tag] and tag ~= newName then
				table.insert(toRename, tag)
			end
		end

		if #toRename > 0 then
			favorite.tags[newName] = true
			for _, tag in pairs(toRename) do
				favorite.tags[tag] = nil
			end
			changed = true
		end
	end

	if changed then
		if self.grouped then
			self:loadVirtualGroups()
		end
		self:save()
	end

	return changed
end

---@param toMerge category
function category:merge(toMerge)
	config.saveFile("data/favorite/preMerge/" .. self.fileName, self:serialize())
	config.saveFile("data/favorite/preMerge/" .. toMerge.fileName, toMerge:serialize())

	local merges = 0

	for _, favorite in pairs(toMerge.favorites) do
		local wasMerged = false

		for _, ownFavorite in pairs(self.favorites) do
			if favorite.data.modulePath == "modules/classes/editor/spawnableElement" and utils.canMergeFavorites(favorite.data, ownFavorite.data) then
				for tag, _ in pairs(favorite.tags) do
					ownFavorite.tags[tag] = true
				end
				wasMerged = true
				merges = merges + 1
			end
		end

		if not wasMerged then
			table.insert(self.favorites, favorite)
			favorite:setCategory(self)
		end
	end

	if self.grouped then
		self:loadVirtualGroups()
	end

	self:save()

	toMerge:delete()

	logger:info(string.format("[%s] Merged %s into %s, resulting in the merging of %d favorites.", settings.mainWindowName, toMerge.name, self.name, merges))
end

---Indexes the entries of one spawn list by the key favorites are stored under.
---Built lazily, and only for the lists a single conversion run actually touches.
---@param spawnList table
---@param modulePath string
---@param cache table<string, table<string, table>>
---@return table<string, table>
local function getSpawnListEntriesByKey(spawnList, modulePath, cache)
	local index = cache[modulePath]
	if index then
		return index
	end

	index = {}
	for _, entry in pairs(spawnList.data or {}) do
		if type(entry) == "table" and type(entry.name) == "string" then
			index[entry.name] = entry
		end
	end
	cache[modulePath] = index

	return index
end

---Resolves the asset favorite one prefab of this category maps to.
---Only single asset prefabs referencing an entry of a path based spawn list qualify:
---a favorite is a pure asset bookmark, so prefabs holding several assets, and spawnables
---defined by configuration instead of an asset path, have no favorite representation.
---@param favorite favorite
---@return {modulePath: string, path: string, name: string, spawnList: table}?
function category:getAssetFavoriteTarget(favorite)
	local data = favorite and favorite.data

	if type(data) ~= "table" or data.modulePath ~= SPAWNABLE_ELEMENT_MODULE_PATH or type(data.spawnable) ~= "table" then
		return nil
	end

	local modulePath = tostring(data.spawnable.modulePath or "")
	local assetPath = tostring(data.spawnable.spawnData or "")

	if modulePath == "" or assetPath == "" then
		return nil
	end

	local spawnUI = self.prefabsUI and self.prefabsUI.spawnUI
	local spawnList = spawnUI and spawnUI.getSpawnListByModulePath(modulePath)

	if not spawnList or not spawnList.isPaths then
		return nil
	end

	local name = utils.trimString(favorite.name or "")

	return {
		modulePath = modulePath,
		path = assetPath,
		name = name ~= "" and name or utils.getFileName(assetPath),
		spawnList = spawnList
	}
end

---How many prefabs of this category can be turned into asset favorites.
---@return number convertible Single asset prefabs that can be favorited
---@return number alreadyFavorite How many of those are favorited already
function category:getAssetFavoriteConversionStats()
	local convertible, alreadyFavorite = 0, 0

	for _, favorite in pairs(self.favorites) do
		local target = self:getAssetFavoriteTarget(favorite)

		if target then
			convertible = convertible + 1

			if assetFavorites.isFavorite(target.modulePath, target.path) then
				alreadyFavorite = alreadyFavorite + 1
			end
		end
	end

	return convertible, alreadyFavorite
end

---Adds every single asset prefab of this category to the asset favorites.
---The prefabs themselves are kept: this copies the asset references over, it does not move them.
---Each favorite is tagged with the category name, plus the tags of its prefab, so the
---category layout survives in the tag grouped favorites list.
---@return number added Newly favorited assets
---@return number updated Already favorited assets that gained tags
---@return number skipped Prefabs holding no bookmarkable asset, or already up to date
function category:convertToAssetFavorites()
	local added, updated, skipped = 0, 0, 0
	local categoryTag = utils.trimString(self.name or "")
	local spawnListIndexes = {}

	-- One disk write for the whole category, instead of one per favorite and per tag.
	assetFavorites.runBatch(function ()
		if categoryTag ~= "" then
			assetFavorites.createTag(categoryTag, self.icon)
		end

		for _, favorite in pairs(self.favorites) do
			local target = self:getAssetFavoriteTarget(favorite)
			local existing = target and assetFavorites.get(target.modulePath, target.path) or nil
			local entry = existing

			if target and not existing then
				-- Favorite the pristine spawn list entry, not the configured prefab: a
				-- favorite bookmarks the asset itself. Paths typed by hand are not listed,
				-- and fall back to the plain asset reference.
				local listEntry = getSpawnListEntriesByKey(target.spawnList, target.modulePath, spawnListIndexes)[target.path]
				local entryData = type(listEntry) == "table" and type(listEntry.data) == "table" and listEntry.data or { spawnData = target.path }

				entry = assetFavorites.add(target.modulePath, target.path, target.name, entryData)
			end

			if not entry then
				skipped = skipped + 1
			else
				local gainedTag = false

				if categoryTag ~= "" and not entry.tags[categoryTag] then
					assetFavorites.setEntryTag(entry, categoryTag, true)
					gainedTag = true
				end

				for tag, _ in pairs(favorite.tags or {}) do
					if not entry.tags[tag] then
						assetFavorites.setEntryTag(entry, tag, true)
						gainedTag = true
					end
				end

				if not existing then
					added = added + 1
				elseif gainedTag then
					updated = updated + 1
				else
					skipped = skipped + 1
				end
			end
		end
	end)

	logger:info(string.format("[%s] Converted category \"%s\" to favorites: %d added, %d updated, %d skipped.", settings.mainWindowName, self.name, added, updated, skipped))

	return added, updated, skipped
end

---Draws the "convert this category to asset favorites" row of the settings popup.
function category:drawConvertToFavorites()
	local convertible, alreadyFavorite = self:getAssetFavoriteConversionStats()
	local canConvert = convertible > 0

	style.mutedText("To favorites:")
	ImGui.SameLine()

	style.pushGreyedOut(not canConvert)
	local clicked = ImGui.Button(IconGlyphs.StarBoxOutline .. " Convert")
	style.popGreyedOut(not canConvert)

	if canConvert then
		style.tooltip(string.format(
			"Adds every single asset prefab of this category to the favorites.\n" ..
			"%d of the %d prefabs hold a single asset (%d already favorited).\n" ..
			"Prefabs holding several assets are skipped: a favorite only bookmarks one asset, without any configuration.\n" ..
			"Each favorite is tagged with the category name, and with the tags of its prefab.\n" ..
			"The prefabs themselves are kept.",
			convertible, #self.favorites, alreadyFavorite
		))
	else
		style.tooltip("No prefab of this category holds a single favoritable asset.\nFavorites only bookmark assets of the \"All\" sub-tab, without any configuration.")
	end

	if not clicked or not canConvert then return end

	local added, updatedCount, skipped = self:convertToAssetFavorites()
	ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("%d favorite(s) added, %d updated, %d skipped", added, updatedCount, skipped)))
end

function category:drawEditPopup()
	if ImGui.IsPopupOpen("##editCategory" .. self.fileName) then
        style.setCursorRelativeAppearing(-5, -5)
    end

	if ImGui.BeginPopup("##editCategory" .. self.fileName) then
        input.updateContext("main")

		style.popupTitle(IconGlyphs.CogOutline, "Category Settings")

		self.icon, self.changeIconSearch, changed = field.drawIconSelector("favoriteCategory:" .. self.fileName, self.icon, self.changeIconSearch)
		if changed then
			self:save()
		end

		ImGui.SameLine()

        -- Edit name
        style.setNextItemWidth(200)
        if self.openPopup then
            self.openPopup = false
            ImGui.SetKeyboardFocusHere()
        end
        self.editName, changed = ImGui.InputTextWithHint("##name", "Name...", self.editName, 100)
        if ImGui.IsItemDeactivatedAfterEdit() then
			if not self.prefabsUI.categories[self.editName] then
				self.prefabsUI.updateCategoryName(self.name, self.editName)
				self.name = self.editName
				self:save()
			else
				self.editName = self.name
			end
		end
		if self.name ~= self.editName and self.prefabsUI.categories[self.editName] then
			ImGui.SameLine()
            style.styledText(IconGlyphs.AlertOutline, 0xFF0000FF)
            style.tooltip("Category with this name already exists.")
		end

		style.mutedText("Merge into:")
		ImGui.SameLine()
		self.mergeCategorySearch, _ = self.prefabsUI.drawSelectCategory(self.mergeCategorySearch)
		ImGui.SameLine()

		local invalidTarget = self.mergeCategorySearch == self.name or not self.prefabsUI.categories[self.mergeCategorySearch]
		if invalidTarget then
			style.styledText(IconGlyphs.AlertOutline, 0xFF0000FF)
			style.tooltip("Invalid merge target category name.")
		else
			if style.warnButton(IconGlyphs.CallMerge .. " Merge", { tooltip = "Merge this category into the selected one. This category will be deleted." }) then
				self.prefabsUI.categories[self.mergeCategorySearch]:merge(self)
			end
		end

		self:drawConvertToFavorites()

		ImGui.Separator()

		-- Close dismisses the popup; edits are saved live so nothing extra is needed here.
		if ImGui.Button(IconGlyphs.CheckboxMarkedCircleOutline .. " Close") then
			ImGui.CloseCurrentPopup()
		end

		ImGui.SameLine()
		style.dangerButton(IconGlyphs.DeleteOutline .. " Delete")
		if ImGui.BeginPopupContextItem("Delete Category?", ImGuiPopupFlags.MouseButtonLeft) then
			style.mutedText("Are you sure you want to delete this category?")
			if style.dangerButton(IconGlyphs.DeleteOutline .. " Confirm") then
				ImGui.CloseCurrentPopup()
				self:delete()
			end
			ImGui.SameLine()
			if ImGui.Button(IconGlyphs.Cancel .. " Cancel") then
				ImGui.CloseCurrentPopup()
			end
			ImGui.EndPopup()
		end

		ImGui.EndPopup()
    end

    if self.openPopup then
        ImGui.OpenPopup("##editCategory" .. self.fileName)
    end
end

function category:drawSideButtons()
	ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 2 * (ImGui.GetFontSize() / 15))

    -- Right side buttons
    local settingsX, _ = ImGui.CalcTextSize(IconGlyphs.FileTreeOutline)
    local groupX, _ = ImGui.CalcTextSize(IconGlyphs.CogOutline)
	if self.isVirtualGroup then settingsX = 0 end
	local totalX = settingsX + groupX + ImGui.GetStyle().ItemSpacing.x * 2
    style.setCursorRightAligned(totalX)

	local grouped = self.grouped
	style.pushStyleColor(not grouped, ImGuiCol.Text, style.mutedColor)
	ImGui.SetNextItemAllowOverlap()
	if ImGui.Button(IconGlyphs.FileTreeOutline) then
		self.grouped = not self.grouped
		self:loadVirtualGroups()
		-- Grouping toggle is UI state; persist it to config without rewriting favorites JSON.
		self:save(true)
	end
	style.popStyleColor(not grouped)
	style.tooltip("Group by tags")

	if self.isVirtualGroup then return end

	ImGui.SameLine()
	ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 2 * (ImGui.GetFontSize() / 15))

	ImGui.SetNextItemAllowOverlap()
	if ImGui.Button(IconGlyphs.CogOutline) then
		self.openPopup = true
	end
end

function category:drawEntries(context, entries)
	if self.headerOpen then
		context.depth = context.depth + 1
		for _, entry in pairs(entries) do
			entry:draw(context)
		end
		context.depth = context.depth - 1
	end
end

function category:loadVirtualGroups()
	self.virtualGroups = {}
	local tags = {}
	local noTag = {}

	local function hasExactTagSet(favoriteTags, groupTags)
		for groupTag, _ in pairs(groupTags) do
			if not favoriteTags[groupTag] then
				return false
			end
		end

		for favoriteTag, _ in pairs(favoriteTags) do
			if not groupTags[favoriteTag] then
				return false
			end
		end

		return true
	end

	local anyTag = false
	for _, favorite in pairs(self.favorites) do
		for tag, _ in pairs(favorite.tags) do
			if not self.virtualGroupTags[tag] then
				if not tags[tag] then
					tags[tag] = {}
				end

				table.insert(tags[tag], favorite)
				anyTag = true
			end
		end
		if hasExactTagSet(favorite.tags, self.virtualGroupTags) then
			table.insert(noTag, favorite)
		end
	end

	if not anyTag then
		self.grouped = false
		return
	end

	if #noTag > 0 then
		tags["No Tag"] = noTag
	end

	for tag, group in pairs(tags) do
		local cat = require("modules/classes/prefabs/category"):new(self.prefabsUI)
		local virtualGroupTags = utils.deepcopy(self.virtualGroupTags)
		virtualGroupTags[tag] = true

		cat:load({
			name = tag,
			headerOpen = false,
			grouped = false,
			favorites = group,
			isVirtualGroup = true,
			virtualGroupTags = virtualGroupTags,
			virtualGroupPath = self.virtualGroupPath .. "/" .. tag,
			root = self.root or self
		}, self.fileName)

		table.insert(self.virtualGroups, cat)
	end
end

function category:getFilteredFavorites()
	local entries = {}

	for _, favorite in pairs(self.favorites) do
		if favorite:isMatch(settings.favoritesFilter, settings.filterTags) then
			table.insert(entries, favorite)
		end
	end

	table.sort(entries, function(a, b) return a.name < b.name end)

	return entries
end

function category:getFilteredEntries()
	local entries = {}

	if not self.grouped then
		entries = self:getFilteredFavorites()
	else
		for _, group in pairs(self.virtualGroups) do
			group.numFavoritesFiltered = #group:getFilteredFavorites()
			if group.numFavoritesFiltered > 0 then
				table.insert(entries, group)
			end
		end

		table.sort(entries, function(a, b)
			if a.numFavoritesFiltered == b.numFavoritesFiltered then
				return a.name < b.name
			end

			return a.numFavoritesFiltered > b.numFavoritesFiltered
		end)
	end

	return entries
end

---@param context {padding: number, row: number, depth: number}
function category:draw(context)
	local filtered = self:getFilteredEntries()

	if #filtered == 0 and not (#self.favorites == 0) then
		return
	end

	self.prefabsUI.pushRow(context)

	ImGui.PushID(context.row)

	ImGui.SetCursorPosX((context.depth) * 17 * style.viewSize)
	ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 4 * style.viewSize, context.padding * 2 + style.viewSize)

    local newState = ImGui.Selectable("##category" .. context.row, self.headerOpen, ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowOverlap)
	if self.headerOpen ~= newState then
		self.headerOpen = newState
	end
	context.row = context.row + 1

	ImGui.SameLine()
	style.pushListRowContent()

	ImGui.SetNextItemAllowOverlap()
	if ImGui.Button(self.headerOpen and IconGlyphs.MenuDownOutline or IconGlyphs.MenuRightOutline) then
		self.headerOpen = not self.headerOpen
	end
	ImGui.SameLine()
	if self.icon ~= "" then
		ImGui.AlignTextToFramePadding()
		ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 2 * style.viewSize)
		ImGui.Text(IconGlyphs[self.icon])
	end
	ImGui.SameLine()
	ImGui.AlignTextToFramePadding()
	ImGui.SetNextItemAllowOverlap()
	ImGui.Text(self.name .. ((self.isVirtualGroup and not self.grouped) and (" (" .. #filtered .. ")") or ""))

	ImGui.SameLine()
	self:drawSideButtons()

	style.popListRowContent(1)

	ImGui.PopID()

	if not self.isVirtualGroup then
		self:drawEditPopup()
	end

	self:drawEntries(context, filtered)
end

function category:serialize()
	local data = {
		name = self.name,
		icon = self.icon,
		favorites = {}
	}

	for _, favorite in pairs(self.favorites) do
		table.insert(data.favorites, favorite:serialize())
	end

	return data
end

---@param stateOnly boolean? When true, only persist grouped-state settings and skip writing favorite JSON.
function category:save(stateOnly)
	if self.isVirtualGroup then
		setGroupedState(self.fileName, self.virtualGroupPath, self.grouped)
		return
	end

	setGroupedState(self.fileName, nil, self.grouped)

	if stateOnly then
		return
	end

	local data = self:serialize()

	config.saveFile("data/favorite/" .. self.fileName, data)
end

function category:delete()
	if self.isVirtualGroup then return end

	os.remove("data/favorite/" .. self.fileName)
	clearGroupedState(self.fileName)
	self.prefabsUI.categories[self.name] = nil
end

return category
