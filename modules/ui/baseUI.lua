local CodewareVersion = "1.18.0"
local ArchiveXLVersion = "1.26.0"
local ModVersion = "a.1.3.3"
local ignoreRequirements = false

local settings = require("modules/utils/settings")
local gameUtils = require("modules/utils/gameUtils")
local style = require("modules/ui/style")
local editor = require("modules/utils/editor/editor")
local input = require("modules/utils/input")
local groupLoadManager = require("modules/utils/pipeline/groupLoadManager")
local groupAMMImportManager = require("modules/utils/pipeline/groupAMMImportManager")
local history = require("modules/utils/history")

---@class baseUI
baseUI = {
    spawnUI = require("modules/ui/spawnUI"),
    spawnedUI = require("modules/ui/spawnedUI"),
    savedUI = require("modules/ui/savedUI"),
    exportUI = require("modules/ui/exportUI"),
    previewTimeline = require("modules/ui/previewTimeline"),
    settingsUI = require("modules/ui/settingsUI"),
    activeTab = 1,
    requestedTab = nil,
    loadTabSize = true,
    loadWindowSize = nil,
    mainWindowPosition = { 0, 0 },
    restoreWindowPosition = false,
    requirementsIssues = {}
}

local menuButtonHovered = false
local dockButtonHovered = false

---Draw the mod version on the right side of the native ImGui title bar.
---The centered title keeps priority; version text is hidden if it would overlap.
---@param titleText string
---@param versionText string
local function drawRightAlignedTitleBarVersion(titleText, versionText)
    if titleText == nil or titleText == "" or versionText == nil or versionText == "" then
        return
    end

    local drawList = ImGui.GetWindowDrawList()
    if not drawList then
        return
    end

    local windowPosX, windowPosY = ImGui.GetWindowPos()
    local windowWidth = ImGui.GetWindowWidth()
    local titleBarHeight = ImGui.GetFrameHeight()
    local styleData = ImGui.GetStyle()

    local titleWidth, _ = ImGui.CalcTextSize(titleText)
    local versionWidth, versionHeight = ImGui.CalcTextSize(versionText)

    local centerX = windowPosX + windowWidth * 0.5
    local titleRight = centerX + titleWidth * 0.5
    local versionRight = windowPosX + windowWidth - styleData.WindowPadding.x
    local versionLeft = versionRight - versionWidth
    local minimumGap = styleData.ItemSpacing.x

    if versionLeft <= titleRight + minimumGap then
        return
    end

    local versionY = windowPosY + (titleBarHeight - versionHeight) * 0.5

    -- Window draw list can be clipped to the content region; temporarily include title bar.
    ImGui.PushClipRect(windowPosX, windowPosY, windowPosX + windowWidth, windowPosY + titleBarHeight, false)
    ImGui.ImDrawListAddText(drawList, versionLeft, versionY, style.mutedColor, versionText)
    ImGui.PopClipRect()
end

local tabs = {
    {
        id = "spawn",
        name = "Spawn New",
        icon = IconGlyphs.PlusBoxOutline,
        flags = ImGuiWindowFlags.None,
        defaultSize = { 750, 1000 },
        draw = function ()
            baseUI.spawnedUI.ensureCache()
            baseUI.spawnUI.draw()
        end
    },
    {
        id = "spawned",
        name = "Spawned",
        icon = IconGlyphs.FileTree,
        flags = ImGuiWindowFlags.None,
        defaultSize = { 600, 1200 },
        draw = baseUI.spawnedUI.draw
    },
    {
        id = "saved",
        name = "Saved",
        icon = IconGlyphs.ContentSaveCogOutline,
        flags = ImGuiWindowFlags.None,
        defaultSize = { 600, 700 },
        draw = baseUI.savedUI.draw
    },
    {
        id = "export",
        name = "Export",
        icon = IconGlyphs.Export,
        flags = ImGuiWindowFlags.None,
        defaultSize = { 600, 700 },
        draw = baseUI.exportUI.draw
    },
    {
        id = "settings",
        name = "Settings",
        icon = IconGlyphs.CogOutline,
        flags = ImGuiWindowFlags.None,
        defaultSize = { 600, 1200 },
        draw = baseUI.settingsUI.draw
    }
}

---@param id string
---@return boolean
function baseUI.selectTab(id)
    for key, tab in ipairs(tabs) do
        if tab.id == id then
            baseUI.requestedTab = key
            return true
        end
    end

    return false
