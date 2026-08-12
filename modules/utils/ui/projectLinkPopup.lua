local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local logger = require("modules/utils/core/logger")
local saveState = require("modules/utils/project/saveState")
local projectFiles = require("modules/utils/project/projectFiles")
local projectTagUtil = require("modules/utils/ui/projectTag")
local pipelineCommon = require("modules/utils/pipeline/common")

---Decides which project file a root group writes to, in the two cases where the answer cannot be
---derived: linking a never-saved group onto an existing project, and a first save whose derived file
---name is already taken.
---
---Both end the same way -- the group gets a uID and is saved immediately -- so they share one popup
---with a shared project list.
---
---Opened through a request flag consumed on the next draw, like `sessionRestorePopup`, because the
---callers (a context menu, the persistence pipeline) are nowhere near the right ImGui window.
local projectLinkPopup = {
    popupId = "Project File",
    openRequested = false,

    ---@type element? Root group waiting for an answer.
    target = nil,
    ---`"link"` when the user asked to adopt an existing project, `"conflict"` on a blocked first save.
    mode = "link",
    ---Free file name offered in conflict mode.
    suggestion = "",
    ---Existing file that blocked the derived name, in conflict mode.
    takenBy = nil,

    filter = "",
    ---@type string? File name picked in the list.
    selected = nil,
    ---Live value of the "new file name" field, without extension.
    newName = "",

    ---Requests waiting their turn. "Save all" over several never-saved groups can raise one conflict
    ---per group, and a single-slot request would drop every one but the last.
    ---@type table[]
    queue = {},

    pendingToasts = {}
}

---@param kind string
---@param text string
local function queueToast(kind, text)
    pipelineCommon.queueToast(projectLinkPopup.pendingToasts, kind, 4000, text)
end

---@param rootChild element?
---@return boolean
local function isUsableTarget(rootChild)
    return rootChild ~= nil
        and saveState.isSavableRootGroup(rootChild)
        and rootChild.projectUID == nil
end

---Loads one request into the visible fields.
---@param request table
local function activate(request)
    projectLinkPopup.target = request.target
    projectLinkPopup.mode = request.mode
    projectLinkPopup.suggestion = request.suggestion
    projectLinkPopup.takenBy = request.takenBy
    projectLinkPopup.newName = projectFiles.stripExtension(request.suggestion)
    projectLinkPopup.selected = request.mode == "conflict" and request.takenBy or nil
    projectLinkPopup.filter = ""
    projectLinkPopup.openRequested = true
end

---Closes the current request and moves on to the next one, if any.
local function finishCurrent()
    projectLinkPopup.target = nil
    projectLinkPopup.selected = nil
    projectLinkPopup.filter = ""
    projectLinkPopup.newName = ""
    projectLinkPopup.suggestion = ""
    projectLinkPopup.takenBy = nil

    while #projectLinkPopup.queue > 0 do
        local queued = table.remove(projectLinkPopup.queue, 1)

        if isUsableTarget(queued.target) then
            activate(queued)
            return
        end
    end
end

