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

local function sanitizeValue(value)
    local sanitized = tostring(value or "")
    sanitized = sanitized:gsub("^%s+", ""):gsub("%s+$", "")
    sanitized = sanitized:gsub("[\128-\255]", "")

    return sanitized
end

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

local function resolvePreferredOption(selected, options, fallback)
    local cleanSelected = sanitizeValue(selected)
    if cleanSelected == "" then
        cleanSelected = sanitizeValue(fallback, "default")
    end

    if #options == 0 then
        return cleanSelected
    end

    if utils.indexValue(options, cleanSelected) ~= -1 then
        return cleanSelected
    end

    return options[1]
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

local function drawHeaderText(key, text)
    ImGui.SameLine()
    ImGui.SetCursorPosX(ImGui.GetCursorPosX() - 8 * style.viewSize)
    ImGui.Text(string.format("[%d] %s", key, text))
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

function community:drawPhaseAppearances(entryKey, phaseKey, entry, phase)
    phase.appearances = phase.appearances or {}
    if #phase.appearances == 0 then
        table.insert(phase.appearances, "default")
    end

    local baseAppearanceOptions, loaded = requestCharacterAppearances(entry.characterRecordId)
    if ImGui.TreeNodeEx("Appearances", ImGuiTreeNodeFlags.SpanFullWidth) then
        for appKey, _ in pairs(phase.appearances) do
            ImGui.PushID(appKey)

            local searchKey = string.format("%s|%s|%s", tostring(entryKey), tostring(phaseKey), tostring(appKey))
            local search = self.phaseAppearanceSearch[searchKey] or ""
            local options = copyList(baseAppearanceOptions)
            local currentValue = resolvePreferredOption(phase.appearances[appKey], options, "default")
            phase.appearances[appKey] = currentValue
            phase.appearances[appKey], search, _ = style.trackedSearchDropdown(
                self.object,
                "##appearance",
                "Search appearance...",
                currentValue,
                search,
                options,
                220,
                true
            )
            self.phaseAppearanceSearch[searchKey] = search
            style.tooltip(loaded
                and "Select an appearance from the selected character record."
                or "Appearances are loading for the selected character record. 'default' is available until the list is cached.")

            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.Delete) then
                history.addAction(history.getElementChange(self.object))
                table.remove(phase.appearances, appKey)
                self.phaseAppearanceSearch[searchKey] = nil
            end

            ImGui.PopID()
        end

        if ImGui.Button("+ [Appearance]") then
            history.addAction(history.getElementChange(self.object))
            table.insert(phase.appearances, baseAppearanceOptions[1] or "default")
        end

        ImGui.TreePop()
    end
end

function community:drawSpotNodeRefs(period)
    if ImGui.TreeNodeEx("Spot NodeRef's", ImGuiTreeNodeFlags.SpanFullWidth) then
        for key, _ in pairs(period.spotNodeRefs) do
            ImGui.PushID(key)

            period.spotNodeRefs[key], _ = registry.drawNodeRefSelector(style.getMaxWidth(250) - 30, period.spotNodeRefs[key], self.object, true)
            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.Delete) then
                history.addAction(history.getElementChange(self.object))
                table.remove(period.spotNodeRefs, key)
            end

            ImGui.PopID()
        end

        if ImGui.Button("+ [Spot Ref]") then
            history.addAction(history.getElementChange(self.object))
            period.markings = {}
            table.insert(period.spotNodeRefs, "")
        end

        ImGui.TreePop()
    end
end

function community:drawMarkings(period)
    if ImGui.TreeNodeEx("Markings", ImGuiTreeNodeFlags.SpanFullWidth) then
        for key, _ in pairs(period.markings) do
            ImGui.PushID(key)

            period.markings[key], _ = style.trackedTextField(self.object, "##marking", period.markings[key], "", 200)
            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.Delete) then
                history.addAction(history.getElementChange(self.object))
                table.remove(period.markings, key)
            end

            ImGui.PopID()
        end

        if ImGui.Button("+ [Marking]") then
            history.addAction(history.getElementChange(self.object))
            period.spotNodeRefs = {}
            table.insert(period.markings, "")
        end

        ImGui.TreePop()
    end
end

function community:drawPeriod(periods, periodKey)
    local period = periods[periodKey]

    if ImGui.TreeNodeEx("##" .. tostring(periodKey), ImGuiTreeNodeFlags.SpanFullWidth) then
        self:drawContext(periodKey, periods)
        drawHeaderText(periodKey, self.periodEnums[period.hour + 1])

        local max = utils.getTextMaxWidth({"Hour", "Is Sequence", "Quantity"}) + 4 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

        style.mutedText("Hour")
        ImGui.SameLine()
        ImGui.SetCursorPosX(max)
        period.hour, _ = style.trackedCombo(self.object, "##hour", period.hour, self.periodEnums)
        style.tooltip("Named hour mappings:\nMidnight = 0:00\nMorning = 6:00\nDay = 9:00\nEvening = 18:00\nNight = 22:00")

        style.mutedText("Is Sequence")
        ImGui.SameLine()
        ImGui.SetCursorPosX(max)
        period.isSequence, _ = style.trackedCheckbox(self.object, "##isSequence", period.isSequence)
        style.tooltip("If true, the NPC(s) will use their assigned AISpot's in the same order as they are listed.\nOtherwise they will use them randomly.\nOnly relevant if AISpots are not set to be infinite.")

        style.mutedText("Quantity")
        ImGui.SameLine()
        ImGui.SetCursorPosX(max)
        period.quantity, changed = style.trackedIntInput(self.object, "##quantity", period.quantity, 0, 9999, 75, 1, 10)
        if changed then
            period.quantity = math.floor(period.quantity)
        end

        self:drawMarkings(period)
        self:drawSpotNodeRefs(period)

        ImGui.TreePop()
    else
        self:drawContext(periodKey, periods)
        drawHeaderText(periodKey, self.periodEnums[period.hour + 1])
    end