end

local MAX_WINDOW_WIDTH = 5000
local MAX_WINDOW_HEIGHT = 3500

local function clampWindowDimension(value, maxValue)
    value = tonumber(value)
    if value == nil or value <= 0 then
        return nil
    end

    return math.min(value, maxValue)
end

local function getMainWindowSize()
    local width = clampWindowDimension(settings.mainWindowWidth, MAX_WINDOW_WIDTH) or tabs[1].defaultSize[1]
    local height = clampWindowDimension(settings.mainWindowHeight, MAX_WINDOW_HEIGHT) or tabs[1].defaultSize[2]

    return width, height
end

local function saveMainWindowSize(width, height)
    local newWidth = clampWindowDimension(width, MAX_WINDOW_WIDTH) or tabs[1].defaultSize[1]
    local newHeight = clampWindowDimension(height, MAX_WINDOW_HEIGHT) or tabs[1].defaultSize[2]
    local changed = false

    if settings.mainWindowWidth ~= newWidth then
        settings.mainWindowWidth = newWidth
        changed = true
    end

    if settings.mainWindowHeight ~= newHeight then
        settings.mainWindowHeight = newHeight
        changed = true
    end

    if changed then
        settings.save()
    end
end

---@param tab {name: string, icon: string?}
---@param stableId string?
---@param mode integer?
---@param includeHiddenText boolean?
---@return string
---@return string?
local function getTabLabel(tab, stableId, mode, includeHiddenText)
    local resolvedId = stableId or ("tabLabel:" .. tostring(tab.id or tab.name))
    return style.resolveActionLabel(tab.icon, tab.name, resolvedId, mode, includeHiddenText)
end

local function isOnlyTab(id)
    for tid, tab in pairs(settings.windowStates) do
        if not tab and tid ~= id then
            return false
        end
    end

    return true
end

local function drawMenuButton()
    ImGui.SameLine()

    local dockLeftIcon = IconGlyphs.DockLeft or "<"
    local dockRightIcon = IconGlyphs.DockRight or ">"
    local dockIcon = settings.editorDockLeft and dockRightIcon or dockLeftIcon
    local dockIconWidth = 0
    local pauseActive = gameUtils.isPauseActive()
    local pauseIcon = pauseActive and (IconGlyphs.Play or ">") or (IconGlyphs.Pause or "||")
    local pauseIconWidth, _ = ImGui.CalcTextSize(pauseIcon)
    local pauseButtonWidth = pauseIconWidth + ImGui.GetStyle().FramePadding.x * 2
    if editor.active then
        dockIconWidth, _ = ImGui.CalcTextSize(dockIcon)
    end
    local iconWidth, _ = ImGui.CalcTextSize(IconGlyphs.DotsHorizontal)
    local iconY = (editor.active and 0 or ImGui.GetFrameHeight()) + ImGui.GetStyle().WindowPadding.y
    local iconX = ImGui.GetWindowWidth() - iconWidth - ImGui.GetStyle().WindowPadding.x - 5
    local pauseX = iconX - ImGui.GetStyle().ItemSpacing.x - pauseButtonWidth

    if editor.active then
        local dockX = pauseX - ImGui.GetStyle().ItemSpacing.x - dockIconWidth
        ImGui.SetCursorPos(dockX, iconY - 4)
        style.pushStyleColor(dockButtonHovered, ImGuiCol.Text, style.mutedColor)
        ImGui.SetItemAllowOverlap()
        ImGui.Text(dockIcon)
        style.popStyleColor(dockButtonHovered)
        dockButtonHovered = ImGui.IsItemHovered()
        if ImGui.IsItemClicked(ImGuiMouseButton.Left) then
            settings.editorDockLeft = not settings.editorDockLeft
            settings.save()
        end
        style.tooltip(settings.editorDockLeft and "Dock panel to the right" or "Dock panel to the left")
    end

    ImGui.SetCursorPos(pauseX, iconY - 4)
    local changed
    pauseActive, changed = style.toggleButton(pauseIcon, pauseActive)
    if changed then
        gameUtils.setPause(pauseActive)
    end
    style.tooltip(pauseActive and "Resume game time" or "Pause game time")

    ImGui.SetCursorPos(iconX, iconY)

    style.pushStyleColor(menuButtonHovered, ImGuiCol.Text, style.mutedColor)
    ImGui.SetItemAllowOverlap()
    ImGui.Text(IconGlyphs.DotsHorizontal)
    style.popStyleColor(menuButtonHovered)
    menuButtonHovered = ImGui.IsItemHovered()

    if ImGui.BeginPopupContextItem("##windowMenu", ImGuiPopupFlags.MouseButtonLeft) then
        style.styledText("Separated Tabs:", style.mutedColor, 0.85)

        for _, tab in pairs(tabs) do
            local menuLabel, hiddenMenuText = getTabLabel(tab, "windowMenuTab:" .. tostring(tab.id), nil, true)
            local _, clicked = ImGui.MenuItem(menuLabel, '', settings.windowStates[tab.id])
            style.tooltipActionLabel(hiddenMenuText)
            if clicked and not isOnlyTab(tab.id) then
                settings.windowStates[tab.id] = not settings.windowStates[tab.id]
                settings.save()

                if settings.windowStates[tab.id] then
                    baseUI.loadWindowSize = tab.id
                end
            end
        end

        ImGui.EndPopup()
    end
