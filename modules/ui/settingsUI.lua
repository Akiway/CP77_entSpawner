local style = require("modules/ui/style")
local about = require("modules/utils/about")
local settings = require("modules/utils/settings")
local field = require("modules/utils/field")
local cache = require("modules/utils/cache")
local utils = require("modules/utils/utils")
local perf = require("modules/utils/perf")
local rht = require("modules/utils/rhtPlugin")
local projectTag = require("modules/utils/ui/projectTag")
local colliderBase = require("modules/classes/spawn/collision/colliderBase")
local previewControls = require("modules/utils/previewControls")
local keys = require("modules/utils/keys")
local input = require("modules/utils/input")

local colliderColors = { "Red", "Green", "Blue" }
local streamingPresetLabels = { "Interior", "Street", "District", "Landscape", "To the Moon" }
local exportFormatLabels = { "JSON", "YAML" }
local PROJECT_NEUTRAL_LABEL = "No Project"
local outlineColors = { "Green", "Red", "Blue", "Orange", "Yellow", "Light Blue", "White", "Black" }
local windowNames = { "World Builder", "Object Spawner", "Entity Spawner", "World Additor", "World Editing Toolkit", "World Editor", "WheezeKit", "Buildy McBuildface", "Keanus Editing Kit (Kek)", "Redkit at home" }
local groupLoadSpeedOptions = { "Fast - with FPS drops", "Slow - without FPS drops" }
local wireframeColorStyles = { "Darker + white text", "Lighter + black text" }
local colorPickerStyles = { "Hue Bar", "Hue Wheel" }
local speedUnits = { "km/h", "mph" }
local actionLabelDisplayModeOptions = {
    { value = 1, label = "Preferred icon" },
    { value = 2, label = "Icon + text" },
    { value = 3, label = "Preferred text" }
}
local wireframeColorStyleTooltipText = "Global projected wireframe color style used by streaming distance and streaming box overlays."

local settingsUI = {}

local function drawWireframePreviewTextBold(drawList, position, color, size, text, scale)
    local content = tostring(text)
    local offset = 0.2 * scale

    ImGui.ImDrawListAddText(drawList, size, position.x + offset, position.y, color, content)
    ImGui.ImDrawListAddText(drawList, size, position.x, position.y + offset, color, content)
    ImGui.ImDrawListAddText(drawList, size, position.x + offset, position.y + offset, color, content)
    ImGui.ImDrawListAddText(drawList, size, position.x, position.y, color, content)
end

local function getWireframePreviewBadgeSize(text, scale, fontRatio)
    local textWidth, textHeight = ImGui.CalcTextSize(text)
    local width = (textWidth * fontRatio) + (10 * scale)
    local height = (textHeight * fontRatio) + (7 * scale)

    return width, height
end

local function drawWireframePreviewBadge(drawList, x, y, text, badgeColor, textColor, scale)
    local fontRatio = 0.8
    local fontSize = ImGui.GetFontSize() * fontRatio
    local textWidth, textHeight = ImGui.CalcTextSize(text)
    textWidth = textWidth * fontRatio
    textHeight = textHeight * fontRatio
    local paddingX = 5 * scale
    local paddingY = 2 * scale

    local badgeX1 = x
    local badgeY1 = y
    local badgeX2 = x + (paddingX * 2) + textWidth
    local badgeY2 = y + paddingX + paddingY + textHeight

    ImGui.ImDrawListAddRectFilled(drawList, badgeX1, badgeY1, badgeX2, badgeY2, badgeColor, 4 * scale)

    local labelPos = {
        x = x + paddingX,
        y = y + (paddingX - 1 * scale)
    }
    drawWireframePreviewTextBold(drawList, labelPos, textColor, fontSize, text, scale)

    return badgeX2 - badgeX1, badgeY2 - badgeY1
end

local function drawWireframeColorStylePreview()
    local scale = style.viewSize or 1
    local drawList = ImGui.GetWindowDrawList()
    local originX, originY = ImGui.GetCursorScreenPos()
    local gapX = 10 * scale
    local gapY = 8 * scale
    local panelPad = 6 * scale
    local badgeText = "50.6m"
    local badgeW, badgeH = getWireframePreviewBadgeSize(badgeText, scale, 0.8)
    local columns = 3
    local rows = 2
    local previewWidth = badgeW * columns + gapX * (columns - 1)
    local previewHeight = badgeH * rows + gapY * (rows - 1)
    local badges = {
        { color = style.successColor, textColor = 0xFFDCD8D1 }, -- darker green
        { color = 0xFF0000B2, textColor = 0xFFDCD8D1 }, -- darker red
        { color = 0xFF992D00, textColor = 0xFFDCD8D1 }, -- darker blue 
        { color = 0xFF50FF50, textColor = 0xFF000000 }, -- lighter green
        { color = 0xFF5050FF, textColor = 0xFF000000 }, -- lighter red
        { color = 0xFFFF7F00, textColor = 0xFF000000 }  -- lighter blue
    }

    ImGui.Dummy(previewWidth + panelPad * 2, previewHeight + panelPad * 2)

    local panelX1 = originX
    local panelY1 = originY
    local panelX2 = originX + previewWidth + panelPad * 2
    local panelY2 = originY + previewHeight + panelPad * 2

    ImGui.ImDrawListAddRectFilled(drawList, panelX1, panelY1, panelX2, panelY2, 0x66000000, 6 * scale)

    for index, badge in ipairs(badges) do
        local zeroIndex = index - 1
        local col = zeroIndex % columns
        local row = math.floor(zeroIndex / columns)
        local badgeX = originX + panelPad + col * (badgeW + gapX)
        local badgeY = originY + panelPad + row * (badgeH + gapY)

        drawWireframePreviewBadge(drawList, badgeX, badgeY, badgeText, badge.color, badge.textColor, scale)
    end
end

local function drawWireframeColorStyleTooltip()
    if not ImGui.IsItemHovered() then return end

    local scale = style.viewSize or 1
    local wrapWidth = 340 * scale

    ImGui.BeginTooltip()
    ImGui.PushStyleColor(ImGuiCol.Text, 0xFFFFFFFF)
    ImGui.PushTextWrapPos(ImGui.GetCursorPosX() + wrapWidth)
    ImGui.TextUnformatted(wireframeColorStyleTooltipText)
    ImGui.PopTextWrapPos()
    ImGui.PopStyleColor()
    ImGui.Spacing()
    drawWireframeColorStylePreview()

    ImGui.EndTooltip()
