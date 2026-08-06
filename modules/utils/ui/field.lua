local history = require("modules/utils/project/history")
local settings = require("modules/utils/core/settings")
local input = require("modules/utils/core/input")
local utils = require("modules/utils/core/utils")
local style = require("modules/ui/style")

local field = {}
local dragBeingEdited = false
local advancedFloatEditStates = {}
local iconPickerInitialized = false
local iconKeys = {}
local iconSearchMeta = {}
local iconPickerStates = {}
local infinitySentinel = 3.4028235e+38
local infinityThreshold = 99999

---Combine ImGui flags without adding a flag twice.
---@param flags number
---@param flag number
---@return number combinedFlags
local function addImGuiFlag(flags, flag)
    if bit32 and bit32.bor then
        return bit32.bor(flags, flag)
    end

    if bit and bit.bor then
        return bit.bor(flags, flag)
    end

    if math.floor(flags / flag) % 2 == 0 then
        return flags + flag
    end

    return flags
end

---Wrap a numeric value into the half-open interval `[min, max)`.
---@param value number Value to wrap.
---@param min number Lower bound of wrapping range.
---@param max number Upper bound of wrapping range.
---@return number wrappedValue Wrapped value, or original value when range is invalid.
local function wrapValue(value, min, max)
    local range = max - min
    if range <= 0 then
        return value
    end

    local wrapped = (value - min) % range
    if wrapped < 0 then
        wrapped = wrapped + range
    end

    return min + wrapped
end

---Check whether a number should be treated as positive infinity sentinel.
---@param value number? Value to check.
---@return boolean isInfinity
local function isPositiveInfinitySentinel(value)
    return type(value) == "number" and value >= infinitySentinel * 0.999
end

---Check whether a number should be treated as negative infinity sentinel.
---@param value number? Value to check.
---@return boolean isInfinity
local function isNegativeInfinitySentinel(value)
    return type(value) == "number" and value <= -infinitySentinel * 0.999
end

---Build the display format used when showing an infinity sentinel in the UI.
---@param prefix string Text shown before the numeric value.
---@param suffix string Text shown after the numeric value.
---@param sign string Either `"+"` or `"-"`.
---@return string displayFormat
local function getInfinityDisplayFormat(prefix, suffix, sign)
    local icon = (IconGlyphs and IconGlyphs.Infinity) or "inf"
    return prefix .. sign .. icon .. suffix
end

---Reset cached icon-grid layout data.
---@param cache table Layout cache table to mutate.
local function resetIconGridLayoutCache(cache)
    cache.search = nil
    cache.showNames = nil
    cache.widthKey = nil
    cache.viewSizeKey = nil
    cache.filteredKeys = {}
    cache.rowHeights = {}
    cache.rowOffsets = {}
    cache.totalRowsHeight = 0
    cache.rowCount = 0
    cache.nColumns = 1
    cache.itemWidth = 0
end

---Get or create state for an icon-picker instance.
---@param id string? Optional picker identifier.
---@return table state Picker state table.
---@return string pickerId Normalized picker ID used internally.
local function getIconPickerState(id)
    local pickerId = tostring(id or "default")

    if not iconPickerStates[pickerId] then
        iconPickerStates[pickerId] = {
            showNames = false,
            layoutCache = {}
        }
        resetIconGridLayoutCache(iconPickerStates[pickerId].layoutCache)
    end

    return iconPickerStates[pickerId], pickerId
end

---Normalize text for case-insensitive token search.
---@param value string? Raw text.
---@return string normalized
local function normalizeSearchText(value)
    local normalized = tostring(value or ""):lower()
    normalized = normalized:gsub("[%-%._/]+", " ")
    normalized = normalized:gsub("%s+", " ")

    return utils.trimString(normalized)
end

---Split comma-separated metadata text into trimmed non-empty values.
---@param rawValue string? Comma-separated text.
---@return string[] values
local function splitMetadataValues(rawValue)
    local values = {}

    for value in tostring(rawValue or ""):gmatch("([^,]+)") do
        value = utils.trimString(value)
        if value ~= "" then
            table.insert(values, value)
        end
    end

    return values
