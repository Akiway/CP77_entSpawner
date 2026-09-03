local utils = require("modules/utils/core/utils")

---Shared `gameTransformAnimatorComponent` data: the clip names the engine reserves, the schemas the
---quick setup builds its UI from, and the value helpers the popup and the device spawnable share.
---
---A transform animator is an array of named clips. Each clip is a timeline; each timeline item is a
---`startTime`, a `duration`, and one `impl` that does the actual work -- move, rotate, spawn an
---effect, play a sound. Unlike an `.anims` clip this is all plain struct data on the component, so
---everything a designer would want to change -- travel distance, swing angle, duration, easing --
---is reachable through instance data.
---
---Two facts shape the whole design of this module:
---
---1. **A door only ever plays four clip names.** `Door.GetProperTransformAnimName()` maps
---   `doorOpeningType` (and, for `TRANSFORM_TWO_SIDES`, which trigger volume the player is in) onto
---   one of `DOOR_CLIPS` below. A clip named anything else on a door is dead weight unless a
---   `PlayTransformAnimationDeviceOperation` fires it by name.
---2. **Every handle slot on a track item is abstract.** `impl`, `movement`, and both position and
---   rotation evaluators declare abstract bases (class flag bit 0 set in the RTTI dump), so nothing
---   here can be materialised by name the way `triggerData` is in deviceOperations.lua -- creating
---   one always needs an explicit class choice from the user. See `IMPL_TYPES` / `EVALUATOR_TYPES`.
---
---Field schemas are read from the RTTI dump; enum member lists are the RED JSON values (enums
---serialize as their member name). Shipped values quoted in comments were read out of
---`base\gameplay\devices\doors\single_door\tech_hinged_door.ent` and
---`base\gameplay\devices\doors\gates\mall_shutter_w150_h250.ent`.
---@class transformAnimations
local transformAnimations = {}

transformAnimations.ANIMATOR_CLASS = "gameTransformAnimatorComponent"
transformAnimations.ROOT_ANIMATOR_CLASS = "gameRootTransformAnimatorComponent"
transformAnimations.DEFINITION_CLASS = "gameTransformAnimationDefinition"
transformAnimations.TIMELINE_CLASS = "gameTransformAnimationTimeline"
transformAnimations.TRACK_ITEM_CLASS = "gameTransformAnimationTrackItem"
transformAnimations.IMPL_BASE_CLASS = "gameTransformAnimationTrackItemImpl"
transformAnimations.MOVEMENT_BASE_CLASS = "gameTransformAnimation_Movement"
transformAnimations.POSITION_BASE_CLASS = "gameTransformAnimation_Position"
transformAnimations.ROTATION_BASE_CLASS = "gameTransformAnimation_Rotation"

transformAnimations.PLAY_SOUND_CLASS = "gameTransformAnimation_PlaySound"

transformAnimations.DOOR_ENTITY_CLASS = "Door"
transformAnimations.DOOR_PS_CLASS = "DoorControllerPS"
transformAnimations.ANIMATED_COMPONENT_CLASS = "entAnimatedComponent"

---Paths into a converted component. `ANIMATIONS_PATH` is relative to the animator component;
---`DOOR_*` are relative to the door's controller component and to the entity chunk (`"0"`).
transformAnimations.ANIMATIONS_PATH = { "animations" }
transformAnimations.DOOR_PROPERTIES_PATH = { "persistentState", "Data", "doorProperties" }
transformAnimations.OPENING_SPEED_PATH = { "persistentState", "Data", "doorProperties", "openingSpeed" }
transformAnimations.OPENING_TIME_PATH = { "persistentState", "Data", "doorProperties", "doorOpeningTime" }
transformAnimations.ANIMATION_TYPE_PATH = { "animationType" }
transformAnimations.OPENING_TYPE_PATH = { "doorOpeningType" }
transformAnimations.AUTO_CLOSE_DELAY_PATH = { "automaticCloseDelay" }
transformAnimations.CLOSING_LENGTH_PATH = { "closingAnimationLength" }

---Enum member names, in declaration order. RED JSON stores the name, not the ordinal.
transformAnimations.ENUMS = {
    EEasingType = { "EET_In", "EET_Out", "EET_InOut" },
    ETransitionType = {
        "EET_Linear", "EET_Sine", "EET_Cubic", "EET_Quad", "EET_Quart", "EET_Quint",
        "EET_Expo", "EET_Circ", "EET_Back", "EET_Bounce", "EET_Elastic"
    },
    gameTransformAnimation_RotateOnAxisAxis = { "X", "Y", "Z" },
    gameTransformAnimation_MoveOnSplineRotationMode = { "Disabled", "Yaw", "PitchAndYaw" },
    EAnimationType = { "REGULAR", "TRANSFORM", "TRANSFORM_TWO_SIDES", "NONE" },
    EDoorOpeningType = {
        "SLIDING_HORIZONTALLY", "SLIDING_VERTICALLY", "HINGED",
        "GATE", "HINGED_SIDE_ONE", "HINGED_SIDE_TWO"
    }
}

