local utils = require("modules/utils/core/utils")
local style = require("modules/ui/style")
local componentKinds = require("modules/utils/data/componentKinds")

---Shared rows, sections and the "Other" section for the styled component panels in Entity Instance Data.
---A panel claims the fields it styles; every field it does not claim is drawn under "Other" by the
---generic property drawer, so no field of a component becomes uneditable.
---Installed onto the entity class via componentUI.install(entity).
local componentUI = {}

---Panels in registration order, the first whose bases the component derives from draws it.
---@type { bases: string[], draw: fun(entity: table, componentID: string|number, component: table, propertySearch: string?) }[]
local panels = {}

---@param source table?
---@param path table
---@return any
local function getNestedValue(source, path)
    if type(source) ~= "table" then
        return nil
    end

    return utils.getNestedValue(source, path)
end

---@param component table
---@param componentChanges table?
---@param path table
---@return any
local function getValue(component, componentChanges, path)
    local changedValue = getNestedValue(componentChanges, path)
    if changedValue ~= nil then
        return changedValue
    end

    return getNestedValue(component, path)
end

---@param component table
---@param componentChanges table?
---@param path table
---@return boolean
local function isPathModified(component, componentChanges, path)
    if type(componentChanges) ~= "table" or componentChanges[path[1]] == nil then
        return false
    end

    local currentValue = getValue(component, componentChanges, path)
    local defaultValue = getNestedValue(component, path)

    return not utils.deepcompare(currentValue, defaultValue, false)
end

---@param value boolean
---@return integer
local function fromBool(value)
    return value and 1 or 0
end

---@param path table
---@return string
local function getWidgetPath(path)
    local parts = {}

    for _, segment in ipairs(path) do
        table.insert(parts, tostring(segment))
    end

    return table.concat(parts, "_")
end

---@param componentID string|number
---@param path table
---@param suffix string?
---@return string
local function getWidgetID(componentID, path, suffix)
    return "##component" .. tostring(componentID) .. getWidgetPath(path) .. tostring(suffix or "")
end

---@param componentID string|number
---@param path table
---@return string
local function getPendingKey(componentID, path)
    return tostring(componentID) .. ":" .. getWidgetPath(path)
end

