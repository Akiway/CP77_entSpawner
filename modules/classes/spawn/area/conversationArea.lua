local triggerArea = require("modules/classes/spawn/area/triggerArea")
local area = require("modules/classes/spawn/area/area")
local utils = require("modules/utils/core/utils")
local style = require("modules/ui/style")
local history = require("modules/utils/project/history")
local registry = require("modules/utils/game/nodeRefRegistry")
local conversationData = require("modules/utils/data/conversationData")

---Interruption operation presets.
---
---`interruptionOperations` is a polymorphic operation list, but every one of the 1243
---`worldInterestingConversationsAreaNode` instances shipped by the base game and Phantom Liberty
---uses one of exactly four shapes, so they are offered as presets instead of a tree editor.
local interruptionPresets = {
    "None",
    "Interrupt On Distraction",
    "Interrupt, Talk On Return",
    "Never Interrupt"
}

---Builds a fresh `array:handle:scnIInterruptionOperation` export value for a preset.
---Returns `nil` for the "None" preset, so the export omits the key and the node keeps its
---engine default (an empty list) rather than shipping an empty Lua table.
---@param preset number 0-based index into `interruptionPresets`.
---@return table? operations
local function buildInterruptionOperations(preset)
    if preset == 1 then
        -- Most common shipped shape: the scene may be interrupted while anyone nearby is
        -- distracted, and the actors do not resume talking on their own once they return.
        return {
            { ["Data"] = { ["$type"] = "scnToggleInterruption_InterruptionOperation", ["enable"] = 1 } },
            { ["Data"] = {
                ["$type"] = "scnOverrideInterruptionScenario_InterruptionOperation",
                ["scenarioId"] = { ["$type"] = "scnInterruptionScenarioId", ["id"] = 0 },
                ["scenarioOperations"] = {
                    { ["Data"] = {
                        ["$type"] = "scnOverrideTalkOnReturn_InterruptionScenarioOperation",
                        ["talkOnReturn"] = 0
                    } },
                    { ["Data"] = {
                        ["$type"] = "scnOverrideInterruptConditions_InterruptionScenarioOperation",
                        ["interruptConditions"] = {
                            { ["Data"] = { ["$type"] = "scnCheckAnyoneDistractedInterruptCondition" } }
                        }
                    } },
                    { ["Data"] = {
                        ["$type"] = "scnOverrideReturnConditions_InterruptionScenarioOperation",
                        ["returnConditions"] = {
                            { ["Data"] = {
                                ["$type"] = "scnCheckDistractedReturnCondition",
                                ["params"] = {
                                    ["$type"] = "scnCheckDistractedReturnConditionParams",
                                    ["distracted"] = 0,
                                    ["target"] = "Anyone"
                                }
                            } }
                        }
                    } }
                }
            } }
        }
    elseif preset == 2 then
        -- The two condition lists are deliberately left off: the operations still clear them,
        -- and an empty Lua table would serialize as a JSON object instead of an array.
        return {
            { ["Data"] = { ["$type"] = "scnToggleInterruption_InterruptionOperation", ["enable"] = 1 } },
            { ["Data"] = {
                ["$type"] = "scnOverrideInterruptionScenario_InterruptionOperation",
                ["scenarioId"] = { ["$type"] = "scnInterruptionScenarioId", ["id"] = 4294967295 },
                ["scenarioOperations"] = {
                    { ["Data"] = {
                        ["$type"] = "scnOverrideTalkOnReturn_InterruptionScenarioOperation",
                        ["talkOnReturn"] = 1
                    } },
                    { ["Data"] = { ["$type"] = "scnOverrideInterruptConditions_InterruptionScenarioOperation" } },
                    { ["Data"] = { ["$type"] = "scnOverrideReturnConditions_InterruptionScenarioOperation" } }
                }
            } }
        }
    elseif preset == 3 then
        return {
            { ["Data"] = { ["$type"] = "scnToggleInterruption_InterruptionOperation", ["enable"] = 0 } }
        }
    end

    return nil
