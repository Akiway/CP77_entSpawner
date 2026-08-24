-- Most of the colors and style has been taken from https://github.com/psiberx/cp2077-red-hot-tools

local history = require("modules/utils/project/history")
local settings = require("modules/utils/core/settings")
local utils = require("modules/utils/core/utils")
local colorUtil = require("modules/utils/ui/color")
local input = require("modules/utils/core/input")
local dragBeingEdited = false

---Records one history action per widget interaction, for every tracked widget in this module.
---
---The order is the whole point. A value typed into a drag field and committed with Enter reports
---`changed` and `finished` on the *same* frame, so clearing the flag before the changed branch let
---that frame re-arm it with nothing left to clear it. `dragBeingEdited` is shared by every tracked
---widget, so once it stuck, no widget pushed a history action again until some other field happened
---to deactivate -- and since a property edit's only dirty-marking hook is that history action, those
---edits also stopped reaching the save file.
---
---Pushing first and closing out afterwards is correct for both shapes: a multi-frame drag arms on its
---first changed frame and disarms on release, and a single-frame commit arms and disarms in one go.
---@param element table? Element to snapshot. Without one there is nothing to record.
---@param changed boolean Whether the widget reported a value change this frame.
---@param finished boolean Whether the widget was deactivated after an edit this frame.
local function trackWidgetEdit(element, changed, finished)
    if changed and element and not dragBeingEdited then
        history.addAction(history.getElementChange(element))
        dragBeingEdited = true
    end

    if finished then
        dragBeingEdited = false
    end
end

local maxLightChannelsWidth = nil
local maxTriggerChannelsWidth = nil
local DEFAULT_TAB_INACTIVE_BG = colorUtil.packAABBGGRR({ 0.08, 0.15, 0.26 }, 0.85)
local DEFAULT_TAB_INACTIVE_HOVER = colorUtil.packAABBGGRR({ 0.13, 0.30, 0.50 }, 1.0)
local DEFAULT_TAB_INACTIVE_PRESSED = colorUtil.packAABBGGRR({ 0.10, 0.24, 0.41 }, 0.95)
local DEFAULT_TAB_INACTIVE_TEXT = colorUtil.packAABBGGRR({ 0.82, 0.87, 0.93 }, 1.0)

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
    lightColorHexBadgeScrim = colorUtil.packAABBGGRR({ 0.04, 0.05, 0.07 }, 1.0),
    lightColorHexBadgeBg = colorUtil.packAABBGGRR({ 0.0, 0.0, 0.0 }, 0.0),
    lightColorHexBadgeHover = colorUtil.packAABBGGRR({ 1.0, 1.0, 1.0 }, 0.10),
    lightColorHexBadgePressed = colorUtil.packAABBGGRR({ 1.0, 1.0, 1.0 }, 0.16),
    lightRadiusIconColor = 0xFF5D9645,
    lightInnerAngleColor = 0xFF98CCE9,
    lightOuterAngleColor = 0xFFAF7838,
}

---@param optionText string
---@param optionDisplayFn fun(optionText: string): string?
---@return string
local function resolveSearchDropdownOptionLabel(optionText, optionDisplayFn)
    if type(optionDisplayFn) == "function" then
        local ok, optionLabel = pcall(optionDisplayFn, optionText)
        if ok and optionLabel ~= nil then
            return tostring(optionLabel)
        end
    end

    return optionText
end

---@param value any
---@param helperText string?
---@param showValue boolean?
---@return string?
---Strips the ImGui id suffix from a widget label. `##`/`###` and everything after them
---are not rendered by ImGui, so they must not leak into tooltips or the clipboard either.
---@param value any
---@return string
local function stripWidgetId(value)
    local text = tostring(value or "")
    local idStart = text:find("##", 1, true)

    if idStart then
        text = text:sub(1, idStart - 1)
    end

    return (text:gsub("%s+$", ""))
end

local function buildSelectorTooltip(value, helperText, showValue)
    local tooltipParts = {}

    if showValue ~= false then
        local valueText = stripWidgetId(value)
        if valueText ~= "" then
            table.insert(tooltipParts, valueText)
        end
    end

    if helperText and helperText ~= "" then
        table.insert(tooltipParts, tostring(helperText))
    end

    if #tooltipParts == 0 then
        return nil
    end

    return table.concat(tooltipParts, "\n\n")
end

---@param value any
---@param showValue boolean?
local function copySelectorValueOnMiddleClick(value, showValue)
    if showValue == false then return end

    local valueText = stripWidgetId(value)
    if valueText == "" then return end

    if ImGui.IsItemHovered() and ImGui.IsItemClicked(ImGuiMouseButton.Middle) then
        ImGui.SetClipboardText(valueText)
    end
end

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
function style.placeTooltipNearCursor(text, offsetX, offsetY, cond)
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

---Show a tooltip for an item whose hovered state was captured beforehand.
---Needed whenever something else (a context popup) is drawn between the item and its tooltip,
---as that leaves `ImGui.IsItemHovered` reporting the popup content instead of the item.
---@param hovered boolean Hovered state captured right after the item was drawn.
---@param text string Tooltip body text.
function style.tooltipHovered(hovered, text)
    if not hovered then return end

    style.placeTooltipNearCursor(text, 8, 8, ImGuiCond.Always)
    ImGui.BeginTooltip()
    ImGui.PushStyleColor(ImGuiCol.Text, style.regularColor)
    ImGui.Text(text)
    ImGui.PopStyleColor()
    ImGui.EndTooltip()
end

---Show a tooltip for the currently hovered item.
---@param text string Tooltip body text.
---@param hoveredFlags number? Optional `ImGuiHoveredFlags` bitmask, e.g. `ImGuiHoveredFlags.AllowWhenDisabled`.
function style.tooltip(text, hoveredFlags)
    local hovered
    if hoveredFlags ~= nil then
        hovered = ImGui.IsItemHovered(hoveredFlags)
    else
        hovered = ImGui.IsItemHovered()
    end

    style.tooltipHovered(hovered, text)
    copySelectorValueOnMiddleClick(currentValue)
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

---Constrain the next popup to the viewport and place it near the cursor when appearing.
---Call right before `ImGui.BeginPopup`, guarded by `ImGui.IsPopupOpen(popupId)`.
---@param popupId string Popup ID to test for.
function style.constrainPopupToViewport(popupId)
    if not ImGui.IsPopupOpen(popupId) then return end

    style.setCursorRelativeAppearing(-5, -5)

    local screenWidth, screenHeight = getDisplaySize()
    local margin = 8
    local maxWidth = math.max(200, screenWidth - margin * 2)
    local maxHeight = math.max(200, screenHeight - margin * 2)

    ImGui.SetNextWindowSizeConstraints(
        math.min(320 * style.viewSize, maxWidth),
        math.min(160 * style.viewSize, maxHeight),
        maxWidth,
        maxHeight
    )
end

---Maximum height a searchable popup may take, clamped to the current screen.
---@return number
function style.getPopupMaxHeight()
    local _, screenHeight = getDisplaySize()

    return math.max(200 * style.viewSize, math.min(520 * style.viewSize, screenHeight - 16))
end

---Draw an inline muted field label aligned to the widget that follows it.
---@param label string Label text.
function style.fieldLabel(label)
    ImGui.AlignTextToFramePadding()
    style.mutedText(label)
    ImGui.SameLine()
end

---Continue the current line, then place the cursor `offset` scaled units from the
---right window edge. Used for the trailing icon buttons of header rows.
---@param offset number Distance from the right edge, in unscaled style units.
function style.sameLineWindowRight(offset)
    ImGui.SameLine()
    ImGui.SetCursorPosX(ImGui.GetWindowWidth() - offset * style.viewSize)
end

---Move the cursor so that `width` pixels of content end up flush with the right
---edge of the current window, accounting for cell padding, scrollbar and scroll.
---@param width number Total width of the content to be drawn.
---@param yOffset number? Optional additional vertical offset in pixels.
function style.setCursorRightAligned(width, yOffset)
    local styleData = ImGui.GetStyle()
    local scrollBarAddition = ImGui.GetScrollMaxY() > 0 and styleData.ScrollbarSize or 0

    ImGui.SetCursorPosX(ImGui.GetWindowWidth() - width - styleData.CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX())

    if yOffset then
        ImGui.SetCursorPosY(ImGui.GetCursorPosY() + yOffset)
    end
end

---Push the transparent-button styling used by list row content (icons, names, cog buttons).
---Must be paired with `style.popListRowContent`.
function style.pushListRowContent()
    ImGui.PushStyleColor(ImGuiCol.Button, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.2)
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
    ImGui.PushStyleVar(ImGuiStyleVar.ButtonTextAlign, 0.5, 0.5)
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 1 * style.viewSize)
end

---Pop the styling pushed by `style.pushListRowContent`.
---@param extraStyleVars number? Extra style vars pushed by the caller inside the scope.
function style.popListRowContent(extraStyleVars)
    ImGui.PopStyleColor(2)
    ImGui.PopStyleVar(2 + (extraStyleVars or 0))
