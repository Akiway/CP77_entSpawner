local style = require("modules/ui/style")
local settings = require("modules/utils/settings")
local field = require("modules/utils/field")
local cache = require("modules/utils/cache")
local utils = require("modules/utils/utils")
local perf = require("modules/utils/perf")

local colliderColors = { "Red", "Green", "Blue" }
local outlineColors = { "Green", "Red", "Blue", "Orange", "Yellow", "Light Blue", "White", "Black" }
local windowNames = { "World Builder", "Object Spawner", "Entity Spawner", "World Additor", "World Editing Toolkit", "World Editor", "WheezeKit", "Buildy McBuildface", "Keanus Editing Kit (Kek)", "Redkit at home" }
local groupLoadSpeedOptions = { "Fast - with FPS drops", "Slow - without FPS drops" }
local wireframeColorStyles = { "Darker + white text", "Lighter + black text" }
local colorPickerStyles = { "Hue Bar", "Hue Wheel" }
local wireframeColorStyleTooltipText = "Global projected wireframe color style used by streaming distance and streaming box overlays."
local materials = { "meatbag.physmat","linoleum.physmat","trash.physmat","plastic.physmat","character_armor.physmat","furniture_upholstery.physmat","metal_transparent.physmat","tire_car.physmat","meat.physmat","metal_car_pipe_steam.physmat","character_flesh.physmat","brick.physmat","character_flesh_head.physmat","leaves.physmat","flesh.physmat","water.physmat","plastic_road.physmat","metal_hollow.physmat","cyberware_flesh.physmat","plaster.physmat","plexiglass.physmat","character_vr.physmat","vehicle_chassis.physmat","sand.physmat","glass_electronics.physmat","leaves_stealth.physmat","tarmac.physmat","metal_car.physmat","tiles.physmat","glass_car.physmat","grass.physmat","concrete.physmat","carpet_techpiercable.physmat","wood_hedge.physmat","stone.physmat","leaves_semitransparent.physmat","metal_catwalk.physmat","upholstery_car.physmat","cyberware_metal.physmat","paper.physmat","leather.physmat","metal_pipe_steam.physmat","metal_pipe_water.physmat","metal_semitransparent.physmat","neon.physmat","glass_dst.physmat","plastic_car.physmat","mud.physmat","dirt.physmat","metal_car_pipe_water.physmat","furniture_leather.physmat","asphalt.physmat","wood_bamboo_poles.physmat","glass_opaque.physmat","carpet.physmat","food.physmat","cyberware_metal_head.physmat","metal_road.physmat","wood_tree.physmat","wood_player_npc_semitransparent.physmat","wood.physmat","metal_car_ricochet.physmat","cardboard.physmat","wood_crown.physmat","metal_ricochet.physmat","plastic_electronics.physmat","glass_semitransparent.physmat","metal_painted.physmat","rubber.physmat","ceramic.physmat","glass_bulletproof.physmat","metal_car_electronics.physmat","trash_bag.physmat","character_cyberflesh.physmat","metal_heavypiercable.physmat","metal.physmat","plastic_car_electronics.physmat","oil_spill.physmat","fabrics.physmat","glass.physmat","metal_techpiercable.physmat","concrete_water_puddles.physmat","character_metal.physmat" }
table.sort(materials, function(a, b) return a < b end)

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
        { color = 0xFF007F00, textColor = 0xFFDCD8D1 }, -- darker green
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

    for _, entry in ipairs(spawnedUI.selectedPaths) do
        local element = entry.ref

        if utils.isA(element, "positionable") then
            local keepVisible = false

            if settings.gizmoActive then
                keepVisible = element.hovered or element.controlsHovered or (settings.gizmoOnSelected and selectedCount == 1)
            end

            element:setVisualizerState(keepVisible)
            if not keepVisible then
                element:setVisualizerDirection("none")
            end
        end

        if utils.isA(element, "spawnableElement") and element.spawnable and element.spawnable:isSpawned() then
            local outline = settings.outlineSelected and element.selected and (settings.outlineColor + 1) or 0
            element.spawnable:setOutline(outline)
        end
    end
