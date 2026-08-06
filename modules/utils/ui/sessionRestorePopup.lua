local style = require("modules/ui/style")
local logger = require("modules/utils/logger")
local config = require("modules/utils/config")
local saveState = require("modules/utils/saveState")
local sessionSnapshot = require("modules/utils/pipeline/sessionSnapshot")
local groupLoadManager = require("modules/utils/pipeline/groupLoadManager")
local groupAMMImportManager = require("modules/utils/pipeline/groupAMMImportManager")
local pipelineCommon = require("modules/utils/pipeline/common")

---Lets the user pick which root items to bring back from a session snapshot.
---
---Structured like `ammImportPresetPopup`: a `requestOpen` flag consumed on the next draw, so callers
---never have to be inside the right ImGui window to open it.
---
---Loading is queued rather than looped: `groupLoadManager.start` handles one request at a time and
---simply returns false if it is busy, so restoring several items chains them through the manager's
---own `onFinished` hook.
local sessionRestorePopup = {
    popupId = "Restore Last Session",
    openRequested = false,

    ---@type table? Index being offered.
    index = nil,
    ---Which snapshot file the index came from.
    sourcePath = nil,
    selection = {},

    ---@type table[] Entries still waiting to be loaded.
    queue = {},
    queueTotal = 0,
    queueDone = 0,
    ---Cached decode of the payload, populated on confirm so blobs do not re-read the file each time.
    ---@type table?
    payload = nil,

    ---Restoring continues across frames from onUpdate, so its notifications have to be parked here
    ---and emitted from `draw`, which is the only place ImGui may be touched.
    pendingToasts = {}
}

---@return boolean
function sessionRestorePopup.isBlocked()
    return groupLoadManager.isActive() or groupAMMImportManager.isActive()
end

---@return boolean
function sessionRestorePopup.isRestoring()
    return #sessionRestorePopup.queue > 0
end

---@param state boolean
local function setSelectionState(state)
    for _, entry in ipairs(sessionRestorePopup.index and sessionRestorePopup.index.entries or {}) do
        sessionRestorePopup.selection[entry.name] = state
    end
end

---Opens the popup against a snapshot file.
---@param path string? Defaults to the previous run's snapshot -- the only one that is ever offered.
---@return boolean opened
function sessionRestorePopup.requestOpen(path)
    path = path or sessionSnapshot.previousPath

    local index = sessionSnapshot.readIndex(path)
    if not index or type(index.entries) ~= "table" or #index.entries == 0 then
        return false
    end

    sessionRestorePopup.index = index
    sessionRestorePopup.sourcePath = path
    sessionRestorePopup.selection = {}
    sessionRestorePopup.payload = nil
    setSelectionState(true)
    sessionRestorePopup.openRequested = true

    return true
end

function sessionRestorePopup.reset()
    sessionRestorePopup.index = nil
    sessionRestorePopup.sourcePath = nil
    sessionRestorePopup.selection = {}
    sessionRestorePopup.payload = nil
    sessionRestorePopup.queue = {}
    sessionRestorePopup.queueTotal = 0
    sessionRestorePopup.queueDone = 0
end

--------------------------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------------------------

local function startNextQueued(spawner)
    local entry = table.remove(sessionRestorePopup.queue, 1)

    if not entry then
        local restored = sessionRestorePopup.queueDone
        sessionRestorePopup.payload = nil

        if restored > 0 then
            -- Queued, not shown: every call after the first arrives through groupLoadManager's
            -- onFinished, which runs from onUpdate, and ImGui may only be touched from onDraw.
            pipelineCommon.queueToast(sessionRestorePopup.pendingToasts, "success", 3000,
                string.format("Restored %d item%s from the last session", restored, restored == 1 and "" or "s"))
        end
        return
    end

    local data = nil
    local projectFile = nil

    if entry.kind == "ref" and entry.projectFile then
        -- The tree was already on disk under its project file, so restore from there and keep the
        -- group bound to it.
        local savedUI = spawner.baseUI.savedUI
        -- Via the accessor, not savedUI.files directly: auto-save can have written a newer tree that
        -- the cached entry does not have yet.
        data = savedUI.getEntryData and savedUI.getEntryData(entry.projectFile)
        projectFile = entry.projectFile

        if not data then
            data = config.loadFile("data/objects/" .. entry.projectFile)
            if type(data) ~= "table" or not data.name then
                data = nil
            end
        end
    else
        if not sessionRestorePopup.payload then
            local decoded = config.loadFile(sessionRestorePopup.sourcePath)
            sessionRestorePopup.payload = (type(decoded) == "table" and decoded.payload) or {}
        end

        data = sessionRestorePopup.payload[entry.name]
        -- A blob that still knows its project file keeps the binding, so saving it later overwrites
        -- the right file rather than creating a duplicate.
        projectFile = entry.projectFile
    end

    if type(data) ~= "table" then
        startNextQueued(spawner)
        return
    end

    local started = groupLoadManager.start({
        spawner = spawner,
        data = data,
        targetParent = spawner.baseUI.spawnedUI.root,
        projectFile = projectFile,
        -- One history entry per restored group would bury whatever the user does next, and each entry
        -- would hold a full serialize of the group.
        suppressHistory = true,
        onFinished = function(loadedGroup)
            sessionRestorePopup.queueDone = sessionRestorePopup.queueDone + 1

            -- A blob is by definition work that was never written to its file, so it must come back
            -- flagged as modified rather than pretending to match disk.
            if entry.kind == "blob" and loadedGroup then
                saveState.markDirty(loadedGroup)
            end

            startNextQueued(spawner)
        end
    })

    if not started then
        logger:warn("[Session] Could not start restore for \"" .. tostring(entry.name) .. "\"")
        startNextQueued(spawner)
    end