end

---@param spawner spawner
local function refreshSelectedVisualizers(spawner)
    local spawnedUI = spawner and spawner.baseUI and spawner.baseUI.spawnedUI
    if not spawnedUI then return end

    spawnedUI.ensureCache()
    local selectedCount = #spawnedUI.selectedPaths
    local selectedVisualizersEnabled = settings.selectedVisualizersEnabled ~= false

    for _, entry in ipairs(spawnedUI.selectedPaths) do
        local element = entry.ref

        if utils.isA(element, "positionable") then
            local showOnHover = settings.gizmoOnHover and (element.hovered or element.controlsHovered)
            local showOnSelected = selectedVisualizersEnabled and settings.gizmoOnSelected and selectedCount == 1
            local keepVisible = showOnHover or showOnSelected

            element:setVisualizerState(keepVisible)
            if not element.visualizerState then
                element:setVisualizerDirection("none")
            end
        end

        if utils.isA(element, "spawnableElement") and element.spawnable and element.spawnable:isSpawned() then
            local outline = settings.outlineSelected and selectedVisualizersEnabled and element.selected and (settings.outlineColor + 1) or 0
            element.spawnable:setOutline(outline)
        end
    end
end

---@param spawner spawner
---@return table[]
local function getSpawnNewVisualizerClassGroups(spawner)
    local spawnUI = spawner and spawner.baseUI and spawner.baseUI.spawnUI or nil
    if not spawnUI or type(spawnUI.getVisualizerClassGroups) ~= "function" then
        return {}
    end

    return spawnUI.getVisualizerClassGroups() or {}
end

---@param groups table[]
---@return string
---@return number
---@return number
local function getSpawnNewVisualizerSummary(groups)
    if type(settings.spawnNewVisualizerEnabledByModule) ~= "table" then
        settings.spawnNewVisualizerEnabledByModule = {}
        settings.save()
    end

    local enabledCount = 0
    local totalCount = 0
    for _, group in ipairs(groups) do
        for _, entry in ipairs(group.entries or {}) do
            totalCount = totalCount + 1
            if settings.spawnNewVisualizerEnabledByModule[entry.modulePath] == true then
                enabledCount = enabledCount + 1
            end
        end
    end

    if totalCount == 0 then
        return "No classes", enabledCount, totalCount
    end

    return string.format("%d / %d enabled", enabledCount, totalCount), enabledCount, totalCount
end

---@param groups table[]
---@param state boolean
---@return boolean
local function setSpawnNewVisualizerDefaultsForAll(groups, state)
    if type(settings.spawnNewVisualizerEnabledByModule) ~= "table" then
        settings.spawnNewVisualizerEnabledByModule = {}
    end

    local changed = false
    for _, group in ipairs(groups) do
        for _, entry in ipairs(group.entries or {}) do
            if settings.spawnNewVisualizerEnabledByModule[entry.modulePath] ~= state then
                settings.spawnNewVisualizerEnabledByModule[entry.modulePath] = state
                changed = true
            end
        end
    end

    if changed then
        settings.save()
    end

    return changed
end

---@param groups table[]
---@return boolean
local function resetSpawnNewVisualizerDefaultsToClassDefaults(groups)
    if type(settings.spawnNewVisualizerEnabledByModule) ~= "table" then
        settings.spawnNewVisualizerEnabledByModule = {}
    end

    local changed = false
    for _, group in ipairs(groups) do
        for _, entry in ipairs(group.entries or {}) do
            local defaultValue = entry.defaultPreviewed == true
            if settings.spawnNewVisualizerEnabledByModule[entry.modulePath] ~= defaultValue then
                settings.spawnNewVisualizerEnabledByModule[entry.modulePath] = defaultValue
                changed = true
            end
        end
    end

    if changed then
        settings.save()
    end

    return changed
end

---@param spawner spawner
local function drawSpawnNewVisualizerDefaultSelector(spawner)
    local groups = getSpawnNewVisualizerClassGroups(spawner)
    local summaryLabel, _, totalCount = getSpawnNewVisualizerSummary(groups)

    ImGui.SetNextWindowSizeConstraints(1, 1, 550 * style.viewSize, 520 * style.viewSize)
    ImGui.SetNextItemWidth(math.max(280 * style.viewSize, 1))
    if ImGui.BeginCombo("Active visualizers by default##spawnNewVisualizerDefaults", summaryLabel) then
        style.styledTextWrapped("This only affects elements newly added from the Spawn New tab.", style.mutedColor)
        style.mutedText("Saved/Favorites keep their own preview state.")
        ImGui.Spacing()

        if totalCount > 0 then
            style.pushButtonNoBG(true)
            if ImGui.Button(IconGlyphs.ExpandAllOutline .. "##spawnNewVisualizerEnableAll") then
                setSpawnNewVisualizerDefaultsForAll(groups, true)
            end
            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.CollapseAllOutline .. "##spawnNewVisualizerDisableAll") then
                setSpawnNewVisualizerDefaultsForAll(groups, false)
            end
            style.pushButtonNoBG(false)
            ImGui.SameLine()
            local resetDefaultsLabel, resetDefaultsHiddenText = style.resolveActionLabel(IconGlyphs.Restore, "Reset to defaults", "spawnNewVisualizerResetDefaults", nil, true)
            if ImGui.Button(resetDefaultsLabel) then
                resetSpawnNewVisualizerDefaultsToClassDefaults(groups)
            end
            style.tooltipActionLabel(resetDefaultsHiddenText)

            ImGui.Separator()
            ImGui.Spacing()
            for _, group in ipairs(groups) do
                style.sectionHeaderStart(group.typeName)

                for _, entry in ipairs(group.entries or {}) do
                    local id = "##spawnNewVisualizerDefault_" .. tostring(entry.modulePath)
                    local current = settings.spawnNewVisualizerEnabledByModule[entry.modulePath] == true
                    local nextState, toggled = ImGui.Checkbox(entry.name .. id, current)

                    if toggled then
                        settings.spawnNewVisualizerEnabledByModule[entry.modulePath] = nextState
                        settings.save()
                    end

                    style.tooltip("Module: " .. tostring(entry.modulePath))
                end

                style.sectionHeaderEnd(false)
            end
        else
            style.mutedText("No Spawn New classes with visualizer controls were found.")
        end

        ImGui.EndCombo()
    end

    style.tooltip("Choose which Spawn New classes start with visualization helper enabled by default.")
