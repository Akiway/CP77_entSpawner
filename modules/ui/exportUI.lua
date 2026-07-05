local config = require("modules/utils/config")
local utils = require("modules/utils/utils")
local style = require("modules/ui/style")
local settings = require("modules/utils/settings")
local field = require("modules/utils/field")
local projectedWireframe = require("modules/utils/editor/projectedWireframe")
local groupExportManager = require("modules/utils/pipeline/groupExportManager")

local minScriptVersion = "1.0.4"
local sectorCategory
local ELEVATOR_FLOOR_TERMINAL_CONTROLLER_CLASS = "ElevatorFloorTerminalControllerPS"
local serializedGroupModulePaths = {
    ["modules/classes/editor/positionableGroup"] = true,
    ["modules/classes/editor/randomizedGroup"] = true
}
local issueOrder = {
    "nodeRefDuplicated",
    "missingElevatorFloorSetup",
    "noOutlineMarkers",
    "noSplineMarker",
    "splineEmptyRef",
    "spotEmptyRef",
    "spotReferencingEmpty",
    "markingUnresolved",
    "missingInitialPhase"
}
local streamingPresetLabels = {
    "Interior",
    "Street",
    "District",
    "Lanscape",
    "To the Moon"
}
local streamingPresetExtents = {
    { x = 150, y = 150, z = 100 },
    { x = 500, y = 500, z = 400 },
    { x = 1200, y = 1200, z = 1000 },
    { x = 6000, y = 6000, z = 5000 },
    { x = 3.4028235e+38, y = 3.4028235e+38, z = 3.4028235e+38 }
}

exportUI = {
    projectName = "",
    xlFormat = 0,
    groups = {},
    templates = {},
    spawner = nil,
    exportHovered = false,
    exportIssues = {
        nodeRefDuplicated = {},
        missingElevatorFloorSetup = {},
        noOutlineMarkers = {},
        noSplineMarker = {},
        splineEmptyRef = {},
        spotEmptyRef = {},
        spotReferencingEmpty = {},
        markingUnresolved = {},
        missingInitialPhase = {}
    },
    sectorPropertiesWidth = nil,
    mainPropertiesWidth = nil,
    templateDeletePopup = false,
    templateDeleteTarget = nil,
    templateDeleteDontAskAgain = false,
    groupsDividerHovered = false,
    groupsDividerDragging = false,
    templatesDividerHovered = false,
    templatesDividerDragging = false
}

function exportUI.init(spawner)
    for _, file in pairs(dir("data/exportTemplates/")) do
        if file.name:match("^.+(%..+)$") == ".json" then
            local data = config.loadFile("data/exportTemplates/" .. file.name)

            if data.groups then
                for key, group in pairs(data.groups) do
                    if not config.fileExists("data/objects/" .. group.name .. ".json") then
                        data.groups[key] = nil
                    end
                end

                exportUI.templates[data.projectName] = data
            end
        end
    end

    exportUI.spawner = spawner
end

local function calculateExtents(center, objects)
    local maxExtent = {x = 0, y = 0, z = 0}

    for _, point in ipairs(objects) do
        if utils.isA(point.ref, "spawnableElement") and Vector4.Distance(point.ref:getPosition(), Vector4.new(0, 0, 0, 0)) > 25 then
            local pos = point.ref:getPosition()
            local range = math.min(point.ref.spawnable.primaryRange, 250)

            local dx = math.abs(pos.x - center.x) + range
            local dy = math.abs(pos.y - center.y) + range
            local dz = math.abs(pos.z - center.z) + range

            maxExtent.x = math.max(maxExtent.x, dx)
            maxExtent.y = math.max(maxExtent.y, dy)
            maxExtent.z = math.max(maxExtent.z, dz)
        end
    end

    return maxExtent
end

local function drawVariantsTooltip()
    ImGui.SameLine()
    ImGui.Text(IconGlyphs.InformationOutline)
    style.tooltip("All objects placed within the root of the group will be part of the default variant\nLeave variant name empty (or set it to \"default\") to treat it as default/non-variant")
end

---@param name string
---@return table?
local function loadSavedGroupBlob(name)
    if not name then return nil end

    local path = "data/objects/" .. name .. ".json"
    if not config.fileExists(path) then
        return nil
    end

    return config.loadFile(path)
end

---@param entry table?
---@return boolean
local function isSerializedGroupEntry(entry)
    return entry ~= nil and (entry.type == "group" or serializedGroupModulePaths[entry.modulePath] == true)
end

---@param blob table?
---@param existingVariantData table?
---@return table
local function buildVariantDataFromBlob(blob, existingVariantData)
    local variants = {}

    for _, child in pairs(blob and blob.childs or {}) do
        if isSerializedGroupEntry(child) and child.name then
            local existing = existingVariantData and existingVariantData[child.name]
            variants[child.name] = {
                name = existing and existing.name or "",
                ref = existing and existing.ref or "",
                defaultOn = existing == nil or existing.defaultOn ~= false
            }
        end
    end

    return variants
end

---@param variantName string?
---@return string, boolean
local function normalizeVariantName(variantName)
    local normalized = utils.trimString(variantName)

    if normalized == "" or normalized:lower() == "default" then
        return "default", true
    end

    return normalized, false
end

---@param variantData table?
---@return string[]
local function getSortedVariantGroupNames(variantData)
    local names = {}

    for name, _ in pairs(variantData or {}) do
        table.insert(names, name)
    end

    table.sort(names, function(a, b)
        local aName = tostring(a or ""):lower()
        local bName = tostring(b or ""):lower()

        if aName == bName then
            return tostring(a or "") < tostring(b or "")
        end

        return aName < bName
    end)

    return names
end

---@param blob table?
---@param fallback table?
---@return table
local function resolveGroupCenter(blob, fallback)
    local source = nil
    if blob and blob.pos then
        source = blob.pos
    elseif blob and blob.origin then
        source = blob.origin
    end

    if source then
        return {
            x = source.x or 0,
            y = source.y or 0,
            z = source.z or 0
        }
    end

    if fallback then
        return {
            x = fallback.x or 0,
            y = fallback.y or 0,
            z = fallback.z or 0
        }
    end

    return { x = 0, y = 0, z = 0 }
end

---@param group table
---@return Vector4?
local function getGroupCenterVector(group)
    local center = group and group.center
    if not center then
        return nil
    end

    return Vector4.new(center.x or 0, center.y or 0, center.z or 0, 0)
end

---@param point Vector4
---@param center Vector4
---@param extentX number
---@param extentY number
---@param extentZ number
---@return boolean
local function isInsideStreamingExtents(point, center, extentX, extentY, extentZ)
    return point.x >= (center.x - extentX) and point.x <= (center.x + extentX)
        and point.y >= (center.y - extentY) and point.y <= (center.y + extentY)
        and point.z >= (center.z - extentZ) and point.z <= (center.z + extentZ)
end

---@param inside boolean
---@return number, number
local function getStreamingWireframeThemeColors(inside)
    local wireframeColorStyle = settings.wireframeColorStyle or 1
    if wireframeColorStyle == 2 then
        return inside and 0xFF50FF50 or 0xFF5050FF, 0xFF000000
    end

    return inside and style.successColor or 0xFF0000B2, 0xFFDCD8D1
end

local function drawGroupStreamingBoxes()
    local player = GetPlayer()
    if not player then return end

    local targets = {}
    for _, group in ipairs(exportUI.groups or {}) do
        if group.visualizeStreamingBox then
            local extentX = tonumber(group.streamingX) or 0
            local extentY = tonumber(group.streamingY) or 0
            local extentZ = tonumber(group.streamingZ) or 0
            local center = getGroupCenterVector(group)

            if center and extentX > 0 and extentY > 0 and extentZ > 0 then
                table.insert(targets, {
                    center = center,
                    extentX = extentX,
                    extentY = extentY,
                    extentZ = extentZ
                })
            end
        end
    end

    if #targets == 0 then return end

    local screen, drawList = projectedWireframe.beginOverlay("##exportStreamingBoxOverlay")
    if not screen then return end

    local playerPos = player:GetWorldPosition()
    local identityQuat = EulerAngles.new(0, 0, 0):ToQuat()

    for _, target in ipairs(targets) do
        local inside = isInsideStreamingExtents(playerPos, target.center, target.extentX, target.extentY, target.extentZ)
        local color, labelColor = getStreamingWireframeThemeColors(inside)

        projectedWireframe.drawOrientedBox(
            drawList,
            screen,
            target.center,
            identityQuat,
            Vector4.new(-target.extentX, -target.extentY, -target.extentZ, 0),
            Vector4.new(target.extentX, target.extentY, target.extentZ, 0),
            {
                frontColor = color,
                backColor = inside and 0x5500FF00 or 0x550000FF,
                frontThickness = 1.5 * style.viewSize,
                backThickness = 1.2 * style.viewSize,
                fadeNear = 45,
                fadeFar = 175,
                fadeLimit = 0.8,
                originColor = color,
                labelColor = labelColor,
                originDistance = utils.distanceVector(playerPos, target.center)
            }
        )
    end

    projectedWireframe.endOverlay()
