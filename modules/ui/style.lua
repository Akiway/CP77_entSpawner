-- Most of the colors and style has been taken from https://github.com/psiberx/cp2077-red-hot-tools

local history = require("modules/utils/history")
local settings = require("modules/utils/settings")
local utils = require("modules/utils/utils")
local dragBeingEdited = false
local maxLightChannelsWidth = nil
local maxTriggerChannelsWidth = nil

local style = {
    mutedColor = 0xFFA5A19B,
    extraMutedColor = 0x96A5A19B,
    highlightColor = 0xFFDCD8D1,
    activeColor = 0xFFB2FF00,
    selectedColor = 0xFFFF9900,
    warnColor = 0xFF0099FF,
    successColor = 0xFF007F00,
    activeTextColor = 0xFF000000,
    elementIndent = 35,
    draggedColor = 0xFF00007F,
    targetedColor = 0xFF00007F,
    regularColor = 0xFFFFFFFF,
    greyedColor = 0xff777777,
}

local initialized = false

---@param lhs number?
---@param rhs number?
---@return number?
local function combineImGuiFlags(lhs, rhs)
    if lhs == nil then return rhs end
    if rhs == nil then return lhs end

    if bit32 and bit32.bor then
        return bit32.bor(lhs, rhs)
    end

    if bit and bit.bor then
        return bit.bor(lhs, rhs)
    end

    return lhs + rhs
end

---@return number?
local function getColorPickerStyleFlag()
    local flags = ImGuiColorEditFlags
    if not flags then
        return nil
    end

    local pickerStyle = tonumber(settings.colorPickerStyle) or 2
    if pickerStyle == 2 then
        return flags.PickerHueWheel
    end

    return flags.PickerHueBar
end

---Clamp a numeric value to an inclusive range.
---@param value number Value to clamp.
---@param minValue number Lower bound.
---@param maxValue number Upper bound.
---@return number clampedValue
local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(value, maxValue))
end

---Get current display resolution.
---@return number width
---@return number height
local function getDisplaySize()
    local width, height = GetDisplayResolution()
    return width, height
end

---Set next window position while keeping it on screen.
---@param x number Desired X position in pixels.
---@param y number Desired Y position in pixels.
---@param width number Window width in pixels.
---@param height number Window height in pixels.
---@param cond number? Optional ImGui condition (defaults to `ImGuiCond.Always`).
local function setNextWindowPosClamped(x, y, width, height, cond)
    local screenWidth, screenHeight = getDisplaySize()
    local margin = 8

    local maxX = math.max(margin, screenWidth - width - margin)
    local maxY = math.max(margin, screenHeight - height - margin)

    ImGui.SetNextWindowPos(clamp(x, margin, maxX), clamp(y, margin, maxY), cond or ImGuiCond.Always)
end

---Estimate tooltip window size from text and default tooltip padding.
---@param text string? Tooltip text.
---@return number width
---@return number height
local function getTooltipSize(text)
    local textWidth, textHeight = ImGui.CalcTextSize(text or "")
    local padding = ImGui.GetStyle().WindowPadding

    return textWidth + (padding.x * 2), textHeight + (padding.y * 2)
end

---Place next tooltip window near the mouse cursor with view-size scaling.
---@param text string? Tooltip text used for size estimation.
---@param offsetX number Horizontal offset in view-space units.
---@param offsetY number Vertical offset in view-space units.
---@param cond number? Optional ImGui condition for SetNextWindowPos.
local function placeTooltipNearCursor(text, offsetX, offsetY, cond)
    local scale = style.viewSize or 1
    local mouseX, mouseY = ImGui.GetMousePos()
    local tooltipWidth, tooltipHeight = getTooltipSize(text)

    setNextWindowPosClamped(mouseX + offsetX * scale, mouseY + offsetY * scale, tooltipWidth, tooltipHeight, cond)
end

---Initialize runtime style scaling values.
---@param force boolean? Recompute even if already initialized.
function style.initialize(force)
    if not force and initialized then return end
    style.viewSize = ImGui.GetFontSize() / 15
    initialized = true

    local _, height = GetDisplayResolution()
    local factor = height / 1440

    style.draggingThreshold = settings.draggingThreshold * factor
end

---Push muted colors for buttons and frame widgets when `state` is true.
---Call `style.popGreyedOut` with the same condition to keep the stack balanced.
---@param state boolean Whether to push greyed-out colors.
function style.pushGreyedOut(state)
    if not state then return end

    ImGui.PushStyleColor(ImGuiCol.Button, style.greyedColor)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, style.greyedColor)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, style.greyedColor)

    ImGui.PushStyleColor(ImGuiCol.FrameBg, style.greyedColor)
    ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, style.greyedColor)
    ImGui.PushStyleColor(ImGuiCol.FrameBgActive, style.greyedColor)