end

---Convert identifier-like text into title-cased words.
---@param value string? Source text.
---@return string titleCased
local function toTitleCaseWords(value)
    local normalized = utils.trimString(tostring(value or ""))
    normalized = normalized:gsub("([a-z0-9])([A-Z])", "%1 %2")
    normalized = normalized:gsub("([A-Z]+)([A-Z][a-z])", "%1 %2")
    normalized = normalized:gsub("[%-%._/]+", " ")
    normalized = normalized:gsub("%s+", " "):lower()

    return (normalized:gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest
    end))
end

---Build searchable metadata for every icon key from `modules/utils/vendor/IconGlyphs.lua`.
local function buildIconSearchMeta()
    iconSearchMeta = {}

    for _, key in ipairs(iconKeys) do
        iconSearchMeta[key] = {
            name = "",
            aliases = {},
            tags = {},
            searchText = normalizeSearchText(key),
            displayName = key,
            tooltipText = nil,
            labelLayouts = {}
        }
    end

    local file = io.open("modules/utils/vendor/IconGlyphs.lua", "r")
    if not file then
        return
    end

    for line in file:lines() do
        local key = line:match("^%-%-%-@field%s+([A-Za-z0-9_]+)%s")
        local metadata = key and iconSearchMeta[key]

        if metadata then
            local canonicalName = utils.trimString(line:match("U%+[%x]+%s+([^,]+)"))
            local aliases = splitMetadataValues((line:match("aliases:%s*(.-)(, tags:|$)")))
            local tags = splitMetadataValues(line:match("tags:%s*(.+)$"))
            local searchParts = { key }

            metadata.name = canonicalName
            metadata.aliases = aliases
            metadata.tags = tags

            if canonicalName ~= "" then
                table.insert(searchParts, canonicalName)
            end

            for _, alias in ipairs(aliases) do
                table.insert(searchParts, alias)
            end

            for _, tag in ipairs(tags) do
                table.insert(searchParts, tag)
            end

            metadata.searchText = normalizeSearchText(table.concat(searchParts, " "))
            metadata.displayName = toTitleCaseWords(canonicalName ~= "" and canonicalName or key)
            metadata.tooltipText = table.concat((function()
                local lines = {}

                if canonicalName ~= "" then
                    table.insert(lines, "Name: " .. canonicalName)
                end
                if #aliases > 0 then
                    table.insert(lines, "Aliases: " .. table.concat(aliases, ", "))
                end
                if #tags > 0 then
                    table.insert(lines, "Tags: " .. table.concat(tags, ", "))
                end

                return lines
            end)(), "\n")
            if metadata.tooltipText == "" then
                metadata.tooltipText = nil
            end
            metadata.labelLayouts = {}
        end
    end

    file:close()
end

---Initialize icon-picker caches once per runtime.
local function ensureIconPickerInitialized()
    if iconPickerInitialized then
        return
    end

    iconKeys = utils.getKeys(IconGlyphs)
    table.sort(iconKeys)
    buildIconSearchMeta()
    iconPickerInitialized = true
end

---Check whether an icon key matches all search terms.
---@param key string Icon key name from `IconGlyphs`.
---@param search string? User-entered search string.
---@return boolean matches
local function matchesIconSearch(key, search)
    local normalizedSearch = normalizeSearchText(search)
    if normalizedSearch == "" then
        return true
    end

    local metadata = iconSearchMeta[key]
    if not metadata then
        return normalizeSearchText(key):find(normalizedSearch, 1, true) ~= nil
    end

    for term in normalizedSearch:gmatch("%S+") do
        if not metadata.searchText:find(term, 1, true) then
            return false
        end
    end

    return true
end

---Get tooltip text for an icon key, if metadata exists.
---@param key string Icon key.
---@return string? tooltip
local function getIconSearchTooltip(key)
    local metadata = iconSearchMeta[key]
    return metadata and metadata.tooltipText or nil
end

