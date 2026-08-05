local config = require("modules/utils/config")
local utils = require("modules/utils/utils")
local gameUtils = require("modules/utils/gameUtils")
local style = require("modules/ui/style")
local settings = require("modules/utils/settings")
local amm = require("modules/utils/ammUtils")
local history = require("modules/utils/history")
local field = require("modules/utils/field")
local colorUtil = require("modules/utils/color")
local projectTagUtil = require("modules/utils/ui/projectTag")
local ammImportReportPopup = require("modules/utils/ui/ammImportReportPopup")
local ammImportPresetPopup = require("modules/utils/ui/ammImportPresetPopup")
local groupLoadManager = require("modules/utils/pipeline/groupLoadManager")
local groupAMMImportManager = require("modules/utils/pipeline/groupAMMImportManager")
local pipelineCommon = require("modules/utils/pipeline/common")
local backup = require("modules/utils/backup")
local sessionSnapshot = require("modules/utils/pipeline/sessionSnapshot")
local sessionRestorePopup = require("modules/utils/ui/sessionRestorePopup")
local saveState = require("modules/utils/saveState")
local projectFiles = require("modules/utils/projectFiles")
local element = require("modules/classes/editor/element")
local logger = require("modules/utils/logger")

local PROJECT_NEUTRAL_KEY = "__no_project__"
local PROJECT_NEUTRAL_LABEL = "No Project"

savedUI = {
    filter = "",
    color = {group = {0, 255, 0}, object = {0, 50, 255}},
    box = {group = {x = 600, y = 116}, object = {x = 600, y = 133}},
    files = {},
    invalidFiles = {},
    corruptedColor = 0xFF00A5FF,
    spawner = nil,
    popup = false,
    deleteFile = nil,
    popupDontAskAgain = false,
    spawned = {},
    maxTextWidth = nil,
    pendingReload = false,
    pendingGroupOpenState = nil,
    projectSectionOpenState = {},
    projectSectionRestoreOpenState = {},
    groupOpenState = {},
    projectSectionEditorState = {},
    projectSectionIconSearch = {},
    groupProjectCreateState = {},
    groupProjectIconSearch = {},
    pendingGroupProjectPopupId = nil,
    ---Live text of the "Group name" and "File name" fields, keyed by file name.
    ---
    ---Kept here rather than on the cached entry: the entry table is the file's content, which
    ---auto-save refreshes underneath the UI, and edit state living on it used to survive those
    ---refreshes and end up showing a name the file no longer had.
    ---@type table<string, {name: string, fileName: string, error: string?}>
    entryEditState = {},
    ---File names whose cached entry still renders correctly but whose `childs` tree is older than the
    ---file, because auto-save wrote it without holding the document in memory. See `getEntryData`.
    stalePayloads = {}
}

---@param group table
---@param spawner spawner
---@param loadHidden boolean?
---@param fileName string? File in `data/objects/` this group comes from. Binds it for auto-save.
function savedUI.startQueuedGroupLoad(group, spawner, loadHidden, fileName)
    local hidden = loadHidden == true

    sessionSnapshot.consume("loaded a project")

    groupLoadManager.start({
        spawner = spawner,
        data = group,
        targetParent = spawner.baseUI.spawnedUI.root,
        setAsSpawnNew = settings.setLoadedGroupAsSpawnNew and not hidden,
        loadHidden = hidden,
        projectFile = fileName
    })
end

---@param entry {fileName: string, data: table}
---@return string
local function getEntrySortName(entry)
    local data = entry and entry.data or nil
    if type(data) == "table" and type(data.name) == "string" and data.name ~= "" then
        return data.name:lower()
    end

    return tostring(entry and entry.fileName or ""):lower()
end

---@param a {fileName: string, data: table}
---@param b {fileName: string, data: table}
---@return boolean
local function compareSavedEntriesByName(a, b)
    local nameA = getEntrySortName(a)
    local nameB = getEntrySortName(b)

    if nameA == nameB then
        return tostring(a.fileName):lower() < tostring(b.fileName):lower()
    end

    return nameA < nameB
end

---@param group table?
---@return table?
local function getGroupProject(group)
    return projectTagUtil.normalizeProject(group and group.project)
end

---@param group table
---@param project table?
local function setGroupProject(group, project)
    local normalized = projectTagUtil.normalizeProject(project)
    if normalized then
        group.project = {
            name = normalized.name,
            icon = normalized.icon,
            color = { normalized.color[1], normalized.color[2], normalized.color[3] }
        }
    else
        group.project = nil
    end
end

local function hasSavedGroups()
    for _, data in pairs(savedUI.files) do
        if utils.isSerializedGroupStrict(data) then
            return true
        end
    end

    return false
end

---@param pos table?
---@return boolean
local function isPositionValid(pos)
    return type(pos) == "table"
        and type(pos.x) == "number"
        and type(pos.y) == "number"
        and type(pos.z) == "number"
end

---@param fileName string
---@param data any
---@return boolean
local function validateSavedEntry(fileName, data)
    if type(data) ~= "table" then
        savedUI.invalidFiles[fileName] = true
        return false
    end

    if type(data.name) ~= "string" or data.name == "" then
        savedUI.invalidFiles[fileName] = true
        return false
    end

    if utils.isSerializedGroupStrict(data) then
        if type(data.childs) ~= "table" or not isPositionValid(data.pos) then
            savedUI.invalidFiles[fileName] = true
            return false
        end

        savedUI.invalidFiles[fileName] = nil
        return true
    end

    if utils.isSerializedSpawnableStrict(data) then
        if type(data.spawnable) ~= "table" or not isPositionValid(data.spawnable.position) then
            savedUI.invalidFiles[fileName] = true
            return false
        end

        savedUI.invalidFiles[fileName] = nil
        return true
    end

    savedUI.invalidFiles[fileName] = true
    return false
end

---@param fileName string
local function loadSavedEntry(fileName)
    local data = config.loadFile("data/objects/" .. fileName)

    if validateSavedEntry(fileName, data) then
        savedUI.files[fileName] = data
    else
        savedUI.files[fileName] = nil
    end
end

---@param fileName string
---@param data table?
---@return boolean
function savedUI.refreshEntry(fileName, data)
    if type(fileName) ~= "string" or fileName == "" then
        return false
    end

    if data ~= nil then
        savedUI.stalePayloads[fileName] = nil

        if validateSavedEntry(fileName, data) then
            savedUI.files[fileName] = data
            return true
        end

        savedUI.files[fileName] = nil
        return false
    end

    savedUI.stalePayloads[fileName] = nil

    local fullPath = "data/objects/" .. fileName
    if not config.fileExists(fullPath) then
        savedUI.files[fileName] = nil
        savedUI.invalidFiles[fileName] = nil
        return false
    end

    loadSavedEntry(fileName)
    return savedUI.files[fileName] ~= nil
end

---Patches the cached entry for a file that was just rewritten, using only the top-level facts this
---tab displays, and flags the entry's tree as no longer matching the file.
---
---`refreshEntry` needs the entire decoded document, and passing `nil` makes it re-read from disk --
---either is unacceptable for auto-save, which streams the document straight to the file and never
---holds it in memory. The fields below are everything the Projects tab renders for a collapsed entry;
---`childs` is left untouched and therefore stale, hence the flag. See `savedUI.getEntryData`.
---@param fileName string
---@param summary table `{ name, elementCount, lastEditedAt, pos, project, childs }`
---@return boolean updated
function savedUI.refreshEntryShallow(fileName, summary)
    if type(fileName) ~= "string" or fileName == "" or type(summary) ~= "table" then
        return false
    end

    local entry = savedUI.files[fileName]
    if not entry then
        -- Not cached yet (or previously invalid): fall back to a normal read so the tab still updates.
        return savedUI.refreshEntry(fileName, nil)
    end

    entry.name = summary.name or entry.name
    entry.lastEditedAt = summary.lastEditedAt or entry.lastEditedAt
    entry.elementCount = summary.elementCount or entry.elementCount
    entry.project = summary.project
    if summary.pos then
        entry.pos = summary.pos
    end

    savedUI.stalePayloads[fileName] = true

    return true