end

---Draw spawnable metadata in a tooltip for the hovered item and copy current value on middle-click.
---@param info table Table containing `node`, `description`, and `previewNote`.
---@param currentValue string? Optional selected value shown before metadata.
function style.spawnableInfo(info, currentValue)
    copySelectorValueOnMiddleClick(currentValue)

    if ImGui.IsItemHovered() then

        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 20)

        if currentValue and currentValue ~= "" then
            style.mutedText("Selected: ")
            ImGui.Text(currentValue)
            ImGui.Spacing()
        end

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

---Draw a popup title row (optional icon + text), followed by a separator.
---@param icon string? Optional leading icon glyph.
---@param text string Title text.
function style.popupTitle(icon, text)
    style.styledText(((icon ~= nil and icon ~= "") and (icon .. " ") or "") .. text, style.highlightColor)
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

-- -------------------------------------------------------------- Panel UI

-- Panel design tokens, as RGBA 0-1. Copied from the shared window library rather than required
-- from it: that library resolves its own `modules/...` paths, so requiring it from here would
-- pick up this mod's files instead.
style.panelCardBg         = { 0.65, 0.70, 1.00, 0.045 }
style.panelFrameBg        = { 0.12, 0.26, 0.42, 0.30 }
style.panelFrameBorder    = { 0.24, 0.59, 1.00, 0.35 }
-- Resting border, lifted just enough to read as "this reacts" without competing with the active
-- one. Alpha is well under the active border's so the hover stays a hint and the focused field
-- remains the loudest thing on screen.
style.panelFrameBorderHi  = { 0.45, 0.72, 1.00, 0.75 }
style.panelSplitterHover  = { 0.30, 0.50, 0.70, 0.50 }
style.panelSplitterDrag   = { 0.00, 1.00, 0.70, 0.60 }
style.panelSplitterIcon   = { 0.60, 0.60, 0.70, 1.00 }
style.panelSplitterIconHi = { 1.00, 1.00, 1.00, 1.00 }

-- Border thickness of an outlined input, shared by the resting frame and the active overdraw so
-- the two land on exactly the same pixels.
local INPUT_BORDER_SIZE = 2.0

---Push the outlined-input look: a tinted frame behind a 2px blue border. Wraps the
---widget call itself, so it applies to whatever input is drawn between push and pop.
function style.pushOutlinedInput()
    local bg = style.panelFrameBg
    local border = style.panelFrameBorder

    -- Also tints the fill drags render with, so the same pair works for any outlined control and
    -- not only a text field.
    ImGui.PushStyleColor(ImGuiCol.PlotHistogram, 0.26, 0.59, 0.98, 1.00)
    ImGui.PushStyleColor(ImGuiCol.FrameBg, bg[1], bg[2], bg[3], bg[4])
    ImGui.PushStyleColor(ImGuiCol.Border, border[1], border[2], border[3], border[4])
    ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, INPUT_BORDER_SIZE)
end

---Pop the styling pushed by `style.pushOutlinedInput`, and mark the field as active or hovered if
---it is.
---
---Must be called immediately after the widget: both borders are read off the last item.
function style.popOutlinedInput()
    ImGui.PopStyleVar(1)
    ImGui.PopStyleColor(3)

    -- ImGui has no "active border" or "hovered border" color, and the real one has to be pushed
    -- before the widget is drawn - by which point nothing knows yet whether it will take focus or
    -- the cursor. So both states are painted over the resting border afterwards instead, which also
    -- avoids the frame of lag a remembered state would cost.
    local overdraw, alpha

    if ImGui.IsItemActive() then
        -- Drawn opaque rather than at the drag bar's own alpha: that alpha is meant for a fill over
        -- the window, and letting the blue resting border show through a 2px line only muddies it.
        overdraw, alpha = style.panelSplitterDrag, 1.0
    elseif ImGui.IsItemHovered() then
        -- Hover keeps its own alpha, so the resting blue underneath softens the lift instead of
        -- replacing it outright.
        overdraw = style.panelFrameBorderHi
        alpha = overdraw[4]
    else
        return
    end

    local drawList = ImGui.GetWindowDrawList()
    if not drawList then return end

    local minX, minY = ImGui.GetItemRectMin()
    local maxX, maxY = ImGui.GetItemRectMax()

    ImGui.ImDrawListAddRect(
        drawList, minX, minY, maxX, maxY,
        ImGui.GetColorU32(overdraw[1], overdraw[2], overdraw[3], alpha),
        ImGui.GetStyle().FrameRounding, 0, INPUT_BORDER_SIZE
    )
end

---`ImGui.InputTextWithHint` in the outlined styling. The standard text field: use this rather than
---calling ImGui directly, so every simple text input in the mod carries the same design.
---@param ... any Arguments forwarded verbatim (id, hint, value, maxLength, flags?).
---@return string newValue
---@return boolean changed
function style.inputTextWithHint(...)
    style.pushOutlinedInput()
    local newValue, changed = ImGui.InputTextWithHint(...)
    style.popOutlinedInput()

    return newValue, changed
end

-- While an input is active, ImGui keeps an internal text copy and can keep showing it after the
-- external value has been emptied. Changing the widget id for one frame retires that copy.
---@type table<string, {count: integer, refocus: boolean}>
local searchInputState = {}

---@param id string
---@param refocus boolean?
function style.clearSearchInput(id, refocus)
    local entry = searchInputState[id]
    searchInputState[id] = { count = ((entry and entry.count) or 0) + 1, refocus = refocus == true }
end

---`style.inputTextWithHint` for search fields. Right-clicking a non-empty search input clears it.
---@param id string
---@param hint string
---@param value string
---@param maxLength number
---@param flags number?
---@return string newValue
---@return boolean changed
---@return boolean cleared
function style.searchInputTextWithHint(id, hint, value, maxLength, flags)
    value = tostring(value or "")

    local entry = searchInputState[id]
    if entry and entry.refocus then
        entry.refocus = false
        ImGui.SetKeyboardFocusHere()
    end

    style.pushOutlinedInput()

    local widgetId = id .. "##take" .. (entry and entry.count or 0)
    local newValue, changed
    if flags ~= nil then
        newValue, changed = ImGui.InputTextWithHint(widgetId, hint, value, maxLength, flags)
    else
        newValue, changed = ImGui.InputTextWithHint(widgetId, hint, value, maxLength)
    end

    style.popOutlinedInput()

    local cleared = false

    if newValue ~= "" and ImGui.IsItemClicked(ImGuiMouseButton.Right) then
        if ImGui.IsItemActive() then
            style.clearSearchInput(id, true)
        end

        newValue = ""
        changed = false
        cleared = true
    end

    return newValue, changed, cleared
end

---`ImGui.InputText` in the outlined styling. The hintless counterpart to
---`style.inputTextWithHint`.
---@param ... any Arguments forwarded verbatim (id, value, maxLength, flags?).
---@return string newValue
---@return boolean changed
function style.inputText(...)
    style.pushOutlinedInput()
    local newValue, changed = ImGui.InputText(...)
    style.popOutlinedInput()

    return newValue, changed
end

---Push the card fill for the next child window.
function style.pushCardBackground()
    local bg = style.panelCardBg
    ImGui.PushStyleColor(ImGuiCol.ChildBg, bg[1], bg[2], bg[3], bg[4])
end

---Pop the fill pushed by `style.pushCardBackground`.
function style.popCardBackground()
    ImGui.PopStyleColor(1)
end

-- Content height of each `height = "auto"` card, measured as it was drawn on the previous frame.
local cardAutoHeight = {}
-- Ids of the auto-height cards currently open, so `endCard` knows which one it is closing.
local cardStack = {}

---@class cardOpts
---@field width number? Child width, already scaled (default `0`, fill the region).
---@field height number|"auto"? Child height, already scaled. `0` (default) fills the region,
---`"auto"` sizes to the content as it measured on the previous frame.
---@field border boolean? Draw the child's border (default false).
---@field flags number? Extra `ImGuiWindowFlags` to combine in.

