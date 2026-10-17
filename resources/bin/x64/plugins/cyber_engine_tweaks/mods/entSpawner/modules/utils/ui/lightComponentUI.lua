local utils = require("modules/utils/core/utils")
local style = require("modules/ui/style")
local history = require("modules/utils/project/history")
local colorUtil = require("modules/utils/ui/color")
local iesProfiles = require("modules/utils/data/iesProfiles")
local componentUI = require("modules/utils/ui/componentUI")

local getComponentValue = componentUI.getValue
local isComponentPathModified = componentUI.isPathModified
local toComponentBool = componentUI.toBool
local getComponentWidgetPath = componentUI.getWidgetPath
local getComponentWidgetID = componentUI.getWidgetID
local getComponentPendingKey = componentUI.getPendingKey
local shouldDrawComponentPath = componentUI.shouldDrawPath
local shouldDrawAnyComponentField = componentUI.shouldDrawAnyField
local drawComponentSectionHeader = componentUI.drawSectionHeader
local drawComponentLabelRow = componentUI.drawLabelRow

---UI for drawing light component instance data on the entity spawnable class, for every class deriving from entLightComponent.
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
    shadowRadius = true,
    shadowSoftnessMode = true,
    shadowFadeDistance = true,
    shadowFadeRange = true,
    flicker = true,
    lightChannel = true,
    iesProfile = true,
    areaShape = true,
    areaTwoSided = true,
    areaRectSideA = true,
    areaRectSideB = true,
    group = true,
    envColorGroup = true,
    colorGroupSaturation = true,
    unit = true,
    temperature = true,
    useInParticles = true,
    useInTransparents = true,
    scaleVolFog = true,
    scaleGI = true,
    scaleEnvProbes = true,
    sceneDiffuse = true,
    sceneSpecularScale = true,
    roughnessBias = true,
    sourceRadius = true,
    autoHideDistance = true,
    EV = true,
    attenuation = true,
    clampAttenuation = true,
    directional = true,
    portalAngleCutoff = true,
    allowDistantLight = true,
    rayTracedShadowsPlatform = true,
    rayTracingLightSourceRadius = true,
    rayTracingContactShadowRange = true,
    rayTracingIntensityScale = true,
    pathTracingLightUsage = true,
    pathTracingOverrideScaleGI = true,
    rtxdiShadowStartingDistance = true
}

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