-- Door clip catalogue ----------------------------------------------------------------------------

---The four names `Door.GetProperTransformAnimName()` can return, in the order the switch tests them.
---`openingType` is the `EDoorOpeningType` that selects the clip; `doorOpenHingedBack` is selected by
---the same `HINGED` value and only differs by which side the player approaches from.
transformAnimations.DOOR_CLIPS = {
    {
        name = "doorSlideHorizontally",
        label = "Slide horizontally",
        openingType = "SLIDING_HORIZONTALLY",
        hint = "Closing replays this clip with a negated timeScale."
    },
    {
        name = "doorSlideVertically",
        label = "Slide vertically",
        openingType = "SLIDING_VERTICALLY",
        hint = "Shutters and roll-ups. Closing replays this clip with a negated timeScale."
    },
    {
        name = "doorOpenHinged",
        label = "Swing (default side)",
        openingType = "HINGED",
        hint = "Played for HINGED unless the door is TRANSFORM_TWO_SIDES and the player stands in SideOne."
    },
    {
        name = "doorOpenHingedBack",
        label = "Swing (from side one)",
        openingType = "HINGED",
        requiresTwoSides = true,
        -- The two-sided branch does not negate timeScale on close, so this one has to be authored as
        -- a complete there-and-back motion rather than a one-way swing.
        hint = "TRANSFORM_TWO_SIDES only. Not reversed on close, so author it as a full open-and-return motion."
    }
}

---`EDoorOpeningType` values the transform path has no case for. Setting one of these on a
---TRANSFORM door makes `GetProperTransformAnimName()` return `n"None"` and nothing plays; they are
---only meaningful on the REGULAR path, where the value is handed to the animgraph instead.
transformAnimations.UNMAPPED_OPENING_TYPES = {
    GATE = true,
    HINGED_SIDE_ONE = true,
    HINGED_SIDE_TWO = true
}

---`EAnimationType` values that route through the transform animator at all.
transformAnimations.TRANSFORM_ANIMATION_TYPES = {
    TRANSFORM = true,
    TRANSFORM_TWO_SIDES = true
}

-- Value helpers ----------------------------------------------------------------------------------

---@param value string?
---@return table
function transformAnimations.cname(value)
    return { ["$type"] = "CName", ["$storage"] = "string", ["$value"] = tostring(value or "") }
end

---@param data any
---@return string
function transformAnimations.readCName(data)
    if type(data) ~= "table" then return "" end
    local value = tostring(data["$value"] or "")
    if value == "None" then return "" end
    return value
end

---@param value string?
---@return table
function transformAnimations.nodeRef(value)
    return { ["$type"] = "NodeRef", ["$storage"] = "string", ["$value"] = tostring(value or "") }
end

---@param data any
---@return string
function transformAnimations.readRawValue(data)
    if type(data) ~= "table" then return "" end
    return tostring(data["$value"] or "")
end

---@param x number?
---@param y number?
---@param z number?
---@return table
function transformAnimations.vector3(x, y, z)
    return { ["$type"] = "Vector3", X = x or 0, Y = y or 0, Z = z or 0 }
end

---@param data any
---@return number x
---@return number y
---@return number z
function transformAnimations.readVector3(data)
    if type(data) ~= "table" then return 0, 0, 0 end
    return utils.toNumber(data.X, 0), utils.toNumber(data.Y, 0), utils.toNumber(data.Z, 0)
end

---@param data any
---@return boolean
function transformAnimations.readBool(value)
    return value == 1 or value == true
end

---`numberOfFullRotations` is stored as a fraction of a turn: 0.25 is a 90 degree swing, and the
---sign picks the direction. Every UI surface should show degrees -- nobody wants to type 0.4722 for
---170 degrees -- so the conversion lives here rather than in the popup.
---@param rotations number?
---@return number degrees
function transformAnimations.rotationsToDegrees(rotations)
    return utils.toNumber(rotations, 0) * 360
end

---@param degrees number?
---@return number rotations
function transformAnimations.degreesToRotations(degrees)
    return utils.toNumber(degrees, 0) / 360
end

-- Easing -----------------------------------------------------------------------------------------

---An `EasingFunction` is a struct of two enums, so the 3 x 11 grid is 33 usable curves. Presenting
---them as two separate combos makes the user hold the pairing in their head; this flattens them into
---one labelled list, built once at load.
---@type { easingType: string, transitionType: string, label: string }[]
transformAnimations.EASING_COMBOS = {}

---@type table<string, number>
local easingComboIndexByKey = {}

do
    -- "EET_" prefixes both enums and carries no information for a reader.
    local function pretty(member)
        return (tostring(member):gsub("^EET_", ""))
    end

    for _, transitionType in ipairs(transformAnimations.ENUMS.ETransitionType) do
        for _, easingType in ipairs(transformAnimations.ENUMS.EEasingType) do
            local combo = {
                easingType = easingType,
                transitionType = transitionType,
                label = string.format("%s / %s", pretty(transitionType), pretty(easingType))
            }
            table.insert(transformAnimations.EASING_COMBOS, combo)
            easingComboIndexByKey[easingType .. "|" .. transitionType] = #transformAnimations.EASING_COMBOS
        end
    end