---Get a human-friendly display label for an icon key.
---@param key string Icon key.
---@return string displayName
local function getIconDisplayName(key)
    local metadata = iconSearchMeta[key]
    return metadata and metadata.displayName or toTitleCaseWords(key)
end

---Build or fetch wrapped label layout for an icon tile.
---@param key string Icon key.
---@param maxWidth number Maximum text width per line.
---@param fontScale number? Font scale used for measurement.
---@return table layout Table with `lines`, `widths`, and `lineCount`.
local function getIconLabelLayout(key, maxWidth, fontScale)
    local metadata = iconSearchMeta[key]
    local scale = fontScale or 1
    local widthKey = math.floor((maxWidth or 0) + 0.5)
    local scaleKey = math.floor(scale * 100 + 0.5)
    local cacheKey = tostring(widthKey) .. ":" .. tostring(scaleKey)
    local displayName = metadata and metadata.displayName or getIconDisplayName(key)

    if metadata and metadata.labelLayouts[cacheKey] then
        local cachedLayout = metadata.labelLayouts[cacheKey]
        if cachedLayout.lines and cachedLayout.widths and #cachedLayout.lines == #cachedLayout.widths then
            return cachedLayout
        end
    end

    local lines = {}
    local widths = {}
    local currentLine = ""

    ImGui.SetWindowFontScale(scale)

    for word in tostring(displayName or ""):gmatch("%S+") do
        local nextLine = currentLine == "" and word or (currentLine .. " " .. word)
        if currentLine ~= "" and ImGui.CalcTextSize(nextLine) > maxWidth then
            table.insert(lines, currentLine)
            currentLine = word
        else
            currentLine = nextLine
        end
    end

    if currentLine == "" then
        currentLine = tostring(displayName or "")
    end
    if currentLine ~= "" then
        table.insert(lines, currentLine)
    end

    for _, line in ipairs(lines) do
        table.insert(widths, ImGui.CalcTextSize(line))
    end

    ImGui.SetWindowFontScale(1)

    local layout = {
        lines = lines,
        widths = widths,
        lineCount = #lines
    }

    if metadata then
        metadata.labelLayouts[cacheKey] = layout
    end

    return layout
end

---Draw precomputed multi-line centered text.
---@param layout table Layout table returned by `getIconLabelLayout`.
---@param centerX number X center position in window space.
---@param fontScale number? Font scale to use while drawing.
local function drawCenteredWrappedText(layout, centerX, fontScale)
    ImGui.SetWindowFontScale(fontScale or 1)

    for index, line in ipairs(layout.lines) do
        local lineWidth = layout.widths and layout.widths[index] or nil
        if lineWidth == nil then
            lineWidth = ImGui.CalcTextSize(line)
        end

        ImGui.SetCursorPosX(centerX - (lineWidth / 2))
        ImGui.Text(line)
    end

    ImGui.SetWindowFontScale(1)
end