end

function baseUI.init()
    if baseUI.previewTimeline and baseUI.previewTimeline.bindSpawnedUI then
        baseUI.previewTimeline.bindSpawnedUI(baseUI.spawnedUI)
    end

    if ignoreRequirements then return end

    if not ArchiveXL then
        table.insert(baseUI.requirementsIssues, "ArchiveXL is not installed")
    elseif not ArchiveXL.Require(ArchiveXLVersion) then
        table.insert(baseUI.requirementsIssues, "ArchiveXL version is outdated, please update to " .. ArchiveXLVersion)
    end

    if not Codeware then
        table.insert(baseUI.requirementsIssues, "Codeware is not installed")
    elseif not Codeware.Require(CodewareVersion) then
        table.insert(baseUI.requirementsIssues, "Codeware version is outdated, please update to " .. CodewareVersion)
    end

    if not Game.GetScriptableServiceContainer():GetService("EntityBuilder") then
        table.insert(baseUI.requirementsIssues, "Redscript part of the mod is not installed")
    end
end

function baseUI.draw(spawner)
    if not editor.camera then return end

    if #baseUI.requirementsIssues > 0 then
        if ImGui.Begin(string.format("%s Error", settings.mainWindowName .. " " .. ModVersion), ImGuiWindowFlags.AlwaysAutoResize) then
            style.mutedText(string.format("The following issues are preventing %s from running:", settings.mainWindowName))

            for _, issue in pairs(baseUI.requirementsIssues) do
                ImGui.Text(issue)
            end

            ImGui.End()
        end
        return
    end

    input.resetContext()
    if baseUI.spawnedUI and baseUI.spawnedUI.resetHoveredEntries then
        baseUI.spawnedUI.resetHoveredEntries()
    end
    history.update()
    local screenWidth, screenHeight = GetDisplayResolution()
    local editorActive = editor.active

    if baseUI.loadTabSize and not editorActive then
        local width, height = getMainWindowSize()
        ImGui.SetNextWindowSize(width, height)
        baseUI.loadTabSize = false
    end
    if editorActive then
        ImGui.SetNextWindowSizeConstraints(screenWidth / 8, screenHeight, screenWidth / 2, screenHeight)
        if settings.editorDockLeft then
            ImGui.SetNextWindowPos(0, 0, ImGuiCond.Always, 0, 0)
        else
            ImGui.SetNextWindowPos(screenWidth, 0, ImGuiCond.Always, 1, 0)
        end
        if baseUI.loadTabSize then
            if settings.editorWidth == 0 then
                local width = getMainWindowSize()
                settings.editorWidth = width
            end
            ImGui.SetNextWindowSize(settings.editorWidth, screenHeight)
        end
        baseUI.loadTabSize = false
    end
    if baseUI.restoreWindowPosition then
        ImGui.SetNextWindowPos(baseUI.mainWindowPosition[1], baseUI.mainWindowPosition[2], ImGuiCond.Always, 0, 0)
        baseUI.restoreWindowPosition = false
    end

    style.pushStyleColor(editorActive, ImGuiCol.WindowBg, 0, 0, 0, 1)
    style.pushStyleVar(editorActive, ImGuiStyleVar.WindowRounding, 0)
    style.pushStyleVar(not editorActive, ImGuiStyleVar.WindowTitleAlign, 0.5, 0.5)

    local flags = tabs[baseUI.activeTab].flags
    if editorActive then
        flags = flags + ImGuiWindowFlags.NoCollapse + ImGuiWindowFlags.NoTitleBar
    end

    if ImGui.Begin(settings.mainWindowName, flags) then
        if not editorActive then
            drawRightAlignedTitleBarVersion(settings.mainWindowName, ModVersion)
        end

        input.updateContext("main")
        groupLoadManager.drawToasts()
        groupAMMImportManager.drawToasts()

        if not editorActive then
            baseUI.mainWindowPosition = { ImGui.GetWindowPos() }
        end

        local x, y = ImGui.GetWindowSize()
        if not editorActive then
            local savedWidth, savedHeight = getMainWindowSize()
            if x ~= savedWidth or y ~= savedHeight then
                saveMainWindowSize(x, y)
            end
        end
        if editorActive and x ~= settings.editorWidth then
            settings.editorWidth = x
            settings.save()
        end

        local xOffset = (settings.editorDockLeft and 1 or -1) * (x / screenWidth)
        editor.camera.updateXOffset(xOffset)

        if ImGui.BeginTabBar("Tabbar", ImGuiTabItemFlags.NoTooltip) then
            for key, tab in ipairs(tabs) do
                if settings.windowStates[tab.id] == nil then
                    settings.windowStates[tab.id] = false
                    settings.save()
                end

                if not settings.windowStates[tab.id] then
                    local tabLabel, tabHiddenText = getTabLabel(tab, "mainTab:" .. tostring(tab.id), nil, true)
                    local tabItemFlags = ImGuiTabItemFlags.None or 0
                    if baseUI.requestedTab == key then
                        tabItemFlags = tabItemFlags + (ImGuiTabItemFlags.SetSelected or 0)
                        baseUI.requestedTab = nil
                    end

                    if ImGui.BeginTabItem(tabLabel, tabItemFlags) then
                        style.tooltipActionLabel(tabHiddenText)
                        if baseUI.activeTab ~= key then
                            baseUI.activeTab = key
                            baseUI.loadTabSize = true
                        end
                        ImGui.Spacing()
                        tab.draw(spawner)
                        ImGui.EndTabItem()
                    else
                        style.tooltipActionLabel(tabHiddenText)
                    end
                else
                    local tabLabel = getTabLabel(tab, "mainTab:" .. tostring(tab.id))
                    ImGui.SetTabItemClosed(tabLabel)
                end
            end
            ImGui.EndTabBar()
        end

        drawMenuButton()

        ImGui.End()
    end

    style.popStyleVar(not editorActive)
    style.popStyleColor(editorActive)
    style.popStyleVar(editorActive)

    for key, tab in pairs(tabs) do
        if settings.windowStates[tab.id] then
            if baseUI.requestedTab == key then
                ImGui.SetNextWindowFocus()
                baseUI.requestedTab = nil
            end

            if baseUI.loadWindowSize == tab.id then
                local width, height = getMainWindowSize()
                ImGui.SetNextWindowSize(width, height)
                baseUI.loadWindowSize = nil
            end

            local detachedTabLabel = getTabLabel(tab, "detachedTab:" .. tostring(tab.id))
            settings.windowStates[tab.id] = ImGui.Begin(detachedTabLabel, true, tabs[key].flags)
            input.updateContext("main")

            if not settings.windowStates[tab.id] then
                settings.save()
            end
            tab.draw(spawner)

            if settings.windowStates[tab.id] then
                ImGui.End()
            end
        end
    end

    baseUI.spawnUI.drawPopup()
    if baseUI.previewTimeline and baseUI.previewTimeline.drawWindow then
        baseUI.previewTimeline.drawWindow()
    end
    if baseUI.spawnedUI and baseUI.spawnedUI.drawPinnedHierarchyWindow then
        baseUI.spawnedUI.drawPinnedHierarchyWindow()
    end
    if baseUI.spawnedUI and baseUI.spawnedUI.finalizeFrame then
        baseUI.spawnedUI.finalizeFrame()
    end

    input.context.viewport.hovered = not input.context.main.hovered
    input.context.viewport.focused = not input.context.main.focused
end

return baseUI
