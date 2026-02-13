local CodewareVersion = "1.16.0"
local ArchiveXLVersion = "1.23.0"
local ModVersion = "a.1.0.9"
local ignoreRequirements = false

local settings = require("modules/utils/settings")
local style = require("modules/ui/style")
local editor = require("modules/utils/editor/editor")
local input = require("modules/utils/input")

---@class baseUI
baseUI = {
    spawnUI = require("modules/ui/spawnUI"),
    spawnedUI = require("modules/ui/spawnedUI"),
    savedUI = require("modules/ui/savedUI"),
    exportUI = require("modules/ui/exportUI"),
    settingsUI = require("modules/ui/settingsUI"),
    activeTab = 1,
    loadTabSize = true,
    loadWindowSize = nil,
    mainWindowPosition = { 0, 0 },
    restoreWindowPosition = false,
    requirementsIssues = {}
}

local menuButtonHovered = false
local dockButtonHovered = false

local tabs = {
    {
        id = "spawn",
        name = "Spawn New",
        icon = IconGlyphs.PlusBoxOutline,
        flags = ImGuiWindowFlags.None,
        defaultSize = { 750, 1000 },
        draw = function ()
            baseUI.spawnedUI.cachePaths()
            baseUI.spawnUI.draw()
        end
    },
    {
        id = "spawned",
        name = "Spawned",
        icon = IconGlyphs.FormatListBulletedType,
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
        flags = ImGuiWindowFlags.AlwaysAutoResize,
        defaultSize = { 600, 1200 },
        draw = baseUI.settingsUI.draw
    }
}

---@param tab {name: string, icon: string?}
---@return string
local function getTabLabel(tab)
    if tab.icon and tab.icon ~= "" then
        return tab.icon .. " " .. tab.name
    end
    return tab.name
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
    if editor.active then
        dockIconWidth, _ = ImGui.CalcTextSize(dockIcon)
    end
    local iconWidth, _ = ImGui.CalcTextSize(IconGlyphs.DotsHorizontal)
    local iconY = (editor.active and 0 or ImGui.GetFrameHeight()) + ImGui.GetStyle().WindowPadding.y
    local iconX = ImGui.GetWindowWidth() - iconWidth - ImGui.GetStyle().WindowPadding.x - 5

    if editor.active then
        local dockX = iconX - ImGui.GetStyle().ItemSpacing.x - dockIconWidth
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

    ImGui.SetCursorPos(iconX, iconY)

    style.pushStyleColor(menuButtonHovered, ImGuiCol.Text, style.mutedColor)
    ImGui.SetItemAllowOverlap()
    ImGui.Text(IconGlyphs.DotsHorizontal)
    style.popStyleColor(menuButtonHovered)
    menuButtonHovered = ImGui.IsItemHovered()

    if ImGui.BeginPopupContextItem("##windowMenu", ImGuiPopupFlags.MouseButtonLeft) then
        style.styledText("Separated Tabs:", style.mutedColor, 0.85)

        for _, tab in pairs(tabs) do
            local _, clicked = ImGui.MenuItem(getTabLabel(tab), '', settings.windowStates[tab.id])
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
    for _, tab in pairs(tabs) do
        if settings.tabSizes[tab.id] == nil then
            settings.tabSizes[tab.id] = tab.defaultSize
            settings.save()
        end
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
    local screenWidth, screenHeight = GetDisplayResolution()
    local editorActive = editor.active

    if baseUI.loadTabSize and not editorActive then
        ImGui.SetNextWindowSize(settings.tabSizes[tabs[baseUI.activeTab].id][1], settings.tabSizes[tabs[baseUI.activeTab].id][2])
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
                settings.editorWidth = settings.tabSizes.spawned[1]
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

    local flags = tabs[baseUI.activeTab].flags
    if editorActive then
        flags = flags + ImGuiWindowFlags.NoCollapse + ImGuiWindowFlags.NoTitleBar
    end

    if ImGui.Begin(settings.mainWindowName .. " " .. ModVersion, flags) then
        input.updateContext("main")

        if not editorActive then
            baseUI.mainWindowPosition = { ImGui.GetWindowPos() }
        end

        local x, y = ImGui.GetWindowSize()
        if not editorActive and (x ~= settings.tabSizes[tabs[baseUI.activeTab].id][1] or y ~= settings.tabSizes[tabs[baseUI.activeTab].id][2]) then
            settings.tabSizes[tabs[baseUI.activeTab].id] = { math.min(x, 5000), math.min(y, 3500) }
            settings.save()
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
                    if ImGui.BeginTabItem(getTabLabel(tab)) then
                        if baseUI.activeTab ~= key then
                            baseUI.activeTab = key
                            baseUI.loadTabSize = true
                        end
                        ImGui.Spacing()
                        tab.draw(spawner)
                        ImGui.EndTabItem()
                    end
                else
                    ImGui.SetTabItemClosed(getTabLabel(tab))
                end
            end
            ImGui.EndTabBar()
        end

        drawMenuButton()

        ImGui.End()
    end

    style.popStyleColor(editorActive)
    style.popStyleVar(editorActive)

    for key, tab in pairs(tabs) do
        if settings.windowStates[tab.id] then
            if baseUI.loadWindowSize == tab.id then
                ImGui.SetNextWindowSize(settings.tabSizes[tab.id][1], settings.tabSizes[tab.id][2])
                baseUI.loadWindowSize = nil
            end

            settings.windowStates[tab.id] = ImGui.Begin(getTabLabel(tab), true, tabs[key].flags)
            input.updateContext("main")

            local x, y = ImGui.GetWindowSize()
            if x ~= settings.tabSizes[tab.id][1] or y ~= settings.tabSizes[tab.id][2] then
                settings.tabSizes[tab.id] = { x, y }
                settings.save()
            end

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

    input.context.viewport.hovered = not input.context.main.hovered
    input.context.viewport.focused = not input.context.main.focused
end

return baseUI
