local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
local registry = require("modules/utils/nodeRefRegistry")
local cache = require("modules/utils/cache")
local builder = require("modules/utils/entityBuilder")
local Cron = require("modules/utils/Cron")

local characterRecords = nil
local pendingAppearanceLoads = {}
--local HIERARCHY_ROW_BG_PERIOD = 0x991C2B3A
--local HIERARCHY_ROW_BG_PHASE = 0x991F3424
--local HIERARCHY_ROW_BG_ENTRY = 0x993B341E
local HIERARCHY_ROW_BG_PERIOD = 0x07FFFFFF
local HIERARCHY_ROW_BG_PHASE = 0x10FFFFFF
local HIERARCHY_ROW_BG_ENTRY = 0x1eFFFFFF
local HIERARCHY_ROW_TOP_PADDING = 2
local HIERARCHY_COLOR_PERIOD = 0xFF377fcd
local HIERARCHY_COLOR_PHASE = 0xFF48c731
local HIERARCHY_COLOR_ENTRY = 0xFFb7692d

---@type fun(value: any, fallback: any?): string
local sanitizeValue = utils.sanitizeText

local function ensureCharacterRecordsLoaded()
    if characterRecords ~= nil then
        return
    end

    characterRecords = {}
    local path = "data/spawnables/entity/records/records.txt"
    local file = io.open(path, "r")
    if not file then
        return
    end

    for line in file:lines() do
        local record = sanitizeValue(line)
        if record:match("^Character%.") then
            table.insert(characterRecords, record)
        end
    end

    file:close()
    table.sort(characterRecords)
end

local function copyList(values)
    local list = {}
    for _, value in ipairs(values or {}) do
        table.insert(list, value)
    end

    return list
end

local function buildSelectorOptions(baseOptions, currentValue)
    local options = copyList(baseOptions)
    local current = sanitizeValue(currentValue)

    if current ~= "" and utils.indexValue(options, current) == -1 then
        table.insert(options, 1, current)
    end

    return options
end

local function normalizeAppearanceOptions(appearances)
    local options = {}
    local dedupe = {}

    for _, appearance in ipairs(appearances or {}) do
        local name = sanitizeValue(appearance)
        if name ~= "" and not dedupe[name] then
            dedupe[name] = true
            table.insert(options, name)
        end
    end

    table.sort(options)
    if #options == 0 then
        table.insert(options, "default")
    end

    return options
end

local function getPreferredAppearanceOption(options)
    for _, option in ipairs(options or {}) do
        local cleanOption = sanitizeValue(option)
        if cleanOption ~= "" and string.find(string.lower(cleanOption), "default", 1, true) then
            return cleanOption
        end
    end

    local firstOption = sanitizeValue(options and options[1] or "")
    if firstOption ~= "" then
        return firstOption
    end

    return "default"
end

local function resolvePreferredOption(selected, options, fallback)
    local cleanFallback = sanitizeValue(fallback ~= nil and fallback or "default")
    if cleanFallback == "" then
        cleanFallback = "default"
    end

    local cleanSelected = sanitizeValue(selected)
    if cleanSelected ~= "" then
        return cleanSelected
    end

    if #options == 0 then
        return cleanFallback
    end

    if utils.indexValue(options, cleanFallback) ~= -1 then
        return cleanFallback
    end

    return sanitizeValue(options[1] or "default")
end

local function collectPhaseNames(phases)
    local names = {}
    local dedupe = {}
    local firstName = nil

    for _, phase in ipairs(phases or {}) do
        local name = sanitizeValue(phase and phase.phaseName or "")
        if name ~= "" then
            if firstName == nil then
                firstName = name
            end

            if not dedupe[name] then
                dedupe[name] = true
                table.insert(names, name)
            end
        end
    end

    return names, firstName
end

local function buildInitialPhaseOptions(phases)
    local phaseNames, firstName = collectPhaseNames(phases)
    local options = {}
    local fallback = "default"

    if #phaseNames == 0 then
        table.insert(options, "default")
    else
        for _, name in ipairs(phaseNames) do
            table.insert(options, name)
        end
        fallback = firstName or "default"
    end

    return options, fallback, phaseNames
end

local function getRecordDisplayName(recordID)
    local cleanRecord = sanitizeValue(recordID)
    if cleanRecord == "" then
        return "None"
    end

    local shortName = cleanRecord:match("([^%.]+)$")
    return shortName ~= nil and shortName ~= "" and shortName or cleanRecord
end