end

function exportUI.drawGroups()
    local defaultSize = 260
    local minSize = 120 * style.viewSize
    local maxSize = 800 * style.viewSize
    settings.exportGroupsHeight = math.max(minSize, math.min(maxSize, settings.exportGroupsHeight or 260))

    ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, 0)
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.FrameBg, 0)

    ImGui.BeginChildFrame(1, 0, settings.exportGroupsHeight)

    if #exportUI.groups > 0 then
        for key, group in ipairs(exportUI.groups) do
            ImGui.BeginGroup()

            local nodeFlags = ImGuiTreeNodeFlags.SpanFullWidth
            if ImGui.TreeNodeEx(group.name, nodeFlags) then
                ImGui.PopStyleColor()
                ImGui.PopStyleVar()

                if not exportUI.sectorPropertiesWidth then
                    exportUI.sectorPropertiesWidth = utils.getTextMaxWidth({ "Sector Category", "Sector Level" }) + ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
                end

                if ImGui.TreeNodeEx("Variants", ImGuiTreeNodeFlags.SpanFullWidth) then
                    drawVariantsTooltip()

                    local baseCursorX = ImGui.GetCursorPosX()
                    style.mutedText("Variant Node Ref")
                    ImGui.SameLine()
                    group.variantRef = ImGui.InputTextWithHint('##variantRef', '$/#foobar', group.variantRef, 100)

                    style.mutedText("Variant name")
                    ImGui.SameLine()
                    ImGui.SetCursorPosX(baseCursorX + 100 * style.viewSize + ImGui.GetStyle().ItemSpacing.x)
                    style.mutedText("Default state")
                    ImGui.SameLine()
                    ImGui.SetCursorPosX(baseCursorX + 185 * style.viewSize + ImGui.GetStyle().ItemSpacing.x)
                    style.mutedText("Group name")
                    ImGui.Separator()


                    for _, name in ipairs(getSortedVariantGroupNames(group.variantData)) do
                        local variantData = group.variantData[name]

                        if variantData ~= nil then
                            ImGui.PushID(name)
                            ImGui.SetNextItemWidth(100 * style.viewSize)
                            local previousName = variantData.name or ""
                            local _, previousIsDefaultName = normalizeVariantName(previousName)
                            variantData.name = ImGui.InputTextWithHint('##variantName', 'default', variantData.name, 100)
                            ImGui.SameLine()
                            local normalizedName, isDefaultName = normalizeVariantName(variantData.name)
                            local changed = false
                            ImGui.BeginDisabled(isDefaultName)
                            variantData.defaultOn, changed = style.toggleButton(IconGlyphs.EyeOutline, variantData.defaultOn)
                            ImGui.SameLine()
                            ImGui.Text(variantData.defaultOn and "Visible" or "Hidden")
                            ImGui.EndDisabled()
                            if isDefaultName then
                                variantData.defaultOn = true
                            elseif previousName ~= variantData.name and previousIsDefaultName then
                                -- If the name was changed from default/non-variant, toggle off defaultOn
                                variantData.defaultOn = false
                                changed = true
                            end
                            if changed and not isDefaultName then
                                for variant, _ in pairs(group.variantData) do
                                    local siblingName = group.variantData[variant] and group.variantData[variant].name
                                    local siblingNormalizedName, siblingIsDefaultName = normalizeVariantName(siblingName)
                                    if not siblingIsDefaultName and siblingNormalizedName == normalizedName then
                                        group.variantData[variant].defaultOn = variantData.defaultOn
                                    end
                                end
                            end
                            ImGui.SameLine()
                            ImGui.SetCursorPosX(baseCursorX + 185 * style.viewSize + ImGui.GetStyle().ItemSpacing.x)
                            style.mutedText(name)

                            ImGui.PopID()
                        end
                    end

                    ImGui.Dummy(0, 4 * style.viewSize)
                    ImGui.TreePop()
                else
                    drawVariantsTooltip()
                end

                style.mutedText("Sector Category")
                style.tooltip("Select the type of the sector for the group, if in doubt use Interior or Exterior")
                ImGui.SameLine()
                ImGui.SetCursorPosX(exportUI.sectorPropertiesWidth)
                ImGui.SetNextItemWidth(150 * style.viewSize)
                group.category = ImGui.Combo("##category", group.category, sectorCategory, #sectorCategory)

                if group.category == 3 then
                    style.mutedText("Prefab Ref")
                    style.tooltip("Prefab NodeRef of the sector")
                    ImGui.SameLine()
                    ImGui.SetCursorPosX(exportUI.sectorPropertiesWidth)
                    ImGui.SetNextItemWidth(150 * style.viewSize)

                    group.prefabRef, _ = ImGui.InputTextWithHint('##prefabRef', '$/#foobar', group.prefabRef, 100)
                end

                style.mutedText("Sector Level")
                style.tooltip("Select the level of the sector for the group")
                ImGui.SameLine()
                ImGui.SetCursorPosX(exportUI.sectorPropertiesWidth)
                ImGui.SetNextItemWidth(150 * style.viewSize)
                group.level, changed = ImGui.InputInt("##level", group.level)
                if changed then
                    group.level = math.min(math.max(group.level, 0), 6)
                end

                if ImGui.TreeNodeEx("Streaming Box", ImGuiTreeNodeFlags.SpanFullWidth) then
                    local streamingPropertiesWidth = utils.getTextMaxWidth({ "Visualize", "Distance Preset", "Box Extents" }) + ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

                    style.mutedText("Visualize")
                    style.tooltip("Draw a projected wireframe of this group's streaming box in the world view.")
                    ImGui.SameLine()
                    ImGui.SetCursorPosX(streamingPropertiesWidth)
                    group.visualizeStreamingBox, _ = ImGui.Checkbox("##visualizeStreamingBox", group.visualizeStreamingBox == true)

                    style.mutedText("Distance Preset")
                    ImGui.SameLine()
                    ImGui.SetCursorPosX(streamingPropertiesWidth)
                    ImGui.SetNextItemWidth(140 * style.viewSize)
                    group.streamingPresetIndex = ImGui.Combo("##groupStreamingDistancePreset", group.streamingPresetIndex or 0, streamingPresetLabels, #streamingPresetLabels)
                    style.tooltip("Quickly set Streaming Box Extents to a common value.\n- Interior: Small rooms and indoor props loaded only when close.\n- Street: Regular city assets visible from nearby streets.\n- District: Medium-large city chunks visible across a wider district area.\n- Landscape: Large outdoor landmarks visible from far away.\n- To the Moon: Keep visible from anywhere; use only for very important assets.")
                    ImGui.SameLine()
                    if ImGui.Button("Apply##groupStreamingDistancePreset") then
                        local preset = streamingPresetExtents[(group.streamingPresetIndex or 0) + 1]
                        if preset then
                            group.streamingX = preset.x
                            group.streamingY = preset.y
                            group.streamingZ = preset.z
                        end
                    end
                    style.tooltip("Apply the selected preset to Streaming Box Extents.")

                    style.mutedText("Box Extents")
                    style.tooltip("Change the size of the streaming box for the sector, extends the given amount on each axis in both directions")
                    ImGui.SameLine()
                    ImGui.SetCursorPosX(streamingPropertiesWidth)
                    if ImGui.Button("Auto") then
                        local blob = config.loadFile("data/objects/" .. group.name .. ".json")
                        local g = require("modules/classes/editor/positionableGroup"):new(exportUI.spawner.baseUI.spawnedUI)
                        g:load(blob, true)

                        local extents = calculateExtents(group.center, g:getPathsRecursive(false))
                        group.streamingX = extents.x * 1.2
                        group.streamingY = extents.y * 1.2
                        group.streamingZ = extents.z * 1.2
                    end
                    style.tooltip("Auto-computes box extents from the group's content.\nUses each spawned element's distance from group center (minimum 250), then applies a 20% safety margin.\nOnly spawnable elements are considered.\nThis replaces current X/Y/Z values.")
                    ImGui.SameLine()
                    group.streamingX, _, _ = field.advancedTrackedFloat(nil, "##x", group.streamingX, {
                        step = 0.25,
                        min = 0,
                        max = 3.4028235e+38,
                        format = "%.1f",
                        width = 84,
                        suffix = " X Size"
                    })
                    ImGui.SameLine()
                    group.streamingY, _, _ = field.advancedTrackedFloat(nil, "##y", group.streamingY, {
                        step = 0.25,
                        min = 0,
                        max = 3.4028235e+38,
                        format = "%.1f",
                        width = 84,
                        suffix = " Y Size"
                    })
                    ImGui.SameLine()
                    group.streamingZ, _, _ = field.advancedTrackedFloat(nil, "##z", group.streamingZ, {
                        step = 0.25,
                        min = 0,
                        max = 3.4028235e+38,
                        format = "%.1f",
                        width = 84,
                        suffix = " Z Size"
                    })
                    ImGui.SameLine()

                    local player = GetPlayer()
                    local center = getGroupCenterVector(group)
                    local playerPos = player and player:GetWorldPosition() or Vector4.new(0, 0, 0, 0)
                    local inside = false

                    if center and player then
                        inside = isInsideStreamingExtents(playerPos, center, group.streamingX, group.streamingY, group.streamingZ)
                    end

                    local distance = center and utils.distanceVector(center, playerPos) or 0
                    style.styledText(IconGlyphs.AxisArrowInfo, inside and 0xFF00FF00 or 0xFF0000FF)
                    style.tooltip("Distance to player: " .. string.format("%.2f", distance))

                    ImGui.TreePop()
                end

                if ImGui.Button("Remove from list") then
                    table.remove(exportUI.groups, key)
                end

                ImGui.Dummy(0, 4 * style.viewSize)
                ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
                ImGui.PushStyleColor(ImGuiCol.FrameBg, 0)
                ImGui.TreePop()
            end
            ImGui.EndGroup()
        end
    else
        ImGui.PushStyleColor(ImGuiCol.Text, style.mutedColor)
        ImGui.TextWrapped("No groups yet added, add them from the \"Saved\" tab!")
        ImGui.PopStyleColor()
    end

    ImGui.EndChildFrame()
    ImGui.PopStyleColor()
    ImGui.PopStyleVar(2)
    drawGroupStreamingBoxes()

    if exportUI.groupsDividerHovered then
        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.4, 0.4, 0.4, 1.0)
    else
        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.2, 0.2, 0.2, 1.0)
    end

    ImGui.BeginChild("##groupsDivider", 0, 7.5 * style.viewSize, false, ImGuiWindowFlags.NoMove)
    local wx, wy = ImGui.GetContentRegionAvail()
    local textWidth, textHeight = ImGui.CalcTextSize(IconGlyphs.DragHorizontalVariant)
    ImGui.SetCursorPosX((wx - textWidth) / 2)
    ImGui.SetCursorPosY(1 * style.viewSize + (wy - textHeight) / 2)
    ImGui.Text(IconGlyphs.DragHorizontalVariant)
    ImGui.EndChild()
    if exportUI.groupsDividerHovered and ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left) then
        settings.exportGroupsHeight = defaultSize
        settings.save()
    end
    exportUI.groupsDividerHovered = ImGui.IsItemHovered()

    if exportUI.groupsDividerHovered and ImGui.IsMouseDragging(0, 0) then
        exportUI.groupsDividerDragging = true
    end
    if exportUI.groupsDividerDragging and not ImGui.IsMouseDragging(0, 0) then
        exportUI.groupsDividerDragging = false
        settings.save()
    end
    if exportUI.groupsDividerDragging then
        local _, dy = ImGui.GetMouseDragDelta(0, 0)
        settings.exportGroupsHeight = settings.exportGroupsHeight + dy
        settings.exportGroupsHeight = math.max(minSize, math.min(maxSize, settings.exportGroupsHeight))
        ImGui.ResetMouseDragDelta()
    end
    if exportUI.groupsDividerHovered or exportUI.groupsDividerDragging then
        ImGui.SetMouseCursor(ImGuiMouseCursor.ResizeNS)
    end
    ImGui.PopStyleColor()