end

---@type string[]
transformAnimations.EASING_LABELS = {}
for _, combo in ipairs(transformAnimations.EASING_COMBOS) do
    table.insert(transformAnimations.EASING_LABELS, combo.label)
end

---Zero-based index into `EASING_COMBOS`, for a combo widget.
---@param easingType string?
---@param transitionType string?
---@return number index Zero-based; 0 (Linear / In) when the pair is unknown
function transformAnimations.easingComboIndex(easingType, transitionType)
    local index = easingComboIndexByKey[tostring(easingType) .. "|" .. tostring(transitionType)]
    return index and (index - 1) or 0
end

---@param index number Zero-based index into `EASING_COMBOS`
---@return string easingType
---@return string transitionType
function transformAnimations.easingComboValues(index)
    local combo = transformAnimations.EASING_COMBOS[(index or 0) + 1]
    if not combo then return "EET_In", "EET_Linear" end
    return combo.easingType, combo.transitionType
end

-- Schemas ------------------------------------------------------------------------------------------
--
-- Same declarative shape the device operations panel uses: `path` is relative to the object that
-- owns the field, and `kind` picks the widget. Kinds shared with deviceOperations.lua behave the
-- same way (cname | noderef | bool | int | float | enum); the three added here are:
--
--   degrees  a Float stored as fractions of a turn, edited in degrees (see rotationsToDegrees)
--   vector3  a Vector3 struct, edited as three drags
--   easing   the paired EasingFunction enums, edited as one combo

---Clip-level fields, relative to a `gameTransformAnimationDefinition`.
transformAnimations.DEFINITION_FIELDS = {
    { path = { "timeScale" }, label = "Time scale", kind = "float",
      hint = "Multiplies the whole clip. The door also divides by openingSpeed on top of this." },
    { path = { "timesToPlay" }, label = "Times to play", kind = "int" },
    { path = { "looping" }, label = "Looping", kind = "bool" },
    { path = { "reverse" }, label = "Reverse", kind = "bool" },
    { path = { "autoStart" }, label = "Auto start", kind = "bool",
      hint = "Plays on attach without waiting for a device state change. Off on every shipped door." },
    { path = { "autoStartDelay" }, label = "Auto start delay", kind = "float" }
}

---Track-level fields, relative to a `gameTransformAnimationTrackItem`.
transformAnimations.TRACK_ITEM_FIELDS = {
    { path = { "startTime" }, label = "Start time", kind = "float" },
    { path = { "duration" }, label = "Duration", kind = "float" }
}