local function requestCharacterAppearances(recordID)
    local record = sanitizeValue(recordID)
    if record == "" or not record:match("^Character%.") then
        return { "default" }, true
    end

    local cacheKey = record .. "_apps"
    local cached = cache.getValue(cacheKey)
    if type(cached) == "table" then
        return normalizeAppearanceOptions(cached), true
    end

    if pendingAppearanceLoads[cacheKey] ~= true then
        pendingAppearanceLoads[cacheKey] = true

        local finished = false
        local function complete(apps)
            if finished then
                return
            end

            finished = true
            pendingAppearanceLoads[cacheKey] = nil
            cache.addValue(cacheKey, apps or {})
        end

        local templateFlat = TweakDB:GetFlat(record .. ".entityTemplatePath")
        local templateHash = templateFlat and templateFlat.hash
        if not templateHash then
            complete({})
            return { "default" }, false
        end

        local templateResRef = ResRef.FromHash(templateHash)
        local depot = Game.GetResourceDepot()
        local exists = false
        if depot then
            pcall(function()
                exists = depot:ResourceExists(templateResRef)
            end)
        end
        if not exists then
            complete({})
            return { "default" }, false
        end

        Cron.After(2.5, function()
            complete({})
        end)

        local ok = pcall(function()
            builder.registerLoadResource(templateResRef, function(resource)
                local apps = {}
                if resource and resource.appearances then
                    for _, appearance in ipairs(resource.appearances) do
                        if appearance and appearance.name and appearance.name.value then
                            table.insert(apps, appearance.name.value)
                        end
                    end
                end

                complete(apps)
            end)
        end)
        if not ok then
            complete({})
        end
    end

    return { "default" }, false
end

---Class for worldCompiledCommunityAreaNode_Streamable
---@class community : visualized
---@field entries table
---@field periodEnums table
---@field periodLinkMode table<string, string>
---@field hierarchyOpen table<string, boolean>
---@field hierarchyBaseCursorX number?
---@field entryInitialPhaseSearch table<string, string>
---@field entryInitialPhaseTouched table<string, boolean>
local community = setmetatable({}, { __index = visualized })

function community:new()
	local o = visualized.new(self)

    o.spawnListType = "files"
    o.dataType = "Community"
    o.spawnDataPath = "data/spawnables/ai/community/"
    o.modulePath = "ai/communityArea"
    o.node = "worldCompiledCommunityAreaNode_Streamable"
    o.description = "A collection of NPCs, with their phases, time periods and assigned spots."
    o.icon = IconGlyphs.AccountGroup

    o.previewed = true
    o.previewColor = "palegreen"

    o.primaryRange = 250
    o.streamingMultiplier = 5

    o.entries = {}
    o.entryRecordSearch = {}
    o.phaseAppearanceSearch = {}
    o.periodLinkMode = {}
    o.hierarchyOpen = {}
    o.hierarchyBaseCursorX = nil
    o.entryInitialPhaseSearch = {}
    o.entryInitialPhaseTouched = {}
    o.periodEnums = {
        "Morning",
        "Day",
        "Evening",
        "Night",
        "Midnight",
        "1:00 AM",
        "2:00 AM",
        "3:00 AM",
        "4:00 AM",
        "5:00 AM",
        "6:00 AM",
        "7:00 AM",
        "8:00 AM",
        "9:00 AM",
        "10:00 AM",
        "11:00 AM",
        "Noon",
        "1:00 PM",
        "2:00 PM",
        "3:00 PM",
        "4:00 PM",
        "5:00 PM",
        "6:00 PM",
        "7:00 PM",
        "8:00 PM",
        "9:00 PM",
        "10:00 PM",
        "11:00 PM"
    }

    setmetatable(o, { __index = self })
   	return o
end

function community:save()
    local data = visualized.save(self)

    data.entries = utils.deepcopy(self.entries)

    return data
end

local function drawBoldMutedText(text)
    local label = tostring(text or "")
    local screenX, screenY = ImGui.GetCursorScreenPos()
    local drawList = ImGui.GetWindowDrawList()
    local fontSize = ImGui.GetFontSize()
    local offset = 0.2 * (style.viewSize or 1)

    ImGui.Text(label)

    if drawList then
        ImGui.ImDrawListAddText(drawList, fontSize, screenX + offset, screenY, style.regularColor, label)
        ImGui.ImDrawListAddText(drawList, fontSize, screenX, screenY + offset, style.regularColor, label)
    end

    ImGui.PopStyleColor()
end

local function drawSectionHeader(title, count)
    drawBoldMutedText(string.format("%s (%d)", title, count))
end

local function drawIconActionButton(icon, id, tooltipText)
    style.pushButtonNoBG(true)
    local clicked = ImGui.Button(icon .. "##" .. id)
    style.pushButtonNoBG(false)
    if tooltipText and tooltipText ~= "" then
        style.tooltip(tooltipText)
    end

    return clicked
end

local function getHierarchyTypeColor(level)
    if level == "entry" then
        return HIERARCHY_COLOR_ENTRY
    elseif level == "phase" then
        return HIERARCHY_COLOR_PHASE
    end

    return HIERARCHY_COLOR_PERIOD
end