end

function exportUI.loadTemplate(data)
    local existingNames = {}
    for _, existing in ipairs(exportUI.groups) do
        if existing.name then
            existingNames[existing.name] = true
        end
    end

    for _, group in pairs(data.groups or {}) do
        local blob = loadSavedGroupBlob(group.name)
        if blob then
            local mapped = {
                name = group.name,
                category = group.category or 1,
                level = group.level or 1,
                visualizeStreamingBox = group.visualizeStreamingBox == true,
                streamingPresetIndex = group.streamingPresetIndex or 0,
                streamingX = group.streamingX or 150,
                streamingY = group.streamingY or 150,
                streamingZ = group.streamingZ or 100,
                center = resolveGroupCenter(blob, group.center),
                prefabRef = group.prefabRef or "",
                variantRef = group.variantRef or "",
                variantData = buildVariantDataFromBlob(blob, group.variantData)
            }

            if not existingNames[mapped.name] then
                table.insert(exportUI.groups, mapped)
                existingNames[mapped.name] = true
            end
        end
    end

    exportUI.xlFormat = data.xlFormat or 0
    exportUI.projectName = data.projectName
end

---@param key string
---@param data table
local function deleteTemplateEntry(key, data)
    local templateName = data and data.projectName or key
    if not templateName then return end

    os.remove("data/exportTemplates/" .. templateName .. ".json")
    exportUI.templates[key] = nil
end

---@param key string
---@param data table
function exportUI.deleteTemplate(key, data)
    if settings.skipTemplateDeleteConfirm then
        deleteTemplateEntry(key, data)
        return
    end

    exportUI.templateDeletePopup = true
    exportUI.templateDeleteTarget = { key = key, data = data }
    exportUI.templateDeleteDontAskAgain = settings.skipTemplateDeleteConfirm
end

function exportUI.handleTemplateDeletePopup()
    if exportUI.templateDeletePopup then
        ImGui.OpenPopup("Delete Template?")
        if ImGui.BeginPopupModal("Delete Template?", true, ImGuiWindowFlags.AlwaysAutoResize) then
            local targetName = exportUI.templateDeleteTarget and exportUI.templateDeleteTarget.data and exportUI.templateDeleteTarget.data.projectName or "Unknown"
            ImGui.Text("Delete \"" .. targetName .. "\"?")
            style.mutedText("This action cannot be undone.")
            ImGui.Dummy(0, 8 * style.viewSize)
            exportUI.templateDeleteDontAskAgain = ImGui.Checkbox("Don't ask again", exportUI.templateDeleteDontAskAgain)
            ImGui.Dummy(0, 8 * style.viewSize)

            if ImGui.Button("Cancel") then
                ImGui.CloseCurrentPopup()
                exportUI.templateDeletePopup = false
                exportUI.templateDeleteTarget = nil
            end

            ImGui.SameLine()

            if ImGui.Button("Confirm") then
                ImGui.CloseCurrentPopup()
                settings.skipTemplateDeleteConfirm = exportUI.templateDeleteDontAskAgain
                settings.save()

                local target = exportUI.templateDeleteTarget
                if target and target.key and target.data then
                    deleteTemplateEntry(target.key, target.data)
                end

                exportUI.templateDeletePopup = false
                exportUI.templateDeleteTarget = nil
            end

            ImGui.EndPopup()
        end
    end
end

