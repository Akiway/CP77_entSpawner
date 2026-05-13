local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local registry = require("modules/utils/nodeRefRegistry")
local history = require("modules/utils/history")

local quickElevatorSetupUI = {
    POPUP_ID = "Quick Elevator Setup##Device"
}

local LIFT_FLOOR_DOOR_LABELS = { "Door 1", "Door 2", "Door 3" }
local FLOOR_LOCALIZATION_SUGGESTIONS = {
    2005, 2006, 2007, 2008, 49169, 49176, 49177, 49178, 49179, 49182, 49183, 49184, 49185, 49186, 49187, 49188, 49189, 49190, 49195, 49196, 49197, 49200, 49201, 49202, 49203, 49204, 49205, 49206, 49207, 49208, 49209, 49210, 49211, 49212, 49213, 49234, 49235, 49236, 49237, 49238, 49239, 49240, 49241, 49242, 49243, 49244, 49245, 49246, 49247, 49248, 49249, 49250, 49251, 49252, 49253, 49254, 49255, 49256, 49257, 49258, 49259, 49260, 49261, 49262, 49263, 49264, 49265, 49266, 49267, 49268, 49269, 49270, 49271, 49272, 49273, 49274, 49275, 49276, 49277, 49278, 49280, 49281, 49282, 49283, 49284, 49285, 49286, 49287, 49288, 49289, 49290, 49291, 49292, 49293, 49294, 49295, 49531, 49876, 49877, 49878, 50190, 50191, 50192, 50195, 50764, 50765, 51054, 51069, 51281, 53282, 53285, 80842, 80843, 84164, 84197, 85520, 86523, 86747, 86748, 86749, 86750, 86971, 86972, 86973, 86977, 88319, 88463, 88464, 88465, 91405, 91406, 94342, 80470, 80471, 80472, 80473, 80474, 80475, 81729, 81730, 84210, 84211, 84291, 84292, 85294, 85295, 85296, 85297, 85298, 85299, 90787, 90788
}