---Begin a card: a child window carrying the panel fill and window padding, so
---content sits inset from the tinted background rather than flush against it.
---
---Must always be paired with `style.endCard`, including when this returns false - `BeginChild`
---pushes a window either way.
---@param id string Child ID, `##` prefixed by the caller if it should stay out of the label.
---@param opts cardOpts?
---@return boolean visible False when the card is clipped and its content can be skipped.
function style.beginCard(id, opts)
    opts = opts or {}

    local height = opts.height or 0
    local auto = height == "auto"
    local flags = ImGuiWindowFlags.AlwaysUseWindowPadding + (opts.flags or 0)

    if auto then
        -- Nothing has been measured on the first frame. Items in a child too short to hold them
        -- are clipped but still advance the cursor, so one frame at a token height is enough to
        -- measure from - and the scroll flags keep that frame from flashing a scrollbar.
        height = cardAutoHeight[id] or 1
        flags = flags + ImGuiWindowFlags.NoScrollbar + ImGuiWindowFlags.NoScrollWithMouse
    end

    style.pushCardBackground()
    local visible = ImGui.BeginChild(id, opts.width or 0, height, opts.border == true, flags)
    style.popCardBackground()

    -- Only a card that drew its content has a height worth measuring. One scrolled out of view
    -- would otherwise measure as empty and stay collapsed once it came back.
    cardStack[#cardStack + 1] = (auto and visible) and id or false

    return visible
end

---End a card started by `style.beginCard`.
function style.endCard()
    local id = table.remove(cardStack)

    -- Measured before the child is closed, while the cursor is still in its coordinate space.
    -- The trailing item spacing is dropped and the bottom padding added back, so the fill closes
    -- the same distance below the content as it opens above it.
    if id then
        local styleData = ImGui.GetStyle()
        cardAutoHeight[id] = ImGui.GetCursorPosY() + styleData.WindowPadding.y - styleData.ItemSpacing.y
    end

    ImGui.EndChild()
end

---The splitter bar itself: transparent at rest, tinted on hover, brighter while dragged, with a
---grip glyph centred in it.
---@param childId string
---@param width number Already scaled. `0` fills the region.
---@param height number Already scaled.
---@param icon string
---@param active boolean Hovered as of the previous frame.
---@param dragging boolean
---@return boolean hovered
local function drawSplitterBar(childId, width, height, icon, active, dragging)
    local bg = dragging and style.panelSplitterDrag
        or active and style.panelSplitterHover
        or nil
    local iconColor = (active or dragging) and style.panelSplitterIconHi
        or style.panelSplitterIcon

    if bg then
        ImGui.PushStyleColor(ImGuiCol.ChildBg, bg[1], bg[2], bg[3], bg[4])
    else
        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0)
    end
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 0, 0)

    if ImGui.BeginChild(childId, width, height, false, ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoScrollbar + ImGuiWindowFlags.NoScrollWithMouse) then
        local availableX, availableY = ImGui.GetWindowSize()
        local textWidth, textHeight = ImGui.CalcTextSize(icon)

        ImGui.SetCursorPosX((availableX - textWidth) / 2)
        ImGui.SetCursorPosY((availableY - textHeight) / 2)
        ImGui.PushStyleColor(ImGuiCol.Text, iconColor[1], iconColor[2], iconColor[3], iconColor[4])
        ImGui.Text(icon)
        ImGui.PopStyleColor()
    end
    ImGui.EndChild()

    local hovered = ImGui.IsItemHovered()

    ImGui.PopStyleVar()
    ImGui.PopStyleColor()

    return hovered
end

---@class dividerState
---@field hovered boolean
---@field dragging boolean

---Horizontal drag bar for resizing the panel above it, in the splitter styling.
---
---The delta comes back in pixels rather than being applied here: what it resizes, and between
---which bounds, is the caller's to decide.
---@param id string Child ID for the bar, unique per divider.
---@param state dividerState Persistent per divider, so two bars do not report each other's hover.
---@return number delta Pixels dragged since the previous frame.
---@return boolean reset Double-clicked, so the caller should restore its default size.
function style.drawHorizontalDivider(id, state)
    local height = 7.5 * style.viewSize
    -- Read before the bar is redrawn: the double-click lands on the hover state the previous
    -- frame settled on, which is the one that says whether the cursor was over this bar.
    local reset = state.hovered and ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left)

    state.hovered = drawSplitterBar(id, 0, height, IconGlyphs.DragHorizontal, state.hovered, state.dragging)

    if state.hovered and ImGui.IsMouseDragging(0, 0) then
        state.dragging = true
    end
    if state.dragging and not ImGui.IsMouseDragging(0, 0) then
        state.dragging = false
    end

    local delta = 0
    if state.dragging then
        local _, dy = ImGui.GetMouseDragDelta(0, 0)
        delta = dy
        ImGui.ResetMouseDragDelta()
    end

    if state.hovered or state.dragging then
        ImGui.SetMouseCursor(ImGuiMouseCursor.ResizeNS)
    end

    return delta, reset
end

---Vertical drag bar, for resizing a panel beside it. The counterpart to
---`style.drawHorizontalDivider`, with the same contract.
---@param id string
---@param height number Already scaled.
---@param state dividerState
---@return number delta Pixels dragged since the previous frame.
---@return boolean reset
function style.drawVerticalDivider(id, height, state)
    local width = 7.5 * style.viewSize
    local reset = state.hovered and ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left)

    state.hovered = drawSplitterBar(id, width, height, IconGlyphs.DragVertical, state.hovered, state.dragging)

    if state.hovered and ImGui.IsMouseDragging(0, 0) then
        state.dragging = true
    end
    if state.dragging and not ImGui.IsMouseDragging(0, 0) then
        state.dragging = false
    end

    local delta = 0
    if state.dragging then
        local dx = ImGui.GetMouseDragDelta(0, 0)
        delta = dx
        ImGui.ResetMouseDragDelta()
    end

    if state.hovered or state.dragging then
        ImGui.SetMouseCursor(ImGuiMouseCursor.ResizeEW)
    end

    return delta, reset
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

---Draw wrapped text with optional color override and font scale.
---@param text string Text to display.
---@param color number? Optional color for `ImGuiCol.Text`.
---@param size number? Optional window font scale (default `1`).
function style.styledTextWrapped(text, color, size)
    style.pushStyleColor(color ~= nil, ImGuiCol.Text, color)
    ImGui.SetWindowFontScale(size or 1)

    ImGui.TextWrapped(text)

    style.popStyleColor(color ~= nil)
    ImGui.SetWindowFontScale(1)
end

style.actionLabelDisplayModes = {
    PreferIcon = 1,
    IconAndText = 2,
    PreferText = 3
}

---@param mode number?
---@return integer
function style.normalizeActionLabelMode(mode)
    local normalized = tonumber(mode) or style.actionLabelDisplayModes.IconAndText
    if normalized < style.actionLabelDisplayModes.PreferIcon or normalized > style.actionLabelDisplayModes.PreferText then
        return style.actionLabelDisplayModes.IconAndText
    end

    return math.floor(normalized)
end

---@return integer
function style.getActionLabelMode()
    return style.normalizeActionLabelMode(settings.actionLabelDisplayMode)
end

---@param mode integer?
---@return integer
function style.getActionLabelModeNoIconOnly(mode)
    local resolvedMode = mode == nil and style.getActionLabelMode() or style.normalizeActionLabelMode(mode)
    if resolvedMode == style.actionLabelDisplayModes.PreferIcon then
        return style.actionLabelDisplayModes.IconAndText
    end

    return resolvedMode
end

---@param icon string?
---@param text string?
---@param id string?
---@param mode integer?
---@param includeHiddenText boolean?
---@return string
---@return string?
function style.resolveActionLabel(icon, text, id, mode, includeHiddenText)
    local hasIcon = type(icon) == "string" and icon ~= ""
    local hasText = type(text) == "string" and text ~= ""
    local resolvedMode = mode == nil and style.getActionLabelMode() or style.normalizeActionLabelMode(mode)
    local hiddenText
    local visible = ""

    if resolvedMode == style.actionLabelDisplayModes.PreferIcon then
        if hasIcon then
            visible = icon
            if hasText then
                hiddenText = text
            end
        elseif hasText then
            visible = text
        end
    elseif resolvedMode == style.actionLabelDisplayModes.PreferText then
        if hasText then
            visible = text
        elseif hasIcon then
            visible = icon
        end
    else
        if hasIcon and hasText then
            visible = icon .. " " .. text
        elseif hasText then
            visible = text
        elseif hasIcon then
            visible = icon
        end
    end

    if includeHiddenText ~= true then
        hiddenText = nil
    end

    local resolvedLabel
    local stableId = type(id) == "string" and id or ""
    if stableId ~= "" then
        resolvedLabel = visible .. "###" .. stableId
    else
        resolvedLabel = visible
    end

    if includeHiddenText == true then
        return resolvedLabel, hiddenText
    end

    return resolvedLabel
end

---@param icon string?
---@param text string?
---@param id string?
---@param mode integer?
---@param includeHiddenText boolean?
---@return string
---@return string?
function style.resolveActionLabelNoIconOnly(icon, text, id, mode, includeHiddenText)
    local resolvedMode = style.getActionLabelModeNoIconOnly(mode)
    return style.resolveActionLabel(icon, text, id, resolvedMode, includeHiddenText)
end

---@param hiddenText string?
---@param explicitTooltip string?
function style.tooltipActionLabel(hiddenText, explicitTooltip)
    if explicitTooltip ~= nil and explicitTooltip ~= "" then
        style.tooltip(explicitTooltip)
        return
    end

    if hiddenText ~= nil and hiddenText ~= "" then
        style.tooltip(hiddenText)
    end
end