function exportUI.drawTemplates()
    local defaultSize = 160
    local minSize = 80 * style.viewSize
    local maxSize = 500 * style.viewSize
    local defaultFramePaddingX = ImGui.GetStyle().FramePadding.x
    local defaultFramePaddingY = ImGui.GetStyle().FramePadding.y
    settings.exportTemplatesHeight = math.max(minSize, math.min(maxSize, settings.exportTemplatesHeight or 160))

    if utils.tableLength(exportUI.templates) > 0 then
        ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, 0)
        ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
        ImGui.PushStyleColor(ImGuiCol.FrameBg, 0)

        ImGui.BeginChildFrame(2, 0, settings.exportTemplatesHeight)

        local sortedTemplates = {}
        for key, data in pairs(exportUI.templates) do
            table.insert(sortedTemplates, { key = key, data = data })
        end

        table.sort(sortedTemplates, function(a, b)
            local aName = tostring(a.data.projectName or a.key or ""):lower()
            local bName = tostring(b.data.projectName or b.key or ""):lower()

            if aName == bName then
                return tostring(a.key) < tostring(b.key)
            end

            return aName < bName
        end)

        if ImGui.BeginTable("##exportTemplatesTable", 3, ImGuiTableFlags.SizingStretchProp or ImGuiTableFlags.NoHostExtendX) then
            ImGui.TableSetupColumn("##templateName", ImGuiTableColumnFlags.WidthStretch, 0.55)
            ImGui.TableSetupColumn("##templateGroups", ImGuiTableColumnFlags.WidthStretch, 0.20)
            ImGui.TableSetupColumn("##templateActions", ImGuiTableColumnFlags.WidthStretch, 0.25)

            for _, entry in ipairs(sortedTemplates) do
                local key = entry.key
                local data = entry.data
                local templateName = tostring(data.projectName or key)
                local groupLabel = tostring(#data.groups)
                local rowHeight = ImGui.GetFrameHeight() + defaultFramePaddingY * 2
                local loadWidth = ImGui.CalcTextSize("Load") + defaultFramePaddingX * 2
                local deleteWidth = ImGui.CalcTextSize(IconGlyphs.DeleteOutline) + defaultFramePaddingX * 2
                local actionsWidth = loadWidth + ImGui.GetStyle().ItemSpacing.x + deleteWidth
                local rowActivated = false
                local rowHovered = false

                ImGui.TableNextRow(ImGuiTableRowFlags.None, rowHeight)
                ImGui.PushID(key)

                ImGui.TableSetColumnIndex(0)
                local rowContentY = ImGui.GetCursorPosY()
                ImGui.PushStyleColor(ImGuiCol.Header, 0, 0, 0, 0)
                ImGui.PushStyleColor(ImGuiCol.HeaderHovered, 0, 0, 0, 0)
                ImGui.PushStyleColor(ImGuiCol.HeaderActive, 0, 0, 0, 0)
                ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, defaultFramePaddingX, defaultFramePaddingY)
                rowActivated = ImGui.Selectable("##templateRow", false, ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowOverlap + ImGuiSelectableFlags.AllowDoubleClick)
                rowHovered = ImGui.IsItemHovered()
                ImGui.PopStyleVar()
                ImGui.PopStyleColor(3)
                ImGui.SetItemAllowOverlap()
                ImGui.TableSetColumnIndex(0)
                ImGui.SetCursorPosY(rowContentY)
                ImGui.AlignTextToFramePadding()
                ImGui.Text(templateName)

                ImGui.TableSetColumnIndex(1)
                ImGui.SetCursorPosY(rowContentY)
                local groupStartX = ImGui.GetCursorPosX()
                local groupAvailWidth = ImGui.GetContentRegionAvail()
                local groupWidth = ImGui.CalcTextSize(groupLabel)
                ImGui.SetCursorPosX(groupStartX + math.max(0, (groupAvailWidth - groupWidth) / 2))
                ImGui.AlignTextToFramePadding()
                style.mutedText(groupLabel)

                ImGui.TableSetColumnIndex(2)
                ImGui.SetCursorPosY(rowContentY)
                local actionsStartX = ImGui.GetCursorPosX()
                local actionsAvailWidth = ImGui.GetContentRegionAvail()
                local loadButtonHovered = false
                local deleteButtonHovered = false
                ImGui.SetCursorPosX(actionsStartX + math.max(0, actionsAvailWidth - actionsWidth))
                ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, defaultFramePaddingX, defaultFramePaddingY)
                if ImGui.Button("Load") then
                    exportUI.loadTemplate(data)
                end
                loadButtonHovered = ImGui.IsItemHovered()
                ImGui.SameLine()
                if style.dangerButton(IconGlyphs.DeleteOutline) then
                    exportUI.deleteTemplate(key, data)
                end
                deleteButtonHovered = ImGui.IsItemHovered()
                ImGui.PopStyleVar()

                if rowHovered then
                    ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.30, 0.30, 0.30, 0.20)
                end
                if rowActivated and not loadButtonHovered and not deleteButtonHovered and ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left) then
                    exportUI.loadTemplate(data)
                end

                ImGui.PopID()
            end

            ImGui.EndTable()
        end

        ImGui.EndChildFrame()
        ImGui.PopStyleColor()
        ImGui.PopStyleVar(2)
    else
        ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, 0)
        ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
        ImGui.PushStyleColor(ImGuiCol.FrameBg, 0)
        ImGui.BeginChildFrame(2, 0, settings.exportTemplatesHeight)
        ImGui.PushStyleColor(ImGuiCol.Text, style.mutedColor)
        ImGui.TextWrapped("No templates created yet.")
        ImGui.PopStyleColor()
        ImGui.EndChildFrame()
        ImGui.PopStyleColor()
        ImGui.PopStyleVar(2)
    end

    if exportUI.templatesDividerHovered then
        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.4, 0.4, 0.4, 1.0)
    else
        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.2, 0.2, 0.2, 1.0)
    end

    ImGui.BeginChild("##templatesDivider", 0, 7.5 * style.viewSize, false, ImGuiWindowFlags.NoMove)
    local wx, wy = ImGui.GetContentRegionAvail()
    local textWidth, textHeight = ImGui.CalcTextSize(IconGlyphs.DragHorizontalVariant)
    ImGui.SetCursorPosX((wx - textWidth) / 2)
    ImGui.SetCursorPosY(1 * style.viewSize + (wy - textHeight) / 2)
    ImGui.Text(IconGlyphs.DragHorizontalVariant)
    ImGui.EndChild()
    if exportUI.templatesDividerHovered and ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left) then
        settings.exportTemplatesHeight = defaultSize
        settings.save()
    end
    exportUI.templatesDividerHovered = ImGui.IsItemHovered()

    if exportUI.templatesDividerHovered and ImGui.IsMouseDragging(0, 0) then
        exportUI.templatesDividerDragging = true
    end
    if exportUI.templatesDividerDragging and not ImGui.IsMouseDragging(0, 0) then
        exportUI.templatesDividerDragging = false
        settings.save()
    end
    if exportUI.templatesDividerDragging then
        local _, dy = ImGui.GetMouseDragDelta(0, 0)
        settings.exportTemplatesHeight = settings.exportTemplatesHeight + dy
        settings.exportTemplatesHeight = math.max(minSize, math.min(maxSize, settings.exportTemplatesHeight))
        ImGui.ResetMouseDragDelta()
    end
    if exportUI.templatesDividerHovered or exportUI.templatesDividerDragging then
        ImGui.SetMouseCursor(ImGuiMouseCursor.ResizeNS)
    end
    ImGui.PopStyleColor()
end

function exportUI.getCurrentIssue()
    for _, key in ipairs(issueOrder) do
        local value = exportUI.exportIssues[key]
        if #value ~= 0 then
            return key
        end
    end
end

function exportUI.resetIssues()
    for _, key in ipairs(issueOrder) do
        exportUI.exportIssues[key] = {}
    end
end

function exportUI.hasBlockingIssues()
    return exportUI.getCurrentIssue() ~= nil
end

function exportUI.drawToasts()
    groupExportManager.drawToasts()
end

function exportUI.cancelExport(reason, suppressToast)
    return groupExportManager.cancel(reason, suppressToast)
end

function exportUI.drawExportProgress()
    return groupExportManager.drawProgress(style)
end

local function resolveIssue(issueKey, forceExport)
    if not issueKey then
        return
    end

    exportUI.exportIssues[issueKey] = {}
    ImGui.CloseCurrentPopup()

    if groupExportManager.isPaused() then
        if forceExport then
            if not exportUI.hasBlockingIssues() then
                groupExportManager.resume()
            end
        else
            exportUI.resetIssues()
            exportUI.cancelExport("validation issue")
        end
    end