end

---Pop greyed-out colors pushed by `style.pushGreyedOut`.
---@param state boolean Same condition passed to `style.pushGreyedOut`.
function style.popGreyedOut(state)
    if not state then return end

    ImGui.PopStyleColor(6)
end

---Conditionally push a style color entry.
---@param state boolean If false, does nothing.
---@param style number ImGui color enum (`ImGuiCol.*`).
---@param ... any Color value(s) accepted by `ImGui.PushStyleColor`.
function style.pushStyleColor(state, style, ...)
    if not state then return end

    ImGui.PushStyleColor(style, ...)
end

---Conditionally push a style var entry.
---@param state boolean If false, does nothing.
---@param style number ImGui style-var enum (`ImGuiStyleVar.*`).
---@param ... any Value(s) accepted by `ImGui.PushStyleVar`.
function style.pushStyleVar(state, style, ...)
    if not state then return end

    ImGui.PushStyleVar(style, ...)
end

---Conditionally pop style var entries.
---@param state boolean If false, does nothing.
---@param count number? Number of entries to pop (default `1`).
function style.popStyleVar(state, count)
    if not state then return end

    ImGui.PopStyleVar(count or 1)
end

---Conditionally pop style color entries.
---@param state boolean If false, does nothing.
---@param count number? Number of entries to pop (default `1`).
function style.popStyleColor(state, count)
    if not state then return end

    ImGui.PopStyleColor(count or 1)
end

---Show a tooltip for the currently hovered item.
---@param text string Tooltip body text.
function style.tooltip(text)
    if ImGui.IsItemHovered() then
        placeTooltipNearCursor(text, 8, 8, ImGuiCond.Always)
        ImGui.BeginTooltip()
        ImGui.PushStyleColor(ImGuiCol.Text, style.regularColor)
        ImGui.Text(text)
        ImGui.PopStyleColor()
        ImGui.EndTooltip()
    end
end

---Position the next window relative to the mouse cursor.
---@param x number Horizontal offset in view-size units.
---@param y number Vertical offset in view-size units.
function style.setCursorRelative(x, y)
    local xC, yC = ImGui.GetMousePos()
    setNextWindowPosClamped(xC + x * style.viewSize, yC + y * style.viewSize, 1, 1, ImGuiCond.Always)
end

---Position the next window relative to the mouse cursor only when appearing.
---@param x number Horizontal offset in view-size units.
---@param y number Vertical offset in view-size units.
function style.setCursorRelativeAppearing(x, y)
    local xC, yC = ImGui.GetMousePos()
    setNextWindowPosClamped(xC + x * style.viewSize, yC + y * style.viewSize, 1, 1, ImGuiCond.Appearing)
end

---Draw spawnable metadata in a tooltip for the hovered item.
---@param info table Table containing `node`, `description`, and `previewNote`.
function style.spawnableInfo(info)
    if ImGui.IsItemHovered() then

        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 20)

        style.mutedText("Node: ")
        ImGui.Text(info.node)
        ImGui.Spacing()
        style.mutedText("Description: ")
        ImGui.Text(info.description)
        ImGui.Spacing()
        style.mutedText("Preview Note: ")
        ImGui.Text(info.previewNote)

        ImGui.EndTooltip()
    end
end

---Draw a separator wrapped by vertical spacing above and below.
function style.spacedSeparator()
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()
end

---Start a section header block with muted title styling.
---Must be paired with `style.sectionHeaderEnd`.
---@param text string Header title text.
---@param tooltip string? Optional tooltip shown when the title is hovered.
function style.sectionHeaderStart(text, tooltip)
    local useDefaultFontSize = text:match("%l") ~= nil

    ImGui.PushStyleColor(ImGuiCol.Text, style.mutedColor)
    if not useDefaultFontSize then
        ImGui.SetWindowFontScale(0.85)
    end
    ImGui.Text(text)

    if tooltip then
        style.tooltip(tooltip)
    end

    if not useDefaultFontSize then
        ImGui.SetWindowFontScale(1)
    end
    ImGui.PopStyleColor()
    ImGui.Separator()
    ImGui.Spacing()

    ImGui.BeginGroup()
    ImGui.AlignTextToFramePadding()
end

