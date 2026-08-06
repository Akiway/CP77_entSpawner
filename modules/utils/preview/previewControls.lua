local Cron = require("modules/utils/vendor/Cron")
local utils = require("modules/utils/core/utils")
local input = require("modules/utils/core/input")
local editor = require("modules/utils/editor/editor")
local settings = require("modules/utils/core/settings")
local GameSettings = require("modules/utils/vendor/GameSettings")
local keys = require("modules/utils/core/keys")

---Keyboard manipulation of the hover asset preview.
---
---The movement cluster orbits the asset on two axes, both of which turn freely all the way around. A
---second pair moves towards / away from it, and a sprint style key speeds all of that up. Two more
---keys step through the appearances.
---
---The two takeovers are independent on purpose:
--- - orbiting, pitching or zooming stops the automatic turntable (`active`)
--- - stepping the appearance stops the appearance cycle (`appearanceLocked`)
---
---Both are dropped when the next preview starts. All keys are user rebindable, see `actions`.
---@class previewControls
---@field active boolean Whether the user took over the point of view from the automatic spin.
---@field yaw number Accumulated left / right orbit, in degrees.
---@field pitch number Accumulated up / down orbit, in degrees. Named after the rotation it drives.
---@field zoom number Framing multiplier, 1 being the default framing.
---@field appearanceLocked boolean Whether the user took over the appearance from the automatic cycle.
---@field appearanceOffset integer Appearances stepped through since the takeover, may be negative.
local previewControls = {
    active = false,
    yaw = 0,
    pitch = 0,
    zoom = 1,
    appearanceLocked = false,
    appearanceOffset = 0
}

local ORBIT_YAW_SPEED = 120   -- Degrees per second
local ORBIT_PITCH_SPEED = 90  -- Degrees per second
local ZOOM_RATE = 2.5         -- Framing multiplied by this per second of holding the zoom keys
local SPRINT_MULTIPLIER = 2.5
local MIN_ZOOM = 0.3
local MAX_ZOOM = 4

---Bindable actions, in the order the settings UI lists them.
---@type { id: string, label: string, hint: string }[]
previewControls.actions = {
    { id = "orbitLeft",      label = "Orbit left",          hint = "Turn the asset around its vertical axis" },
    { id = "orbitRight",     label = "Orbit right",         hint = "Turn the asset around its vertical axis" },
    { id = "orbitUp",        label = "Orbit up",            hint = "Turn the asset around the screen horizontal axis, to see it from above" },
    { id = "orbitDown",      label = "Orbit down",          hint = "Turn the asset around the screen horizontal axis, to see it from below" },
    { id = "zoomIn",         label = "Zoom in",             hint = "Move towards the asset" },
    { id = "zoomOut",        label = "Zoom out",            hint = "Move away from the asset" },
    { id = "faster",         label = "Faster",              hint = "Hold to speed everything up, like sprinting" },
    { id = "appearancePrev", label = "Previous appearance", hint = "Step back through the appearances, and stop the automatic cycle" },
    { id = "appearanceNext", label = "Next appearance",     hint = "Step forward through the appearances, and stop the automatic cycle" }
}

-- The movement cluster covers both turntable axes, and the two keys right above / below it on the
-- same hand handle the zoom. R and F sit on the same physical keys in both layouts.
local layoutDefaults = {
    qwerty = {
        orbitLeft = "A", orbitRight = "D", orbitUp = "W", orbitDown = "S",
        zoomIn = "R", zoomOut = "F", faster = "LeftShift",
        appearancePrev = "Q", appearanceNext = "E"
    },
    -- French keyboards move the cluster to ZQSD, which frees A right next to it for the appearances
    azerty = {
        orbitLeft = "Q", orbitRight = "D", orbitUp = "Z", orbitDown = "S",
        zoomIn = "R", zoomOut = "F", faster = "LeftShift",
        appearancePrev = "A", appearanceNext = "E"
    }
}

-- Game languages whose keyboards are AZERTY. QWERTZ (de, cs, hu) keeps WASD and QE on the same
-- physical keys as QWERTY, so those fall through to the default layout.
local azertyLanguages = { fr = true }

-- The hint runs on every preview frame, so it is only rebuilt when the bindings or the number of
-- appearances change.
---@type string[]?
local hintLines = nil
local hintAppearanceCount = -1

---On screen language the game is running in, e.g. "fr-fr".
---@return string? language nil while the settings system is not up yet (main menu, early boot).
local function readGameLanguage()
    local ok, var = pcall(GameSettings.Var, "/language/OnScreen")
    if not ok or type(var) ~= "table" or type(var.value) ~= "string" or var.value == "" then
        return nil
    end

    return var.value
end

---@param language string? Game language, defaults to the one currently set.
---@return string layout "qwerty" | "azerty"
function previewControls.getKeyboardLayout(language)
    language = language or readGameLanguage()
    if type(language) ~= "string" then
        return "qwerty"
    end

    return azertyLanguages[language:sub(1, 2):lower()] and "azerty" or "qwerty"