end

---Returns existing project tags gathered from saved groups, when available.
---@return table<string, table> projectMap
---@return table[] projectOptions
local function getDefaultProjectOptions()
    if type(savedUI) == "table" and type(savedUI.getProjectCatalog) == "function" then
        return savedUI.getProjectCatalog()
    end

    return {}, {}
end

---Primes the create-project popup editor state for the default project tag.
local function primeDefaultProjectCreateState()
    local current = projectTag.normalizeProject(settings.defaultGroupProject)
    settingsUI.defaultProjectCreateState = {
        name = "",
        icon = current and current.icon or projectTag.DEFAULT_ICON,
        color = projectTag.normalizeColor(current and current.color or nil)
    }
    settingsUI.defaultProjectIconSearch = settingsUI.defaultProjectIconSearch or ""
end

---Stores (or clears) the default project tag for new groups and persists it.
---@param project table?
local function setDefaultGroupProject(project)
    local normalized = projectTag.normalizeProject(project)
    if normalized then
        settings.defaultGroupProject = {
            name = normalized.name,
            icon = normalized.icon,
            color = { normalized.color[1], normalized.color[2], normalized.color[3] }
        }
    else
        settings.defaultGroupProject = nil
    end

    settings.save()
end

---Draws the "Default project tag for new groups" selector, matching the Projects
---tab assignment UI (existing projects + create-new + clear).
local function drawDefaultProjectSelector()
    local current = projectTag.normalizeProject(settings.defaultGroupProject)
    local currentKey = current and projectTag.normalizeNameKey(current.name) or nil
    local previewText = current and current.name or PROJECT_NEUTRAL_LABEL
    local previewIcon = IconGlyphs[(current and current.icon) or projectTag.DEFAULT_ICON] or ""

    local _, projectOptions = getDefaultProjectOptions()

    ImGui.SetNextItemWidth(200 * style.viewSize)
    if ImGui.BeginCombo("Default project tag for new groups", previewIcon .. " " .. previewText) then
        if ImGui.Selectable((IconGlyphs[projectTag.DEFAULT_ICON] or "") .. " " .. PROJECT_NEUTRAL_LABEL, current == nil) and current ~= nil then
            setDefaultGroupProject(nil)
        end

        for _, option in ipairs(projectOptions) do
            local icon = IconGlyphs[option.project.icon] or IconGlyphs[projectTag.DEFAULT_ICON] or ""
            local label = string.format("%s %s##defaultProjectOption%s", icon, option.project.name, option.key)
            if ImGui.Selectable(label, currentKey == option.key) and currentKey ~= option.key then
                setDefaultGroupProject(option.project)
            end
        end

        ImGui.Separator()
        if ImGui.Selectable((IconGlyphs.Plus or "+") .. " Create new project tag...##defaultProjectCreate", false) then
            primeDefaultProjectCreateState()
            settingsUI.pendingDefaultProjectPopup = true
        end

        ImGui.EndCombo()
    end
    style.tooltip("Project tag assigned to newly created groups by default.")

    ImGui.SameLine()
    style.pushGreyedOut(current == nil)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Close .. "##defaultProjectClear") and current ~= nil then
        setDefaultGroupProject(nil)
    end
    style.pushButtonNoBG(false)
    style.popGreyedOut(current == nil)
    style.tooltip("Clear default project tag")

    local popupId = "##defaultGroupProjectPopup"
    if settingsUI.pendingDefaultProjectPopup then
        ImGui.OpenPopup(popupId)
        settingsUI.pendingDefaultProjectPopup = false
    end

    if not settingsUI.defaultProjectCreateState then
        primeDefaultProjectCreateState()
    end
    local editor = settingsUI.defaultProjectCreateState

    if ImGui.BeginPopup(popupId) then
        style.mutedText("Create default project tag")
        ImGui.Separator()

        ImGui.SetNextItemWidth(220 * style.viewSize)
        editor.name, _ = ImGui.InputTextWithHint("##defaultProjectName", "Project name...", editor.name or "", 100)

        editor.icon, settingsUI.defaultProjectIconSearch, _ = field.drawIconSelector("settingsDefaultProject", editor.icon, settingsUI.defaultProjectIconSearch)
        ImGui.SameLine()
        editor.color, _ = style.trackedColor(nil, "##defaultProjectColor", editor.color, 58)

        ImGui.Dummy(0, 8 * style.viewSize)
        local canAssign = projectTag.trimText(editor.name) ~= ""
        style.pushGreyedOut(not canAssign)
        if ImGui.Button("Assign##defaultProject") and canAssign then
            setDefaultGroupProject({ name = editor.name, icon = editor.icon, color = editor.color })
            ImGui.CloseCurrentPopup()
        end
        style.popGreyedOut(not canAssign)

        ImGui.SameLine()
        if ImGui.Button("Cancel##defaultProject") then
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end
end