---End a section block started by `style.sectionHeaderStart`.
---@param noSpacing boolean? If true, skip trailing spacing.
function style.sectionHeaderEnd(noSpacing)
    ImGui.EndGroup()

    if not noSpacing then
        ImGui.Spacing()
        ImGui.Spacing()
    end
end

---Draw text using `style.mutedColor`.
---@param text string Text to display.
function style.mutedText(text)
    style.styledText(text, style.mutedColor)
end

---Draw text with optional color override and font scale.
---@param text string Text to display.
---@param color number? Optional color for `ImGuiCol.Text`.
---@param size number? Optional window font scale (default `1`).
function style.styledText(text, color, size)
    style.pushStyleColor(color ~= nil, ImGuiCol.Text, color)
    ImGui.SetWindowFontScale(size or 1)

    ImGui.Text(text)

    style.popStyleColor(color ~= nil)
    ImGui.SetWindowFontScale(1)
end

---Draw an icon + label row with optional offsets and aligned field position.
---@param icon string
---@param label string
---@param opts table?
---@return number rowStartY
function style.drawIconLabelRow(icon, label, opts)
    opts = opts or {}
    local rowStartY = ImGui.GetCursorPosY()
    local iconOffset = (opts.iconOffset or 4) * (style.viewSize or 1)
    local labelOffset = (opts.labelOffset or 2) * (style.viewSize or 1)

    ImGui.SetCursorPosY(rowStartY + iconOffset)
    if opts.iconColor then
        style.styledText(icon, opts.iconColor)
    else
        style.mutedText(icon)
    end
    ImGui.SameLine()
    ImGui.SetCursorPosY(rowStartY + labelOffset)
    style.mutedText(label)
    ImGui.SameLine()
    ImGui.SetCursorPosY(rowStartY)

    if opts.fieldX then
        ImGui.SetCursorPosX(opts.fieldX)
    end

    return rowStartY
end

---Push or pop a no-background button style preset.
---Use `true` before drawing buttons and `false` after.
---@param push boolean `true` to push style, `false` to pop it.
function style.pushButtonNoBG(push)
    if push then
        ImGui.PushStyleColor(ImGuiCol.Button, 0)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.2)
        ImGui.PushStyleVar(ImGuiStyleVar.ButtonTextAlign, 0.5, 0.5)
    else
        ImGui.PopStyleColor(2)
        ImGui.PopStyleVar()
    end
end

---Draw a red "danger" button.
---@param text string Button label / ID.
---@param ... any Optional size args forwarded to `ImGui.Button`.
---@return boolean clicked
function style.dangerButton(text, ...)
    ImGui.PushStyleColor(ImGuiCol.Button, 0.65, 0.15, 0.15, 1.0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.80, 0.20, 0.20, 1.0)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.55, 0.10, 0.10, 1.0)
    local clicked = ImGui.Button(text, ...)
    ImGui.PopStyleColor(3)
    return clicked
end

---Draw an orange warning button.
---@param text string Button label / ID.
---@param ... any Optional size args forwarded to `ImGui.Button`.
---@return boolean clicked
function style.warnButton(text, ...)
    local rgb = style.warnColor % 0x1000000
    local defaultColor = 0xCC000000 + rgb
    local activeColor = 0x99000000 + rgb
    ImGui.PushStyleColor(ImGuiCol.Button, defaultColor)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, style.warnColor)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, activeColor)
    local clicked = ImGui.Button(text, ...)
    ImGui.PopStyleColor(3)
    return clicked
end

---Draw a green button matching default wireframe green styling.
---@param text string Button label / ID.
---@param ... any Optional size args forwarded to `ImGui.Button`.
---@return boolean clicked
function style.successButton(text, ...)
    local rgb = style.successColor % 0x1000000
    local defaultColor = 0xCC000000 + rgb
    local activeColor = 0x99000000 + rgb
    ImGui.PushStyleColor(ImGuiCol.Button, defaultColor)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, style.successColor)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, activeColor)
    local clicked = ImGui.Button(text, ...)
    ImGui.PopStyleColor(3)
    return clicked
end

---Draw a toggle-style button and return updated state.
---@param text string Button label / ID.
---@param state boolean Current toggle state.
---@return boolean state Updated toggle state.
---@return boolean changed True when clicked.
function style.toggleButton(text, state)
    local clicked

    if state then
        -- toggled on state
        local rgb = style.activeColor % 0x1000000
        local defaultColor = 0xCC000000 + rgb
        local activeColor = 0x99000000 + rgb
        ImGui.PushStyleColor(ImGuiCol.Button, defaultColor)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, style.activeColor)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, activeColor)
        ImGui.PushStyleColor(ImGuiCol.Text, style.activeTextColor)
        clicked = ImGui.Button(text)
        ImGui.PopStyleColor(4)
    else
        -- toggled off state
        ImGui.PushStyleColor(ImGuiCol.Text, style.mutedColor)
        style.pushButtonNoBG(true)
        clicked = ImGui.Button(text)
        style.pushButtonNoBG(false)
        ImGui.PopStyleColor()
    end

    if clicked then
        return not state, true
    end

    return state, false