local function drawHierarchyDisclosureButton(id, isOpen, level)
    style.pushButtonNoBG(true)
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
    ImGui.PushStyleColor(ImGuiCol.Text, getHierarchyTypeColor(level))
    local clicked = ImGui.Button((isOpen and IconGlyphs.MenuDownOutline or IconGlyphs.MenuRightOutline) .. "##" .. id)
    ImGui.PopStyleColor()
    ImGui.PopStyleVar()
    style.pushButtonNoBG(false)
    return clicked
end

local function hierarchyIndent()
    return 17 * style.viewSize
end

local function drawDuplicateDeleteButtons(duplicateId, deleteId)
    local duplicateClicked = false
    local deleteClicked = false

    ImGui.SameLine()
    local currentX = ImGui.GetCursorPosX()
    local availableWidth = tonumber((ImGui.GetContentRegionAvail())) or 0
    local duplicateTextWidth, _ = ImGui.CalcTextSize(IconGlyphs.ContentDuplicate)
    local deleteTextWidth, _ = ImGui.CalcTextSize(IconGlyphs.DeleteOutline)
    local framePaddingX = ImGui.GetStyle().FramePadding.x
    local buttonsWidth = duplicateTextWidth + deleteTextWidth + 4 * framePaddingX + ImGui.GetStyle().ItemSpacing.x
    local rightAlignedX = currentX + math.max(0, availableWidth - buttonsWidth)
    if rightAlignedX > currentX then
        ImGui.SetCursorPosX(rightAlignedX)
    end

    duplicateClicked = drawIconActionButton(IconGlyphs.ContentDuplicate, duplicateId, "Duplicate")
    ImGui.SameLine()
    deleteClicked = style.dangerButton(IconGlyphs.DeleteOutline .. "##" .. deleteId)
    style.tooltip("Delete")

    return duplicateClicked, deleteClicked
end

function community:drawContext(key, tbl)
    if ImGui.BeginPopupContextItem("##remove" .. key, ImGuiPopupFlags.MouseButtonRight) then
        if ImGui.MenuItem(IconGlyphs.DeleteOutline .. " Delete") then
            history.addAction(history.getElementChange(self.object))
            table.remove(tbl, key)
        end
        if ImGui.MenuItem(IconGlyphs.ContentDuplicate .. " Duplicate") then
            history.addAction(history.getElementChange(self.object))
            table.insert(tbl, utils.deepcopy(tbl[key]))
        end
        ImGui.EndPopup()
    end
end

function community:getHierarchyState(key, defaultOpen)
    local state = self.hierarchyOpen[key]
    if state == nil then
        state = defaultOpen ~= false
        self.hierarchyOpen[key] = state
    end

    return state
end

---@param isOpen boolean
function community:setHierarchyStateForAll(isOpen)
    for _, entry in ipairs(self.entries or {}) do
        local entryHierarchyKey = "entry:" .. tostring(entry)
        self.hierarchyOpen[entryHierarchyKey] = isOpen

        for _, phase in ipairs(entry.phases or {}) do
            local phaseHierarchyKey = entryHierarchyKey .. "/phase:" .. tostring(phase)
            self.hierarchyOpen[phaseHierarchyKey] = isOpen

            for _, period in ipairs(phase.timePeriods or {}) do
                local periodHierarchyKey = phaseHierarchyKey .. "/period:" .. tostring(period)
                self.hierarchyOpen[periodHierarchyKey] = isOpen
            end
        end
    end
end

---@param level string?
function community:drawHierarchyRowBackground(level)
    local topPadding = HIERARCHY_ROW_TOP_PADDING * style.viewSize
    local cursorX = ImGui.GetCursorPosX()
    local baseX = self.hierarchyBaseCursorX or cursorX
    local rowX, rowY = ImGui.GetCursorScreenPos()
    local xOffset = math.max(0, cursorX - baseX)
    local rowWidth = tonumber((ImGui.GetContentRegionAvail())) or 0
    rowWidth = rowWidth + xOffset
    if rowWidth <= 0 then
        return
    end

    local drawList = ImGui.GetWindowDrawList()
    local color
    if level == "entry" then
        color = HIERARCHY_ROW_BG_ENTRY
    elseif level == "phase" then
        color = HIERARCHY_ROW_BG_PHASE
    else
        color = HIERARCHY_ROW_BG_PERIOD
    end

    local rowHeight = topPadding + ImGui.GetFrameHeight() + 2 * style.viewSize
    ImGui.ImDrawListAddRectFilled(drawList, rowX, rowY, rowX - xOffset + rowWidth, rowY + rowHeight, color, 4 * style.viewSize)

    if topPadding > 0 then
        ImGui.SetCursorPosY(ImGui.GetCursorPosY() + topPadding)
    end
end