end

---Default binding for every action, picked from the game language's keyboard layout.
---@param language string? Game language, defaults to the one currently set.
---@return table<string, string>
function previewControls.getDefaultBindings(language)
    local defaults = layoutDefaults[previewControls.getKeyboardLayout(language)] or layoutDefaults.qwerty
    local bindings = {}

    for _, action in ipairs(previewControls.actions) do
        -- Empty rather than nil for an action a layout forgot, so it stays unbound instead of
        -- looking like a missing entry that has to be resolved again on every frame.
        bindings[action.id] = defaults[action.id] or layoutDefaults.qwerty[action.id] or ""
    end

    return bindings
end

---Currently bound keys, filling in any action the config does not have yet.
---@return table<string, string> bindings ImGuiKey names, keyed by action id.
function previewControls.getBindings()
    local stored = settings.previewBindings
    if type(stored) ~= "table" then
        stored = {}
        settings.previewBindings = stored
    end

    local complete = true
    for _, action in ipairs(previewControls.actions) do
        if type(stored[action.id]) ~= "string" then
            complete = false
            break
        end
    end

    if complete then
        return stored
    end

    local language = readGameLanguage()
    local defaults = previewControls.getDefaultBindings(language)

    if not language then
        -- Settings system not up yet: hand out the defaults without writing them, so the real
        -- language still gets to decide once the game is running.
        local pending = {}
        for _, action in ipairs(previewControls.actions) do
            pending[action.id] = stored[action.id] or defaults[action.id]
        end

        return pending
    end

    local known = {}
    for _, action in ipairs(previewControls.actions) do
        known[action.id] = true
        if type(stored[action.id]) ~= "string" then
            stored[action.id] = defaults[action.id]
        end
    end

    -- Drop bindings for actions that no longer exist, so renamed ones do not linger in the config
    for id in pairs(stored) do
        if not known[id] then
            stored[id] = nil
        end
    end

    settings.save()

    return stored
end

---Binds a single action, persisting it.
---@param actionId string
---@param keyName string ImGuiKey name
function previewControls.setBinding(actionId, keyName)
    local stored = settings.previewBindings
    if type(stored) ~= "table" then
        stored = previewControls.getDefaultBindings()
        settings.previewBindings = stored
    end

    stored[actionId] = keyName
    hintLines = nil
    settings.save()
end

---Rebinds every action back to the default for the current game language.
function previewControls.restoreDefaultBindings()
    settings.previewBindings = previewControls.getDefaultBindings()
    hintLines = nil
    settings.save()
end

---@param bindings table<string, string>
---@param positive string Action id driving the axis towards +1
---@param negative string Action id driving the axis towards -1
---@return number
local function axisValue(bindings, positive, negative)
    local value = 0
    if keys.isDown(bindings[positive]) then value = value + 1 end
    if keys.isDown(bindings[negative]) then value = value - 1 end

    return value
end

---World space axis pointing to the right of the screen, which the pitch pivots around.
---@return Vector4?
local function getScreenRight()
    local rotation = editor.getCameraRotation()
    if not rotation then return nil end

    return rotation:ToQuat():Transform(Vector4.new(1, 0, 0, 0))
end

---@return boolean
function previewControls.isActive()
    return previewControls.active
end

---Drops any manual manipulation, putting the next preview back on its automatic turntable and cycle.
function previewControls.reset()
    previewControls.active = false
    previewControls.yaw = 0
    previewControls.pitch = 0
    previewControls.zoom = 1
    previewControls.appearanceLocked = false
    previewControls.appearanceOffset = 0
end

---Polls the bound keys, must run once per frame for as long as a preview is alive.
function previewControls.update()
    -- Same rule as every other hotkey: a focused text field (e.g. the search bar) keeps the keys.
    if input.isUIInputActive() then return end

    -- Ctrl combos belong to the editor shortcuts (Ctrl + A / C / D / S ...), leave those alone.
    if ImGui.IsKeyDown(ImGuiKey.LeftCtrl) or ImGui.IsKeyDown(ImGuiKey.RightCtrl) then return end

    local bindings = previewControls.getBindings()

    -- Stepping the appearance does not count as taking the point of view over, it only stops the
    -- appearance cycle. The turntable keeps spinning.
    local step = 0
    if keys.isPressed(bindings.appearanceNext) then step = step + 1 end
    if keys.isPressed(bindings.appearancePrev) then step = step - 1 end

    if step ~= 0 then
        previewControls.appearanceLocked = true
        previewControls.appearanceOffset = previewControls.appearanceOffset + step
    end

    local delta = Cron.deltaTime or 0
    if delta <= 0 then return end

    -- Positive angles are the directions "orbit right" and "orbit up" read as on screen
    local yaw = axisValue(bindings, "orbitRight", "orbitLeft")
    local pitch = axisValue(bindings, "orbitDown", "orbitUp")
    local dolly = axisValue(bindings, "zoomIn", "zoomOut")

    if yaw == 0 and pitch == 0 and dolly == 0 then return end

    if keys.isDown(bindings.faster) then
        delta = delta * SPRINT_MULTIPLIER
    end

    -- Both axes wrap instead of clamping, so the asset can be rolled all the way over on either one
    previewControls.active = true
    previewControls.yaw = (previewControls.yaw + yaw * ORBIT_YAW_SPEED * delta) % 360
    previewControls.pitch = (previewControls.pitch + pitch * ORBIT_PITCH_SPEED * delta) % 360
    previewControls.zoom = math.min(MAX_ZOOM, math.max(MIN_ZOOM, previewControls.zoom * (ZOOM_RATE ^ (dolly * delta))))