end

---Set next item width scaled by `style.viewSize`.
---@param width number Width in unscaled style units.
function style.setNextItemWidth(width)
    ImGui.SetNextItemWidth(width * style.viewSize)
end

---Draw a checkbox and record history when value changes.
---@param element table? Element used for undo history tracking.
---@param text string Checkbox label / ID.
---@param state boolean Current value.
---@param disabled boolean? Whether the checkbox is disabled.
---@return boolean newState
---@return boolean changed
function style.trackedCheckbox(element, text, state, disabled)
    ImGui.BeginDisabled(disabled == true)
    local newState, changed = ImGui.Checkbox(text, state)
    ImGui.EndDisabled()
    if changed then
        history.addAction(history.getElementChange(element))
    end
    return newState, changed
end

---Draw a float drag field with history tracking and clamp bounds.
---@param element table? Element used for undo history tracking.
---@param text string Widget label / ID.
---@param value number Current value.
---@param step number Drag speed.
---@param min number Minimum allowed value.
---@param max number Maximum allowed value.
---@param format string Display format (ImGui printf-style).
---@param width number? Field width in unscaled style units (default `80`).
---@return number newValue
---@return boolean changed
---@return boolean finished True when item was deactivated after edit.
function style.trackedDragFloat(element, text, value, step, min, max, format, width)
    width = width or 80
    ImGui.SetNextItemWidth(width * style.viewSize)
    local newValue, changed = ImGui.DragFloat(text, value, step, min, max, format)

    local finished = ImGui.IsItemDeactivatedAfterEdit()
	if finished then
		dragBeingEdited = false
	end
	if changed and element and not dragBeingEdited then
		history.addAction(history.getElementChange(element))
		dragBeingEdited = true
	end

    newValue = math.max(newValue, min)
    newValue = math.min(newValue, max)

    return newValue, changed, finished
end

---Draw an integer drag field with history tracking and clamp bounds.
---@param element table Element used for undo history tracking.
---@param text string Widget label / ID.
---@param value number Current value.
---@param min number Minimum allowed value.
---@param max number Maximum allowed value.
---@param width number? Field width in unscaled style units (default `80`).
---@return number newValue
---@return boolean changed
---@return boolean finished True when item was deactivated after edit.
function style.trackedDragInt(element, text, value, min, max, width)
    width = width or 80
    ImGui.SetNextItemWidth(width * style.viewSize)
    local newValue, changed = ImGui.DragFloat(text, value, 1, min, max, "%.0f")

    local finished = ImGui.IsItemDeactivatedAfterEdit()
	if finished then
		dragBeingEdited = false
	end
	if changed and not dragBeingEdited then
		history.addAction(history.getElementChange(element))
		dragBeingEdited = true
	end

    newValue = math.floor(newValue)
    newValue = math.max(newValue, min)
    newValue = math.min(newValue, max)

    return newValue, changed, finished
end

---Draw an integer slider with history tracking and clamp bounds.
---@param element table Element used for undo history tracking.
---@param text string Widget label / ID.
---@param value number Current value.
---@param min number Minimum allowed value.
---@param max number Maximum allowed value.
---@param width number? Field width in unscaled style units (default `80`).
---@return number newValue
---@return boolean changed
---@return boolean finished True when item was deactivated after edit.
function style.trackedSliderInt(element, text, value, min, max, width)
    width = width or 80
    ImGui.SetNextItemWidth(width * style.viewSize)
    local newValue, changed
    if ImGui.SliderInt then
        newValue, changed = ImGui.SliderInt(text, value, min, max)
    elseif ImGui.SliderFloat then
        newValue, changed = ImGui.SliderFloat(text, value, min, max, "%.0f")
    else
        newValue, changed = ImGui.DragFloat(text, value, 1, min, max, "%.0f")
    end

    local finished = ImGui.IsItemDeactivatedAfterEdit()
    if finished then
        dragBeingEdited = false
    end
    if changed and not dragBeingEdited then
        history.addAction(history.getElementChange(element))
        dragBeingEdited = true
    end

    newValue = math.floor(newValue)
    newValue = math.max(newValue, min)
    newValue = math.min(newValue, max)

    return newValue, changed, finished