end

---Returns a cached entry that is safe to use as *content*, re-reading it from disk when auto-save has
---moved past what is in memory.
---
---`savedUI.files` serves two jobs: it backs what this tab renders, and it is the source both for
---loading a project into the Spawned tab and for writing one back (rename, project tag). Auto-save
---never materialises the whole document -- it streams the rope straight into the file -- so it can
---only patch the display fields. Anything that needs the actual tree has to come through here, or it
---would load a version older than the file, or worse, save that older version back over it.
---
---Re-reading is only paid for files auto-save has actually touched, and only when something asks for
---their contents.
---@param fileName string
---@return table? entry
function savedUI.getEntryData(fileName)
    if type(fileName) ~= "string" or fileName == "" then
        return nil
    end

    if savedUI.stalePayloads[fileName] then
        savedUI.stalePayloads[fileName] = nil

        local entry = savedUI.files[fileName]
        local fresh = config.loadFile("data/objects/" .. fileName)

        if entry and type(fresh) == "table" and fresh.name then
            -- Refreshed in place rather than swapped: this tab hands entries around by reference
            -- (drawGroup receives one as an argument), so replacing the table would leave the caller
            -- holding a detached copy for the rest of the frame.
            --
            -- `newName` is the live rename field, not file content, and it lives on this same table.
            -- Wiping it here left the rename handler concatenating a nil the moment it refreshed an
            -- auto-saved entry, so it is carried across.
            local editedName = entry.newName

            for key in pairs(entry) do
                entry[key] = nil
            end
            for key, value in pairs(fresh) do
                entry[key] = value
            end

            entry.newName = editedName or entry.name
        else
            loadSavedEntry(fileName)
        end
    end

    return savedUI.files[fileName]
end

---Permanent way back into the previous session's backup.
---
---The banner in the Spawned tab disappears as soon as work starts, which is right for the common
---case but strands anyone who accidentally spawns one prop before restoring. This one never
---disappears. It always targets the run before this one -- the snapshot the current run is building
---only becomes reachable after a restart.
function savedUI.drawSessionRestoreEntry()
    if not config.fileExists(sessionSnapshot.previousPath) then
        return
    end

    ImGui.Dummy(0, 4 * style.viewSize)

    local restoreBlocked = sessionRestorePopup.isBlocked()
    style.pushGreyedOut(restoreBlocked)
    if ImGui.Button(IconGlyphs.BackupRestore .. " Restore previous session##savedUIRestoreSession")
        and not restoreBlocked then
        sessionRestorePopup.requestOpen()
    end
    style.popGreyedOut(restoreBlocked)
    style.tooltip("Pick what to bring back from the session before this one.\nRestored items are added alongside what is already open; nothing on disk is overwritten.")
end

---@param source "on_save"|"on_game_load"
---@param fileName string
local function queueBackupRestore(source, fileName)
    local sourceLabel = source == "on_save" and "previous save" or "game load"

    if backup.restoreObjectBackup(source, fileName) then
        savedUI.pendingReload = true
        ImGui.ShowToast(ImGui.Toast.new(pipelineCommon.resolveToastType("success"), 5000, string.format("Restored \"%s\" from %s", fileName, sourceLabel)))
    else
        ImGui.ShowToast(ImGui.Toast.new(pipelineCommon.resolveToastType("error"), 5000, string.format("Failed to restore \"%s\" from %s", fileName, sourceLabel)))
    end
end

---@param source "on_save"|"on_game_load"
---@param label string
---@param fileName string
local function drawBackupRestoreAction(source, label, fileName)
    local exists, timestamp = backup.getObjectBackupInfo(source, fileName)
    local displayTimestamp = timestamp

    style.pushGreyedOut(not exists)
    if ImGui.Button(label .. "##" .. source) and exists then
        queueBackupRestore(source, fileName)
    end
    style.popGreyedOut(not exists)

    if type(displayTimestamp) ~= "string" or displayTimestamp == "" then
        displayTimestamp = "Unknown"
    end

    ImGui.SameLine()
    style.mutedText(displayTimestamp)
end

---@param fileName string
local function drawBackupRestoreActions(fileName)
    ImGui.Dummy(0, 4 * style.viewSize)
    style.sectionHeaderStart("BACKUP")
    drawBackupRestoreAction("on_save", "Restore previous save", fileName)
    drawBackupRestoreAction("on_game_load", "Restore from game load", fileName)
end

---@param fileName string
---@param tagX number
local function drawCorruptedEntry(fileName, tagX)
    style.pushStyleColor(true, ImGuiCol.Text, savedUI.corruptedColor)
    local open = ImGui.TreeNodeEx(fileName)
    style.popStyleColor(true)

    ImGui.SameLine()
    ImGui.SetCursorPosX(tagX)
    style.styledText("CORRUPTED", savedUI.corruptedColor, 0.9)

    if open then
        style.styledText("Cannot parse this save file.", savedUI.corruptedColor, 0.9)

        ImGui.PushID("corruptedBackup" .. fileName)
        drawBackupRestoreActions(fileName)
        ImGui.PopID()

        ImGui.TreePop()
        ImGui.Spacing()
    end
end

local function syncSavedFileCaches()
    local existing = {}

    for _, file in pairs(dir("data/objects")) do
        if file.name:match("^.+(%..+)$") == ".json" then
            existing[file.name] = true

            if not savedUI.files[file.name] and savedUI.invalidFiles[file.name] == nil then
                loadSavedEntry(file.name)
            end
        end
    end

    for fileName, _ in pairs(savedUI.files) do
        if not existing[fileName] then
            savedUI.files[fileName] = nil
            savedUI.groupOpenState[fileName] = nil
            savedUI.stalePayloads[fileName] = nil
        end
    end

    for fileName, _ in pairs(savedUI.invalidFiles) do
        if not existing[fileName] then
            savedUI.invalidFiles[fileName] = nil
        end
    end
end

---@param group table
---@return number
local function getSavedGroupElementCount(group)
    if group.elementCount ~= nil then
        return group.elementCount
    end

    local count = 0
    local stack = { group }

    while #stack > 0 do
        local current = table.remove(stack)

        for _, child in pairs(current.childs or {}) do
            if utils.isSerializedSpawnableStrict(child) then
                count = count + 1
            elseif utils.isSerializedGroupStrict(child) then
                table.insert(stack, child)
            end
        end
    end

    group.elementCount = count
    return count
end

---@param filter string
---@param data table
---@param fileName string?
---@return boolean
local function matchesSavedFilter(filter, data, fileName)
    if not data or type(data.name) ~= "string" then
        return false
    end

    if utils.matchSearch(data.name, filter) then
        return true
    end

    -- Searchable by file name too: it is the id users are given everywhere else (tooltips, the
    -- context menu, backups), so it has to be a way back to the entry.
    return fileName ~= nil and utils.matchSearch(fileName, filter)
end

---@param fileName string
---@param data table
---@param updateTimestamp boolean?
---@return boolean
local function saveSavedEntry(fileName, data, updateTimestamp)
    if not fileName or fileName == "" or type(data) ~= "table" then
        return false
    end

    if updateTimestamp ~= false then
        data.lastEditedAt = os.date("%Y-%m-%d %H:%M:%S")
    end

    local ok = config.saveFile("data/objects/" .. fileName, data)
    if ok then
        savedUI.files[fileName] = data
        savedUI.invalidFiles[fileName] = nil
        -- The file is now exactly this table again, so whatever auto-save had written is superseded.
        savedUI.stalePayloads[fileName] = nil
    end

    return ok
end

