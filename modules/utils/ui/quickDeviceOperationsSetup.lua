local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local history = require("modules/utils/project/history")
local registry = require("modules/utils/game/nodeRefRegistry")
local red = require("modules/utils/interop/redConverter")
local data = require("modules/utils/data/deviceOperations")

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

    ---Draw one field descriptor against the table that owns it. Mutates `owner` in place.
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

        if field.kind == "cname" or field.kind == "tweakdbid" then
            local currentText = field.kind == "cname" and data.readCName(current) or data.readRawValue(current)
            local newValue, _, finished = style.trackedTextField(
                self.object, "##field", currentText, field.kind == "cname" and "Name..." or "TweakDB ID...", width
            )
            if finished then
                writePath(owner, field.path, field.kind == "cname" and data.cname(newValue) or data.tweakDBID(newValue))
                changed, settled = true, true
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

            self.deviceOperationsFieldSearch = self.deviceOperationsFieldSearch or {}
            local searchKey = table.concat(field.path, "/") .. tostring(owner)
            local newValue, searchValue, finished = style.trackedSearchDropdown(
                "##field", "Search class...", currentClass,
                self.deviceOperationsFieldSearch[searchKey] or "", getActionClasses(),
                {
                    element = self.object,
                    width = 240,
                    matchContentWidth = true,
                    listHeight = 200,
                    tooltip = "Matched on class name only."
                }
            )
            self.deviceOperationsFieldSearch[searchKey] = searchValue

            if finished and newValue ~= "" and newValue ~= currentClass then
                writePath(owner, field.path, { HandleId = "0", Data = { ["$type"] = newValue } })
                changed, settled = true, true
            end

            if currentClass == "" and field.required then
                ImGui.SameLine()
                style.styledText(IconGlyphs.AlertOutline, style.warnColor)
                style.tooltip("This trigger reads the action's class name without a null check, so leaving it unset crashes the game when the trigger evaluates.")
            end
        end

        if field.hint then
            style.tooltip(field.hint)
        end

        return changed, settled
    end

    ---@param self table device spawnable
    ---@param fields table[]
    ---@param owner table
    ---@return boolean changed
    ---@return boolean settled
    local function drawFields(self, fields, owner)
        if not fields or #fields == 0 then return false, false end

        local labels = {}
        for _, field in ipairs(fields) do table.insert(labels, field.label) end
        local labelWidth = utils.getTextMaxWidth(labels) + 3 * ImGui.GetStyle().ItemSpacing.x

        local changed, settled = false, false
        for index, field in ipairs(fields) do
            ImGui.PushID(index)
            local fieldChanged, fieldSettled = drawField(self, field, owner, labelWidth)
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
        local defaultWidth = 720 * style.viewSize
        local defaultHeight = 720 * style.viewSize
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
        style.tooltip("Used to name the operations the template creates.")

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
        local built = template.build(utils.sanitizeText(self.deviceOperationsTemplatePrefix or ""))

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
                    if finished and newName ~= name then
                        -- Rename both sides at once: leaving the references behind is exactly the
                        -- silent breakage this panel exists to prevent.
                        writePath(operationData, { "operationName" }, data.cname(newName))
                        retargetReferences(triggers, operations, name, newName)
                        commit(operations, true, triggers)
                    end
                    style.tooltip("Referenced by triggers. The match is exact and case-sensitive.")

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
                        local fieldsChanged, fieldsSettled = drawFields(self, typeInfo.fields, operationData)
                        if fieldsChanged then commit(operations, fieldsSettled) end
                    elseif typeInfo and typeInfo.list then
                        local listChanged, listSettled = self:drawDeviceOperationPayloadList(typeInfo.list, operationData)
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

    ---Draw the repeated payload struct of an operation, e.g. the SFX entries of a Play sound.
    ---@param listInfo table
    ---@param operationData table
    ---@return boolean changed
    ---@return boolean settled
    function device:drawDeviceOperationPayloadList(listInfo, operationData)
        local entries = readPath(operationData, listInfo.path)
        if type(entries) ~= "table" then
            entries = {}
            writePath(operationData, listInfo.path, entries)
        end

        local changed, settled = false, false

        for index, entry in ipairs(entries) do
            ImGui.PushID(1000 + index)
            ImGui.Separator()

            style.mutedText(string.format("%s %d", listInfo.label, index))
            ImGui.SameLine()
            if style.dangerButton(IconGlyphs.DeleteOutline .. "##deletePayloadEntry") then
                history.addAction(history.getElementChange(self.object))
                table.remove(entries, index)
                ImGui.PopID()
                return true, true
            end

            local entryChanged, entrySettled = drawFields(self, listInfo.fields, entry)
            if entryChanged then
                changed = true
                settled = settled or entrySettled
            end

            ImGui.PopID()
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
                            local fieldsChanged, fieldsSettled = drawFields(self, typeInfo.fields, triggerData)
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