end

local function drawIssueButtons(issueKey)
    if ImGui.Button("OK") then
        resolveIssue(issueKey, false)
    end

    if groupExportManager.isPaused() then
        ImGui.SameLine()
        if style.warnButton("Force export") then
            resolveIssue(issueKey, true)
        end
    end
end

function exportUI.drawIssues()
    if exportUI.getCurrentIssue() == "nodeRefDuplicated" then
        ImGui.OpenPopup("Duplicated NodeRefs")
        if ImGui.BeginPopupModal("Duplicated NodeRefs", true, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("Duplicated nodeRefs found, please fix them before exporting!")

            ImGui.Separator()

            for _, duplicate in pairs(exportUI.exportIssues.nodeRefDuplicated) do
                style.mutedText("NodeRef:")
                ImGui.SameLine()
                ImGui.Text(duplicate.nodeRef)

                style.mutedText("Node 1: ")
                ImGui.SameLine()
                ImGui.Text(duplicate.name1)

                style.mutedText("Node 2: ")
                ImGui.SameLine()
                ImGui.Text(duplicate.name2)
            end

            ImGui.Separator()

            drawIssueButtons("nodeRefDuplicated")
            ImGui.EndPopup()
        end
    end
    if exportUI.getCurrentIssue() == "missingElevatorFloorSetup" then
        ImGui.OpenPopup("Missing Elevator Floor Setup")
        if ImGui.BeginPopupModal("Missing Elevator Floor Setup", true, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("Persistent elevator floor terminal data is missing and export cannot safely create .psrep entries.")

            ImGui.Separator()

            for _, entry in pairs(exportUI.exportIssues.missingElevatorFloorSetup) do
                style.mutedText("Node Name:")
                ImGui.SameLine()
                ImGui.Text(entry.name)

                style.mutedText("Group:")
                ImGui.SameLine()
                ImGui.Text(entry.group)

                style.mutedText("NodeRef:")
                ImGui.SameLine()
                ImGui.Text(entry.nodeRef ~= "" and entry.nodeRef or "(empty)")

                style.mutedText("Issue:")
                ImGui.SameLine()
                ImGui.Text(entry.reason)

                ImGui.Separator()
            end

            drawIssueButtons("missingElevatorFloorSetup")
            ImGui.EndPopup()
        end
    end
    if exportUI.getCurrentIssue() == "noOutlineMarkers" then
        ImGui.OpenPopup("Missing Outline Markers")
        if ImGui.BeginPopupModal("Missing Outline Markers", true, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("The following area nodes have no outline, possibly due to a broken outline group link!")

            ImGui.Separator()

            for _, area in pairs(exportUI.exportIssues.noOutlineMarkers) do
                style.mutedText("Area Name:")
                ImGui.SameLine()
                ImGui.Text(area)

                ImGui.Separator()
            end

            drawIssueButtons("noOutlineMarkers")
            ImGui.EndPopup()
        end
    end
    if exportUI.getCurrentIssue() == "noSplineMarker" then
        ImGui.OpenPopup("Missing Spline Points")
        if ImGui.BeginPopupModal("Missing Spline Points", true, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("The following spline nodes have no points, possibly due to a broken spline group link!")

            ImGui.Separator()

            for _, spline in pairs(exportUI.exportIssues.noSplineMarker) do
                style.mutedText("Spline Name:")
                ImGui.SameLine()
                ImGui.Text(spline)

                ImGui.Separator()
            end

            drawIssueButtons("noSplineMarker")
            ImGui.EndPopup()
        end
    end
    if exportUI.getCurrentIssue() == "splineEmptyRef" then
        ImGui.OpenPopup("Empty Spline NodeRef")
        if ImGui.BeginPopupModal("Empty Spline NodeRef", true, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("The following Spline nodes do not have a NodeRef assigned to them, making them unusable!")

            ImGui.Separator()

            for _, name in pairs(exportUI.exportIssues.splineEmptyRef) do
                style.mutedText("Node Name:")
                ImGui.SameLine()
                ImGui.Text(name)
            end

            ImGui.Separator()

            drawIssueButtons("splineEmptyRef")
            ImGui.EndPopup()
        end
    end
    if exportUI.getCurrentIssue() == "spotEmptyRef" then
        ImGui.OpenPopup("Empty AISpot NodeRef")
        if ImGui.BeginPopupModal("Empty AISpot NodeRef", true, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("The following AISpot's do not have a NodeRef assigned to them, making them unusable!")

            ImGui.Separator()

            for _, name in pairs(exportUI.exportIssues.spotEmptyRef) do
                style.mutedText("Node Name:")
                ImGui.SameLine()
                ImGui.Text(name)
            end

            ImGui.Separator()

            drawIssueButtons("spotEmptyRef")
            ImGui.EndPopup()
        end
    end
    if exportUI.getCurrentIssue() == "spotReferencingEmpty" then
        ImGui.OpenPopup("Community Referencing Missing NodeRef")
        if ImGui.BeginPopupModal("Community Referencing Missing NodeRef", true, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("The following Community Entries reference a NodeRef that is not part of this export. (Might still work, if the NodeRef is part of another export)")

            ImGui.Separator()

            for _, entry in pairs(exportUI.exportIssues.spotReferencingEmpty) do
                style.mutedText("Node Name:")
                ImGui.SameLine()
                ImGui.Text(entry.name)

                style.mutedText("Community Entry:")
                ImGui.SameLine()
                ImGui.Text(entry.entry)

                style.mutedText("Entry Phase:")
                ImGui.SameLine()
                ImGui.Text(entry.phase)

                style.mutedText("Phase Period:")
                ImGui.SameLine()
                ImGui.Text(entry.period)

                style.mutedText("Missing spotNodeRef:")
                ImGui.SameLine()
                ImGui.Text(entry.ref)

                ImGui.Separator()
            end

            drawIssueButtons("spotReferencingEmpty")
            ImGui.EndPopup()
        end
    end
    if exportUI.getCurrentIssue() == "markingUnresolved" then
        ImGui.OpenPopup("Unresolved Marking")
        if ImGui.BeginPopupModal("Unresolved Marking", true, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("The following markings have no AISpots associated with them.")

            ImGui.Separator()

            for _, entry in pairs(exportUI.exportIssues.markingUnresolved) do
                style.mutedText("Node Name:")
                ImGui.SameLine()
                ImGui.Text(entry.name)

                style.mutedText("Community Entry:")
                ImGui.SameLine()
                ImGui.Text(entry.entry)

                style.mutedText("Entry Phase:")
                ImGui.SameLine()
                ImGui.Text(entry.phase)

                style.mutedText("Phase Period:")
                ImGui.SameLine()
                ImGui.Text(entry.period)

                style.mutedText("Marking:")
                ImGui.SameLine()
                ImGui.Text(entry.marking)

                ImGui.Separator()
            end

            drawIssueButtons("markingUnresolved")
            ImGui.EndPopup()
        end
    end
    if exportUI.getCurrentIssue() == "missingInitialPhase" then
        ImGui.OpenPopup("Missing Initial Phase")
        if ImGui.BeginPopupModal("Missing Initial Phase", true, ImGuiWindowFlags.AlwaysAutoResize) then
            ImGui.Text("The following Community Entries reference non-existing phases as their initial phase.")

            ImGui.Separator()

            for _, entry in pairs(exportUI.exportIssues.missingInitialPhase) do
                style.mutedText("Node Name:")
                ImGui.SameLine()
                ImGui.Text(entry.name)

                style.mutedText("Community Entry:")
                ImGui.SameLine()
                ImGui.Text(entry.entry)

                style.mutedText("Missing Phase:")
                ImGui.SameLine()
                ImGui.Text(entry.phase)

                ImGui.Separator()
            end

            drawIssueButtons("missingInitialPhase")
            ImGui.EndPopup()
        end
    end
end

function exportUI.draw()
    local runtime = groupExportManager.getState()
    local exporting = groupExportManager.isActive()

    exportUI.drawToasts()

    if not exporting or groupExportManager.isPaused() then
        exportUI.drawIssues()
    end

    if not sectorCategory then
        sectorCategory = utils.enumTable("worldStreamingSectorCategory")
    end

    do
        local headerX = ImGui.GetCursorPosX()
        local headerWidth = ImGui.GetContentRegionAvail()
        local qtyLabel = "Qty groups"
        local qtyLabelWidth = ImGui.CalcTextSize(qtyLabel)
        local qtyLabelX = headerX + headerWidth * 0.55 + math.max(0, (headerWidth * 0.20 - qtyLabelWidth) / 2)

        ImGui.PushStyleColor(ImGuiCol.Text, style.mutedColor)
        ImGui.Text("Export templates")
        style.tooltip("Templates let you save an export setup for later usage, without having to setup what groups/settings to use each time.")
        ImGui.SameLine()
        ImGui.SetCursorPosX(math.max(ImGui.GetCursorPosX(), qtyLabelX))
        ImGui.Text(qtyLabel)
        ImGui.PopStyleColor()
        ImGui.Separator()
        ImGui.Spacing()

        ImGui.BeginGroup()
        ImGui.AlignTextToFramePadding()
    end

    exportUI.drawTemplates()
    exportUI.handleTemplateDeletePopup()

    style.sectionHeaderEnd()

    style.sectionHeaderStart("Properties")

    if not exportUI.mainPropertiesWidth then
        exportUI.mainPropertiesWidth = utils.getTextMaxWidth({ "Project Name", "XL Format" }) + ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    style.pushStyleColor(exportUI.projectName == "" and exportUI.exportHovered, ImGuiCol.Text, 0xFF0000FF)
    ImGui.Text("Project Name")
    style.popStyleColor(exportUI.projectName == "" and exportUI.exportHovered)
    ImGui.SameLine()
    ImGui.SetNextItemWidth(200 * style.viewSize)
    ImGui.SetCursorPosX(exportUI.mainPropertiesWidth)
    exportUI.projectName = ImGui.InputTextWithHint('##name', 'Export name...', exportUI.projectName, 100)
    if exportUI.projectName ~= "" then
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Close .. "##clearExportProjectName") then
            exportUI.projectName = ""
        end
        style.pushButtonNoBG(false)
    end

    ImGui.Text("XL Format")
    ImGui.SameLine()
    ImGui.SetNextItemWidth(150 * style.viewSize)
    ImGui.SetCursorPosX(exportUI.mainPropertiesWidth)
    exportUI.xlFormat, _ = ImGui.Combo("##xlFormat", exportUI.xlFormat, { "JSON", "YAML" }, 2)
    style.tooltip("Select the format in which the contents of the generated .xl file should be.")

    style.pushGreyedOut(#exportUI.groups == 0 or exporting)
    if ImGui.Button("Clear group list") and not exporting then
        exportUI.groups = {}
    end
    style.popGreyedOut(#exportUI.groups == 0 or exporting)
    style.tooltip("Remove all groups from the current export list")

    style.sectionHeaderEnd()
    style.sectionHeaderStart(string.format("Groups (%d)", #exportUI.groups))

    exportUI.drawGroups()

    style.sectionHeaderEnd()
    style.sectionHeaderStart("Export and Save")

    local groupNameCounts = {}
    local duplicateGroupNames = {}
    for _, group in ipairs(exportUI.groups) do
        local name = group.name or ""
        groupNameCounts[name] = (groupNameCounts[name] or 0) + 1
    end
    for name, count in pairs(groupNameCounts) do
        if name ~= "" and count > 1 then
            table.insert(duplicateGroupNames, name)
        end
    end

    if #duplicateGroupNames > 0 then
        table.sort(duplicateGroupNames)
        local duplicateGroupWarningLabel = style.resolveActionLabelNoIconOnly(IconGlyphs.AlertOutline, "Duplicate group names detected", nil)
        style.styledText(duplicateGroupWarningLabel, 0xFF0088FF)
        style.tooltip("Duplicated group names:\n- " .. table.concat(duplicateGroupNames, "\n- "))
        ImGui.Spacing()
    end

    style.pushGreyedOut(#exportUI.groups == 0 or exportUI.projectName == "" or exporting)
    local fullExportLabel = "Full export"
    local updateChangedLabel = "Update existing export"
    if exporting then
        local modeLabel = runtime and runtime.mode == "incremental" and "Updating..." or "Exporting..."
        fullExportLabel = string.format("%s (%d/%d)", modeLabel, runtime.completedGroups or 0, runtime.totalGroups or 0)
        updateChangedLabel = fullExportLabel
    end

    if ImGui.Button(updateChangedLabel) and #exportUI.groups > 0 and exportUI.projectName ~= "" and not exporting then
        exportUI.export("incremental")
    end
    style.tooltip("Update the existing export file by rebuilding only changed groups.")
    exportUI.exportHovered = ImGui.IsItemHovered()

    ImGui.SameLine()
    if ImGui.Button(fullExportLabel) and #exportUI.groups > 0 and exportUI.projectName ~= "" and not exporting then
        exportUI.export("full")
    end
    style.tooltip("Export all selected groups from scratch, overriding the existing export file.")
    exportUI.exportHovered = exportUI.exportHovered or ImGui.IsItemHovered()

    ImGui.SameLine()
    if ImGui.Button("Save as Template") and #exportUI.groups > 0 and exportUI.projectName ~= "" and not exporting then
        local data = {
            projectName = exportUI.projectName,
            xlFormat = exportUI.xlFormat,
            groups = utils.deepcopy(exportUI.groups)
        }
        exportUI.templates[exportUI.projectName] = data
        config.saveFile("data/exportTemplates/" .. exportUI.projectName .. ".json", data)
    end
    style.tooltip("Save the current export setup as a template for later (re)usage")

    style.popGreyedOut(#exportUI.groups == 0 or exportUI.projectName == "" or exporting)

    exportUI.drawExportProgress()

    style.sectionHeaderEnd(true)
end

function exportUI.addGroup(name)
    for _, data in pairs(exportUI.groups) do
        if data.name == name then return end
    end

    local data = {
        name = name,
        category = 1,
        level = 1,
        visualizeStreamingBox = false,
        streamingPresetIndex = 0,
        streamingX = 150,
        streamingY = 150,
        streamingZ = 100,
        center = nil,
        prefabRef = "",
        variantRef = "",
        variantData = {}
    }

    table.insert(exportUI.groups, data)
    local blob = loadSavedGroupBlob(name)
    if not blob then return end

    data.variantData = buildVariantDataFromBlob(blob, nil)
    data.center = resolveGroupCenter(blob, nil)
end

---Remove groups from export list by group name
---@param name string
---@return integer
function exportUI.removeGroupByName(name)
    local removed = 0

    for i = #exportUI.groups, 1, -1 do
        if exportUI.groups[i].name == name then
            table.remove(exportUI.groups, i)
            removed = removed + 1
        end
    end

    return removed
end

---Sync group data in export list from saved group file
---Keeps export-specific settings (streaming/category/level/refs) while refreshing center + variants
---@param name string
---@return integer
function exportUI.syncGroup(name)
    local blob = loadSavedGroupBlob(name)
    if not blob then return 0 end

    local updated = 0

    for _, group in ipairs(exportUI.groups) do
        if group.name == name then
            group.variantData = buildVariantDataFromBlob(blob, group.variantData)
            group.center = resolveGroupCenter(blob, group.center)
            updated = updated + 1
        end
    end

    return updated
end

function exportUI.getSpawnableByNodeRef(nodeRefMap, nodeRef)
    if not nodeRef or nodeRef == "" then
        return nil
    end

    return nodeRefMap[nodeRef]
end

---@param value any
---@return string
local function sanitizeValue(value)
    local sanitized = tostring(value or "")
    sanitized = sanitized:gsub("^%s+", ""):gsub("%s+$", "")
    sanitized = sanitized:gsub("[\128-\255]", "")
    return sanitized
end

---@param object table
---@param reason string
local function addMissingElevatorFloorSetupIssue(object, reason)
    local ref = object and object.ref
    local spawnable = ref and ref.spawnable
    if not spawnable then
        return
    end

    local root = ref and ref.getRootParent and ref:getRootParent() or nil
    table.insert(exportUI.exportIssues.missingElevatorFloorSetup, {
        name = tostring(ref and ref.name or "Unknown"),
        group = tostring(root and root.name or "Unknown"),
        nodeRef = sanitizeValue(spawnable.nodeRef),
        reason = tostring(reason or "Missing elevator floor setup")
    })
end

function exportUI.handleDevice(object, devices, psEntries, childs, nodeRefMap)
    local hash = utils.nodeRefStringToHashString(object.ref.spawnable.nodeRef)

    local childHashes = {}
    for _, child in pairs(object.ref.spawnable.deviceConnections) do
        table.insert(childHashes, utils.nodeRefStringToHashString(child.nodeRef))

        -- Remember what childs exist, so that we can also add those to the devices file which are entityNodes, not deviceNodes

        local childRef = exportUI.getSpawnableByNodeRef(nodeRefMap, child.nodeRef)
        if childRef and childRef.ref.spawnable.deviceConnections == nil then
            table.insert(childs, {
                className = child.deviceClassName,
                nodePosition = utils.fromVector(childRef ~= nil and childRef.ref:getPosition() or object.ref:getPosition()),
                ref = child.nodeRef,
                parent = hash
            })
        end
    end

    devices[hash] = {
        hash = hash,
        className = object.ref.spawnable.deviceClassName,
        nodePosition = utils.fromVector(object.ref:getPosition()),
        parents = {},
        children = childHashes
    }

    if object.ref.spawnable.persistent and object.ref.spawnable.nodeRef ~= "" then
        local psData = object.ref.spawnable:getPSData()
        local className = sanitizeValue(object.ref.spawnable.deviceClassName)
        local isElevatorFloorTerminal = className == ELEVATOR_FLOOR_TERMINAL_CONTROLLER_CLASS

        if isElevatorFloorTerminal then
            if type(psData) ~= "table" then
                addMissingElevatorFloorSetupIssue(object, "Persistent data is missing")
            elseif type(psData.elevatorFloorSetup) ~= "table" then
                addMissingElevatorFloorSetupIssue(object, "persistentState.Data.elevatorFloorSetup is missing")
            end
        end

        if psData then
            local PSID = PersistentID.ForComponent(entEntityID.new({ hash = loadstring("return " .. hash .. "ULL", "")() }), object.ref.spawnable.controllerComponent):ToHash()
            PSID = tostring(PSID):gsub("ULL", "")

            psEntries[PSID] = {
                PSID = PSID,
                instanceData = psData
            }
        end
    end
end

local function buildMarkingRefMap(spotNodes)
    local markingRefMap = {}

    for _, node in pairs(spotNodes) do
        for _, marking in pairs(node.markings or {}) do
            if not markingRefMap[marking] then
                markingRefMap[marking] = {}
            end
            table.insert(markingRefMap[marking], node.ref)
        end
    end

    return markingRefMap
end

local function hasEntryPhase(entry, phase)
    for _, entryPhase in pairs(entry.phases) do
        if entryPhase.phaseName == phase then
            return true
        end
    end

    return false
end

function exportUI.handleCommunities(projectName, communities, spotNodes, nodeRefs)
    local wsPersistentData = {}
    local registryEntries = {}
    local periodEnums = utils.enumTable("communityECommunitySpawnTime")
    local markingRefMap = buildMarkingRefMap(spotNodes)

    -- Collect all spots for workspotsPersistentData
    for _, node in pairs(spotNodes) do
        table.insert(wsPersistentData, {
            ["$type"] = "AISpotPersistentData",
            ["globalNodeId"] = {
                ["$type"] = "worldGlobalNodeID",
                ["hash"] = utils.nodeRefStringToHashString(node.ref)
            },
            ["isEnabled"] = 1,
            ["worldPosition"] = {
                ["$type"] = "WorldPosition",
                ["x"] = {
                    ["$type"] = "FixedPoint",
                    ["Bits"] = math.floor(node.position.x * 131072)
                },
                ["y"] = {
                    ["$type"] = "FixedPoint",
                    ["Bits"] = math.floor(node.position.y * 131072)
                },
                ["z"] = {
                    ["$type"] = "FixedPoint",
                    ["Bits"] = math.floor(node.position.z * 131072)
                }
            },
            ["yaw"] = node.yaw
        })

        if node.ref == "" then
            table.insert(exportUI.exportIssues.spotEmptyRef, node.name)
        end
    end

    -- Generate registry entry, and resolve markings to nodeRefs
    for _, community in pairs(communities) do
        local initialStates = {}
        local entries = {}

        for entryKey, entry in pairs(community.data) do
            table.insert(initialStates, {
                ["$type"] = "worldCommunityEntryInitialState",
                ["entryActiveOnStart"] = entry.entryActiveOnStart and 1 or 0,
                ["entryName"] = {
                    ["$type"] = "CName",
                    ["$storage"] = "string",
                    ["$value"] = entry.entryName
                },
                ["initialPhaseName"] = {
                    ["$type"] = "CName",
                    ["$storage"] = "string",
                    ["$value"] = entry.initialPhaseName
                }
            })

            if not hasEntryPhase(entry, entry.initialPhaseName) then
                table.insert(exportUI.exportIssues.missingInitialPhase, {
                    name = community.node.name,
                    entry = entry.entryName,
                    phase = entry.initialPhaseName
                })
            end

            local phases = {}

            for phaseKey, phase in pairs(entry.phases) do
                local appearances = {}
                for _, appearance in pairs(phase.appearances) do
                    table.insert(appearances, {
                        ["$type"] = "CName",
                        ["$storage"] = "string",
                        ["$value"] = appearance
                    })
                end

                local periods = {}

                for periodKey, period in pairs(phase.timePeriods) do
                    local markings = {}
                    local spotRefs = {}
                    if #period.markings > 0 then
                        local exportedPeriod = community.node.data.area.Data.entriesData[entryKey].phasesData[phaseKey].timePeriodsData[periodKey]
                        exportedPeriod.spotNodeIds = {}

                        for _, marking in pairs(period.markings) do
                            table.insert(markings, {
                                ["$type"] = "CName",
                                ["$storage"] = "string",
                                ["$value"] = marking
                            })

                            -- Update spotRefs on communityAreaNode, resolved from cached marking lookup.
                            local refs = markingRefMap[marking] or {}
                            for _, refValue in pairs(refs) do
                                table.insert(spotRefs, {
                                    ["$type"] = "NodeRef",
                                    ["$storage"] = "string",
                                    ["$value"] = refValue
                                })
                                table.insert(exportedPeriod.spotNodeIds, {
                                    ["$type"] = "worldGlobalNodeID",
                                    ["hash"] = utils.nodeRefStringToHashString(refValue)
                                })
                            end

                            if #refs == 0 then
                                table.insert(exportUI.exportIssues.markingUnresolved, {
                                    name = community.node.name,
                                    entry = entry.entryName,
                                    phase = phase.phaseName,
                                    period = periodEnums[period.hour + 1],
                                    marking = marking
                                })
                            end
                        end
                    else
                        for _, ref in pairs(period.spotNodeRefs) do
                            table.insert(spotRefs, {
                                ["$type"] = "NodeRef",
                                ["$storage"] = "string",
                                ["$value"] = ref
                            })
                            if not nodeRefs[ref] then
                                table.insert(exportUI.exportIssues.spotReferencingEmpty, {
                                    name = community.node.name,
                                    entry = entry.entryName,
                                    phase = phase.phaseName,
                                    period = periodEnums[period.hour + 1],
                                    ref = ref
                                })
                            end
                        end
                    end

                    table.insert(periods, {
                        ["$type"] = "communityPhaseTimePeriod",
                        ["hour"] = periodEnums[period.hour + 1],
                        ["isSequence"] = period.isSequence and 1 or 0,
                        ["markings"] = markings,
                        ["quantity"] = period.quantity,
                        ["spotNodeRefs"] = spotRefs
                    })
                end

                table.insert(phases, {
                    ["Data"] = {
                        ["$type"] = "communitySpawnPhase",
                        ["appearances"] = appearances,
                        ["phaseName"] = {
                            ["$type"] = "CName",
                            ["$storage"] = "string",
                            ["$value"] = phase.phaseName
                        },
                        ["timePeriods"] = periods
                    }
                  })
            end

            table.insert(entries, {
                ["Data"] = {
                    ["$type"] = "communitySpawnEntry",
                    ["characterRecordId"] = {
                        ["$type"] = "TweakDBID",
                        ["$storage"] = "string",
                        ["$value"] = entry.characterRecordId
                    },
                    ["entryName"] = {
                        ["$type"] = "CName",
                        ["$storage"] = "string",
                        ["$value"] = entry.entryName
                    },
                    ["phases"] = phases,
                }
            })
        end

        table.insert(registryEntries, {
            ["$type"] = "worldCommunityRegistryItem",
            ["communityAreaType"] = "Regular",
            ["communityId"] = {
                ["$type"] = "gameCommunityID",
                ["entityId"] = {
                    ["$type"] = "entEntityID",
                    ["hash"] = utils.nodeRefStringToHashString(community.node.nodeRef)
                }
            },
            ["entriesInitialState"] = initialStates,
            ["template"] = {
                ["Data"] = {
                    ["$type"] = "communityCommunityTemplateData",
                    ["entries"] = entries
                }
            }
        })
    end

    if #wsPersistentData == 0 and #registryEntries == 0 then return end

    return {
        name = projectName .. "_always_loaded",
        min = { x = -99999, y = -99999, z = -99999 },
        max = { x = 99999, y = 99999, z = 99999 },
        category = "AlwaysLoaded",
        level = 1,
        nodes = {
            {
                ["scale"] = {
                    ["x"] = 1,
                    ["y"] = 1,
                    ["z"] = 1
                },
                ["data"] = {
                    ["workspotsPersistentData"] = wsPersistentData,
                    ["communitiesData"] = registryEntries
                },
                ["name"] = "registry",
                ["position"] = {
                    ["x"] = 0,
                    ["y"] = 0,
                    ["w"] = 0,
                    ["z"] = 0
                },
                ["rotation"] = {
                    ["j"] = 0,
                    ["k"] = 0,
                    ["i"] = 0,
                    ["r"] = 0
                },
                ["primaryRange"] = 99999999,
                ["secondaryRange"] = 17.320507,
                ["uk11"] = 512,
                ["type"] = "worldCommunityRegistryNode",
                ["nodeRef"] = "",
                ["uk10"] = 32
            }
        }
    }
end

local function shouldExportNode(node)
    return not settings.ignoreHiddenDuringExport and (not utils.isA(node.parent, "randomizedGroup") or node.visible) or node.visible
end

function exportUI.exportGroup(group)
    if not config.fileExists("data/objects/" .. group.name .. ".json") then return end

    local data = config.loadFile("data/objects/" .. group.name .. ".json")

    local g = require("modules/classes/editor/positionableGroup"):new(exportUI.spawner.baseUI.spawnedUI)
    g:load(data, true)

    local center = g:getPosition()
    local min = { x = center.x - group.streamingX, y = center.y - group.streamingY, z = center.z - group.streamingZ }
    local max = { x = center.x + group.streamingX, y = center.y + group.streamingY, z = center.z + group.streamingZ }

    local exported = {
        name = utils.createFileName(group.name):lower():gsub(" ", "_"),
        min = min,
        max = max,
        category = sectorCategory[group.category + 1],
        level = group.level,
        nodes = {},
        prefabRef = group.prefabRef,
        variantIndices = { 0 },
        variants = {}
    }

    local devices = {}
    local psEntries = {}
    local childs = {}
    local communities = {}
    local spotNodes = {}

    local variantNodes = {
        default = {}
    }
    local variantInfo = {}
    local nodes = {}
    local rootChildByName = {}

    for _, node in pairs(g.childs) do
        rootChildByName[node.name] = node
    end

    -- Group and bring the nodes in order, based on their variant, starting with default
    for groupName, variant in pairs(group.variantData) do
        local variantName = normalizeVariantName(variant.name)

        if not variantNodes[variantName] then
            variantNodes[variantName] = {}
            variantInfo[variantName] = {
                defaultOn = variant.defaultOn
            }
        end

        local node = rootChildByName[groupName]
        if node then
            for _, entry in pairs(node:getPathsRecursive(false)) do
                if utils.isA(entry.ref, "spawnableElement") and not entry.ref.spawnable.noExport and shouldExportNode(entry.ref) then
                    table.insert(variantNodes[variantName], entry)
                end
            end
        end
    end

    for _, node in pairs(g.childs) do
        if utils.isA(node, "spawnableElement") and not node.spawnable.noExport and shouldExportNode(node) then
            table.insert(variantNodes["default"], { ref = node })
        end
    end

    nodes = variantNodes["default"]

    local index = 1
    for key, variant in pairs(variantNodes) do
        if key ~= "default" then
            table.insert(exported.variantIndices, #nodes)
            utils.combine(nodes, variant)

            table.insert(exported.variants, {
                name = key,
                index = index,
                defaultOn = variantInfo[key].defaultOn and 1 or 0,
                ref = group.variantRef
            })

            index = index + 1
        end
    end

    local nodeRefMap = {}
    for _, object in ipairs(nodes) do
        if utils.isA(object.ref, "spawnableElement") and object.ref.spawnable and object.ref.spawnable.nodeRef and object.ref.spawnable.nodeRef ~= "" then
            nodeRefMap[object.ref.spawnable.nodeRef] = object
        end
    end

    local nodeCount = #nodes
    for key, object in ipairs(nodes) do
        if utils.isA(object.ref, "spawnableElement") and not object.ref.spawnable.noExport and shouldExportNode(object.ref) then
            table.insert(exported.nodes, object.ref.spawnable:export(key, nodeCount))

            -- Handle device nodes
            if object.ref.spawnable.node == "worldDeviceNode" then
                exportUI.handleDevice(object, devices, psEntries, childs, nodeRefMap)
            elseif object.ref.spawnable.node == "worldCompiledCommunityAreaNode_Streamable" then
                table.insert(communities, { data = object.ref.spawnable.entries, node = exported.nodes[#exported.nodes] })
            elseif object.ref.spawnable.node == "worldAISpotNode" then
                table.insert(spotNodes, {
                    ref = object.ref.spawnable.nodeRef,
                    position = utils.fromVector(object.ref:getPosition()),
                    yaw = object.ref.spawnable.rotation.yaw,
                    markings = object.ref.spawnable.markings,
                    name = object.ref.name
                })
            end
        end
    end

    return exported, devices, psEntries, childs, communities, spotNodes
end

local function collectMissingSplineNodeRefs(nodes)
    for _, node in ipairs(nodes or {}) do
        local nodeRef = node.nodeRef or ""

        if node.type == "worldSplineNode" and nodeRef == "" then
            local name = tostring(node.name or "Unnamed Spline"):gsub("^%[Spline%]%s*", "")
            table.insert(exportUI.exportIssues.splineEmptyRef, name)
        end
    end
end

local function collectDuplicateNodeRefs(nodeRefs, nodes)
    for _, node in ipairs(nodes or {}) do
        local nodeRef = node.nodeRef or ""
        if not nodeRefs[nodeRef] then
            nodeRefs[nodeRef] = node.name
        elseif nodeRef ~= "" then
            table.insert(exportUI.exportIssues.nodeRefDuplicated, {
                nodeRef = nodeRef,
                name1 = nodeRefs[nodeRef],
                name2 = node.name
            })
            break
        end
    end
end

---@param mode string?
function exportUI.export(mode)
    if groupExportManager.isActive() then
        return
    end

    local exportMode = mode == "incremental" and "incremental" or "full"
    exportUI.resetIssues()

    if not sectorCategory then
        sectorCategory = utils.enumTable("worldStreamingSectorCategory")
    end

    groupExportManager.start({
        spawner = exportUI.spawner,
        projectName = exportUI.projectName,
        xlFormat = exportUI.xlFormat,
        version = minScriptVersion,
        groups = exportUI.groups,
        sectorCategory = sectorCategory,
        shouldExportNode = shouldExportNode,
        handleDevice = exportUI.handleDevice,
        handleCommunities = exportUI.handleCommunities,
        collectMissingSplineNodeRefs = collectMissingSplineNodeRefs,
        collectDuplicateNodeRefs = collectDuplicateNodeRefs,
        hasBlockingIssues = exportUI.hasBlockingIssues,
        mode = exportMode,
        ignoreHiddenDuringExport = settings.ignoreHiddenDuringExport == true
    })
end

return exportUI
