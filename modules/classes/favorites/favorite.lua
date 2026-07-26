local utils = require("modules/utils/utils")
local settings = require("modules/utils/settings")
local style = require("modules/ui/style")
local editor = require("modules/utils/editor/editor")
local prefabPreview = require("modules/utils/prefabPreview")

---@class favorite
---@field name string
---@field tags table
---@field data positionable
---@field category category?
---@field icon string
---@field assetCount number?
---@field favoritesUI favoritesUI
---@field spawnUI spawnUI
local favorite = {}
local iconResolveCache = {}
local SPAWNABLE_ELEMENT_MODULE_PATH = "modules/classes/editor/spawnableElement"
local POSITIONABLE_GROUP_MODULE_PATH = "modules/classes/editor/positionableGroup"

local isSerializedSpawnable = utils.isSerializedSpawnable
local isSerializedGroup = utils.isSerializedGroup

---@param data table?
---@return number?
local function getSerializedAssetCount(data)
    if isSerializedSpawnable(data) then
        return 1
    end

    if not isSerializedGroup(data) then
        return nil
    end

    local directCount = tonumber(data.elementCount)
    if directCount then
        return math.max(0, math.floor(directCount))
    end

    local count = 0
    local stack = { data }

    while #stack > 0 do
        local current = table.remove(stack)

        for _, child in pairs(current.childs or {}) do
            if isSerializedSpawnable(child) then
                count = count + 1
            elseif isSerializedGroup(child) then
                local childCount = tonumber(child.elementCount)
                if childCount then
                    count = count + math.max(0, math.floor(childCount))
                else
                    table.insert(stack, child)
                end
            end
        end
    end

    return count
end

---@param iconGlyph string?
---@return string
local function iconKeyFromGlyph(iconGlyph)
    if not iconGlyph or iconGlyph == "" then
        return ""
    end

    local iconKey = utils.indexValue(IconGlyphs, iconGlyph)
    if iconKey == -1 then
        return ""
    end

    return iconKey
end

---@param data table?
---@return string
local function resolveIconKeyFromModulePath(data)
    if type(data) ~= "table" then
        return ""
    end

    local modulePath = data.modulePath
    if type(modulePath) ~= "string" or modulePath == "" then
        return ""
    end

    local cacheKey = modulePath
    if modulePath == SPAWNABLE_ELEMENT_MODULE_PATH then
        cacheKey = cacheKey .. "|" .. tostring(data.spawnable and data.spawnable.modulePath or "")
    end

    if iconResolveCache[cacheKey] ~= nil then
        return iconResolveCache[cacheKey]
    end

    if modulePath == SPAWNABLE_ELEMENT_MODULE_PATH then
        local spawnablePath = data.spawnable and data.spawnable.modulePath
        if type(spawnablePath) == "string" and spawnablePath ~= "" then
            local okRequire, spawnableClass = pcall(require, "modules/classes/spawn/" .. spawnablePath)
            if okRequire and spawnableClass and spawnableClass.new then
                local okNew, spawnable = pcall(function ()
                    return spawnableClass:new()
                end)
                if okNew and spawnable then
                    local resolved = iconKeyFromGlyph(spawnable.icon)
                    if resolved ~= "" then
                        iconResolveCache[cacheKey] = resolved
                        return resolved
                    end
                end
            end
        end

        local fallback = iconKeyFromGlyph(IconGlyphs.CubeOutline)
        iconResolveCache[cacheKey] = fallback
        return fallback
    end

    if modulePath == POSITIONABLE_GROUP_MODULE_PATH then
        local groupIcon = iconKeyFromGlyph(IconGlyphs.Group)
        iconResolveCache[cacheKey] = groupIcon
        return groupIcon
    end

    local okRequire, elementClass = pcall(require, modulePath)
    if okRequire and elementClass and elementClass.new then
        local okNew, element = pcall(function ()
            return elementClass:new(nil)
        end)
        if okNew and element then
            local resolved = iconKeyFromGlyph(element.icon)
            if resolved ~= "" then
                iconResolveCache[cacheKey] = resolved
                return resolved
            end
        end
    end

    iconResolveCache[cacheKey] = ""
    return ""
end

---@param fUI favoritesUI
---@return favorite
function favorite:new(fUI)
	local o = {}

	o.name = "New Favorite"
    o.tags = {}
    o.data = nil
    o.category = nil
    o.icon = ""
    o.assetCount = nil

    o.favoritesUI = fUI
    o.spawnUI = fUI.spawnUI

	self.__index = self
   	return setmetatable(o, self)
end

---Loads the data from a given table, containing the same data as exported during serialize()
function favorite:load(data)
	self.name = data.name
    self.tags = data.tags
    self.data = data.data
    self.icon = data.icon or ""
    self.assetCount = nil

    if self.icon == "" or not IconGlyphs[self.icon] then
        self.icon = resolveIconKeyFromModulePath(self.data)
    end
end

function favorite:setCategory(category)
    self.category = category
end

function favorite:isMatch(stringFilter, tagFilter)
    if not utils.matchSearch(self.name, stringFilter) then return false end

    if utils.tableLength(tagFilter) == 0 then
        return true
    end

    if utils.tableLength(self.tags) == 0 then
        return false
    end

    for tag, _ in pairs(tagFilter) do
        if self.tags[tag] and not settings.favoritesTagsAND then return true end
        if not self.tags[tag] and settings.favoritesTagsAND then
            return false
        end
    end

    return settings.favoritesTagsAND
end

function favorite:checkIsDuplicate()
    if not self.category then return false end

    for _, fav in pairs(self.category.favorites) do
        if fav ~= self and utils.canMergeFavorites(fav.data, self.data) then
            return true
        end
	end

    return false