---Recompute icon-grid virtualization/cache for the current picker state.
---@param cache table Mutable layout cache table.
---@param search string Current search string.
---@param showNames boolean Whether labels are shown under glyphs.
---@param availableWidth number Available child width.
---@param labelFontScale number Font scale used for labels.
---@param buttonHeight number Height of each icon button.
local function rebuildIconGridLayout(cache, search, showNames, availableWidth, labelFontScale, buttonHeight)
    local filteredKeys = {}

    for _, key in ipairs(iconKeys) do
        if matchesIconSearch(key, search) then
            table.insert(filteredKeys, key)
        end
    end

    local minCellWidth = (showNames and 58 or 40) * style.viewSize
    local maxItemWidth = showNames and minCellWidth or buttonHeight
    local safeWidth = math.max(availableWidth, minCellWidth)
    local nColumns = showNames and math.max(1, math.floor(safeWidth / minCellWidth)) or 10
    local itemWidth = math.min(maxItemWidth, safeWidth / nColumns)
    local rowCount = math.ceil(#filteredKeys / nColumns)
    local rowHeights = {}
    local rowOffsets = {}
    local totalRowsHeight = 0

    if showNames then
        local lineHeight = ImGui.GetFontSize() * labelFontScale

        for row = 1, rowCount do
            rowOffsets[row] = totalRowsHeight

            local maxLines = 1
            for col = 1, nColumns do
                local key = filteredKeys[(row - 1) * nColumns + col]
                if key then
                    local layout = getIconLabelLayout(key, itemWidth, labelFontScale)
                    maxLines = math.max(maxLines, layout.lineCount)
                end
            end

            local rowHeight = buttonHeight + (maxLines * lineHeight) + 4 * style.viewSize
            rowHeights[row] = rowHeight
            totalRowsHeight = totalRowsHeight + rowHeight
        end
    else
        local rowHeight = buttonHeight + 4 * style.viewSize

        for row = 1, rowCount do
            rowOffsets[row] = totalRowsHeight
            rowHeights[row] = rowHeight
            totalRowsHeight = totalRowsHeight + rowHeight
        end
    end

    cache.filteredKeys = filteredKeys
    cache.rowHeights = rowHeights
    cache.rowOffsets = rowOffsets
    cache.totalRowsHeight = totalRowsHeight
    cache.rowCount = rowCount
    cache.nColumns = nColumns
    cache.itemWidth = itemWidth
end

---Get icon-grid layout, rebuilding cache when relevant inputs changed.
---@param cache table Mutable layout cache table.
---@param search string Current search string.
---@param showNames boolean Whether labels are shown under glyphs.
---@param availableWidth number Available child width.
---@param labelFontScale number Font scale used for labels.
---@param buttonHeight number Height of each icon button.
---@return table cache Updated cache table.
local function getIconGridLayout(cache, search, showNames, availableWidth, labelFontScale, buttonHeight)
    local widthKey = math.floor(math.max(availableWidth, 1) + 0.5)
    local viewSizeKey = math.floor((style.viewSize or 1) * 100 + 0.5)
    local searchValue = tostring(search or "")

    if cache.search ~= searchValue or
       cache.showNames ~= showNames or
       cache.widthKey ~= widthKey or
       cache.viewSizeKey ~= viewSizeKey then
        rebuildIconGridLayout(cache, searchValue, showNames, availableWidth, labelFontScale, buttonHeight)
        cache.search = searchValue
        cache.showNames = showNames
        cache.widthKey = widthKey
        cache.viewSizeKey = viewSizeKey
    end

    return cache
end

---Draw a searchable icon selector combo.
---@param id string? Stable picker instance ID used to keep per-popup state.
---@param current string Current icon key.
---@param search string? Current search text for the picker.
---@return string current Updated icon key.
---@return string search Updated search text.
---@return boolean changed True when a different icon was selected.
function field.drawIconSelector(id, current, search)
    ensureIconPickerInitialized()

    local pickerState, pickerId = getIconPickerState(id)
    local changed = false
    local search = search or ""
    local previewValue = IconGlyphs[current] or ""
    local _, screenHeight = GetDisplayResolution()
    local popupSearchHeight = ImGui.GetFrameHeightWithSpacing()
    local popupPaddingY = (ImGui.GetStyle().WindowPadding.y * 2) + ImGui.GetStyle().ItemSpacing.y
    local maxPopupHeight = screenHeight * 0.8
    local availableGridHeight = math.max(1, maxPopupHeight - popupSearchHeight - popupPaddingY)
    local gridHeight = math.min(400 * style.viewSize, availableGridHeight)
    local popupHeight = gridHeight + popupSearchHeight + popupPaddingY
    local comboId = "##icon" .. pickerId

    style.setNextItemWidth(42)
    ImGui.SetNextWindowSizeConstraints(1, popupHeight, 10000, popupHeight)
    if ImGui.BeginCombo(comboId, previewValue) then
        input.updateContext("main")

        local interiorWidth = 250 - (2 * ImGui.GetStyle().FramePadding.x) - 30
        style.setNextItemWidth(interiorWidth)
        search, _ = ImGui.InputTextWithHint("##iconSearch" .. pickerId, "Icon, alias or tag...", search, 100)
        local searchWidth, _ = ImGui.GetItemRectSize()
        local clearButtonWidth = 0
        local controlsWidth = searchWidth

        if search ~= "" then
            ImGui.SameLine()
            style.pushButtonNoBG(true)
            if ImGui.Button(IconGlyphs.Close .. "##iconClear" .. pickerId) then
                search = ""
            end
            clearButtonWidth, _ = ImGui.GetItemRectSize()
            controlsWidth = controlsWidth + ImGui.GetStyle().ItemSpacing.x + clearButtonWidth
            style.pushButtonNoBG(false)
        end

        ImGui.SameLine()
        pickerState.showNames, _ = ImGui.Checkbox("Show names##showIconNames" .. pickerId, pickerState.showNames)
        local showNamesWidth, _ = ImGui.GetItemRectSize()
        controlsWidth = controlsWidth + ImGui.GetStyle().ItemSpacing.x + showNamesWidth

        local gridWidth = math.max(controlsWidth, 340 * style.viewSize)
        if ImGui.BeginChild("##iconGrid" .. pickerId, gridWidth, gridHeight, true) then
            local buttonHeight = 26 * style.viewSize
            local labelFontScale = 0.75
            local showNames = pickerState.showNames
            local gridLayout = getIconGridLayout(pickerState.layoutCache, search, showNames, ImGui.GetContentRegionAvail(), labelFontScale, buttonHeight)
            local filteredKeys = gridLayout.filteredKeys
            local nColumns = gridLayout.nColumns
            local itemWidth = gridLayout.itemWidth
            local rowCount = gridLayout.rowCount
            local rowHeights = gridLayout.rowHeights
            local rowOffsets = gridLayout.rowOffsets
            local totalRowsHeight = gridLayout.totalRowsHeight

            if #filteredKeys == 0 then
                style.mutedText("No icons.")
            else
                local scrollY = ImGui.GetScrollY()
                local viewportBottom = scrollY + gridHeight
                local startRow = 1
                while startRow <= rowCount and rowOffsets[startRow] + rowHeights[startRow] < scrollY do
                    startRow = startRow + 1
                end

                local endRow = startRow
                while endRow <= rowCount and rowOffsets[endRow] < viewportBottom do
                    endRow = endRow + 1
                end

                startRow = math.max(1, startRow - 1)
                endRow = math.min(rowCount, math.max(startRow, endRow))

                local topSpacer = rowCount > 0 and rowOffsets[startRow] or 0
                local renderedHeight = 0
                for row = startRow, endRow do
                    renderedHeight = renderedHeight + rowHeights[row]
                end
                local bottomSpacer = math.max(0, totalRowsHeight - topSpacer - renderedHeight)

                if topSpacer > 0 then
                    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + topSpacer)
                end

                ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, 2 * style.viewSize, 2 * style.viewSize)
                ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 2 * style.viewSize, 1 * style.viewSize)
                if ImGui.BeginTable("##iconGridTable" .. pickerId, nColumns, ImGuiTableFlags.SizingStretchSame) then
                    for row = startRow, endRow do
                        ImGui.TableNextRow(ImGuiTableRowFlags.None, rowHeights[row])

                        for col = 1, nColumns do
                            local index = (row - 1) * nColumns + col
                            local key = filteredKeys[index]

                            ImGui.TableSetColumnIndex(col - 1)
                            if key then
                                ImGui.PushID(key)

                                local selected = current == key
                                local columnWidth = ImGui.GetContentRegionAvail()
                                local columnStartX = ImGui.GetCursorPosX()
                                local itemStartX = columnStartX + math.max(0, (columnWidth - itemWidth) / 2)
                                local tooltip = getIconSearchTooltip(key)
                                local labelLayout = showNames and getIconLabelLayout(key, itemWidth, labelFontScale) or nil

                                if selected then
                                    ImGui.PushStyleColor(ImGuiCol.Button, 0.0, 1.0, 0.7, 0.8)
                                    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.0, 1.0, 0.7, 1.0)
                                    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.0, 1.0, 0.7, 0.6)
                                    ImGui.PushStyleColor(ImGuiCol.Text, style.activeTextColor)
                                else
                                    ImGui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
                                    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.15)
                                    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 1, 1, 1, 0.2)
                                end

                                ImGui.SetCursorPosX(itemStartX)
                                if ImGui.Button(IconGlyphs[key] .. "##iconButton", itemWidth, buttonHeight) then
                                    current = key
                                    changed = true
                                    ImGui.CloseCurrentPopup()
                                end
                                if tooltip then
                                    style.tooltip(tooltip)
                                end
                                ImGui.PopStyleColor(selected and 4 or 3)

                                if showNames then
                                    ImGui.SetCursorPosX(itemStartX)
                                    style.pushStyleColor(true, ImGuiCol.Text, style.mutedColor)
                                    drawCenteredWrappedText(labelLayout, columnStartX + (columnWidth / 2), labelFontScale)
                                    style.popStyleColor(true)
                                    if tooltip then
                                        style.tooltip(tooltip)
                                    end
                                end

                                ImGui.PopID()
                            end
                        end
                    end

                    ImGui.EndTable()
                end
                ImGui.PopStyleVar(2)

                if bottomSpacer > 0 then
                    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + bottomSpacer)
                end
            end

            ImGui.EndChild()
        end

        ImGui.EndCombo()
    end

    return current, search, changed
