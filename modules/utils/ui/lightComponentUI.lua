local utils = require("modules/utils/utils")
local style = require("modules/ui/style")
local history = require("modules/utils/history")
local colorUtil = require("modules/utils/color")
local iesProfiles = require("modules/utils/iesProfiles")

---UI for drawing gameLightComponent/entLightComponent instance data on the entity spawnable class.
---Installed onto the entity class via lightComponentUI.install(entity).
local lightComponentUI = {}

local lightChannelBitMaskByName = {
    LC_Channel1 = 1,
    LC_Channel2 = 2,
    LC_Channel3 = 4,
    LC_Channel4 = 8,
    LC_Channel5 = 16,
    LC_Channel6 = 32,
    LC_Channel7 = 64,
    LC_Channel8 = 128,
    LC_ChannelWorld = 256,
    LC_Character = 512,
    LC_Player = 1024,
    LC_Automated = 32768
}

local lightChannelNameToIndex = {}
for index, name in ipairs(style.lightChannelEnum or {}) do
    lightChannelNameToIndex[name] = index
end

local function isMaskBitSet(mask, bit)
    if type(mask) ~= "number" or bit <= 0 then
        return false
    end

    local normalized = math.floor(mask)
    return math.floor(normalized / bit) % 2 == 1
end

---@param value number|string|nil
---@return boolean[]
local function decodeLightChannelSelection(value)
    local selection = {}
    local names = style.lightChannelEnum or {}

    for i = 1, #names do
        selection[i] = false
    end

    if type(value) == "number" then
        for index, name in ipairs(names) do
            local bit = lightChannelBitMaskByName[name]
            if bit then
                selection[index] = isMaskBitSet(value, bit)
            end
        end
        return selection
    end

    if type(value) ~= "string" then
        return selection
    end

    local normalized = utils.trimString(value)
    if normalized == "" or normalized == "0" then
        return selection
    end

    local numeric = tonumber(normalized)
    if numeric then
        return decodeLightChannelSelection(numeric)
    end

    for token in normalized:gmatch("[^,]+") do
        local key = utils.trimString(token)
        local index = lightChannelNameToIndex[key]
        if index then
            selection[index] = true
        end
    end

    return selection
end

---@param selection boolean[]
---@return string
local function encodeLightChannelSelection(selection)
    return utils.buildBitfieldString(selection, style.lightChannelEnum or {})
end

local LIGHT_COMPONENT_TYPE_POINT = "LT_Point"
local LIGHT_COMPONENT_TYPE_SPOT = "LT_Spot"
local LIGHT_COMPONENT_TYPE_AREA = "LT_Area"

local LIGHT_COMPONENT_TYPE_OPTIONS = style.lightTypeOptions

---Keys drawn explicitly by the sections below, used to detect leftover/unknown keys for the "Other" section.
local lightComponentNewUIKeys = {
    type = true,
    color = true,
    intensity = true,
    radius = true,
    capsuleLength = true,
    spotCapsule = true,
    innerAngle = true,
    outerAngle = true,
    softness = true,
    contactShadows = true,
    enableLocalShadows = true,
    enableLocalShadowsForceStaticsOnly = true,
    shadowAngle = true,
    shadowFadeDistance = true,
    shadowFadeRange = true,
    flicker = true,
    lightChannel = true,
    iesProfile = true,
    useInParticles = true,
    useInTransparents = true,
    scaleVolFog = true,
    sceneDiffuse = true,
    sceneSpecularScale = true,
    roughnessBias = true,
    sourceRadius = true,
    autoHideDistance = true,
    EV = true,
    attenuation = true,
    clampAttenuation = true,
    directional = true,
    rayTracedShadowsPlatform = true,
    rayTracingLightSourceRadius = true,
    rayTracingContactShadowRange = true,
    rayTracingIntensityScale = true,
    pathTracingLightUsage = true,
    pathTracingOverrideScaleGI = true,
    rtxdiShadowStartingDistance = true
}

---@param component table
---@return boolean
local function isLightComponentData(component)
    if type(component) ~= "table" then
        return false
    end

    local componentType = tostring(component["$type"] or "")
    return componentType == "gameLightComponent" or componentType == "entLightComponent"
end

---@param source table?
---@param path table
---@return any
local function getNestedLightComponentValue(source, path)
    if type(source) ~= "table" then
        return nil
    end

    return utils.getNestedValue(source, path)
end

---@param component table
---@param componentChanges table?
---@param path table
---@return any
local function getLightComponentValue(component, componentChanges, path)
    local changedValue = getNestedLightComponentValue(componentChanges, path)
    if changedValue ~= nil then
        return changedValue
    end

    return getNestedLightComponentValue(component, path)
end

---@param component table
---@param componentChanges table?
---@param path table
---@return boolean
local function isLightComponentPathModified(component, componentChanges, path)
    if type(componentChanges) ~= "table" or componentChanges[path[1]] == nil then
        return false
    end

    local currentValue = getLightComponentValue(component, componentChanges, path)
    local defaultValue = getNestedLightComponentValue(component, path)

    return not utils.deepcompare(currentValue, defaultValue, false)
end

---@param value any
---@return boolean
local function toLightComponentBool(value)
    return value == true or value == 1
end

---@param value boolean
---@return integer
local function fromLightComponentBool(value)
    return value and 1 or 0