---@param fileName string
---@param group table
---@param project table?
---@param showToast boolean?
---@return boolean
local function assignProjectToGroup(fileName, group, project, showToast)
    -- This writes the whole cached entry back to disk, so it must not be holding a tree that
    -- auto-save has already moved past -- that would silently revert the saved content.
    savedUI.getEntryData(fileName)

    local existing = getGroupProject(group)
    local nextProject = projectTagUtil.normalizeProject(project)

    local unchanged = (existing == nil and nextProject == nil)
    if not unchanged and existing and nextProject then
        unchanged = existing.name == nextProject.name
            and existing.icon == nextProject.icon
            and existing.color[1] == nextProject.color[1]
            and existing.color[2] == nextProject.color[2]
            and existing.color[3] == nextProject.color[3]
    end

    if unchanged then
        return true
    end

    setGroupProject(group, nextProject)
    local saved = saveSavedEntry(fileName, group, true)

    if saved and showToast then
        local target = nextProject and ("project \"" .. nextProject.name .. "\"") or "No Project"
        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Assigned \"%s\" to %s", group.name, target)))
    elseif not saved and showToast then
        ImGui.ShowToast(ImGui.Toast.new(pipelineCommon.resolveToastType("error"), 4000, string.format("Failed to update project for \"%s\"", group.name)))
    end

    return saved
end

---@param key string
---@param groups {fileName: string, data: table}[]
---@param project table?
---@param showToast boolean?
local function applyProjectToSectionGroups(key, groups, project, showToast)
    local applied = 0
    local failures = 0
    local normalized = projectTagUtil.normalizeProject(project)
    local newKey = normalized and projectTagUtil.normalizeNameKey(normalized.name) or PROJECT_NEUTRAL_KEY
    local previousSectionOpen = savedUI.projectSectionOpenState[key]

    for _, entry in ipairs(groups or {}) do
        local saved = assignProjectToGroup(entry.fileName, entry.data, normalized, false)
        if saved then
            applied = applied + 1
        else
            failures = failures + 1
        end
    end

    if not showToast then
        if previousSectionOpen ~= nil and newKey ~= key then
            savedUI.projectSectionOpenState[newKey] = previousSectionOpen
        end
        return
    end

    if previousSectionOpen ~= nil and newKey ~= key then
        savedUI.projectSectionOpenState[newKey] = previousSectionOpen
    end

    if failures == 0 then
        if normalized then
            ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 3000, string.format("Updated project \"%s\" on %d group%s", normalized.name, applied, applied == 1 and "" or "s")))
        elseif key == PROJECT_NEUTRAL_KEY then
            ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 3000, string.format("Moved %d group%s to %s", applied, applied == 1 and "" or "s", PROJECT_NEUTRAL_LABEL)))
        end
    else
        ImGui.ShowToast(ImGui.Toast.new(pipelineCommon.resolveToastType("error"), 4000, string.format("Project update incomplete (%d updated, %d failed)", applied, failures)))
    end
end

---@param allGroups {fileName: string, data: table}[]
---@return table<string, table>, table[]
local function collectProjectCatalog(allGroups)
    local projectMap = {}
    local projectOptions = {}

    for _, entry in ipairs(allGroups) do
        local project = getGroupProject(entry.data)
        if project then
            local key = projectTagUtil.normalizeNameKey(project.name)
            if key ~= "" then
                if not projectMap[key] then
                    projectMap[key] = {
                        key = key,
                        project = project,
                        groups = {}
                    }
                end

                table.insert(projectMap[key].groups, entry)
            end
        end
    end

    for _, bucket in pairs(projectMap) do
        table.insert(projectOptions, bucket)
    end

    table.sort(projectOptions, function(a, b)
        local nameA = a.project.name:lower()
        local nameB = b.project.name:lower()
        if nameA == nameB then
            return a.key < b.key
        end
        return nameA < nameB
    end)

    return projectMap, projectOptions
end

---Returns the catalog of existing project tags gathered from all saved groups.
---Used by other UIs (e.g. Settings) to offer existing projects for selection.
---@return table<string, table> projectMap
---@return table[] projectOptions
function savedUI.getProjectCatalog()
    local allGroups = {}
    for fileName, data in pairs(savedUI.files) do
        if utils.isSerializedGroupStrict(data) then
            table.insert(allGroups, { fileName = fileName, data = data })
        end
    end

    return collectProjectCatalog(allGroups)
end

---@param filteredGroups {fileName: string, data: table}[]
---@return table[]
local function buildProjectSections(filteredGroups)
    local sections = {
        {
            key = PROJECT_NEUTRAL_KEY,
            isNeutral = true,
            project = {
                name = PROJECT_NEUTRAL_LABEL,
                icon = projectTagUtil.DEFAULT_ICON,
                color = { projectTagUtil.DEFAULT_COLOR[1], projectTagUtil.DEFAULT_COLOR[2], projectTagUtil.DEFAULT_COLOR[3] }
            },
            groups = {}
        }
    }
    local sectionByKey = {
        [PROJECT_NEUTRAL_KEY] = sections[1]
    }

    for _, entry in ipairs(filteredGroups) do
        local project = getGroupProject(entry.data)
        local key = project and projectTagUtil.normalizeNameKey(project.name) or PROJECT_NEUTRAL_KEY
        if key == "" then
            key = PROJECT_NEUTRAL_KEY
            project = nil
        end

        local section = sectionByKey[key]
        if not section then
            section = {
                key = key,
                isNeutral = false,
                project = project,
                groups = {}
            }
            sectionByKey[key] = section
            table.insert(sections, section)
        end

        if section.project == nil and project ~= nil then
            section.project = project
        end

        table.insert(section.groups, entry)
    end

    table.sort(sections, function(a, b)
        if a.isNeutral ~= b.isNeutral then
            return a.isNeutral
        end

        local aName = ((a.project and a.project.name) or ""):lower()
        local bName = ((b.project and b.project.name) or ""):lower()

        if aName == bName then
            return a.key < b.key
        end

        return aName < bName
    end)

    for _, section in ipairs(sections) do
        table.sort(section.groups, compareSavedEntriesByName)
    end

    return sections
end

---@param fileName string Project uID of the entry being deleted.
---@param data table
---@return integer removed
local function removeFromExportListIfPresent(fileName, data)
    if not utils.isSerializedGroupStrict(data) then
        return 0
    end

    local baseUI = savedUI.spawner and savedUI.spawner.baseUI
    if not baseUI or not baseUI.exportUI or not baseUI.exportUI.removeGroupByFile then
        return 0
    end

    return baseUI.exportUI.removeGroupByFile(fileName)
end

local function showDeletedGroupToast(data, removedFromExport)
    if not utils.isSerializedGroupStrict(data) then
        return
    end

    local msg = string.format("Deleted saved group \"%s\"", data.name)
    if removedFromExport > 0 then
        msg = msg .. " and removed it from export list"
    end

    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, msg))
end

function savedUI.convertObject(object, getState)
    local spawnable = require("modules/classes/spawn/entity/entityTemplate"):new()
    spawnable:loadSpawnData({
        spawnData = object.path,
        app = object.app
    }, ToVector4(object.pos), ToEulerAngles(object.rot))

    local newObject = require("modules/classes/editor/spawnableElement"):new(savedUI)
    newObject.name = object.name
    newObject.headerOpen = object.headerOpen
    newObject.loadRange = object.loadRange
    newObject.autoLoad = object.autoLoad
    newObject.spawnable = spawnable

    if getState then
        return newObject:serialize()
    else
        return newObject
    end
end

function savedUI.convertGroup(group)
    local data = {}

    for _, child in pairs(group.childs) do
        if child.type == "object" then
            table.insert(data, savedUI.convertObject(child, true))
        else
            table.insert(data, savedUI.convertGroup(child))
        end
    end

    group.childs = data
    return group
end

function savedUI.backwardComp()
    for _, file in pairs(dir("data/objects")) do
        if file.name:match("^.+(%..+)$") == ".json" then
            local data = config.loadFile("data/objects/" .. file.name)

            if data.type == "object" and data.path then
                config.saveFile("data/oldFormat/" .. file.name, data)

                local new = savedUI.convertObject(data, true)
                config.saveFile("data/objects/" .. file.name, new)
                logger:warn("Converted \"" .. file.name .. "\" to the new file format.")
            elseif data.type == "group" and not data.isUsingSpawnables then
                config.saveFile("data/oldFormat/" .. file.name, data)

                data = savedUI.convertGroup(data)
                data.isUsingSpawnables = true
                config.saveFile("data/objects/" .. file.name, data)
                logger:warn("Converted \"" .. file.name .. "\" to the new file format.")
            end
        end
    end