end

---Draw a float slider with history tracking and clamp bounds.
---@param element table Element used for undo history tracking.
---@param text string Widget label / ID.
---@param value number Current value.
---@param min number Minimum allowed value.
---@param max number Maximum allowed value.
---@param format string? Display format (ImGui printf-style).
---@param width number? Field width in unscaled style units (default `80`).
---@return number newValue
---@return boolean changed
---@return boolean finished True when item was deactivated after edit.
function style.trackedSliderFloat(element, text, value, min, max, format, width)
    width = width or 80
    ImGui.SetNextItemWidth(width * style.viewSize)
    local newValue, changed
    if ImGui.SliderFloat then
        newValue, changed = ImGui.SliderFloat(text, value, min, max, format or "%.3f")
    else
        local dragStep = math.max((max - min) / 200, 0.001)
        newValue, changed = ImGui.DragFloat(text, value, dragStep, min, max, format or "%.3f")
    end

    local finished = ImGui.IsItemDeactivatedAfterEdit()
    if finished then
        dragBeingEdited = false
    end
    if changed and not dragBeingEdited then
        history.addAction(history.getElementChange(element))
        dragBeingEdited = true
    end

    newValue = math.max(newValue, min)
    newValue = math.min(newValue, max)

    return newValue, changed, finished
end

---Draw an integer input field with history tracking and clamp bounds.
---@param element table Element used for undo history tracking.
---@param text string Widget label / ID.
---@param value number Current value.
---@param min number Minimum clamp value (also used as InputInt step).
---@param max number Maximum clamp value (also used as InputInt fast step).
---@param width number? Field width in unscaled style units (default `80`).
---@return number newValue
---@return boolean changed
---@return boolean finished True when item was deactivated after edit.
function style.trackedIntInput(element, text, value, min, max, width)
    width = width or 80
    ImGui.SetNextItemWidth(width * style.viewSize)
    local newValue, changed = ImGui.InputInt(text, value, min, max)

    local finished = ImGui.IsItemDeactivatedAfterEdit()
	if finished then
		dragBeingEdited = false
	end
	if changed and not dragBeingEdited then
		history.addAction(history.getElementChange(element))
		dragBeingEdited = true
	end

    newValue = math.max(newValue, min)
    newValue = math.min(newValue, max)

    return newValue, changed, finished
end