---Installs the light component drawing methods onto the entity spawnable class.
---@param entity table The entity spawnable class table
function lightComponentUI.install(entity)
    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    ---@return string
    function entity:drawLightComponentTypeTabs(componentID, component, componentChanges, propertySearch)
        local path = { "type" }
        local lightType = normalizeLightComponentType(getComponentValue(component, componentChanges, path))

        if not shouldDrawComponentPath(component, componentChanges, path, "Type", propertySearch) then
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

        self:drawComponentReset(componentID, path, "ELightType")
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
        if not shouldDrawComponentPath(component, componentChanges, path, "Color", propertySearch) then
            return false
        end

        self.lightComponentColorHexText = self.lightComponentColorHexText or {}
        self.lightComponentColorHexEditing = self.lightComponentColorHexEditing or {}

        local stateKey = tostring(componentID) .. ":" .. getComponentWidgetPath(path)
        local colorData = getComponentValue(component, componentChanges, path)
        local pendingColor = self:getComponentPendingValue(componentID, path)
        local color = pendingColor or colorDataToUnit(colorData)
        local currentHex = colorUtil.formatHexRGB(color)

        local popupId = "##lightComponentColorPicker" .. stateKey
        local modified = pendingColor ~= nil or isComponentPathModified(component, componentChanges, path)

        local changed, finished
        self.lightComponentColorHexText[stateKey], self.lightComponentColorHexEditing[stateKey], changed, finished = style.drawLightColorSwatch(
            self.object,
            popupId,
            getComponentWidgetID(componentID, path, "Hex"),
            color,
            self.lightComponentColorHexText[stateKey],
            self.lightComponentColorHexEditing[stateKey],
            {
                modified = modified,
                afterHexInput = function()
                    self:drawComponentReset(componentID, path, "Color")
                end
            }
        )

        if changed then
            self.lightComponentColorHexText[stateKey] = (self.lightComponentColorHexText[stateKey] or ""):upper()
            local parsedColor = colorUtil.parseHexRGB(self.lightComponentColorHexText[stateKey])
            if parsedColor then
                parsedColor[4] = color[4]
                self:setComponentPendingValue(componentID, path, parsedColor)
            end
        end
        if finished then
            local parsedColor = colorUtil.parseHexRGB(self.lightComponentColorHexText[stateKey])
            if parsedColor then
                parsedColor[4] = color[4]
                self:commitComponentValue(componentID, path, unitToColorData(colorData, parsedColor))
                self.lightComponentColorHexText[stateKey] = colorUtil.formatHexRGB(parsedColor)
            else
                self:clearComponentPendingValue(componentID, path)
                self.lightComponentColorHexText[stateKey] = currentHex
            end
        end

        if ImGui.BeginPopup(popupId) then
            local newColor, colorChanged, colorFinished = style.trackedColorPicker(self.object, getComponentWidgetID(componentID, path, "Picker"), color)
            if colorChanged then
                newColor[4] = color[4]
                self:setComponentPendingValue(componentID, path, newColor)
                self.lightComponentColorHexText[stateKey] = colorUtil.formatHexRGB(newColor)
            end
            if colorFinished then
                local finalColor = colorChanged and newColor or self:getComponentPendingValue(componentID, path)
                if finalColor ~= nil then
                    finalColor[4] = finalColor[4] or color[4]
                    self:commitComponentValue(componentID, path, unitToColorData(colorData, finalColor))
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
        local drawPrimaryFields = shouldDrawAnyComponentField(component, componentChanges, primaryFields, propertySearch)

        if drewColor and drawPrimaryFields then
            ImGui.SameLine()
            ImGui.Dummy(2 * style.viewSize, 0)
            ImGui.SameLine()
        end

        if drawPrimaryFields then
            ImGui.BeginGroup()
            ImGui.Dummy(0, 8 * style.viewSize)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "intensity" }, "Intensity", {
                icon = IconGlyphs.WeatherSunny,
                newLine = true,
                step = 1,
                min = 0,
                maxValue = 999999,
                format = "%.1f",
                width = 80
            }, propertySearch)
            ImGui.Dummy(0, 4 * style.viewSize)
            if self:drawComponentFloatRow(componentID, component, componentChanges, { "radius" }, "Radius", {
                icon = IconGlyphs.RadiusOutline,
                iconColor = style.lightRadiusIconColor,
                newLine = true,
                step = 0.25,
                min = 0,
                maxValue = 9999,
                format = "%.1fm",
                width = 60,
                tooltip = "How far the light source emits light."
            }, propertySearch) then
                self:drawComponentRadiusToggle(componentID, component)
            end
            ImGui.EndGroup()
        end

        ImGui.Dummy(0, 8 * style.viewSize)

        if lightType == LIGHT_COMPONENT_TYPE_AREA then
            self:drawComponentFloatRow(componentID, component, componentChanges, { "capsuleLength" }, "Capsule Length", {
                icon = IconGlyphs.Pill,
                max = baseMax,
                step = 0.05,
                min = 0,
                maxValue = 9999,
                format = "%.2fm",
                width = 60
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "spotCapsule" }, "Spot Capsule", {
                max = baseMax
            }, propertySearch)
        end

        local spotCapsule = toComponentBool(getComponentValue(component, componentChanges, { "spotCapsule" }))
        if lightType == LIGHT_COMPONENT_TYPE_SPOT or (lightType == LIGHT_COMPONENT_TYPE_AREA and spotCapsule) then
            self:drawComponentFloatRow(componentID, component, componentChanges, { "innerAngle" }, "Inner Angle", {
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
            self:drawComponentFloatRow(componentID, component, componentChanges, { "outerAngle" }, "Outer Angle", {
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
            self:drawComponentFloatRow(componentID, component, componentChanges, { "softness" }, "Softness", {
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
        if not shouldDrawComponentPath(component, componentChanges, path, "IES Profile", propertySearch) then
            return
        end

        self.lightComponentIESSearch = self.lightComponentIESSearch or {}
        local stateKey = getComponentPendingKey(componentID, path)
        self.lightComponentIESSearch[stateKey] = self.lightComponentIESSearch[stateKey] or ""

        local defaultValue = utils.getNestedValue(component, path)
        local defaultPath = iesProfiles.extractPath(defaultValue)
        local currentValue = getComponentValue(component, componentChanges, path)
        local currentPath = iesProfiles.extractPath(currentValue)
        local modified = isComponentPathModified(component, componentChanges, path)

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
        drawComponentLabelRow("IES Profile", max, modified)

        local list = iesProfiles.getSelectable()
        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
        local newPath, newSearch, changed = style.trackedSearchDropdown(
            getComponentWidgetID(componentID, path),
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
        self:drawComponentReset(componentID, path, "raRef:CIESDataResource")
        style.popStyleColor(modified)

        if changed and newPath ~= currentPath then
            commitProfile(newPath)
        end

        ImGui.SameLine()
        ImGui.BeginDisabled(#iesProfiles.get() == 0)
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.SkipPrevious .. getComponentWidgetID(componentID, path, "CyclePrevious")) then
            local previousProfile, cycled = iesProfiles.getPrevious(currentPath)
            if cycled then
                history.addAction(history.getElementChange(self.object))
                commitProfile(previousProfile)
            end
        end
        style.tooltip("Select the previous IES profile.")
        ImGui.SameLine()
        if ImGui.Button(IconGlyphs.SkipNext .. getComponentWidgetID(componentID, path, "Cycle")) then
            local nextProfile, cycled = iesProfiles.getNext(currentPath)
            if cycled then
                history.addAction(history.getElementChange(self.object))
                commitProfile(nextProfile)
            end
        end
        style.pushButtonNoBG(false)
        ImGui.EndDisabled()
        style.tooltip("Select the next IES profile.")

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Reload .. getComponentWidgetID(componentID, path, "Reload")) then
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
            { path = { "shadowRadius" }, label = "Shadow Radius" },
            { path = { "shadowSoftnessMode" }, label = "Shadow Softness Mode" },
            { path = { "shadowFadeDistance" }, label = "Shadow Fade Distance" },
            { path = { "shadowFadeRange" }, label = "Shadow Fade Range" }
        }
        if not shouldDrawAnyComponentField(component, componentChanges, fields, propertySearch) then
            return
        end

        if drawComponentSectionHeader("Shadow Settings", self:isAnyComponentFieldModified(componentID, component, componentChanges, fields)) then
            local max = utils.getTextMaxWidth({
                "Contact Shadows",
                "Local Shadows",
                "Local Shadows (Statics Only)",
                "Shadow Angle",
                "Shadow Radius",
                "Shadow Softness Mode",
                "Shadow Fade Distance",
                "Shadow Fade Range"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

            self:drawComponentEnumRow(componentID, component, componentChanges, { "contactShadows" }, "Contact Shadows", "rendContactShadowReciever", {
                max = max,
                width = 130
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "enableLocalShadows" }, "Local Shadows", {
                max = max
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "enableLocalShadowsForceStaticsOnly" }, "Local Shadows (Statics Only)", {
                max = max,
                disabled = not toComponentBool(getComponentValue(component, componentChanges, { "enableLocalShadows" }))
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "shadowAngle" }, "Shadow Angle", {
                max = max,
                step = 0.01,
                min = -1,
                maxValue = 9999,
                format = "%.2f",
                width = 75,
                default = -1,
                tooltip = "-1 lets the engine derive the angle from the light itself"
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "shadowRadius" }, "Shadow Radius", {
                max = max,
                step = 0.01,
                min = -1,
                maxValue = 9999,
                format = "%.2f",
                width = 75,
                default = -1,
                tooltip = "Radius of the shadow casting source\n-1 lets the engine derive it from the light itself"
            }, propertySearch)
            self:drawComponentEnumRow(componentID, component, componentChanges, { "shadowSoftnessMode" }, "Shadow Softness Mode", "ELightShadowSoftnessMode", {
                max = max,
                width = 130
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "shadowFadeDistance" }, "Shadow Fade Distance", {
                max = max,
                step = 0.01,
                min = 0,
                maxValue = 9999,
                format = "%.1f",
                width = 75
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "shadowFadeRange" }, "Shadow Fade Range", {
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
        if not shouldDrawAnyComponentField(component, componentChanges, fields, propertySearch) then
            return
        end

        if drawComponentSectionHeader("Flicker Settings", self:isAnyComponentFieldModified(componentID, component, componentChanges, fields)) then
            local max = utils.getTextMaxWidth({
                "Flicker Period",
                "Flicker Strength",
                "Flicker Offset"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

            self:drawComponentFloatRow(componentID, component, componentChanges, { "flicker", "flickerPeriod" }, "Flicker Period", {
                max = max,
                step = 0.01,
                min = 0.05,
                maxValue = 9999,
                format = "%.2f",
                width = 85
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "flicker", "flickerStrength" }, "Flicker Strength", {
                max = max,
                step = 0.01,
                min = 0,
                maxValue = 9999,
                format = "%.2f",
                width = 85
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "flicker", "positionOffset" }, "Flicker Offset", {
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
        if not shouldDrawComponentPath(component, componentChanges, path, "Light Channels", propertySearch) then
            return
        end

        if drawComponentSectionHeader("Light Channels", self:isAnyComponentFieldModified(componentID, component, componentChanges, {
            { path = path }
        })) then
            local selection = decodeLightChannelSelection(getComponentValue(component, componentChanges, path))
            local previous = encodeLightChannelSelection(selection)
            selection = style.drawLightChannelsSelector(self.object, selection)
            local current = encodeLightChannelSelection(selection)
            self:drawComponentReset(componentID, path, "rendLightChannel")

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
    function entity:drawLightComponentGroupSection(componentID, component, componentChanges, propertySearch)
        local fields = {
            { path = { "group" }, label = "Light Group" },
            { path = { "envColorGroup" }, label = "Env. Color Group" },
            { path = { "colorGroupSaturation" }, label = "Color Group Saturation" }
        }
        if not shouldDrawAnyComponentField(component, componentChanges, fields, propertySearch) then
            return
        end

        if drawComponentSectionHeader("Group Settings", self:isAnyComponentFieldModified(componentID, component, componentChanges, fields)) then
            local max = utils.getTextMaxWidth({
                "Light Group",
                "Env. Color Group",
                "Color Group Saturation"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

            self:drawComponentEnumRow(componentID, component, componentChanges, { "group" }, "Light Group", "rendLightGroup", {
                max = max,
                width = 130,
                tooltip = "Render group this light belongs to, used to toggle sets of lights together"
            }, propertySearch)
            self:drawComponentEnumRow(componentID, component, componentChanges, { "envColorGroup" }, "Env. Color Group", "EEnvColorGroup", {
                max = max,
                width = 130,
                tooltip = "Environment color group, letting the weather/environment system tint this light"
            }, propertySearch)
            self:drawComponentIntRow(componentID, component, componentChanges, { "colorGroupSaturation" }, "Color Group Saturation", {
                max = max,
                min = 0,
                maxValue = 255,
                width = 110,
                typeName = "Uint8",
                default = 100,
                tooltip = "How strongly the environment color group tints this light"
            }, propertySearch)

            ImGui.TreePop()
        end
    end

    ---Emitter geometry only the Area light type makes use of, the primary block keeps the two
    ---properties that get adjusted often (Capsule Length and Spot Capsule).
    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    function entity:drawLightComponentAreaSection(componentID, component, componentChanges, propertySearch)
        -- Hidden for the other light types, which ignore these properties anyway, but still
        -- reachable through the property search so a stored value never becomes uneditable.
        local searchActive = type(propertySearch) == "string" and propertySearch ~= ""
        local lightType = normalizeLightComponentType(getComponentValue(component, componentChanges, { "type" }))
        if lightType ~= LIGHT_COMPONENT_TYPE_AREA and not searchActive then
            return
        end

        local fields = {
            { path = { "areaShape" }, label = "Area Shape" },
            { path = { "areaTwoSided" }, label = "Two Sided" },
            { path = { "areaRectSideA" }, label = "Rect Side A" },
            { path = { "areaRectSideB" }, label = "Rect Side B" }
        }
        if not shouldDrawAnyComponentField(component, componentChanges, fields, propertySearch) then
            return
        end

        if drawComponentSectionHeader("Area Settings", self:isAnyComponentFieldModified(componentID, component, componentChanges, fields)) then
            local max = utils.getTextMaxWidth({
                "Area Shape",
                "Two Sided",
                "Rect Side A",
                "Rect Side B"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

            self:drawComponentEnumRow(componentID, component, componentChanges, { "areaShape" }, "Area Shape", "EAreaLightShape", {
                max = max,
                width = 130,
                tooltip = "Shape of the emitting surface\nCapsule uses Capsule Length and Source Radius\nSphere uses only Source Radius"
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "areaTwoSided" }, "Two Sided", {
                max = max,
                default = true,
                tooltip = "Emit light from both sides of the area light instead of the facing side only"
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "areaRectSideA" }, "Rect Side A", {
                max = max,
                step = 0.05,
                min = 0,
                maxValue = 9999,
                format = "%.2fm",
                width = 75,
                default = 1,
                tooltip = "Width of the rectangular emitter"
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "areaRectSideB" }, "Rect Side B", {
                max = max,
                step = 0.05,
                min = 0,
                maxValue = 9999,
                format = "%.2fm",
                width = 75,
                default = 1,
                tooltip = "Height of the rectangular emitter"
            }, propertySearch)

            ImGui.TreePop()
        end
    end

    ---@param componentID string|number
    ---@param component table
    ---@param componentChanges table?
    ---@param propertySearch string?
    function entity:drawLightComponentMiscSection(componentID, component, componentChanges, propertySearch)
        local fields = {
            { path = { "unit" }, label = "Intensity Unit" },
            { path = { "temperature" }, label = "Temperature" },
            { path = { "useInParticles" }, label = "Use in particles" },
            { path = { "useInTransparents" }, label = "Use in transparents" },
            { path = { "scaleVolFog" }, label = "Scale Vol. Fog" },
            { path = { "scaleGI" }, label = "Scale GI" },
            { path = { "scaleEnvProbes" }, label = "Scale Env. Probes" },
            { path = { "sceneDiffuse" }, label = "Scene Diffuse" },
            { path = { "sceneSpecularScale" }, label = "Specular Scale" },
            { path = { "roughnessBias" }, label = "Roughness Bias" },
            { path = { "sourceRadius" }, label = "Source Radius" },
            { path = { "autoHideDistance" }, label = "Auto Hide Distance" },
            { path = { "EV" }, label = "EV" },
            { path = { "attenuation" }, label = "Attenuation Mode" },
            { path = { "clampAttenuation" }, label = "Clamp Attenuation" },
            { path = { "directional" }, label = "Directional" },
            { path = { "portalAngleCutoff" }, label = "Portal Angle Cutoff" },
            { path = { "allowDistantLight" }, label = "Allow Distant Light" }
        }
        if not shouldDrawAnyComponentField(component, componentChanges, fields, propertySearch) then
            return
        end

        if drawComponentSectionHeader("Misc. Settings", self:isAnyComponentFieldModified(componentID, component, componentChanges, fields)) then
            local max = utils.getTextMaxWidth({
                "Directional",
                "Use in particles",
                "Use in transparents",
                "Scale Vol. Fog",
                "Scale GI",
                "Scale Env. Probes",
                "Auto Hide Distance",
                "EV",
                "Intensity Unit",
                "Temperature",
                "Attenuation Mode",
                "Clamp Attenuation",
                "Specular Scale",
                "Scene Diffuse",
                "Roughness Bias",
                "Source Radius",
                "Portal Angle Cutoff",
                "Allow Distant Light"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

            self:drawComponentEnumRow(componentID, component, componentChanges, { "unit" }, "Intensity Unit", "ELightUnit", {
                max = max,
                width = 130,
                tooltip = "Unit the intensity value is interpreted in"
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "temperature" }, "Temperature", {
                max = max,
                step = 10,
                min = -1,
                maxValue = 20000,
                format = "%.0fK",
                width = 110,
                default = -1,
                tooltip = "Color temperature in Kelvin, tinting the light color\n-1 disables it and uses the light color as is"
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "useInParticles" }, "Use in particles", {
                max = max
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "useInTransparents" }, "Use in transparents", {
                max = max
            }, propertySearch)
            self:drawComponentIntRow(componentID, component, componentChanges, { "scaleVolFog" }, "Scale Vol. Fog", {
                max = max,
                min = 0,
                maxValue = 255,
                width = 110,
                typeName = "Uint8"
            }, propertySearch)
            self:drawComponentIntRow(componentID, component, componentChanges, { "scaleGI" }, "Scale GI", {
                max = max,
                min = 0,
                maxValue = 255,
                width = 110,
                typeName = "Uint8",
                default = 100,
                tooltip = "Scales how much this light contributes to global illumination"
            }, propertySearch)
            self:drawComponentIntRow(componentID, component, componentChanges, { "scaleEnvProbes" }, "Scale Env. Probes", {
                max = max,
                min = 0,
                maxValue = 255,
                width = 110,
                typeName = "Uint8",
                default = 100,
                tooltip = "Scales how much this light contributes to environment probes"
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "sceneDiffuse" }, "Scene Diffuse", {
                max = max
            }, propertySearch)
            self:drawComponentIntRow(componentID, component, componentChanges, { "sceneSpecularScale" }, "Specular Scale", {
                max = max,
                min = 0,
                maxValue = 255,
                width = 110,
                typeName = "Uint8"
            }, propertySearch)
            self:drawComponentIntRow(componentID, component, componentChanges, { "roughnessBias" }, "Roughness Bias", {
                max = max,
                min = -127,
                maxValue = 127,
                width = 110,
                typeName = "Int8"
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "sourceRadius" }, "Source Radius", {
                max = max,
                step = 0.0025,
                min = 0,
                maxValue = 9999,
                format = "%.3f",
                width = 110
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "autoHideDistance" }, "Auto Hide Distance", {
                max = max,
                step = 0.05,
                min = 0,
                maxValue = 9999,
                format = "%.1f",
                width = 110
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "EV" }, "EV", {
                max = max,
                step = 0.1,
                min = 0,
                maxValue = 9999,
                format = "%.1f",
                width = 110
            }, propertySearch)
            self:drawComponentEnumRow(componentID, component, componentChanges, { "attenuation" }, "Attenuation Mode", "rendLightAttenuation", {
                max = max,
                width = 130
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "clampAttenuation" }, "Clamp Attenuation", {
                max = max
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "directional" }, "Directional", {
                max = max
            }, propertySearch)
            self:drawComponentIntRow(componentID, component, componentChanges, { "portalAngleCutoff" }, "Portal Angle Cutoff", {
                max = max,
                min = 0,
                maxValue = 255,
                width = 110,
                typeName = "Uint8",
                tooltip = "Angle at which the light stops shining through portals"
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "allowDistantLight" }, "Allow Distant Light", {
                max = max,
                default = true,
                tooltip = "Let this light be picked up by the distant lights system\nwhich keeps it visible past the auto hide distance"
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
        if not shouldDrawAnyComponentField(component, componentChanges, fields, propertySearch) then
            return
        end

        if drawComponentSectionHeader("Ray/Path Tracing Settings", self:isAnyComponentFieldModified(componentID, component, componentChanges, fields)) then
            local max = utils.getTextMaxWidth({
                "Ray Traced Shadows Platform",
                "RT Light Source Radius",
                "RT Contact Shadow Range",
                "RT Intensity Scale",
                "Path Tracing Light Usage",
                "PT Override Scale GI",
                "RTXDI Shadow Start Distance"
            }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

            self:drawComponentEnumRow(componentID, component, componentChanges, { "rayTracedShadowsPlatform" }, "Ray Traced Shadows Platform", "rendRayTracedShadowsPlatform", {
                max = max,
                width = 175
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "rayTracingLightSourceRadius" }, "RT Light Source Radius", {
                max = max,
                step = 0.005,
                min = 0,
                maxValue = 9999,
                format = "%.3f",
                width = 120
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "rayTracingContactShadowRange" }, "RT Contact Shadow Range", {
                max = max,
                step = 0.05,
                min = 0,
                maxValue = 9999,
                format = "%.2f",
                width = 120
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "rayTracingIntensityScale" }, "RT Intensity Scale", {
                max = max,
                step = 0.01,
                min = 0,
                maxValue = 9999,
                format = "%.2f",
                width = 120
            }, propertySearch)
            self:drawComponentEnumRow(componentID, component, componentChanges, { "pathTracingLightUsage" }, "Path Tracing Light Usage", "rendEPathTracingLightUsage", {
                max = max,
                width = 175
            }, propertySearch)
            self:drawComponentBoolRow(componentID, component, componentChanges, { "pathTracingOverrideScaleGI" }, "PT Override Scale GI", {
                max = max
            }, propertySearch)
            self:drawComponentFloatRow(componentID, component, componentChanges, { "rtxdiShadowStartingDistance" }, "RTXDI Shadow Start Distance", {
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
        self:drawComponentOtherSection(componentID, component, componentChanges, lightComponentNewUIKeys, propertySearch)
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
        self:drawLightComponentGroupSection(componentID, component, componentChanges, propertySearch)
        self:drawLightComponentAreaSection(componentID, component, componentChanges, propertySearch)
        self:drawLightComponentMiscSection(componentID, component, componentChanges, propertySearch)
        self:drawLightComponentRayPathTracingSection(componentID, component, componentChanges, propertySearch)
        self:drawLightComponentOtherSection(componentID, component, componentChanges, propertySearch)
    end
end

lightComponentUI.decodeLightChannelSelection = decodeLightChannelSelection
lightComponentUI.encodeLightChannelSelection = encodeLightChannelSelection

return lightComponentUI