end

---Queues the selected entries for loading.
---@param spawner spawner
---@return integer queued
function sessionRestorePopup.restoreSelected(spawner)
    local entries = sessionRestorePopup.index and sessionRestorePopup.index.entries or {}
    local queue = {}

    for _, entry in ipairs(entries) do
        if sessionRestorePopup.selection[entry.name] then
            queue[#queue + 1] = entry
        end
    end

    if #queue == 0 then return 0 end

    sessionRestorePopup.queue = queue
    sessionRestorePopup.queueTotal = #queue
    sessionRestorePopup.queueDone = 0

    -- Whatever happens next, this is now a live session rather than a recoverable one.
    sessionSnapshot.consume("restored")

    startNextQueued(spawner)

    return #queue
end

--------------------------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------------------------

---@param entry table
---@return string badge
---@return string tooltip
local function describeEntry(entry)
    if entry.kind == "ref" then
        return "matches saved project",
            "This was saved to \"" .. tostring(entry.projectFile) .. "\" and had no unsaved changes.\nRestored from that file."
    end

    if entry.wasProject then
        return "unsaved changes",
            "Saved as \"" .. tostring(entry.projectFile) .. "\", but edited after that.\nRestored from the snapshot, still marked as modified."
    end

    return "never saved",
        "This group was never saved to a project file.\nRestored from the snapshot only."
end

---@param spawner spawner
function sessionRestorePopup.draw(spawner)
    pipelineCommon.drawQueuedToasts(sessionRestorePopup.pendingToasts)

    if sessionRestorePopup.openRequested then
        ImGui.OpenPopup(sessionRestorePopup.popupId)
        sessionRestorePopup.openRequested = false
    end

    local defaultWidth = 720 * style.viewSize
    local defaultHeight = 560 * style.viewSize
    local minWidth = 560 * style.viewSize
    local minHeight = 380 * style.viewSize
    local screenWidth, screenHeight = GetDisplayResolution()
    ImGui.SetNextWindowSize(defaultWidth, defaultHeight, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSizeConstraints(minWidth, minHeight,
        math.max(minWidth, screenWidth - 40 * style.viewSize),
        math.max(minHeight, screenHeight - 40 * style.viewSize))

    if not ImGui.BeginPopupModal(sessionRestorePopup.popupId, true) then
        return
    end

    local index = sessionRestorePopup.index
    local entries = index and index.entries or {}
    local blocked = sessionRestorePopup.isBlocked()

    style.mutedText(string.format("Snapshot from %s | %d root item%s",
        tostring(index and index.savedAt or "unknown"), #entries, #entries == 1 and "" or "s"))
    style.styledTextWrapped("Restored items are added to the Spawned tab alongside anything already there. Nothing on disk is overwritten.")
    ImGui.Dummy(0, 8 * style.viewSize)

    style.pushGreyedOut(#entries == 0)
    if ImGui.Button("Select All##sessionRestoreSelectAll") and #entries > 0 then
        setSelectionState(true)
    end
    ImGui.SameLine()
    if ImGui.Button("Select None##sessionRestoreSelectNone") and #entries > 0 then
        setSelectionState(false)
    end
    style.popGreyedOut(#entries == 0)

    if blocked then
        style.mutedText("Restoring is unavailable while another loading operation is running.")
    end

    ImGui.Dummy(0, 6 * style.viewSize)

    if ImGui.BeginChild("##sessionRestoreList", 0, 300 * style.viewSize, true) then
        if #entries == 0 then
            style.mutedText("The snapshot is empty.")
        else
            for _, entry in ipairs(entries) do
                local name = tostring(entry.name)
                local badge, tooltip = describeEntry(entry)
                local count = math.max(0, tonumber(entry.elementCount) or 0)
                local countLabel = string.format("%d asset%s", count, count == 1 and "" or "s")

                local rightLabel = badge .. "  -  " .. countLabel
                local rightWidth, _ = ImGui.CalcTextSize(rightLabel)
                local scrollBarAddition = ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0
                local rightX = ImGui.GetWindowWidth() - rightWidth - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()

                ImGui.PushID("sessionRestoreRow" .. name)

                local selected = sessionRestorePopup.selection[name] == true
                local nextSelected, changed = ImGui.Checkbox("##sessionRestoreSelected", selected)
                if changed then
                    sessionRestorePopup.selection[name] = nextSelected == true
                end

                ImGui.SameLine()
                ImGui.Text((entry.isGroup and IconGlyphs.FolderOutline or IconGlyphs.FileOutline) .. " " .. name)
                style.tooltip(tooltip)

                ImGui.SameLine()
                ImGui.SetCursorPosX(rightX)
                style.mutedText(rightLabel)
                style.tooltip(tooltip)

                ImGui.PopID()
            end
        end

        ImGui.EndChild()
    end

    local selectedCount = 0
    for _, entry in ipairs(entries) do
        if sessionRestorePopup.selection[entry.name] then
            selectedCount = selectedCount + 1
        end
    end

    ImGui.Dummy(0, 6 * style.viewSize)
    style.mutedText(string.format("Selected: %d of %d", selectedCount, #entries))
    ImGui.Dummy(0, 8 * style.viewSize)

    if ImGui.Button("Cancel##sessionRestoreCancel") then
        ImGui.CloseCurrentPopup()
    end

    ImGui.SameLine()
    local restoreDisabled = blocked or selectedCount == 0
    style.pushGreyedOut(restoreDisabled)
    if ImGui.Button("Restore Selected##sessionRestoreConfirm") and not restoreDisabled then
        sessionRestorePopup.restoreSelected(spawner)
        ImGui.CloseCurrentPopup()
    end
    style.popGreyedOut(restoreDisabled)

    ImGui.EndPopup()
end

return sessionRestorePopup