---Draw a combo box and record history when selection changes.
---@param element table Element used for undo history tracking.
---@param text string Combo label / ID.
---@param selected number Current selected index.
---@param options table Array-like table of option labels.
---@param width number? Field width in unscaled style units (default `100`).
---@return number newValue Selected index returned by ImGui.
---@return boolean changed
function style.trackedCombo(element, text, selected, options, width)
    width = width or 100
    ImGui.SetNextItemWidth(width * style.viewSize)

    local newValue, changed = ImGui.Combo(text, selected, options, #options)

    if changed then
        history.addAction(history.getElementChange(element))
    end
    return newValue, changed
end

---Draw an RGB color editor with history tracking.
---@param element table? Element used for undo history tracking.
---@param name string Widget label / ID.
---@param color table Current color value (RGB vector/table).
---@param width number? Base field width in unscaled style units (default `80`).
---@param flags number? Optional `ImGuiColorEditFlags` bitmask.
---@return table newValue
---@return boolean changed
---@return boolean finished True when item was deactivated after edit.
function style.trackedColor(element, name, color, width, flags)
    width = width or 80
    width = width * 3 + 2 * ImGui.GetStyle().ItemSpacing.x
    ImGui.SetNextItemWidth(width * style.viewSize)

    local pickerStyleFlag = getColorPickerStyleFlag()
    local effectiveFlags = combineImGuiFlags(flags, pickerStyleFlag)

    local newValue, changed
    if effectiveFlags ~= nil then
        newValue, changed = ImGui.ColorEdit3(name, color, effectiveFlags)
    else
        newValue, changed = ImGui.ColorEdit3(name, color)
    end

    local finished = ImGui.IsItemDeactivatedAfterEdit()
	if finished then
		dragBeingEdited = false
	end
	if changed and element and not dragBeingEdited then
		history.addAction(history.getElementChange(element))
		dragBeingEdited = true
	end

    return newValue, changed, finished
end

---Draw an RGB color picker with history tracking.
---@param element table? Element used for undo history tracking.
---@param name string Widget label / ID.
---@param color table Current color value (RGB vector/table).
---@param flags number? Optional `ImGuiColorEditFlags` bitmask.
---@return table newValue
---@return boolean changed
---@return boolean finished True when item was deactivated after edit.
function style.trackedColorPicker(element, name, color, flags)
    local pickerStyleFlag = getColorPickerStyleFlag()
    local effectiveFlags = combineImGuiFlags(flags, pickerStyleFlag)

    local newValue, changed
    if effectiveFlags ~= nil then
        newValue, changed = ImGui.ColorPicker3(name, color, effectiveFlags)
    else
        newValue, changed = ImGui.ColorPicker3(name, color)
    end

    local finished = ImGui.IsItemDeactivatedAfterEdit()
    if finished then
        dragBeingEdited = false
    end
    if changed and element and not dragBeingEdited then
        history.addAction(history.getElementChange(element))
        dragBeingEdited = true
    end

    return newValue, changed, finished
end

---Draw an RGBA color editor with history tracking.
---@param element table? Element used for undo history tracking.
---@param name string Widget label / ID.
---@param color table Current color value (RGBA vector/table).
---@param width number? Base field width in unscaled style units (default `80`).
---@param flags number? Optional `ImGuiColorEditFlags` bitmask.
---@return table newValue
---@return boolean changed
---@return boolean finished True when item was deactivated after edit.
function style.trackedColorAlpha(element, name, color, width, flags)
    width = width or 80
    width = width * 4 + 3 * ImGui.GetStyle().ItemSpacing.x
    ImGui.SetNextItemWidth(width * style.viewSize)

    local pickerStyleFlag = getColorPickerStyleFlag()
    local effectiveFlags = combineImGuiFlags(flags, pickerStyleFlag)

    local newValue, changed
    if effectiveFlags ~= nil then
        newValue, changed = ImGui.ColorEdit4(name, color, effectiveFlags)
    else
        newValue, changed = ImGui.ColorEdit4(name, color)
    end

    local finished = ImGui.IsItemDeactivatedAfterEdit()
    if finished then
        dragBeingEdited = false
    end
    if changed and element and not dragBeingEdited then
        history.addAction(history.getElementChange(element))
        dragBeingEdited = true
    end

    return newValue, changed, finished
end

---Draw a text input with hint, optional auto-width, and history tracking.
---@param element table? Element used for undo history tracking.
---@param text string Widget label / ID.
---@param value string Current text.
---@param hint string Placeholder shown when empty.
---@param width number? Field width in unscaled style units.
---Use `-1` to auto-fit to remaining row width (minimum 140).
---@return string newValue
---@return boolean changed
---@return boolean finished True when item was deactivated after edit.
function style.trackedTextField(element, text, value, hint, width)
    if width == -1 then
        width = (ImGui.GetWindowContentRegionWidth() - ImGui.GetCursorPosX()) / style.viewSize
        width = math.max(width, 140)
    end

    width = width or 80
    ImGui.SetNextItemWidth(width * style.viewSize)
    local newValue, changed = ImGui.InputTextWithHint(text, hint, value, 500)

    local finished = ImGui.IsItemDeactivatedAfterEdit()
	if finished then
        newValue = string.gsub(newValue, "[\128-\255]", "")
		dragBeingEdited = false
	end
	if changed and element and not dragBeingEdited then
		history.addAction(history.getElementChange(element))
		dragBeingEdited = true
	end

    return newValue, changed, finished
end

---Get remaining content width (scaled units), clamped to a minimum.
---@param min number Minimum width in raw pixels before scaling.
---@return number width Width in style-scaled units.
function style.getMaxWidth(min)
    local width = (ImGui.GetWindowContentRegionWidth() - ImGui.GetCursorPosX())
    width = math.max(width, min)

    return width / style.viewSize
end

---@param options table
---@param baseWidth number
---@return number
local function getSearchDropdownPopupMaxWidth(options, baseWidth)
    local maxTextWidth = 0

    for _, option in pairs(options or {}) do
        local optionText = tostring(option)
        local optionWidth, _ = ImGui.CalcTextSize(optionText)
        if optionWidth > maxTextWidth then
            maxTextWidth = optionWidth
        end
    end

    local styleData = ImGui.GetStyle()
    local contentWidth = maxTextWidth
        + (2 * styleData.WindowPadding.x)
        + (2 * styleData.FramePadding.x)
        + styleData.ScrollbarSize
        + styleData.ItemSpacing.x

    local screenWidth = select(1, GetDisplayResolution()) or 0
    local screenLimit = screenWidth > 0 and (screenWidth * 0.9) or math.huge

    return math.min(math.max(baseWidth, contentWidth), screenLimit)
end

---Searchable dropdown with decoupled search text state.
---Use this when selected value and typed filter must be independent.
---@param element table? Element used for undo history tracking when selection changes.
---@param text string Combo label / ID.
---@param searchHint string Placeholder for the filter input.
---@param value string Current selected value.
---@param searchValue string Current typed filter.
---@param options table List of selectable values.
---@param width number? Combo width in unscaled style units (default `100`).
---@param matchContentWidth boolean? When true, popup max width expands up to the longest option text.
---@return string value
---@return string searchValue
---@return boolean finished
function style.trackedSearchDropdown(element, text, searchHint, value, searchValue, options, width, matchContentWidth)
    value = value or ""
    searchValue = searchValue or ""
    options = options or {}
    width = width or 100
    matchContentWidth = matchContentWidth == true

    local finished = false
    local selectedValue = tostring(value)
    local comboWidth = width * style.viewSize
    local popupMaxWidth = comboWidth

    if matchContentWidth then
        popupMaxWidth = getSearchDropdownPopupMaxWidth(options, comboWidth)
        ImGui.SetNextWindowSizeConstraints(1, 1, popupMaxWidth, 10000)
    end

    ImGui.SetNextItemWidth(comboWidth)
    if (ImGui.BeginCombo(text, value)) then
        local effectiveWidth = matchContentWidth and (popupMaxWidth / style.viewSize) or width
        local interiorWidth = effectiveWidth - (2 * ImGui.GetStyle().FramePadding.x) - 30
        searchValue, _, _ = style.trackedTextField(nil, "##search", searchValue, searchHint, interiorWidth)
        local x, _ = ImGui.GetItemRectSize()

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Close) then
            searchValue = ""
        end
        style.pushButtonNoBG(false)

        local xButton, _ = ImGui.GetItemRectSize()
        if ImGui.BeginChild("##list", x + xButton + ImGui.GetStyle().ItemSpacing.x, 120 * style.viewSize) then
            for _, option in pairs(options) do
                local optionText = tostring(option)
                if utils.safePatternMatch(optionText:lower(), searchValue:lower()) then
                    local selected = optionText == selectedValue
                    if selected then
                        local rowX, rowY = ImGui.GetCursorScreenPos()
                        local rowWidth = ImGui.GetContentRegionAvail()
                        local rowHeight = ImGui.GetFrameHeight() - (1.5 * ImGui.GetStyle().FramePadding.y)
                        local drawList = ImGui.GetWindowDrawList()
                        ImGui.ImDrawListAddRectFilled(
                            drawList,
                            rowX,
                            rowY - (0.5 * ImGui.GetStyle().FramePadding.y),
                            rowX + rowWidth,
                            rowY + rowHeight,
                            style.selectedColor,
                            3 * style.viewSize
                        )
                    end

                    if ImGui.Selectable(optionText) then
                        if element then
                            history.addAction(history.getElementChange(element))
                        end
                        value = optionText
                        finished = true
                        ImGui.CloseCurrentPopup()
                    end
                end
            end

            ImGui.EndChild()
        end

        ImGui.EndCombo()
    end

    return value, searchValue, finished
