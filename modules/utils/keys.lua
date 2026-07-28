---Helpers around the `ImGuiKey` enum, for user rebindable keys.
---
---Bindings are stored by ImGuiKey *name* rather than by value, so config.json stays readable and
---survives ImGui renumbering its enum. Names are also what the settings UI and the on screen hints
---display, through the two label helpers below.
---@class keys
local keys = {}

-- Everything the user is allowed to bind. Escape is deliberately left out, the rebinding UI uses it
-- to cancel. Mouse buttons are out too, IsKeyDown does not report them.
local bindable = {
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    "Space", "Tab", "Enter", "Backspace", "Insert", "Delete",
    "Home", "End", "PageUp", "PageDown",
    "UpArrow", "DownArrow", "LeftArrow", "RightArrow",
    "LeftShift", "RightShift", "LeftCtrl", "RightCtrl", "LeftAlt", "RightAlt",
    "Keypad0", "Keypad1", "Keypad2", "Keypad3", "Keypad4",
    "Keypad5", "Keypad6", "Keypad7", "Keypad8", "Keypad9",
    "KeypadDecimal", "KeypadDivide", "KeypadMultiply", "KeypadSubtract", "KeypadAdd", "KeypadEnter",
    "Apostrophe", "Comma", "Minus", "Period", "Slash", "Semicolon", "Equal",
    "LeftBracket", "Backslash", "RightBracket", "GraveAccent"
}

-- Compact forms used by the on screen hint, where horizontal space is tight.
local shortLabels = {
    LeftShift = "Shift", RightShift = "R-Shift",
    LeftCtrl = "Ctrl", RightCtrl = "R-Ctrl",
    LeftAlt = "Alt", RightAlt = "R-Alt",
    UpArrow = "Up", DownArrow = "Down", LeftArrow = "Left", RightArrow = "Right",
    PageUp = "PgUp", PageDown = "PgDn", Backspace = "Bksp",
    Apostrophe = "'", Comma = ",", Minus = "-", Period = ".", Slash = "/",
    Semicolon = ";", Equal = "=", LeftBracket = "[", Backslash = "\\", RightBracket = "]",
    GraveAccent = "`", KeypadDecimal = "Num .", KeypadDivide = "Num /",
    KeypadMultiply = "Num *", KeypadSubtract = "Num -", KeypadAdd = "Num +", KeypadEnter = "Num Enter"
}

---@return string[] names Bindable key names the running ImGui actually knows about.
function keys.getBindable()
    local available = {}

    for _, name in ipairs(bindable) do
        if ImGuiKey[name] ~= nil then
            table.insert(available, name)
        end
    end

    return available
end

---@param name string? ImGuiKey name
---@return integer? value
function keys.getValue(name)
    if type(name) ~= "string" then return nil end

    return ImGuiKey[name]
end

---Readable form of a key name, e.g. "LeftShift" -> "Left Shift", "Keypad0" -> "Keypad 0".
---@param name string?
---@return string
function keys.getLabel(name)
    if type(name) ~= "string" or name == "" then return "Unbound" end

    local label = name:gsub("(%l)(%u)", "%1 %2")
    if label:find("^Keypad") then
        label = label:gsub("(%a)(%d)", "%1 %2")
    end

    return label
end

---Compact form of a key name, for the preview hint.
---@param name string?
---@return string
function keys.getShortLabel(name)
    if type(name) ~= "string" or name == "" then return "--" end

    return shortLabels[name] or keys.getLabel(name)
end

---@param name string?
---@return boolean
function keys.isDown(name)
    local value = keys.getValue(name)

    return value ~= nil and ImGui.IsKeyDown(value)
end

---Whether the key went down this frame. Key repeat is ignored, one press is one step.
---@param name string?
---@return boolean
function keys.isPressed(name)
    local value = keys.getValue(name)

    return value ~= nil and ImGui.IsKeyPressed(value, false)
end

---First bindable key pressed this frame, used to record a new binding.
---@return string? name
function keys.capture()
    for _, name in ipairs(bindable) do
        local value = ImGuiKey[name]
        if value ~= nil and ImGui.IsKeyPressed(value, false) then
            return name
        end
    end

    return nil
end

return keys