end

---@param selectedPresetFiles table?
---@return boolean
function savedUI.importAMMPresets(selectedPresetFiles)
    if ammImportPresetPopup.isBlocked() then
        return false
    end

    return groupAMMImportManager.start({
        savedUI = savedUI,
        selectedPresetFiles = selectedPresetFiles
    })
end

---Returns the live edit state of one entry's name fields, seeded from what is on disk.
---@param fileName string
---@param data table
---@return {name: string, fileName: string, error: string?}
local function getEntryEditState(fileName, data)
    local state = savedUI.entryEditState[fileName]

    if not state then
        state = {
            name = tostring(data.name or ""),
            fileName = projectFiles.stripExtension(fileName)
        }
        savedUI.entryEditState[fileName] = state
    end

    return state
end

---Moves the per-file UI state of an entry to a new file name, so a rename does not reset how the
---entry was folded or which popup it had open.
---@param oldFileName string
---@param newFileName string
local function moveEntryUIState(oldFileName, newFileName)
    for _, map in ipairs({
        savedUI.files,
        savedUI.groupOpenState,
        savedUI.stalePayloads,
        savedUI.invalidFiles,
        savedUI.entryEditState,
        savedUI.groupProjectCreateState,
        savedUI.groupProjectIconSearch
    }) do
        map[newFileName] = map[oldFileName]
        map[oldFileName] = nil
    end
end

---Renames the group inside a project file, without touching the file itself.
---@param fileName string
---@param data table Cached entry, refreshed by the caller.
---@param newName string
---@return boolean ok
local function renameSavedGroup(fileName, data, newName)
    local cleaned = element.sanitizeDisplayName(newName)
    if cleaned == "" or cleaned == data.name then
        return false
    end

    local previousName = data.name
    data.name = cleaned

    if not saveSavedEntry(fileName, data, true) then
        data.name = previousName
        ImGui.ShowToast(ImGui.Toast.new(pipelineCommon.resolveToastType("error"), 4000,
            string.format("Failed to rename \"%s\"", tostring(previousName))))
        return false
    end

    local baseUI = savedUI.spawner and savedUI.spawner.baseUI
    if baseUI and baseUI.exportUI and baseUI.exportUI.renameGroupByFile then
        -- The export list shows the group's name, and the exported sector names are derived from it.
        baseUI.exportUI.renameGroupByFile(fileName, cleaned)
    end

    -- A project open in the Spawned tab is the same project: renaming it here has to reach the live
    -- group too, or the next save would write the old name straight back over this one.
    --
    -- Through `rename` rather than by assignment, so it goes through the same rules as renaming in
    -- the hierarchy: sibling-unique names (root names have to stay distinct -- the session snapshot
    -- keys its payload by them), cache invalidation, and an undo entry.
    local spawned = saveState.findRootChildByUID(fileName)
    if spawned and spawned.name ~= cleaned then
        spawned:rename(cleaned)
    end

    return true
end

---Renames the file a project lives in, keeping the group's own name as it is.
---@param fileName string Current file name including extension.
---@param newBaseName string File name typed by the user, without extension.
---@return string? newFileName The new file name, when the rename went through.
---@return string? error
local function renameSavedFile(fileName, newBaseName)
    local newFileName = projectFiles.withExtension(projectFiles.stripExtension(newBaseName))

    if newFileName == fileName then
        return nil
    end

    local valid, err = projectFiles.validateFileName(newFileName, fileName)
    if not valid then
        return nil, err
    end

    -- Anything auto-save wrote but this tab has not read yet has to be picked up before the file
    -- moves, or the cached entry would be attached to the new name while holding older content.
    savedUI.getEntryData(fileName)

    local renamed, renameErr = projectFiles.rename(fileName, newFileName)
    if not renamed then
        return nil, renameErr
    end

    moveEntryUIState(fileName, newFileName)

    -- The uID *is* the file name, so the live group has to follow it. Its content is unaffected --
    -- the same bytes simply live under a new name now.
    local spawned = saveState.retargetProjectUID(fileName, newFileName)
    if spawned then
        logger:info(string.format("[SavedUI] \"%s\" now writes to \"%s\"", tostring(spawned.name), newFileName))
    end

    local baseUI = savedUI.spawner and savedUI.spawner.baseUI
    if baseUI and baseUI.exportUI and baseUI.exportUI.retargetGroupFile then
        baseUI.exportUI.retargetGroupFile(fileName, newFileName)
    end

    backup.invalidateInfoCache()

    return newFileName
end

---@param fileName string
---@param group table
local function primeGroupProjectCreateState(fileName, group)
    local current = getGroupProject(group)
    savedUI.groupProjectCreateState[fileName] = {
        name = "",
        icon = current and current.icon or projectTagUtil.DEFAULT_ICON,
        color = projectTagUtil.normalizeColor(current and current.color or nil)
    }
    savedUI.groupProjectIconSearch[fileName] = savedUI.groupProjectIconSearch[fileName] or ""
end

---@param group table
---@param fileName string
---@param projectMap table<string, table>
---@param projectOptions table[]
local function drawGroupProjectAssignment(group, fileName, projectMap, projectOptions)
    local currentProject = getGroupProject(group)
    local currentKey = currentProject and projectTagUtil.normalizeNameKey(currentProject.name) or PROJECT_NEUTRAL_KEY
    local previewText = PROJECT_NEUTRAL_LABEL
    local previewIcon = IconGlyphs[projectTagUtil.DEFAULT_ICON] or ""

    if currentProject then
        previewText = currentProject.name
        previewIcon = IconGlyphs[currentProject.icon] or IconGlyphs[projectTagUtil.DEFAULT_ICON] or ""
    end

    style.mutedText("Project")
    ImGui.SameLine()
    ImGui.SetCursorPosX(savedUI.maxTextWidth)
    ImGui.SetNextItemWidth(180 * style.viewSize)

    local comboSelectionApplied = false
    if ImGui.BeginCombo("##groupProjectAssign" .. fileName, previewIcon .. " " .. previewText) then
        local neutralSelected = currentKey == PROJECT_NEUTRAL_KEY
        if ImGui.Selectable((IconGlyphs[projectTagUtil.DEFAULT_ICON] or "") .. " " .. PROJECT_NEUTRAL_LABEL, neutralSelected)
            and currentKey ~= PROJECT_NEUTRAL_KEY then
            assignProjectToGroup(fileName, group, nil, true)
            comboSelectionApplied = true
            ImGui.CloseCurrentPopup()
        end

        if not comboSelectionApplied then
            for _, option in ipairs(projectOptions) do
                local selected = currentKey == option.key
                local icon = IconGlyphs[option.project.icon] or IconGlyphs[projectTagUtil.DEFAULT_ICON] or ""
                local label = string.format("%s %s##projectOption%s", icon, option.project.name, option.key)

                if ImGui.Selectable(label, selected) and currentKey ~= option.key then
                    assignProjectToGroup(fileName, group, option.project, true)
                    comboSelectionApplied = true
                    ImGui.CloseCurrentPopup()
                    break
                end
            end
        end

        if not comboSelectionApplied then
            ImGui.Separator()
            local plusIcon = IconGlyphs.Plus or "+"
            if ImGui.Selectable(string.format("%s Create new project tag...##createProject%s", plusIcon, fileName), false) then
                primeGroupProjectCreateState(fileName, group)
                savedUI.pendingGroupProjectPopupId = "##groupCreateProjectPopup" .. fileName
            end
        end

        ImGui.EndCombo()
    end

    if comboSelectionApplied then
        return
    end

    ImGui.SameLine()
    style.pushGreyedOut(currentProject == nil)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Close .. "##groupProjectClear" .. fileName) and currentProject ~= nil then
        assignProjectToGroup(fileName, group, nil, true)
    end
    style.pushButtonNoBG(false)
    style.popGreyedOut(currentProject == nil)
    style.tooltip("Remove project attribution")

    local popupId = "##groupCreateProjectPopup" .. fileName
    if savedUI.pendingGroupProjectPopupId == popupId then
        ImGui.OpenPopup(popupId)
        savedUI.pendingGroupProjectPopupId = nil
    end

    local editor = savedUI.groupProjectCreateState[fileName]
    if not editor then
        primeGroupProjectCreateState(fileName, group)
        editor = savedUI.groupProjectCreateState[fileName]
    end

    if ImGui.BeginPopup(popupId) then
        style.mutedText("Create project tag for this group")
        ImGui.Separator()

        ImGui.SetNextItemWidth(220 * style.viewSize)
        editor.name, _ = ImGui.InputTextWithHint("##newGroupProjectName" .. fileName, "Project name...", editor.name or "", 100)

        editor.icon, savedUI.groupProjectIconSearch[fileName], _ = field.drawIconSelector("savedGroupProject:" .. fileName, editor.icon, savedUI.groupProjectIconSearch[fileName])
        ImGui.SameLine()
        editor.color, _ = style.trackedColor(nil, "##newGroupProjectColor" .. fileName, editor.color, 58)

        local normalizedName = projectTagUtil.normalizeNameKey(editor.name)
        local existingProject = projectMap[normalizedName]
        if existingProject then
            style.mutedText("Existing project name detected. Assignment will reuse the existing shared project data.")
        end

        ImGui.Dummy(0, 8 * style.viewSize)
        local canAssign = projectTagUtil.trimText(editor.name) ~= ""
        style.pushGreyedOut(not canAssign)
        if ImGui.Button("Assign") and canAssign then
            local targetProject = existingProject and existingProject.project or {
                name = editor.name,
                icon = editor.icon,
                color = editor.color
            }

            assignProjectToGroup(fileName, group, targetProject, true)
            ImGui.CloseCurrentPopup()
        end
        style.popGreyedOut(not canAssign)

        ImGui.SameLine()
        if ImGui.Button("Cancel##groupProjectCreateCancel" .. fileName) then
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end
end

