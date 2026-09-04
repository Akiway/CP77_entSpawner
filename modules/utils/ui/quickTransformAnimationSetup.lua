local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local history = require("modules/utils/project/history")
local registry = require("modules/utils/game/nodeRefRegistry")
local red = require("modules/utils/interop/redConverter")
local data = require("modules/utils/data/transformAnimations")
local animSets = require("modules/utils/data/doorAnimSets")
local audioData = require("modules/utils/data/audioData")
local soundSelector = require("modules/utils/ui/soundSelector")
local logger = require("modules/utils/core/logger")

---Quick setup for `gameTransformAnimatorComponent`, available on any entity that carries one.
---
---The generic instance data editor can already reach this component, but the numbers it shows are
---the numbers the engine stores, and those are not the numbers anyone thinks in: a 90 degree swing
---is `numberOfFullRotations = 0.25`, and the easing everyone wants to pick is split across two
---enums twelve levels down a handle chain. This panel puts the four values that actually describe a
---door -- angle, travel, duration, easing -- on one screen in the units a person would use.
---
---It also owns the one cross-field rule the engine does not enforce: `MoveDoor()` schedules the busy
---flag, the occluder and the player blocker off `doorOpeningTime` alone, never off the animation's
---real length, so speeding a door up without lowering that value leaves an invisible blocker in an
---open doorway. The speed control here writes both together unless the user unlinks them.
---
---Clips and tracks can be added, removed and retyped here. Every handle slot on a track item
---declares an abstract base (`impl`, `movement`, both evaluators), so creating one always needs an
---explicit class choice -- the materialise-by-name path `triggerData` uses in
---quickDeviceOperationsSetup.lua does not apply, and a bare `NewObject` would leave those slots null.
local quickTransformAnimationSetupUI = {
    POPUP_ID = "Transform Animations##wb-Device-wui"
}