---The concrete `gameTransformAnimationTrackItemImpl` classes, keyed by the class the handle holds.
---`motion` marks the ones that move the mesh -- used to pick a clip's primary track when a timeline
---carries several items (a shipped hinged door runs its 1 s rotation alongside a 3 s dust effect).
transformAnimations.IMPL_TYPES = {
    {
        class = "gameTransformAnimation_Move", label = "Move", motion = true,
        hint = "Moves between two evaluated positions. Both stock sliding doors use this.",
        fields = {},
        evaluators = {
            { path = { "startPositionEvaluator" }, label = "Start position", base = "position",
              default = "gameTransformAnimation_Position_InitialPosition" },
            { path = { "targetPositionEvaluator" }, label = "Target position", base = "position",
              default = "gameTransformAnimation_Position_LocalPosition" }
        },
        movementPath = { "movement" },
        movementDefault = "gameTransformAnimation_Movement_PredefinedFunction"
    },
    {
        class = "gameTransformAnimation_RotateOnAxis", label = "Rotate on axis", motion = true,
        hint = "Spins around one local axis. Both stock hinged clips use this.",
        fields = {
            { path = { "axis" }, label = "Axis", kind = "enum", enum = "gameTransformAnimation_RotateOnAxisAxis" },
            -- Shipped: 0.25 (90 deg) on tech_hinged_door, 0.45 (162 deg) on the mall shutter.
            { path = { "numberOfFullRotations" }, label = "Angle", kind = "degrees",
              hint = "Stored as fractions of a full turn. Negative swings the other way." },
            -- Zero on every shipped door, and the RTTI gives no unit, so it is exposed raw rather
            -- than converted to degrees on a guess.
            { path = { "startAngle" }, label = "Start angle", kind = "float",
              hint = "Zero on every shipped door; unit not established." },
            { path = { "reverseDirection" }, label = "Reverse direction", kind = "bool" }
        },
        movementPath = { "movement" },
        movementDefault = "gameTransformAnimation_Movement_PredefinedFunction"
    },
    {
        class = "gameTransformAnimation_RotateFromTo", label = "Rotate from / to", motion = true,
        hint = "Quaternion to quaternion. No stock door uses it; needed for arcs the axis form cannot express.",
        fields = {},
        evaluators = {
            { path = { "startRotationEvaluator" }, label = "Start rotation", base = "rotation",
              default = "gameTransformAnimation_Rotation_InitialRotation" },
            { path = { "targetRotationEvaluator" }, label = "Target rotation", base = "rotation",
              default = "gameTransformAnimation_Rotation_LocalRotation" }
        },
        movementPath = { "movement" },
        movementDefault = "gameTransformAnimation_Movement_PredefinedFunction"
    },
    {
        class = "gameTransformAnimation_MoveOnSpline", label = "Move on spline", motion = true,
        hint = "Follows a placed worldSplineNode between two normalised positions.",
        fields = {
            { path = { "splineNode" }, label = "Spline node", kind = "noderef" },
            { path = { "from" }, label = "From", kind = "float" },
            { path = { "to" }, label = "To", kind = "float" },
            { path = { "rotationMode" }, label = "Rotation", kind = "enum",
              enum = "gameTransformAnimation_MoveOnSplineRotationMode" }
        },
        movementPath = { "movement" },
        movementDefault = "gameTransformAnimation_Movement_PredefinedFunction"
    },
    {
        class = "gameTransformAnimation_SpawnEffect", label = "Spawn effect",
        hint = "Starts a named effect. tech_hinged_door runs dust_falling on its own 3 s track.",
        fields = {
            { path = { "effectName" }, label = "Effect", kind = "cname", width = 240 },
            { path = { "effectTag" }, label = "Tag", kind = "cname", width = 240 },
            { path = { "persistOnDetach" }, label = "Persist on detach", kind = "bool" }
        }
    },
    {
        class = "gameTransformAnimation_KillEffect", label = "Kill effect",
        fields = {
            { path = { "effectTag" }, label = "Tag", kind = "cname", width = 240 }
        }
    },
    {
        class = "gameTransformAnimation_BreakEffectLoop", label = "Break effect loop",
        fields = {
            { path = { "effectTag" }, label = "Tag", kind = "cname", width = 240 }
        }
    },
    {
        class = "gameTransformAnimation_PlaySound", label = "Play sound",
        hint = "Timeline-anchored audio, separate from the open / close / force_open metadata events the door fires.",
        fields = {
            -- `oneShot`: the track fires the event and nothing ever stops it. A looping event
            -- started here runs until the entity is destroyed, so the picker offers only events that
            -- end on their own. Typing one in still works, for a loop that is genuinely wanted.
            { path = { "soundName" }, label = "Sound", kind = "cname", width = 240, oneShot = true },
            { path = { "unique" }, label = "Unique", kind = "bool" }
        }
    }
}

---Concrete `gameTransformAnimation_Movement` classes.
transformAnimations.MOVEMENT_TYPES = {
    {
        class = "gameTransformAnimation_Movement_PredefinedFunction", label = "Preset curve",
        easingPath = { "function" }
    },
    {
        class = "gameTransformAnimation_Movement_CurveSet", label = "Curve set",
        hint = "Declares no fields of its own.",
        fields = {}
    },
    {
        -- `curveData:Float` has no redConverter handling, so this class round-trips but cannot be
        -- edited here. Offering it in a picker would hand the user a dead end; it stays listed so an
        -- existing one is still recognised and labelled rather than showing as an unknown class.
        class = "gameTransformAnimation_Movement_CustomCurve", label = "Custom curve",
        hint = "Hand-authored curve data. Not editable in the editor -- edit under Entity Instance Data.",
        unsupported = true,
        fields = {}
    }
}

---Concrete `gameTransformAnimation_Position` classes, for a `_Move`'s two evaluators.
transformAnimations.POSITION_TYPES = {
    {
        class = "gameTransformAnimation_Position_InitialPosition", label = "Where it started",
        hint = "The component's own position when the clip begins, plus an optional offset.",
        fields = {
            { path = { "offset" }, label = "Offset", kind = "vector3" },
            { path = { "offsetInWorldSpace" }, label = "Offset in world space", kind = "bool" }
        }
    },
    {
        class = "gameTransformAnimation_Position_LocalPosition", label = "Local position",
        hint = "A position in the entity's own space. This is the travel distance on a sliding door.",
        fields = {
            { path = { "position" }, label = "Position", kind = "vector3" }
        }
    },
    {
        class = "gameTransformAnimation_Position_MarkerPosition", label = "Marker node",
        fields = {
            { path = { "markerNode" }, label = "Marker", kind = "noderef" },
            { path = { "offset" }, label = "Offset", kind = "vector3" }
        }
    }
}

---Concrete `gameTransformAnimation_Rotation` classes, for a `_RotateFromTo`'s two evaluators.
transformAnimations.ROTATION_TYPES = {
    {
        class = "gameTransformAnimation_Rotation_InitialRotation", label = "Where it started",
        hint = "Declares no fields of its own.",
        fields = {}
    },
    {
        class = "gameTransformAnimation_Rotation_CurrentRotation", label = "Current rotation + offset",
        fields = {
            { path = { "offset" }, label = "Offset", kind = "quaternion" }
        }
    },
    {
        class = "gameTransformAnimation_Rotation_LocalRotation", label = "Local rotation",
        fields = {
            { path = { "rotation" }, label = "Rotation", kind = "quaternion" }
        }
    },
    {
        class = "gameTransformAnimation_Rotation_MarkerRotation", label = "Marker node",
        fields = {
            { path = { "markerNode" }, label = "Marker", kind = "noderef" },
            { path = { "offset" }, label = "Offset", kind = "vector3" }
        }
    }
}