end

---Draw a no-background button only when the condition is true.
---@param condition boolean Whether to draw the button.
---@param text string Button label / ID.
---@param greyed boolean? If true, draw in greyed-out style.
---@return boolean clicked True when the button was pressed.
function style.drawNoBGConditionalButton(condition, text, greyed)
    local push = false
    local greyed = greyed ~= nil and greyed or false

    if condition then
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        style.pushGreyedOut(greyed)
        if ImGui.Button(text) then
            push = true
        end
        style.popGreyedOut(greyed)
        style.pushButtonNoBG(false)
    end

    return push
end

style.lightChannelEnum = {
    "LC_Channel1",
    "LC_Channel2",
    "LC_Channel3",
    "LC_Channel4",
    "LC_Channel5",
    "LC_Channel6",
    "LC_Channel7",
    "LC_Channel8",
    "LC_ChannelWorld",
    "LC_Character",
    "LC_Player",
    "LC_Automated"
}

style.triggerChannelEnum = {
    "TC_Default",
    "TC_Player",
    "TC_Camera",
    "TC_Human",
    "TC_SoundReverbArea",
    "TC_SoundAmbientArea",
    "TC_Quest",
    "TC_Projectiles",
    "TC_Vehicle",
    "TC_Environment",
    "TC_WaterNullArea",
    "TC_Custom0",
    "TC_Custom1",
    "TC_Custom2",
    "TC_Custom3",
    "TC_Custom4",
    "TC_Custom5",
    "TC_Custom6",
    "TC_Custom7",
    "TC_Custom8",
    "TC_Custom9",
    "TC_Custom10",
    "TC_Custom11",
    "TC_Custom12",
    "TC_Custom13",
    "TC_Custom14"
}