end

---@return table
local function defaultGroup()
    return {
        path = "",
        overrideEnabled = false,
        ignoreLocalLimit = false,
        ignoreGlobalLimit = false,
        interruption = 0
    }
end

---@return table
local function defaultScene()
    return {
        path = "",
        ignoreLocalLimit = false,
        ignoreGlobalLimit = false,
        interruption = 0,
        conditionEnabled = false,
        conditionFact = "",
        conditionComparison = 2, -- EComparisonType.Equal
        conditionValue = 1
    }
end

---Widens one stored entry into the current record shape.
---Projects saved before the per-entry limit / interruption / condition fields existed hold plain
---depot path strings here, so those load as a record carrying engine defaults.
---@param entry any
---@param default fun(): table
---@return table
local function normalizeEntry(entry, default)
    local record = default()

    if type(entry) == "string" then
        record.path = entry
        return record
    end

    if type(entry) ~= "table" then
        return record
    end

    for key, value in pairs(record) do
        local stored = entry[key]
        if stored ~= nil and type(stored) == type(value) then
            record[key] = stored
        end
    end

    return record
end

---Normalizes a list that stays a plain list of depot paths / node refs.
---A ref may only appear once: binding the same workspot twice gives the scene one usable spot,
---not two, so duplicates are dropped here as well as blocked in the UI.
---@param list any
---@return string[]
local function normalizePaths(list)
    local result = {}
    local seen = {}

    if type(list) ~= "table" then
        return result
    end

    for _, entry in ipairs(list) do
        local path = nil

        if type(entry) == "string" then
            path = entry
        elseif type(entry) == "table" and type(entry.path) == "string" then
            path = entry.path
        end

        -- Empty rows are placeholders the user has not filled in yet, so only one is kept.
        if path and not seen[path] then
            seen[path] = true
            table.insert(result, path)
        end
    end

    return result
end

---Loads the single conversation group, migrating the two list fields it replaced.
---
---`conversationGroups` and `conversationResources` are the same reference in two shapes, and no
---shipped node fills both, so they collapse into one entry whose override toggle picks the shape.
---An older project that somehow held both keeps the override, since it is the richer of the two.
---@param data table Stored spawn data.
---@return table group
local function loadGroup(data)
    if type(data.group) == "table" then
        return normalizeEntry(data.group, defaultGroup)
    end

    local resources = type(data.resources) == "table" and data.resources or {}
    if resources[1] then
        local group = normalizeEntry(resources[1], defaultGroup)
        group.overrideEnabled = true
        return group
    end

    local groups = normalizePaths(data.groups)
    if groups[1] then
        local group = defaultGroup()
        group.path = groups[1]
        return group
    end

    return defaultGroup()
end

---Loads the single inline conversation, migrating the list field it replaced.
---@param data table Stored spawn data.
---@return table scene
local function loadScene(data)
    if type(data.scene) == "table" then
        return normalizeEntry(data.scene, defaultScene)
    end

    local scenes = type(data.scenes) == "table" and data.scenes or {}
    if scenes[1] then
        return normalizeEntry(scenes[1], defaultScene)
    end

    return defaultScene()
end

---Class for worldInterestingConversationsAreaNode
---@class conversationArea : triggerArea
---@field private group table `conversationGroups` / `conversationResources`, one group resource.
---@field private scene table `conversations`, one inline scene with its overrides.
---@field private workspots string[]
---@field private savingStrategy number
---@field private savingStrategyEnums table
---@field private comparisonEnums table
---@field private groupSearch string
---@field private sceneSearch string
---@field private maxConversationPropertyWidth number?
local conversationArea = setmetatable({}, { __index = triggerArea })