-- Construction -------------------------------------------------------------------------------------

---The abstract handle slots a freshly created impl leaves null, and the concrete class to put in
---each.
---
---`redConverter`'s `synthesizeNullHandles` fills a null handle only when the declared inner type is
---concrete, and every slot here declares an abstract base -- so `NewObject("gameTransformAnimation_Move")`
---comes back with `movement` and both evaluators null. A track built from that plays nothing and
---hands the engine null handles to walk, so the creator has to fill them.
---@param implClass string
---@return { path: table, class: string }[]
function transformAnimations.getTrackSlotDefaults(implClass)
    local implType = transformAnimations.getImplType(implClass)
    if not implType then return {} end

    local slots = {}

    for _, evaluator in ipairs(implType.evaluators or {}) do
        if evaluator.default then
            table.insert(slots, { path = evaluator.path, class = evaluator.default })
        end
    end

    if implType.movementPath and implType.movementDefault then
        table.insert(slots, { path = implType.movementPath, class = implType.movementDefault })
    end

    return slots
end

---A new, empty clip.
---
---Built literally rather than through `NewObject`: `gameTransformAnimationDefinition` and its
---timeline are plain structs, and writing the full shape here keeps the result identical whether it
---is applied to the live component or exported, with no reliance on what the RTTI constructor
---happens to default.
---@param name string
---@return table
function transformAnimations.newDefinition(name)
    return {
        ["$type"] = transformAnimations.DEFINITION_CLASS,
        name = transformAnimations.cname(name),
        autoStart = 0,
        autoStartDelay = 0,
        looping = 0,
        reverse = 0,
        timeScale = 1,
        timesToPlay = 1,
        timeline = {
            ["$type"] = transformAnimations.TIMELINE_CLASS,
            items = {}
        }
    }
end

---A new track item wrapping an already built impl handle.
---@param implHandle table A `{ HandleId, Data }` wrapper
---@param startTime number?
---@param duration number?
---@return table
function transformAnimations.newTrackItem(implHandle, startTime, duration)
    return {
        ["$type"] = transformAnimations.TRACK_ITEM_CLASS,
        startTime = startTime or 0,
        duration = duration or 1,
        impl = implHandle
    }
end

---Reserved door clip names not present on the animator, in `DOOR_CLIPS` order.
---@param animations table?
---@return table[] clips Entries from `DOOR_CLIPS`
function transformAnimations.missingDoorClips(animations)
    local missing = {}

    for _, clip in ipairs(transformAnimations.DOOR_CLIPS) do
        if not transformAnimations.findDefinition(animations, clip.name) then
            table.insert(missing, clip)
        end
    end

    return missing
end

---@param list table[]
---@param class string
---@return table?
local function findByClass(list, class)
    for _, entry in ipairs(list) do
        if entry.class == class then return entry end
    end
    return nil
end

---@param class string
---@return table?
function transformAnimations.getImplType(class)
    return findByClass(transformAnimations.IMPL_TYPES, class)
end

---@param class string
---@return table?
function transformAnimations.getMovementType(class)
    return findByClass(transformAnimations.MOVEMENT_TYPES, class)
end

---Evaluator catalogue for an `evaluators` entry's `base`.
---@param base string "position" | "rotation"
---@return table[]
function transformAnimations.getEvaluatorTypes(base)
    if base == "rotation" then return transformAnimations.ROTATION_TYPES end
    return transformAnimations.POSITION_TYPES
end

---@param base string "position" | "rotation"
---@param class string
---@return table?
function transformAnimations.getEvaluatorType(base, class)
    return findByClass(transformAnimations.getEvaluatorTypes(base), class)
end

---Human label for any of the classes catalogued above, falling back to the raw class name.
---@param class string
---@return string
function transformAnimations.getClassLabel(class)
    for _, list in ipairs({
        transformAnimations.IMPL_TYPES,
        transformAnimations.MOVEMENT_TYPES,
        transformAnimations.POSITION_TYPES,
        transformAnimations.ROTATION_TYPES
    }) do
        local entry = findByClass(list, class)
        if entry then return entry.label end
    end
    return tostring(class)
end

-- Reading a loaded animator ----------------------------------------------------------------------

---@param handle any A `{ HandleId, Data }` wrapper
---@return table?
function transformAnimations.handleData(handle)
    if type(handle) ~= "table" then return nil end
    return type(handle.Data) == "table" and handle.Data or nil
end

---@param handle any
---@return string
function transformAnimations.handleClass(handle)
    local data = transformAnimations.handleData(handle)
    return data and tostring(data["$type"] or "") or ""
end

