local input = {
    hotkeys = {},
    mouse = {},
    context = {
        main = { hovered = false, focused = false },
        spawned = { hovered = false, focused = false },
        hierarchy = { hovered = false, focused = false },
        viewport = { hovered = false, focused = false }
    },
    numericDown = {},
    backspaceDown = false,
    dotDown = false,
    trackingNumeric = false,
    numericSign = 1,
    numeric = "",
    ---Raised by the settings UI while it records a new binding, so the key being bound does not also
    ---trigger a hotkey. Cleared by input.update every frame, a hidden rebinding UI cannot get stuck.
    rebindActive = false,
}

--- Mouse wheel ----------------------------------------------------------------------------------
-- CET's ImGui binding exposes no wheel accessor at all: there is no `GetIO`, no `GetMouseWheel`,
-- and `ImGuiKey` stops short of the mouse aliases. The only thing the wheel is allowed to touch is
-- the scroll offset of whichever window ImGui considers hovered, so it is read back through one:
-- a full screen, fully transparent, item-less window with an oversized content area, parked at the
-- very back of the z-order. Being at the back means it is only ever the hovered window when nothing
-- else is under the cursor, which is exactly the 3D viewport - any real window on top keeps its own
-- wheel handling. The frame-to-frame change of its scroll offset converts back into wheel notches.

--- Tall enough that thousands of notches fit before either scroll end is reached.
local WHEEL_PROBE_CONTENT_HEIGHT = 200000
--- Guards against a single frame swallowing a whole flick of the wheel.
local WHEEL_MAX_NOTCHES = 10
--- Built on first use, the ImGui globals do not exist yet while this file is being required.
local wheelProbeFlags = nil
--- Which flags the probe window wants. Not every CET build exposes the same set (NoDocking is
--- absent from a non-docking ImGui, for one), and none of these are load bearing on their own, so
--- the ones this build does not know are simply left out rather than erroring on a nil.
local WHEEL_PROBE_FLAG_NAMES = {
    "NoDecoration", "NoMove", "NoBackground", "NoSavedSettings",
    "NoFocusOnAppearing", "NoBringToFrontOnFocus", "NoNav"
}

---@class inputWheelProbe
---@field lastScroll number? Scroll offset seen on the previous frame, `nil` until the first poll.
---@field resync boolean Set after re-centering, drops one frame of delta rather than reporting a jump.
---@field holdsActiveId boolean True while ImGui's active id belongs to the probe, see input.isUIInputActive.
---@field lastFrame number ImGui frame the probe was last submitted on, guards against a double poll.
input.wheelProbe = {
    lastScroll = nil,
    resync = false,
    holdsActiveId = false,
    lastFrame = -1
}

---Reads how far the mouse wheel moved this frame, in wheel notches.
---Positive is a pull towards the user (scroll down), negative is a push away from it (scroll up).
---Only reports movement while the cursor sits over the bare viewport, see the note above.
---Must be called from inside the ImGui draw pass, at most once per frame.
---@return number notches Signed notch count, `0` when the wheel did not move.
function input.pollMouseWheel()
    local probe = input.wheelProbe

    -- camera.update runs a second time within the same frame whenever editor mode is toggled from a
    -- hotkey or a button. The wheel has already been accounted for by then, so ignore the repeat.
    local frame = ImGui.GetFrameCount()
    if frame == probe.lastFrame then return 0 end
    probe.lastFrame = frame

    if not wheelProbeFlags then
        wheelProbeFlags = 0
        for _, name in ipairs(WHEEL_PROBE_FLAG_NAMES) do
            local flag = ImGuiWindowFlags[name]
            if type(flag) == "number" then
                wheelProbeFlags = wheelProbeFlags + flag
            end
        end
    end

    local width, height = GetDisplayResolution()

    ImGui.SetNextWindowPos(0, 0, ImGuiCond.Always)
    ImGui.SetNextWindowSize(width, height, ImGuiCond.Always)
    ImGui.SetNextWindowContentSize(0, WHEEL_PROBE_CONTENT_HEIGHT)

    -- Begin / End are paired unconditionally, the window is never collapsible but ImGui still
    -- requires the call even when Begin returns false.
    ImGui.Begin("##wb-wheel-probe-wui", wheelProbeFlags)

    -- A left click on any window makes ImGui take its move id as the active id, even for a window
    -- flagged NoMove. That would otherwise read as "a UI widget is being used" for as long as the
    -- button is held, which is every drag in the viewport. Remember when the probe is the one that
    -- took it, so input.isUIInputActive can discount it.
    if ImGui.IsMouseClicked(ImGuiMouseButton.Left) and ImGui.IsWindowHovered() then
        input.wheelProbe.holdsActiveId = true
    elseif not ImGui.IsMouseDown(ImGuiMouseButton.Left) then
        input.wheelProbe.holdsActiveId = false
    end

    local scroll = ImGui.GetScrollY()
    local scrollMax = ImGui.GetScrollMaxY()
    local notches = 0

    if probe.resync or probe.lastScroll == nil then
        probe.resync = false
    else
        -- Mirrors ImGui's own step, `trunc(min(5 * fontSize, innerHeight * 0.67))` pixels per notch.
        local perNotch = math.floor(math.min(5 * ImGui.GetFontSize(), height * 0.67))
        if perNotch >= 1 then
            notches = (scroll - probe.lastScroll) / perNotch
            notches = math.max(- WHEEL_MAX_NOTCHES, math.min(WHEEL_MAX_NOTCHES, notches))
        end
    end

    probe.lastScroll = scroll

    -- Park the offset back in the middle once it drifts towards either end, so the wheel never runs
    -- into the scroll clamp. ImGui applies the incoming wheel before this frame's Begin resolves the
    -- request, so the frame after a re-center cannot be measured - only do it while the wheel is
    -- idle and genuinely far out, which makes the dropped frame unnoticeable.
    if notches == 0 and scrollMax > 0 and math.abs(scroll - (scrollMax * 0.5)) > (scrollMax * 0.3) then
        ImGui.SetScrollY(scrollMax * 0.5)
        probe.resync = true
    end

    ImGui.End()

    return notches