end

---Lines of the on screen control hint, top to bottom.
---@param appearanceCount integer? Number of appearances the preview can cycle through.
---@return string[]
function previewControls.getHintLines(appearanceCount)
    appearanceCount = appearanceCount or 0

    if hintLines and hintAppearanceCount == appearanceCount then
        return hintLines
    end

    local bindings = previewControls.getBindings()

    local function pair(positive, negative)
        return keys.getShortLabel(bindings[positive]) .. " / " .. keys.getShortLabel(bindings[negative])
    end

    -- Both orbit axes share a line, left / right first then up / down
    local lines = {
        ("Orbit: %s / %s"):format(pair("orbitLeft", "orbitRight"), pair("orbitUp", "orbitDown")),
        ("Zoom: %s"):format(pair("zoomIn", "zoomOut"))
    }

    if appearanceCount > 1 then
        table.insert(lines, ("Appearance: %s"):format(pair("appearancePrev", "appearanceNext")))
    end

    -- Last, it modifies all of the above rather than doing anything on its own
    table.insert(lines, ("Faster: %s"):format(keys.getShortLabel(bindings.faster)))

    hintLines = lines
    hintAppearanceCount = appearanceCount

    return lines
end

---Tooltip body listing every preview action with the key it is currently bound to.
---Read from the bindings rather than hardcoded, so rebinding is reflected everywhere it is shown.
---@return string
function previewControls.getBindingsTooltip()
    local bindings = previewControls.getBindings()
    local lines = { "Keys available while a preview is showing:" }

    for _, action in ipairs(previewControls.actions) do
        table.insert(lines, string.format("- %s: %s", action.label, keys.getLabel(bindings[action.id])))
    end

    table.insert(lines, "")
    table.insert(lines, "Moving the point of view stops the automatic turntable, stepping the appearance stops the automatic cycle.")
    table.insert(lines, "They can be rebound in the \"Settings\" tab, under \"Bindings\".")

    return table.concat(lines, "\n")
end

---Appearance index the preview should show, given the one its automatic cycle last picked.
---@param cycleIndex integer Index the automatic cycle is at, 0 based.
---@param count integer Number of entries to wrap around, must be > 0.
---@return integer index 0 based, wrapped into [0, count)
function previewControls.getAppearanceIndex(cycleIndex, count)
    if count <= 0 then
        return 0
    end

    return (cycleIndex + previewControls.appearanceOffset) % count
end

---Applies the manual orbit on top of the rotation a preview had when it got taken over.
---The orbit turns around the world up axis and the pitch around the screen right axis, so both stay
---predictable no matter how far the asset has already been turned.
---@param base EulerAngles Rotation captured while the preview was still spinning on its own.
---@return EulerAngles
function previewControls.applyOrbit(base)
    local rotation = utils.multQuat(Quaternion.SetAxisAngle(Vector4.new(0, 0, 1, 0), Deg2Rad(previewControls.yaw)), base:ToQuat())

    local right = getScreenRight()
    if right then
        rotation = utils.multQuat(Quaternion.SetAxisAngle(right, Deg2Rad(previewControls.pitch)), rotation)
    end

    return rotation:ToEulerAngles()
end

---Turns a preview spawnable, either on its automatic turntable or from the keyboard once taken over.
---While automatic, the current rotation is kept as the base the manual orbit will start from, so
---taking over does not snap the asset back to where it started.
---@param instance spawnable
---@param autoSpeed number Degrees per second of the automatic turntable.
function previewControls.updateTurntable(instance, autoSpeed)
    if previewControls.active then
        instance.rotation = previewControls.applyOrbit(instance.assetPreviewBaseRotation or instance.rotation)
        return
    end

    local spin = Quaternion.SetAxisAngle(Vector4.new(0, 0, 1, 0), Deg2Rad(autoSpeed * (Cron.deltaTime or 0)))
    instance.rotation = utils.multQuat(instance.rotation:ToQuat(), spin):ToEulerAngles()
    instance.assetPreviewBaseRotation = instance.rotation
end

return previewControls