---@param definition table? A `gameTransformAnimationDefinition`
---@return string
function transformAnimations.definitionName(definition)
    if type(definition) ~= "table" then return "" end
    return transformAnimations.readCName(definition.name)
end

---@param animations table? The animator's `animations` array
---@param name string
---@return table? definition
---@return number? index
function transformAnimations.findDefinition(animations, name)
    if type(animations) ~= "table" then return nil, nil end

    for index, definition in ipairs(animations) do
        if transformAnimations.definitionName(definition) == name then
            return definition, index
        end
    end

    return nil, nil
end

---@param definition table? A `gameTransformAnimationDefinition`
---@return table[] items
function transformAnimations.timelineItems(definition)
    if type(definition) ~= "table" then return {} end
    local timeline = definition.timeline
    if type(timeline) ~= "table" or type(timeline.items) ~= "table" then return {} end
    return timeline.items
end

---The track that actually moves the mesh. A shipped timeline carries the motion alongside effect
---tracks with unrelated durations, so "how long is this clip" has to mean the motion track and not
---simply the first item or the longest one.
---@param definition table? A `gameTransformAnimationDefinition`
---@return table? item
---@return number? index
function transformAnimations.findMotionTrack(definition)
    for index, item in ipairs(transformAnimations.timelineItems(definition)) do
        local implType = transformAnimations.getImplType(transformAnimations.handleClass(item.impl))
        if implType and implType.motion then
            return item, index
        end
    end
    return nil, nil
end

---One line describing what a track does, for a collapsed header.
---
---Folding the tracks away only helps if the closed row still says which one to open, so this reports
---the value that distinguishes the track -- the angle, the travel, the effect or sound name -- rather
---than repeating the class.
---@param item table? A `gameTransformAnimationTrackItem`
---@return string
function transformAnimations.describeTrack(item)
    local implData = transformAnimations.handleData(item and item.impl)
    if not implData then return "" end

    local class = tostring(implData["$type"] or "")

    if class == "gameTransformAnimation_RotateOnAxis" then
        local degrees = transformAnimations.rotationsToDegrees(implData.numberOfFullRotations)
        local axis = tostring(implData.axis or "?")
        local reversed = transformAnimations.readBool(implData.reverseDirection) and " reversed" or ""
        return string.format("%s %.0f deg%s", axis, degrees, reversed)
    end

    if class == "gameTransformAnimation_Move" then
        local target = transformAnimations.handleData(implData.targetPositionEvaluator)
        if target and target["$type"] == "gameTransformAnimation_Position_LocalPosition" then
            local x, y, z = transformAnimations.readVector3(target.position)
            return string.format("to %.2f, %.2f, %.2f", x, y, z)
        end
        return target and transformAnimations.getClassLabel(tostring(target["$type"] or "")) or ""
    end

    if class == "gameTransformAnimation_MoveOnSpline" then
        return string.format("spline %.2f to %.2f",
            utils.toNumber(implData.from, 0), utils.toNumber(implData.to, 0))
    end

    if class == "gameTransformAnimation_SpawnEffect" then
        return transformAnimations.readCName(implData.effectName)
    end

    if class == "gameTransformAnimation_KillEffect" or class == "gameTransformAnimation_BreakEffectLoop" then
        return transformAnimations.readCName(implData.effectTag)
    end

    if class == "gameTransformAnimation_PlaySound" then
        return transformAnimations.readCName(implData.soundName)
    end

    return ""
end

---Every clip name present on the animator, in array order.
---@param animations table?
---@return string[]
function transformAnimations.listDefinitionNames(animations)
    local names = {}
    for _, definition in ipairs(type(animations) == "table" and animations or {}) do
        table.insert(names, transformAnimations.definitionName(definition))
    end
    return names
end

-- Door wiring --------------------------------------------------------------------------------------

---Which of the four reserved clips a door will actually play, given its two enums. Mirrors
---`Door.GetProperTransformAnimName()`, including its lack of a case for GATE and the two
---HINGED_SIDE_* values.
---@param openingType string? `EDoorOpeningType` member name
---@param animationType string? `EAnimationType` member name
---@param fromSideOne boolean? Player standing in the SideOne trigger volume
---@return string? clipName nil when the engine would return n"None"
function transformAnimations.clipForDoor(openingType, animationType, fromSideOne)
    if openingType == "SLIDING_HORIZONTALLY" then return "doorSlideHorizontally" end
    if openingType == "SLIDING_VERTICALLY" then return "doorSlideVertically" end

    if openingType == "HINGED" then
        if animationType == "TRANSFORM_TWO_SIDES" and fromSideOne then
            return "doorOpenHingedBack"
        end
        return "doorOpenHinged"
    end

    return nil
end

---@param animationType string?
---@return boolean
function transformAnimations.usesTransformAnimator(animationType)
    return transformAnimations.TRANSFORM_ANIMATION_TYPES[tostring(animationType)] == true
end

---@param openingType string?
---@return boolean
function transformAnimations.isUnmappedOpeningType(openingType)
    return transformAnimations.UNMAPPED_OPENING_TYPES[tostring(openingType)] == true