end

---@param spawner spawner
function settingsUI.draw(spawner)
    ImGui.PushItemWidth(120 * style.viewSize)

    if ImGui.TreeNodeEx("Spawning", ImGuiTreeNodeFlags.SpanFullWidth) then
        local pos, changed = ImGui.Combo("##spawnPos", settings.spawnPos - 1, { "At selected", "Screen center" }, 2)
        settings.spawnPos = pos + 1
        if changed then settings.save() end
        if settings.spawnPos == 1 then
            style.tooltip("Spawn the new object at the position of the selected object(s), if none are selected, it will spawn in front of the player")
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

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Editing", ImGuiTreeNodeFlags.SpanFullWidth) then
        if ImGui.RadioButton("Make cloned group original groups child", settings.moveCloneToParent == 1) then
            settings.moveCloneToParent = 1
            settings.save()
        end
        style.tooltip("When cloning a group, place the newly created group inside the original one")

        ImGui.SameLine()

        if ImGui.RadioButton("Move cloned group to groups parent", settings.moveCloneToParent == 2) then
            settings.moveCloneToParent = 2
            settings.save()
        end
        style.tooltip("When cloning a group, place the newly created group at the same level as the the one it was cloned from")

        settings.draggingThreshold, changed = ImGui.InputFloat("Dragging Threshold", settings.draggingThreshold, 0, 100, "%.1f")
        if changed then
            style.initialize(true)
            settings.save()
        end
        style.tooltip("A threshold for all dragging operations, such as the ones in the scene hierarchy.")

        settings.nodeRefPrefix, changed = ImGui.InputTextWithHint("NodeRef Prefix", "", settings.nodeRefPrefix, 128)
        if changed then settings.save() end
        style.tooltip("Prefix to add when auto generating NodeRef")

        settings.defaultColliderMaterial, changed = ImGui.Combo("Default Collider Material", settings.defaultColliderMaterial, materials, #materials)
        if changed then settings.save() end

        local colorPickerStyle = math.max(1, math.min(#colorPickerStyles, tonumber(settings.colorPickerStyle) or 2))
        local colorPickerStyleIndex, colorPickerStyleChanged = ImGui.Combo("Color Picker style", colorPickerStyle - 1, colorPickerStyles, #colorPickerStyles)
        if colorPickerStyleChanged then
            settings.colorPickerStyle = colorPickerStyleIndex + 1
            settings.save()
        end
        style.tooltip("Global style used by all color editors.")

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("TRANSFORM")
        settings.posSteps, changed = ImGui.InputFloat("Position controls step size", settings.posSteps, -9999, 9999, "%.4f")
        if changed then settings.save() end

        settings.rotSteps, changed = ImGui.InputFloat("Rotation controls step size", settings.rotSteps, -9999, 9999, "%.4f")
        if changed then settings.save() end

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

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Editor Mode", ImGuiTreeNodeFlags.SpanFullWidth) then
        style.pushGreyedOut(not spawner.editor.active)
        if ImGui.Button("Reset camera position") and spawner.editor.active then
            if spawner.editor.camera and spawner.editor.camera.resetPosition and spawner.editor.camera.resetPosition() then
                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Camera position reset"))
            end
        end
        style.popGreyedOut(not spawner.editor.active)
        style.tooltip("Move the 3D-Editor camera back to your player position from before entering editor mode.")

        settings.cameraMovementSpeed, changed = ImGui.InputFloat("Camera Movement Speed", settings.cameraMovementSpeed, 0, 10, "%.2f")
        if changed then settings.save() end

        settings.cameraRotateSpeed, changed = ImGui.InputFloat("Camera Rotation Speed", settings.cameraRotateSpeed, 0, 10, "%.2f")
        if changed then settings.save() end

        settings.cameraZoomSpeed, changed = ImGui.InputFloat("Camera Zoom Speed", settings.cameraZoomSpeed, 0, 10, "%.2f")
        if changed then settings.save() end

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Visualizers", ImGuiTreeNodeFlags.SpanFullWidth) then
        settings.gizmoActive, changed = ImGui.Checkbox("Show arrows", settings.gizmoActive)
        if changed then
            settings.save()
            refreshSelectedVisualizers(spawner)
        end
        style.tooltip("Globally enable or disable the arrows")

        ImGui.BeginDisabled(not settings.gizmoActive)
        settings.gizmoOnSelected, changed = ImGui.Checkbox("Keep arrows when element is selected", settings.gizmoOnSelected)
        if changed then
            settings.save()
            refreshSelectedVisualizers(spawner)
        end
        style.tooltip("Always show the arrows when an element is selected.\nWhen disabled, arrows are only shown while hovering the element or its transform controls.")
        ImGui.EndDisabled()

        settings.outlineSelected, changed = ImGui.Checkbox("Outline selected", settings.outlineSelected)
        if changed then
            settings.save()
            refreshSelectedVisualizers(spawner)
        end
        style.tooltip("Outline the selected element(s) with a color.")

        settings.outlineColor, changed = ImGui.Combo("Outline color", settings.outlineColor, outlineColors, #outlineColors)
        if changed then
            settings.save()
            refreshSelectedVisualizers(spawner)
        end

        settings.groupWireframeEnabled, changed = ImGui.Checkbox("Show Group Wireframe", settings.groupWireframeEnabled)
        if changed then settings.save() end
        style.tooltip("Only visible in 3D-Editor mode, show boundaries and origin of selected group with a colored outline.")

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("AI SPOT PREVIEW")
        settings.defaultAISpotNPC, changed = ImGui.InputTextWithHint("Default AI Spot NPC", "Character.", settings.defaultAISpotNPC, 128)
        if changed then
            settings.defaultAISpotNPC = string.gsub(settings.defaultAISpotNPC, "[\128-\255]", "")
            settings.save()
        end

        settings.defaultAISpotSpeed, changed = ImGui.InputFloat("Default AI Spot Animation Speed", settings.defaultAISpotSpeed, 0, 25, "%.1f")
        if changed then settings.save() end
        style.sectionHeaderEnd()

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("SPLINE PREVIEW")
        settings.defaultSplineCurveQuality, changed = ImGui.InputInt("Default Curve Quality", settings.defaultSplineCurveQuality, 1, 1)
        if changed then
            settings.defaultSplineCurveQuality = math.max(8, math.min(24, math.floor(settings.defaultSplineCurveQuality)))
            settings.save()
        end
        style.tooltip("Default number of samples used for spline curve preview (8-24).")
        style.sectionHeaderEnd()

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("COLLIDERS")
        settings.colliderColor, changed = ImGui.Combo("Collider color", settings.colliderColor, colliderColors, #colliderColors)
        if changed then settings.save() end
        style.sectionHeaderEnd()

        ImGui.Dummy(0, 8 * style.viewSize)
        style.sectionHeaderStart("Wireframe")
        local wireframeColorStyle = math.max(1, math.min(#wireframeColorStyles, settings.wireframeColorStyle or 1))
        local wireframeColorStyleIndex, wireframeColorStyleChanged = ImGui.Combo("Wireframe color style", wireframeColorStyle - 1, wireframeColorStyles, #wireframeColorStyles)
        if wireframeColorStyleChanged then
            settings.wireframeColorStyle = wireframeColorStyleIndex + 1
            settings.save()
        end
        drawWireframeColorStyleTooltip()
        style.sectionHeaderEnd()

        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Misc", ImGuiTreeNodeFlags.SpanFullWidth) then
        settings.headerState, changed = ImGui.Checkbox("Close collapsible headers by default", settings.headerState)
        if changed then settings.save() end

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

        local index, indexChanged = ImGui.Combo("Main Window Name", math.max(0, utils.indexValue(windowNames, settings.mainWindowName) - 1), windowNames, #windowNames)
        if indexChanged then
            settings.mainWindowName = windowNames[index + 1]
            spawner.baseUI.restoreWindowPosition = true
            spawner.baseUI.loadTabSize = true
            settings.save()
        end

        ImGui.TreePop()
    end

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

        ImGui.TreePop()
    end

    ImGui.PopItemWidth()
end

return settingsUI
