local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local history = require("modules/utils/project/history")
local registry = require("modules/utils/game/nodeRefRegistry")
local red = require("modules/utils/interop/redConverter")
local data = require("modules/utils/data/deviceOperations")
local audioData = require("modules/utils/data/audioData")
local soundSelector = require("modules/utils/ui/soundSelector")

---Quick setup for `DeviceOperationsContainer`, available on any device whose controller PS derives
---from `ScriptableDeviceComponentPS`.
---
---The generic instance data editor can author this container, but it cannot help with the one thing
---that actually goes wrong: a trigger reaches an operation only by an exact, case-sensitive CName
---match, so a stray space means the trigger fires and nothing happens, with no error anywhere. Here
---that reference is a dropdown over the operations that exist, renames rewrite every reference, and
---names that can never match are called out.
---
---Deep payload editing stays in the generic editor. This panel owns structure and wiring: names,
---references, trigger conditions, ordering, and the common single-value payload fields.
local quickDeviceOperationsSetupUI = {
    POPUP_ID = "Device Operations##wb-Device-wui"
}

---@param device table
---@param options table?
function quickDeviceOperationsSetupUI.install(device, options)
    if not device then
        return
    end

    options = options or {}

    local actionClassCache = nil

    ---@return string[]
    local function getActionClasses()
        if not actionClassCache then
            actionClassCache = utils.getConcreteDerivedClasses("ScriptableDeviceAction")
        end
        return actionClassCache
    end

    ---Build a fresh RED object as editor JSON. `synthesizeNullHandles` fills in concrete sub-handles
    ---such as a trigger's `triggerData`; see redConverter.lua for why it is opt-in.
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

    ---@param handle table? A `{ HandleId, Data }` wrapper
    ---@return table?
    local function handleData(handle)
        if type(handle) ~= "table" then return nil end
        return type(handle.Data) == "table" and handle.Data or nil
    end

    ---@param operation table? Operation `Data`
    ---@return string
    local function operationName(operation)
        return data.readCName(readPath(operation, { "operationName" }))
    end

    -- Field rendering ---------------------------------------------------------------------------

    ---Column width a field gets when its descriptor does not name one, in unscaled style units.
    local DEFAULT_FIELD_WIDTHS = {
        cname = 180,
        tweakdbid = 240,
        noderef = 180,
        enum = 120,
        bool = 34,
        int = 90,
        float = 50,
        class = 240
    }

    ---@param field table
    ---@return number width In unscaled style units
    local function fieldWidth(field)
        return field.width or DEFAULT_FIELD_WIDTHS[field.kind] or 160
    end

    ---Width of the table column a field sits in: the widget, plus room for the warning icon the name
    ---fields draw after themselves. Without the extra the icon lands outside the cell and is clipped,
    ---which would hide exactly the marker saying the name matches nothing.
    ---@param field table
    ---@return number width In unscaled style units
    local function fieldColumnWidth(field)
        local canWarn = field.kind == "cname" or field.kind == "tweakdbid" or field.kind == "class"

        return fieldWidth(field) + (canWarn and 26 or 8)
    end

    ---Key under which a row's transient UI state (a dropdown's typed filter) is kept.
    ---
    ---Built from the row's *position*, never from the table it edits. `getComponentPathArray` hands
    ---out a fresh `deepcopy` on every frame, so a key derived from the owning table's identity
    ---changed every frame: the stored filter was never found again, and the typed text survived only
    ---for as long as ImGui served the input's own internal buffer -- that is, until it lost focus.
    ---@param keyPrefix string
    ---@param field table
    ---@return string
    local function searchStateKey(keyPrefix, field)
        return keyPrefix .. "/" .. table.concat(field.path, ".")
    end

    ---Joins a widget's own tooltip with the field's hint into the one tooltip the widget carries.
    ---
    ---`style.tooltip` binds to the last item drawn, so a widget that already set a tooltip and a
    ---hint emitted after it both bind to the same combo and render stacked on top of each other.
    ---Whichever branch draws a tooltip takes the hint into it instead.
    ---@param ... string? Parts, in the order they should read
    ---@return string? tooltip nil when every part was empty
    local function joinTooltip(...)
        local parts = {}

        for _, part in ipairs({ ... }) do
            if type(part) == "string" and part ~= "" then
                table.insert(parts, part)
            end
        end

        if #parts == 0 then return nil end

        return table.concat(parts, "\n\n")
    end

    ---Popup width that leaves room for a right-aligned annotation beside the longest option.
    ---
    ---`matchContentWidth` measures the option labels alone, and `trackedSearchDropdown` drops an
    ---annotation that does not fit after the label -- so with annotations on, the popup sized to the
    ---labels is exactly the width at which the annotations stop being drawn.
    ---@param options string[]
    ---@param annotations table<string, string>
    ---@return number width In unscaled style units
    local function annotatedPopupWidth(options, annotations)
        local widest = 0
        local styleData = ImGui.GetStyle()

        for _, option in ipairs(options) do
            local width = ImGui.CalcTextSize(option)
            local annotation = annotations[option]

            if type(annotation) == "string" and annotation ~= "" then
                width = width + (2 * styleData.ItemSpacing.x) + ImGui.CalcTextSize(annotation)
            end

            widest = math.max(widest, width)
        end

        local content = widest
            + (2 * styleData.WindowPadding.x)
            + (2 * styleData.FramePadding.x)
            + styleData.ScrollbarSize
            + styleData.ItemSpacing.x

        -- The same ceiling the label-only measurement uses: this width is applied as a minimum, so
        -- without it one absurdly named component would push the popup off the screen.
        local screenWidth = select(1, GetDisplayResolution()) or 0
        if screenWidth > 0 then
            content = math.min(content, screenWidth * 0.9)
        end

        return content / style.viewSize
    end

    ---Dropdown configuration for a field that names something, or nil when it stays free text.
    ---
    ---Every name in this panel is matched exactly at runtime and does nothing when it is wrong, with
    ---no log line -- so wherever the set of valid names can be read back off the entity, or off the
    ---shipped data, it is offered as a list instead of asking for a guess.
    ---@param self table device spawnable
    ---@param field table
    ---@param currentText string The value the field holds right now
    ---@return table? config
    local function resolveSelector(self, field, currentText)
        if field.selector == "component" then
            local options, classes = data.getComponents(self, field.componentFilter)
            local currentClass = classes[currentText]

            return {
                options = options,
                hint = "Search component or type...",
                -- The class of what is already picked, so the type is readable without opening the
                -- list: a device carries a dozen components named `mesh1`, `trigger`, `audio`, and
                -- which one of those a name is decides whether the operation does anything at all.
                tooltip = currentClass
                    and string.format("Component on this entity, matched by name.\nThis one is a %s.", currentClass)
                    or "Component on this entity, matched by name.",
                verify = true,
                matchWidth = true,
                popupMinWidth = annotatedPopupWidth(options, classes),
                annotationFn = function (optionText)
                    return classes[optionText] or ""
                end,
                tooltipFn = function (optionText)
                    local class = classes[optionText]
                    return class and string.format("%s\nClass: %s", optionText, class) or nil
                end,
                -- The class is on screen, so it has to be searchable too: `bink` should find the
                -- Bink component whatever its author called it.
                filterFn = function (optionText, query)
                    return utils.safePatternMatch(optionText:lower(), query)
                        or utils.safePatternMatch((classes[optionText] or ""):lower(), query)
                end,
                empty = field.componentFilter
                    and string.format("This entity carries no %s.", data.describeComponentFilter(field.componentFilter))
                    or "No components found on this entity yet."
            }
        elseif field.selector == "meshAppearance" then
            local options, owners, pending, meshCount = data.getMeshAppearanceNames(self)

            ---@param optionText string
            ---@return string
            local function describeOwners(optionText)
                local names = owners[optionText] or {}
                if #names == 0 then return "" end
                if #names == 1 then return names[1] end

                return string.format("%d meshes", #names)
            end

            local annotations = {}
            for _, option in ipairs(options) do
                annotations[option] = describeOwners(option)
            end

            return {
                options = options,
                hint = "Search appearance...",
                -- No tooltip of its own: the field's hint already says what a mesh appearance is and
                -- where the name lands, and both would render into the same tooltip.
                -- Not verified while the meshes are still being read: the list is genuinely
                -- incomplete then, and a warning on a name that is about to appear reads as a bug.
                verify = not pending,
                matchWidth = true,
                popupMinWidth = annotatedPopupWidth(options, annotations),
                annotationFn = function (optionText)
                    return annotations[optionText] or ""
                end,
                tooltipFn = function (optionText)
                    local names = owners[optionText] or {}
                    if #names == 0 then return nil end

                    return string.format(
                        "Offered by %d of this entity's %d mesh components:\n%s",
                        #names, meshCount, table.concat(names, "\n")
                    )
                end,
                empty = pending
                    and "Reading the appearances off this entity's meshes..."
                    or (meshCount == 0
                        and "This entity carries no mesh component, so there is no appearance to switch to."
                        or "None of this entity's meshes define a named appearance."),
                -- A list that has not finished loading is not a problem with what the author wrote,
                -- so it does not get the warning icon an empty list otherwise earns.
                emptyIcon = pending and IconGlyphs.TimerSand or nil,
                emptyColor = pending and style.mutedColor or nil
            }
        elseif field.selector == "animation" then
            return {
                options = data.getAnimationNames(self),
                hint = "Search clip...",
                tooltip = "Transform animation clip defined on this entity's animator component.",
                verify = true,
                matchWidth = true,
                empty = "This entity has no transform animator, so no clip name can play."
            }
        elseif field.selector == "vfx" then
            return {
                options = data.getEffectNames(self),
                hint = "Search effect...",
                tooltip = "Effect registered on this entity's entEffectSpawnerComponent. The operation starts it by name.",
                verify = true,
                matchWidth = true,
                empty = "This entity registers no effects, so there is no name to start."
            }
        elseif field.selector == "customAction" then
            local componentID = self:getDeviceOperationsComponentID()
            local entries = componentID
                and self:getComponentPathArray(self, componentID, data.CUSTOM_ACTIONS_PATH)
                or {}
            local isGeneric = data.classDerivesFrom(self.deviceClassName, data.GENERIC_PS_CLASS)

            return {
                options = data.readCustomActionIDs(entries),
                hint = "Search action...",
                tooltip = "One of this device's own custom actions. The name is invented per device, so this list is the whole vocabulary.",
                verify = true,
                matchWidth = true,
                empty = isGeneric
                    and "This device declares no custom actions. Add them under Entity Instance Data (genericDeviceActionsSetup.customActions.actions) first -- this operation only enables and disables actions that already exist, it cannot create one."
                    or string.format("This device's controller is %s, not GenericDeviceController, which is the only one that carries custom actions. Nothing here can fire.", tostring(self.deviceClassName))
            }

        elseif field.selector == "interactionTag" then
            -- The tags come from the `.interaction` descriptor the component points at, which CET
            -- cannot read, so this list is the shipped vocabulary rather than this entity's own.
            -- Custom stays on for a descriptor that names its layers differently.
            local hasInteraction = #data.getComponents(self, "gameinteractionsComponent") > 0

            return {
                options = data.getInteractionAreaTags(),
                hint = "Search tag...",
                tooltip = "Layer on the entity's interaction component. LogicArea is the 35m proximity layer nearly every device carries.",
                verify = false,
                matchWidth = true,
                annotationFn = data.annotateInteractionAreaTag,
                tooltipFn = data.describeInteractionAreaTag,
                warn = not hasInteraction
                    and "This entity carries no gameinteractionsComponent, so no interaction layer can raise this trigger."
                    or nil
            }

        elseif field.selector == "event" then
            local config = audioData.getFieldSelector("event")

            if config then
                -- Handed to the dedicated sound selector rather than a plain dropdown: an audio
                -- event name says nothing about what the event does, and this operation can both
                -- play and stop one, so nothing here is mandatory -- the filters are the author's.
                return {
                    sound = true,
                    options = {},
                    hint = config.hint,
                    tooltip = config.tooltip,
                    -- Not verified against a list: an event missing from the shipped metadata is
                    -- still playable, and modded soundbanks add their own.
                    verify = false
                }
            end
        elseif field.records then
            return {
                options = data.getRecordNames(field.records),
                hint = "Search record...",
                tooltip = string.format("%s entry from the live TweakDB. Custom IDs are accepted for records a mod adds.", field.records),
                verify = false,
                -- Same reason as the event list: item records alone run to tens of thousands.
                matchWidth = false
            }
        end

        return nil
    end

    ---Draw one field's widget, with no label of its own: the caller owns the layout, because the
    ---same descriptor is drawn as a labelled row by the single-value operations and as a table cell
    ---by the list ones.
    ---@param self table device spawnable
    ---@param field table Descriptor from the data module
    ---@param owner table Table holding the field
    ---@param keyPrefix string Stable identity for this row's transient UI state
    ---@param width number Widget width in unscaled style units
    ---@return boolean changed The value was written and must be persisted
    ---@return boolean settled The edit is over, so the device may respawn
    local function drawFieldWidget(self, field, owner, keyPrefix, width)
        local changed, settled = false, false
        local current = readPath(owner, field.path)
        -- Set by the branches that draw a tooltip of their own, which fold the hint into it.
        local hintConsumed = false

        self.deviceOperationsFieldSearch = self.deviceOperationsFieldSearch or {}
        self.deviceOperationsFieldShowAll = self.deviceOperationsFieldShowAll or {}

        if field.kind == "cname" or field.kind == "tweakdbid" then
            local currentText = field.kind == "cname" and data.readCName(current) or data.readRawValue(current)
            local selector = resolveSelector(self, field, currentText)

            ---@param text string
            ---@return table value The RED JSON form this field stores
            local function encode(text)
                return field.kind == "cname" and data.cname(text) or data.tweakDBID(text)
            end

            if selector and selector.sound then
                local newValue, finished = soundSelector.draw("##field", currentText, {
                    stateKey = string.format("deviceOperations/%s/%s", tostring(self.object and self.object.id), searchStateKey(keyPrefix, field)),
                    element = self.object,
                    width = width,
                    listHeight = 200,
                    hint = selector.hint,
                    tooltip = joinTooltip(selector.tooltip, field.hint),
                    showNote = false,
                    showTest = true,
                    testTarget = self:getEntity()
                })
                hintConsumed = true

                if finished and newValue ~= currentText then
                    writePath(owner, field.path, encode(newValue))
                    changed, settled = true, true
                end

            elseif selector then
                local searchKey = searchStateKey(keyPrefix, field)
                local newValue, searchValue, finished = style.trackedSearchDropdown(
                    "##field", selector.hint, currentText,
                    self.deviceOperationsFieldSearch[searchKey] or "", selector.options,
                    {
                        element = self.object,
                        width = width,
                        allowCustom = true,
                        matchContentWidth = selector.matchWidth == true,
                        popupMinWidth = selector.popupMinWidth,
                        listHeight = 200,
                        optionTooltipFn = selector.tooltipFn,
                        optionAnnotationFn = selector.annotationFn,
                        optionFilterFn = selector.filterFn,
                        tooltip = joinTooltip(selector.tooltip, field.hint)
                    }
                )
                hintConsumed = true
                self.deviceOperationsFieldSearch[searchKey] = searchValue

                if finished and newValue ~= currentText then
                    writePath(owner, field.path, encode(newValue))
                    changed, settled = true, true
                end

                if selector.warn then
                    ImGui.SameLine()
                    style.styledText(IconGlyphs.AlertOutline, style.warnColor)
                    style.tooltip(selector.warn)
                elseif #selector.options == 0 and selector.empty then
                    ImGui.SameLine()
                    style.styledText(selector.emptyIcon or IconGlyphs.AlertOutline, selector.emptyColor or style.warnColor)
                    style.tooltip(selector.empty)
                elseif selector.verify and currentText ~= "" and not utils.has_value(selector.options, currentText) then
                    ImGui.SameLine()
                    style.styledText(IconGlyphs.AlertOutline, style.warnColor)
                    style.tooltip(string.format(
                        "'%s' is not one of the %d names this entity offers, so nothing will match it.",
                        currentText, #selector.options
                    ))
                end
            else
                local newValue, _, finished = style.trackedTextField(
                    self.object, "##field", currentText, field.kind == "cname" and "Name..." or "TweakDB ID...", width
                )
                if finished then
                    writePath(owner, field.path, encode(newValue))
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
            -- Written on every change rather than only on commit: InputInt's +/- buttons do not
            -- raise IsItemDeactivatedAfterEdit, so a commit-only write would silently drop them.
            -- The explicit step/fastStep matter too -- trackedIntInput defaults them to min/max.
            local newValue, didChange, finished = style.trackedIntInput(
                self.object, "##field", math.floor(tonumber(current) or 0), -2147483648, 2147483647, width, 1, 10
            )
            if didChange then
                writePath(owner, field.path, newValue)
                changed, settled = true, finished
            end

        elseif field.kind == "float" then
            -- DragFloat keeps no buffer of its own: it renders whatever value it is handed. Writing
            -- only on commit means every frame of the drag hands it back the pre-drag value and the
            -- drag appears to snap back, so the value is written as it moves and settles on release.
            local newValue, didChange, finished = style.trackedDragFloat(
                self.object, "##field", tonumber(current) or 0, 0.05, -100000, 100000, "%.2f", width
            )
            if didChange then
                writePath(owner, field.path, newValue)
                changed, settled = true, finished
            end

        elseif field.kind == "enum" then
            local values = data.ENUMS[field.enum] or {}
            local index = math.max(0, utils.indexValue(values, tostring(current or "")) - 1)
            local newIndex, didChange = style.trackedCombo(self.object, "##field", index, values, width)
            if didChange then
                writePath(owner, field.path, values[newIndex + 1])
                changed, settled = true, true
            end

        elseif field.kind == "class" then
            -- A null handle whose declared type is abstract: only the class name is ever compared, so
            -- the picked class is the whole payload and the instance stays empty.
            local currentClass = ""
            local existing = handleData(readPath(owner, field.path))
            if existing and type(existing["$type"]) == "string" then
                currentClass = existing["$type"]
            end

            local searchKey = searchStateKey(keyPrefix, field)

            -- The trigger fires for any action the device performs, but the device can only perform
            -- the ones its controller creates -- 22 on a radio, out of the 325 ScriptableDeviceAction
            -- subclasses the unscoped list offers. Picking one of the other 303 is a trigger that can
            -- never fire, and nothing at runtime says so.
            local scoped = field.selector == "deviceAction"
                and data.getDeviceActions(self.deviceClassName)
                or nil
            -- A controller the table does not know (a modded one) resolves to nothing, and then the
            -- full list is not a fallback, it is the only honest answer.
            local canScope = scoped ~= nil and scoped.resolved and #scoped.options > 0
            local showAll = not canScope or self.deviceOperationsFieldShowAll[searchKey] == true

            local function currentOptions()
                return showAll and getActionClasses() or scoped.options
            end

            local newValue, searchValue, finished = style.trackedSearchDropdown(
                "##field", "Search class...", currentClass,
                self.deviceOperationsFieldSearch[searchKey] or "", currentOptions(),
                {
                    element = self.object,
                    width = width,
                    -- On with a scoped list so a modded action class can still be typed, and on with
                    -- the full one too, where it costs nothing.
                    allowCustom = true,
                    matchContentWidth = true,
                    listHeight = 200,
                    tooltip = joinTooltip(
                        canScope
                            and string.format(
                                "Matched on class name only.\n%s can raise %d interaction, %d quickhack and %d quest actions.",
                                tostring(self.deviceClassName),
                                scoped.counts.interaction or 0, scoped.counts.quickhack or 0, scoped.counts.quest or 0
                            )
                            or "Matched on class name only.",
                        field.hint
                    ),
                    drawHeaderFn = canScope and function ()
                        local expanded, toggled = style.toggleButton(IconGlyphs.FormatListBulleted .. "##allActions", showAll)
                        if toggled then
                            showAll = expanded
                            self.deviceOperationsFieldShowAll[searchKey] = expanded
                        end
                        style.tooltip("Show every device action in the game, not just the ones this controller can raise.\nOnly useful for an action a mod makes this device perform.")

                        ImGui.SameLine()
                        style.mutedText(showAll
                            and string.format("all %d actions", #getActionClasses())
                            or string.format("%d this device can perform", #scoped.options))
                    end or nil,
                    -- Read inside the popup so the toggle above narrows the list on the same frame.
                    optionsFn = currentOptions,
                    optionAnnotationFn = canScope and function (optionText)
                        return scoped.category[optionText] or ""
                    end or nil,
                    optionTooltipFn = function (optionText)
                        return data.describeDeviceAction(optionText, scoped and scoped.category[optionText] or nil)
                    end
                }
            )
            hintConsumed = true
            self.deviceOperationsFieldSearch[searchKey] = searchValue

            if finished and newValue ~= "" and newValue ~= currentClass then
                writePath(owner, field.path, { HandleId = "0", Data = { ["$type"] = newValue } })
                changed, settled = true, true
            end

            if currentClass == "" and field.required then
                ImGui.SameLine()
                style.styledText(IconGlyphs.AlertOutline, style.warnColor)
                style.tooltip("This trigger reads the action's class name without a null check, so leaving it unset crashes the game when the trigger evaluates.")
            elseif canScope and currentClass ~= "" and not scoped.category[currentClass] then
                ImGui.SameLine()
                style.styledText(IconGlyphs.AlertOutline, style.warnColor)
                style.tooltip(string.format(
                    "%s never creates a %s, so this trigger cannot fire.\nPick one of the %d actions this controller can perform, unless a mod raises this action on it.",
                    tostring(self.deviceClassName), currentClass, #scoped.options
                ))
            end
        end

        if field.hint and not hintConsumed then
            style.tooltip(field.hint)
        end

        return changed, settled
    end

    ---Draw a set of fields as labelled rows, for the operations whose payload is a single struct.
    ---@param self table device spawnable
    ---@param fields table[]
    ---@param owner table
    ---@param keyPrefix string
    ---@return boolean changed
    ---@return boolean settled
    local function drawFields(self, fields, owner, keyPrefix)
        if not fields or #fields == 0 then return false, false end

        local labels = {}
        for _, field in ipairs(fields) do table.insert(labels, field.label) end
        local labelWidth = utils.getTextMaxWidth(labels) + 3 * ImGui.GetStyle().ItemSpacing.x

        local changed, settled = false, false
        for index, field in ipairs(fields) do
            ImGui.PushID(index)

            style.mutedText(field.label)
            ImGui.SameLine()
            ImGui.SetCursorPosX(labelWidth)

            local fieldChanged, fieldSettled = drawFieldWidget(self, field, owner, keyPrefix, fieldWidth(field))
            if fieldChanged then
                changed = true
                settled = settled or fieldSettled
            end

            ImGui.PopID()
        end

        return changed, settled
    end

    -- Container access ----------------------------------------------------------------------------

    ---@return string?
    function device:getDeviceOperationsComponentID()
        return self:getPersistentComponentID(self, self.deviceClassName)
    end

    ---@param componentID string
    ---@return boolean
    function device:hasDeviceOperationsContainer(componentID)
        return handleData(self:getComponentPathValue(self, componentID, data.CONTAINER_PATH)) ~= nil
    end

    ---@param componentID string
    function device:createDeviceOperationsContainer(componentID)
        local container = makeHandle(data.CONTAINER_CLASS)
        if not container then return end

        history.addAction(history.getElementChange(self.object))
        self:updateComponentPathValue(self, componentID, data.CONTAINER_PATH, container)
    end

    ---@param componentID string
    function device:removeDeviceOperationsContainer(componentID)
        history.addAction(history.getElementChange(self.object))
        self:updateComponentPathValue(self, componentID, data.CONTAINER_PATH, nil)
    end

    ---@param componentID string
    ---@return table[]
    function device:getDeviceOperationsList(componentID)
        return self:getComponentPathArray(self, componentID, data.OPERATIONS_PATH)
    end

    ---@param componentID string
    ---@return table[]
    function device:getDeviceOperationTriggerList(componentID)
        return self:getComponentPathArray(self, componentID, data.TRIGGERS_PATH)
    end

    ---Rewrite every reference to `oldName`, so renaming an operation cannot silently orphan the
    ---triggers that run it. Covers both reference sites: a trigger's `operationsToExecute` and an
    ---operation's own `toggleOperations`.
    ---@param triggers table[]
    ---@param operations table[]
    ---@param oldName string
    ---@param newName string
    local function retargetReferences(triggers, operations, oldName, newName)
        for _, trigger in ipairs(triggers) do
            local triggerData = handleData(handleData(trigger) and readPath(handleData(trigger), { "triggerData" }))
            for _, execution in ipairs(triggerData and readPath(triggerData, { "operationsToExecute" }) or {}) do
                local execData = handleData(execution)
                if execData and data.readCName(readPath(execData, { "operationName" })) == oldName then
                    writePath(execData, { "operationName" }, data.cname(newName))
                end
            end
        end

        for _, operation in ipairs(operations) do
            local operationData = handleData(operation)
            for _, toggle in ipairs(operationData and readPath(operationData, { "toggleOperations" }) or {}) do
                if data.readCName(readPath(toggle, { "operationName" })) == oldName then
                    writePath(toggle, { "operationName" }, data.cname(newName))
                end
            end
        end
    end

    -- Popup ---------------------------------------------------------------------------------------

    function device:drawDeviceOperationsSetupPopup()
        -- Wide enough for the payload tables: the broadest of them (Play effect) is a little over
        -- 800 unscaled units of columns, and a table clips at the window edge rather than scrolling.
        local defaultWidth = 900 * style.viewSize
        local defaultHeight = 760 * style.viewSize
        local minWidth = 620 * style.viewSize
        local minHeight = 520 * style.viewSize
        local screenWidth, screenHeight = GetDisplayResolution()

        ImGui.SetNextWindowSize(defaultWidth, defaultHeight, ImGuiCond.FirstUseEver)
        ImGui.SetNextWindowSizeConstraints(
            minWidth, minHeight,
            math.max(minWidth, screenWidth - 40 * style.viewSize),
            math.max(minHeight, screenHeight - 40 * style.viewSize)
        )

        if not ImGui.BeginPopupModal(quickDeviceOperationsSetupUI.POPUP_ID, true) then
            return
        end
        style.styledTextWrapped(IconGlyphs.Flask .. " Experimental feature : the Device Operations manager is a work in progress. It is not yet fully tested and may have bugs or incomplete functionality.", style.activeColor)


        local componentID = self:getDeviceOperationsComponentID()

        if not componentID then
            ImGui.TextWrapped("Device state is not available yet. Ensure the device is spawned and assembled.")
            ImGui.Separator()
            if ImGui.Button("Close##deviceOperationsClose") then ImGui.CloseCurrentPopup() end
            ImGui.EndPopup()
            return
        end

        if not self:hasDeviceOperationsContainer(componentID) then
            self:drawDeviceOperationsEmptyState(componentID)
            ImGui.EndPopup()
            return
        end

        local operations = self:getDeviceOperationsList(componentID)
        local triggers = self:getDeviceOperationTriggerList(componentID)

        self:drawDeviceOperationsWarnings(componentID, operations, triggers)

        local _, availableY = ImGui.GetContentRegionAvail()
        local footerHeight = ImGui.GetFrameHeightWithSpacing() + 14 * style.viewSize

        if ImGui.BeginChild("##deviceOperationsBody", 0, math.max(0, availableY - footerHeight), false) then
            self:drawDeviceOperationsList(componentID, operations, triggers)
            ImGui.Dummy(0, 8 * style.viewSize)
            self:drawDeviceOperationTriggerList(componentID, operations, triggers)
        end
        ImGui.EndChild()

        ImGui.Separator()
        if ImGui.Button("Close##deviceOperationsClose") then ImGui.CloseCurrentPopup() end
        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline .. " Remove container##deviceOperationsRemove") then
            self:removeDeviceOperationsContainer(componentID)
        end
        style.tooltip("Removes the whole container, putting the device back to the null it shipped with.")

        ImGui.EndPopup()
    end

    ---@param componentID string
    function device:drawDeviceOperationsEmptyState(componentID)
        style.styledTextWrapped(
            "This device has no DeviceOperationsContainer. It ships null on virtually every device, which is why nothing is listed here yet.",
            style.extraMutedColor
        )
        ImGui.Dummy(0, 4 * style.viewSize)
        ImGui.TextWrapped("Creating one lets the device react to state changes, actions, quest facts and volumes by playing sounds, effects, animations and more, with no scripting.")
        ImGui.Dummy(0, 8 * style.viewSize)

        if ImGui.Button(IconGlyphs.Plus .. " Create container##deviceOperationsCreate") then
            self:createDeviceOperationsContainer(componentID)
        end

        ImGui.Dummy(0, 10 * style.viewSize)
        style.sectionHeaderStart("Or start from a template")

        self.deviceOperationsTemplatePrefix = self.deviceOperationsTemplatePrefix or ""
        style.mutedText("Name prefix")
        ImGui.SameLine()
        self.deviceOperationsTemplatePrefix = style.trackedTextField(
            self.object, "##deviceOperationsPrefix", self.deviceOperationsTemplatePrefix, "e.g. fan", 160
        )
        style.tooltip("Used to name the operations the template creates.\nSpaces are stored as underscores, since a name with one can never be matched.")

        for _, template in ipairs(data.TEMPLATES) do
            ImGui.Dummy(0, 4 * style.viewSize)
            if ImGui.Button(template.label .. "##deviceOperationsTemplate" .. template.id) then
                self:applyDeviceOperationsTemplate(componentID, template)
            end
            style.tooltip(template.description)

            if template.needsSoundComponent and not data.hasSoundComponent(self) then
                ImGui.SameLine()
                style.styledText(IconGlyphs.AlertOutline, style.warnColor)
                style.tooltip("This entity has no gameaudioSoundComponent, so the sound will not route anywhere. That component cannot be added from World Builder; it has to be added to the .ent.")
            end
        end

        style.sectionHeaderEnd()

        ImGui.Separator()
        if ImGui.Button("Close##deviceOperationsClose") then ImGui.CloseCurrentPopup() end
    end

    ---@param componentID string
    ---@param template table
    function device:applyDeviceOperationsTemplate(componentID, template)
        -- Folded the same way a typed operation name is: the prefix ends up inside every name the
        -- template creates, and there is no name field here for the author to notice a space in.
        local built = template.build(data.sanitizeOperationName(utils.sanitizeText(self.deviceOperationsTemplatePrefix or "")))

        local operations = self:hasDeviceOperationsContainer(componentID) and self:getDeviceOperationsList(componentID) or {}
        local triggers = self:hasDeviceOperationsContainer(componentID) and self:getDeviceOperationTriggerList(componentID) or {}

        for _, spec in ipairs(built.operations) do
            local handle = makeHandle(spec.class)
            if handle then
                writePath(handle.Data, { "operationName" }, data.cname(spec.name))

                for _, entry in ipairs(spec.set or {}) do
                    if entry.listItem then
                        local item = makeObject(entry.listItem)
                        if item then
                            for _, value in ipairs(entry.values or {}) do
                                writePath(item, value.path, value.value)
                            end
                            writePath(handle.Data, entry.path, { item })
                        end
                    end
                end

                table.insert(operations, handle)
            end
        end

        for _, spec in ipairs(built.triggers) do
            local handle = makeHandle(spec.class)
            local triggerData = handle and handleData(readPath(handle.Data, { "triggerData" }))
            if triggerData then
                for _, value in ipairs(spec.values or {}) do
                    writePath(triggerData, value.path, value.value)
                end

                local executions = {}
                for _, name in ipairs(spec.runs or {}) do
                    local execution = makeHandle(data.EXECUTION_CLASS)
                    if execution then
                        writePath(execution.Data, { "operationName" }, data.cname(name))
                        table.insert(executions, execution)
                    end
                end
                writePath(triggerData, { "operationsToExecute" }, executions)

                table.insert(triggers, handle)
            end
        end

        history.addAction(history.getElementChange(self.object))

        if not self:hasDeviceOperationsContainer(componentID) then
            local container = makeHandle(data.CONTAINER_CLASS)
            if not container then return end
            writePath(container.Data, { "operations" }, operations)
            writePath(container.Data, { "triggers" }, triggers)
            self:updateComponentPathValue(self, componentID, data.CONTAINER_PATH, container)
            return
        end

        self:updateComponentPathValue(self, componentID, data.OPERATIONS_PATH, operations, { suppressRespawn = true })
        self:updateComponentPathValue(self, componentID, data.TRIGGERS_PATH, triggers)
    end

    ---@param componentID string
    ---@param operations table[]
    ---@param triggers table[]
    function device:drawDeviceOperationsWarnings(componentID, operations, triggers)
        local names = {}
        local referenced = {}
        local usesSound = false

        for _, operation in ipairs(operations) do
            local operationData = handleData(operation)
            if operationData then
                table.insert(names, operationName(operationData))
                if operationData["$type"] == "PlaySoundDeviceOperation" then usesSound = true end
                for _, toggle in ipairs(readPath(operationData, { "toggleOperations" }) or {}) do
                    referenced[data.readCName(readPath(toggle, { "operationName" }))] = true
                end
            end
        end

        for _, trigger in ipairs(triggers) do
            local triggerData = handleData(readPath(handleData(trigger) or {}, { "triggerData" }))
            for _, execution in ipairs(triggerData and readPath(triggerData, { "operationsToExecute" }) or {}) do
                local execData = handleData(execution)
                if execData then referenced[data.readCName(readPath(execData, { "operationName" }))] = true end
            end
        end

        local unused, orphans, duplicates = data.crossReference(names, referenced)

        local function warn(text)
            style.styledTextWrapped(IconGlyphs.AlertOutline .. " " .. text, style.warnColor)
        end

        for name, _ in pairs(orphans) do
            warn(string.format("No operation is named '%s', so the trigger asking for it does nothing.", name))
        end

        for _, name in ipairs(names) do
            local problem = data.checkOperationName(name)
            if problem then
                warn(string.format("Operation '%s': %s", name, problem))
            end
        end

        if usesSound and not data.hasSoundComponent(self) then
            warn("This entity has no gameaudioSoundComponent, so Play sound does nothing. That component cannot be added from World Builder; it has to be added to the .ent.")
        end

        if not self.persistent then
            warn("Persistent is off, so this setup is not written to the .psrep file.")
        end

        local notes = {}
        for name, _ in pairs(unused) do
            if name ~= "" then table.insert(notes, string.format("'%s' is never referenced by a trigger", name)) end
        end
        for name, count in pairs(duplicates) do
            table.insert(notes, string.format("%d operations share the name '%s', so a trigger runs all of them", count, name))
        end

        if #notes > 0 then
            table.sort(notes)
            style.styledTextWrapped(IconGlyphs.InformationOutline .. " " .. table.concat(notes, ". ") .. ".", style.extraMutedColor)
        end

        -- Editing the container of a device already loaded in a save has no effect: `m_operations` is
        -- persistent, so the save's copy wins until the state is forgotten.
        style.styledTextWrapped(
            IconGlyphs.InformationOutline .. " Operations are saved with the device. On a save that already loaded it, use the reload button next to Persistent.",
            style.extraMutedColor
        )

        ImGui.Dummy(0, 6 * style.viewSize)
    end

    ---@param componentID string
    ---@param operations table[]
    ---@param triggers table[]
    function device:drawDeviceOperationsList(componentID, operations, triggers)
        style.sectionHeaderStart(string.format("Operations (%d)", #operations), "Named effects. Triggers run them by name.")

        -- History is not pushed here: every tracked widget already records one at the start of its
        -- own edit, so doing it again would double up (and, during a drag, once per frame). The
        -- structural buttons below are plain ImGui, so those push their own.
        ---@param settled boolean? false while an edit is still in flight, which holds off the respawn
        local function commit(newOperations, settled, newTriggers)
            if newTriggers then
                self:updateComponentPathValue(self, componentID, data.TRIGGERS_PATH, newTriggers, { suppressRespawn = true })
            end
            self:updateComponentPathValue(self, componentID, data.OPERATIONS_PATH, newOperations, { suppressRespawn = settled == false })
        end

        for index, operation in ipairs(operations) do
            local operationData = handleData(operation)
            if operationData then
                ImGui.PushID(index)

                local keyPrefix = string.format("operation%d", index)
                local class = tostring(operationData["$type"] or "")
                local name = operationName(operationData)
                local header = string.format("%s  -  %s", name ~= "" and name or "<unnamed>", data.getOperationLabel(class))

                local open = ImGui.TreeNodeEx(header .. "###operation")

                ImGui.SameLine()
                if style.dangerButton(IconGlyphs.DeleteOutline .. "##deleteOperation") then
                    history.addAction(history.getElementChange(self.object))
                    table.remove(operations, index)
                    commit(operations, true)
                    if open then ImGui.TreePop() end
                    ImGui.PopID()
                    break
                end
                style.tooltip("Delete this operation.")

                if index > 1 then
                    ImGui.SameLine()
                    if ImGui.Button(IconGlyphs.ArrowUp .. "##moveOperationUp") then
                        history.addAction(history.getElementChange(self.object))
                        operations[index], operations[index - 1] = operations[index - 1], operations[index]
                        commit(operations, true)
                    end
                end

                if index < #operations then
                    ImGui.SameLine()
                    if ImGui.Button(IconGlyphs.ArrowDown .. "##moveOperationDown") then
                        history.addAction(history.getElementChange(self.object))
                        operations[index], operations[index + 1] = operations[index + 1], operations[index]
                        commit(operations, true)
                    end
                end

                if open then
                    local typeInfo = data.getOperationType(class)
                    if typeInfo and typeInfo.hint then
                        style.styledTextWrapped(typeInfo.hint, style.extraMutedColor)
                    end

                    style.mutedText("Name")
                    ImGui.SameLine()
                    local newName, _, finished = style.trackedTextField(self.object, "##operationName", name, "Operation name...", 240)
                    if finished then
                        -- Folded before it is stored, so a typed space cannot produce a name no
                        -- trigger can reference. The field shows the stored form on the next frame.
                        newName = data.sanitizeOperationName(newName)
                    end
                    if finished and newName ~= name then
                        -- Rename both sides at once: leaving the references behind is exactly the
                        -- silent breakage this panel exists to prevent.
                        writePath(operationData, { "operationName" }, data.cname(newName))
                        retargetReferences(triggers, operations, name, newName)
                        commit(operations, true, triggers)
                    end
                    style.tooltip("Referenced by triggers. The match is exact and case-sensitive.\nSpaces are stored as underscores, since a name with one can never be matched.")

                    local problem = data.checkOperationName(name)
                    if problem then
                        ImGui.SameLine()
                        style.styledText(IconGlyphs.AlertOutline, style.warnColor)
                        style.tooltip(problem)
                    end

                    local enabled, enabledChanged = style.trackedCheckbox(self.object, "Enabled##operationEnabled", data.readBool(operationData.isEnabled))
                    if enabledChanged then
                        operationData.isEnabled = enabled and 1 or 0
                        commit(operations, true)
                    end

                    ImGui.SameLine()
                    local once, onceChanged = style.trackedCheckbox(self.object, "Run once##operationOnce", data.readBool(operationData.executeOnce))
                    if onceChanged then
                        operationData.executeOnce = once and 1 or 0
                        commit(operations, true)
                    end

                    ImGui.SameLine()
                    local disables, disablesChanged = style.trackedCheckbox(self.object, "Disable device##operationDisable", data.readBool(operationData.disableDevice))
                    if disablesChanged then
                        operationData.disableDevice = disables and 1 or 0
                        commit(operations, true)
                    end

                    if typeInfo and typeInfo.deferToInstanceData then
                        style.styledTextWrapped("Edit this operation's payload under Entity Instance Data.", style.extraMutedColor)
                    elseif typeInfo and typeInfo.fields then
                        local fieldsChanged, fieldsSettled = drawFields(self, typeInfo.fields, operationData, keyPrefix)
                        if fieldsChanged then commit(operations, fieldsSettled) end
                    elseif typeInfo and typeInfo.list then
                        local listChanged, listSettled = self:drawDeviceOperationPayloadList(typeInfo.list, operationData, keyPrefix)
                        if listChanged then commit(operations, listSettled) end
                    end

                    ImGui.TreePop()
                end

                ImGui.PopID()
            end
        end

        if ImGui.Button(IconGlyphs.Plus .. " Add operation##addOperation") then
            ImGui.OpenPopup("##addOperationMenu")
        end

        if ImGui.BeginPopup("##addOperationMenu") then
            for _, typeInfo in ipairs(data.OPERATION_TYPES) do
                if ImGui.MenuItem(typeInfo.label) then
                    local handle = makeHandle(typeInfo.class)
                    if handle then
                        history.addAction(history.getElementChange(self.object))
                        writePath(handle.Data, { "operationName" }, data.cname(string.format("operation_%d", #operations + 1)))
                        table.insert(operations, handle)
                        commit(operations, true)
                    end
                end
                style.tooltip(typeInfo.class)
            end
            ImGui.EndPopup()
        end

        style.sectionHeaderEnd()
    end

    ---Draw the repeated payload struct of an operation -- the SFX entries of a Play sound, the items
    ---of a Grant items -- as a table, one row per entry and one column per field.
    ---
    ---A table rather than a stack of labelled rows because these lists are read as much as they are
    ---written: with three sounds on one operation the question is almost always "which of these is
    ---the STOP", and stacked rows repeat every label three times to answer it. The columns are fixed
    ---width, so a narrow window clips the rightmost ones rather than scrolling -- the popup opens
    ---wide enough for the broadest of them and can be widened further.
    ---@param listInfo table
    ---@param operationData table
    ---@param keyPrefix string Stable identity for this operation's transient UI state
    ---@return boolean changed
    ---@return boolean settled
    function device:drawDeviceOperationPayloadList(listInfo, operationData, keyPrefix)
        local entries = readPath(operationData, listInfo.path)
        if type(entries) ~= "table" then
            entries = {}
            writePath(operationData, listInfo.path, entries)
        end

        local changed, settled = false, false
        local fields = listInfo.fields

        if #entries > 0 then
            local tableFlags = ImGuiTableFlags.SizingFixedFit
                + ImGuiTableFlags.BordersInnerV
                + ImGuiTableFlags.BordersOuter
                + ImGuiTableFlags.RowBg

            -- The id is the item class and nothing else. It must not carry anything that changes
            -- while the panel is open -- the same trap as `##` on the tree node headers, where a
            -- computed label folded into the id made ImGui treat the widget as a brand new one.
            if ImGui.BeginTable("##payload" .. tostring(listInfo.itemClass), #fields + 2, tableFlags) then
                ImGui.TableSetupColumn("#", ImGuiTableColumnFlags.WidthFixed, 18 * style.viewSize)
                for _, field in ipairs(fields) do
                    ImGui.TableSetupColumn(field.label, ImGuiTableColumnFlags.WidthFixed, fieldColumnWidth(field) * style.viewSize)
                end
                ImGui.TableSetupColumn("", ImGuiTableColumnFlags.WidthFixed, 30 * style.viewSize)
                ImGui.TableHeadersRow()

                for index, entry in ipairs(entries) do
                    ImGui.PushID(1000 + index)
                    ImGui.TableNextRow()

                    ImGui.TableNextColumn()
                    style.mutedText(tostring(index))

                    local rowKeyPrefix = string.format("%s/%s/%d", keyPrefix, tostring(listInfo.itemClass), index)

                    for fieldIndex, field in ipairs(fields) do
                        ImGui.TableNextColumn()
                        ImGui.PushID(fieldIndex)

                        local fieldChanged, fieldSettled = drawFieldWidget(self, field, entry, rowKeyPrefix, fieldWidth(field))
                        if fieldChanged then
                            changed = true
                            settled = settled or fieldSettled
                        end

                        ImGui.PopID()
                    end

                    ImGui.TableNextColumn()
                    if style.dangerButton(IconGlyphs.DeleteOutline .. "##deletePayloadEntry") then
                        history.addAction(history.getElementChange(self.object))
                        table.remove(entries, index)
                        ImGui.PopID()
                        ImGui.EndTable()
                        return true, true
                    end
                    style.tooltip(string.format("Delete this %s.", listInfo.singular))

                    ImGui.PopID()
                end

                ImGui.EndTable()
            end
        else
            style.mutedText(string.format("No %s yet.", listInfo.label:lower()))
        end

        if ImGui.Button(IconGlyphs.Plus .. " Add " .. listInfo.singular .. "##addPayloadEntry") then
            local item = makeObject(listInfo.itemClass)
            if item then
                history.addAction(history.getElementChange(self.object))
                table.insert(entries, item)
                changed, settled = true, true
            end
        end

        return changed, settled
    end

    ---@param componentID string
    ---@param operations table[]
    ---@param triggers table[]
    function device:drawDeviceOperationTriggerList(componentID, operations, triggers)
        style.sectionHeaderStart(string.format("Triggers (%d)", #triggers), "Conditions that run operations by name.")

        local operationNames = {}
        for _, operation in ipairs(operations) do
            local operationData = handleData(operation)
            local name = operationData and operationName(operationData) or ""
            if name ~= "" and not utils.has_value(operationNames, name) then
                table.insert(operationNames, name)
            end
        end

        ---@param settled boolean? false while an edit is still in flight, which holds off the respawn
        local function commit(newTriggers, settled)
            self:updateComponentPathValue(self, componentID, data.TRIGGERS_PATH, newTriggers, { suppressRespawn = settled == false })
        end

        for index, trigger in ipairs(triggers) do
            local triggerObject = handleData(trigger)
            local triggerData = handleData(triggerObject and readPath(triggerObject, { "triggerData" }))

            if triggerObject then
                ImGui.PushID(5000 + index)

                local keyPrefix = string.format("trigger%d", index)
                local class = tostring(triggerObject["$type"] or "")
                local runs = {}
                for _, execution in ipairs(triggerData and readPath(triggerData, { "operationsToExecute" }) or {}) do
                    local execData = handleData(execution)
                    if execData then table.insert(runs, data.readCName(readPath(execData, { "operationName" }))) end
                end

                local header = string.format("%s  ->  %s", data.getTriggerLabel(class),
                    #runs > 0 and table.concat(runs, ", ") or "<nothing>")

                local open = ImGui.TreeNodeEx(header .. "###trigger")

                ImGui.SameLine()
                if style.dangerButton(IconGlyphs.DeleteOutline .. "##deleteTrigger") then
                    history.addAction(history.getElementChange(self.object))
                    table.remove(triggers, index)
                    commit(triggers, true)
                    if open then ImGui.TreePop() end
                    ImGui.PopID()
                    break
                end
                style.tooltip("Delete this trigger.")

                if open then
                    local typeInfo = data.getTriggerType(class)
                    if typeInfo and typeInfo.hint then
                        style.styledTextWrapped(typeInfo.hint, style.extraMutedColor)
                    end

                    if not triggerData then
                        style.styledTextWrapped("This trigger has no trigger data and will never fire. Delete and re-add it.", style.warnColor)
                    else
                        if typeInfo then
                            local fieldsChanged, fieldsSettled = drawFields(self, typeInfo.fields, triggerData, keyPrefix)
                            if fieldsChanged then commit(triggers, fieldsSettled) end
                        end

                        local runsChanged, runsSettled = self:drawDeviceOperationExecutions(triggerData, operationNames)
                        if runsChanged then commit(triggers, runsSettled) end
                    end

                    ImGui.TreePop()
                end

                ImGui.PopID()
            end
        end

        if ImGui.Button(IconGlyphs.Plus .. " Add trigger##addTrigger") then
            ImGui.OpenPopup("##addTriggerMenu")
        end

        if ImGui.BeginPopup("##addTriggerMenu") then
            for _, typeInfo in ipairs(data.TRIGGER_TYPES) do
                if ImGui.MenuItem(typeInfo.label) then
                    local handle = makeHandle(typeInfo.class)
                    if handle then
                        history.addAction(history.getElementChange(self.object))
                        table.insert(triggers, handle)
                        commit(triggers, true)
                    end
                end
                style.tooltip(typeInfo.class)
            end
            ImGui.EndPopup()
        end

        style.sectionHeaderEnd()
    end

    ---The reference list: which operations this trigger runs, and after how long.
    ---@param triggerData table
    ---@param operationNames string[]
    ---@return boolean changed
    ---@return boolean settled
    function device:drawDeviceOperationExecutions(triggerData, operationNames)
        local executions = readPath(triggerData, { "operationsToExecute" })
        if type(executions) ~= "table" then
            executions = {}
            writePath(triggerData, { "operationsToExecute" }, executions)
        end

        local changed, settled = false, false

        style.mutedText("Runs operations")

        for index, execution in ipairs(executions) do
            local execData = handleData(execution)
            if execData then
                ImGui.PushID(9000 + index)

                local current = data.readCName(readPath(execData, { "operationName" }))
                local knownIndex = utils.indexValue(operationNames, current)

                if #operationNames == 0 then
                    style.mutedText("Add an operation first")
                else
                    -- A dropdown over the operations that exist, rather than free text: an exact,
                    -- case-sensitive CName match is the only way a trigger reaches an operation, and
                    -- a mistyped one fails silently.
                    local comboIndex = math.max(0, knownIndex - 1)
                    local newIndex, didChange = style.trackedCombo(self.object, "##executionName", comboIndex, operationNames, 240)
                    if didChange then
                        writePath(execData, { "operationName" }, data.cname(operationNames[newIndex + 1]))
                        changed, settled = true, true
                    end
                end

                if knownIndex < 1 then
                    ImGui.SameLine()
                    style.styledText(IconGlyphs.AlertOutline, style.warnColor)
                    style.tooltip(string.format("No operation is named '%s'. This trigger fires and nothing happens.", current))
                end

                ImGui.SameLine()
                style.mutedText("Delay")
                ImGui.SameLine()
                -- Written as the drag moves, not only on release: DragFloat renders the value it is
                -- handed, so a commit-only write hands back the pre-drag value every frame and the
                -- drag snaps back. `settled` stays false until release, which holds off the respawn.
                local delay, delayChanged, delayFinished = style.trackedDragFloat(
                    self.object, "##executionDelay", tonumber(readPath(execData, { "delay" })) or 0, 0.05, 0, 3600, "%.2fs", 80
                )
                if delayChanged then
                    writePath(execData, { "delay" }, delay)
                    changed, settled = true, delayFinished
                end
                style.tooltip("Seconds before the operation runs. The delay lives on this reference, so the same operation can be instant from one trigger and delayed from another.")

                ImGui.SameLine()
                if style.dangerButton(IconGlyphs.DeleteOutline .. "##deleteExecution") then
                    history.addAction(history.getElementChange(self.object))
                    table.remove(executions, index)
                    ImGui.PopID()
                    return true, true
                end

                ImGui.PopID()
            end
        end

        if ImGui.Button(IconGlyphs.Plus .. " Run another operation##addExecution") then
            local execution = makeHandle(data.EXECUTION_CLASS)
            if execution then
                history.addAction(history.getElementChange(self.object))
                writePath(execution.Data, { "operationName" }, data.cname(operationNames[1] or ""))
                table.insert(executions, execution)
                changed, settled = true, true
            end
        end

        return changed, settled
    end
end

return quickDeviceOperationsSetupUI