---@param device table
---@param options table?
function quickElevatorSetupUI.install(device, options)
    if not device then
        return
    end

    options = options or {}
    local liftControllerClass = tostring(options.liftControllerClass or "LiftControllerPS")
    local elevatorFloorControllerClass = tostring(options.elevatorFloorControllerClass or "ElevatorFloorTerminalControllerPS")
    local elevatorFloorTerminalComponentID = tostring(options.elevatorFloorTerminalComponentID or "1394923055520256000")
    local sanitizeConnectionValue = options.sanitizeConnectionValue or function(value)
        local sanitized = tostring(value or "")
        sanitized = sanitized:gsub("^%s+", ""):gsub("%s+$", "")
        sanitized = sanitized:gsub("[\128-\255]", "")
        return sanitized
    end
    local boolToInt = options.boolToInt or function(value, defaultValue)
        if value == nil then
            value = defaultValue
        end
        return (value == true or value == 1) and 1 or 0
    end

    ---@param buttonLabels string[]?
    ---@param minWidth number?
    ---@return number
    local function getRowFieldWidth(buttonLabels, minWidth)
        local labels = buttonLabels or {}
        local styleData = ImGui.GetStyle()
        local framePaddingX = styleData.FramePadding.x * 2
        local itemSpacingX = styleData.ItemSpacing.x
        local reservedWidth = 0

        for _, label in ipairs(labels) do
            reservedWidth = reservedWidth + ImGui.CalcTextSize(tostring(label or "")) + framePaddingX
        end

        if #labels > 0 then
            -- One SameLine gap before each button.
            reservedWidth = reservedWidth + itemSpacingX * #labels
        end

        local fieldWidth = (ImGui.GetWindowContentRegionWidth() - ImGui.GetCursorPosX() - reservedWidth) / style.viewSize
        return math.max(tonumber(minWidth) or 140, fieldWidth)
    end

    ---@param entry table?
    ---@param index number
    ---@return string
    local function getFloorPopupSectionStateKey(entry, index)
        if entry and entry.folderElement and entry.folderElement.id ~= nil then
            return "folder:" .. tostring(entry.folderElement.id)
        end

        local nodeRef = sanitizeConnectionValue(entry and (entry.nodeRef or entry.rawNodeRef or "") or "")
        if nodeRef ~= "" then
            return "nodeRef:" .. nodeRef
        end

        return "index:" .. tostring(index)
    end

    ---@param entry table
    ---@param index number
    ---@param count number
    ---@return boolean deleted
    function device:drawLiftFloorEntry(entry, index, count)
        ImGui.PushID("liftFloorEntry" .. index)
        
        local floorsLabelX = utils.getTextMaxWidth({
            "Terminal Node Ref",
            "Ground Marker Node Ref",
            "Localization",
            "Floor Name",
            "Open Lift Doors",
            "Doors"
        }) + 2 * ImGui.GetStyle().ItemSpacing.x

        local folderName = entry.folderElement and entry.folderElement.name or ("Floor_" .. tostring(index - 1))
        local floorHeaderLabel = folderName
        if entry.terminalSpawnable then
            local headerComponentID = self:getPersistentComponentID(
                entry.terminalSpawnable,
                elevatorFloorControllerClass,
                elevatorFloorTerminalComponentID
            )
            if headerComponentID then
                local headerFloorSetup = self:getComponentPathValue(
                    entry.terminalSpawnable,
                    headerComponentID,
                    { "persistentState", "Data", "elevatorFloorSetup" }
                )

                if type(headerFloorSetup) == "table" then
                    local headerFloorName = tostring(
                        headerFloorSetup.floorDisplayName
                        and headerFloorSetup.floorDisplayName["$value"]
                        or ""
                    )
                    headerFloorName = headerFloorName:gsub("^%s+", ""):gsub("%s+$", "")

                    if headerFloorName ~= "" and headerFloorName ~= "None" then
                        local localizedHeaderFloorName = tostring(self:resolveLocKey(headerFloorName) or headerFloorName)
                        localizedHeaderFloorName = localizedHeaderFloorName:gsub("^%s+", ""):gsub("%s+$", "")

                        if localizedHeaderFloorName ~= "" and localizedHeaderFloorName ~= "None" then
                            floorHeaderLabel = string.format("%s | %s", folderName, localizedHeaderFloorName)
                        end
                    end
                end
            end
        end
        local styleData = ImGui.GetStyle()
        local framePaddingX = styleData.FramePadding.x * 2
        local itemSpacingX = styleData.ItemSpacing.x
        local upButtonWidth = ImGui.CalcTextSize(IconGlyphs.ArrowUp) + framePaddingX
        local downButtonWidth = ImGui.CalcTextSize(IconGlyphs.ArrowDown) + framePaddingX
        local deleteButtonWidth = ImGui.CalcTextSize(IconGlyphs.DeleteOutline) + framePaddingX
        local buttonRowWidth = upButtonWidth + downButtonWidth + deleteButtonWidth + (itemSpacingX * 2)
        local rightAlignedButtonsX = ImGui.GetWindowContentRegionWidth() - buttonRowWidth

        self.quickLiftPopupFloorOpenState = self.quickLiftPopupFloorOpenState or {}
        local floorSectionStateKey = getFloorPopupSectionStateKey(entry, index)
        local initialFloorSectionOpen = self.quickLiftPopupFloorOpenState[floorSectionStateKey]
        if initialFloorSectionOpen == nil then
            initialFloorSectionOpen = true
            self.quickLiftPopupFloorOpenState[floorSectionStateKey] = initialFloorSectionOpen
        end
        ImGui.SetNextItemOpen(initialFloorSectionOpen, ImGuiCond.Once)

        local floorSectionFlags = ImGuiTreeNodeFlags.SpanFullWidth + ImGuiTreeNodeFlags.AllowItemOverlap
        local floorSectionOpen = ImGui.CollapsingHeader(floorHeaderLabel .. "##liftFloorSection", floorSectionFlags)
        self.quickLiftPopupFloorOpenState[floorSectionStateKey] = floorSectionOpen

        ImGui.SameLine()
        ImGui.SetCursorPosX(math.max(ImGui.GetCursorPosX(), rightAlignedButtonsX))
        style.pushGreyedOut(index <= 1)
        if ImGui.Button(IconGlyphs.ArrowUp .. "##liftFloorUp") and index > 1 then
            self:moveLiftFloor(self:getLiftFloorEntries(), index, -1)
        end
        style.popGreyedOut(index <= 1)
        style.tooltip("Move floor before previous floor connection.")

        ImGui.SameLine()
        style.pushGreyedOut(index >= count)
        if ImGui.Button(IconGlyphs.ArrowDown .. "##liftFloorDown") and index < count then
            self:moveLiftFloor(self:getLiftFloorEntries(), index, 1)
        end
        style.popGreyedOut(index >= count)
        style.tooltip("Move floor after next floor connection.")

        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline .. "##liftFloorDelete") then
            self:removeLiftFloor(entry)
            ImGui.PopID()
            return true
        end
        style.tooltip("Delete floor folder and remove its lift connection.")

        if not floorSectionOpen then
            ImGui.PopID()
            return false
        end

        local function applyTerminalNodeRef(newNodeRef)
            local normalizedNodeRef = sanitizeConnectionValue(newNodeRef)
            local currentNodeRef = sanitizeConnectionValue(entry.connection and entry.connection.nodeRef or entry.nodeRef or entry.rawNodeRef or "")
            if normalizedNodeRef == currentNodeRef then
                return
            end

            local changes = { history.getElementChange(self.object) }
            if entry.terminalElement then
                table.insert(changes, history.getElementChange(entry.terminalElement))
            end

            if #changes > 1 then
                history.addAction(history.getComposite(changes))
            else
                history.addAction(changes[1])
            end

            if entry.connection then
                entry.connection.nodeRef = normalizedNodeRef
            end
            if entry.terminalSpawnable then
                entry.terminalSpawnable.nodeRef = normalizedNodeRef
            end
            entry.nodeRef = normalizedNodeRef

            registry.invalidate()
            if self.object.sUI and self.object.sUI.cachePaths then
                self.object.sUI.cachePaths()
            end
        end

        style.mutedText("Terminal Node Ref")
        ImGui.SameLine()
        ImGui.SetCursorPosX(floorsLabelX)
        local terminalNodeRefFieldWidth = getRowFieldWidth({ IconGlyphs.ReloadAlert })
        local displayedNodeRef = sanitizeConnectionValue(entry.connection and entry.connection.nodeRef or entry.nodeRef or entry.rawNodeRef or "")
        local nodeRefOwner = entry.terminalElement or self.object
        local editedNodeRef, nodeRefChanged, nodeRefFinished = style.trackedTextField(
            nodeRefOwner,
            "##liftFloorNodeRef",
            displayedNodeRef,
            "NodeRef...",
            terminalNodeRefFieldWidth
        )
        if nodeRefChanged and nodeRefFinished then
            applyTerminalNodeRef(editedNodeRef)
        end
        if entry.rawNodeRef and entry.nodeRef and entry.rawNodeRef ~= entry.nodeRef then
            style.tooltip("Connection stored as hash/alias, resolved to: " .. tostring(entry.nodeRef))
        else
            style.tooltip("NodeRef used by this floor terminal and its lift connection.")
        end

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        local canGenerateTerminalNodeRef = entry.terminalElement ~= nil
        ImGui.BeginDisabled(not canGenerateTerminalNodeRef)
        if ImGui.Button(IconGlyphs.ReloadAlert .. "##liftFloorNodeRefGenerate") and canGenerateTerminalNodeRef then
            applyTerminalNodeRef(registry.generate(entry.terminalElement))
        end
        ImGui.EndDisabled()
        style.pushButtonNoBG(false)
        if canGenerateTerminalNodeRef then
            style.tooltip("Generate a unique NodeRef for this floor terminal and update the lift connection.")
        else
            style.tooltip("Terminal node not found in hierarchy.")
        end

        if not entry.terminalSpawnable or not entry.terminalElement then
            ImGui.TextWrapped("Terminal node not found in hierarchy.")
            ImGui.PopID()
            return false
        end

        local componentID = self:getPersistentComponentID(
            entry.terminalSpawnable,
            elevatorFloorControllerClass,
            elevatorFloorTerminalComponentID
        )

        if not componentID then
            ImGui.TextWrapped("Terminal persistent state is not available yet. Try again once the terminal is assembled.")
            ImGui.PopID()
            return false
        end

        local floorSetup = self:getComponentPathValue(
            entry.terminalSpawnable,
            componentID,
            { "persistentState", "Data", "elevatorFloorSetup" }
        )
        floorSetup = self:normalizeElevatorFloorSetup(floorSetup)

        local function applyMarkerNodeRef(newNodeRef)
            if not entry.markerElement or not entry.markerElement.spawnable then
                return
            end

            local normalizedMarkerNodeRef = sanitizeConnectionValue(newNodeRef)
            local currentMarkerNodeRef = sanitizeConnectionValue(entry.markerElement.spawnable.nodeRef)
            if normalizedMarkerNodeRef == currentMarkerNodeRef then
                return
            end

            local changes = { history.getElementChange(entry.markerElement) }
            if entry.terminalElement then
                table.insert(changes, history.getElementChange(entry.terminalElement))
            end

            if #changes > 1 then
                history.addAction(history.getComposite(changes))
            else
                history.addAction(changes[1])
            end

            entry.markerElement.spawnable.nodeRef = normalizedMarkerNodeRef
            floorSetup = self:updateElevatorFloorSetup(entry, componentID, floorSetup)

            registry.invalidate()
            if self.object.sUI and self.object.sUI.cachePaths then
                self.object.sUI.cachePaths()
            end
        end

        style.mutedText("Ground Marker Node Ref")
        ImGui.SameLine()
        ImGui.SetCursorPosX(floorsLabelX)
        local canEditMarkerNodeRef = entry.markerElement ~= nil and entry.markerElement.spawnable ~= nil
        local markerNodeRefOwner = entry.markerElement or entry.terminalElement or self.object
        local markerNodeRefValue = sanitizeConnectionValue(canEditMarkerNodeRef and entry.markerElement.spawnable.nodeRef or "")
        local markerNodeRefFieldWidth = getRowFieldWidth({ IconGlyphs.ReloadAlert })
        ImGui.BeginDisabled(not canEditMarkerNodeRef)
        local editedMarkerNodeRef, markerNodeRefChanged, markerNodeRefFinished = style.trackedTextField(
            markerNodeRefOwner,
            "##liftFloorMarkerNodeRef",
            markerNodeRefValue,
            "NodeRef...",
            markerNodeRefFieldWidth
        )
        ImGui.EndDisabled()
        style.tooltip("NodeRef used by this ground marker and this floor terminal connection.")
        if markerNodeRefChanged and markerNodeRefFinished then
            applyMarkerNodeRef(editedMarkerNodeRef)
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        ImGui.BeginDisabled(not canEditMarkerNodeRef)
        if ImGui.Button(IconGlyphs.ReloadAlert .. "##liftFloorMarkerNodeRefGenerate") and canEditMarkerNodeRef then
            applyMarkerNodeRef(registry.generate(entry.markerElement))
        end
        ImGui.EndDisabled()
        style.pushButtonNoBG(false)
        if canEditMarkerNodeRef then
            style.tooltip("Generate a unique NodeRef for this floor marker and update terminal floorMarker.")
        else
            style.tooltip("Floor marker node not found in hierarchy.")
        end
        
        ImGui.Dummy(0, 4 * style.viewSize)

        style.drawIconLabelRow(IconGlyphs.Translate, "Floor Name")
        ImGui.SameLine()
        ImGui.SetCursorPosX(floorsLabelX)
        local floorNameValue = tostring(
            floorSetup.floorDisplayName
            and floorSetup.floorDisplayName["$value"]
            or floorSetup.floorName
            or ""
        )
        local floorName, floorNameChanged, floorNameFinished = style.trackedTextField(
            entry.terminalElement,
            "##liftFloorName",
            floorNameValue,
            "Floor name / LocKey...",
            180
        )
        style.tooltip("Displayed floor name on the terminals, can be a localization key (LocKey#) or plain text.")
        if floorNameChanged and floorNameFinished then
            floorSetup.floorDisplayName = floorSetup.floorDisplayName or {
                ["$type"] = "CName",
                ["$storage"] = "string",
                ["$value"] = "None"
            }
            floorSetup.floorDisplayName["$type"] = "CName"
            floorSetup.floorDisplayName["$storage"] = "string"
            floorSetup.floorDisplayName["$value"] = floorName
            floorSetup = self:updateElevatorFloorSetup(entry, componentID, floorSetup)
        end

        ImGui.SameLine()
        ImGui.SetNextItemWidth(180 * style.viewSize)
        if ImGui.BeginCombo("##liftFloorLocalizationSuggestions", "Localization suggestions") then
            local localizationSuggestions = {}
            for _, locKeyNumber in ipairs(FLOOR_LOCALIZATION_SUGGESTIONS) do
                local locKeyValue = "LocKey#" .. tostring(locKeyNumber)
                local localizedText = tostring(self:resolveLocKey(locKeyValue) or locKeyValue)
                table.insert(localizationSuggestions, {
                    locKeyNumber = locKeyNumber,
                    locKeyValue = locKeyValue,
                    localizedText = localizedText
                })
            end

            table.sort(localizationSuggestions, function(a, b)
                local textA = string.lower(a.localizedText)
                local textB = string.lower(b.localizedText)
                if textA ~= textB then
                    return textA < textB
                end

                local numberA = tonumber(a.locKeyNumber)
                local numberB = tonumber(b.locKeyNumber)
                if numberA and numberB then
                    return numberA < numberB
                end

                return tostring(a.locKeyNumber) < tostring(b.locKeyNumber)
            end)

            for suggestionIndex, suggestion in ipairs(localizationSuggestions) do
                local optionLabel = suggestion.localizedText .. "##liftFloorLocSuggestion" .. tostring(suggestion.locKeyNumber) .. "_" .. tostring(suggestionIndex)

                if ImGui.Selectable(optionLabel, false) then
                    history.addAction(history.getElementChange(entry.terminalElement or self.object))
                    floorSetup.floorDisplayName = floorSetup.floorDisplayName or {
                        ["$type"] = "CName",
                        ["$storage"] = "string",
                        ["$value"] = "None"
                    }
                    floorSetup.floorDisplayName["$type"] = "CName"
                    floorSetup.floorDisplayName["$storage"] = "string"
                    floorSetup.floorDisplayName["$value"] = suggestion.locKeyValue
                    floorSetup = self:updateElevatorFloorSetup(entry, componentID, floorSetup)
                end
            end
            ImGui.EndCombo()
        end
        style.tooltip("Suggestions only. Selecting one writes LocKey#<id> into Floor Name.")

        self:drawLocalizationStringPreview(floorName, floorsLabelX)

        ImGui.BeginGroup()
        style.drawIconLabelRow(IconGlyphs.EyeOffOutline, "Hidden")
        ImGui.SameLine()
        ImGui.SetCursorPosX(floorsLabelX)
        local isHidden = boolToInt(floorSetup.isHidden, 0) == 1
        local newHidden, hiddenChanged = style.trackedCheckbox(entry.terminalElement, "##liftFloorHidden", isHidden)

        ImGui.EndGroup()
        style.tooltip("Hide this floor from terminal listings.")
        if hiddenChanged then
            history.addAction(history.getElementChange(entry.terminalElement or self.object))
            floorSetup.isHidden = newHidden and 1 or 0
            floorSetup = self:updateElevatorFloorSetup(entry, componentID, floorSetup)
        end

        ImGui.BeginGroup()
        style.drawIconLabelRow(IconGlyphs.Cancel, "Inactive")
        ImGui.SameLine()
        ImGui.SetCursorPosX(floorsLabelX)
        local isInactive = boolToInt(floorSetup.isInactive, 0) == 1
        local newInactive, inactiveChanged = style.trackedCheckbox(entry.terminalElement, "##liftFloorInactive", isInactive)
        ImGui.EndGroup()
        style.tooltip("Disable this floor so it cannot be selected.")
        if inactiveChanged then
            history.addAction(history.getElementChange(entry.terminalElement or self.object))
            floorSetup.isInactive = newInactive and 1 or 0
            floorSetup = self:updateElevatorFloorSetup(entry, componentID, floorSetup)
        end

        style.drawIconLabelRow(IconGlyphs.DoorSlidingOpen, "Open Lift Doors")
        ImGui.SameLine()
        ImGui.SetCursorPosX(floorsLabelX)
        for doorIndex, doorLabel in ipairs(LIFT_FLOOR_DOOR_LABELS) do
            if doorIndex > 1 then
                ImGui.SameLine()
                ImGui.SetCursorPosX(ImGui.GetCursorPosX() + ImGui.GetStyle().ItemSpacing.x * 2)
            end
            local enabled = boolToInt(floorSetup.doorShouldOpenFrontLeftRight and floorSetup.doorShouldOpenFrontLeftRight[doorIndex], 1) == 1
            local newEnabled, doorChanged = style.trackedCheckbox(entry.terminalElement, doorLabel .. "##door" .. doorIndex, enabled)
            if doorChanged then
                floorSetup.doorShouldOpenFrontLeftRight[doorIndex] = newEnabled and 1 or 0
                floorSetup = self:updateElevatorFloorSetup(entry, componentID, floorSetup)
            end
        end

        ImGui.Spacing()
        ImGui.Separator()
        ImGui.Spacing()

        style.drawIconLabelRow(IconGlyphs.DoorSliding, "External Doors")
        ImGui.SameLine()
        local addDoorPopupId = "##liftFloorAddDoorPopup" .. tostring(index)
        local canManageFloorDoors = self.getLiftFloorDoorDefinitions ~= nil
            and self.getLiftFloorDoorEntries ~= nil
            and self.addLiftFloorDoor ~= nil
            and self.updateLiftFloorDoorNodeRef ~= nil
            and self.removeLiftFloorDoor ~= nil
        ImGui.BeginDisabled(not canManageFloorDoors)
        if ImGui.Button(IconGlyphs.Plus .. " Add door##liftFloorAddDoorButton") and canManageFloorDoors then
            ImGui.OpenPopup(addDoorPopupId)
        end
        ImGui.EndDisabled()
        style.tooltip("Add a door to this floor group and connect it to the floor terminal.")

        if canManageFloorDoors and ImGui.BeginPopup(addDoorPopupId) then
            local doorDefinitions = self:getLiftFloorDoorDefinitions()
            for _, definition in ipairs(doorDefinitions) do
                if ImGui.Selectable(tostring(definition.label), false) then
                    self:addLiftFloorDoor(entry, definition.key)
                    ImGui.CloseCurrentPopup()
                end
            end
            ImGui.EndPopup()
        end

        local floorDoorEntries = canManageFloorDoors and self:getLiftFloorDoorEntries(entry) or {}
        if #floorDoorEntries == 0 then
            style.mutedText("No connected doors for this floor.")
        else
            for doorRowIndex, doorEntry in ipairs(floorDoorEntries) do
                ImGui.PushID("liftFloorDoorRow" .. tostring(doorRowIndex))

                ImGui.SetCursorPosX(40 * style.viewSize)
                style.mutedText(tostring(doorEntry.doorLabel or "Door"))
                ImGui.SameLine()
                ImGui.SetCursorPosX(floorsLabelX + 20 * style.viewSize)

                local doorNodeRefOwner = doorEntry.doorElement or entry.terminalElement or self.object
                local doorNodeRefValue = sanitizeConnectionValue(
                    doorEntry.connection and doorEntry.connection.nodeRef
                    or doorEntry.nodeRef
                    or doorEntry.rawNodeRef
                    or ""
                )
                local editedDoorNodeRef, doorNodeRefChanged, doorNodeRefFinished = style.trackedTextField(
                    doorNodeRefOwner,
                    "##liftFloorDoorNodeRef",
                    doorNodeRefValue,
                    "Door NodeRef...",
                    getRowFieldWidth({ IconGlyphs.ReloadAlert, IconGlyphs.DeleteOutline })
                )
                if doorNodeRefChanged and doorNodeRefFinished then
                    self:updateLiftFloorDoorNodeRef(entry, doorEntry, editedDoorNodeRef)
                end
                style.tooltip("NodeRef used by the door and this floor terminal connection.")

                ImGui.SameLine()
                style.pushButtonNoBG(true)
                local canGenerateDoorNodeRef = doorEntry.doorElement ~= nil and self.generateLiftFloorDoorNodeRef ~= nil
                ImGui.BeginDisabled(not canGenerateDoorNodeRef)
                if ImGui.Button(IconGlyphs.ReloadAlert .. "##liftFloorDoorNodeRefGenerate") and canGenerateDoorNodeRef then
                    self:generateLiftFloorDoorNodeRef(entry, doorEntry)
                end
                ImGui.EndDisabled()
                style.pushButtonNoBG(false)
                if canGenerateDoorNodeRef then
                    style.tooltip("Generate a unique NodeRef for this door and update the floor terminal connection.")
                else
                    style.tooltip("Door node not found in hierarchy.")
                end

                ImGui.SameLine()
                local deletedDoor = false
                if style.dangerButton(IconGlyphs.DeleteOutline .. "##liftFloorDoorDelete") then
                    self:removeLiftFloorDoor(entry, doorEntry)
                    deletedDoor = true
                end
                style.tooltip("Delete this door and remove its terminal connection.")

                ImGui.PopID()

                if deletedDoor then
                    break
                end
            end
        end

        ImGui.PopID()
        return false
    end

    ---@param childHeight number?
    function device:drawLiftFloorManager(childHeight)
        local managerHeight = math.max(0, tonumber(childHeight) or (280 * style.viewSize))

        if ImGui.BeginChild("##liftFloorManagerChild", 0, managerHeight, true) then
            local entries = self:getLiftFloorEntries()
            if #entries == 0 then
                ImGui.TextWrapped("No floor terminals are connected to this lift yet.")
            else
                for index, entry in ipairs(entries) do
                    local deleted = self:drawLiftFloorEntry(entry, index, #entries)
                    if deleted then
                        break
                    end
                end
            end

            ImGui.Dummy(0, 8 * style.viewSize)
            ImGui.EndChild()
        end
    end

    function device:drawLiftSetupPopup()
        local defaultWidth = 580 * style.viewSize
        local defaultHeight = 520 * style.viewSize
        local minWidth = 540 * style.viewSize
        local minHeight = 480 * style.viewSize
        local screenWidth, screenHeight = GetDisplayResolution()
        local maxWidth = math.max(minWidth, screenWidth - 40 * style.viewSize)
        local maxHeight = math.max(minHeight, screenHeight - 40 * style.viewSize)

        ImGui.SetNextWindowSize(defaultWidth, defaultHeight, ImGuiCond.FirstUseEver)
        ImGui.SetNextWindowSizeConstraints(minWidth, minHeight, maxWidth, maxHeight)

        local popupIsOpen = ImGui.BeginPopupModal(quickElevatorSetupUI.POPUP_ID, true)
        if not popupIsOpen then
            self.quickLiftSetupPopupWasOpen = false
            return
        end

        local settingsLabelX = utils.getTextMaxWidth({
            "Elevator Node Ref",
            "Starting Floor",
            IconGlyphs.ChevronDoubleRight .. " Lift Speed",
            IconGlyphs.ChevronTripleRight .. " Empty Lift Speed Mult."
        }) + 4 * ImGui.GetStyle().ItemSpacing.x

        local function applyElevatorNodeRef(newNodeRef)
            local normalizedNodeRef = sanitizeConnectionValue(newNodeRef)
            local currentNodeRef = sanitizeConnectionValue(self.nodeRef)
            if normalizedNodeRef == currentNodeRef then
                return
            end

            history.addAction(history.getElementChange(self.object))
            self.nodeRef = normalizedNodeRef

            registry.invalidate()
            if self.object.sUI and self.object.sUI.cachePaths then
                self.object.sUI.cachePaths()
            end
        end

        local canGenerateElevatorNodeRef = self.object ~= nil and self.object.parent ~= nil
        local popupJustOpened = not self.quickLiftSetupPopupWasOpen
        self.quickLiftSetupPopupWasOpen = true
        if popupJustOpened and canGenerateElevatorNodeRef and sanitizeConnectionValue(self.nodeRef) == "" then
            local generatedNodeRef = sanitizeConnectionValue(registry.generate(self.object))
            if generatedNodeRef ~= "" then
                applyElevatorNodeRef(generatedNodeRef)
            end
        end

        style.mutedText("Elevator Node Ref")
        ImGui.SameLine()
        ImGui.SetCursorPosX(settingsLabelX)
        local elevatorNodeRefFieldWidth = getRowFieldWidth({ IconGlyphs.ReloadAlert })
        local editedElevatorNodeRef, elevatorNodeRefChanged, elevatorNodeRefFinished = style.trackedTextField(
            self.object,
            "##liftSetupElevatorNodeRef",
            sanitizeConnectionValue(self.nodeRef),
            "NodeRef...",
            elevatorNodeRefFieldWidth
        )
        if elevatorNodeRefChanged and elevatorNodeRefFinished then
            applyElevatorNodeRef(editedElevatorNodeRef)
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        ImGui.BeginDisabled(not canGenerateElevatorNodeRef)
        if ImGui.Button(IconGlyphs.ReloadAlert .. "##liftSetupElevatorNodeRefGenerate") and canGenerateElevatorNodeRef then
            applyElevatorNodeRef(registry.generate(self.object))
        end
        ImGui.EndDisabled()
        style.pushButtonNoBG(false)
        style.tooltip("Generate a unique NodeRef for this elevator.")

        ImGui.Dummy(0, 4 * style.viewSize)

        local liftComponentID = self:getPersistentComponentID(self, liftControllerClass, self.psControllerID)
        local liftSetupPath = { "persistentState", "Data", "liftSetup" }
        local liftSetup = liftComponentID and self:getComponentPathValue(self, liftComponentID, liftSetupPath) or nil

        if liftComponentID and type(liftSetup) == "table" then
            style.mutedText("Starting Floor")
            ImGui.SameLine()
            ImGui.SetCursorPosX(settingsLabelX)
            local startingFloor = math.max(0, math.floor(tonumber(liftSetup.startingFloorTerminal) or 0))
            local newStartingFloor, startingChanged = style.trackedIntInput(
                self.object,
                "##liftSetupStartingFloorTerminal",
                startingFloor,
                0,
                999,
                100,
                1,
                10
            )
            if startingChanged then
                local updated = utils.deepcopy(liftSetup)
                updated.startingFloorTerminal = math.max(0, math.floor(tonumber(newStartingFloor) or 0))
                self:updateComponentPathValue(self, liftComponentID, liftSetupPath, updated)
                liftSetup = updated
            end

            style.drawIconLabelRow(IconGlyphs.ChevronDoubleRight, "Lift Speed")
            ImGui.SameLine()
            ImGui.SetCursorPosX(settingsLabelX)
            local liftSpeed = math.max(0, tonumber(liftSetup.liftSpeed) or 0)
            local newLiftSpeed, liftSpeedChanged = style.trackedDragFloat(
                self.object,
                "##liftSetupLiftSpeed",
                liftSpeed,
                0.05,
                0,
                500,
                "%.2f",
                100
            )
            if liftSpeedChanged then
                local updated = utils.deepcopy(liftSetup)
                updated.liftSpeed = math.max(0, tonumber(newLiftSpeed) or 0)
                self:updateComponentPathValue(self, liftComponentID, liftSetupPath, updated)
                liftSetup = updated
            end

            style.drawIconLabelRow(IconGlyphs.ChevronTripleRight, "Empty Lift Speed Mult.")
            ImGui.SameLine()
            ImGui.SetCursorPosX(settingsLabelX)
            local emptyMultiplier = math.max(0, tonumber(liftSetup.emptyLiftSpeedMultiplier) or 0)
            local newEmptyMultiplier, emptyMultiplierChanged = style.trackedDragFloat(
                self.object,
                "##liftSetupEmptyLiftSpeedMultiplier",
                emptyMultiplier,
                0.05,
                0,
                500,
                "x%.2f",
                100
            )
            if emptyMultiplierChanged then
                local updated = utils.deepcopy(liftSetup)
                updated.emptyLiftSpeedMultiplier = math.max(0, tonumber(newEmptyMultiplier) or 0)
                self:updateComponentPathValue(self, liftComponentID, liftSetupPath, updated)
            end
        else
            ImGui.TextWrapped("Lift persistent state is not available yet. Ensure the elevator is spawned and assembled.")
        end

        ImGui.Dummy(0, 8 * style.viewSize)
        style.drawIconLabelRow(IconGlyphs.FloorPlan, "Floor Manager")
        ImGui.SameLine()
        if ImGui.Button(IconGlyphs.Plus .. " Add Floor##liftFloorManagerAdd") then
            self:addLiftFloor()
        end
        style.tooltip("Create a floor folder with a terminal and marker, then connect it to this lift.")

        local _, popupContentAvailY = ImGui.GetContentRegionAvail()
        local footerReserveHeight = ImGui.GetFrameHeightWithSpacing() + 14 * style.viewSize
        local floorManagerHeight = math.max(0, popupContentAvailY - footerReserveHeight)
        self:drawLiftFloorManager(floorManagerHeight)

        ImGui.Separator()
        if ImGui.Button("Close##liftSetupPopupClose") then
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end
end

return quickElevatorSetupUI