---@param section table
---@return table
local function getSectionProjectEditorState(section)
    local editor = savedUI.projectSectionEditorState[section.key]
    if not editor then
        editor = {
            name = section.project.name,
            icon = section.project.icon,
            color = projectTagUtil.normalizeColor(section.project.color)
        }
        savedUI.projectSectionEditorState[section.key] = editor
    end

    return editor
end

---@param section table
---@param spawner spawner
---@param projectMap table<string, table>
---@param buttonTextColor number[]
---@return boolean actionButtonClicked
local function drawProjectSectionActions(section, spawner, projectMap, buttonTextColor)
    if section.isNeutral then
        return false
    end

    local actionButtonClicked = false
    local popupId = "##savedProjectEditPopup" .. section.key
    local editor = getSectionProjectEditorState(section)

    if not ImGui.IsPopupOpen(popupId) then
        editor.name = section.project.name
        editor.icon = section.project.icon
        editor.color = projectTagUtil.normalizeColor(section.project.color)
    end

    ImGui.SameLine()
    local exportIcon = IconGlyphs.Export
    local editIcon = IconGlyphs.CogOutline
    local exportWidth, _ = ImGui.CalcTextSize(exportIcon)
    local editWidth, _ = ImGui.CalcTextSize(editIcon)
    local exportButtonWidth = exportWidth + ImGui.GetStyle().FramePadding.x * 2
    local editButtonWidth = editWidth + ImGui.GetStyle().FramePadding.x * 2
    local buttonsWidth = exportButtonWidth + ImGui.GetStyle().ItemSpacing.x + editButtonWidth
    local scrollBarAddition = ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0
    local cursorX = ImGui.GetWindowWidth() - buttonsWidth - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()
    ImGui.SetCursorPosX(cursorX)
    ImGui.SetNextItemAllowOverlap()
    style.pushButtonNoBG(true)
    ImGui.PushStyleColor(ImGuiCol.Text, buttonTextColor[1], buttonTextColor[2], buttonTextColor[3], buttonTextColor[4] or 1)

    if ImGui.Button(exportIcon .. "##savedProjectExportButton" .. section.key) then
        actionButtonClicked = true
        local exportUI = spawner.baseUI.exportUI
        local projectGroups = (projectMap[section.key] and projectMap[section.key].groups) or section.groups

        exportUI.projectName = section.project.name
        for _, entry in ipairs(projectGroups) do
            exportUI.addGroup(entry.data.name, entry.fileName)
        end

        spawner.baseUI.selectTab("export")
    end
    style.tooltip("Add all project groups to the export list")

    ImGui.SameLine()
    ImGui.SetNextItemAllowOverlap()
    if ImGui.Button(editIcon .. "##savedProjectEditButton" .. section.key) then
        actionButtonClicked = true
        ImGui.OpenPopup(popupId)
    end
    ImGui.PopStyleColor()
    style.pushButtonNoBG(false)
    style.tooltip("Edit project tag")

    if ImGui.BeginPopup(popupId) then
        style.mutedText("Project tag")
        ImGui.Separator()

        ImGui.SetNextItemWidth(220 * style.viewSize)
        editor.name, _ = ImGui.InputTextWithHint("##savedProjectName" .. section.key, "Project name...", editor.name, 100)

        editor.icon, savedUI.projectSectionIconSearch[section.key], _ =
            field.drawIconSelector("savedProjectSection:" .. section.key, editor.icon, savedUI.projectSectionIconSearch[section.key])
        ImGui.SameLine()
        editor.color, _ = style.trackedColor(nil, "##savedProjectColor" .. section.key, editor.color, 58)

        local updatedProject = projectTagUtil.normalizeProject({
            name = editor.name,
            icon = editor.icon,
            color = editor.color
        })
        local canApply = updatedProject ~= nil

        ImGui.Dummy(0, 8 * style.viewSize)
        if not canApply then
            style.styledText("Project name is required.", 0xFF0000FF, 0.9)
        else
            style.mutedText("Project cannot be deleted. Move groups to \"" .. PROJECT_NEUTRAL_LABEL .. "\" to unassign.")
        end

        style.pushGreyedOut(not canApply)
        if ImGui.Button("Apply to all groups##savedProjectApply" .. section.key) and canApply then
            local targetGroups = (projectMap[section.key] and projectMap[section.key].groups) or section.groups
            applyProjectToSectionGroups(section.key, targetGroups, updatedProject, true)
        end
        style.popGreyedOut(not canApply)

        ImGui.SameLine()
        if ImGui.Button("Close##savedProjectClose" .. section.key) then
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end

    return actionButtonClicked
end

