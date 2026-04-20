local utils = require("modules/utils/utils")
local settings = require("modules/utils/settings")
local style = require("modules/ui/style")
local editor = require("modules/utils/editor/editor")

---@class favorite
---@field name string
---@field tags table
---@field data positionable
---@field category category?
---@field icon string
---@field favoritesUI favoritesUI
---@field spawnUI spawnUI
local favorite = {}
local iconResolveCache = {}

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
    if modulePath == "modules/classes/editor/spawnableElement" then
        cacheKey = cacheKey .. "|" .. tostring(data.spawnable and data.spawnable.modulePath or "")
    end

    if iconResolveCache[cacheKey] ~= nil then
        return iconResolveCache[cacheKey]
    end

    if modulePath == "modules/classes/editor/spawnableElement" then
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

    if modulePath == "modules/classes/editor/positionableGroup" then
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

function favorite:drawSideButtons()
	ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 2 * (ImGui.GetFontSize() / 15))

    -- Right side buttons
    local settingsX, _ = ImGui.CalcTextSize(IconGlyphs.CogOutline)
	local totalX = settingsX + ImGui.GetStyle().ItemSpacing.x
    local scrollBarAddition = ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0
    local cursorX = ImGui.GetWindowWidth() - totalX - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()
    ImGui.SetCursorPosX(cursorX)

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

        ImGui.EndPopup()
    end

    -- Asset preview
    if self.data.modulePath == "modules/classes/editor/spawnableElement" and ImGui.IsItemHovered() and settings.assetPreviewEnabled[self.data.spawnable.modulePath] then
        self.spawnUI.handleAssetPreviewHovered(self, true)
    elseif self.spawnUI.hoveredEntry == self and (self.spawnUI.previewInstance or self.spawnUI.previewTimer) then
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
	ImGui.Text(self.name)

	ImGui.SameLine()
	self:drawSideButtons()

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