function conversationArea:new()
	local o = triggerArea.new(self)

    o.spawnListType = "files"
    o.dataType = "Conversation Area"
    o.spawnDataPath = "data/spawnables/area/conversationArea/"
    o.modulePath = "area/conversationArea"
    o.node = "worldInterestingConversationsAreaNode"
    o.description = "Trigger used for activating conversation scenes."
    o.previewNote = "Not previewed in editor."
    o.icon = IconGlyphs.AccountVoice

    o.triggerType = "Conversation"

    o.group = defaultGroup()
    o.scene = defaultScene()
    o.workspots = {}
    o.savingStrategy = 0
    o.savingStrategyEnums = utils.enumTable("audioConversationSavingStrategy")
    o.comparisonEnums = utils.enumTable("EComparisonType")

    -- Filter text for the path dropdowns, and the ref of the last rejected duplicate workspot.
    -- Transient, never serialized.
    o.groupSearch = ""
    o.sceneSearch = ""
    o.duplicateWorkspot = nil

    o.maxConversationPropertyWidth = nil

    setmetatable(o, { __index = self })
   	return o
end

function conversationArea:loadSpawnData(data, position, rotation)
    triggerArea.loadSpawnData(self, data, position, rotation)

    -- `spawnable.loadSpawnData` assigns tables by reference and its payloads outlive the load
    -- (project cache, clipboard), so every record is rebuilt here rather than shared. This doubles
    -- as the migration path for the older list-shaped fields.
    self.group = loadGroup(data)
    self.scene = loadScene(data)
    self.workspots = normalizePaths(data.workspots)

    self.groupSearch = ""
    self.sceneSearch = ""
    self.duplicateWorkspot = nil
end

function conversationArea:save()
    local data = triggerArea.save(self)

    data.group = utils.deepcopy(self.group)
    data.scene = utils.deepcopy(self.scene)
    data.workspots = utils.deepcopy(self.workspots)
    data.savingStrategy = self.savingStrategy

    return data
end

---Number of workspots the selected resources are expected to need.
---
---A scene binds one workspot per actor, so a group spanning scenes of differing size reports a
---range. Picking both a group and a scene means the area has to satisfy whichever needs more.
---@return number? min
---@return number? max
function conversationArea:getExpectedWorkspots()
    local min, max = nil, nil

    local function merge(entryMin, entryMax)
        if not entryMin then
            return
        end

        min = min and math.max(min, entryMin) or entryMin
        max = max and math.max(max, entryMax) or entryMax
    end

    merge(conversationData.groups.actorRange(self.group.path))
    merge(conversationData.scenes.actorRange(self.scene.path))

    return min, max
end

---Draws a searchable depot path dropdown backed by one of the cached path lists.
---@param id string Unique widget ID.
---@param value string Current depot path.
---@param search string Current filter text.
---@param list ConversationPathList
---@param hint string Placeholder for the filter input.
---@param tooltip string
---@return string value
---@return string search
function conversationArea:drawResourcePath(id, value, search, list, hint, tooltip)
    local width = style.getMaxWidth(250) - 30
    local newValue, newSearch = style.trackedSearchDropdown(
        "##" .. id,
        hint,
        value,
        search,
        list.getSelectable(),
        {
            element = self.object,
            width = width,
            matchContentWidth = true,
            allowCustom = true,
            optionDisplayFn = list.displayName,
            -- The readable label drops the folders, so the depot path goes in the tooltip.
            optionTooltipFn = function(optionText)
                return optionText
            end,
            optionDecoratorFn = style.drawPathOriginPrefix,
            -- 32 groups and 639 scenes, so the default list height leaves a lot of scrolling.
            listHeight = 300,
            tooltip = tooltip,
            clearable = true
        }
    )

    -- The width above leaves room for this button, so it sits where the delete buttons used to.
    local empty = newValue == ""

    ImGui.SameLine()
    style.pushButtonNoBG(true)
    -- `pushButtonNoBG` zeroes the button background, so `pushGreyedOut` would not show through.
    -- Muting the glyph is what reads as disabled here.
    style.pushStyleColor(empty, ImGuiCol.Text, style.greyedColor)
    if ImGui.Button(IconGlyphs.Close .. "##" .. id .. "Clear") and not empty then
        history.addAction(history.getElementChange(self.object))
        newValue = ""
    end
    style.popStyleColor(empty)
    style.pushButtonNoBG(false)
    style.tooltip("Clear the selection.\nRight-clicking the dropdown does the same, middle-clicking it copies the path.")

    return newValue, newSearch