---@param section table
---@param spawner spawner
---@param projectMap table<string, table>
---@param projectOptions table[]
local function drawProjectSection(section, spawner, projectMap, projectOptions)
    if #section.groups == 0 then
        return
    end

    local sectionColor = colorUtil.normalizeRGB(section.project and section.project.color or nil, projectTagUtil.DEFAULT_COLOR)
    local textColor = colorUtil.readableTextColor(sectionColor, projectTagUtil.DEFAULT_MIN_CONTRAST_RATIO)
    local hoverAmount = textColor[1] > 0 and 0.08 or -0.08
    local activeAmount = textColor[1] > 0 and 0.14 or -0.14
    local hoverColor = colorUtil.adjustBrightness(sectionColor, hoverAmount)
    local activeColor = colorUtil.adjustBrightness(sectionColor, activeAmount)
    local icon = IconGlyphs[(section.project and section.project.icon) or projectTagUtil.DEFAULT_ICON] or ""
    local sectionName = (section.project and section.project.name) or PROJECT_NEUTRAL_LABEL
    local label = string.format("%s %s (%d)##savedProjectSection%s", icon, sectionName, #section.groups, section.key)

    local restoreSectionState = savedUI.projectSectionRestoreOpenState[section.key]
    if restoreSectionState ~= nil then
        ImGui.SetNextItemOpen(restoreSectionState, ImGuiCond.Always)
        savedUI.projectSectionRestoreOpenState[section.key] = nil
    elseif savedUI.pendingGroupOpenState ~= nil then
        ImGui.SetNextItemOpen(savedUI.pendingGroupOpenState, ImGuiCond.Always)
    elseif savedUI.projectSectionOpenState[section.key] ~= nil then
        ImGui.SetNextItemOpen(savedUI.projectSectionOpenState[section.key], ImGuiCond.Always)
    end

    local previousOpen = savedUI.projectSectionOpenState[section.key]

    ImGui.PushStyleColor(ImGuiCol.Header, sectionColor[1], sectionColor[2], sectionColor[3], 0.95)
    ImGui.PushStyleColor(ImGuiCol.HeaderHovered, hoverColor[1], hoverColor[2], hoverColor[3], 0.98)
    ImGui.PushStyleColor(ImGuiCol.HeaderActive, activeColor[1], activeColor[2], activeColor[3], 1.0)
    ImGui.PushStyleColor(ImGuiCol.Text, textColor[1], textColor[2], textColor[3], textColor[4])
    local openOnArrowFlag = ImGuiTreeNodeFlags.OpenOnArrow or 0
    local openOnDoubleClickFlag = ImGuiTreeNodeFlags.OpenOnDoubleClick or 0
    local allowOverlapFlag = ImGuiTreeNodeFlags.AllowItemOverlap or 0
    local sectionNodeFlags = ImGuiTreeNodeFlags.SpanFullWidth +
        ImGuiTreeNodeFlags.Framed +
        openOnArrowFlag +
        openOnDoubleClickFlag +
        allowOverlapFlag
    local open = ImGui.TreeNodeEx(label, sectionNodeFlags)
    ImGui.SetItemAllowOverlap()
    ImGui.PopStyleColor(4)

    local actionButtonClicked = drawProjectSectionActions(section, spawner, projectMap, textColor)

    if actionButtonClicked and previousOpen ~= nil and open ~= previousOpen then
        open = previousOpen
        savedUI.projectSectionRestoreOpenState[section.key] = previousOpen
    end

    savedUI.projectSectionOpenState[section.key] = open

    if open then
        for _, entry in ipairs(section.groups) do
            savedUI.drawGroup(entry.data, spawner, entry.fileName, projectMap, projectOptions)
        end

        ImGui.TreePop()
    end
end

function savedUI.draw(spawner)
    if not savedUI.maxTextWidth then
        savedUI.maxTextWidth = utils.getTextMaxWidth({"Group name", "File name", "Project", "Position"}) + 6 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    ImGui.PushItemWidth(200 * style.viewSize)
    savedUI.filter, changed = ImGui.InputTextWithHint('##Filter', 'Search for data...', savedUI.filter, 100)
    if changed then
        settings.savedUIFilter = savedUI.filter
        settings.save()
    end
    ImGui.PopItemWidth()

    if savedUI.filter ~= '' then
        ImGui.SameLine()

        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Close) then
            savedUI.filter = ''
            settings.savedUIFilter = savedUI.filter
            settings.save()
        end
        style.pushButtonNoBG(false)
    end

    ammImportReportPopup.syncAutoOpen()
    local hasImportReport = ammImportReportPopup.hasReport()
    local ammImportActive = groupAMMImportManager.isActive()
    local blockImport = ammImportPresetPopup.isBlocked()
    local framePaddingX = ImGui.GetStyle().FramePadding.x
    local itemSpacingX = ImGui.GetStyle().ItemSpacing.x
    local importActionText = ammImportActive and "Importing AMM Presets..." or "Import AMM Presets"
    local importLabel, importHiddenText = style.resolveActionLabel(IconGlyphs.FileImportOutline, importActionText, nil, nil, true)
    local reportLabel, reportHiddenText = style.resolveActionLabel(IconGlyphs.FileChartOutline, "View report", nil, nil, true)
    local importLabelWidth, _ = ImGui.CalcTextSize(importLabel)
    local reportLabelWidth, _ = ImGui.CalcTextSize(reportLabel)
    local reloadLabelWidth, _ = ImGui.CalcTextSize(IconGlyphs.Reload)
    local primaryActionWidth = importLabelWidth + framePaddingX * 2
    local reportActionWidth = reportLabelWidth + framePaddingX * 2
    local reloadActionWidth = reloadLabelWidth + framePaddingX * 2
    local topActionsWidth = primaryActionWidth + reportActionWidth + reloadActionWidth + itemSpacingX * 3

    ImGui.SameLine()
    ImGui.SetCursorPosX(ImGui.GetWindowWidth() - topActionsWidth)
    style.pushGreyedOut(blockImport)
    if ImGui.Button(importLabel .. "##savedUIImportAMMPresets") and not blockImport then
        ammImportPresetPopup.requestOpen()
    end
    style.popGreyedOut(blockImport)

    if groupLoadManager.isActive() then
        local tooltipText = "Import is disabled while a group is loading."
        if importHiddenText then
            style.tooltipActionLabel(importHiddenText, importHiddenText .. "\n" .. tooltipText)
        else
            style.tooltip(tooltipText)
        end
    elseif ammImportActive then
        local tooltipText = "AMM preset import is already running."
        if importHiddenText then
            style.tooltipActionLabel(importHiddenText, importHiddenText .. "\n" .. tooltipText)
        else
            style.tooltip(tooltipText)
        end
    elseif amm.importing then
        local tooltipText = "Another AMM operation is currently running."
        if importHiddenText then
            style.tooltipActionLabel(importHiddenText, importHiddenText .. "\n" .. tooltipText)
        else
            style.tooltip(tooltipText)
        end
    else
        local tooltipText = "Choose which presets to import from data/AMMImport.\nImport might take a bit, depending on size.\nThe initial spawn will lag.\nMight leave behind unwanted objects, so reloading a save is advised."
        if importHiddenText then
            style.tooltipActionLabel(importHiddenText, importHiddenText .. "\n" .. tooltipText)
        else
            style.tooltip(tooltipText)
        end
    end

    ImGui.SameLine()
    style.pushGreyedOut(not hasImportReport)
    if ImGui.Button(reportLabel .. "##savedUIImportReport") and hasImportReport then
        ammImportReportPopup.requestOpen()
    end
    style.popGreyedOut(not hasImportReport)
    if hasImportReport then
        if reportHiddenText then
            style.tooltipActionLabel(reportHiddenText, reportHiddenText .. "\nOpen the latest AMM import report.")
        else
            style.tooltip("Open the latest AMM import report.")
        end
    else
        if reportHiddenText then
            style.tooltipActionLabel(reportHiddenText, reportHiddenText .. "\nNo AMM import report available yet.")
        else
            style.tooltip("No AMM import report available yet.")
        end
    end

    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload) then
        savedUI.reload()
    end
    style.tooltip("Reload saved groups from disk.")
    style.pushButtonNoBG(false)

    savedUI.drawSessionRestoreEntry()

    style.spacedSeparator()

    groupLoadManager.drawProgress(style)
    groupAMMImportManager.drawProgress(style)

    style.pushButtonNoBG(true)
    local hasGroups = hasSavedGroups()
    ImGui.BeginDisabled(not hasGroups)
    if ImGui.Button(IconGlyphs.CollapseAllOutline) then
        savedUI.pendingGroupOpenState = false
    end
    style.tooltip("Fold all groups")

    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.ExpandAllOutline) then
        savedUI.pendingGroupOpenState = true
    end
    style.tooltip("Expand all groups")
    ImGui.EndDisabled()
    style.pushButtonNoBG(false)

    ImGui.BeginChild("savedUI")

    local qtyHeader = "Qty assets"
    local qtyHeaderWidth, _ = ImGui.CalcTextSize(qtyHeader)
    local headerScrollBarAddition = ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0
    local qtyHeaderX = ImGui.GetWindowWidth() - qtyHeaderWidth - ImGui.GetStyle().CellPadding.x / 2 - headerScrollBarAddition + ImGui.GetScrollX()

    style.mutedText("Project / Group name")
    ImGui.SameLine()
    ImGui.SetCursorPosX(qtyHeaderX)
    style.mutedText(qtyHeader)
    ImGui.Separator()

    syncSavedFileCaches()

    local sortedCorruptedFiles = utils.getKeys(savedUI.invalidFiles)
    table.sort(sortedCorruptedFiles, function(a, b)
        return a:lower() < b:lower()
    end)

    local filteredCorruptedCount = 0
    for _, fileName in ipairs(sortedCorruptedFiles) do
        if fileName:lower():match(savedUI.filter:lower()) ~= nil then
            drawCorruptedEntry(fileName, qtyHeaderX)
            filteredCorruptedCount = filteredCorruptedCount + 1
        end
    end

    local allGroups = {}
    local allObjects = {}
    for fileName, data in pairs(savedUI.files) do
        local entry = {
            fileName = fileName,
            data = data
        }

        if utils.isSerializedGroupStrict(data) then
            table.insert(allGroups, entry)
        elseif utils.isSerializedSpawnableStrict(data) then
            table.insert(allObjects, entry)
        end
    end

    table.sort(allGroups, compareSavedEntriesByName)
    table.sort(allObjects, compareSavedEntriesByName)

    local filteredGroups = {}
    for _, entry in ipairs(allGroups) do
        if matchesSavedFilter(savedUI.filter, entry.data, entry.fileName) then
            table.insert(filteredGroups, entry)
        end
    end

    local filteredObjects = {}
    for _, entry in ipairs(allObjects) do
        if matchesSavedFilter(savedUI.filter, entry.data, entry.fileName) then
            table.insert(filteredObjects, entry)
        end
    end

    local projectMap, projectOptions = collectProjectCatalog(allGroups)
    local projectSections = buildProjectSections(filteredGroups)

    if savedUI.pendingGroupOpenState ~= nil then
        local forcedState = savedUI.pendingGroupOpenState

        for _, entry in ipairs(allGroups) do
            savedUI.groupOpenState[entry.fileName] = forcedState
        end

        savedUI.projectSectionOpenState[PROJECT_NEUTRAL_KEY] = forcedState
        for projectKey, _ in pairs(projectMap) do
            savedUI.projectSectionOpenState[projectKey] = forcedState
        end
        savedUI.projectSectionRestoreOpenState = {}
    end

    local visibleResults = false
    for _, section in ipairs(projectSections) do
        if #section.groups > 0 then
            drawProjectSection(section, spawner, projectMap, projectOptions)
            visibleResults = true
        end
    end

    if #filteredObjects > 0 then
        if visibleResults then
            ImGui.Dummy(0, 4 * style.viewSize)
            style.mutedText("Saved Objects")
            ImGui.Separator()
        end

        for _, entry in ipairs(filteredObjects) do
            savedUI.drawObject(entry.data, spawner, entry.fileName)
        end
        visibleResults = true
    end

    if not visibleResults and filteredCorruptedCount == 0 then
        style.mutedText("No saved entries match the current search.")
    end

    savedUI.pendingGroupOpenState = nil

    ImGui.EndChild()

    if savedUI.pendingReload then
        savedUI.pendingReload = false
        savedUI.reload()
    end

    savedUI.handlePopUp()