---Draw an icon + label row with optional offsets and aligned field position.
---@param icon string
---@param label string?
---@param opts table?
---@return number rowStartY
function style.drawIconLabelRow(icon, label, opts)
    ImGui.BeginGroup()
    opts = opts or {}
    local rowStartY = ImGui.GetCursorPosY()
    local iconOffset = (opts.iconOffset or 4) * (style.viewSize or 1)
    local labelOffset = (opts.labelOffset or 2) * (style.viewSize or 1)

    if icon ~= nil then
        ImGui.SetCursorPosY(rowStartY + iconOffset)
        if opts.iconColor then
            style.styledText(icon, opts.iconColor)
        else
            style.mutedText(icon)
        end
        ImGui.SameLine()
    end
    if label ~= nil then
        ImGui.SetCursorPosY(rowStartY + labelOffset)
        style.mutedText(label)
        ImGui.SameLine()
    end
    ImGui.SetCursorPosY(rowStartY)

    if opts.fieldX then
        ImGui.SetCursorPosX(opts.fieldX)
    end

    ImGui.EndGroup()
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

---@class warnButtonOpts
---@field disabled boolean? Draw as disabled and suppress click handling.
---@field tooltip string? Tooltip shown when enabled.
---@field disabledTooltip string? Tooltip shown when disabled (falls back to `tooltip` when omitted).
---@field tooltipOffsetX number? Optional cursor-relative X offset before drawing tooltip.
---@field tooltipOffsetY number? Optional cursor-relative Y offset before drawing tooltip.

---Draw an orange warning button.
---Supports optional disable state and tooltip handling through a trailing options table.
---Usage: `style.warnButton(text, [w], [h], { disabled = bool, tooltip = "...", disabledTooltip = "..." })`.
---@param text string Button label / ID.
---@param opts warnButtonOpts? Optional flags. See `warnButtonOpts` for details.
---@return boolean clicked
function style.warnButton(text, opts)
    opts = opts or {}
    local disabled = opts.disabled == true or false
    local tooltipText = disabled and opts.disabledTooltip or opts.tooltip
    local tooltipOffsetX = opts.tooltipOffsetX
    local tooltipOffsetY = opts.tooltipOffsetY

    local rgb = style.warnColor % 0x1000000
    local defaultColor = disabled and style.greyedColor or 0xCC000000 + rgb
    local hoveredColor = disabled and style.greyedColor or style.warnColor
    local activeColor = disabled and style.greyedColor or 0x99000000 + rgb
    local clicked = false

    
    ImGui.PushStyleColor(ImGuiCol.Button, defaultColor)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, hoveredColor)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, activeColor)
    clicked = ImGui.Button(text)
    ImGui.PopStyleColor(3)

    if tooltipText then
        if tooltipOffsetX and tooltipOffsetY and ImGui.IsItemHovered() then
            style.setCursorRelative(tooltipOffsetX, tooltipOffsetY)
        end
        style.tooltip(tooltipText)
    end

    return (not disabled) and clicked
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
        local borderSize = 1 * style.viewSize
        ImGui.PushStyleColor(ImGuiCol.Text, style.mutedColor)
        style.pushButtonNoBG(true)
        ImGui.PushStyleColor(ImGuiCol.Border, style.mutedColor)
        ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, borderSize)
        clicked = ImGui.Button(text)
        ImGui.PopStyleVar()
        ImGui.PopStyleColor()

        if ImGui.IsItemHovered() then
            local drawList = ImGui.GetWindowDrawList()
            local minX, minY = ImGui.GetItemRectMin()
            local maxX, maxY = ImGui.GetItemRectMax()
            local frameRounding = ImGui.GetStyle().FrameRounding or 0
            ImGui.ImDrawListAddRect(drawList, minX, minY, maxX, maxY, style.activeColor, frameRounding, 0, borderSize)
        end

        style.pushButtonNoBG(false)
        ImGui.PopStyleColor()
    end

    if clicked then
        return not state, true
    end

    return state, false
end

---Draw a segmented-tab style button with shared selected/inactive visuals.
---Use this for enum-like switch rows (for example light type or NodeRef/Marking tabs).
---@param text string Button label / ID.
---@param selected boolean Whether this tab is currently selected.
---@param width number? Optional width in pixels (already scaled if desired).
---@param height number? Optional height in pixels.
---@param opts table? Optional colors:
---`activeBg`, `activeHover`, `activePressed`, `activeText`,
---`inactiveBg`, `inactiveHover`, `inactivePressed`, `inactiveText`.
---@return boolean clicked
function style.switchTabButton(text, selected, width, height, opts)
    opts = opts or {}
    local activeBg = opts.activeBg or style.selectedColor
    local activeHover = opts.activeHover or activeBg
    local activePressed = opts.activePressed or activeBg
    local activeText = opts.activeText or 0xFFFFFFFF
    local inactiveBg = opts.inactiveBg or DEFAULT_TAB_INACTIVE_BG
    local inactiveHover = opts.inactiveHover or DEFAULT_TAB_INACTIVE_HOVER
    local inactivePressed = opts.inactivePressed or DEFAULT_TAB_INACTIVE_PRESSED
    local inactiveText = opts.inactiveText or DEFAULT_TAB_INACTIVE_TEXT

    if selected then
        ImGui.PushStyleColor(ImGuiCol.Button, activeBg)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, activeHover)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, activePressed)
        ImGui.PushStyleColor(ImGuiCol.Text, activeText)
    else
        ImGui.PushStyleColor(ImGuiCol.Button, inactiveBg)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, inactiveHover)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, inactivePressed)
        ImGui.PushStyleColor(ImGuiCol.Text, inactiveText)
    end

    local clicked
    if width ~= nil or height ~= nil then
        clicked = ImGui.Button(text, width or 0, height or 0)
    else
        clicked = ImGui.Button(text)
    end

    ImGui.PopStyleColor(4)
    return clicked
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
	trackWidgetEdit(element, changed, finished)

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
	trackWidgetEdit(element, changed, finished)

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
    trackWidgetEdit(element, changed, finished)

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
    trackWidgetEdit(element, changed, finished)

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
---@param step number? Optional InputInt step used by +/- buttons (default `min`).
---@param fastStep number? Optional InputInt fast step (default `max`).
---@return number newValue
---@return boolean changed
---@return boolean finished True when item was deactivated after edit.
function style.trackedIntInput(element, text, value, min, max, width, step, fastStep)
    width = width or 80
    step = step == nil and min or step
    fastStep = fastStep == nil and max or fastStep
    ImGui.SetNextItemWidth(width * style.viewSize)
    local newValue, changed = ImGui.InputInt(text, value, step, fastStep)

    local finished = ImGui.IsItemDeactivatedAfterEdit()
	trackWidgetEdit(element, changed, finished)

    newValue = math.max(newValue, min)
    newValue = math.min(newValue, max)

    return newValue, changed, finished
end

---@param disabledOptions table Keys are 1-based option indices and / or option labels.
---@param index number 1-based option index.
---@param optionText string
---@return boolean
local function isComboOptionDisabled(disabledOptions, index, optionText)
    return disabledOptions[index] == true or disabledOptions[optionText] == true
end

---@param disabledTooltip string|fun(optionText: string, index: number): string?
---@param optionText string
---@param index number 1-based option index.
---@return string?
local function resolveComboDisabledTooltip(disabledTooltip, optionText, index)
    if type(disabledTooltip) == "function" then
        local ok, tooltipText = pcall(disabledTooltip, optionText, index)
        if ok and tooltipText ~= nil and tooltipText ~= "" then
            return tostring(tooltipText)
        end

        return nil
    end

    if type(disabledTooltip) == "string" and disabledTooltip ~= "" then
        return disabledTooltip
    end

    return nil
end

---Combo drawn from selectables, so that individual options can be greyed out and made unselectable.
---@param text string Combo label / ID.
---@param selected number Current zero-based selected index.
---@param options table Array-like table of option labels.
---@param comboWidth number Combo width in pixels.
---@param disabledOptions table Keys are 1-based option indices and / or option labels.
---@param opts TrackedComboOpts
---@return number newValue
---@return boolean changed
local function drawComboWithDisabledOptions(text, selected, options, comboWidth, disabledOptions, opts)
    local newValue = selected
    local changed = false
    local previewValue = tostring(options[(selected or 0) + 1] or "")

    ImGui.SetNextItemWidth(comboWidth)
    local comboOpen = ImGui.BeginCombo(text, previewValue)
    local tooltipText = buildSelectorTooltip(previewValue, opts.tooltip, opts.currentValueTooltip)
    copySelectorValueOnMiddleClick(previewValue, opts.currentValueTooltip)
    if tooltipText then
        style.tooltip(tooltipText)
    end

    if comboOpen then
        for index, option in ipairs(options) do
            local optionText = tostring(option)
            local isSelected = (index - 1) == selected

            ImGui.PushID(index)
            if not isSelected and isComboOptionDisabled(disabledOptions, index, optionText) then
                ImGui.Selectable(optionText, false, ImGuiSelectableFlags.Disabled)

                local disabledTooltip = resolveComboDisabledTooltip(opts.disabledTooltip, optionText, index)
                if disabledTooltip then
                    style.tooltip(disabledTooltip, ImGuiHoveredFlags.AllowWhenDisabled)
                end
            else
                if ImGui.Selectable(optionText, isSelected) then
                    newValue = index - 1
                    changed = newValue ~= selected
                end
                if isSelected then
                    ImGui.SetItemDefaultFocus()
                end
            end
            ImGui.PopID()
        end

        ImGui.EndCombo()
    end

    return newValue, changed