end

-- Spawnable queries --------------------------------------------------------------------------------

---The animator component to drive the panel from, or nil when the entity has none.
---
---Gate the UI on this, never on a device class: `q113_sliding_wall.ent` is a TRANSFORM door with no
---animator component at all, and instance data overrides existing components only -- it cannot add
---one. Root animators are accepted too; they carry the identical `animations` array.
---@param spawnable table entity spawnable
---@return string? componentID
function transformAnimations.findAnimatorComponentID(spawnable)
    if type(spawnable) ~= "table" or type(spawnable.findComponentIDByType) ~= "function" then
        return nil
    end

    return spawnable:findComponentIDByType(transformAnimations.ANIMATOR_CLASS)
        or spawnable:findComponentIDByType(transformAnimations.ROOT_ANIMATOR_CLASS)
end

---Whether to offer the panel at all.
---
---Deliberately *not* `findAnimatorComponentID(...) ~= nil`: `defaultComponentData` holds only the PS
---controller until something forces a full load, so that check is false on a freshly spawned device
---and the button would never appear. `hasTransformAnimator` is set from the live component list at
---assemble instead; the panel force-loads the rest when it opens.
---@param spawnable table entity spawnable
---@return boolean
function transformAnimations.supportsTransformAnimations(spawnable)
    return type(spawnable) == "table" and spawnable.hasTransformAnimator == true
end

---Make sure the animator is present in `defaultComponentData`, loading it if this is the first time
---anything asked for it. Call on popup open, not per frame -- a full load converts every component.
---@param spawnable table entity spawnable
---@return string? componentID
function transformAnimations.ensureAnimatorLoaded(spawnable)
    local componentID = transformAnimations.findAnimatorComponentID(spawnable)
    if componentID then return componentID end

    if type(spawnable) ~= "table" or type(spawnable.loadInstanceData) ~= "function" then
        return nil
    end

    local entityRef = spawnable.getEntity and spawnable:getEntity() or nil
    if not entityRef then return nil end

    local ok = pcall(function ()
        spawnable:loadInstanceData(entityRef, true)
    end)
    if not ok then return nil end

    return transformAnimations.findAnimatorComponentID(spawnable)
end

---Names of the components parented to the animator, i.e. the things a clip actually moves.
---
---**A transform animator moves its own transform and nothing else.** Anything that should travel
---with it binds to it through `parentTransform` -> `entHardTransformBinding.bindName`. Measured
---across shipped doors:
---
---  tech_hinged_door.ent      TRANSFORM  entMeshComponent "Mesh2812" -> DoorTransformAnimator
---  mall_shutter_w150.ent     REGULAR    entAnimatedComponent "anim" -> DoorTransformAnimator
---  double_door_simple_1.ent  REGULAR    nothing bound
---
---CDPR's door template carries a fully populated `DoorTransformAnimator` on *every* door, bound or
---not, so the presence of four clips says nothing about whether they can move anything. Only this
---does. Requires a full instance data load -- call `ensureAnimatorLoaded` first.
---@param spawnable table entity spawnable
---@param componentID string The animator's component ID
---@return string[] names
function transformAnimations.getAnimatorBoundComponents(spawnable, componentID)
    local components = type(spawnable) == "table" and spawnable.defaultComponentData or nil
    if type(components) ~= "table" then return {} end

    local animator = components[componentID]
    if type(animator) ~= "table" then return {} end

    local animatorName = transformAnimations.readCName(animator.name)
    if animatorName == "" then return {} end

    local bound = {}

    for id, component in pairs(components) do
        if id ~= componentID and type(component) == "table" then
            local parent = component.parentTransform
            local binding = type(parent) == "table" and type(parent.Data) == "table" and parent.Data or nil
            if binding and transformAnimations.readCName(binding.bindName) == animatorName then
                table.insert(bound, transformAnimations.readCName(component.name))
            end
        end
    end

    table.sort(bound)

    return bound
end

---Is the entity chunk a `Door` (or a subclass the editor already knows), i.e. should the panel show
---the door-specific rows -- clip mapping, animation type, the linked speed control?
---@param spawnable table entity spawnable
---@return boolean
function transformAnimations.isDoorEntity(spawnable)
    local entityChunk = type(spawnable) == "table" and (spawnable.defaultComponentData or {})["0"] or nil
    if type(entityChunk) ~= "table" then return false end

    local class = tostring(entityChunk["$type"] or "")
    if class == "" then return false end

    local isDoor = false
    pcall(function ()
        local reflected = Reflection.GetClass(class)
        while reflected do
            if reflected:GetName().value == transformAnimations.DOOR_ENTITY_CLASS then
                isDoor = true
                return
            end
            reflected = reflected:GetParent()
        end
    end)

    return isDoor
end

-- Validation ---------------------------------------------------------------------------------------