end

---Forgets the last scroll offset, so the next poll starts a fresh baseline instead of reporting the
---gap that built up while the probe was not being drawn.
function input.resetMouseWheel()
    input.wheelProbe.lastScroll = nil
    input.wheelProbe.resync = false
    input.wheelProbe.holdsActiveId = false
end

function input.registerImGuiHotkey(keys, callback, runCondition)
    table.insert(input.hotkeys, {keys = keys, active = false, callback = callback, runCondition = runCondition})
end

function input.registerMouseAction(mouseKey, callback, runCondition)
    table.insert(input.mouse, {mouseKey = mouseKey, active = false, callback = callback, runCondition = runCondition})
end

---Returns whether an ImGui control currently owns user input.
---InputText remains active while focused, even if the pointer moves over another window.
---@return boolean
function input.isUIInputActive()
    if input.rebindActive then return true end

    -- ImGui only ever has one active id, so while it belongs to the wheel probe no real widget can
    -- hold it. The mouse check keeps a stale flag harmless if polling stopped mid-click.
    if input.wheelProbe.holdsActiveId and ImGui.IsMouseDown(ImGuiMouseButton.Left) then
        return false
    end

    return ImGui.IsAnyItemActive and ImGui.IsAnyItemActive() or false
end

function input.update()
    local uiInputActive = input.isUIInputActive()

    for _, hotkey in ipairs(input.hotkeys) do
        local pressed = true

        for _, key in ipairs(hotkey.keys) do
            if not ImGui.IsKeyDown(key) then
                pressed = false
                hotkey.active = false
                break
            end
        end

        if pressed and not hotkey.active then
            if not uiInputActive and ((hotkey.runCondition and hotkey.runCondition()) or hotkey.runCondition == nil) then
                hotkey.callback()
            end
            hotkey.active = true
        end
    end

    for _, mouse in ipairs(input.mouse) do
        if ImGui.IsMouseDown(mouse.mouseKey) then
            if not mouse.active then
                if not uiInputActive and ((mouse.runCondition and mouse.runCondition()) or mouse.runCondition == nil) then
                    mouse.callback()
                end
                mouse.active = true
            end
        else
            mouse.active = false
        end
    end

    if input.trackingNumeric then
        for i = 0, 9 do
            if ImGui.IsKeyDown(ImGuiKey[tostring(i)]) or ImGui.IsKeyDown(ImGuiKey["Keypad" .. tostring(i)]) then
                if not input.numericDown[i] then
                    input.numeric = input.numeric .. i
                    input.numericDown[i] = true
                end
            else
                input.numericDown[i] = false
            end
        end

        if ImGui.IsKeyDown(ImGuiKey.Backspace) and not input.backspaceDown then
            input.numeric = input.numeric:sub(1, -2)
            input.backspaceDown = true
        else
            input.backspaceDown = false
        end

        if ImGui.IsKeyDown(ImGuiKey.Period) or ImGui.IsKeyDown(ImGuiKey.KeypadDecimal) and not input.dotDown then
            if not string.find(input.numeric, "%.") then
                input.numeric = input.numeric .. "."
            end
            input.dotDown = true
        else
            input.dotDown = false
        end

        if ImGui.IsKeyDown(ImGuiKey.Minus) or ImGui.IsKeyDown(ImGuiKey.KeypadSubtract) then
            input.numericSign = -1
        end

        if ImGui.IsKeyDown(ImGuiKey.Equal) or ImGui.IsKeyDown(ImGuiKey.KeypadAdd) then
            input.numericSign = 1
        end
    end

    -- Re-raised by the settings UI on every frame it keeps recording, see input.rebindActive
    input.rebindActive = false
end

function input.resetContext()
    for key, _ in pairs(input.context) do
        input.context[key] = { hovered = false, focused = false }
    end
end

function input.updateContext(key)
    -- `AllowWhenBlockedByActiveItem`: ImGui reports no window as hovered for as long as any widget
    -- owns the active id, so a window would stop counting as hovered for the whole of a drag on one
    -- of its own DragFloats. `viewport.hovered` is derived from `main.hovered`, which made every
    -- Ctrl + drag on a value field read as a Ctrl + drag in the bare viewport - that starts a box
    -- select, and a box select drops the current selection.
    local hoveredFlags = ImGuiHoveredFlags.ChildWindows + ImGuiHoveredFlags.AllowWhenBlockedByActiveItem

    input.context[key].hovered = ImGui.IsWindowHovered(hoveredFlags) or input.context[key].hovered
    input.context[key].focused = ImGui.IsWindowFocused(ImGuiHoveredFlags.ChildWindows) or input.context[key].focused
end

function input.trackNumeric(state)
    input.numeric = ""
    input.numericSign = 1
    input.trackingNumeric = state
end

function input.getNumeric(default)
    return (tonumber(input.numeric) or default) * input.numericSign
end

return input