---@param component table
---@param componentChanges table?
---@param path table
---@param label string
---@param propertySearch string?
---@return boolean
local function shouldDrawPath(component, componentChanges, path, label, propertySearch)
    if type(propertySearch) ~= "string" or propertySearch == "" then
        return true
    end

    local key = path[#path]
    if utils.matchesInstanceDataSearch(key, propertySearch) or utils.matchesInstanceDataSearch(label, propertySearch) then
        return true
    end

    local value = getValue(component, componentChanges, path)
    local hasMatch = utils.matchesPropertySearchEntry(key, value, propertySearch, {})

    return hasMatch
end

---@param component table
---@param componentChanges table?
---@param fields table[]
---@param propertySearch string?
---@return boolean
local function shouldDrawAnyField(component, componentChanges, fields, propertySearch)
    if type(propertySearch) ~= "string" or propertySearch == "" then
        return true
    end

    for _, fieldInfo in ipairs(fields) do
        if shouldDrawPath(component, componentChanges, fieldInfo.path, fieldInfo.label or tostring(fieldInfo.path[#fieldInfo.path]), propertySearch) then
            return true
        end
    end

    return false
end

---@param title string
---@param modified boolean
---@return boolean
local function drawSectionHeader(title, modified)
    style.pushStyleColor(not modified, ImGuiCol.Text, style.mutedColor)
    local open = ImGui.TreeNodeEx(title)
    style.popStyleColor(not modified)

    return open
end

---@param label string
---@param modified boolean
local function drawLabel(label, modified)
    if modified then
        style.styledText(label, style.regularColor)
    else
        style.mutedText(label)
    end
end

---@param label string
---@param max number
---@param modified boolean
local function drawLabelRow(label, max, modified)
    drawLabel(label, modified)
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
end

---@param component table
---@param componentChanges table?
---@param claimedKeys table<string, boolean> Keys the panel draws itself
---@param propertySearch string?
---@return table
---@return number
local function getOtherKeys(component, componentChanges, claimedKeys, propertySearch)
    local seen = {}
    local keys = {}
    local max = 0

    local function collect(source)
        if type(source) ~= "table" then
            return
        end

        for key, _ in pairs(source) do
            if not seen[key] and not claimedKeys[key] and not utils.shouldSkipInstanceDataPropertyKey(key) then
                local value = getValue(component, componentChanges, { key })
                if type(propertySearch) ~= "string" or propertySearch == "" or utils.matchesPropertySearchEntry(key, value, propertySearch, {}) then
                    seen[key] = true
                    table.insert(keys, key)
                    max = math.max(max, ImGui.CalcTextSize(tostring(key)))
                end
            end
        end
    end

    collect(component)
    collect(componentChanges)

    table.sort(keys, function(a, b)
        return string.lower(tostring(a)) < string.lower(tostring(b))
    end)

    return keys, max
end

---Registers a panel for every component deriving from one of `bases`.
---Register a subclass's panel before its base's, the first match wins.
---@param bases string[]
---@param draw fun(entity: table, componentID: string|number, component: table, propertySearch: string?)
function componentUI.registerPanel(bases, draw)
    table.insert(panels, { bases = bases, draw = draw })
    componentKinds.clearCache(panels)
end

---@param component table
---@return fun(entity: table, componentID: string|number, component: table, propertySearch: string?)?
function componentUI.getPanel(component)
    if type(component) ~= "table" then
        return nil
    end

    local panel = componentKinds.findByBase(panels, tostring(component["$type"] or ""))
    return panel and panel.draw
end

---Draws a panel described as data: sections of rows, then "Other" for every key no row claims.
---A row is `{ path, label, kind, ... }`, `kind` one of "float", "int", "bool", "enum" (with `enum`),
---"property" (the generic drawer) or "custom" (with `draw(entity, componentID, component, componentChanges, max)`).
---A float row with `radiusPreview` gets the radius sphere toggle. A row whose field the component
---does not have is skipped; `visible(component, componentChanges)` hides a row outside a property search.
---@param spec { sections: { title: string?, rows: table[] }[] }
---@return fun(entity: table, componentID: string|number, component: table, propertySearch: string?)
function componentUI.dataPanel(spec)
    local claimedKeys = {}
    for _, section in ipairs(spec.sections) do
        for _, row in ipairs(section.rows) do
            claimedKeys[row.path[1]] = true
        end
    end

    return function(entity, componentID, component, propertySearch)
        local componentChanges = entity.instanceDataChanges[componentID]
        local searchActive = type(propertySearch) == "string" and propertySearch ~= ""

        for _, section in ipairs(spec.sections) do
            local rows = {}
            for _, row in ipairs(section.rows) do
                if getValue(component, componentChanges, { row.path[1] }) ~= nil
                    and (searchActive or not row.visible or row.visible(component, componentChanges)) then
                    table.insert(rows, row)
                end
            end

            if #rows > 0 then
                entity:drawComponentSection(componentID, component, componentChanges, section.title, rows, propertySearch)
            end
        end

        entity:drawComponentOtherSection(componentID, component, componentChanges, claimedKeys, propertySearch)
    end
end

---Installs the shared component drawing methods onto the entity spawnable class.
---@param entity table The entity spawnable class table
function componentUI.install(entity)
    ---@param componentID string|number
    ---@param path table
    ---@return any
    function entity:getComponentPendingValue(componentID, path)
        self.componentPendingValues = self.componentPendingValues or {}
        return self.componentPendingValues[getPendingKey(componentID, path)]
    end

    ---@param componentID string|number
    ---@param path table
    ---@param value any
    function entity:setComponentPendingValue(componentID, path, value)
        self.componentPendingValues = self.componentPendingValues or {}
        self.componentPendingValues[getPendingKey(componentID, path)] = utils.deepcopy(value)
    end

    ---@param componentID string|number
    ---@param path table
    function entity:clearComponentPendingValue(componentID, path)
        if not self.componentPendingValues then
            return
        end

        self.componentPendingValues[getPendingKey(componentID, path)] = nil
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param path table
    ---@return any
    function entity:getComponentDisplayValue(componentID, component, componentChanges, path)
        local pendingValue = self:getComponentPendingValue(componentID, path)
        if pendingValue ~= nil then
            return pendingValue
        end

        return getValue(component, componentChanges, path)
    end

    ---@param componentID string|number
    ---@param path table
    ---@param value any
    function entity:commitComponentValue(componentID, path, value)
        self:clearComponentPendingValue(componentID, path)
        self:updatePropValue(componentID, path, value)
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param fields table[]
    ---@return boolean
    function entity:isAnyComponentFieldModified(componentID, component, componentChanges, fields)
        for _, fieldInfo in ipairs(fields or {}) do
            local path = fieldInfo.path
            if path
                and (
                    self:getComponentPendingValue(componentID, path) ~= nil
                    or isPathModified(component, componentChanges, path)
                ) then
                return true
            end
        end

        return false
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param path table
    ---@param label string
    ---@param opts table?
    ---@param propertySearch string?
    ---@return boolean
    function entity:drawComponentFloatRow(componentID, component, componentChanges, path, label, opts, propertySearch)
        opts = opts or {}
        if not shouldDrawPath(component, componentChanges, path, label, propertySearch) then
            return false
        end

        local pendingValue = self:getComponentPendingValue(componentID, path)
        local modified = pendingValue ~= nil or isPathModified(component, componentChanges, path)
        local max = opts.max
        local value = tonumber(self:getComponentDisplayValue(componentID, component, componentChanges, path)) or opts.default or 0

        if opts.icon then
            style.drawIconLabelRow(opts.icon, label, { iconColor = opts.iconColor, fieldX = max })
            if not opts.newLine then
                ImGui.SameLine()
            end
        else
            drawLabelRow(label, max, modified)
        end

        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
        local newValue, changed, finished = style.trackedDragFloat(
            self.object,
            getWidgetID(componentID, path),
            value,
            opts.step or 0.01,
            opts.min or -99999,
            opts.maxValue or 99999,
            opts.format or "%.2f",
            opts.width or 90
        )
        self:drawResetProp(componentID, path, opts.typeName or "Float")
        style.popStyleColor(modified)

        if changed then
            self:setComponentPendingValue(componentID, path, newValue)
        end
        if finished then
            local finalValue = changed and newValue or self:getComponentPendingValue(componentID, path)
            if finalValue ~= nil then
                self:commitComponentValue(componentID, path, finalValue)
            end
        end

        if opts.tooltip then
            style.tooltip(opts.tooltip)
        end

        return true
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param path table
    ---@param label string
    ---@param opts table?
    ---@param propertySearch string?
    ---@return boolean
    function entity:drawComponentIntRow(componentID, component, componentChanges, path, label, opts, propertySearch)
        opts = opts or {}
        if not shouldDrawPath(component, componentChanges, path, label, propertySearch) then
            return false
        end

        local pendingValue = self:getComponentPendingValue(componentID, path)
        local modified = pendingValue ~= nil or isPathModified(component, componentChanges, path)
        drawLabelRow(label, opts.max, modified)

        local value = math.floor(tonumber(self:getComponentDisplayValue(componentID, component, componentChanges, path)) or opts.default or 0)
        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
        local newValue, changed, finished = style.trackedSliderInt(
            self.object,
            getWidgetID(componentID, path),
            value,
            opts.min or 0,
            opts.maxValue or 255,
            opts.width or 110
        )
        self:drawResetProp(componentID, path, opts.typeName or "Int32")
        style.popStyleColor(modified)

        if changed then
            self:setComponentPendingValue(componentID, path, newValue)
        end
        if finished then
            local finalValue = changed and newValue or self:getComponentPendingValue(componentID, path)
            if finalValue ~= nil then
                self:commitComponentValue(componentID, path, finalValue)
            end
        end

        if opts.tooltip then
            style.tooltip(opts.tooltip)
        end

        return true
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param path table
    ---@param label string
    ---@param opts table?
    ---@param propertySearch string?
    ---@return boolean
    function entity:drawComponentBoolRow(componentID, component, componentChanges, path, label, opts, propertySearch)
        opts = opts or {}
        if not shouldDrawPath(component, componentChanges, path, label, propertySearch) then
            return false
        end

        local modified = isPathModified(component, componentChanges, path)
        drawLabelRow(label, opts.max, modified)

        local currentValue = getValue(component, componentChanges, path)
        if currentValue == nil and opts.default ~= nil then
            currentValue = opts.default
        end

        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
        local newValue, changed = style.trackedCheckbox(
            self.object,
            getWidgetID(componentID, path),
            utils.toBoolean(currentValue),
            opts.disabled
        )
        self:drawResetProp(componentID, path, opts.typeName or "Bool")
        style.popStyleColor(modified)

        if changed then
            self:updatePropValue(componentID, path, fromBool(newValue))
        end

        if opts.tooltip then
            style.tooltip(opts.tooltip)
        end

        return true
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param path table
    ---@param label string
    ---@param enumName string
    ---@param opts table?
    ---@param propertySearch string?
    ---@return boolean
    function entity:drawComponentEnumRow(componentID, component, componentChanges, path, label, enumName, opts, propertySearch)
        opts = opts or {}
        if not shouldDrawPath(component, componentChanges, path, label, propertySearch) then
            return false
        end

        if not self.enumInfo[enumName] then
            self.enumInfo[enumName] = utils.enumTable(enumName)
        end

        local values = self.enumInfo[enumName] or {}
        if #values == 0 then
            return false
        end

        local modified = isPathModified(component, componentChanges, path)
        drawLabelRow(label, opts.max, modified)

        local currentValue = getValue(component, componentChanges, path)
        local selected = utils.indexValue(values, currentValue) - 1
        if selected < 0 then
            selected = 0
        end

        -- The combo draws its own tooltip, so helper text has to be appended to the type name
        -- instead of being drawn as a second tooltip window on top of it.
        local tooltipText = enumName
        if opts.tooltip then
            tooltipText = tooltipText .. "\n\n" .. opts.tooltip
        end

        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
        local newSelected, changed = style.trackedCombo(
            self.object,
            getWidgetID(componentID, path),
            selected,
            values,
            opts.width or 130,
            { tooltip = tooltipText }
        )
        self:drawResetProp(componentID, path, enumName)
        style.popStyleColor(modified)

        if changed then
            self:updatePropValue(componentID, path, values[newSelected + 1])
        end

        return true
    end

    ---Draws one property through the generic instance data drawer, which knows resources, structs,
    ---arrays and the audio name selectors.
    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param key string
    ---@param max number
    ---@param propertySearch string?
    function entity:drawComponentPropertyRow(componentID, component, componentChanges, key, max, propertySearch)
        local value = getValue(component, componentChanges, { key })

        style.pushStyleColor(true, ImGuiCol.Text, style.mutedColor)
        self:drawInstanceDataProperty(componentID, key, value, { key }, max, propertySearch, false)
        style.popStyleColor(true)
    end

    ---Draws a list of rows, as a collapsible section when `title` is set.
    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param title string?
    ---@param rows table[] Rows as described at componentUI.dataPanel
    ---@param propertySearch string?
    function entity:drawComponentSection(componentID, component, componentChanges, title, rows, propertySearch)
        if not shouldDrawAnyField(component, componentChanges, rows, propertySearch) then
            return
        end

        if title and not drawSectionHeader(title, self:isAnyComponentFieldModified(componentID, component, componentChanges, rows)) then
            return
        end

        local labels = {}
        for _, row in ipairs(rows) do
            table.insert(labels, row.kind == "property" and tostring(row.path[1]) or row.label)
        end
        local max = utils.getTextMaxWidth(labels) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

        for _, row in ipairs(rows) do
            local opts = utils.deepcopy(row.opts or {})
            opts.max = max

            if row.kind == "float" then
                if self:drawComponentFloatRow(componentID, component, componentChanges, row.path, row.label, opts, propertySearch) and row.radiusPreview then
                    self:drawComponentRadiusToggle(componentID, component)
                end
            elseif row.kind == "int" then
                self:drawComponentIntRow(componentID, component, componentChanges, row.path, row.label, opts, propertySearch)
            elseif row.kind == "bool" then
                self:drawComponentBoolRow(componentID, component, componentChanges, row.path, row.label, opts, propertySearch)
            elseif row.kind == "enum" then
                self:drawComponentEnumRow(componentID, component, componentChanges, row.path, row.label, row.enum, opts, propertySearch)
            elseif row.kind == "custom" then
                if shouldDrawPath(component, componentChanges, row.path, row.label, propertySearch) then
                    row.draw(self, componentID, component, componentChanges, max)
                end
            else
                self:drawComponentPropertyRow(componentID, component, componentChanges, row.path[1], max - ImGui.GetCursorPosX(), propertySearch)
            end
        end

        if title then
            ImGui.TreePop()
        end
    end

    ---Draws every key of the component the panel does not claim, through the generic drawer.
    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param claimedKeys table<string, boolean>
    ---@param propertySearch string?
    function entity:drawComponentOtherSection(componentID, component, componentChanges, claimedKeys, propertySearch)
        local keys, max = getOtherKeys(component, componentChanges, claimedKeys, propertySearch)
        if #keys == 0 then
            return
        end

        local allOtherKeys = getOtherKeys(component, componentChanges, claimedKeys, nil)
        local otherFields = {}
        for _, key in ipairs(allOtherKeys) do
            table.insert(otherFields, { path = { key } })
        end

        if drawSectionHeader("Other", self:isAnyComponentFieldModified(componentID, component, componentChanges, otherFields)) then
            for _, propKey in ipairs(keys) do
                self:drawComponentPropertyRow(componentID, component, componentChanges, propKey, max, propertySearch)
            end

            ImGui.TreePop()
        end
    end
end

componentUI.getValue = getValue
componentUI.isPathModified = isPathModified
componentUI.getWidgetPath = getWidgetPath
componentUI.getWidgetID = getWidgetID
componentUI.getPendingKey = getPendingKey
componentUI.shouldDrawPath = shouldDrawPath
componentUI.shouldDrawAnyField = shouldDrawAnyField
componentUI.drawSectionHeader = drawSectionHeader
componentUI.drawLabelRow = drawLabelRow

return componentUI