end

---Draw a combo box and record history when selection changes.
---@class TrackedComboOpts
---@field tooltip string? Optional helper text appended after the current value.
---@field currentValueTooltip boolean? When false, suppresses the current-value tooltip and middle-click copy.
---@field disabledOptions table<number|string, boolean>? Options that are greyed out and can not be picked, keyed by 1-based index and / or option label. The currently selected option is never disabled.
---@field disabledTooltip (string|fun(optionText: string, index: number): string?)? Tooltip shown when hovering a disabled option.
---@param element table Element used for undo history tracking.
---@param text string Combo label / ID.
---@param selected number Current selected index.
---@param options table Array-like table of option labels.
---@param width number? Field width in unscaled style units (default `100`).
---@param opts TrackedComboOpts?
---@return number newValue Selected index returned by ImGui.
---@return boolean changed
function style.trackedCombo(element, text, selected, options, width, opts)
    if type(width) == "table" then
        opts = width
        width = opts.width
    end

    width = width or 100
    opts = opts or {}

    local disabledOptions = opts.disabledOptions
    local newValue, changed

    if type(disabledOptions) == "table" and next(disabledOptions) ~= nil then
        newValue, changed = drawComboWithDisabledOptions(text, selected, options, width * style.viewSize, disabledOptions, opts)
    else
        ImGui.SetNextItemWidth(width * style.viewSize)

        newValue, changed = ImGui.Combo(text, selected, options, #options)
        local tooltipText = buildSelectorTooltip(options[(newValue or selected or 0) + 1], opts.tooltip, opts.currentValueTooltip)
        copySelectorValueOnMiddleClick(options[(newValue or selected or 0) + 1], opts.currentValueTooltip)
        if tooltipText then
            style.tooltip(tooltipText)
        end
    end

    if changed then
        history.addAction(history.getElementChange(element))
    end
    return newValue, changed
end

---Show a current-value tooltip for a direct zero-based ImGui.Combo call and copy it on middle-click.
---@param selected number Current zero-based selected index.
---@param options table Array-like table of option labels.
---@param helperText string? Optional helper text appended after the current value.
---@param showValue boolean? When false, suppresses the current-value tooltip and middle-click copy.
function style.comboValueTooltip(selected, options, helperText, showValue)
    local index = tonumber(selected) or 0
    local tooltipText = buildSelectorTooltip(options and options[index + 1], helperText, showValue)
    copySelectorValueOnMiddleClick(options and options[index + 1], showValue)
    if tooltipText then
        style.tooltip(tooltipText)
    end
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
	trackWidgetEdit(element, changed, finished)

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
    trackWidgetEdit(element, changed, finished)

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
    trackWidgetEdit(element, changed, finished)

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
    local newValue, changed = style.inputTextWithHint(text, hint, value, 500)

	local finished = ImGui.IsItemDeactivatedAfterEdit()
	if finished then
        newValue = utils.stripNonASCII(newValue)
	end
	trackWidgetEdit(element, changed, finished)

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

---Build the preview label of a multi-select combo from its selection state.
---Shows `allLabel` when nothing is selected, the single key when exactly one is,
---and `multiLabelFormat` (a `%d` format) otherwise.
---@param selections table<string, boolean>? Selection state map.
---@param allLabel string Label used when no option is selected.
---@param multiLabelFormat string `string.format` pattern receiving the selected count.
---@param formatKey fun(key: string): string? Optional decorator for the single-selection label.
---@return string
function style.getMultiSelectPreviewLabel(selections, allLabel, multiLabelFormat, formatKey)
    local selected = {}

    for key, isSelected in pairs(selections or {}) do
        if isSelected == true then
            table.insert(selected, tostring(key))
        end
    end

    if #selected == 0 then
        return allLabel
    end

    if #selected == 1 then
        return type(formatKey) == "function" and formatKey(selected[1]) or selected[1]
    end

    return string.format(multiLabelFormat, #selected)
end

-- Query-syntax help shared by every search field supporting `utils.matchSearch`.
style.searchQuerySyntaxTooltip = "Supports custom search query syntax:\n- | (OR), includes any terms including the word after the |\n- ! (NOT), excludes any terms including the word after the !\n- & (AND), terms must include the word after the &\n- E.g. table|chair!poor&low to match any terms that include 'table' or 'chair', but not 'poor', and must include 'low'"

---Draw the glyph button that goes in front of a search input: a magnifier while the field is
---empty, a clear button once there is a query to drop. Always drawn, so the row keeps the same
---layout whether or not something has been typed. Leaves the cursor on the same line, ready for
---the input itself.
---@param id string Button ID, `##` prefixed by the caller so the glyph stays out of the ID.
---@param hasQuery boolean Whether the field currently holds a query.
---@param searchTooltip string? Tooltip shown while the field is empty (default `"Search"`).
---@return boolean cleared True when the button was pressed while there was a query to clear.
function style.drawSearchClearButton(id, hasQuery, searchTooltip)
    local cleared = false

    -- Tightened spacing: the glyph reads as part of the field beside it, not as a button of its own.
    ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 4 * style.viewSize, ImGui.GetStyle().ItemSpacing.y)
    style.pushButtonNoBG(true)
    if ImGui.Button((hasQuery and IconGlyphs.CloseCircleOutline or IconGlyphs.Magnify) .. id) and hasQuery then
        cleared = true
    end
    style.pushButtonNoBG(false)
    style.tooltip(hasQuery and "Clear the search" or (searchTooltip or "Search"))

    ImGui.SameLine()
    ImGui.PopStyleVar()

    return cleared
end

---Draw the standard search row: clear/search button, text input and syntax help glyph.
---Right-clicking the input clears it.
---@class SearchFilterRowOpts
---@field width number? Input width in unscaled units (default `300`).
---@field maxLength number? Input buffer length (default `100`).
---@field hint string? Placeholder text.
---@field searchTooltip string? Tooltip of the leading glyph while the field is empty.
---@param id string Input ID, e.g. `##filter`.
---@param value string Current search text.
---@param opts SearchFilterRowOpts?
---@return string value
---@return boolean changed
---@return boolean cleared
function style.drawSearchFilterRow(id, value, opts)
    opts = opts or {}
    value = tostring(value or "")

    local cleared = style.drawSearchClearButton(id .. "Clear", value ~= "", opts.searchTooltip)
    if cleared then
        value = ""
        style.clearSearchInput(id, true)
    end

    ImGui.SetNextItemWidth((opts.width or 300) * style.viewSize)
    local changed, inputCleared
    value, changed, inputCleared = style.searchInputTextWithHint(id, opts.hint or "Search by name... (Supports pattern matching)", value, opts.maxLength or 100)
    cleared = cleared or inputCleared

    ImGui.SameLine()
    style.mutedText(IconGlyphs.InformationOutline)
    style.tooltip(style.searchQuerySyntaxTooltip)

    return value, changed, cleared
end

---@param options table
---@param baseWidth number
---@param optionDisplayFn fun(optionText: string): string?
---@return number
local function getSearchDropdownPopupMaxWidth(options, baseWidth, optionDisplayFn)
    local maxTextWidth = 0

    for _, option in pairs(options or {}) do
        local optionText = tostring(option)
        local optionLabel = resolveSearchDropdownOptionLabel(optionText, optionDisplayFn)
        local optionWidth, _ = ImGui.CalcTextSize(optionLabel)
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
---@class TrackedSearchDropdownOpts
---@field element table? Element used for undo history tracking when selection changes.
---@field width number? Combo width in unscaled style units (default `100`).
---@field matchContentWidth boolean? When true, popup max width expands up to the longest option text.
---@field allowCustom boolean? When true, allows selecting typed search text as a custom value.
---@field optionDisplayFn fun(optionText: string): string? Optional display transformer.
---@field optionTooltipFn fun(optionText: string, optionLabel: string): string? Optional tooltip resolver for each option row.
---@field optionExistsFn fun(optionText: string): boolean? Optional existence test used for custom-value dedupe.
---@field optionFilterFn fun(optionText: string, query: string): boolean? Optional search matcher (query is already lowercased).
---@field tooltip string? Optional helper text appended after the current value.
---@field currentValueTooltip boolean? When false, suppresses the current-value tooltip and middle-click copy.
---@param text string Combo label / ID.
---@param searchHint string Placeholder for the filter input.
---@param value string Current selected value.
---@param searchValue string Current typed filter.
---@param options table List of selectable values.
---@param opts TrackedSearchDropdownOpts?
---@return string value
---@return string searchValue
---@return boolean finished
function style.trackedSearchDropdown(text, searchHint, value, searchValue, options, opts)
    opts = opts or {}

    value = value or ""
    searchValue = searchValue or ""
    options = options or {}
    local element = opts.element
    local width = opts.width or 100
    local matchContentWidth = opts.matchContentWidth == true
    local allowCustom = opts.allowCustom == true
    local optionDisplayFn = opts.optionDisplayFn
    local optionTooltipFn = opts.optionTooltipFn
    local optionExistsFn = opts.optionExistsFn
    local optionFilterFn = opts.optionFilterFn

    local finished = false
    local selectedValue = tostring(value)
    local previewValue = resolveSearchDropdownOptionLabel(selectedValue, optionDisplayFn)
    local comboWidth = width * style.viewSize
    local popupMaxWidth = comboWidth

    if matchContentWidth then
        popupMaxWidth = getSearchDropdownPopupMaxWidth(options, comboWidth, optionDisplayFn)
        ImGui.SetNextWindowSizeConstraints(1, 1, popupMaxWidth, 10000)
    end

    ImGui.SetNextItemWidth(comboWidth)
    local comboOpen = ImGui.BeginCombo(text, previewValue)
    local tooltipText = buildSelectorTooltip(selectedValue, opts.tooltip, opts.currentValueTooltip)
    copySelectorValueOnMiddleClick(selectedValue, opts.currentValueTooltip)
    if tooltipText then
        style.tooltip(tooltipText)
    end

    if comboOpen then
        local effectiveWidth = matchContentWidth and (popupMaxWidth / style.viewSize) or width
        local interiorWidth = effectiveWidth - (2 * ImGui.GetStyle().FramePadding.x) - 30
        if style.drawSearchClearButton("##searchClear", searchValue ~= "") then
            searchValue = ""
            style.clearSearchInput("##search", true)
        end
        local xButton, _ = ImGui.GetItemRectSize()

        ImGui.SetNextItemWidth(interiorWidth * style.viewSize)
        searchValue, _, _ = style.searchInputTextWithHint("##search", searchHint, searchValue, 500)
        local x, _ = ImGui.GetItemRectSize()

        local customValue = tostring(searchValue or "")
        customValue = utils.sanitizeText(customValue)
        local customExists = false
        if customValue ~= "" then
            if type(optionExistsFn) == "function" then
                local ok, exists = pcall(optionExistsFn, customValue)
                customExists = ok and exists == true
            else
                customExists = utils.indexValue(options, customValue) ~= -1
            end
        end
        local showCustomOption = allowCustom and customValue ~= "" and not customExists
        local query = string.lower(searchValue or "")
        local hasQuery = query ~= ""
        if ImGui.BeginChild("##list", x + xButton + ImGui.GetStyle().ItemSpacing.x, 120 * style.viewSize) then
            if showCustomOption then
                local customLabel = resolveSearchDropdownOptionLabel(customValue, optionDisplayFn)
                if ImGui.Selectable("Use custom: " .. customLabel) then
                    if element then
                        history.addAction(history.getElementChange(element))
                    end
                    value = customValue
                    finished = true
                    ImGui.CloseCurrentPopup()
                end
                style.tooltip(customValue)
                if next(options) ~= nil then
                    ImGui.Separator()
                end
            end

            local function drawOptionRow(optionText, optionIndex)
                if hasQuery then
                    if type(optionFilterFn) == "function" then
                        local ok, matched = pcall(optionFilterFn, optionText, query)
                        if not ok or matched ~= true then
                            return
                        end
                    else
                        local optionTextLower = string.lower(optionText)
                        local matchesRaw = utils.safePatternMatch(optionTextLower, query)

                        if not matchesRaw then
                            local optionLabelForMatch = resolveSearchDropdownOptionLabel(optionText, optionDisplayFn)
                            local matchesLabel = optionLabelForMatch ~= optionText and utils.safePatternMatch(string.lower(optionLabelForMatch), query)
                            if not matchesLabel then
                                return
                            end
                        end
                    end
                end

                local optionLabel = resolveSearchDropdownOptionLabel(optionText, optionDisplayFn)
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

                ImGui.PushID(tostring(optionIndex or optionText))
                if ImGui.Selectable(optionLabel) then
                    if element then
                        history.addAction(history.getElementChange(element))
                    end
                    value = optionText
                    finished = true
                    ImGui.CloseCurrentPopup()
                end

                if type(optionTooltipFn) == "function" then
                    local ok, optionTooltip = pcall(optionTooltipFn, optionText, optionLabel)
                    if ok and optionTooltip and optionTooltip ~= "" then
                        style.tooltip(optionTooltip)
                    end
                end
                ImGui.PopID()
            end

            if not finished then
                for optionIndex, option in pairs(options) do
                    drawOptionRow(tostring(option), optionIndex)
                    if finished then
                        break
                    end
                end
            end

            ImGui.EndChild()
        end

        ImGui.EndCombo()
    end

    return value, searchValue, finished
end

---@class SearchableMultiSelectComboOpts
---@field comboId string Hidden ImGui ID used for the combo (for example `##deviceClassFilterCombo`).
---@field previewLabel string
---@field searchHint string?
---@field searchValue string?
---@field options table?
---@field getOptions fun(): table? Optional lazy options provider called only while popup is open.
---@field selections table<string, boolean>?
---@field comboWidth number?
---@field searchWidth number?
---@field maxPopupHeight number?
---@field emptyText string?
---@field noMatchText string?
---@field searchInputId string?
---@field searchClearButtonId string?
---@field selectAllButtonId string?
---@field unselectAllButtonId string?
---@field optionIdPrefix string?
---@field selectAllTooltip string?
---@field unselectAllTooltip string?
---@field showClearSelectionButton boolean? Show a pre-combo icon button that clears selected options.
---@field clearSelectionButtonId string? Unique ID suffix for the clear-selection icon button.
---@field clearSelectionTooltip string? Tooltip shown on the clear-selection icon button.
---@field showAndFilterToggle boolean? Show an optional AND/OR mode toggle button in the combo header row.
---@field andFilterState boolean? Current state of the optional AND/OR mode toggle.
---@field onAndFilterChanged fun(nextState: boolean)? Callback fired when the optional AND/OR mode toggle changes.
---@field andFilterTooltip string? Tooltip shown on the optional AND/OR mode toggle.
---@field andFilterIcon string? Icon text used for the optional AND/OR mode toggle.
---@field getOptionKey fun(option: table, idx: integer): string?
---@field getOptionLabel fun(option: table, idx: integer): string?
---@field matchesOption fun(option: table, searchValue: string, idx: integer): boolean?
---@field singleSelect boolean? Only one option can be selected: options become rows, picking one replaces the selection and closes the popup.
---@field allowCreate boolean? Show an input + add button inside the popup to create a new option.
---@field createHint string? Hint text for the create input.
---@field createValue string? Current text of the create input (externalized state, returned as 3rd value).
---@field createInputId string? Unique ID for the create input.
---@field createButtonId string? Unique ID suffix for the create add button.
---@field createIcon string? Icon key. When set, an icon selector is drawn before the create input.
---@field createIconSearch string? Search text of that icon selector (externalized state).
---@field createIconPickerId string? Unique ID for that icon selector.
---@field createDisabled boolean? Greys the add button out and refuses the creation, e.g. on a name conflict.
---@field createTooltip string? Tooltip of the add button, typically saying why it is refused.
---@field onCreate fun(name: string, iconKey: string?)? Called when the user confirms a new option; defaults to selecting the name.

---Draw a searchable multi-select combo with select-all / unselect-all controls.
---Selection state is externalized through `selections` where keys map to booleans.
---With `singleSelect`, the same widget picks exactly one option instead.
---The caller owns visible label layout; this component renders only the combo widget by `comboId`.
---@param opts SearchableMultiSelectComboOpts
---@return boolean changed
---@return string searchValue
---@return string createValue Current text of the create input (empty unless `allowCreate` is set).
---@return string createIcon Icon key of the create row selector (unchanged unless `createIcon` is set).
---@return string createIconSearch Search text of the create row icon selector.
function style.drawSearchableMultiSelectCombo(opts)
    opts = opts or {}

    local comboId = tostring(opts.comboId or opts.comboLabel or "##multiSelectCombo")
    if not comboId:match("^##") and not comboId:match("^###") then
        comboId = "##" .. comboId
    end

    local previewLabel = tostring(opts.previewLabel or "")
    local searchHint = tostring(opts.searchHint or "Search...")
    local searchValue = tostring(opts.searchValue or "")
    local staticOptions = opts.options
    local getOptions = opts.getOptions
    local selections = opts.selections or {}
    local comboWidth = opts.comboWidth or (260 * style.viewSize)
    local searchWidth = opts.searchWidth or (220 * style.viewSize)
    local maxPopupHeight = opts.maxPopupHeight or style.getPopupMaxHeight()
    local emptyText = tostring(opts.emptyText or "No options available")
    local noMatchText = tostring(opts.noMatchText or "No matching options")
    local searchInputId = tostring(opts.searchInputId or "##multiSelectSearch")
    local searchClearButtonId = tostring(opts.searchClearButtonId or "##multiSelectSearchClear")
    local selectAllButtonId = tostring(opts.selectAllButtonId or "##multiSelectSelectAll")
    local unselectAllButtonId = tostring(opts.unselectAllButtonId or "##multiSelectUnselectAll")
    local optionIdPrefix = tostring(opts.optionIdPrefix or "##multiSelectOption")
    local showClearSelectionButton = opts.showClearSelectionButton == true
    local clearSelectionButtonId = tostring(opts.clearSelectionButtonId or "##multiSelectClearSelection")
    local clearSelectionTooltip = tostring(opts.clearSelectionTooltip or "Clear selected filters")
    local showAndFilterToggle = opts.showAndFilterToggle == true
    local andFilterState = opts.andFilterState == true
    local onAndFilterChanged = opts.onAndFilterChanged
    local andFilterTooltip = tostring(opts.andFilterTooltip or "AND filter mode (Leave off for OR filter)")
    local andFilterIcon = tostring(opts.andFilterIcon or IconGlyphs.SetCenter)
    local getOptionKey = opts.getOptionKey or function (option)
        return tostring(option or "")
    end
    local getOptionLabel = opts.getOptionLabel or function (option)
        return tostring(option or "")
    end
    -- Default matcher: case-insensitive search over the option key, which is what
    -- every caller needs. Pass `matchesOption` only for non-standard matching.
    local matchesOption = opts.matchesOption or function (option, searchValue, idx)
        local search = string.lower(tostring(searchValue or ""))
        if search == "" then
            return true
        end

        return utils.safePatternMatch(string.lower(tostring(getOptionKey(option, idx) or "")), search)
    end
    local allowCreate = opts.allowCreate == true
    local createHint = tostring(opts.createHint or "New option...")
    local createValue = tostring(opts.createValue or "")
    local createInputId = tostring(opts.createInputId or "##multiSelectCreate")
    local createButtonId = tostring(opts.createButtonId or "##multiSelectCreateAdd")
    local createIcon = opts.createIcon
    local createIconSearch = tostring(opts.createIconSearch or "")
    local createIconPickerId = tostring(opts.createIconPickerId or (comboId .. "CreateIcon"))
    local onCreate = opts.onCreate
    local createDisabled = opts.createDisabled == true
    local createTooltip = tostring(opts.createTooltip or "")
    local singleSelect = opts.singleSelect == true

    local changed = false

    ImGui.PushItemWidth(comboWidth)
    ImGui.SetNextWindowSizeConstraints(1, 1, 10000, maxPopupHeight)
    if ImGui.BeginCombo(comboId, previewLabel) then
        -- The popup is its own window, so without this the main window counts as unhovered
        -- and the viewport starts taking the clicks / keys meant for the search field.
        input.updateContext("main")

        local options = staticOptions
        if type(getOptions) == "function" then
            options = getOptions()
        end
        options = options or {}

        if style.drawSearchClearButton(searchClearButtonId, searchValue ~= "") then
            searchValue = ""
            style.clearSearchInput(searchInputId, true)
        end

        ImGui.SetNextItemWidth(searchWidth)
        local nextSearchValue, searchChanged, searchCleared = style.searchInputTextWithHint(searchInputId, searchHint, searchValue, 100)
        if searchChanged or searchCleared then
            searchValue = nextSearchValue
        end

        style.pushButtonNoBG(true)

        -- Bulk selection only means anything when several options can be held at once.
        if not singleSelect then
            if ImGui.Button(IconGlyphs.ExpandAllOutline .. selectAllButtonId) then
                for idx, option in ipairs(options) do
                    local optionKey = tostring(getOptionKey(option, idx) or "")
                    if optionKey ~= "" then
                        selections[optionKey] = true
                    end
                end
                changed = true
            end
            if opts.selectAllTooltip then
                style.tooltip(opts.selectAllTooltip)
            end

            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.CollapseAllOutline .. unselectAllButtonId) then
                for optionKey, _ in pairs(selections) do
                    selections[optionKey] = nil
                end
                changed = true
            end
            if opts.unselectAllTooltip then
                style.tooltip(opts.unselectAllTooltip)
            end
        end

        if showAndFilterToggle then
            if not singleSelect then
                ImGui.SameLine()
            end
            local nextAndFilterState, andFilterChanged = style.toggleButton(andFilterIcon, andFilterState)
            if andFilterChanged then
                andFilterState = nextAndFilterState
                if type(onAndFilterChanged) == "function" then
                    onAndFilterChanged(nextAndFilterState)
                end
            end

            if andFilterTooltip ~= "" then
                style.tooltip(andFilterTooltip)
            end
        end

        style.pushButtonNoBG(false)

        if allowCreate then
            local createInputWidth = searchWidth

            if createIcon ~= nil then
                -- Lazy require: `field` depends on `style`, so it cannot be required at load time.
                local field = require("modules/utils/ui/field")
                local iconSelectorWidth = 42 * style.viewSize

                createIcon, createIconSearch = field.drawIconSelector(createIconPickerId, createIcon, createIconSearch)
                ImGui.SameLine()

                createInputWidth = math.max(60 * style.viewSize, searchWidth - iconSelectorWidth - ImGui.GetStyle().ItemSpacing.x)
            end

            ImGui.SetNextItemWidth(createInputWidth)
            createValue, _ = style.inputTextWithHint(createInputId, createHint, createValue, 100)

            local createClicked = style.drawNoBGConditionalButton(createValue ~= "", IconGlyphs.TagPlusOutline .. createButtonId, createDisabled)

            -- Only requested when the button was actually drawn, so it never lands on the input.
            if createValue ~= "" and createTooltip ~= "" then
                style.tooltip(createTooltip)
            end

            if createClicked and not createDisabled then
                if type(onCreate) == "function" then
                    onCreate(createValue, createIcon)
                else
                    selections[createValue] = true
                end
                createValue = ""
                changed = true
            end
        end

        ImGui.Separator()

        if #options == 0 then
            style.mutedText(emptyText)
        else
            local hasVisibleOption = false
            for idx, option in ipairs(options) do
                if matchesOption(option, searchValue, idx) then
                    hasVisibleOption = true

                    local optionKey = tostring(getOptionKey(option, idx) or "")
                    if optionKey ~= "" then
                        local optionLabel = tostring(getOptionLabel(option, idx) or optionKey)
                        local isSelected = selections[optionKey] == true

                        if singleSelect then
                            -- `Selectable` returns the state it was flipped to, so any difference
                            -- means the row was clicked, including re-picking the current option.
                            if ImGui.Selectable(optionLabel .. optionIdPrefix .. tostring(idx), isSelected) ~= isSelected then
                                if not isSelected then
                                    for selectedKey, _ in pairs(selections) do
                                        selections[selectedKey] = nil
                                    end
                                    selections[optionKey] = true
                                    changed = true
                                end

                                ImGui.CloseCurrentPopup()
                            end
                        else
                            local checked, toggled = ImGui.Checkbox(optionLabel .. optionIdPrefix .. tostring(idx), isSelected)
                            if toggled then
                                if checked then
                                    selections[optionKey] = true
                                else
                                    selections[optionKey] = nil
                                end
                                changed = true
                            end
                        end
                    end
                end
            end

            if not hasVisibleOption then
                style.mutedText(noMatchText)
            end
        end

        ImGui.EndCombo()
    end

    if showClearSelectionButton then
        local canClearSelections = false
        for _, isSelected in pairs(selections) do
            if isSelected == true then
                canClearSelections = true
                break
            end
        end

        if canClearSelections then
            ImGui.SameLine()
            style.pushButtonNoBG(true)
            local clearPressed = ImGui.Button(IconGlyphs.FilterRemoveOutline .. clearSelectionButtonId)
            style.pushButtonNoBG(false)

            if clearSelectionTooltip ~= "" then
                style.tooltip(clearSelectionTooltip)
            end

            if clearPressed then
                for optionKey, _ in pairs(selections) do
                    selections[optionKey] = nil
                end
                changed = true
            end
        end
    end
    ImGui.PopItemWidth()

    return changed, searchValue, createValue, createIcon, createIconSearch