end

---@return number?
function favorite:getAssetCount()
    if self.assetCount == nil then
        self.assetCount = getSerializedAssetCount(self.data)
    end

    return self.assetCount
end

---@param assetCount number?
function favorite:drawSideButtons(assetCount)
    -- Right side buttons
    local settingsX, _ = ImGui.CalcTextSize(IconGlyphs.CogOutline)
    local countCogSpacing = math.max(ImGui.GetStyle().ItemSpacing.x, 24 * style.viewSize)
    local countText = assetCount and tostring(assetCount) or nil
    local countX = 0
    if countText then
        countX, _ = ImGui.CalcTextSize(countText)
    end

	local totalX = settingsX + ImGui.GetStyle().ItemSpacing.x
    if countText then
        totalX = totalX + countX + countCogSpacing
    end
    local scrollBarAddition = ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0
    local cursorX = ImGui.GetWindowWidth() - totalX - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()
    ImGui.SetCursorPosX(cursorX)

    if countText then
        ImGui.SetNextItemAllowOverlap()
        ImGui.AlignTextToFramePadding()
        style.mutedText(countText)
        style.tooltip("Quantity assets")
        ImGui.SameLine()
        ImGui.SetCursorPosX(cursorX + countX + countCogSpacing)
    end
    
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 1 * style.viewSize)
	ImGui.SetNextItemAllowOverlap()
	if ImGui.Button(IconGlyphs.CogOutline) then
		self.favoritesUI.openPopup = true
        self.favoritesUI.popupItem = self
        self.favoritesUI.popupItemConflict = self:checkIsDuplicate()
	end
end

function favorite:draw(context)
    self.favoritesUI.pushRow(context)

	ImGui.PushID(context.row)

	ImGui.SetCursorPosX((context.depth) * 17 * style.viewSize)
	ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 4 * style.viewSize, context.padding * 2 + style.viewSize)

    if ImGui.Selectable("##favorite" .. context.row, false, ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowOverlap) then
        self.spawnUI.spawnNew({ data = self.data }, require(self.data.modulePath), true)
    elseif ImGui.IsMouseDragging(0, style.draggingThreshold) and not self.spawnUI.dragging and ImGui.IsItemHovered() then
        self.spawnUI.dragging = true
        self.spawnUI.dragData = { data = self.data, name = self.name }
    elseif not ImGui.IsMouseDragging(0, style.draggingThreshold) and self.spawnUI.dragging then
        if not ImGui.IsItemHovered() then
            local ray = editor.getScreenToWorldRay()
            self.spawnUI.popupSpawnHit = editor.getRaySceneIntersection(ray, GetPlayer():GetFPPCameraComponent():GetLocalToWorld():GetTranslation(), nil, true)

            spawnUI.dragData.lastSpawned = spawnUI.spawnNew(self.spawnUI.dragData, require(self.data.modulePath), true)
        end

        self.spawnUI.dragging = false
        self.spawnUI.dragData = nil
        self.spawnUI.popupSpawnHit = nil
    end

    if ImGui.BeginPopupContextItem("##favoriteContext", ImGuiPopupFlags.MouseButtonRight) then
        if ImGui.MenuItem("Spawn as Hidden") then
            self.spawnUI.spawnNew({ data = self.data }, require(self.data.modulePath), true, { loadHidden = true })
        end

        ImGui.Separator()

        -- Nested confirm so a single misclick can't delete a prefab (removal is not undoable).
        if ImGui.BeginMenu(IconGlyphs.DeleteOutline .. " Delete") then
            if ImGui.MenuItem("Confirm delete") then
                if self.category then
                    self.category:removeFavorite(self)
                end
            end
            ImGui.EndMenu()
        end

        ImGui.EndPopup()
    end

    -- Asset preview
    local isSingleAsset = self.data.modulePath == SPAWNABLE_ELEMENT_MODULE_PATH
    if isSingleAsset and ImGui.IsItemHovered() and settings.assetPreviewEnabled[self.data.spawnable.modulePath] then
        self.spawnUI.handleAssetPreviewHovered(self, true)
    elseif not isSingleAsset and ImGui.IsItemHovered() and prefabPreview.isPreviewable(self.data, self:getAssetCount()) then
        self.spawnUI.handlePrefabPreviewHovered(self)
    elseif self.spawnUI.hoveredEntry == self and (self.spawnUI.previewInstance or self.spawnUI.previewTimer or prefabPreview.isActive()) then
        self.spawnUI.hoveredEntry = nil
        self.spawnUI.stopActiveAssetPreview()
    end

	context.row = context.row + 1

	ImGui.SameLine()
	ImGui.PushStyleColor(ImGuiCol.Button, 0)
	ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.2)
	ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
	ImGui.PushStyleVar(ImGuiStyleVar.ButtonTextAlign, 0.5, 0.5)
	ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 1 * style.viewSize)

	ImGui.SetNextItemAllowOverlap()
	if self.icon ~= "" then
		ImGui.AlignTextToFramePadding()
		ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 2 * style.viewSize)
		ImGui.Text(IconGlyphs[self.icon])
	end
	ImGui.SameLine()
	ImGui.AlignTextToFramePadding()
	ImGui.SetNextItemAllowOverlap()
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 1 * style.viewSize)
	ImGui.Text(self.name)

	ImGui.SameLine()
	self:drawSideButtons(self:getAssetCount())

	ImGui.PopStyleColor(2)
	ImGui.PopStyleVar(3)

	ImGui.PopID()
end

function favorite:serialize()
	local data = {
		name = self.name,
        tags = self.tags,
        data = self.data,
        icon = self.icon
	}

	return data
end

return favorite