---Draws the "Default values" section grouping default values for inputs and selectors.
local function drawDefaultsSection()
    if not ImGui.TreeNodeEx("Default values", ImGuiTreeNodeFlags.SpanFullWidth) then
        return
    end

    ImGui.Dummy(0, 4 * style.viewSize)
    style.sectionHeaderStart("Node properties")
    local changed
    settings.nodeRefPrefix, changed = ImGui.InputTextWithHint("NodeRef Prefix", "", settings.nodeRefPrefix, 128)
    if changed then settings.save() end
    style.tooltip("Prefix to add when auto generating NodeRef")

    settings.defaultColliderMaterial = tonumber(settings.defaultColliderMaterial) or 0
    local selectedMaterial = colliderBase.getMaterialDisplayByIndex(settings.defaultColliderMaterial)
    local materialChanged
    selectedMaterial, settingsUI.defaultColliderMaterialSearch, materialChanged = style.trackedSearchDropdown(
        "Default Collider Material##defaultColliderMaterial",
        "Search material...",
        selectedMaterial,
        settingsUI.defaultColliderMaterialSearch or "",
        colliderBase.getMaterialDisplayOptions(),
        {
            width = 200,
            matchContentWidth = true,
            tooltip = "Physics material used by default for newly created colliders."
        }
    )
    if materialChanged then
        settings.defaultColliderMaterial = colliderBase.getMaterialIndexByDisplay(selectedMaterial) or settings.defaultColliderMaterial
        settings.save()
    end

    local streamingPreset = math.max(0, math.min(#streamingPresetLabels - 1, settings.defaultStreamingPreset or 0))
    local streamingPresetIndex, streamingChanged = ImGui.Combo("Default Streaming distance", streamingPreset, streamingPresetLabels, #streamingPresetLabels)
    if streamingChanged then
        settings.defaultStreamingPreset = streamingPresetIndex
        settings.save()
    end
    style.comboValueTooltip(streamingPreset, streamingPresetLabels, "Streaming distance preset applied to newly spawned nodes.\nSets both the preset selector and the numeric Streaming Distance value.\n- Interior | 100\n- Street | 400\n- District | 1000\n- Landscape | 5000\n- To the Moon | infinite")
    style.sectionHeaderEnd()

    ImGui.Dummy(0, 8 * style.viewSize)
    style.sectionHeaderStart("Groups")
    drawDefaultProjectSelector()
    style.sectionHeaderEnd()

    ImGui.Dummy(0, 8 * style.viewSize)
    style.sectionHeaderStart("Export")
    local exportFormat = math.max(0, math.min(#exportFormatLabels - 1, settings.defaultExportFormat or 0))
    local exportFormatIndex, exportFormatChanged = ImGui.Combo("Default export format", exportFormat, exportFormatLabels, #exportFormatLabels)
    if exportFormatChanged then
        settings.defaultExportFormat = exportFormatIndex
        settings.save()
    end
    style.tooltip("Default format for the generated .xl file in the Export tab.")
    style.sectionHeaderEnd()
    
    ImGui.Dummy(0, 4 * style.viewSize)
    ImGui.TreePop()
end

---Draws one rebindable row: a button showing the bound key, which starts listening when clicked.
---@param action { id: string, label: string, hint: string }
---@param bindings table<string, string>
---@param usageCount table<string, integer> How many actions each key is bound to, to flag conflicts
local function drawBindingRow(action, bindings, usageCount)
    local listening = settingsUI.listeningBinding == action.id
    local bound = bindings[action.id] or ""
    local conflicting = not listening and bound ~= "" and (usageCount[bound] or 0) > 1

    style.pushStyleColor(conflicting, ImGuiCol.Text, style.warnColor)
    if ImGui.Button((listening and "Press a key..." or keys.getLabel(bound)) .. "##binding" .. action.id, 150 * style.viewSize, 0) then
        settingsUI.listeningBinding = listening and nil or action.id
    end
    style.popStyleColor(conflicting)

    if listening then
        style.tooltip("Press the key to bind, or Escape to cancel.")
    elseif conflicting then
        style.tooltip(action.hint .. "\n\nThis key is bound to more than one action, both will trigger.")
    else
        style.tooltip(action.hint)
    end

    ImGui.SameLine()
    ImGui.Text(action.label)

    if not listening then return end

    -- Keep the key being recorded from also firing whatever hotkey it happens to be
    input.rebindActive = true

    if ImGui.IsKeyPressed(ImGuiKey.Escape, false) then
        settingsUI.listeningBinding = nil
        return
    end

    local captured = keys.capture()
    if captured then
        previewControls.setBinding(action.id, captured)
        settingsUI.listeningBinding = nil
    end
end

local function drawBindingsSection()
    if not ImGui.TreeNodeEx("Bindings", ImGuiTreeNodeFlags.SpanFullWidth) then
        settingsUI.listeningBinding = nil
        return
    end

    ImGui.Dummy(0, 4 * style.viewSize)
    style.sectionHeaderStart("Asset preview", "Keys used while hovering an entry in the \"Spawn New\" list.\nMoving the point of view stops the automatic turntable, stepping the appearance stops the automatic appearance cycle.\nThey are also listed in the bottom left corner of the preview itself.")

    local bindings = previewControls.getBindings()

    local usageCount = {}
    for _, action in ipairs(previewControls.actions) do
        local bound = bindings[action.id] or ""
        usageCount[bound] = (usageCount[bound] or 0) + 1
    end

    for _, action in ipairs(previewControls.actions) do
        drawBindingRow(action, bindings, usageCount)
    end

    ImGui.Dummy(0, 4 * style.viewSize)
    if ImGui.Button("Restore defaults##previewBindings") then
        previewControls.restoreDefaultBindings()
        settingsUI.listeningBinding = nil
    end
    style.tooltip(("Rebind everything to the defaults for the game's language, currently a %s keyboard."):format(previewControls.getKeyboardLayout():upper()))
    style.sectionHeaderEnd()

    ImGui.Dummy(0, 4 * style.viewSize)
    ImGui.TreePop()
end

local aboutRowLabels = { "Version", "Author", "Contributors" }

---Width of the label column of the About rows, so every value lines up.
---@return number
local function getAboutLabelWidth()
    local width = 0

    for _, label in ipairs(aboutRowLabels) do
        width = math.max(width, (ImGui.CalcTextSize(label)))
    end

    return width + ImGui.GetStyle().ItemSpacing.x * 2
end

---@param label string
---@param value string
---@param labelWidth number
---@param wrapped boolean? Wrap the value instead of letting it run past the window.
local function drawAboutRow(label, value, labelWidth, wrapped)
    local startX = ImGui.GetCursorPosX()

    style.mutedText(label)
    ImGui.SameLine(startX + labelWidth)

    if wrapped then
        ImGui.TextWrapped(value)
    else
        ImGui.Text(value)
    end
end

local function drawAboutSection()
    if not ImGui.TreeNodeEx("About", ImGuiTreeNodeFlags.SpanFullWidth) then
        return
    end

    ImGui.Dummy(0, 4 * style.viewSize)

    local labelWidth = getAboutLabelWidth()
    style.styledText(about.name, style.highlightColor)
    ImGui.Dummy(0, 4 * style.viewSize)

    drawAboutRow("Version", about.version, labelWidth)
    drawAboutRow("Author", about.author, labelWidth)
    drawAboutRow("Contributors", table.concat(about.contributors, ", "), labelWidth, true)

    ImGui.Dummy(0, 8 * style.viewSize)
    style.sectionHeaderStart("Thanks")
    style.styledTextWrapped(about.thanks, style.mutedColor)
    style.sectionHeaderEnd()

    ImGui.Dummy(0, 4 * style.viewSize)
    ImGui.TreePop()
end

local dependencyStateDisplay = {
    ok = { icon = IconGlyphs.CheckCircleOutline, label = "Installed" },
    outdated = { icon = IconGlyphs.AlertCircleOutline, label = "Outdated" },
    missing = { icon = IconGlyphs.CloseCircleOutline, label = "Not installed" },
    unknown = { icon = IconGlyphs.HelpCircleOutline, label = "Could not be detected" }
}

-- Same red the other "this is broken" markers use, e.g. the missing mesh warning on AI spots.
local dependencyErrorColor = 0xFF2525E5

---@param status aboutDependencyStatus
---@return number
local function getDependencyColor(status)
    if status.state == about.states.ok then
        return style.successColor
    end

    if status.state == about.states.outdated then
        return style.warnColor
    end

    -- A missing optional integration is a plain fact, only a missing requirement is an error.
    if status.state == about.states.missing and status.required then
        return dependencyErrorColor
    end

    return style.mutedColor
end

---@param status aboutDependencyStatus
---@return string
local function getDependencyStateText(status)
    local display = dependencyStateDisplay[status.state] or dependencyStateDisplay.unknown
    local text = display.label

    if status.state == about.states.ok then
        if status.detectedVersion then
            text = text .. " (" .. status.detectedVersion .. ")"
        end

        return text
    end

    if status.detectedVersion then
        text = text .. " (" .. status.detectedVersion .. ")"
    end

    if status.minVersion then
        text = text .. " - requires " .. status.minVersion
    end

    return text
end

---Tooltip for prose long enough that the plain one-line tooltip would run off screen.
---@param hovered boolean Hovered state captured right after the item was drawn.
---@param text string
local function drawWrappedTooltip(hovered, text)
    if not hovered then return end

    ImGui.BeginTooltip()
    ImGui.PushStyleColor(ImGuiCol.Text, style.regularColor)
    ImGui.PushTextWrapPos(ImGui.GetCursorPosX() + 340 * style.viewSize)
    ImGui.TextUnformatted(text)
    ImGui.PopTextWrapPos()
    ImGui.PopStyleColor()
    ImGui.EndTooltip()
end

---@param status aboutDependencyStatus
local function drawDependencyRow(status)
    local display = dependencyStateDisplay[status.state] or dependencyStateDisplay.unknown
    local color = getDependencyColor(status)

    ImGui.PushID(status.id)

    -- Grouped so the whole row, not just the name, answers to the hover.
    ImGui.BeginGroup()
    style.styledText(display.icon, color)
    ImGui.SameLine()
    ImGui.Text(status.name)
    ImGui.SameLine()
    style.styledText(getDependencyStateText(status), color)

    if status.state == about.states.unknown then
        style.tooltip("This one has no Lua side of its own, so World Builder cannot check it directly.")
    end
    ImGui.EndGroup()

    if status.satisfied then
        -- Nothing to act on here, so what it brings stays out of the way until asked for.
        drawWrappedTooltip(ImGui.IsItemHovered(), status.provides)
        ImGui.PopID()
        return
    end

    if status.url then
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.ContentCopy) then
            ImGui.SetClipboardText(status.url)
            ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Copied download link"))
        end
        style.pushButtonNoBG(false)
        style.tooltip("Copy download link:\n" .. status.url)
    end

    ImGui.Indent(20 * style.viewSize)
    style.styledTextWrapped(status.provides, style.mutedColor)
    ImGui.Unindent(20 * style.viewSize)

    ImGui.PopID()
end

---@param statuses aboutDependencyStatus[]
local function drawDependenciesSummary(statuses)
    local missingRequired = 0
    local missingOptional = 0

    for _, status in ipairs(statuses) do
        if not status.satisfied then
            if status.required then
                missingRequired = missingRequired + 1
            else
                missingOptional = missingOptional + 1
            end
        end
    end

    if missingRequired > 0 then
        style.styledTextWrapped(string.format("%d required %s missing or outdated.", missingRequired, missingRequired == 1 and "dependency is" or "dependencies are"), dependencyErrorColor)
    elseif missingOptional > 0 then
        style.styledTextWrapped("Everything required is installed, some optional integrations are not.", style.successColor)
    else
        style.styledTextWrapped("Everything is installed.", style.successColor)
    end
end

local function drawDependenciesSection()
    if not ImGui.TreeNodeEx("Dependencies", ImGuiTreeNodeFlags.SpanFullWidth) then
        return
    end

    ImGui.Dummy(0, 4 * style.viewSize)

    local statuses = about.getDependencies()
    local required = {}
    local optional = {}

    for _, status in ipairs(statuses) do
        table.insert(status.required and required or optional, status)
    end

    drawDependenciesSummary(statuses)

    ImGui.Dummy(0, 8 * style.viewSize)
    style.sectionHeaderStart("Required", "World Builder needs these to work, and refuses to start without most of them.")
    for _, status in ipairs(required) do
        drawDependencyRow(status)
    end
    style.sectionHeaderEnd()

    ImGui.Dummy(0, 8 * style.viewSize)
    style.sectionHeaderStart("Optional integrations", "Other mods World Builder makes use of when they are installed. Everything else keeps working without them.")
    for _, status in ipairs(optional) do
        drawDependencyRow(status)
    end
    style.sectionHeaderEnd()

    ImGui.Dummy(0, 4 * style.viewSize)
    ImGui.TreePop()
end

---@param spawner spawner
function settingsUI.draw(spawner)
    ImGui.PushItemWidth(120 * style.viewSize)

    if ImGui.TreeNodeEx("Spawning", ImGuiTreeNodeFlags.SpanFullWidth) then
        local pos, changed = ImGui.Combo("##spawnPos", settings.spawnPos - 1, { "At selected", "Screen center" }, 2)
        settings.spawnPos = pos + 1
        if changed then settings.save() end
        if settings.spawnPos == 1 then
            style.tooltip("Spawn the new object at the position of the selected object(s), if none are selected, it will spawn in front of the camera.")
        else
            style.tooltip("Spawn position is relative to the camera position and orientation.")
        end
        ImGui.SameLine()
        ImGui.Text("Spawn new objects")

        settings.spawnDist, changed = ImGui.InputFloat("Spawn distance from camera", settings.spawnDist, -9999, 9999, "%.1f")
        if changed then settings.save() end
        style.tooltip("Distance from the camera to spawn the object at, used for the fallback for \"At selected\", and always used for \"Screen center\"")

        settings.setLoadedGroupAsSpawnNew, changed = ImGui.Checkbox("Set group as target on load", settings.setLoadedGroupAsSpawnNew)
        if changed then settings.save() end
        style.tooltip("Set group as \"Target Group\" when loading it from the \"Saved\" tab")

        local speedPreset = math.max(1, math.min(#groupLoadSpeedOptions, settings.groupLoadSpeedPreset or 2))
        local selectedPreset, presetChanged = ImGui.Combo("Prefab/Saved group load speed", speedPreset - 1, groupLoadSpeedOptions, #groupLoadSpeedOptions)
        if presetChanged then
            settings.groupLoadSpeedPreset = selectedPreset + 1
            settings.save()
        end
        style.tooltip("Mostly noticeable on heavy groups with thousands of elements")

        settings.prefabPreviewMaxAssets, changed = ImGui.InputInt("Prefab preview max assets", math.floor(settings.prefabPreviewMaxAssets or 300), 10)
        if changed then
            settings.prefabPreviewMaxAssets = math.max(0, math.min(settings.prefabPreviewMaxAssets, 300))
            settings.save()
        end
        style.tooltip("When hovering a prefab favorite, spawn a rotating preview of it if it contains at most this many assets.\nSet to 0 to disable prefab previews. (max 300)")

        ImGui.Dummy(0, 4 * style.viewSize)
        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Editing", ImGuiTreeNodeFlags.SpanFullWidth) then
        style.mutedText("When duplicating a group, place the cloned group:")
        if ImGui.RadioButton("Inside the original group", settings.moveCloneToParent == 1) then
            settings.moveCloneToParent = 1
            settings.save()
        end
        style.tooltip("When cloning a group, place the newly created group inside the original one")

        ImGui.SameLine()

        if ImGui.RadioButton("At the same level as the original group", settings.moveCloneToParent == 2) then
            settings.moveCloneToParent = 2
            settings.save()
        end
        style.tooltip("When cloning a group, place the newly created group at the same level as the the one it was cloned from")
        
        ImGui.Dummy(0, 4 * style.viewSize)

        settings.draggingThreshold, changed = ImGui.InputFloat("Dragging Threshold", settings.draggingThreshold, 0, 100, "%.1f")
        if changed then
            style.initialize(true)
            settings.save()
        end
        style.tooltip("A threshold for all dragging operations, such as the ones in the scene hierarchy.")

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("TRANSFORM")
        settings.posSteps, changed = ImGui.InputFloat("Position controls step size", settings.posSteps, -9999, 9999, "%.4f")
        if changed then settings.save() end

        settings.rotSteps, changed = ImGui.InputFloat("Rotation controls step size", settings.rotSteps, -9999, 9999, "%.4f")
        if changed then settings.save() end

        settings.applyRotationWhenDropped, changed = ImGui.Checkbox("Apply Rotation When Dropped", settings.applyRotationWhenDropped)
        if changed then settings.save() end
        style.tooltip("Default state of the \"Apply Rotation When Dropped\" option in an element's General properties.\nWhen enabled, dropping an element onto a surface also aligns its rotation to that surface.\nThis only sets the default for newly created elements, each one can still be changed individually.")

        settings.rotationShiftClickStep, changed = field.advancedTrackedFloat(nil, "Quick Rotation Step", settings.rotationShiftClickStep, {
            step = 0.5,
            shiftStep = 5,
            min = 0,
            max = 360,
            format = "%.2f",
            shiftFormat = "%.2f",
            width = 120
        })
        if changed then settings.save() end
        style.tooltip("Amount added/subtracted when Shift+Left/Right clicking Roll/Pitch/Yaw fields.")

        settings.precisionMultiplier, changed = ImGui.InputFloat("Precision multiplier", settings.precisionMultiplier, 0, 10, "x%.3f")
        if changed then settings.save() end
        style.tooltip("When holding SHIFT while dragging transform values, the step size will be multiplied by this value")

        settings.coarsePrecisionMultiplier, changed = ImGui.InputFloat("Coarse precision multiplier", settings.coarsePrecisionMultiplier, 0, 100, "x%.3f")
        if changed then settings.save() end
        style.tooltip("When holding CTRL while dragging transform values, the step size will be multiplied by this value")
        style.sectionHeaderEnd(true)

        ImGui.Dummy(0, 4 * style.viewSize)
        ImGui.TreePop()
    end

    drawDefaultsSection()
    drawBindingsSection()

    if ImGui.TreeNodeEx("Editor Mode", ImGuiTreeNodeFlags.SpanFullWidth) then
        style.pushGreyedOut(not spawner.editor.active)
        local resetCameraLabel, resetCameraHiddenText = style.resolveActionLabel(IconGlyphs.CameraRetakeOutline, "Reset camera position", "resetCameraPosition", nil, true)
        if ImGui.Button(resetCameraLabel) and spawner.editor.active then
            if spawner.editor.camera and spawner.editor.camera.resetPosition and spawner.editor.camera.resetPosition() then
                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Camera position reset"))
            end
        end
        style.popGreyedOut(not spawner.editor.active)
        if resetCameraHiddenText then
            style.tooltipActionLabel(resetCameraHiddenText, resetCameraHiddenText .. "\nMove the 3D-Editor camera back to your player position from before entering editor mode.")
        else
            style.tooltip("Move the 3D-Editor camera back to your player position from before entering editor mode.")
        end

        settings.cameraMovementSpeed, changed = ImGui.InputFloat("Camera Movement Speed", settings.cameraMovementSpeed, 0, 10, "%.2f")
        if changed then settings.save() end

        settings.cameraRotateSpeed, changed = ImGui.InputFloat("Camera Rotation Speed", settings.cameraRotateSpeed, 0, 10, "%.2f")
        if changed then settings.save() end

        settings.cameraZoomSpeed, changed = ImGui.InputFloat("Camera Zoom Speed", settings.cameraZoomSpeed, 0, 10, "%.2f")
        if changed then settings.save() end

        ImGui.Dummy(0, 4 * style.viewSize)
        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Visualizers", ImGuiTreeNodeFlags.SpanFullWidth) then
        settings.groupWireframeEnabled, changed = ImGui.Checkbox("Show Group Wireframe", settings.groupWireframeEnabled)
        if changed then settings.save() end
        style.tooltip("Only visible in 3D-Editor mode, show boundaries and origin of selected group with a colored outline.")

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("Positioning Helpers")
        settings.gizmoOnHover, changed = ImGui.Checkbox("Show arrows when hovering an element", settings.gizmoOnHover)
        if changed then
            settings.save()
            refreshSelectedVisualizers(spawner)
        end

        settings.gizmoOnSelected, changed = ImGui.Checkbox("Show arrows when element is selected", settings.gizmoOnSelected)
        if changed then
            settings.save()
            refreshSelectedVisualizers(spawner)
        end

        settings.arrowScaleWithDistance, changed = ImGui.Checkbox("Scale arrows with camera distance", settings.arrowScaleWithDistance)
        if changed then
            settings.save()
            refreshSelectedVisualizers(spawner)
        end
        style.tooltip("While in editor mode, keep the positioning arrows at a roughly constant on-screen size, growing them the further the camera is so they stay visible when far away. Outside editor mode the arrows always use their base size.")

        ImGui.SetNextItemWidth(150 * style.viewSize)
        settings.arrowSizeMultiplier, changed = ImGui.SliderFloat("Arrow size multiplier", settings.arrowSizeMultiplier, 0.25, 4.0, "%.2f")
        if changed then
            settings.arrowSizeMultiplier = math.max(0.25, math.min(settings.arrowSizeMultiplier, 4.0))
            settings.save()
            refreshSelectedVisualizers(spawner)
        end
        style.tooltip("Overall size of the positioning arrows. Increase this to make them easier to see, e.g. in bright daylight.")

        settings.outlineSelected, changed = ImGui.Checkbox("Show outline when element is selected", settings.outlineSelected)
        if changed then
            settings.save()
            refreshSelectedVisualizers(spawner)
        end

        settings.outlineColor, changed = ImGui.Combo("Outline color", settings.outlineColor, outlineColors, #outlineColors)
        if changed then
            settings.save()
            refreshSelectedVisualizers(spawner)
        end
        style.sectionHeaderEnd()

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("Visualization Helpers")
        drawSpawnNewVisualizerDefaultSelector(spawner)
        style.sectionHeaderEnd()

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("AI Spot Preview")
        settings.defaultAISpotNPC, changed = ImGui.InputTextWithHint("Default AI Spot NPC Record", "Character.", settings.defaultAISpotNPC, 128)
        if changed then
            settings.defaultAISpotNPC = utils.stripNonASCII(settings.defaultAISpotNPC)
            settings.save()
        end

        settings.defaultAISpotAppearance, changed = ImGui.InputTextWithHint("Default AI Spot NPC Appearance", "default", settings.defaultAISpotAppearance, 128)
        if changed then
            settings.defaultAISpotAppearance = utils.sanitizeText(settings.defaultAISpotAppearance or "default", "default")
            settings.save()
        end

        settings.defaultAISpotSpeed, changed = ImGui.InputFloat("Default AI Spot Animation Speed", settings.defaultAISpotSpeed, 0, 25, "%.1f")
        if changed then settings.save() end
        style.sectionHeaderEnd()

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("Spline Preview")
        settings.defaultSplineCurveQuality, changed = ImGui.InputInt("Default Curve Quality", settings.defaultSplineCurveQuality, 1, 1)
        if changed then
            settings.defaultSplineCurveQuality = math.max(8, math.min(24, math.floor(settings.defaultSplineCurveQuality)))
            settings.save()
        end
        style.tooltip("Default number of samples used for spline curve preview (8-24).")
        style.sectionHeaderEnd()

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("Colliders")
        settings.colliderColor, changed = ImGui.Combo("Collider color", settings.colliderColor, colliderColors, #colliderColors)
        if changed then settings.save() end
        style.sectionHeaderEnd()

        ImGui.Dummy(0, 4 * style.viewSize)
        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Appearance", ImGuiTreeNodeFlags.SpanFullWidth) then
        local index, indexChanged = ImGui.Combo("Main Window Name", math.max(0, utils.indexValue(windowNames, settings.mainWindowName) - 1), windowNames, #windowNames)
        if indexChanged then
            settings.mainWindowName = windowNames[index + 1]
            spawner.baseUI.restoreWindowPosition = true
            spawner.baseUI.loadTabSize = true
            settings.save()
        end

        local colorPickerStyle = math.max(1, math.min(#colorPickerStyles, tonumber(settings.colorPickerStyle) or 2))
        local colorPickerStyleIndex, colorPickerStyleChanged = ImGui.Combo("Color Picker style", colorPickerStyle - 1, colorPickerStyles, #colorPickerStyles)
        if colorPickerStyleChanged then
            settings.colorPickerStyle = colorPickerStyleIndex + 1
            settings.save()
        end
        style.tooltip("Global style used by all color editors.")

        local wireframeColorStyle = math.max(1, math.min(#wireframeColorStyles, settings.wireframeColorStyle or 1))
        local wireframeColorStyleIndex, wireframeColorStyleChanged = ImGui.Combo("Wireframe color style", wireframeColorStyle - 1, wireframeColorStyles, #wireframeColorStyles)
        if wireframeColorStyleChanged then
            settings.wireframeColorStyle = wireframeColorStyleIndex + 1
            settings.save()
        end
        drawWireframeColorStyleTooltip()

        local speedUnit = math.max(1, math.min(#speedUnits, tonumber(settings.speedUnit) or 1))
        local speedUnitIndex, speedUnitChanged = ImGui.Combo("Speed unit", speedUnit - 1, speedUnits, #speedUnits)
        if speedUnitChanged then
            settings.speedUnit = speedUnitIndex + 1
            settings.save()
        end
        style.tooltip("Unit used to display speeds (for example on Speed Spline nodes).")

        local stickyRowsEnabled, stickyRowsChanged = ImGui.Checkbox("Sticky Hierarchy Rows", settings.stickyRowsEnabled)
        if stickyRowsChanged then
            settings.stickyRowsEnabled = stickyRowsEnabled
            settings.save()
        end
        style.tooltip("Pin open parent groups to the top of the Spawned hierarchy while scrolling through their children.")

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("Balance between icons and text")
        local actionLabelDisplayMode = style.normalizeActionLabelMode(settings.actionLabelDisplayMode)
        local actionLabelModeChanged = false
        for index, option in ipairs(actionLabelDisplayModeOptions) do
            if index > 1 then
                ImGui.SameLine()
            end

            local buttonId = "##actionLabelDisplayMode" .. tostring(option.value)
            if style.switchTabButton(option.label .. buttonId, actionLabelDisplayMode == option.value, nil, 0) then
                if actionLabelDisplayMode ~= option.value then
                    actionLabelDisplayMode = option.value
                    actionLabelModeChanged = true
                end
            end
        end

        if actionLabelModeChanged then
            settings.actionLabelDisplayMode = actionLabelDisplayMode
            settings.save()
        end
        style.sectionHeaderEnd()

        ImGui.Dummy(0, 4 * style.viewSize)
        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Misc", ImGuiTreeNodeFlags.SpanFullWidth) then
        settings.deleteConfirm, changed = ImGui.Checkbox("Show confirm to delete saved group popup", settings.deleteConfirm)
        if changed then settings.save() end

        local showTemplateDeleteConfirm = not settings.skipTemplateDeleteConfirm
        showTemplateDeleteConfirm, changed = ImGui.Checkbox("Show confirm to delete export template popup", showTemplateDeleteConfirm)
        if changed then
            settings.skipTemplateDeleteConfirm = not showTemplateDeleteConfirm
            settings.save()
        end

        local showConvertConfirm = not settings.skipLossyConversionWarning
        showConvertConfirm, changed = ImGui.Checkbox("Show confirm to convert popup", showConvertConfirm)
        if changed then
            settings.skipLossyConversionWarning = not showConvertConfirm
            settings.save()
        end

        settings.despawnOnReload, changed = ImGui.Checkbox("Despawn everything on \"Reload all mods\"", settings.despawnOnReload)
        if changed then settings.save() end

        settings.ignoreHiddenDuringExport, changed = ImGui.Checkbox("Ignore hidden elements during export", settings.ignoreHiddenDuringExport)
        if changed then settings.save() end

        ImGui.TreePop()
    end

    rht.drawSettings()
    
    if ImGui.TreeNodeEx("Debug", ImGuiTreeNodeFlags.SpanFullWidth) then
        if ImGui.TreeNodeEx("Cache Exclusions", ImGuiTreeNodeFlags.SpanFullWidth) then
            style.tooltip("Resource paths or glob patterns to exclude from cache reads. Use exact paths, * for any sequence, and ? for a single character.")

            local x, _ = ImGui.GetContentRegionAvail()
            if ImGui.BeginChild("##list", -1, 115 * style.viewSize) then
                x = x - (30 * style.viewSize) - (ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0)
                for key, exclusion in pairs(settings.cacheExclusions) do
                    ImGui.PushID(key)
                    ImGui.SetNextItemWidth(x)
                    settings.cacheExclusions[key], changed = ImGui.InputTextWithHint("##exclusion", "base\\*.ent", exclusion, 128)
                    if changed then
                        settings.save()
                    end
                    ImGui.SameLine()
                    if ImGui.Button(IconGlyphs.Delete) then
                        table.remove(settings.cacheExclusions, key)
                        settings.save()
                    end
                    ImGui.PopID()
                end

                if ImGui.Button("+") then
                    table.insert(settings.cacheExclusions, "")
                    settings.save()
                end

                ImGui.EndChild()
            end

            ImGui.TreePop()
        else
            style.tooltip("Resource paths or glob patterns to exclude from cache reads. Use exact paths, * for any sequence, and ? for a single character.")
        end

        if ImGui.Button("Clear cache") then
            cache.reset()
            ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Cleared cache"))
        end
        style.tooltip("Clears the cache")

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("PERFORMANCES")
        settings.spawnedUIPerfEnabled, changed = ImGui.Checkbox("Enable Spawned UI profiler", settings.spawnedUIPerfEnabled)
        if changed then
            settings.save()

            if not settings.spawnedUIPerfEnabled then
                settings.spawnedUIPerfShowPanel = false
                settings.save()
            end
        end
        style.tooltip("Track timing for Spawned UI stages such as cache rebuild, hierarchy draw, and properties draw.")

        ImGui.BeginDisabled(not settings.spawnedUIPerfEnabled)
        settings.spawnedUIPerfShowPanel, changed = ImGui.Checkbox("Show Spawned UI profiler window", settings.spawnedUIPerfShowPanel)
        if changed then settings.save() end
        ImGui.EndDisabled()

        ImGui.BeginDisabled(not settings.spawnedUIPerfEnabled)
        if ImGui.Button("Reset Spawned UI profiler metrics") then
            perf.reset()
        end
        ImGui.EndDisabled()
        style.sectionHeaderEnd()

        ImGui.Dummy(0, 4 * style.viewSize)
        ImGui.TreePop()
    end

    drawAboutSection()
    drawDependenciesSection()

    ImGui.PopItemWidth()
end

return settingsUI