end

---Draw the expand-all / collapse-all icon button pair used above collapsible lists.
---@param idScope string Unique ID scope, e.g. `spawnHierarchy`.
---@param onExpand fun() Called when expand all is pressed.
---@param onCollapse fun() Called when collapse all is pressed.
---@param opts {disabled: boolean?, expandTooltip: string?, collapseTooltip: string?}?
function style.drawExpandCollapseButtons(idScope, onExpand, onCollapse, opts)
    opts = opts or {}

    local expandIcon = IconGlyphs.ExpandAllOutline or IconGlyphs.ArrowExpandAll or IconGlyphs.ExpandAll or "+"
    local collapseIcon = IconGlyphs.CollapseAllOutline or IconGlyphs.ArrowCollapseAll or IconGlyphs.CollapseAll or "-"

    ImGui.BeginDisabled(opts.disabled == true)

    style.pushButtonNoBG(true)
    if ImGui.Button(expandIcon .. "##" .. idScope .. "ExpandAll") then
        onExpand()
    end
    style.pushButtonNoBG(false)
    style.tooltip(opts.expandTooltip or "Expand all")

    ImGui.SameLine()

    style.pushButtonNoBG(true)
    if ImGui.Button(collapseIcon .. "##" .. idScope .. "CollapseAll") then
        onCollapse()
    end
    style.pushButtonNoBG(false)
    style.tooltip(opts.collapseTooltip or "Collapse all")

    ImGui.EndDisabled()
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