end

---Draws the "Group name" and "File name" rows of one saved entry.
---
---Two fields because they are two different things: the name is what the group is called wherever it
---appears, the file name is the project's identity -- what auto-save writes to, what a spawned copy
---is linked to, and what backups are filed under. Editing either one leaves the other alone.
---@param data table Cached entry for `fileName`.
---@param fileName string
---@return string fileName Possibly renamed, for the rest of the frame.
function savedUI.drawEntryNameFields(data, fileName)
    local state = getEntryEditState(fileName, data)

    -- Re-seeded whenever the file changed underneath us (auto-save, a save from the Spawned tab), but
    -- never while the field has focus, or typing would fight the refresh. Not re-seeding at all is
    -- what let the old single field drift away from the entry it belonged to.
    if not state.nameFocused and state.name ~= data.name then
        state.name = tostring(data.name or "")
    end

    style.mutedText("Group name")
    ImGui.SameLine()
    ImGui.SetCursorPosX(savedUI.maxTextWidth)
    ImGui.PushItemWidth(180 * style.viewSize)
    state.name = ImGui.InputTextWithHint("##groupName" .. fileName, "Group name...", state.name, 100)
    ImGui.PopItemWidth()
    state.nameFocused = ImGui.IsItemActive()
    style.tooltip("Name of the group itself, shown here and in the Spawned tab.\nDoes not affect which file it is saved in.")

    if ImGui.IsItemDeactivatedAfterEdit() then
        -- Refreshed first: auto-save may have written a newer tree that only exists on disk, and
        -- writing the cached one back would undo it.
        savedUI.getEntryData(fileName)

        if not renameSavedGroup(fileName, data, state.name) then
            state.name = tostring(data.name or "")
        end
    end

    style.mutedText("File name")
    ImGui.SameLine()
    ImGui.SetCursorPosX(savedUI.maxTextWidth)
    ImGui.PushItemWidth(180 * style.viewSize)
    state.fileName = ImGui.InputTextWithHint("##fileName" .. fileName, "File name...", state.fileName, 100)
    ImGui.PopItemWidth()
    style.tooltip("File this project is stored in, and the id everything else refers to it by.\nRenaming it keeps any spawned copy linked.")

    local renameCommitted = ImGui.IsItemDeactivatedAfterEdit()

    -- Muted, and after the field: the extension is fixed, so it reads as part of the name being
    -- edited rather than something to type.
    ImGui.SameLine()
    style.mutedText(projectFiles.extension)

    if renameCommitted then
        local newFileName, err = renameSavedFile(fileName, state.fileName)

        if newFileName then
            fileName = newFileName
            state.error = nil
        else
            state.error = err
            state.fileName = projectFiles.stripExtension(fileName)
        end
    end

    if state.error then
        ImGui.SetCursorPosX(savedUI.maxTextWidth)
        style.styledText(state.error, style.warnColor, 0.9)
    end

    return fileName
end

---@param projectMap table<string, table>?
---@param projectOptions table[]?
function savedUI.drawGroup(group, spawner, fileName, projectMap, projectOptions)
    if savedUI.pendingGroupOpenState ~= nil then
        ImGui.SetNextItemOpen(savedUI.pendingGroupOpenState, ImGuiCond.Always)
    elseif savedUI.groupOpenState[fileName] ~= nil then
        ImGui.SetNextItemOpen(savedUI.groupOpenState[fileName], ImGuiCond.Always)
    end

    local open = ImGui.TreeNodeEx(group.name .. "##savedGroupNode:" .. fileName)
    savedUI.groupOpenState[fileName] = open

    -- Two projects may legitimately be called the same thing now, so the row says which file it is.
    ImGui.SameLine()
    ImGui.Dummy(8 * style.viewSize, 0)
    ImGui.SameLine()
    style.mutedText(fileName)
    style.tooltip("Project file (unique id)")

    local openedAs = saveState.findRootChildByUID(fileName)
    if openedAs then
        ImGui.SameLine()
        style.mutedText(IconGlyphs.ContentSaveSettingsOutline)
        style.tooltip(string.format("Open in the Spawned tab as \"%s\"", tostring(openedAs.name)))
    end

    local countText = tostring(getSavedGroupElementCount(group))
    local textWidth, _ = ImGui.CalcTextSize(countText)
    local scrollBarAddition = ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0
    local cursorX = ImGui.GetWindowWidth() - textWidth - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()

    ImGui.SameLine()
    ImGui.SetCursorPosX(cursorX)
    style.mutedText(countText)

    if open then
        local pPos = Vector4.new(0, 0, 0, 0)
        if spawner.player then
            pPos = spawner.player:GetWorldPosition()
        end
        local posString = ("X=%.1f Y=%.1f Z=%.1f, Distance: %.1f"):format(group.pos.x, group.pos.y, group.pos.z, ToVector4(group.pos):Distance(pPos))

        fileName = savedUI.drawEntryNameFields(group, fileName)

        drawGroupProjectAssignment(group, fileName, projectMap or {}, projectOptions or {})

        style.mutedText("Position")
        ImGui.SameLine()
        ImGui.SetCursorPosX(savedUI.maxTextWidth)
        ImGui.Text(posString)

        local groupLoadActive = groupLoadManager.isActive() or groupAMMImportManager.isActive()
        style.pushGreyedOut(groupLoadActive)
        if ImGui.Button("Load") and not groupLoadActive then
            savedUI.startQueuedGroupLoad(savedUI.getEntryData(fileName) or group, spawner, false, fileName)
        end
        if groupLoadActive then
            style.tooltip("Loading is disabled while another pipeline operation is active")
        else
            style.tooltip("Load and spawn the group immediately")
        end

        ImGui.SameLine()
        if ImGui.Button("Load as Hidden") and not groupLoadActive then
            savedUI.startQueuedGroupLoad(savedUI.getEntryData(fileName) or group, spawner, true, fileName)
        end
        if groupLoadActive then
            style.tooltip("Loading is disabled while another pipeline operation is active")
        else
            style.tooltip("Load with hidden root so children are kept despawned until shown")
        end
        style.popGreyedOut(groupLoadActive)

        ImGui.SameLine()
        local teleportDisabledByEditor = spawner.editor and spawner.editor.active == true
        if style.warnButton(IconGlyphs.RunFast, {
            tooltip = "Teleport player to group",
            disabled = teleportDisabledByEditor,
            disabledTooltip = "Teleportation disabled while in 3D-Editor mode"
        }) then
            gameUtils.teleportPlayer(utils.getVector(group.pos))
        end

        ImGui.SameLine()
        if ImGui.Button("Add to Export") then
            spawner.baseUI.exportUI.addGroup(group.name, fileName)
        end
        
        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline) then
            savedUI.deleteData(fileName, group)
        end
	    style.tooltip("Delete group")

        ImGui.PushID("groupBackup" .. fileName)
        drawBackupRestoreActions(fileName)
        ImGui.PopID()

        ImGui.TreePop()
        ImGui.Spacing()
    end