---Draw controls for selecting light-channel flags.
---Includes select all/none, copy, and paste actions.
---@param object table? Optional element for undo history tracking.
---@param lightChannels boolean[] Array of channel states.
---@return boolean[] lightChannels Updated channel states.
function style.drawLightChannelsSelector(object, lightChannels)
    if not maxLightChannelsWidth then
        maxLightChannelsWidth = utils.getTextMaxWidth(style.lightChannelEnum) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.PlusBoxMultipleOutline) then
        if object then history.addAction(history.getElementChange(object)) end
        for i = 1, #lightChannels do
            lightChannels[i] = true
        end
    end
    style.tooltip("Select all light channels")
    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.MinusBoxMultipleOutline) then
        if object then history.addAction(history.getElementChange(object)) end
        for i = 1, #lightChannels do
            lightChannels[i] = false
        end
    end
    style.tooltip("Deselect all light channels")
    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.ContentCopy) then
        utils.insertClipboardValue("lightChannels", utils.deepcopy(lightChannels))
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Copied light channels to the clipboard"))
    end
    style.tooltip("Copy light channels to clipboard")

    ImGui.SameLine()
    local channels = utils.getClipboardValue("lightChannels")
    style.pushGreyedOut(channels == nil)
    if ImGui.Button(IconGlyphs.ContentPaste) and channels ~= nil then
        if object then history.addAction(history.getElementChange(object)) end
        lightChannels = utils.deepcopy(channels)
    end
    style.tooltip("Paste light channels from clipboard")
    style.popGreyedOut(channels == nil)
    style.pushButtonNoBG(false)

    for key, channel in ipairs(style.lightChannelEnum) do
        style.mutedText(channel)
        ImGui.SameLine()
        ImGui.SetCursorPosX(maxLightChannelsWidth)

        if object then
            lightChannels[key], _ = style.trackedCheckbox(object, "##lightChannel" .. key, lightChannels[key])
        else
            lightChannels[key], _ = ImGui.Checkbox("##lightChannel" .. key, lightChannels[key])
        end
    end

    return lightChannels
end

---Draw controls for selecting trigger-channel flags.
---Includes select all/none, copy, and paste actions.
---@param object table? Optional element for undo history tracking.
---@param triggerChannels boolean[] Array of channel states.
---@return boolean[] triggerChannels Updated channel states.
function style.drawTriggerChannelsSelector(object, triggerChannels)
    if not maxTriggerChannelsWidth then
        maxTriggerChannelsWidth = utils.getTextMaxWidth(style.triggerChannelEnum) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.PlusBoxMultipleOutline) then
        if object then history.addAction(history.getElementChange(object)) end
        for i = 1, #triggerChannels do
            triggerChannels[i] = true
        end
    end
    style.tooltip("Select all trigger channels")
    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.MinusBoxMultipleOutline) then
        if object then history.addAction(history.getElementChange(object)) end
        for i = 1, #triggerChannels do
            triggerChannels[i] = false
        end
    end
    style.tooltip("Deselect all trigger channels")
    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.ContentCopy) then
        utils.insertClipboardValue("triggerChannels", utils.deepcopy(triggerChannels))
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, "Copied trigger channels to the clipboard"))
    end
    style.tooltip("Copy trigger channels to clipboard")

    ImGui.SameLine()
    local channels = utils.getClipboardValue("triggerChannels")
    style.pushGreyedOut(channels == nil)
    if ImGui.Button(IconGlyphs.ContentPaste) and channels ~= nil then
        if object then history.addAction(history.getElementChange(object)) end
        triggerChannels = utils.deepcopy(channels)
    end
    style.tooltip("Paste trigger channels from clipboard")
    style.popGreyedOut(channels == nil)
    style.pushButtonNoBG(false)

    for key, channel in ipairs(style.triggerChannelEnum) do
        style.mutedText(channel)
        ImGui.SameLine()
        ImGui.SetCursorPosX(maxTriggerChannelsWidth)

        if object then
            triggerChannels[key], _ = style.trackedCheckbox(object, "##triggerChannel" .. key, triggerChannels[key])
        else
            triggerChannels[key], _ = ImGui.Checkbox("##triggerChannel" .. key, triggerChannels[key])
        end
    end

    return triggerChannels
end

return style