end

---@param path table
---@return string
local function getLightComponentWidgetPath(path)
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
local function getLightComponentWidgetID(componentID, path, suffix)
    return "##lightComponent" .. tostring(componentID) .. getLightComponentWidgetPath(path) .. tostring(suffix or "")
end

---@param componentID string|number
---@param path table
---@return string
local function getLightComponentPendingKey(componentID, path)
    return tostring(componentID) .. ":" .. getLightComponentWidgetPath(path)
end

---@param value any
---@return string
local function normalizeLightComponentType(value)
    if type(value) == "number" then
        local option = LIGHT_COMPONENT_TYPE_OPTIONS[value + 1]
        return option and option.value or LIGHT_COMPONENT_TYPE_SPOT
    end

    if type(value) == "string" and value ~= "" then
        return value
    end

    return LIGHT_COMPONENT_TYPE_SPOT
end

---@param component table
---@param componentChanges table?
---@param path table
---@param label string
---@param propertySearch string?
---@return boolean
local function shouldDrawLightComponentPath(component, componentChanges, path, label, propertySearch)
    if type(propertySearch) ~= "string" or propertySearch == "" then
        return true
    end

    local key = path[#path]
    if utils.matchesInstanceDataSearch(key, propertySearch) or utils.matchesInstanceDataSearch(label, propertySearch) then
        return true
    end

    local value = getLightComponentValue(component, componentChanges, path)
    local hasMatch = utils.matchesPropertySearchEntry(key, value, propertySearch, {})

    return hasMatch
end

---@param component table
---@param componentChanges table?
---@param fields table[]
---@param propertySearch string?
---@return boolean
local function shouldDrawAnyLightComponentField(component, componentChanges, fields, propertySearch)
    if type(propertySearch) ~= "string" or propertySearch == "" then
        return true
    end

    for _, fieldInfo in ipairs(fields) do
        if shouldDrawLightComponentPath(component, componentChanges, fieldInfo.path, fieldInfo.label or tostring(fieldInfo.path[#fieldInfo.path]), propertySearch) then
            return true
        end
    end

    return false
end

---@param title string
---@param modified boolean
---@return boolean
local function drawLightComponentSectionHeader(title, modified)
    style.pushStyleColor(not modified, ImGuiCol.Text, style.mutedColor)
    local open = ImGui.TreeNodeEx(title)
    style.popStyleColor(not modified)

    return open
end

---@param label string
---@param modified boolean
local function drawLightComponentLabel(label, modified)
    if modified then
        style.styledText(label, style.regularColor)
    else
        style.mutedText(label)
    end
end

---@param label string
---@param max number
---@param modified boolean
local function drawLightComponentLabelRow(label, max, modified)
    drawLightComponentLabel(label, modified)
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
end

---@param source table?
---@return number[]
local function colorDataToUnit(source)
    source = type(source) == "table" and source or {}
    local function channelToUnit(value, fallback)
        local number = tonumber(value)
        if number == nil then
            number = fallback
        end

        return math.max(0, math.min(255, number)) / 255
    end

    return {
        channelToUnit(source.Red, 255),
        channelToUnit(source.Green, 255),
        channelToUnit(source.Blue, 255),
        channelToUnit(source.Alpha, 255)
    }
end

---@param source table?
---@param color number[]
---@return table
local function unitToColorData(source, color)
    local updated = utils.deepcopy(type(source) == "table" and source or {})
    updated["$type"] = updated["$type"] or "Color"
    updated.Red = math.floor(math.max(0, math.min(1, tonumber(color[1]) or 0)) * 255 + 0.5)
    updated.Green = math.floor(math.max(0, math.min(1, tonumber(color[2]) or 0)) * 255 + 0.5)
    updated.Blue = math.floor(math.max(0, math.min(1, tonumber(color[3]) or 0)) * 255 + 0.5)

    if updated.Alpha ~= nil or color[4] ~= nil then
        local alpha = tonumber(color[4])
        if alpha == nil then
            alpha = (tonumber(updated.Alpha) or 255) / 255
        end

        updated.Alpha = math.floor(math.max(0, math.min(1, alpha)) * 255 + 0.5)
    end

    return updated
end

---@param component table
---@param componentChanges table?
---@param propertySearch string?
---@return table
---@return number
local function getLightComponentOtherKeys(component, componentChanges, propertySearch)
    local seen = {}
    local keys = {}
    local max = 0

    local function collect(source)
        if type(source) ~= "table" then
            return
        end

        for key, _ in pairs(source) do
            if not seen[key] and not lightComponentNewUIKeys[key] and not utils.shouldSkipInstanceDataPropertyKey(key) then
                local value = getLightComponentValue(component, componentChanges, { key })
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

---Installs the light component drawing methods onto the entity spawnable class.
---@param entity table The entity spawnable class table
function lightComponentUI.install(entity)
    ---@param componentID string|number
    ---@param path table
    ---@return any
    function entity:getLightComponentPendingValue(componentID, path)
        self.lightComponentPendingValues = self.lightComponentPendingValues or {}
        return self.lightComponentPendingValues[getLightComponentPendingKey(componentID, path)]
    end

    ---@param componentID string|number
    ---@param path table
    ---@param value any
    function entity:setLightComponentPendingValue(componentID, path, value)
        self.lightComponentPendingValues = self.lightComponentPendingValues or {}
        self.lightComponentPendingValues[getLightComponentPendingKey(componentID, path)] = utils.deepcopy(value)
    end

    ---@param componentID string|number
    ---@param path table
    function entity:clearLightComponentPendingValue(componentID, path)
        if not self.lightComponentPendingValues then
            return
        end

        self.lightComponentPendingValues[getLightComponentPendingKey(componentID, path)] = nil
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param path table
    ---@return any
    function entity:getLightComponentDisplayValue(componentID, component, componentChanges, path)
        local pendingValue = self:getLightComponentPendingValue(componentID, path)
        if pendingValue ~= nil then
            return pendingValue
        end

        return getLightComponentValue(component, componentChanges, path)
    end

    ---@param componentID string|number
    ---@param path table
    ---@param value any
    function entity:commitLightComponentValue(componentID, path, value)
        self:clearLightComponentPendingValue(componentID, path)
        self:updatePropValue(componentID, path, value)
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param fields table[]
    ---@return boolean
    function entity:isAnyLightComponentFieldModified(componentID, component, componentChanges, fields)
        for _, fieldInfo in ipairs(fields or {}) do
            local path = fieldInfo.path
            if path
                and (
                    self:getLightComponentPendingValue(componentID, path) ~= nil
                    or isLightComponentPathModified(component, componentChanges, path)
                ) then
                return true
            end
        end

        return false
    end

    ---@param componentID string|number
    ---@param path table
    ---@param typeName string?
    function entity:drawLightComponentReset(componentID, path, typeName)
        self:drawResetProp(componentID, utils.deepcopy(path), typeName)
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param path table
    ---@param label string
    ---@param opts table?
    ---@param propertySearch string?
    ---@return boolean
    function entity:drawLightComponentFloatRow(componentID, component, componentChanges, path, label, opts, propertySearch)
        opts = opts or {}
        if not shouldDrawLightComponentPath(component, componentChanges, path, label, propertySearch) then
            return false
        end

        local pendingValue = self:getLightComponentPendingValue(componentID, path)
        local modified = pendingValue ~= nil or isLightComponentPathModified(component, componentChanges, path)
        local max = opts.max
        local value = tonumber(self:getLightComponentDisplayValue(componentID, component, componentChanges, path)) or opts.default or 0

        if opts.icon then
            style.drawIconLabelRow(opts.icon, label, { iconColor = opts.iconColor, fieldX = max })
            if not opts.newLine then
                ImGui.SameLine()
            end
        else
            drawLightComponentLabelRow(label, max, modified)
        end

        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
        local newValue, changed, finished = style.trackedDragFloat(
            self.object,
            getLightComponentWidgetID(componentID, path),
            value,
            opts.step or 0.01,
            opts.min or -99999,
            opts.maxValue or 99999,
            opts.format or "%.2f",
            opts.width or 90
        )
        self:drawLightComponentReset(componentID, path, opts.typeName or "Float")
        style.popStyleColor(modified)

        if changed then
            self:setLightComponentPendingValue(componentID, path, newValue)
        end
        if finished then
            local finalValue = changed and newValue or self:getLightComponentPendingValue(componentID, path)
            if finalValue ~= nil then
                self:commitLightComponentValue(componentID, path, finalValue)
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
    function entity:drawLightComponentIntRow(componentID, component, componentChanges, path, label, opts, propertySearch)
        opts = opts or {}
        if not shouldDrawLightComponentPath(component, componentChanges, path, label, propertySearch) then
            return false
        end

        local pendingValue = self:getLightComponentPendingValue(componentID, path)
        local modified = pendingValue ~= nil or isLightComponentPathModified(component, componentChanges, path)
        drawLightComponentLabelRow(label, opts.max, modified)

        local value = math.floor(tonumber(self:getLightComponentDisplayValue(componentID, component, componentChanges, path)) or opts.default or 0)
        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
        local newValue, changed, finished = style.trackedSliderInt(
            self.object,
            getLightComponentWidgetID(componentID, path),
            value,
            opts.min or 0,
            opts.maxValue or 255,
            opts.width or 110
        )
        self:drawLightComponentReset(componentID, path, opts.typeName or "Int32")
        style.popStyleColor(modified)

        if changed then
            self:setLightComponentPendingValue(componentID, path, newValue)
        end
        if finished then
            local finalValue = changed and newValue or self:getLightComponentPendingValue(componentID, path)
            if finalValue ~= nil then
                self:commitLightComponentValue(componentID, path, finalValue)
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
    function entity:drawLightComponentBoolRow(componentID, component, componentChanges, path, label, opts, propertySearch)
        opts = opts or {}
        if not shouldDrawLightComponentPath(component, componentChanges, path, label, propertySearch) then
            return false
        end

        local modified = isLightComponentPathModified(component, componentChanges, path)
        drawLightComponentLabelRow(label, opts.max, modified)

        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
        local newValue, changed = style.trackedCheckbox(
            self.object,
            getLightComponentWidgetID(componentID, path),
            toLightComponentBool(getLightComponentValue(component, componentChanges, path)),
            opts.disabled
        )
        self:drawLightComponentReset(componentID, path, opts.typeName or "Bool")
        style.popStyleColor(modified)

        if changed then
            self:updatePropValue(componentID, path, fromLightComponentBool(newValue))
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
    function entity:drawLightComponentEnumRow(componentID, component, componentChanges, path, label, enumName, opts, propertySearch)
        opts = opts or {}
        if not shouldDrawLightComponentPath(component, componentChanges, path, label, propertySearch) then
            return false
        end

        if not self.enumInfo[enumName] then
            self.enumInfo[enumName] = utils.enumTable(enumName)
        end

        local values = self.enumInfo[enumName] or {}
        if #values == 0 then
            return false
        end

        local modified = isLightComponentPathModified(component, componentChanges, path)
        drawLightComponentLabelRow(label, opts.max, modified)

        local currentValue = getLightComponentValue(component, componentChanges, path)
        local selected = utils.indexValue(values, currentValue) - 1
        if selected < 0 then
            selected = 0
        end

        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
        local newSelected, changed = style.trackedCombo(
            self.object,
            getLightComponentWidgetID(componentID, path),
            selected,
            values,
            opts.width or 130,
            { tooltip = enumName }
        )
        self:drawLightComponentReset(componentID, path, enumName)
        style.popStyleColor(modified)

        if changed then
            self:updatePropValue(componentID, path, values[newSelected + 1])
        end

        return true
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    ---@return string
    function entity:drawLightComponentTypeTabs(componentID, component, componentChanges, propertySearch)
        local path = { "type" }
        local lightType = normalizeLightComponentType(getLightComponentValue(component, componentChanges, path))

        if not shouldDrawLightComponentPath(component, componentChanges, path, "Type", propertySearch) then
            return lightType
        end

        local tabWidth = 95 * style.viewSize

        for index, typeInfo in ipairs(LIGHT_COMPONENT_TYPE_OPTIONS) do
            if index > 1 then
                ImGui.SameLine()
            end

            local typeLabel, hiddenTypeText = style.resolveActionLabel(
                typeInfo.icon,
                typeInfo.label,
                "lightComponentType" .. tostring(componentID) .. typeInfo.value,
                nil,
                true
            )
            local clicked = style.switchTabButton(
                typeLabel,
                lightType == typeInfo.value,
                tabWidth,
                0
            )
            style.tooltipActionLabel(hiddenTypeText, "Light type")

            if clicked and lightType ~= typeInfo.value then
                history.addAction(history.getElementChange(self.object))
                self:updatePropValue(componentID, path, typeInfo.value)
                lightType = typeInfo.value
            end
        end

        self:drawLightComponentReset(componentID, path, "ELightType")
        ImGui.Spacing()

        return lightType
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    ---@return boolean
    function entity:drawLightComponentColor(componentID, component, componentChanges, propertySearch)
        local path = { "color" }
        if not shouldDrawLightComponentPath(component, componentChanges, path, "Color", propertySearch) then
            return false
        end

        self.lightComponentColorHexText = self.lightComponentColorHexText or {}
        self.lightComponentColorHexEditing = self.lightComponentColorHexEditing or {}

        local stateKey = tostring(componentID) .. ":" .. getLightComponentWidgetPath(path)
        local colorData = getLightComponentValue(component, componentChanges, path)
        local pendingColor = self:getLightComponentPendingValue(componentID, path)
        local color = pendingColor or colorDataToUnit(colorData)
        local currentHex = colorUtil.formatHexRGB(color)

        local popupId = "##lightComponentColorPicker" .. stateKey
        local modified = pendingColor ~= nil or isLightComponentPathModified(component, componentChanges, path)

        local changed, finished
        self.lightComponentColorHexText[stateKey], self.lightComponentColorHexEditing[stateKey], changed, finished = style.drawLightColorSwatch(
            self.object,
            popupId,
            getLightComponentWidgetID(componentID, path, "Hex"),
            color,
            self.lightComponentColorHexText[stateKey],
            self.lightComponentColorHexEditing[stateKey],
            {
                modified = modified,
                afterHexInput = function()
                    self:drawLightComponentReset(componentID, path, "Color")
                end
            }
        )

        if changed then
            self.lightComponentColorHexText[stateKey] = (self.lightComponentColorHexText[stateKey] or ""):upper()
            local parsedColor = colorUtil.parseHexRGB(self.lightComponentColorHexText[stateKey])
            if parsedColor then
                parsedColor[4] = color[4]
                self:setLightComponentPendingValue(componentID, path, parsedColor)
            end
        end
        if finished then
            local parsedColor = colorUtil.parseHexRGB(self.lightComponentColorHexText[stateKey])
            if parsedColor then
                parsedColor[4] = color[4]
                self:commitLightComponentValue(componentID, path, unitToColorData(colorData, parsedColor))
                self.lightComponentColorHexText[stateKey] = colorUtil.formatHexRGB(parsedColor)
            else
                self:clearLightComponentPendingValue(componentID, path)
                self.lightComponentColorHexText[stateKey] = currentHex
            end
        end

        if ImGui.BeginPopup(popupId) then
            local newColor, colorChanged, colorFinished = style.trackedColorPicker(self.object, getLightComponentWidgetID(componentID, path, "Picker"), color)
            if colorChanged then
                newColor[4] = color[4]
                self:setLightComponentPendingValue(componentID, path, newColor)
                self.lightComponentColorHexText[stateKey] = colorUtil.formatHexRGB(newColor)
            end
            if colorFinished then
                local finalColor = colorChanged and newColor or self:getLightComponentPendingValue(componentID, path)
                if finalColor ~= nil then
                    finalColor[4] = finalColor[4] or color[4]
                    self:commitLightComponentValue(componentID, path, unitToColorData(colorData, finalColor))
                    self.lightComponentColorHexText[stateKey] = colorUtil.formatHexRGB(finalColor)
                end
            end
            ImGui.EndPopup()
        end

        return true
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    function entity:drawLightComponentPrimary(componentID, component, componentChanges, propertySearch)
        local baseMax = utils.getTextMaxWidth({
            string.format("%s %s", IconGlyphs.Pill, "Capsule Length"),
            string.format("%s %s", IconGlyphs.CircleHalfFull, "Spot Capsule"),
            string.format("%s %s", IconGlyphs.Cone, "Inner Angle"),
            string.format("%s %s", IconGlyphs.Cone, "Outer Angle"),
            string.format("%s %s", IconGlyphs.FormatLineWeight, "Softness")
        }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        local lightType = self:drawLightComponentTypeTabs(componentID, component, componentChanges, propertySearch)
        local drewColor = self:drawLightComponentColor(componentID, component, componentChanges, propertySearch)

        local primaryFields = {
            { path = { "intensity" }, label = "Intensity" },
            { path = { "radius" }, label = "Radius" }
        }
        local drawPrimaryFields = shouldDrawAnyLightComponentField(component, componentChanges, primaryFields, propertySearch)

        if drewColor and drawPrimaryFields then
            ImGui.SameLine()
            ImGui.Dummy(2 * style.viewSize, 0)
            ImGui.SameLine()
        end

        if drawPrimaryFields then
            ImGui.BeginGroup()
            ImGui.Dummy(0, 8 * style.viewSize)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "intensity" }, "Intensity", {
                icon = IconGlyphs.WeatherSunny,
                newLine = true,
                step = 1,
                min = 0,
                maxValue = 999999,
                format = "%.1f",
                width = 80
            }, propertySearch)
            ImGui.Dummy(0, 4 * style.viewSize)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "radius" }, "Radius", {
                icon = IconGlyphs.RadiusOutline,
                iconColor = style.lightRadiusIconColor,
                newLine = true,
                step = 0.25,
                min = 0,
                maxValue = 9999,
                format = "%.1fm",
                width = 60,
                tooltip = "How far the light source emits light."
            }, propertySearch)
            ImGui.EndGroup()
        end

        ImGui.Dummy(0, 8 * style.viewSize)

        if lightType == LIGHT_COMPONENT_TYPE_AREA then
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "capsuleLength" }, "Capsule Length", {
                icon = IconGlyphs.Pill,
                max = baseMax,
                step = 0.05,
                min = 0,
                maxValue = 9999,
                format = "%.2fm",
                width = 60
            }, propertySearch)
            self:drawLightComponentBoolRow(componentID, component, componentChanges, { "spotCapsule" }, "Spot Capsule", {
                max = baseMax
            }, propertySearch)
        end

        local spotCapsule = toLightComponentBool(getLightComponentValue(component, componentChanges, { "spotCapsule" }))
        if lightType == LIGHT_COMPONENT_TYPE_SPOT or (lightType == LIGHT_COMPONENT_TYPE_AREA and spotCapsule) then
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "innerAngle" }, "Inner Angle", {
                icon = IconGlyphs.Cone,
                iconColor = style.lightInnerAngleColor,
                max = baseMax,
                step = 0.1,
                min = 0,
                maxValue = 360,
                format = "%.1f°",
                width = 60,
                tooltip = "Inner angle of the light."
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "outerAngle" }, "Outer Angle", {
                icon = IconGlyphs.Cone,
                iconColor = style.lightOuterAngleColor,
                max = baseMax,
                step = 0.1,
                min = 0,
                maxValue = 360,
                format = "%.1f°",
                width = 60,
                tooltip = "Outer angle of the light."
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "softness" }, "Softness", {
                icon = IconGlyphs.FormatLineWeight,
                max = baseMax,
                step = 0.05,
                min = 0,
                maxValue = 9999,
                format = "%.2f",
                width = 60,
                tooltip = "Softens the transition between both angles."
            }, propertySearch)
        end
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    function entity:drawLightComponentIESProfile(componentID, component, componentChanges, propertySearch)
        local path = { "iesProfile" }
        if not shouldDrawLightComponentPath(component, componentChanges, path, "IES Profile", propertySearch) then
            return
        end

        self.lightComponentIESSearch = self.lightComponentIESSearch or {}
        local stateKey = getLightComponentPendingKey(componentID, path)
        self.lightComponentIESSearch[stateKey] = self.lightComponentIESSearch[stateKey] or ""

        local defaultValue = getNestedLightComponentValue(component, path)
        local defaultPath = iesProfiles.extractPath(defaultValue)
        local currentValue = getLightComponentValue(component, componentChanges, path)
        local currentPath = iesProfiles.extractPath(currentValue)
        local modified = isLightComponentPathModified(component, componentChanges, path)

        ---Applies a new IES profile path, reverting to the component default when they match
        ---so no spurious change is stored.
        ---@param newPath string
        local function commitProfile(newPath)
            if newPath == defaultPath then
                self:updatePropValue(componentID, path, utils.deepcopy(defaultValue))
            else
                self:updatePropValue(componentID, path, iesProfiles.buildRef(defaultValue, newPath))
            end
        end

        local max = utils.getTextMaxWidth({ "IES Profile" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
        drawLightComponentLabelRow("IES Profile", max, modified)

        local list = iesProfiles.getSelectable()
        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
        local newPath, newSearch, changed = style.trackedSearchDropdown(
            getLightComponentWidgetID(componentID, path),
            "Search IES profile...",
            currentPath,
            self.lightComponentIESSearch[stateKey],
            list,
            {
                element = self.object,
                width = 200,
                matchContentWidth = true,
                optionDisplayFn = function(optionText)
                    return iesProfiles.displayName(optionText)
                end,
                tooltip = "IES light projection profile (raRef:CIESDataResource)"
            }
        )
        self.lightComponentIESSearch[stateKey] = newSearch
        self:drawLightComponentReset(componentID, path, "raRef:CIESDataResource")
        style.popStyleColor(modified)

        if changed and newPath ~= currentPath then
            commitProfile(newPath)
        end

        ImGui.SameLine()
        ImGui.BeginDisabled(#iesProfiles.get() == 0)
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.SkipNext .. getLightComponentWidgetID(componentID, path, "Cycle")) then
            local nextProfile, cycled = iesProfiles.getNext(currentPath)
            if cycled then
                history.addAction(history.getElementChange(self.object))
                commitProfile(nextProfile)
            end
        end
        style.pushButtonNoBG(false)
        ImGui.EndDisabled()
        style.tooltip("Select the next IES profile. Wraps around, including 'None'.")

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Reload .. getLightComponentWidgetID(componentID, path, "Reload")) then
            iesProfiles.reload()
        end
        style.pushButtonNoBG(false)
        style.tooltip("Reload the IES profile list from disk.")
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    function entity:drawLightComponentShadowSection(componentID, component, componentChanges, propertySearch)
        local fields = {
            { path = { "contactShadows" }, label = "Contact Shadows" },
            { path = { "enableLocalShadows" }, label = "Local Shadows" },
            { path = { "enableLocalShadowsForceStaticsOnly" }, label = "Local Shadows (Statics Only)" },
            { path = { "shadowAngle" }, label = "Shadow Angle" },
            { path = { "shadowFadeDistance" }, label = "Shadow Fade Distance" },
            { path = { "shadowFadeRange" }, label = "Shadow Fade Range" }
        }
        if not shouldDrawAnyLightComponentField(component, componentChanges, fields, propertySearch) then
            return
        end

        if drawLightComponentSectionHeader("Shadow Settings", self:isAnyLightComponentFieldModified(componentID, component, componentChanges, fields)) then
            local max = utils.getTextMaxWidth({
                "Contact Shadows",
                "Local Shadows",
                "Local Shadows (Statics Only)",
                "Shadow Angle",
                "Shadow Fade Distance",
                "Shadow Fade Range"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

            self:drawLightComponentEnumRow(componentID, component, componentChanges, { "contactShadows" }, "Contact Shadows", "rendContactShadowReciever", {
                max = max,
                width = 130
            }, propertySearch)
            self:drawLightComponentBoolRow(componentID, component, componentChanges, { "enableLocalShadows" }, "Local Shadows", {
                max = max
            }, propertySearch)
            self:drawLightComponentBoolRow(componentID, component, componentChanges, { "enableLocalShadowsForceStaticsOnly" }, "Local Shadows (Statics Only)", {
                max = max,
                disabled = not toLightComponentBool(getLightComponentValue(component, componentChanges, { "enableLocalShadows" }))
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "shadowAngle" }, "Shadow Angle", {
                max = max,
                step = 0.01,
                min = -1,
                maxValue = 9999,
                format = "%.2f",
                width = 75
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "shadowFadeDistance" }, "Shadow Fade Distance", {
                max = max,
                step = 0.01,
                min = 0,
                maxValue = 9999,
                format = "%.1f",
                width = 75
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "shadowFadeRange" }, "Shadow Fade Range", {
                max = max,
                step = 0.01,
                min = 0,
                maxValue = 9999,
                format = "%.1f",
                width = 75
            }, propertySearch)

            ImGui.TreePop()
        end
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    function entity:drawLightComponentFlickerSection(componentID, component, componentChanges, propertySearch)
        local fields = {
            { path = { "flicker", "flickerPeriod" }, label = "Flicker Period" },
            { path = { "flicker", "flickerStrength" }, label = "Flicker Strength" },
            { path = { "flicker", "positionOffset" }, label = "Flicker Offset" }
        }
        if not shouldDrawAnyLightComponentField(component, componentChanges, fields, propertySearch) then
            return
        end

        if drawLightComponentSectionHeader("Flicker Settings", self:isAnyLightComponentFieldModified(componentID, component, componentChanges, fields)) then
            local max = utils.getTextMaxWidth({
                "Flicker Period",
                "Flicker Strength",
                "Flicker Offset"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "flicker", "flickerPeriod" }, "Flicker Period", {
                max = max,
                step = 0.01,
                min = 0.05,
                maxValue = 9999,
                format = "%.2f",
                width = 85
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "flicker", "flickerStrength" }, "Flicker Strength", {
                max = max,
                step = 0.01,
                min = 0,
                maxValue = 9999,
                format = "%.2f",
                width = 85
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "flicker", "positionOffset" }, "Flicker Offset", {
                max = max,
                step = 0.01,
                min = 0,
                maxValue = 9999,
                format = "%.2f",
                width = 85
            }, propertySearch)

            ImGui.TreePop()
        end
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    function entity:drawLightComponentChannelsSection(componentID, component, componentChanges, propertySearch)
        local path = { "lightChannel" }
        if not shouldDrawLightComponentPath(component, componentChanges, path, "Light Channels", propertySearch) then
            return
        end

        if drawLightComponentSectionHeader("Light Channels", self:isAnyLightComponentFieldModified(componentID, component, componentChanges, {
            { path = path }
        })) then
            local selection = decodeLightChannelSelection(getLightComponentValue(component, componentChanges, path))
            local previous = encodeLightChannelSelection(selection)
            selection = style.drawLightChannelsSelector(self.object, selection)
            local current = encodeLightChannelSelection(selection)
            self:drawLightComponentReset(componentID, path, "rendLightChannel")

            if current ~= previous then
                self:updatePropValue(componentID, path, current)
            end

            ImGui.TreePop()
        end
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    function entity:drawLightComponentMiscSection(componentID, component, componentChanges, propertySearch)
        local fields = {
            { path = { "useInParticles" }, label = "Use in particles" },
            { path = { "useInTransparents" }, label = "Use in transparents" },
            { path = { "scaleVolFog" }, label = "Scale Vol. Fog" },
            { path = { "sceneDiffuse" }, label = "Scene Diffuse" },
            { path = { "sceneSpecularScale" }, label = "Specular Scale" },
            { path = { "roughnessBias" }, label = "Roughness Bias" },
            { path = { "sourceRadius" }, label = "Source Radius" },
            { path = { "autoHideDistance" }, label = "Auto Hide Distance" },
            { path = { "EV" }, label = "EV" },
            { path = { "attenuation" }, label = "Attenuation Mode" },
            { path = { "clampAttenuation" }, label = "Clamp Attenuation" },
            { path = { "directional" }, label = "Directional" }
        }
        if not shouldDrawAnyLightComponentField(component, componentChanges, fields, propertySearch) then
            return
        end

        if drawLightComponentSectionHeader("Misc. Settings", self:isAnyLightComponentFieldModified(componentID, component, componentChanges, fields)) then
            local max = utils.getTextMaxWidth({
                "Directional",
                "Use in particles",
                "Use in transparents",
                "Scale Vol. Fog",
                "Auto Hide Distance",
                "EV",
                "Attenuation Mode",
                "Clamp Attenuation",
                "Specular Scale",
                "Scene Diffuse",
                "Roughness Bias",
                "Source Radius"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

            self:drawLightComponentBoolRow(componentID, component, componentChanges, { "useInParticles" }, "Use in particles", {
                max = max
            }, propertySearch)
            self:drawLightComponentBoolRow(componentID, component, componentChanges, { "useInTransparents" }, "Use in transparents", {
                max = max
            }, propertySearch)
            self:drawLightComponentIntRow(componentID, component, componentChanges, { "scaleVolFog" }, "Scale Vol. Fog", {
                max = max,
                min = 0,
                maxValue = 255,
                width = 110,
                typeName = "Uint8"
            }, propertySearch)
            self:drawLightComponentBoolRow(componentID, component, componentChanges, { "sceneDiffuse" }, "Scene Diffuse", {
                max = max
            }, propertySearch)
            self:drawLightComponentIntRow(componentID, component, componentChanges, { "sceneSpecularScale" }, "Specular Scale", {
                max = max,
                min = 0,
                maxValue = 255,
                width = 110,
                typeName = "Uint8"
            }, propertySearch)
            self:drawLightComponentIntRow(componentID, component, componentChanges, { "roughnessBias" }, "Roughness Bias", {
                max = max,
                min = -127,
                maxValue = 127,
                width = 110,
                typeName = "Int8"
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "sourceRadius" }, "Source Radius", {
                max = max,
                step = 0.0025,
                min = 0,
                maxValue = 9999,
                format = "%.3f",
                width = 110
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "autoHideDistance" }, "Auto Hide Distance", {
                max = max,
                step = 0.05,
                min = 0,
                maxValue = 9999,
                format = "%.1f",
                width = 110
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "EV" }, "EV", {
                max = max,
                step = 0.1,
                min = 0,
                maxValue = 9999,
                format = "%.1f",
                width = 110
            }, propertySearch)
            self:drawLightComponentEnumRow(componentID, component, componentChanges, { "attenuation" }, "Attenuation Mode", "rendLightAttenuation", {
                max = max,
                width = 130
            }, propertySearch)
            self:drawLightComponentBoolRow(componentID, component, componentChanges, { "clampAttenuation" }, "Clamp Attenuation", {
                max = max
            }, propertySearch)
            self:drawLightComponentBoolRow(componentID, component, componentChanges, { "directional" }, "Directional", {
                max = max
            }, propertySearch)

            ImGui.TreePop()
        end
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    function entity:drawLightComponentRayPathTracingSection(componentID, component, componentChanges, propertySearch)
        local fields = {
            { path = { "rayTracedShadowsPlatform" }, label = "Ray Traced Shadows Platform" },
            { path = { "rayTracingLightSourceRadius" }, label = "RT Light Source Radius" },
            { path = { "rayTracingContactShadowRange" }, label = "RT Contact Shadow Range" },
            { path = { "rayTracingIntensityScale" }, label = "RT Intensity Scale" },
            { path = { "pathTracingLightUsage" }, label = "Path Tracing Light Usage" },
            { path = { "pathTracingOverrideScaleGI" }, label = "PT Override Scale GI" },
            { path = { "rtxdiShadowStartingDistance" }, label = "RTXDI Shadow Start Distance" }
        }
        if not shouldDrawAnyLightComponentField(component, componentChanges, fields, propertySearch) then
            return
        end

        if drawLightComponentSectionHeader("Ray/Path Tracing Settings", self:isAnyLightComponentFieldModified(componentID, component, componentChanges, fields)) then
            local max = utils.getTextMaxWidth({
                "Ray Traced Shadows Platform",
                "RT Light Source Radius",
                "RT Contact Shadow Range",
                "RT Intensity Scale",
                "Path Tracing Light Usage",
                "PT Override Scale GI",
                "RTXDI Shadow Start Distance"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

            self:drawLightComponentEnumRow(componentID, component, componentChanges, { "rayTracedShadowsPlatform" }, "Ray Traced Shadows Platform", "rendRayTracedShadowsPlatform", {
                max = max,
                width = 175
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "rayTracingLightSourceRadius" }, "RT Light Source Radius", {
                max = max,
                step = 0.005,
                min = 0,
                maxValue = 9999,
                format = "%.3f",
                width = 120
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "rayTracingContactShadowRange" }, "RT Contact Shadow Range", {
                max = max,
                step = 0.05,
                min = 0,
                maxValue = 9999,
                format = "%.2f",
                width = 120
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "rayTracingIntensityScale" }, "RT Intensity Scale", {
                max = max,
                step = 0.01,
                min = 0,
                maxValue = 9999,
                format = "%.2f",
                width = 120
            }, propertySearch)
            self:drawLightComponentEnumRow(componentID, component, componentChanges, { "pathTracingLightUsage" }, "Path Tracing Light Usage", "rendEPathTracingLightUsage", {
                max = max,
                width = 175
            }, propertySearch)
            self:drawLightComponentBoolRow(componentID, component, componentChanges, { "pathTracingOverrideScaleGI" }, "PT Override Scale GI", {
                max = max
            }, propertySearch)
            self:drawLightComponentFloatRow(componentID, component, componentChanges, { "rtxdiShadowStartingDistance" }, "RTXDI Shadow Start Distance", {
                max = max,
                step = 0.05,
                min = 0,
                maxValue = 9999,
                format = "%.2f",
                width = 120
            }, propertySearch)

            ImGui.TreePop()
        end
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    function entity:drawLightComponentOtherSection(componentID, component, componentChanges, propertySearch)
        local keys, max = getLightComponentOtherKeys(component, componentChanges, propertySearch)
        if #keys == 0 then
            return
        end

        local allOtherKeys = getLightComponentOtherKeys(component, componentChanges, nil)
        local otherFields = {}
        for _, key in ipairs(allOtherKeys) do
            table.insert(otherFields, { path = { key } })
        end

        if drawLightComponentSectionHeader("Other", self:isAnyLightComponentFieldModified(componentID, component, componentChanges, otherFields)) then
            for _, propKey in ipairs(keys) do
                local entry = getLightComponentValue(component, componentChanges, { propKey })

                style.pushStyleColor(true, ImGuiCol.Text, style.mutedColor)
                self:drawInstanceDataProperty(componentID, propKey, entry, { propKey }, max, propertySearch, false)
                style.popStyleColor(true)
            end

            ImGui.TreePop()
        end
    end

    ---@param componentID string|number
    ---@param component table
    ---@param propertySearch string?
    function entity:drawLightComponentInstanceData(componentID, component, propertySearch)
        local componentChanges = self.instanceDataChanges[componentID]

        self:drawLightComponentPrimary(componentID, component, componentChanges, propertySearch)
        ImGui.Dummy(0, 4 * style.viewSize)
        self:drawLightComponentIESProfile(componentID, component, componentChanges, propertySearch)
        self:drawLightComponentShadowSection(componentID, component, componentChanges, propertySearch)
        self:drawLightComponentFlickerSection(componentID, component, componentChanges, propertySearch)
        self:drawLightComponentChannelsSection(componentID, component, componentChanges, propertySearch)
        self:drawLightComponentMiscSection(componentID, component, componentChanges, propertySearch)
        self:drawLightComponentRayPathTracingSection(componentID, component, componentChanges, propertySearch)
        self:drawLightComponentOtherSection(componentID, component, componentChanges, propertySearch)
    end
end

lightComponentUI.isLightComponentData = isLightComponentData
lightComponentUI.decodeLightChannelSelection = decodeLightChannelSelection
lightComponentUI.encodeLightChannelSelection = encodeLightChannelSelection

return lightComponentUI