---@param device table
---@param options table?
function quickTransformAnimationSetupUI.install(device, options)
    if not device then
        return
    end

    options = options or {}

    ---@param tbl table?
    ---@param path table
    ---@return any
    local function readPath(tbl, path)
        local value = tbl
        for _, key in ipairs(path) do
            if type(value) ~= "table" then return nil end
            value = value[key]
        end
        return value
    end

    ---@param tbl table
    ---@param path table
    ---@param value any
    local function writePath(tbl, path, value)
        local nested = tbl
        for index = 1, #path - 1 do
            if type(nested[path[index]]) ~= "table" then
                nested[path[index]] = {}
            end
            nested = nested[path[index]]
        end
        nested[path[#path]] = value
    end

    -- Construction ---------------------------------------------------------------------------------

    ---Build a fresh RED object as editor JSON.
    ---@param class string
    ---@return table?
    local function makeObject(class)
        local instance = nil
        if not pcall(function () instance = NewObject(class) end) or not instance then
            return nil
        end

        local converted = nil
        if not pcall(function () converted = red.redDataToJSON(instance, { synthesizeNullHandles = true }) end) then
            return nil
        end

        return converted
    end

    ---@param class string
    ---@return table?
    local function makeHandle(class)
        local object = makeObject(class)
        if not object then return nil end
        return { HandleId = "0", Data = object }
    end

    ---An impl handle with its abstract slots filled in.
    ---
    ---`synthesizeNullHandles` cannot reach `movement` or the evaluators -- their declared types are
    ---abstract -- so a bare `NewObject` leaves them null and the track is both unusable and unshowable.
    ---@param implClass string
    ---@return table?
    local function makeImplHandle(implClass)
        local handle = makeHandle(implClass)
        if not handle then return nil end

        for _, slot in ipairs(data.getTrackSlotDefaults(implClass)) do
            local slotHandle = makeHandle(slot.class)
            if not slotHandle then return nil end
            writePath(handle.Data, slot.path, slotHandle)
        end

        return handle
    end

    -- Field rendering ------------------------------------------------------------------------------

    ---Where in the animation tree the field being drawn sits, as `clip/<i>/track/<j>`.
    ---
    ---Anything keyed on the *table* holding the field is worthless here: `getComponentPathArray`
    ---deepcopies the animation list on every frame, so `tostring(owner)` is a different address each
    ---frame. Search text stored under it is orphaned immediately, which is invisible while the input
    ---has focus (ImGui keeps its own buffer) and shows up the moment a click makes ImGui re-sync from
    ---the value we hand back -- the box empties. Position survives the copy; identity does not.
    local fieldScope = ""

    ---Draw one field descriptor against the table that owns it. Mutates `owner` in place.
    ---
    ---The kinds shared with the device operations panel behave identically, including the two
    ---writing rules that matter: DragFloat has no buffer of its own, so a float is written as it
    ---moves and only *settles* on release (a commit-only write hands the pre-drag value back every
    ---frame and the drag snaps back); and InputInt's +/- buttons never raise
    ---IsItemDeactivatedAfterEdit, so an int is written on every change.
    ---@param self table device spawnable
    ---@param field table Descriptor from the data module
    ---@param owner table Table holding the field
    ---@param labelWidth number
    ---@return boolean changed The value was written and must be persisted
    ---@return boolean settled The edit is over, so the device may respawn
    local function drawField(self, field, owner, labelWidth)
        local changed, settled = false, false
        local current = readPath(owner, field.path)
        local width = field.width or 160

        style.mutedText(field.label)
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelWidth)

        if field.kind == "cname" then
            -- Every audio name in the engine is a plain CName, so a free text box makes a Wwise
            -- event indistinguishable from an effect tag and drops a typo silently at runtime.
            -- `getFieldKind` is the same classifier the generic instance data editor uses, keyed on
            -- the property name and the class that owns it: `soundName` on a track resolves to the
            -- sound-event vocabulary, while `effectName` and `effectTag` stay free text, which is
            -- right -- those are VFX names registered on the entity, not audio.
            local kind = audioData.getFieldKind(field.path[#field.path], tostring(owner["$type"] or ""))
            local selector = kind and audioData.getFieldSelector(kind) or nil

            if selector then
                local currentName = data.readCName(current)
                local searchKey = fieldScope .. "/" .. table.concat(field.path, "/")

                local newValue, finished

                if kind == "event" then
                    -- A field the engine only ever starts carries the one-shot rule as a mandatory
                    -- criterion, so the selector says why the list is short instead of just being
                    -- short. Everything else leaves every criterion optional.
                    --
                    -- The test button emits from the device, not the player: the note beside it says
                    -- the event carries 8m, and that only means anything heard from where the device
                    -- actually stands. The note itself -- loop, length, range -- is what a timeline
                    -- track needs: a one-shot shorter than the track leaves silence, and a looping
                    -- event never stops on its own.
                    newValue, finished = soundSelector.draw("##audioField", currentName, {
                        stateKey = string.format("transformAnimation/%s/%s", tostring(self.object and self.object.id), searchKey),
                        element = self.object,
                        width = 250,
                        listHeight = 200,
                        hint = selector.hint,
                        tooltip = selector.tooltip,
                        preset = field.oneShot and soundSelector.presets.oneShot or nil,
                        showTest = true,
                        testTarget = self:getEntity()
                    })
                else
                    local searchValue

                    self.transformAnimationAudioSearch = self.transformAnimationAudioSearch or {}

                    newValue, searchValue, finished = style.trackedSearchDropdown(
                        "##audioField", selector.hint, currentName,
                        self.transformAnimationAudioSearch[searchKey] or "", selector.options,
                        {
                            element = self.object,
                            width = 250,
                            listHeight = 200,
                            allowCustom = true,
                            matchContentWidth = selector.matchWidth == true,
                            optionDisplayFn = selector.displayFn,
                            optionTooltipFn = selector.tooltipFn,
                            tooltip = selector.tooltip
                        }
                    )
                    self.transformAnimationAudioSearch[searchKey] = searchValue
                end

                if finished and newValue ~= currentName then
                    writePath(owner, field.path, data.cname(newValue))
                    changed, settled = true, true
                end
            else
                local newValue, _, finished = style.trackedTextField(
                    self.object, "##field", data.readCName(current), "Name...", width
                )
                if finished then
                    writePath(owner, field.path, data.cname(newValue))
                    changed, settled = true, true
                end
            end

        elseif field.kind == "noderef" then
            local newValue, finished = registry.drawNodeRefSelector(width, data.readRawValue(current), self.object, false)
            if finished then
                writePath(owner, field.path, data.nodeRef(newValue))
                changed, settled = true, true
            end

        elseif field.kind == "bool" then
            local newValue, didChange = style.trackedCheckbox(self.object, "##field", data.readBool(current))
            if didChange then
                writePath(owner, field.path, newValue and 1 or 0)
                changed, settled = true, true
            end

        elseif field.kind == "int" then
            local newValue, didChange, finished = style.trackedIntInput(
                self.object, "##field", math.floor(tonumber(current) or 0), 0, 2147483647, width, 1, 10
            )
            if didChange then
                writePath(owner, field.path, newValue)
                changed, settled = true, finished
            end

        elseif field.kind == "float" then
            local newValue, didChange, finished = style.trackedDragFloat(
                self.object, "##field", tonumber(current) or 0, 0.01, -100000, 100000, field.format or "%.2f", width
            )
            if didChange then
                writePath(owner, field.path, newValue)
                changed, settled = true, finished
            end

        elseif field.kind == "degrees" then
            -- Stored as fractions of a turn; shown and edited in degrees, because 0.4722 is not a
            -- number anyone reasons about and 170 is.
            local newValue, didChange, finished = style.trackedDragFloat(
                self.object, "##field", data.rotationsToDegrees(current), 0.5, -3600, 3600, "%.1f deg", width
            )
            if didChange then
                writePath(owner, field.path, data.degreesToRotations(newValue))
                changed, settled = true, finished
            end

        elseif field.kind == "vector3" then
            local x, y, z = data.readVector3(current)
            local componentWidth = math.max(52, (width - 2 * ImGui.GetStyle().ItemSpacing.x) / 3)
            local values = { x, y, z }
            local anyChanged, anyFinished = false, false

            for index, axis in ipairs({ "X", "Y", "Z" }) do
                if index > 1 then ImGui.SameLine() end
                ImGui.PushID(index)
                local newValue, didChange, finished = style.trackedDragFloat(
                    self.object, "##" .. axis, values[index], 0.01, -10000, 10000, axis .. " %.3f", componentWidth
                )
                ImGui.PopID()
                if didChange then
                    values[index] = newValue
                    anyChanged = true
                    anyFinished = anyFinished or finished
                end
            end

            if anyChanged then
                writePath(owner, field.path, data.vector3(values[1], values[2], values[3]))
                changed, settled = true, anyFinished
            end

        elseif field.kind == "quaternion" then
            -- Kept as raw i/j/k/r rather than converted to Euler: no shipped door uses a rotation
            -- evaluator, so there is no reference data to check a conversion against, and silently
            -- round-tripping a quaternion through Euler angles loses more than it gains.
            local quat = type(current) == "table" and current or {}
            local componentWidth = math.max(46, (width - 3 * ImGui.GetStyle().ItemSpacing.x) / 4)
            local keys = { "i", "j", "k", "r" }
            local values = {}
            for index, key in ipairs(keys) do
                values[index] = utils.toNumber(quat[key], key == "r" and 1 or 0)
            end
            local anyChanged, anyFinished = false, false

            for index, key in ipairs(keys) do
                if index > 1 then ImGui.SameLine() end
                ImGui.PushID(index)
                local newValue, didChange, finished = style.trackedDragFloat(
                    self.object, "##" .. key, values[index], 0.01, -1, 1, key .. " %.3f", componentWidth
                )
                ImGui.PopID()
                if didChange then
                    values[index] = newValue
                    anyChanged = true
                    anyFinished = anyFinished or finished
                end
            end

            if anyChanged then
                writePath(owner, field.path, {
                    ["$type"] = "Quaternion",
                    i = values[1], j = values[2], k = values[3], r = values[4]
                })
                changed, settled = true, anyFinished
            end

        elseif field.kind == "enum" then
            local values = data.ENUMS[field.enum] or {}
            local index = math.max(0, utils.indexValue(values, tostring(current or "")) - 1)
            local newIndex, didChange = style.trackedCombo(self.object, "##field", index, values, width)
            if didChange then
                writePath(owner, field.path, values[newIndex + 1])
                changed, settled = true, true
            end
        end

        if field.hint then
            style.tooltip(field.hint)
        end

        return changed, settled
    end

    ---Draw a list of field descriptors.
    ---
    ---`scope` is required, and is not decoration: every widget in here is labelled `##field`, so its
    ---ImGui ID is decided entirely by the ID stack. Two field lists drawn at the same nesting level
    ---both start their per-field `PushID` at 1, which made the first track field and the first impl
    ---field literally the same widget -- clicking the axis combo drove start time, and duration and
    ---angle shared a value. The scope separates them.
    ---@param self table device spawnable
    ---@param fields table[]
    ---@param owner table
    ---@param scope string Unique among the field lists drawn at this nesting level
    ---@param labelWidth number? Shared column, so lists drawn one under the other line up
    ---@return boolean changed
    ---@return boolean settled
    local function drawFields(self, fields, owner, scope, labelWidth)
        if not fields or #fields == 0 then return false, false end

        if not labelWidth then
            local labels = {}
            for _, field in ipairs(fields) do table.insert(labels, field.label) end
            -- `SetCursorPosX` is window absolute while the labels start at the current indent, so the
            -- column has to include that indent or a long label runs under its own input.
            labelWidth = ImGui.GetCursorPosX() + utils.getTextMaxWidth(labels) + 3 * ImGui.GetStyle().ItemSpacing.x
        end

        local changed, settled = false, false

        ImGui.PushID(tostring(scope))
        for index, field in ipairs(fields) do
            ImGui.PushID(index)
            local fieldChanged, fieldSettled = drawField(self, field, owner, labelWidth)
            if fieldChanged then
                changed = true
                settled = settled or fieldSettled
            end
            ImGui.PopID()
        end
        ImGui.PopID()

        return changed, settled
    end

    ---The 3 x 11 EasingFunction grid as one labelled combo, drawn against a `_Movement` payload.
    ---@param self table device spawnable
    ---@param movementData table The movement handle's `Data`
    ---@param easingPath table Path to the `EasingFunction` struct
    ---How far the evaluator block under a track is indented. Shared with `animationLabelWidth`, which
    ---has to account for it when sizing the label column.
    local EVALUATOR_INDENT = 12

    ---One label column for the whole clip list, cached per impl-agnostic layout.
    ---
    ---Sizing per field list, or even per track, makes the rows step across the panel: a Play sound
    ---track's short labels put its inputs left of a Rotate track's, and the clip's own fields left of
    ---both. They are read as one column down the panel, so they are measured as one -- every label
    ---that can appear anywhere in the list, including evaluator labels with their indent added.
    ---@return number
    local function animationLabelWidth()
        local labels = { "Easing" }

        for _, field in ipairs(data.DEFINITION_FIELDS) do table.insert(labels, field.label) end
        for _, field in ipairs(data.TRACK_ITEM_FIELDS) do table.insert(labels, field.label) end

        local evaluatorLabels = {}

        for _, implType in ipairs(data.IMPL_TYPES) do
            for _, field in ipairs(implType.fields or {}) do table.insert(labels, field.label) end

            for _, evaluator in ipairs(implType.evaluators or {}) do
                for _, evaluatorType in ipairs(data.getEvaluatorTypes(evaluator.base) or {}) do
                    for _, field in ipairs(evaluatorType.fields or {}) do
                        table.insert(evaluatorLabels, field.label)
                    end
                end
            end
        end

        local width = utils.getTextMaxWidth(labels)

        -- Evaluator rows sit one indent deeper, so their labels reach further right than their text
        -- is wide. Measured with that indent added, otherwise the deepest label decides nothing.
        if #evaluatorLabels > 0 then
            width = math.max(width, utils.getTextMaxWidth(evaluatorLabels) + EVALUATOR_INDENT * style.viewSize)
        end

        return width + 3 * ImGui.GetStyle().ItemSpacing.x
    end

    ---@param labelWidth number
    ---@return boolean changed
    ---@return boolean settled
    local function drawEasing(self, movementData, easingPath, labelWidth)
        local easing = readPath(movementData, easingPath)
        if type(easing) ~= "table" then return false, false end

        style.mutedText("Easing")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelWidth)

        local index = data.easingComboIndex(easing.easingType, easing.transitionType)
        local newIndex, didChange = style.trackedCombo(
            self.object, "##easing", index, data.EASING_LABELS, 180, { popupMaxHeight = 300 }
        )
        style.tooltip("Curve shape, then which end of the motion it is applied to. Linear / InOut is the flat mechanical default.")

        if didChange then
            local easingType, transitionType = data.easingComboValues(newIndex)
            writePath(movementData, easingPath, {
                ["$type"] = "EasingFunction",
                easingType = easingType,
                transitionType = transitionType
            })
            return true, true
        end

        return false, false
    end

    -- Component access -----------------------------------------------------------------------------

    ---Cached across frames: the popup body runs every frame, and the uncached path force-loads and
    ---then walks every component. The cache drops itself whenever the id stops resolving, which is
    ---what a respawn that cleared `defaultComponentData` looks like from here.
    ---@return string?
    function device:getTransformAnimatorComponentID()
        local cached = self.transformAnimatorComponentID
        if cached and (self.defaultComponentData or {})[cached] then
            return cached
        end

        local componentID = data.ensureAnimatorLoaded(self)
        self.transformAnimatorComponentID = componentID

        return componentID
    end

    ---@param componentID string
    ---@return table[]
    function device:getTransformAnimationList(componentID)
        return self:getComponentPathArray(self, componentID, data.ANIMATIONS_PATH)
    end

    ---The animator on the spawned entity, found by class rather than by name: a device can carry
    ---either the placed animator or the root one, and only the class tells them apart.
    ---@param entityRef userdata
    ---@return userdata? component
    local function liveAnimator(entityRef)
        local found = nil

        pcall(function ()
            for _, component in ipairs(entityRef:GetComponents() or {}) do
                if component:IsA(data.ANIMATOR_CLASS) or component:IsA(data.ROOT_ANIMATOR_CLASS) then
                    found = component
                    return
                end
            end
        end)

        return found
    end

    ---Clip names the live animator actually holds. The panel edits a JSON copy of `animations`; the
    ---component the play event reaches is the native one, and the two only agree after a respawn.
    ---@param animator userdata?
    ---@return table<string, boolean>
    local function liveClipNames(animator)
        local names = {}
        if not animator then return names end

        pcall(function ()
            for _, definition in ipairs(animator.animations or {}) do
                local name = tostring(definition.name.value or "")
                if name ~= "" then names[name] = true end
            end
        end)

        return names
    end

    ---Queue a play event at the live entity. Costs nothing and touches no data, so it stays usable
    ---even while the clip itself is unedited -- it is the fastest way to see what a door does.
    ---
    ---Nothing here is silent. A play event that reaches a disabled animator, or names a clip the
    ---live component does not have, does exactly nothing and looks identical to a broken button --
    ---so both are checked and logged, and a disabled animator is switched back on rather than
    ---reported. A device animator is routinely off: the controller toggles it with the device state,
    ---and a fan that has never been turned on has never enabled it.
    ---@param clipName string
    ---@param timeScale number
    function device:previewTransformAnimation(clipName, timeScale)
        local entityRef = self:getEntity()
        if clipName == "" then return end

        if not entityRef then
            logger:info("[transformAnimations] Preview skipped: the entity is not spawned.")
            return
        end

        local animator = liveAnimator(entityRef)
        if not animator then
            logger:info(string.format(
                "[transformAnimations] Preview skipped: \"%s\" has no live transform animator.",
                self.spawnData or "entity"))
            return
        end

        local enabled = true
        pcall(function () enabled = animator:IsEnabled() end)
        if not enabled then
            pcall(function () animator:Toggle(true) end)
        end

        local names = liveClipNames(animator)
        if next(names) ~= nil and not names[clipName] then
            local known = {}
            for name, _ in pairs(names) do table.insert(known, name) end
            table.sort(known)
            logger:info(string.format(
                "[transformAnimations] The live animator has no clip \"%s\". It holds: %s. Respawn to apply edits.",
                clipName, table.concat(known, ", ")))
        end

        local ok, err = pcall(function ()
            local event = gameTransformAnimationPlayEvent.new()
            event.animationName = CName.new(clipName)
            event.looping = false
            event.timesPlayed = 1
            event.timeScale = timeScale ~= 0 and timeScale or 1
            entityRef:QueueEvent(event)
        end)

        if not ok then
            logger:error(string.format("[transformAnimations] Preview failed for \"%s\": %s",
                clipName, tostring(err)))
        end
    end

    ---@param clipName string
    function device:resetTransformAnimation(clipName)
        local entityRef = self:getEntity()
        if not entityRef or clipName == "" then return end

        local ok, err = pcall(function ()
            local event = gameTransformAnimationResetEvent.new()
            event.animationName = CName.new(clipName)
            entityRef:QueueEvent(event)
        end)

        if not ok then
            logger:error(string.format("[transformAnimations] Reset failed for \"%s\": %s",
                clipName, tostring(err)))
        end
    end

    -- Door rows ------------------------------------------------------------------------------------

    ---The door's two enums live on the entity chunk, which `instanceDataChanges` keys as "0".
    ---@param path table
    ---@return any
    local function readEntityValue(self, path)
        return self:getComponentPathValue(self, "0", path)
    end

    ---@param path table
    ---@param value any
    local function writeEntityValue(self, path, value)
        self:updateComponentPathValue(self, "0", path, value)
    end

    ---What the animator actually moves. A transform animator drives its own transform only, so a
    ---clip is invisible unless something is parented to it -- and CDPR ships a fully populated
    ---`DoorTransformAnimator` on doors where nothing is, which makes the clip list misleading on its
    ---own.
    ---@param bound string[] Component names from `getAnimatorBoundComponents`
    ---@param labelWidth number
    function device:drawTransformAnimationBindingRow(bound, labelWidth)
        style.mutedText("Moves")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelWidth)

        if #bound == 0 then
            style.styledText(IconGlyphs.AlertOutline .. " nothing", style.warnColor)
            style.tooltip(
                "No component on this entity has parentTransform bound to the animator, so every clip below moves an\n"
                .. "invisible transform. The binding lives in the .ent and instance data cannot add one -- pick a door\n"
                .. "whose mesh follows the animator instead."
            )
        else
            style.styledText(table.concat(bound, ", "), style.successColor)
            style.tooltip("Components whose parentTransform binds to the animator. These follow every clip below.")
        end
    end

    ---@param componentID string
    ---@param animations table[]
    function device:drawTransformAnimationDoorSection(componentID, animations)
        style.sectionHeaderStart("Door", "How the door picks which clip to play, and how fast.")

        local animationType = tostring(readEntityValue(self, data.ANIMATION_TYPE_PATH) or "")
        local openingType = tostring(readEntityValue(self, data.OPENING_TYPE_PATH) or "")
        local bound = data.getAnimatorBoundComponents(self, componentID)

        local labels = { "Animation type", "Opening type", "Opening speed", "Gameplay gate" }
        local labelWidth = ImGui.GetCursorPosX() + utils.getTextMaxWidth(labels) + 3 * ImGui.GetStyle().ItemSpacing.x

        -- Drawn before the type combo, not after it: on a door with nothing parented to the animator
        -- switching to TRANSFORM stops the door animating, and the user has to see that first.
        self:drawTransformAnimationBindingRow(bound, labelWidth)
        ImGui.Dummy(0, 4 * style.viewSize)

        style.mutedText("Animation type")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelWidth)
        local typeValues = data.ENUMS.EAnimationType
        local typeIndex = math.max(0, utils.indexValue(typeValues, animationType) - 1)
        local newTypeIndex, typeChanged = style.trackedCombo(self.object, "##animationType", typeIndex, typeValues, 180)
        if typeChanged then
            writeEntityValue(self, data.ANIMATION_TYPE_PATH, typeValues[newTypeIndex + 1])
        end
        style.tooltip("REGULAR plays a baked animgraph clip and ignores everything below. TRANSFORM plays the clips on this component.")

        style.mutedText("Opening type")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelWidth)
        local openingValues = data.ENUMS.EDoorOpeningType
        local openingIndex = math.max(0, utils.indexValue(openingValues, openingType) - 1)
        local newOpeningIndex, openingChanged = style.trackedCombo(self.object, "##openingType", openingIndex, openingValues, 180)
        if openingChanged then
            writeEntityValue(self, data.OPENING_TYPE_PATH, openingValues[newOpeningIndex + 1])
        end
        style.tooltip("Selects which of the four reserved clip names the door plays.")

        local activeClip = data.clipForDoor(openingType, animationType, false)
        if activeClip then
            style.mutedText("Plays")
            ImGui.SameLine()
            ImGui.SetCursorPosX(labelWidth)
            style.styledText(activeClip, style.successColor)
        end

        local problems, notes = data.checkDoorSetup(animations, animationType, openingType, bound)
        for _, problem in ipairs(problems) do
            ImGui.Dummy(0, 2 * style.viewSize)
            style.styledText(IconGlyphs.AlertOutline, style.warnColor)
            ImGui.SameLine()
            style.styledTextWrapped(problem, style.warnColor)
        end
        for _, note in ipairs(notes) do
            ImGui.Dummy(0, 2 * style.viewSize)
            style.styledTextWrapped(note, style.extraMutedColor)
        end

        ImGui.Dummy(0, 6 * style.viewSize)
        self:drawTransformAnimationSpeedRows(animations, animationType, openingType, labelWidth)

        style.sectionHeaderEnd()
    end

    ---The linked speed control. `openingSpeed` scales the animation; `doorOpeningTime` is what the
    ---script actually waits on. Writing them apart is the invisible-blocker bug, so they move
    ---together unless the user says otherwise.
    ---@param animations table[]
    ---@param animationType string
    ---@param openingType string
    ---@param labelWidth number
    function device:drawTransformAnimationSpeedRows(animations, animationType, openingType, labelWidth)
        local controllerID = self:getPersistentComponentID(self, self.deviceClassName)
        if not controllerID then return end

        local openingSpeed = utils.toNumber(self:getComponentPathValue(self, controllerID, data.OPENING_SPEED_PATH), 1)
        local openingTime = utils.toNumber(self:getComponentPathValue(self, controllerID, data.OPENING_TIME_PATH), 0)

        local activeClip = data.clipForDoor(openingType, animationType, false)
        local definition = activeClip and data.findDefinition(animations, activeClip) or nil

        if self.transformAnimationLinkTiming == nil then
            self.transformAnimationLinkTiming = true
        end

        style.mutedText("Opening speed")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelWidth)
        local newSpeed, speedChanged, speedFinished = style.trackedDragFloat(
            self.object, "##openingSpeed", openingSpeed, 0.01, 0.01, 100, "%.2fx", 120
        )
        if speedChanged then
            -- The linked write is always suppressed and the speed write carries the respawn, so a
            -- settled drag respawns the device once rather than twice. Both land in
            -- `instanceDataChanges` either way, and the single dirty mark covers the pair.
            if self.transformAnimationLinkTiming and definition then
                local matched = data.matchingOpeningTime(definition, newSpeed)
                self:updateComponentPathValue(self, controllerID, data.OPENING_TIME_PATH, matched,
                    { suppressRespawn = true })
                openingTime = matched
            end

            self:updateComponentPathValue(self, controllerID, data.OPENING_SPEED_PATH, newSpeed,
                { suppressRespawn = not speedFinished })
        end
        style.tooltip("Divides the clip's duration. Also applies on the REGULAR animgraph path.")

        ImGui.SameLine()
        local linked, linkChanged = style.trackedCheckbox(self.object, "Link##linkTiming", self.transformAnimationLinkTiming)
        if linkChanged then self.transformAnimationLinkTiming = linked end
        style.tooltip("Keeps the gameplay gate matched to the animation. Unlink only if you want them to differ on purpose.")

        style.mutedText("Gameplay gate")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelWidth)
        local newTime, timeChanged, timeFinished = style.trackedDragFloat(
            self.object, "##openingTime", openingTime, 0.01, 0, 3600, "%.2fs", 120
        )
        if timeChanged then
            self:updateComponentPathValue(self, controllerID, data.OPENING_TIME_PATH, newTime,
                { suppressRespawn = not timeFinished })
        end
        style.tooltip("doorOpeningTime. Holds the busy flag, the occluder and the player blocker. Nothing derives it from the animation.")

        -- No motion track means no length to compare the gate against; reporting "motion finishes in
        -- 0.00s" for an effects-only clip would be a warning about nothing.
        if not definition or not data.findMotionTrack(definition) then return end

        local visual, gate, drift = data.timingDrift(definition, openingSpeed, openingTime)
        ImGui.Dummy(0, 2 * style.viewSize)

        if math.abs(drift) < 0.05 then
            style.styledText(string.format("Motion %.2fs, gate %.2fs -- matched.", visual, gate), style.extraMutedColor)
        else
            style.styledText(IconGlyphs.AlertOutline, style.warnColor)
            ImGui.SameLine()
            if drift > 0 then
                style.styledTextWrapped(string.format(
                    "Motion finishes in %.2fs but the gate runs %.2fs: the door looks open for %.2fs while the blocker and occluder are still up.",
                    visual, gate, drift), style.warnColor)
            else
                style.styledTextWrapped(string.format(
                    "Gate clears after %.2fs but the motion runs %.2fs: the door is walkable %.2fs before it finishes moving.",
                    gate, visual, -drift), style.warnColor)
            end

            ImGui.Dummy(0, 2 * style.viewSize)
            if ImGui.Button(string.format("Set gate to %.2fs##matchGate", visual)) then
                history.addAction(history.getElementChange(self.object))
                self:updateComponentPathValue(self, controllerID, data.OPENING_TIME_PATH, visual)
            end
        end
    end

    -- Clip list ------------------------------------------------------------------------------------

    ---@param componentID string
    ---@param animations table[]
    function device:drawTransformAnimationList(componentID, animations)
        style.sectionHeaderStart(string.format("Clips (%d)", #animations), "Named timelines on this component.")

        ---History is not pushed here: every tracked widget records one at the start of its own edit.
        ---@param settled boolean? false while an edit is still in flight, which holds off the respawn
        local function commit(settled)
            self:updateComponentPathValue(self, componentID, data.ANIMATIONS_PATH, animations,
                { suppressRespawn = settled == false })
        end

        for index, definition in ipairs(animations) do
            ImGui.PushID(index)
            fieldScope = "clip/" .. index

            local name = data.definitionName(definition)
            local motionTrack = data.findMotionTrack(definition)
            local implLabel = motionTrack and data.getClassLabel(data.handleClass(motionTrack.impl)) or "no motion track"
            local header = string.format("%s  -  %s###clip", name ~= "" and name or "<unnamed>", implLabel)

            local open = ImGui.TreeNodeEx(header)

            ImGui.SameLine()
            style.pushButtonNoBG(true)
            if ImGui.Button(IconGlyphs.Play .. "##previewClip") then
                self:previewTransformAnimation(name, 1)
            end
            style.pushButtonNoBG(false)
            style.tooltip("Play this clip on the spawned entity. Preview only -- changes nothing.")

            ImGui.SameLine()
            style.pushButtonNoBG(true)
            if ImGui.Button(IconGlyphs.Restore .. "##resetClip") then
                self:resetTransformAnimation(name)
            end
            style.pushButtonNoBG(false)
            style.tooltip("Put the mesh back where the clip started.")

            ImGui.SameLine()
            local deleted = style.dangerButton(IconGlyphs.DeleteOutline .. "##deleteClip")
            if deleted then
                history.addAction(history.getElementChange(self.object))
                table.remove(animations, index)
                commit(true)
            end
            style.tooltip("Remove this clip. A door plays only the four reserved names, so removing one it needs stops it moving.")

            if deleted then
                -- `break`, not `return`: `sectionHeaderStart` above opened an ImGui group that only
                -- `sectionHeaderEnd` at the bottom of this function closes.
                if open then ImGui.TreePop() end
                ImGui.PopID()
                break
            end

            if open then
                -- One column for the clip and every track under it. Anchored to where the rows start,
                -- because `SetCursorPosX` is window absolute while the labels honour the indent.
                local labelWidth = ImGui.GetCursorPosX() + animationLabelWidth()

                local changed, settled = drawFields(self, data.DEFINITION_FIELDS, definition, "clip", labelWidth)
                if changed then commit(settled) end

                self:drawTransformAnimationTracks(definition, commit, labelWidth)

                ImGui.TreePop()
            end

            ImGui.PopID()
        end

        if #animations == 0 then
            style.styledTextWrapped(
                "This animator carries no clips yet. Add one below, or add the reserved door names the entity is missing.",
                style.extraMutedColor
            )
            ImGui.Dummy(0, 4 * style.viewSize)
        end

        self:drawTransformAnimationAddClip(animations, commit)

        style.sectionHeaderEnd()
    end

    ---Add-clip row. Door clips come first and by name, because those four are the only names a door
    ---will ever ask the animator for; anything else needs a Device Operation to play it.
    ---@param animations table[]
    ---@param commit fun(settled: boolean?)
    function device:drawTransformAnimationAddClip(animations, commit)
        ImGui.Dummy(0, 4 * style.viewSize)

        local missing = data.missingDoorClips(animations)

        if #missing > 0 and data.isDoorEntity(self) then
            -- One menu rather than a button per name: the reserved names are long enough that four
            -- buttons run off the side of the popup.
            ImGui.Button(IconGlyphs.Plus .. " Add a reserved door clip##addDoorClip")
            if ImGui.BeginPopupContextItem("##addDoorClipMenu", ImGuiPopupFlags.MouseButtonLeft) then
                for _, clip in ipairs(missing) do
                    if ImGui.MenuItem(string.format("%s  (%s)", clip.name, clip.label)) then
                        history.addAction(history.getElementChange(self.object))
                        table.insert(animations, data.newDefinition(clip.name))
                        commit(true)
                    end
                    style.tooltip(clip.hint)
                end
                ImGui.EndPopup()
            end
            style.tooltip("The four names a door asks the animator for. A new clip starts empty -- add a track to it.")
            ImGui.Dummy(0, 4 * style.viewSize)
        end

        self.transformAnimationNewClipName = self.transformAnimationNewClipName or ""

        style.mutedText("New clip")
        ImGui.SameLine()
        self.transformAnimationNewClipName = style.trackedTextField(
            self.object, "##newClipName", self.transformAnimationNewClipName, "Name...", 180
        )
        style.tooltip("A clip named anything other than the four reserved door names is only reachable from a Transform animation device operation.")

        local name = utils.trimString(self.transformAnimationNewClipName)
        local duplicate = name ~= "" and data.findDefinition(animations, name) ~= nil

        ImGui.SameLine()
        if duplicate then
            style.styledText(IconGlyphs.AlertOutline, style.warnColor)
            style.tooltip("A clip with this name already exists. Names are how the engine asks for a clip, so duplicates are ambiguous.")
        elseif name ~= "" then
            if ImGui.Button(IconGlyphs.Plus .. " Add##addNamedClip") then
                history.addAction(history.getElementChange(self.object))
                table.insert(animations, data.newDefinition(name))
                self.transformAnimationNewClipName = ""
                commit(true)
            end
        end
    end

    ---@param definition table
    ---@param commit fun(settled: boolean?)
    ---@param labelWidth number? Column shared with the clip's own fields
    function device:drawTransformAnimationTracks(definition, commit, labelWidth)
        -- `timelineItems` returns a throwaway table when the timeline is missing, which is the right
        -- answer for reading and the wrong one for appending: the insert would land on a copy and
        -- the commit would write a clip with no tracks. Materialise it here instead.
        if type(definition.timeline) ~= "table" then
            definition.timeline = { ["$type"] = data.TIMELINE_CLASS, items = {} }
        end
        if type(definition.timeline.items) ~= "table" then
            definition.timeline.items = {}
        end

        local items = definition.timeline.items
        local clipScope = fieldScope

        for index, item in ipairs(items) do
            fieldScope = string.format("%s/track/%d", clipScope, index)

            local implData = data.handleData(item.impl)
            if implData then
                local implClass = tostring(implData["$type"] or "")
                local implType = data.getImplType(implClass)

                ImGui.PushID(1000 + index)

                -- `###track` so the visible summary can change with the values without ImGui
                -- treating it as a different node and snapping the fold shut mid-edit.
                local summary = data.describeTrack(item)
                local header = string.format("Track %d  -  %s%s###track",
                    index, data.getClassLabel(implClass), summary ~= "" and ("  (" .. summary .. ")") or "")

                local open = ImGui.TreeNodeEx(header)
                if implType and implType.hint then
                    style.tooltip(implType.hint)
                end

                ImGui.SameLine()
                local deleted = style.dangerButton(IconGlyphs.DeleteOutline .. "##deleteTrack")
                if deleted then
                    history.addAction(history.getElementChange(self.object))
                    -- `table.remove`, never a nil write at the index: assigning nil punches a hole,
                    -- `#items` stops being meaningful and the array no longer encodes as a JSON array
                    -- on export.
                    table.remove(items, index)
                    commit(true)
                end
                style.tooltip("Remove this track from the clip.")

                if deleted then
                    -- `break` so the Add track row below still draws this frame.
                    if open then ImGui.TreePop() end
                    ImGui.PopID()
                    break
                end

                if open then
                    local changed, settled = drawFields(self, data.TRACK_ITEM_FIELDS, item, "track", labelWidth)

                    if implType then
                        local fieldsChanged, fieldsSettled = drawFields(self, implType.fields, implData, "impl", labelWidth)
                        if fieldsChanged then
                            changed = true
                            settled = settled or fieldsSettled
                        end

                        local evalChanged, evalSettled = self:drawTransformAnimationEvaluators(implType, implData, labelWidth)
                        if evalChanged then
                            changed = true
                            settled = settled or evalSettled
                        end

                        local moveChanged, moveSettled = self:drawTransformAnimationMovement(implType, implData, labelWidth)
                        if moveChanged then
                            changed = true
                            settled = settled or moveSettled
                        end
                    else
                        style.styledTextWrapped(
                            string.format("Unrecognised track type %s. Edit it under Entity Instance Data.", implClass),
                            style.extraMutedColor
                        )
                    end

                    if changed then commit(settled) end

                    ImGui.TreePop()
                end

                ImGui.PopID()
            end
        end

        ImGui.Dummy(0, 4 * style.viewSize)

        ImGui.Button(IconGlyphs.Plus .. " Add track##addTrack")
        if ImGui.BeginPopupContextItem("##addTrackMenu", ImGuiPopupFlags.MouseButtonLeft) then
            for _, implType in ipairs(data.IMPL_TYPES) do
                if ImGui.MenuItem(implType.label) then
                    local handle = makeImplHandle(implType.class)
                    if handle then
                        history.addAction(history.getElementChange(self.object))
                        table.insert(items, data.newTrackItem(handle))
                        commit(true)
                    end
                end
                if implType.hint then
                    style.tooltip(implType.hint)
                end
            end
            ImGui.EndPopup()
        end
        style.tooltip("Tracks run in parallel. A shipped hinged door pairs a 1 s rotation with a 3 s dust effect.")
    end

    ---Swap the concrete class in one abstract handle slot, keeping the label as the click target.
    ---
    ---The class *is* the behaviour here: "where it started" and "local position" are different
    ---evaluators, not different values of one. Switching replaces the payload rather than merging,
    ---because the two share no fields.
    ---@param owner table Table holding the handle
    ---@param path table Path to the handle
    ---@param currentClass string
    ---@param choices table[] Catalogue entries with `class` and `label`
    ---@param popupId string
    ---@return boolean changed
    local function drawClassSwitch(self, owner, path, currentClass, choices, popupId)
        if ImGui.BeginPopupContextItem(popupId, ImGuiPopupFlags.MouseButtonLeft) then
            for _, choice in ipairs(choices) do
                -- An unsupported class stays listed so an existing one is still named, but offering
                -- it as a destination would hand the user a payload this panel cannot edit.
                if not choice.unsupported and choice.class ~= currentClass then
                    if ImGui.MenuItem(choice.label) then
                        local handle = makeHandle(choice.class)
                        if handle then
                            history.addAction(history.getElementChange(self.object))
                            writePath(owner, path, handle)
                            ImGui.EndPopup()
                            return true
                        end
                    end
                    if choice.hint then
                        style.tooltip(choice.hint)
                    end
                end
            end
            ImGui.EndPopup()
        end

        return false
    end

    ---A `_Move`'s two position evaluators, or a `_RotateFromTo`'s two rotation evaluators.
    ---@param implType table
    ---@param implData table
    ---@param labelWidth number?
    ---@return boolean changed
    ---@return boolean settled
    function device:drawTransformAnimationEvaluators(implType, implData, labelWidth)
        if not implType.evaluators then return false, false end

        local changed, settled = false, false

        for index, evaluator in ipairs(implType.evaluators) do
            local evaluatorData = data.handleData(readPath(implData, evaluator.path))
            if evaluatorData then
                local evaluatorClass = tostring(evaluatorData["$type"] or "")
                local evaluatorType = data.getEvaluatorType(evaluator.base, evaluatorClass)

                ImGui.PushID(2000 + index)

                style.mutedText(string.format("%s  (%s)", evaluator.label, data.getClassLabel(evaluatorClass)))
                if evaluatorType and evaluatorType.hint then
                    style.tooltip(evaluatorType.hint)
                end

                ImGui.SameLine()
                ImGui.SmallButton(IconGlyphs.SwapHorizontal .. "##switchEvaluator")
                local switched = drawClassSwitch(self, implData, evaluator.path, evaluatorClass,
                    data.getEvaluatorTypes(evaluator.base), "##switchEvaluatorMenu")
                style.tooltip("Change what this evaluator reads from.")

                if switched then
                    -- Breaks before the Indent below, so there is nothing to unindent.
                    ImGui.PopID()
                    changed, settled = true, true
                    break
                end

                ImGui.Indent(EVALUATOR_INDENT * style.viewSize)
                if evaluatorType then
                    local fieldsChanged, fieldsSettled = drawFields(self, evaluatorType.fields, evaluatorData, "eval", labelWidth)
                    if fieldsChanged then
                        changed = true
                        settled = settled or fieldsSettled
                    end
                else
                    style.styledTextWrapped(
                        string.format("Unrecognised evaluator %s.", evaluatorClass), style.extraMutedColor
                    )
                end
                ImGui.Unindent(EVALUATOR_INDENT * style.viewSize)

                ImGui.PopID()
            end
        end

        return changed, settled
    end

    ---@param implType table
    ---@param implData table
    ---@param labelWidth number?
    ---@return boolean changed
    ---@return boolean settled
    function device:drawTransformAnimationMovement(implType, implData, labelWidth)
        if not implType.movementPath then return false, false end

        local movementData = data.handleData(readPath(implData, implType.movementPath))
        if not movementData then return false, false end

        local movementClass = tostring(movementData["$type"] or "")
        local movementType = data.getMovementType(movementClass)

        if movementType and movementType.unsupported then
            style.styledTextWrapped(
                string.format("%s: %s", movementType.label, movementType.hint or ""), style.extraMutedColor
            )
            -- Offered even here: a custom curve this panel cannot edit is exactly the case where the
            -- user most needs a way back to a preset.
            ImGui.SmallButton(IconGlyphs.SwapHorizontal .. " Use a preset curve##switchMovement")
            if drawClassSwitch(self, implData, implType.movementPath, movementClass,
                data.MOVEMENT_TYPES, "##switchMovementMenu") then
                return true, true
            end
            return false, false
        end

        if not (movementType and movementType.easingPath) then
            return false, false
        end

        return drawEasing(self, movementData, movementType.easingPath,
            labelWidth or (ImGui.GetCursorPosX() + utils.getTextMaxWidth({ "Easing" })
                + 3 * ImGui.GetStyle().ItemSpacing.x))
    end

    -- Baked animation --------------------------------------------------------------------------------

    ---The other half of door motion, and the only one a REGULAR door uses.
    ---
    ---`entAnimatedComponent.animations.gameplay[].animSet` is an ordinary resource ref, so instance
    ---data can repoint it -- and since a baked clip carries its own travel distance, that is the only
    ---way to change how far a REGULAR door moves. Swaps are restricted to sets that share the rig and
    ---provide every animation name the current set does; see doorAnimSets.lua for why both matter.
    function device:drawTransformAnimationBakedSection()
        local componentID = self:findComponentIDByType(data.ANIMATED_COMPONENT_CLASS)
        if not componentID then return end

        local entries = self:getComponentPathArray(self, componentID, { "animations", "gameplay" })
        if #entries == 0 then return end

        -- Only shown for doors the generated store knows about: offering a free-text resource field
        -- for an arbitrary rig would invite exactly the swap that breaks the door.
        local anyKnown = false
        for _, entry in ipairs(entries) do
            if animSets.isKnown(readPath(entry, { "animSet", "DepotPath", "$value" })) then
                anyKnown = true
                break
            end
        end
        if not anyKnown then return end

        style.sectionHeaderStart("Baked animation", "The animgraph clips, used when animation type is REGULAR.")

        for index, entry in ipairs(entries) do
            local path = tostring(readPath(entry, { "animSet", "DepotPath", "$value" }) or "")
            local current = animSets.get(path)

            ImGui.PushID(3000 + index)

            style.mutedText(animSets.displayName(path))
            style.tooltip(path)

            if current then
                local compatible = animSets.getCompatible(path)

                if #compatible > 0 then
                    local options = { animSets.displayName(path) }
                    for _, option in ipairs(compatible) do
                        table.insert(options, animSets.displayName(option))
                    end

                    ImGui.SameLine()
                    local newIndex, didChange = style.trackedCombo(self.object, "##animSet", 0, options, 220)
                    if didChange and newIndex > 0 then
                        local target = compatible[newIndex]
                        if target then
                            history.addAction(history.getElementChange(self.object))
                            -- The wrapper shape comes from `convertResRefAsync`; only the path
                            -- changes, so the ref is rewritten rather than rebuilt.
                            writePath(entry, { "animSet", "DepotPath", "$value" }, target)
                            writePath(entry, { "animSet", "DepotPath", "$storage" }, "string")
                            self:updateComponentPathValue(self, componentID, { "animations", "gameplay" }, entries)
                        end
                    end
                    style.tooltip("Sets sharing this rig that provide every animation this one does. A shutter's height is the roll-up distance.")
                else
                    ImGui.SameLine()
                    style.styledText("no compatible alternative", style.extraMutedColor)
                    style.tooltip("No other shipped set shares this rig and provides every animation the graph asks for.")
                end

                ImGui.Indent(12 * style.viewSize)
                for _, animation in ipairs(current.animations) do
                    style.styledText(string.format("%s   %.2fs", animation.name, animation.duration), style.extraMutedColor)
                end
                ImGui.Unindent(12 * style.viewSize)
            else
                ImGui.SameLine()
                style.styledText("not a known door set", style.extraMutedColor)
            end

            ImGui.PopID()
        end

        style.sectionHeaderEnd()
    end

    -- Popup ------------------------------------------------------------------------------------------

    function device:drawTransformAnimationSetupPopup()
        local defaultWidth = 700 * style.viewSize
        local defaultHeight = 680 * style.viewSize
        local minWidth = 600 * style.viewSize
        local minHeight = 480 * style.viewSize
        local screenWidth, screenHeight = GetDisplayResolution()

        ImGui.SetNextWindowSize(defaultWidth, defaultHeight, ImGuiCond.FirstUseEver)
        ImGui.SetNextWindowSizeConstraints(
            minWidth, minHeight,
            math.max(minWidth, screenWidth - 40 * style.viewSize),
            math.max(minHeight, screenHeight - 40 * style.viewSize)
        )

        if not ImGui.BeginPopupModal(quickTransformAnimationSetupUI.POPUP_ID, true) then
            return
        end
        style.styledTextWrapped(IconGlyphs.Flask .. " Experimental feature : the Transform Animations manager is a work in progress. It is not yet fully tested and may have bugs or incomplete functionality.", style.activeColor)

        local componentID = self:getTransformAnimatorComponentID()

        if not componentID then
            ImGui.TextWrapped("Device state is not available yet. Ensure the device is spawned and assembled.")
            ImGui.Separator()
            if ImGui.Button("Close##transformAnimationsClose") then ImGui.CloseCurrentPopup() end
            ImGui.EndPopup()
            return
        end

        local animations = self:getTransformAnimationList(componentID)

        local _, availableY = ImGui.GetContentRegionAvail()
        local footerHeight = ImGui.GetFrameHeightWithSpacing() + 14 * style.viewSize

        if ImGui.BeginChild("##transformAnimationsBody", 0, math.max(0, availableY - footerHeight), false) then
            if data.isDoorEntity(self) then
                self:drawTransformAnimationDoorSection(componentID, animations)
                ImGui.Dummy(0, 8 * style.viewSize)
            else
                -- Non-door devices get the binding readout too; it is the one fact that decides
                -- whether anything below can be seen.
                local bound = data.getAnimatorBoundComponents(self, componentID)
                local labelWidth = ImGui.GetCursorPosX() + utils.getTextMaxWidth({ "Moves" })
                    + 3 * ImGui.GetStyle().ItemSpacing.x
                self:drawTransformAnimationBindingRow(bound, labelWidth)
                ImGui.Dummy(0, 8 * style.viewSize)
            end

            self:drawTransformAnimationBakedSection()

            self:drawTransformAnimationList(componentID, animations)
        end
        ImGui.EndChild()

        ImGui.Separator()
        if ImGui.Button("Close##transformAnimationsClose") then ImGui.CloseCurrentPopup() end

        ImGui.EndPopup()
    end
end

return quickTransformAnimationSetupUI