---Shared Point/Spot/Area light-type visual metadata, keyed both by numeric `ELightType` ordinal (`index`)
---and by the `ELightType` string constant (`value`) used in raw component data.
style.lightTypeOptions = {
    { index = 0, value = "LT_Point", icon = IconGlyphs.LightbulbOn20, label = "Point" },
    { index = 1, value = "LT_Spot", icon = IconGlyphs.TrackLight, label = "Spot" },
    { index = 2, value = "LT_Area", icon = IconGlyphs.CarParkingLights, label = "Area" }
}

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

---Warnings shown in front of individual light channels, keyed by the names in `style.lightChannelEnum`.
style.lightChannelWarnings = {
    LC_Channel1 = "This channel is bugged in game and may not work as expected."
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
---@return boolean changed Whether the selection was edited this frame.
function style.drawLightChannelsSelector(object, lightChannels)
    local changed = false

    if not maxLightChannelsWidth then
        -- Channels carrying a warning are prefixed with an icon, so the checkbox column has to leave
        -- room for the longest label plus that icon.
        maxLightChannelsWidth = utils.getTextMaxWidth(style.lightChannelEnum) + ImGui.CalcTextSize(IconGlyphs.AlertOutline) + 3 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.PlusBoxMultipleOutline) then
        if object then history.addAction(history.getElementChange(object)) end
        for i = 1, #lightChannels do
            lightChannels[i] = true
        end
        changed = true
    end
    style.tooltip("Select all light channels")
    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.MinusBoxMultipleOutline) then
        if object then history.addAction(history.getElementChange(object)) end
        for i = 1, #lightChannels do
            lightChannels[i] = false
        end
        changed = true
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
        changed = true
    end
    style.tooltip("Paste light channels from clipboard")
    style.popGreyedOut(channels == nil)
    style.pushButtonNoBG(false)

    for key, channel in ipairs(style.lightChannelEnum) do
        local warning = style.lightChannelWarnings[channel]

        if warning then
            style.styledText(IconGlyphs.AlertOutline, style.warnColor)
            style.tooltip(warning)
            ImGui.SameLine()
        end

        style.mutedText(channel)
        if warning then
            style.tooltip(warning)
        end
        ImGui.SameLine()
        ImGui.SetCursorPosX(maxLightChannelsWidth)

        local channelChanged
        if object then
            lightChannels[key], channelChanged = style.trackedCheckbox(object, "##lightChannel" .. key, lightChannels[key])
        else
            lightChannels[key], channelChanged = ImGui.Checkbox("##lightChannel" .. key, lightChannels[key])
        end

        changed = changed or channelChanged
    end

    return lightChannels, changed