end

---Left hand label of one property row, aligned with the rest of the section.
---@param label string
function conversationArea:drawPropertyLabel(label)
    if not self.maxConversationPropertyWidth then
        self.maxConversationPropertyWidth = utils.getTextMaxWidth({ "Ignore Global Limit", "Expected Workspots", "Comparison" }) + 4 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    style.mutedText(label)
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxConversationPropertyWidth)
end

---Draws the workspot count the picked resource implies, as a read only property row.
---@param list ConversationPathList
---@param path string
function conversationArea:drawExpectedWorkspots(list, path)
    local label = conversationData.formatActorRange(list.actorRange(path))
    if not label then
        return
    end

    self:drawPropertyLabel("Expected Workspots")
    style.styledText(label, style.highlightColor)
    style.tooltip("One workspot per scene actor. The player is never bound to one, so they do not count.\nShipped areas match this count 95% of the time, and carry a spare otherwise, so treat it as a minimum.")
end

---Draws the two per-entry playback limit overrides and the interruption preset, shared by
---the group override and the inline scene.
---@param entry table
function conversationArea:drawEntryCommon(entry)
    self:drawPropertyLabel("Ignore Local Limit")
    entry.ignoreLocalLimit, _ = style.trackedCheckbox(self.object, "##ignoreLocalLimit", entry.ignoreLocalLimit)
    style.tooltip("Play this conversation even when this area already reached its own conversation limit.")

    self:drawPropertyLabel("Ignore Global Limit")
    entry.ignoreGlobalLimit, _ = style.trackedCheckbox(self.object, "##ignoreGlobalLimit", entry.ignoreGlobalLimit)
    style.tooltip("Play this conversation even when the world wide conversation limit is reached.")

    self:drawPropertyLabel("Interruption")
    -- `trackedCombo` draws the current-value tooltip itself, so the helper text goes through it.
    -- A `style.tooltip` call after it would open a second window on top of the first.
    entry.interruption, _ = style.trackedCombo(self.object, "##interruption", entry.interruption, interruptionPresets, 190, {
        tooltip = "How the conversation reacts to the player interrupting it.\nThese are the four setups shipped by the base game."
    })
end

---@param entry table
function conversationArea:drawSceneCondition(entry)
    self:drawPropertyLabel("Condition")
    entry.conditionEnabled, _ = style.trackedCheckbox(self.object, "##conditionEnabled", entry.conditionEnabled)
    style.tooltip("Only play this conversation while a quest fact comparison holds.")

    if not entry.conditionEnabled then
        return
    end

    self:drawPropertyLabel("Fact")
    entry.conditionFact, _ = style.trackedTextField(self.object, "##conditionFact", entry.conditionFact, "sts_ep1_08_finished", 190)
    style.tooltip("Quest fact name, as used by the facts database.")

    self:drawPropertyLabel("Comparison")
    entry.conditionComparison, _ = style.trackedCombo(self.object, "##conditionComparison", entry.conditionComparison, self.comparisonEnums, 130)

    self:drawPropertyLabel("Value")
    entry.conditionValue, _, _ = style.trackedIntInput(self.object, "##conditionValue", entry.conditionValue, -2147483648, 2147483647, 100, 1, 10)
end

---Muted header note naming the picked resource, so a collapsed section still reads.
---@param list ConversationPathList
---@param path string
---@return string?
local function headerNote(list, path)
    if path == "" then
        return nil
    end

    return list.displayName(path)
end