---@param request table
---@return boolean queued
local function enqueue(request)
    if not isUsableTarget(request.target) then return false end

    for _, queued in ipairs(projectLinkPopup.queue) do
        if queued.target == request.target then return true end
    end

    if projectLinkPopup.target == request.target then return true end

    if projectLinkPopup.target == nil then
        activate(request)
    else
        projectLinkPopup.queue[#projectLinkPopup.queue + 1] = request
    end

    return true
end

---Asks the user which existing project a group should take over.
---@param rootChild element Root group with no uID.
---@return boolean opened
function projectLinkPopup.requestLink(rootChild)
    return enqueue({
        target = rootChild,
        mode = "link",
        suggestion = projectFiles.suggestFileName(rootChild and rootChild.name)
    })
end

---Asks what to do when a first save cannot use the file name the group's name points at.
---@param rootChild element Root group with no uID.
---@param suggestion string? Free file name to offer instead.
---@param takenBy string? Existing file that holds the derived name.
---@return boolean opened
function projectLinkPopup.requestConflict(rootChild, suggestion, takenBy)
    return enqueue({
        target = rootChild,
        mode = "conflict",
        suggestion = suggestion or projectFiles.suggestFileName(rootChild and rootChild.name),
        takenBy = takenBy
    })
end

---Links the group to a file and writes it there straight away.
---
---Saving immediately is the point of both flows: "replace this project" that leaves the file
---untouched until some later pass would be a promise, not an action, and the group would sit there
---claiming a file whose content is someone else's.
---@param rootChild element
---@param fileName string
---@return boolean ok
local function linkAndSave(rootChild, fileName)
    if not saveState.linkToProjectFile(rootChild, fileName) then
        local claimant = saveState.findRootChildByUID(fileName)
        queueToast("error", string.format("\"%s\" is already open as \"%s\"",
            fileName, tostring(claimant and claimant.name or "another group")))
        return false
    end

    local sUI = rootChild.sUI
    if sUI and sUI.saveRootGroup then
        sUI.saveRootGroup(rootChild)
    else
        rootChild:save(true)
    end

    logger:info(string.format("[ProjectLink] \"%s\" now writes to \"%s\"", tostring(rootChild.name), fileName))

    return true
end

---Collects the saved projects offered in the list.
---@param spawner spawner
---@return {fileName: string, name: string, project: table?, openedAs: element?}[]
local function collectProjects(spawner)
    local savedUI = spawner and spawner.baseUI and spawner.baseUI.savedUI or nil
    local files = savedUI and savedUI.files or nil
    local entries = {}

    if type(files) ~= "table" then
        return entries
    end

    for fileName, data in pairs(files) do
        if utils.isSerializedGroupStrict(data) then
            entries[#entries + 1] = {
                fileName = fileName,
                name = tostring(data.name or projectFiles.stripExtension(fileName)),
                project = projectTagUtil.normalizeProject(data.project),
                openedAs = saveState.findRootChildByUID(fileName)
            }
        end
    end

    table.sort(entries, function(a, b)
        local nameA, nameB = a.name:lower(), b.name:lower()
        if nameA == nameB then
            return a.fileName:lower() < b.fileName:lower()
        end
        return nameA < nameB
    end)

    return entries
end

---@param spawner spawner
---@return string? selectedFileName
local function drawProjectList(spawner)
    local entries = collectProjects(spawner)
    local filter = projectLinkPopup.filter

    if ImGui.BeginChild("##projectLinkList", 0, 260 * style.viewSize, true) then
        local shown = 0

        for _, entry in ipairs(entries) do
            if filter == ""
                or utils.matchSearch(entry.name, filter)
                or utils.matchSearch(entry.fileName, filter) then
                shown = shown + 1

                ImGui.PushID("projectLinkRow" .. entry.fileName)

                local isOpen = entry.openedAs ~= nil
                local selected = projectLinkPopup.selected == entry.fileName
                local label = string.format("%s %s", IconGlyphs.FolderOutline, entry.name)

                style.pushGreyedOut(isOpen)
                if ImGui.Selectable(label .. "##projectLinkSelect", selected) and not isOpen then
                    projectLinkPopup.selected = entry.fileName
                end
                style.popGreyedOut(isOpen)

                if isOpen then
                    style.tooltip(string.format(
                        "\"%s\" is already open in the Spawned tab as \"%s\".\nUnlink or remove that group first.",
                        entry.fileName, tostring(entry.openedAs.name)))
                end

                ImGui.SameLine()
                local suffix = entry.fileName
                if entry.project then
                    suffix = suffix .. "  -  " .. entry.project.name
                end
                local suffixWidth, _ = ImGui.CalcTextSize(suffix)
                local scrollBarAddition = ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0
                local rightX = ImGui.GetWindowWidth() - suffixWidth - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()
                ImGui.SetCursorPosX(math.max(rightX, ImGui.GetCursorPosX()))
                style.mutedText(suffix)

                ImGui.PopID()
            end
        end

        if shown == 0 then
            style.mutedText(#entries == 0 and "No saved projects yet." or "No project matches the search.")
        end

        ImGui.EndChild()
    end

    return projectLinkPopup.selected
end

---@param spawner spawner
function projectLinkPopup.draw(spawner)
    pipelineCommon.drawQueuedToasts(projectLinkPopup.pendingToasts)

    if projectLinkPopup.openRequested then
        ImGui.OpenPopup(projectLinkPopup.popupId)
        projectLinkPopup.openRequested = false
    elseif projectLinkPopup.target and not ImGui.IsPopupOpen(projectLinkPopup.popupId) then
        -- Dismissed through the window's close button, which never reaches the buttons below.
        -- Treated as a cancel so the queue keeps moving instead of stalling on a hidden request.
        finishCurrent()
    end

    local defaultWidth = 700 * style.viewSize
    local defaultHeight = 520 * style.viewSize
    local minWidth = 520 * style.viewSize
    local minHeight = 360 * style.viewSize
    local screenWidth, screenHeight = GetDisplayResolution()
    ImGui.SetNextWindowSize(defaultWidth, defaultHeight, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSizeConstraints(minWidth, minHeight,
        math.max(minWidth, screenWidth - 40 * style.viewSize),
        math.max(minHeight, screenHeight - 40 * style.viewSize))

    if not ImGui.BeginPopupModal(projectLinkPopup.popupId, true) then
        return
    end

    local target = projectLinkPopup.target

    -- The group can be deleted, or saved by another route, while the popup sits open.
    if not isUsableTarget(target) then
        style.mutedText("The group this was opened for is no longer waiting for a file name.")
        ImGui.Dummy(0, 8 * style.viewSize)
        if ImGui.Button("Close##projectLinkStaleClose") then
            finishCurrent()
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
        return
    end

    if #projectLinkPopup.queue > 0 then
        style.mutedText(string.format("%d more group%s waiting after this one",
            #projectLinkPopup.queue, #projectLinkPopup.queue == 1 and "" or "s"))
    end

    local isConflict = projectLinkPopup.mode == "conflict"
    local closeAfterDraw = false

    if isConflict then
        style.styledTextWrapped(string.format(
            "\"%s\" has never been saved, and \"%s\" is already taken by another project.",
            tostring(target.name), tostring(projectLinkPopup.takenBy)))
        style.mutedText("Save it under a different file name, or replace an existing project.")
    else
        style.styledTextWrapped(string.format(
            "Save \"%s\" as an existing project. The project you pick is replaced by this group, and this group is linked to it from now on.",
            tostring(target.name)))
        style.mutedText("The previous content stays available through \"Restore previous save\" in the Projects tab.")
    end

    ImGui.Dummy(0, 8 * style.viewSize)

    local canCreate = false
    local newFileName = nil

    if isConflict then
        style.mutedText("New file name")
        ImGui.SameLine()
        ImGui.SetNextItemWidth(260 * style.viewSize)
        projectLinkPopup.newName = style.inputTextWithHint("##projectLinkNewName", "File name...", projectLinkPopup.newName, 100)
        ImGui.SameLine()
        style.mutedText(projectFiles.extension)

        local valid, err = projectFiles.validateFileName(projectLinkPopup.newName)
        canCreate = valid
        newFileName = projectFiles.withExtension(projectFiles.stripExtension(projectLinkPopup.newName))

        if not valid then
            style.styledText(tostring(err), style.warnColor, 0.9)
        else
            style.mutedText(string.format("Creates \"%s\"", newFileName))
        end

        ImGui.Dummy(0, 4 * style.viewSize)

        style.pushGreyedOut(not canCreate)
        if ImGui.Button("Save as new project##projectLinkCreate") and canCreate then
            -- Closing is deferred to the end of the frame rather than returning from here, so every
            -- style push in this function keeps its matching pop.
            closeAfterDraw = linkAndSave(target, newFileName)
        end
        style.popGreyedOut(not canCreate)

        style.spacedSeparator()
        style.mutedText("Or replace an existing project")
    end

    ImGui.SetNextItemWidth(260 * style.viewSize)
    projectLinkPopup.filter = style.inputTextWithHint("##projectLinkFilter", "Search projects...", projectLinkPopup.filter, 100)

    ImGui.Dummy(0, 4 * style.viewSize)
    local selected = drawProjectList(spawner)
    ImGui.Dummy(0, 6 * style.viewSize)

    if selected then
        style.mutedText(string.format("Replaces \"%s\"", selected))
    else
        style.mutedText("No project selected.")
    end

    ImGui.Dummy(0, 8 * style.viewSize)

    if ImGui.Button("Cancel##projectLinkCancel") then
        closeAfterDraw = true
    end

    ImGui.SameLine()
    local replaceDisabled = selected == nil or saveState.findRootChildByUID(selected) ~= nil
    style.pushGreyedOut(replaceDisabled)
    if ImGui.Button("Replace selected project##projectLinkReplace") and not replaceDisabled then
        closeAfterDraw = linkAndSave(target, selected)
    end
    style.popGreyedOut(replaceDisabled)

    if closeAfterDraw then
        finishCurrent()
        ImGui.CloseCurrentPopup()
    end

    ImGui.EndPopup()
end

return projectLinkPopup