function community:drawPhaseAppearances(entryKey, phaseKey, entry, phase)
    phase.appearances = phase.appearances or {}

    local baseAppearanceOptions, loaded = requestCharacterAppearances(entry.characterRecordId)
    local appearancesHeader = style.resolveActionLabelNoIconOnly(IconGlyphs.Hanger, "Appearances", nil)
    drawSectionHeader(appearancesHeader, #phase.appearances)
    ImGui.SameLine()
    if ImGui.Button("+##addAppearance") then
        history.addAction(history.getElementChange(self.object))
        table.insert(phase.appearances, getPreferredAppearanceOption(baseAppearanceOptions))
    end
    style.tooltip("Add appearance")

    ImGui.Indent(hierarchyIndent())
    for appKey, _ in pairs(phase.appearances) do
        ImGui.PushID(appKey)

        local searchKey = string.format("%s|%s|%s", tostring(entryKey), tostring(phaseKey), tostring(appKey))
        local search = self.phaseAppearanceSearch[searchKey] or ""
        local fallbackAppearance = getPreferredAppearanceOption(baseAppearanceOptions)
        local currentValue = resolvePreferredOption(phase.appearances[appKey], baseAppearanceOptions, fallbackAppearance)
        local options = buildSelectorOptions(baseAppearanceOptions, currentValue)
        phase.appearances[appKey] = currentValue
        phase.appearances[appKey], search, _ = style.trackedSearchDropdown(
            "##appearance",
            "Search appearance...",
            currentValue,
            search,
            options,
            {
                element = self.object,
                width = style.getMaxWidth(220) - 110,
                matchContentWidth = true,
                allowCustom = true,
                tooltip = loaded
                    and "Select an appearance from the selected character record, or type one and choose 'Use custom: ...'."
                    or "Appearances are loading for the selected character record. 'default' is available until the list is cached. You can still use a custom value."
            }
        )
        self.phaseAppearanceSearch[searchKey] = search

        local duplicateClicked, deleteClicked = drawDuplicateDeleteButtons("duplicateAppearance", "deleteAppearance")
        if duplicateClicked then
            history.addAction(history.getElementChange(self.object))
            table.insert(phase.appearances, utils.deepcopy(phase.appearances[appKey]))
        end
        if deleteClicked then
            history.addAction(history.getElementChange(self.object))
            table.remove(phase.appearances, appKey)
            self.phaseAppearanceSearch[searchKey] = nil
            ImGui.PopID()
            break
        end

        ImGui.PopID()
    end
    ImGui.Unindent(hierarchyIndent())
end

function community:drawSpotNodeRefs(period)
    period.spotNodeRefs = period.spotNodeRefs or {}

    for key, _ in pairs(period.spotNodeRefs) do
        ImGui.PushID(key)

        if period.isSequence then
            style.mutedText(string.format("%d.", key))
        else
            style.mutedText(IconGlyphs.CircleSmall)
        end
        ImGui.SameLine()

        period.spotNodeRefs[key], _ = registry.drawNodeRefSelector(math.max(120, style.getMaxWidth(220) - 30), period.spotNodeRefs[key], self.object, true)
        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline .. "##deleteSpotNodeRef") then
            history.addAction(history.getElementChange(self.object))
            table.remove(period.spotNodeRefs, key)
        end
        style.tooltip("Delete")

        ImGui.PopID()
    end

    if ImGui.Button("+ [Spot Ref]") then
        history.addAction(history.getElementChange(self.object))
        period.markings = {}
        table.insert(period.spotNodeRefs, "")
    end
end

function community:drawMarkings(period)
    period.markings = period.markings or {}

    for key, _ in pairs(period.markings) do
        ImGui.PushID(key)

        period.markings[key], _ = style.trackedTextField(self.object, "##marking", period.markings[key], "", style.getMaxWidth(220) - 30)
        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline .. "##deleteMarking") then
            history.addAction(history.getElementChange(self.object))
            table.remove(period.markings, key)
        end
        style.tooltip("Delete")

        ImGui.PopID()
    end

    if ImGui.Button("+ [Marking]") then
        history.addAction(history.getElementChange(self.object))
        period.spotNodeRefs = {}
        table.insert(period.markings, "")
    end
end