end

---Advanced tracked DragFloat with optional labels, precision modifiers, and looping.
---`Shift` enables fine control (`shiftFormat`), `Ctrl` enables coarse control.
---History is pushed once per drag interaction when `element` is provided.
---@param element table? Element used for undo history tracking.
---@param text string Widget label / ID.
---@param value number Current value.
---@param options table? Optional behavior overrides:
---`step` (`number`, default `0.01`), `min` (`number`, default `-99999`),
---`max` (`number`, default `99999`), `format` (`string`, default `"%.2f"`),
---`shiftFormat` (`string`, default `"%.3f"`), `width` (`number`, default `74`),
---`prefix` (`string`, default `""`), `suffix` (`string`, default `""`),
---`manualEditFormat` (`string`, optional) to use while typing a value manually,
---`flags` (`number`, default `0`) forwarded to `ImGui.DragFloat`,
---`loop` (`boolean`, default `false`) to wrap values between min/max,
---`shiftStep` (`number`, optional, effective final step while Shift is held) and
---`ctrlStep` (`number`, optional) to override modifier drag steps.
---@return number newValue Updated value (may include infinity sentinel or wrapped value).
---@return boolean changed True while value changed this frame.
---@return boolean finished True when item was deactivated after edit.
function field.advancedTrackedFloat(element, text, value, options)
    options = options or {}

    local step = options.step or 0.01
    local shiftStep = options.shiftStep
    local ctrlStep = options.ctrlStep
    local min = options.min or -99999
    local max = options.max or 99999
    local format = options.format or "%.2f"
    local shiftFormat = options.shiftFormat or "%.3f"
    local width = options.width or 74
    local prefix = options.prefix or ""
    local suffix = options.suffix or ""
    local manualEditFormat = options.manualEditFormat
    local flags = options.flags or 0
    local loop = options.loop == true

    local dragStep = step
    local shiftDown = ImGui.IsKeyDown(ImGuiKey.LeftShift) or ImGui.IsKeyDown(ImGuiKey.RightShift)
    local ctrlDown = ImGui.IsKeyDown(ImGuiKey.LeftCtrl) or ImGui.IsKeyDown(ImGuiKey.RightCtrl)

    if shiftDown then
        -- ImGui drag applies an internal x10 multiplier while Shift is held, compensating here with `* 0.1`.
        dragStep = 0.1 * (tonumber(shiftStep) or (dragStep * settings.precisionMultiplier))
    elseif ctrlDown then
        dragStep = tonumber(ctrlStep) or (dragStep * settings.coarsePrecisionMultiplier)
    end

    local wasPositiveInfinity = not loop and isPositiveInfinitySentinel(value)
    local wasNegativeInfinity = not loop and isNegativeInfinitySentinel(value)
    local dragValue = value
    if wasPositiveInfinity then
        dragValue = infinityThreshold
    elseif wasNegativeInfinity then
        dragValue = -infinityThreshold
    end

    ImGui.SetNextItemWidth(width * (style.viewSize or 1))
    local activeFormat = shiftDown and shiftFormat or format

    local cursorX, cursorY = ImGui.GetCursorScreenPos()
    local mouseX, mouseY = ImGui.GetMousePos()
    local itemWidth = ImGui.CalcItemWidth()
    local itemHeight = ImGui.GetFrameHeight()
    local mouseOverItem = mouseX >= cursorX and mouseX <= cursorX + itemWidth
        and mouseY >= cursorY and mouseY <= cursorY + itemHeight
    local leftClicked = ImGui.IsMouseClicked(ImGuiMouseButton.Left)
    local leftDoubleClicked = ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left)

    -- Dear ImGui normally turns Ctrl+click on a DragFloat into text input.
    -- Disable input for that activation frame so Ctrl can instead modify drag speed.
    if mouseOverItem and ctrlDown and leftClicked and not leftDoubleClicked then
        flags = addImGuiFlag(flags, ImGuiSliderFlags.NoInput)
    end

    local editState
    if manualEditFormat ~= nil then
        local id = ImGui.GetID(text)
        editState = advancedFloatEditStates[id] or { manual = false, focused = false }
        advancedFloatEditStates[id] = editState

        local mouseRequestedInput = mouseOverItem and leftDoubleClicked
        local keyboardRequestedInput = editState.focused and ImGui.IsKeyPressed(ImGuiKey.Enter)

        if mouseRequestedInput or keyboardRequestedInput then
            editState.manual = true
        end
        if editState.manual then
            activeFormat = manualEditFormat
        end
    end

    local displayFormat = prefix .. activeFormat .. suffix
    if wasPositiveInfinity then
        displayFormat = getInfinityDisplayFormat(prefix, suffix, "+")
    elseif wasNegativeInfinity then
        displayFormat = getInfinityDisplayFormat(prefix, suffix, "-")
    end

    -- For looping fields, avoid DragFloat clamp so value can cross bounds both ways.
    local dragMin = min
    local dragMax = max
    if loop then
        dragMin = -999999999
        dragMax = 999999999
    end

    local newValue, changed = ImGui.DragFloat(text, dragValue, dragStep, dragMin, dragMax, displayFormat, flags)

    if editState ~= nil then
        local active = ImGui.IsItemActive()
        editState.focused = ImGui.IsItemFocused()
        if editState.manual and not active then
            editState.manual = false
        end
    end

    local finished = ImGui.IsItemDeactivatedAfterEdit()
    -- Push first, close out after: a value committed with Enter reports `changed` and `finished` on
    -- the same frame, so clearing first would leave the flag stuck set, silencing history and change
    -- tracking for every later edit. Same reasoning as `style.trackWidgetEdit`.
    if changed and element and not dragBeingEdited then
        history.addAction(history.getElementChange(element))
        dragBeingEdited = true
    end
    if finished then
        dragBeingEdited = false
    end

    if not loop then
        if wasPositiveInfinity then
            if changed and newValue < infinityThreshold then
                newValue = infinityThreshold
            else
                newValue = infinitySentinel
            end
        elseif wasNegativeInfinity then
            if changed and newValue > -infinityThreshold then
                newValue = -infinityThreshold
            else
                newValue = -infinitySentinel
            end
        elseif changed and newValue > infinityThreshold then
            newValue = infinitySentinel
        elseif changed and newValue < -infinityThreshold then
            newValue = -infinitySentinel
        end
    end

    if loop and min ~= nil and max ~= nil then
        newValue = wrapValue(newValue, min, max)
    else
        local isInfinity = isPositiveInfinitySentinel(newValue) or isNegativeInfinitySentinel(newValue)
        if not isInfinity then
            if min ~= nil then
                newValue = math.max(newValue, min)
            end
            if max ~= nil then
                newValue = math.min(newValue, max)
            end
        end
    end

    return newValue, changed, finished
end

return field