---Problems worth surfacing for one door, given what is actually on the entity. Returns plain
---strings so the popup decides how to present them.
---@param animations table? The animator's `animations` array
---@param animationType string?
---@param openingType string?
---@param boundComponents string[]? From `getAnimatorBoundComponents`
---@return string[] problems
---@return string[] notes
function transformAnimations.checkDoorSetup(animations, animationType, openingType, boundComponents)
    local problems, notes = {}, {}
    local boundCount = #(boundComponents or {})

    -- Checked before anything else, and on both paths: a clip that moves an animator no component
    -- is parented to is invisible, so every other diagnosis below would be a distraction.
    if boundCount == 0 then
        table.insert(problems,
            "Nothing on this entity is parented to the animator, so its clips move nothing visible. "
            .. "Switching to TRANSFORM will stop the door animating rather than start it.")
    end

    if not transformAnimations.usesTransformAnimator(animationType) then
        if animationType == "NONE" then
            table.insert(notes, "Animation type is NONE: the door changes state but never moves.")
        elseif boundCount > 0 then
            local populated = 0
            for _, clip in ipairs(transformAnimations.DOOR_CLIPS) do
                if transformAnimations.findDefinition(animations, clip.name) then
                    populated = populated + 1
                end
            end
            -- The mall shutter is this case: REGULAR, four complete clips nothing plays, and its
            -- animated component *is* parented to the animator -- so flipping the type works there.
            -- The promise is only safe once the binding above has been confirmed.
            if populated > 0 then
                table.insert(notes, string.format(
                    "Animation type is REGULAR, so these %d clip%s %s ignored. %s follow%s the animator, so switching to TRANSFORM would play them.",
                    populated, populated == 1 and "" or "s", populated == 1 and "is" or "are",
                    table.concat(boundComponents, ", "), boundCount == 1 and "s" or ""))
            else
                table.insert(notes, "Animation type is REGULAR: motion comes from the animgraph, not from these clips.")
            end
        else
            table.insert(notes, "Animation type is REGULAR: motion comes from the animgraph, not from these clips.")
        end
        return problems, notes
    end

    if transformAnimations.isUnmappedOpeningType(openingType) then
        table.insert(problems, string.format(
            "Opening type %s has no transform mapping: the door plays nothing. Use SLIDING_HORIZONTALLY, SLIDING_VERTICALLY or HINGED.",
            tostring(openingType)))
        return problems, notes
    end

    local expected = transformAnimations.clipForDoor(openingType, animationType, false)
    if expected then
        local definition = transformAnimations.findDefinition(animations, expected)
        if not definition then
            table.insert(problems, string.format("No clip named %s, so this door has nothing to play.", expected))
        elseif not transformAnimations.findMotionTrack(definition) then
            -- A clip added here starts empty, and an effects-only timeline is a legitimate shape --
            -- just not for the clip the door depends on to open.
            table.insert(problems, string.format(
                "%s has no track that moves anything. Add a Move or Rotate track to it.", expected))
        end
    end

    if animationType == "TRANSFORM_TWO_SIDES" and openingType == "HINGED"
        and not transformAnimations.findDefinition(animations, "doorOpenHingedBack") then
        table.insert(problems, "Two-sided door with no doorOpenHingedBack clip: approaching from side one plays nothing.")
    end

    if animationType == "TRANSFORM" and transformAnimations.findDefinition(animations, "doorOpenHingedBack") then
        table.insert(notes, "doorOpenHingedBack is only reached by TRANSFORM_TWO_SIDES; on TRANSFORM it never plays.")
    end

    return problems, notes
end

---How far the visual motion and the gameplay gate have drifted apart.
---
---`MoveDoor()` schedules the busy flag, the occluder re-enable and the player blocker off
---`doorOpeningTime` alone -- never off the animation's real length -- so raising `openingSpeed`
---without lowering `doorOpeningTime` leaves an invisible blocker standing in an open doorway.
---@param definition table? The clip the door will play
---@param openingSpeed number?
---@param openingTime number?
---@return number visualDuration Seconds the mesh is actually in motion
---@return number gateDuration Seconds the gameplay code waits
---@return number drift gateDuration - visualDuration
function transformAnimations.timingDrift(definition, openingSpeed, openingTime)
    local track = transformAnimations.findMotionTrack(definition)
    local duration = utils.toNumber(track and track.duration, 0)
    local timeScale = utils.toNumber(definition and definition.timeScale, 1)

    -- Door.GetOpeningSpeed() coerces a stored zero to 1; a zero timeScale would divide by zero here
    -- for no useful reading, so it gets the same treatment.
    local speed = utils.toNumber(openingSpeed, 1)
    if speed == 0 then speed = 1 end
    if timeScale == 0 then timeScale = 1 end

    local visual = duration / math.abs(timeScale) / math.abs(speed)
    local gate = utils.toNumber(openingTime, 0)

    return visual, gate, gate - visual
end

---The `doorOpeningTime` that would match the clip at the given speed, for the linked speed control.
---@param definition table?
---@param openingSpeed number?
---@return number
function transformAnimations.matchingOpeningTime(definition, openingSpeed)
    local visual = transformAnimations.timingDrift(definition, openingSpeed, 0)
    return visual
end

return transformAnimations