function conversationArea:drawGroup()
    if not style.treeNodeWithNote("Conversation Group", headerNote(conversationData.groups, self.group.path)) then
        return
    end

    style.styledTextWrapped("Conversation group played by this area. A group bundles the scenes that fit one crowd archetype.", style.mutedColor)

    ImGui.PushID("group")

    self.group.path, self.groupSearch = self:drawResourcePath(
        "group",
        self.group.path,
        self.groupSearch,
        conversationData.groups,
        "Search conversation group...",
        "Conversation group resource (.conversations)"
    )

    self:drawExpectedWorkspots(conversationData.groups, self.group.path)

    self:drawPropertyLabel("Override Playback")
    self.group.overrideEnabled, _ = style.trackedCheckbox(self.object, "##overrideEnabled", self.group.overrideEnabled)
    style.tooltip("Wrap the group so the limits and interruption below apply to it.\nWithout this the group plays with whatever its own resource defines.")

    if self.group.overrideEnabled then
        self:drawEntryCommon(self.group)
    end

    ImGui.PopID()
    ImGui.TreePop()
end

function conversationArea:drawScene()
    if not style.treeNodeWithNote("Conversation Scene", headerNote(conversationData.scenes, self.scene.path)) then
        return
    end

    style.styledTextWrapped("A single scene played by this area, outside of any conversation group.", style.mutedColor)

    ImGui.PushID("scene")

    self.scene.path, self.sceneSearch = self:drawResourcePath(
        "scenePath",
        self.scene.path,
        self.sceneSearch,
        conversationData.scenes,
        "Search conversation scene...",
        "Conversation scene resource (.scene)"
    )

    self:drawExpectedWorkspots(conversationData.scenes, self.scene.path)
    self:drawEntryCommon(self.scene)
    self:drawSceneCondition(self.scene)

    ImGui.PopID()
    ImGui.TreePop()
end

function conversationArea:drawWorkspots()
    if not style.treeNodeWithCount("Workspots", #self.workspots) then
        return
    end

    style.styledTextWrapped("The Workspot nodes to which the actors on the scene are linked. Without them, nothing plays out.", style.mutedColor)

    local expectedMin, expectedMax = self:getExpectedWorkspots()
    if expectedMin and #self.workspots < expectedMin then
        style.styledTextWrapped(string.format(
            "The picked resources need %s workspots, but only %d %s bound.",
            conversationData.formatActorRange(expectedMin, expectedMax),
            #self.workspots,
            #self.workspots == 1 and "is" or "are"
        ), style.warnColor)
    end

    local remove = nil
    local hasEmptyRow = false

    for index, workspot in ipairs(self.workspots) do
        ImGui.PushID(index)

        -- Every ref the other rows already hold is taken off this row's list: binding the same
        -- workspot twice still leaves the scene with one place to put an actor.
        local taken = {}
        for otherIndex, otherRef in ipairs(self.workspots) do
            if otherIndex ~= index and otherRef ~= "" then
                taken[otherRef] = true
            end
        end

        local newRef, finished = registry.drawNodeRefSelector(style.getMaxWidth(250) - 30, workspot, self.object, true, taken)

        -- The picker doubles as a free text field, which the list filtering above cannot cover, so
        -- a typed duplicate is rejected once the user commits it rather than while they type.
        if finished and newRef ~= "" and taken[newRef] then
            self.duplicateWorkspot = newRef
            self.workspots[index] = ""
        else
            if finished then
                self.duplicateWorkspot = nil
            end
            self.workspots[index] = newRef
        end

        hasEmptyRow = hasEmptyRow or self.workspots[index] == ""

        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline) then
            history.addAction(history.getElementChange(self.object))
            remove = index
        end

        ImGui.PopID()
    end

    if remove then
        table.remove(self.workspots, remove)
        self.duplicateWorkspot = nil
    end

    if self.duplicateWorkspot then
        style.styledTextWrapped(string.format("%s is already bound to this area. Each workspot may only be listed once.", self.duplicateWorkspot), style.warnColor)
    end

    style.pushGreyedOut(hasEmptyRow)
    if ImGui.Button("+ Workspot") and not hasEmptyRow then
        history.addAction(history.getElementChange(self.object))
        table.insert(self.workspots, "")
    end
    style.popGreyedOut(hasEmptyRow)

    if hasEmptyRow then
        style.tooltip("Fill in the empty workspot row first.")
    end

    ImGui.TreePop()