function community:drawPeriod(periods, periodKey, periodHierarchyKey)
    local period = periods[periodKey]
    if not period then
        return false
    end

    period.hour = tonumber(period.hour) or 1
    period.isSequence = period.isSequence == true
    period.quantity = math.floor(tonumber(period.quantity) or 1)
    period.markings = period.markings or {}
    period.spotNodeRefs = period.spotNodeRefs or {}
    local periodLabel = self.periodEnums[period.hour + 1] or tostring(period.hour)
    self:drawHierarchyRowBackground("period")

    local periodOpen = self:getHierarchyState(periodHierarchyKey, false)
    if drawHierarchyDisclosureButton("periodHierarchy", periodOpen, "period") then
        periodOpen = not periodOpen
        self.hierarchyOpen[periodHierarchyKey] = periodOpen
    end
    self:drawContext(periodKey, periods)
    

    local modeKey = tostring(period)
    local linkMode = self.periodLinkMode[modeKey]
    if linkMode ~= "marking" and linkMode ~= "nodeRef" then
        linkMode = (#period.markings > 0 and #period.spotNodeRefs == 0) and "marking" or "nodeRef"
    end

    ImGui.SameLine()
    if periodOpen then
        style.drawIconLabelRow(nil, string.format("[%d]", periodKey))
        ImGui.SameLine()
        period.hour, _ = style.trackedCombo(self.object, "##hour", period.hour, self.periodEnums, 150, {
            tooltip = "Named hour mappings:\nMidnight = 0:00\nMorning = 6:00\nDay = 9:00\nEvening = 18:00\nNight = 22:00"
        })

        ImGui.SameLine()
        local nextSequence, sequenceChanged = style.toggleButton(IconGlyphs.Numeric .. "##isSequence", period.isSequence)
        if sequenceChanged then
            history.addAction(history.getElementChange(self.object))
            period.isSequence = nextSequence
        end
        style.tooltip("Is Sequence: " .. tostring(period.isSequence) .. "\nIf true, the NPC(s) will use their assigned AISpot's in the same order as they are listed.\nOtherwise they will use them randomly.\nOnly relevant if AISpots are not set to be infinite.")

        ImGui.SameLine()
        local changed
        period.quantity, changed = style.trackedIntInput(self.object, "##quantity", period.quantity, 0, 9999, 85, 1, 10)
        if changed then
            period.quantity = math.floor(period.quantity)
        end
        style.tooltip("Quantity: " .. tostring(period.quantity) .. "\nNumber of NPC slots active during this time period.")
    else
        style.drawIconLabelRow(nil, string.format("[%d] %s", periodKey, periodLabel))
        ImGui.SameLine()
        ImGui.Dummy(8 * style.viewSize, 0)
        ImGui.SameLine()
        style.drawIconLabelRow(nil, string.format("%d NPC%s", period.quantity, period.quantity == 1 and "" or "s"))
        style.tooltip(string.format(
            "This period has %d NPC slot%s.",
            period.quantity,
            period.quantity == 1 and "" or "s"
        ))
        ImGui.SameLine()
        ImGui.Dummy(8 * style.viewSize, 0)
        ImGui.SameLine()
        local linkCount = linkMode == "nodeRef" and #period.spotNodeRefs or #period.markings
        style.drawIconLabelRow(linkMode == "nodeRef" and IconGlyphs.PoundBoxOutline or IconGlyphs.TagMultiple, tostring(linkCount))
        style.tooltip(string.format(
            "This period has %d %s%s.",
            linkCount,
            linkMode == "nodeRef" and "node ref" or "marking",
            linkCount == 1 and "" or "s"
        ))
    end

    local duplicateClicked, deleteClicked = drawDuplicateDeleteButtons("duplicatePeriod", "deletePeriod")
    if duplicateClicked then
        history.addAction(history.getElementChange(self.object))
        table.insert(periods, utils.deepcopy(periods[periodKey]))
    end
    if deleteClicked then
        history.addAction(history.getElementChange(self.object))
        table.remove(periods, periodKey)
        self.hierarchyOpen[periodHierarchyKey] = nil
        return true
    end

    if periodOpen then
        ImGui.Indent(hierarchyIndent())
        ImGui.Dummy(0, 4 * style.viewSize)

        local nodeRefsLabel, nodeRefsHiddenText = style.resolveActionLabel(IconGlyphs.PoundBoxOutline, "NodeRefs", "periodLinkNodeRef", nil, true)
        if style.switchTabButton(nodeRefsLabel, linkMode == "nodeRef", 120 * style.viewSize, 0) then
            linkMode = "nodeRef"
        end
        style.tooltipActionLabel(nodeRefsHiddenText)
        ImGui.SameLine()

        local markingsLabel, markingsHiddenText = style.resolveActionLabel(IconGlyphs.TagMultiple, "Markings", "periodLinkMarking", nil, true)
        if style.switchTabButton(markingsLabel, linkMode == "marking", 120 * style.viewSize, 0) then
            linkMode = "marking"
        end
        style.tooltipActionLabel(markingsHiddenText)
        self.periodLinkMode[modeKey] = linkMode

        if linkMode == "nodeRef" then
            self:drawSpotNodeRefs(period)
        else
            self:drawMarkings(period)
        end

        ImGui.Unindent(hierarchyIndent())
    end

    return false
end

function community:drawPhasePeriods(phase, phaseHierarchyKey)
    local periodsHeader = style.resolveActionLabelNoIconOnly(IconGlyphs.ClockOutline, "Time Periods", nil)
    drawSectionHeader(periodsHeader, #phase.timePeriods)
    ImGui.SameLine()
    if ImGui.Button("+##addPeriod") then
        history.addAction(history.getElementChange(self.object))
        table.insert(phase.timePeriods, {
            hour = 1,
            isSequence = false,
            markings = {},
            quantity = 1,
            spotNodeRefs = {}
        })
    end
    style.tooltip("Add time period")

    for periodKey, _ in pairs(phase.timePeriods) do
        ImGui.PushID(periodKey)

        local period = phase.timePeriods[periodKey]
        local periodHierarchyKey = phaseHierarchyKey .. "/period:" .. tostring(period)
        local deleted = self:drawPeriod(phase.timePeriods, periodKey, periodHierarchyKey)

        ImGui.PopID()
        if deleted then
            break
        end
    end
end

function community:drawPhases(entryKey, entry, entryHierarchyKey)
    drawSectionHeader("Phases", #entry.phases)
    ImGui.SameLine()
    if ImGui.Button("+##addPhase") then
        history.addAction(history.getElementChange(self.object))
        local nextPhaseIndex = #entry.phases + 1
        table.insert(entry.phases, {
            phaseName = string.format("phase_%d", nextPhaseIndex),
            appearances = { "default" },
            timePeriods = {}
        })
    end
    style.tooltip("Add phase")

    for key, phase in pairs(entry.phases) do
        ImGui.PushID(key)

        phase.appearances = phase.appearances or { "default" }
        phase.timePeriods = phase.timePeriods or {}
        phase.phaseName = sanitizeValue(phase.phaseName)
        self:drawHierarchyRowBackground("phase")

        local phaseHierarchyKey = entryHierarchyKey .. "/phase:" .. tostring(phase)
        local phaseOpen = self:getHierarchyState(phaseHierarchyKey, false)
        if drawHierarchyDisclosureButton("phaseHierarchy", phaseOpen, "phase") then
            phaseOpen = not phaseOpen
            self.hierarchyOpen[phaseHierarchyKey] = phaseOpen
        end
        self:drawContext(key, entry.phases)

        ImGui.SameLine()
        if phaseOpen then
            style.drawIconLabelRow(nil, string.format("[%d]", key))
            ImGui.SameLine()
            phase.phaseName, _ = style.trackedTextField(self.object, "##phaseName", phase.phaseName, "default", 120)
        else
            local phaseNameLabel = phase.phaseName ~= "" and phase.phaseName or "default"
            style.drawIconLabelRow(nil, string.format("[%d] %s", key, phaseNameLabel))
            ImGui.SameLine()
            ImGui.Dummy(8 * style.viewSize, 0)
            ImGui.SameLine()

            style.drawIconLabelRow(IconGlyphs.Hanger, tostring(#phase.appearances))
            style.tooltip(string.format(
                "This phase has %d appearance option%s.",
                #phase.appearances,
                #phase.appearances == 1 and "" or "s"
            ))
            ImGui.SameLine()
            ImGui.Dummy(8 * style.viewSize, 0)
            ImGui.SameLine()

            style.drawIconLabelRow(IconGlyphs.ClockOutline, tostring(#phase.timePeriods))
            style.tooltip(string.format(
                "This phase has %d time period%s.",
                #phase.timePeriods,
                #phase.timePeriods == 1 and "" or "s"
            ))
        end

        local duplicateClicked, deleteClicked = drawDuplicateDeleteButtons("duplicatePhase", "deletePhase")
        if duplicateClicked then
            history.addAction(history.getElementChange(self.object))
            table.insert(entry.phases, utils.deepcopy(entry.phases[key]))
        end
        if deleteClicked then
            history.addAction(history.getElementChange(self.object))
            table.remove(entry.phases, key)
            self.hierarchyOpen[phaseHierarchyKey] = nil
            ImGui.PopID()
            break
        end

        if phaseOpen then
            ImGui.Indent(hierarchyIndent())
            ImGui.Dummy(0, 4 * style.viewSize)
            self:drawPhaseAppearances(entryKey, key, entry, phase)
            ImGui.Dummy(0, 8 * style.viewSize)
            self:drawPhasePeriods(phase, phaseHierarchyKey)
            ImGui.Dummy(0, 4 * style.viewSize)
            ImGui.Unindent(hierarchyIndent())
        end

        ImGui.PopID()
    end
end

function community:drawEntries()
    ensureCharacterRecordsLoaded()

    style.pushButtonNoBG(true)
    ImGui.BeginDisabled(#self.entries == 0)
    if ImGui.Button(IconGlyphs.CollapseAllOutline .. "##communityFoldAll") then
        self:setHierarchyStateForAll(false)
    end
    style.tooltip("Fold all groups")
    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.ExpandAllOutline .. "##communityExpandAll") then
        self:setHierarchyStateForAll(true)
    end
    style.tooltip("Expand all groups")
    ImGui.EndDisabled()
    style.pushButtonNoBG(false)
    ImGui.Spacing()

    drawSectionHeader("Entries", #self.entries)
    ImGui.SameLine()
    if ImGui.Button("+##addEntry") then
        history.addAction(history.getElementChange(self.object))
        local nextEntryIndex = #self.entries + 1
        table.insert(self.entries, {
            entryName = string.format("entry_%d", nextEntryIndex),
            characterRecordId = "Character.Judy",
            initialPhaseName = "default",
            entryActiveOnStart = true,
            phases = {}
        })
    end
    style.tooltip("Add entry")
    self.hierarchyBaseCursorX = ImGui.GetCursorPosX()

    for key, entry in pairs(self.entries) do
        ImGui.PushID(key)
        local entryKey = tostring(key)

        entry.phases = entry.phases or {}
        entry.entryName = sanitizeValue(entry.entryName)
        entry.characterRecordId = sanitizeValue(entry.characterRecordId)
        entry.initialPhaseName = sanitizeValue(entry.initialPhaseName)
        entry.entryActiveOnStart = entry.entryActiveOnStart ~= false
        local phaseOptions, defaultInitialPhase, phaseNames = buildInitialPhaseOptions(entry.phases)
        if #phaseNames == 0 then
            entry.initialPhaseName = "default"
            self.entryInitialPhaseTouched[entryKey] = false
        else
            local hasSelection = utils.indexValue(phaseOptions, entry.initialPhaseName) ~= -1
            local untouchedDefault = entry.initialPhaseName == "default" and not self.entryInitialPhaseTouched[entryKey]
            if entry.initialPhaseName == "" or not hasSelection or untouchedDefault then
                entry.initialPhaseName = defaultInitialPhase
                self.entryInitialPhaseTouched[entryKey] = false
            end
        end
        self:drawHierarchyRowBackground("entry")

        local entryHierarchyKey = "entry:" .. tostring(entry)
        local entryOpen = self:getHierarchyState(entryHierarchyKey, false)
        if drawHierarchyDisclosureButton("entryHierarchy", entryOpen, "entry") then
            entryOpen = not entryOpen
            self.hierarchyOpen[entryHierarchyKey] = entryOpen
        end
        self:drawContext(key, self.entries)

        ImGui.SameLine()
        if entryOpen then
            style.drawIconLabelRow(nil, string.format("[%d]", key))
            ImGui.SameLine()
            entry.entryName, _ = style.trackedTextField(self.object, "##entryName", entry.entryName, "name", 120)

            ImGui.SameLine()
            style.mutedText(IconGlyphs.AlphaRBoxOutline)
            ImGui.SameLine()
            local recordSearch = self.entryRecordSearch[entryKey] or ""
            local recordOptions = buildSelectorOptions(characterRecords, entry.characterRecordId)
            entry.characterRecordId, recordSearch, _ = style.trackedSearchDropdown(
                "##characterRecordId",
                "Search character record...",
                entry.characterRecordId,
                recordSearch,
                recordOptions,
                {
                    element = self.object,
                    width = 200,
                    matchContentWidth = true,
                    allowCustom = true,
                    tooltip = "Select the character record (TweakDBID) for this community entry, or type one and choose 'Use custom: ...'."
                }
            )
            self.entryRecordSearch[entryKey] = recordSearch

            ImGui.SameLine()
            if drawIconActionButton(IconGlyphs.CogOutline, "entrySettings", nil) then
                ImGui.OpenPopup("##entrySettingsPopup")
            end
            style.tooltip(string.format(
                "Initial Phase Name: %s\nActive On Start: %s",
                entry.initialPhaseName ~= "" and entry.initialPhaseName or "default",
                entry.entryActiveOnStart and "true" or "false"
            ))

            if ImGui.BeginPopup("##entrySettingsPopup") then
                style.mutedText("Initial Phase Name")
                local phaseSearchKey = entryKey
                local phaseSearch = self.entryInitialPhaseSearch[phaseSearchKey] or ""
                local previousInitialPhase = entry.initialPhaseName
                entry.initialPhaseName, phaseSearch, _ = style.trackedSearchDropdown(
                    "##initialPhaseName",
                    "Search phase...",
                    entry.initialPhaseName,
                    phaseSearch,
                    phaseOptions,
                    {
                        element = self.object,
                        width = 220,
                        matchContentWidth = true
                    }
                )
                if entry.initialPhaseName ~= previousInitialPhase then
                    self.entryInitialPhaseTouched[entryKey] = true
                end
                self.entryInitialPhaseSearch[phaseSearchKey] = phaseSearch
                style.tooltip(
                    #phaseNames == 0
                        and "No phases available, using 'default'."
                        or "Select the phase to start this entry from."
                )

                style.mutedText("Active On Start")
                entry.entryActiveOnStart, _ = style.trackedCheckbox(self.object, "##activeOnStart", entry.entryActiveOnStart)
                ImGui.EndPopup()
            end
        else
            local entryNameLabel = entry.entryName ~= "" and entry.entryName or "name"
            local recordLabel = getRecordDisplayName(entry.characterRecordId)
            style.drawIconLabelRow(nil, string.format("[%d] %s", key, entryNameLabel))
            ImGui.SameLine()
            ImGui.Dummy(8 * style.viewSize, 0)
            ImGui.SameLine()

            style.drawIconLabelRow(nil, string.format("%d phase%s", #entry.phases, #entry.phases == 1 and "" or "s"))
            ImGui.SameLine()
            ImGui.Dummy(8 * style.viewSize, 0)
            ImGui.SameLine()

            style.drawIconLabelRow(IconGlyphs.AlphaRBoxOutline, recordLabel)
            style.tooltip("Character record assigned to this entry.")
        end

        local duplicateClicked, deleteClicked = drawDuplicateDeleteButtons("duplicateEntry", "deleteEntry")
        if duplicateClicked then
            history.addAction(history.getElementChange(self.object))
            table.insert(self.entries, utils.deepcopy(self.entries[key]))
        end
        if deleteClicked then
            history.addAction(history.getElementChange(self.object))
            table.remove(self.entries, key)
            self.hierarchyOpen[entryHierarchyKey] = nil
            self.entryRecordSearch[entryKey] = nil
            self.entryInitialPhaseSearch[entryKey] = nil
            self.entryInitialPhaseTouched[entryKey] = nil
            ImGui.PopID()
            break
        end

        if entryOpen then
            ImGui.Indent(hierarchyIndent())
            ImGui.Dummy(0, 4 * style.viewSize)
            self:drawPhases(key, entry, entryHierarchyKey)
            ImGui.Dummy(0, 4 * style.viewSize)
            ImGui.Unindent(hierarchyIndent())
        end

        ImGui.PopID()
    end

    self.hierarchyBaseCursorX = nil
end

function community:draw()
    visualized.draw(self)

    local x = utils.getTextMaxWidth({"Visualize position", "CommunityID (NodeRef)"}) + 4 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    self:drawPreviewCheckbox("Visualize position", x)
    style.tooltip("Preview a sphere, to make the community selectable in editor mode.")

    style.mutedText("CommunityID (NodeRef)")
    ImGui.SameLine()
    ImGui.SetCursorPosX(x)
    local nodeRefWidth = style.getMaxWidth(250) - 30
    local changed = false
    self.nodeRef, changed, _ = style.trackedTextField(self.object, "##commID", self.nodeRef, "$/#foobar", nodeRefWidth)
    if changed then
        registry.invalidate()
    end
    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.ReloadAlert .. "##communityNodeRefGenerate") then
        local generated = registry.generate(self.object)
        if generated ~= self.nodeRef then
            history.addAction(history.getElementChange(self.object))
            self.nodeRef = generated
            registry.invalidate()
        end
    end
    style.pushButtonNoBG(false)
    style.tooltip("Generate a unique NodeRef for this object")

    self:drawEntries()
end

function community:getProperties()
    local properties = visualized.getProperties(self)
    table.insert(properties, {
        id = self.node,
        name = self.dataType,
        defaultHeader = true,
        draw = function()
            self:draw()
        end
    })
    return properties
end

function community:export()
    local ref = utils.nodeRefStringToHashString(self.nodeRef)

    local entries = {}

    for _, entry in pairs(self.entries) do
        local phases = {}
        for _, phase in pairs(entry.phases) do
            local periods = {}

            for _, period in pairs(phase.timePeriods) do
                local ids = {}

                for _, ref in pairs(period.spotNodeRefs) do
                    table.insert(ids, {
                        ["$type"] = "worldGlobalNodeID",
                        ["hash"] = utils.nodeRefStringToHashString(ref)
                    })
                end

                table.insert(periods, {
                    ["$type"] = "communityCommunityEntryPhaseTimePeriodData",
                    ["isSequence"] = period.isSequence and 1 or 0,
                    ["periodName"] = {
                        ["$type"] = "CName",
                        ["$storage"] = "string",
                        ["$value"] = self.periodEnums[period.hour + 1]
                    },
                    ["spotNodeIds"] = ids
                })
            end

            table.insert(phases, {
                ["$type"] = "communityCommunityEntryPhaseSpotsData",
                ["entryPhaseName"] = {
                    ["$type"] = "CName",
                    ["$storage"] = "string",
                    ["$value"] = phase.phaseName
                },
                ["timePeriodsData"] = periods
            })
        end

        table.insert(entries, {
            ["$type"] = "communityCommunityEntrySpotsData",
            ["entryName"] = {
                ["$type"] = "CName",
                ["$storage"] = "string",
                ["$value"] = entry.entryName
            },
            ["phasesData"] = phases
        })
    end

    local data = visualized.export(self)
    data.type = "worldCompiledCommunityAreaNode_Streamable"
    data.data = {
        ["sourceObjectId"] = {
            ["$type"] = "entEntityID",
            ["hash"] = ref
        },
        ["area"] = {
            ["Data"] = {
                ["$type"] = "communityArea",
                ["entriesData"] = entries
            }
        }
    }

    return data
end

return community