end

function community:drawPhasePeriods(phase)
    if ImGui.TreeNodeEx("Time Periods", ImGuiTreeNodeFlags.SpanFullWidth) then
        for periodKey, _ in pairs(phase.timePeriods) do
            ImGui.PushID(periodKey)

            self:drawPeriod(phase.timePeriods, periodKey)

            ImGui.PopID()
        end

        if ImGui.Button("+ [Period]") then
            history.addAction(history.getElementChange(self.object))
            table.insert(phase.timePeriods, {
                hour = 1,
                isSequence = false,
                markings = {},
                quantity = 1,
                spotNodeRefs = {}
            })
        end

        ImGui.TreePop()
    end
end

function community:drawPhases(entryKey, entry)
    if ImGui.TreeNodeEx("Phases", ImGuiTreeNodeFlags.SpanFullWidth) then
        for key, phase in pairs(entry.phases) do
            ImGui.PushID(key)

            phase.appearances = phase.appearances or { "default" }
            phase.timePeriods = phase.timePeriods or {}

            if ImGui.TreeNodeEx("##" .. tostring(key), ImGuiTreeNodeFlags.SpanFullWidth) then
                self:drawContext(key, entry.phases)
                drawHeaderText(key, phase.phaseName)

                style.mutedText("Phase Name")
                ImGui.SameLine()
                phase.phaseName, _ = style.trackedTextField(self.object, "##phaseName", phase.phaseName, "uniqueName", 200)

                self:drawPhaseAppearances(entryKey, key, entry, phase)
                self:drawPhasePeriods(phase)

                ImGui.TreePop()
            else
                self:drawContext(key, entry.phases)
                drawHeaderText(key, phase.phaseName)
            end

            ImGui.PopID()
        end

        if ImGui.Button("+ [Phase]") then
            history.addAction(history.getElementChange(self.object))
            table.insert(entry.phases, {
                phaseName = "default",
                appearances = { "default" },
                timePeriods = {}
            })
        end
        ImGui.TreePop()
    end
end

function community:drawEntries()
    ensureCharacterRecordsLoaded()

    if ImGui.TreeNodeEx("Entries", ImGuiTreeNodeFlags.SpanFullWidth) then
        for key, entry in pairs(self.entries) do
            ImGui.PushID(key)

            entry.phases = entry.phases or {}
            entry.characterRecordId = sanitizeValue(entry.characterRecordId)

            if ImGui.TreeNodeEx("##" .. tostring(key), ImGuiTreeNodeFlags.SpanFullWidth) then
                self:drawContext(key, self.entries)
                drawHeaderText(key, entry.entryName)

                local max = utils.getTextMaxWidth({"Entry Name", "Character Record", "Initial Phase Name", "Active On Start"}) + 10 * ImGui.GetStyle().ItemSpacing.x

                style.mutedText("Entry Name")
                ImGui.SameLine()
                ImGui.SetCursorPosX(max)
                entry.entryName, _ = style.trackedTextField(self.object, "##entryName", entry.entryName, "uniqueName", -1)

                style.mutedText("Character Record")
                ImGui.SameLine()
                ImGui.SetCursorPosX(max)
                local recordSearch = self.entryRecordSearch[tostring(key)] or ""
                local recordOptions = buildSelectorOptions(characterRecords, entry.characterRecordId)
                entry.characterRecordId, recordSearch, _ = style.trackedSearchDropdown(
                    self.object,
                    "##characterRecordId",
                    "Search character record...",
                    entry.characterRecordId,
                    recordSearch,
                    recordOptions,
                    250,
                    true
                )
                self.entryRecordSearch[tostring(key)] = recordSearch
                style.tooltip("Select the character record (TweakDBID) for this community entry.")

                style.mutedText("Initial Phase Name")
                ImGui.SameLine()
                ImGui.SetCursorPosX(max)
                entry.initialPhaseName, _ = style.trackedTextField(self.object, "##initialPhaseName", entry.initialPhaseName, "", -1)

                style.mutedText("Active On Start")
                ImGui.SameLine()
                ImGui.SetCursorPosX(max)
                entry.entryActiveOnStart, _ = style.trackedCheckbox(self.object, "##activeOnStart", entry.entryActiveOnStart)

                self:drawPhases(key, entry)

                ImGui.TreePop()
            else
                self:drawContext(key, self.entries)
                drawHeaderText(key, entry.entryName)
            end

            ImGui.PopID()
        end

        if ImGui.Button("+ [Entry]") then
            history.addAction(history.getElementChange(self.object))
            table.insert(self.entries, {
                entryName = "name",
                characterRecordId = "Character.Judy",
                initialPhaseName = "default",
                entryActiveOnStart = true,
                phases = {}
            })
        end

        ImGui.TreePop()
    end
end

function community:draw()
    visualized.draw(self)

    local x = utils.getTextMaxWidth({"Preview Sphere", "CommunityID (NodeRef)"}) + 4 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    self:drawPreviewCheckbox("Preview Sphere", x)
    style.tooltip("Preview a sphere, to make the community selectable in editor mode.")

    style.mutedText("CommunityID (NodeRef)")
    ImGui.SameLine()
    ImGui.SetCursorPosX(x)
    self.nodeRef, _, _ = style.trackedTextField(self.object, "##commID", self.nodeRef, "$/#foobar", -1)

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