end

---Draws a fixed-size color swatch with an inline hex input, a hover tooltip, and a click-to-open popup
---trigger. Positions the cursor after the widget as if it were a single item. The caller owns the actual
---color-picker popup (matching `popupId`, opened via `ImGui.BeginPopup`) and all apply/commit logic for
---the parsed hex text - this only draws the shared swatch/hex-input geometry used by lights and light
---components alike.
---@param object table? Element used for undo history tracking on the hex input.
---@param popupId string Popup id to open when the swatch is clicked.
---@param hexInputId string Widget id for the hex input field.
---@param color number[] Unit RGB(A) color, 0-1 range. Alpha defaults to 1 for the swatch fill when absent.
---@param hexText string? Cached hex input text returned by this function on a previous frame.
---@param hexEditing boolean? Whether the hex input was active on a previous frame.
---@param opts table? { modified: boolean?, afterHexInput: fun()? } `afterHexInput` runs right after the
---hex input (e.g. to draw a reset-to-default button) while the hex badge frame colors are still pushed.
---@return string hexText
---@return boolean hexEditing
---@return boolean changed True when the hex input text changed this frame.
---@return boolean finished True when the hex input was deactivated after edit.
function style.drawLightColorSwatch(object, popupId, hexInputId, color, hexText, hexEditing, opts)
    opts = opts or {}

    local swatchSize = 142 * style.viewSize
    local swatchRoundness = 14 * style.viewSize
    local hexInputWidth = 96
    local hexInputBottomOffset = 10 * style.viewSize
    local currentHex = colorUtil.formatHexRGB(color)

    if not hexEditing and hexText ~= currentHex then
        hexText = currentHex
    end

    ImGui.BeginGroup()
    local swatchLocalX = ImGui.GetCursorPosX()
    local swatchLocalY = ImGui.GetCursorPosY()
    local swatchX, swatchY = ImGui.GetCursorScreenPos()
    local swatchMaxX = swatchX + swatchSize
    local swatchMaxY = swatchY + swatchSize
    local hexInputScreenX = swatchX + 10 * style.viewSize
    local hexInputScreenY = swatchY + swatchSize - ImGui.GetFrameHeight() - hexInputBottomOffset
    local hexInputScreenW = hexInputWidth * style.viewSize
    local hexInputScreenH = ImGui.GetFrameHeight()

    ImGui.Dummy(swatchSize, swatchSize)
    local drawList = ImGui.GetWindowDrawList()
    ImGui.ImDrawListAddRectFilled(
        drawList,
        swatchX,
        swatchY,
        swatchMaxX,
        swatchMaxY,
        colorUtil.packAABBGGRR(color, color[4] or 1),
        swatchRoundness
    )
    if opts.modified then
        ImGui.ImDrawListAddRect(
            drawList,
            swatchX,
            swatchY,
            swatchMaxX,
            swatchMaxY,
            style.regularColor,
            swatchRoundness,
            0,
            2 * style.viewSize
        )
    end

    local badgePadding = 3 * style.viewSize
    local badgeRounding = ImGui.GetStyle().FrameRounding + badgePadding
    ImGui.ImDrawListAddRectFilled(
        drawList,
        hexInputScreenX - badgePadding,
        hexInputScreenY - badgePadding,
        hexInputScreenX + hexInputScreenW + badgePadding,
        hexInputScreenY + hexInputScreenH + badgePadding,
        style.lightColorHexBadgeScrim,
        badgeRounding
    )

    local afterSwatchY = swatchLocalY + swatchSize
    local hexInputY = swatchLocalY + swatchSize - ImGui.GetFrameHeight() - hexInputBottomOffset
    ImGui.SetCursorPos(swatchLocalX + 10 * style.viewSize, hexInputY)
    ImGui.PushStyleColor(ImGuiCol.FrameBg, style.lightColorHexBadgeBg)
    ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, style.lightColorHexBadgeHover)
    ImGui.PushStyleColor(ImGuiCol.FrameBgActive, style.lightColorHexBadgePressed)
    local changed, finished
    hexText, changed, finished = style.trackedTextField(object, hexInputId, hexText or currentHex, "#RRGGBB", hexInputWidth)
    hexEditing = ImGui.IsItemActive()
    if opts.afterHexInput then
        opts.afterHexInput()
    end
    ImGui.PopStyleColor(3)

    local popupOpen = ImGui.IsPopupOpen(popupId)
    local hoveringSwatch = ImGui.IsMouseHoveringRect(swatchX, swatchY, swatchMaxX, swatchMaxY)
    local hoveringHexInput = ImGui.IsMouseHoveringRect(
        hexInputScreenX - badgePadding,
        hexInputScreenY - badgePadding,
        hexInputScreenX + hexInputScreenW + badgePadding,
        hexInputScreenY + hexInputScreenH + badgePadding
    )
    if not popupOpen and hoveringSwatch and not hoveringHexInput then
        if ImGui.IsMouseClicked(0) then
            ImGui.OpenPopup(popupId)
        end
        ImGui.BeginTooltip()
        ImGui.PushStyleColor(ImGuiCol.Text, style.regularColor)
        ImGui.Text(colorUtil.formatPreviewTooltip(color))
        ImGui.PopStyleColor()
        ImGui.EndTooltip()
    end

    ImGui.SetCursorPos(swatchLocalX, afterSwatchY)
    ImGui.EndGroup()

    return hexText, hexEditing, changed, finished
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