end

function conversationArea:drawConversation(changed)
    if changed then
        self.trigger = {
            ["$type"] = "worldInterestingConversationsAreaNotifier"
        }

        return
    end

    self:drawGroup()
    self:drawScene()
    self:drawWorkspots()

    style.mutedText("Saving Strategy")
    ImGui.SameLine()
    self.savingStrategy, _ = style.trackedCombo(self.object, "##savingStrategy", self.savingStrategy, self.savingStrategyEnums, 100, {
        tooltip = "Whether the conversation progress survives a save / load. The base game always uses Default."
    })

    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload .. "##reloadConversationLists") then
        conversationData.reloadAll()
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reload the conversation group and scene path lists from disk.")
end

function conversationArea:getAvailableTriggers()
    return {
        ["Conversation"] = conversationArea.drawConversation
    }
end

function conversationArea:draw()
    area.draw(self)

    if ImGui.TreeNodeEx(self.triggerType, ImGuiTreeNodeFlags.SpanFullWidth) then
        self:drawChannelSelect()
        self:drawConversation(false)
        ImGui.TreePop()
    end
end

function conversationArea:export()
    local data = triggerArea.export(self)
    data.type = "worldInterestingConversationsAreaNode"

    if #self.workspots == 0 then
        -- 1240 of the 1243 shipped nodes bind at least one workspot; without one the area has
        -- no actors to run the scene on, so it silently does nothing in game.
        local issues = self.object.sUI.spawner.baseUI.exportUI.exportIssues
        table.insert(issues.noConversationWorkspots, self.object.name)
    end

    local groups = {}
    local resources = {}
    local scenes = {}
    local workspots = {}

    if self.group.path ~= "" then
        if self.group.overrideEnabled then
            local resource = {
                ["$type"] = "worldConversationGroupData",
                ["conversationGroup"] = conversationData.exportRef(self.group.path),
                ["ignoreLocalLimit"] = self.group.ignoreLocalLimit and 1 or 0,
                ["ignoreGlobalLimit"] = self.group.ignoreGlobalLimit and 1 or 0
            }

            resource.interruptionOperations = buildInterruptionOperations(self.group.interruption)

            table.insert(resources, { ["Data"] = resource })
        else
            table.insert(groups, conversationData.exportRef(self.group.path))
        end
    end

    if self.scene.path ~= "" then
        -- The base game references conversation scenes as soft imports, so the sector does not
        -- pull every scene in on load.
        local scene = {
            ["$type"] = "worldConversationData",
            ["sceneFilename"] = conversationData.exportRef(self.scene.path, "Soft"),
            ["ignoreLocalLimit"] = self.scene.ignoreLocalLimit and 1 or 0,
            ["ignoreGlobalLimit"] = self.scene.ignoreGlobalLimit and 1 or 0
        }

        scene.interruptionOperations = buildInterruptionOperations(self.scene.interruption)

        if self.scene.conditionEnabled then
            scene.condition = {
                ["Data"] = {
                    ["$type"] = "questFactsDBCondition",
                    ["type"] = {
                        ["Data"] = {
                            ["$type"] = "questVarComparison_ConditionType",
                            ["factName"] = self.scene.conditionFact or "",
                            ["value"] = self.scene.conditionValue or 0,
                            ["comparisonType"] = self.comparisonEnums[(self.scene.conditionComparison or 0) + 1]
                        }
                    }
                }
            }
        end

        table.insert(scenes, { ["Data"] = scene })
    end

    for _, workspot in ipairs(self.workspots) do
        table.insert(workspots, {
            ["$type"] = "NodeRef",
            ["$storage"] = "string",
            ["$value"] = workspot
        })
    end

    data.data.conversationGroups = groups
    data.data.conversationResources = resources
    data.data.conversations = scenes
    data.data.savingStrategy = self.savingStrategyEnums[self.savingStrategy + 1]
    data.data.workspots = workspots

    return data
end

return conversationArea