end

---@param obj table
---@param spawner spawner
---@param fileName string
function savedUI.drawObject(obj, spawner, fileName)
    if ImGui.TreeNodeEx(obj.name) then
        local pPos = Vector4.new(0, 0, 0, 0)
        if spawner.player then
            pPos = spawner.player:GetWorldPosition()
        end
        local posString = ("X=%.1f Y=%.1f Z=%.1f, Distance: %.1f"):format(obj.spawnable.position.x, obj.spawnable.position.y, obj.spawnable.position.z, ToVector4(obj.spawnable.position):Distance(pPos))

        fileName = savedUI.drawEntryNameFields(obj, fileName)

        ImGui.PushID("objectBackup" .. fileName)
        drawBackupRestoreActions(fileName)
        ImGui.PopID()

        style.mutedText("Position:")
        ImGui.SameLine()
        ImGui.Text(posString)

        style.mutedText("Type:")
        ImGui.SameLine()
        ImGui.Text(obj.spawnable.dataType)

        local pipelineBusy = groupLoadManager.isActive() or groupAMMImportManager.isActive()
        style.pushGreyedOut(pipelineBusy)
        if ImGui.Button("Load") and not pipelineBusy then
            local o = require("modules/classes/editor/spawnableElement"):new(spawner.baseUI.spawnedUI)
            o:load(obj)
            spawner.baseUI.spawnedUI.addRootElement(o)
            history.addAction(history.getInsert({ o }))
        end
        if pipelineBusy then
            style.tooltip("Loading is disabled while another pipeline operation is active")
        else
            style.tooltip("Load object immediately")
        end
        style.popGreyedOut(pipelineBusy)

        ImGui.SameLine()
        local teleportDisabledByEditor = spawner.editor and spawner.editor.active == true
        if style.warnButton(IconGlyphs.RunFast, {
            disabled = teleportDisabledByEditor,
            tooltip = "Teleport player to object",
            disabledTooltip = TELEPORT_DISABLED_EDITOR_TOOLTIP
        }) then
            gameUtils.teleportPlayer(utils.getVector(obj.spawnable.position))
        end
        
        ImGui.SameLine()
        if ImGui.Button("Delete") then
            savedUI.deleteData(fileName, obj)
        end

        ImGui.TreePop()
        ImGui.Spacing()
    end
end

---Deletes one saved entry from disk.
---
---Addressed by file name rather than by the group's name: the two stopped being the same thing, and
---deleting by name would either miss the file or hit whichever project happens to be named that.
---@param fileName string File name including extension.
---@param data table Cached entry, used for the notifications only.
local function removeSavedEntry(fileName, data)
    os.remove(projectFiles.getPath(fileName))
    savedUI.files[fileName] = nil
    savedUI.invalidFiles[fileName] = nil
    savedUI.groupOpenState[fileName] = nil
    savedUI.stalePayloads[fileName] = nil
    savedUI.entryEditState[fileName] = nil

    -- The group may still be open in the Spawned tab; its file is gone, so it is no longer a project
    -- and saving it has to ask for a new file rather than silently recreating this one.
    local spawned = saveState.findRootChildByUID(fileName)
    if spawned then
        saveState.unbindProjectFile(spawned)
    end

    local removedFromExport = removeFromExportListIfPresent(fileName, data)
    showDeletedGroupToast(data, removedFromExport)
end

---@param fileName string File name including extension.
---@param data table Cached entry.
function savedUI.deleteData(fileName, data)
    if settings.deleteConfirm then
        savedUI.popup = true
        savedUI.deleteFile = { fileName = fileName, data = data }
        savedUI.popupDontAskAgain = not settings.deleteConfirm
    else
        removeSavedEntry(fileName, data)
    end
end

function savedUI.handlePopUp()
    if savedUI.popup then
        ImGui.OpenPopup("Delete Data?")
        if ImGui.BeginPopupModal("Delete Data?", true, ImGuiWindowFlags.AlwaysAutoResize) then
            local pending = savedUI.deleteFile
            local targetName = pending and pending.data and pending.data.name or "Unknown"
            ImGui.Text("Delete \"" .. targetName .. "\"?")
            style.mutedText(pending and pending.fileName or "")
            style.mutedText("This action cannot be undone.")
            ImGui.Dummy(0, 8 * style.viewSize)
            savedUI.popupDontAskAgain = ImGui.Checkbox("Don't ask again", savedUI.popupDontAskAgain)
            ImGui.Dummy(0, 8 * style.viewSize)

            if ImGui.Button("Cancel") then
                ImGui.CloseCurrentPopup()
                savedUI.popup = false
                savedUI.deleteFile = nil
            end

            ImGui.SameLine()

            if ImGui.Button("Confirm") then
                ImGui.CloseCurrentPopup()
                -- Store user preference
                settings.deleteConfirm = not savedUI.popupDontAskAgain
                settings.save()

                if pending then
                    removeSavedEntry(pending.fileName, pending.data)
                end

                savedUI.deleteFile = nil
                savedUI.popup = false
            end
            ImGui.EndPopup()
        end
    end

    ammImportPresetPopup.draw(function(selectedPresetFiles)
        return savedUI.importAMMPresets(selectedPresetFiles)
    end)
    ammImportReportPopup.draw()
end

function savedUI.reload()
    savedUI.files = {}
    savedUI.invalidFiles = {}
    savedUI.stalePayloads = {}
    savedUI.pendingReload = false
    savedUI.projectSectionOpenState = {}
    savedUI.projectSectionRestoreOpenState = {}
    savedUI.groupOpenState = {}
    savedUI.projectSectionEditorState = {}
    savedUI.projectSectionIconSearch = {}
    savedUI.groupProjectCreateState = {}
    savedUI.groupProjectIconSearch = {}
    savedUI.entryEditState = {}
    savedUI.pendingGroupProjectPopupId = nil
    ammImportPresetPopup.reset()
    backup.invalidateInfoCache()

    for _, file in pairs(dir("data/objects")) do
        if file.name:match("^.+(%..+)$") == ".json" then
            loadSavedEntry(file.name)
        end
    end
end

return savedUI
