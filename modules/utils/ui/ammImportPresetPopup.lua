local style = require("modules/ui/style")
local amm = require("modules/utils/pipeline/ammUtils")
local groupLoadManager = require("modules/utils/pipeline/groupLoadManager")
local groupAMMImportManager = require("modules/utils/pipeline/groupAMMImportManager")

local ammImportPresetPopup = {
    popupId = "Select AMM Presets",
    openRequested = false,
    candidates = nil,
    selection = {}
}

local function getErrorToastType()
    if ImGui.ToastType and ImGui.ToastType.Error then
        return ImGui.ToastType.Error
    end

    return ImGui.ToastType.Success
end

---@return boolean
function ammImportPresetPopup.isBlocked()
    return groupLoadManager.isActive() or amm.importing or groupAMMImportManager.isActive()
end

local function refreshCandidates()
    local candidates = groupAMMImportManager.listImportablePresets()
    ammImportPresetPopup.candidates = candidates
    ammImportPresetPopup.selection = {}

    for _, preset in ipairs(candidates.presets or {}) do
        local fileName = tostring(preset.fileName or "")
        if fileName ~= "" then
            ammImportPresetPopup.selection[fileName] = true
        end
    end
end

---@return string[], number, number
local function getSelectedPresets()
    local selectedFiles = {}
    local selectedCount = 0
    local selectedObjects = 0
    local presets = ammImportPresetPopup.candidates and ammImportPresetPopup.candidates.presets or {}

    for _, preset in ipairs(presets) do
        local fileName = tostring(preset.fileName or "")
        if fileName ~= "" and ammImportPresetPopup.selection[fileName] == true then
            table.insert(selectedFiles, fileName)
            selectedCount = selectedCount + 1
            selectedObjects = selectedObjects + math.max(0, tonumber(preset.objectCount) or 0)
        end
    end

    return selectedFiles, selectedCount, selectedObjects
end

---@param selected boolean
local function setSelectionState(selected)
    local presets = ammImportPresetPopup.candidates and ammImportPresetPopup.candidates.presets or {}

    for _, preset in ipairs(presets) do
        local fileName = tostring(preset.fileName or "")
        if fileName ~= "" then
            ammImportPresetPopup.selection[fileName] = selected == true
        end
    end
end

---@return boolean opened
function ammImportPresetPopup.requestOpen()
    if ammImportPresetPopup.isBlocked() then
        return false
    end

    refreshCandidates()
    ammImportPresetPopup.openRequested = true
    return true
end

function ammImportPresetPopup.reset()
    ammImportPresetPopup.openRequested = false
    ammImportPresetPopup.candidates = nil
    ammImportPresetPopup.selection = {}
end

---@param onImportSelected fun(selectedPresetFiles: string[]): boolean?
function ammImportPresetPopup.draw(onImportSelected)
    if ammImportPresetPopup.openRequested then
        ImGui.OpenPopup(ammImportPresetPopup.popupId)
        ammImportPresetPopup.openRequested = false
    end

    local defaultWidth = 720 * style.viewSize
    local defaultHeight = 620 * style.viewSize
    local minWidth = 560 * style.viewSize
    local minHeight = 420 * style.viewSize
    local screenWidth, screenHeight = GetDisplayResolution()
    local maxWidth = math.max(minWidth, screenWidth - 40 * style.viewSize)
    local maxHeight = math.max(minHeight, screenHeight - 40 * style.viewSize)
    ImGui.SetNextWindowSize(defaultWidth, defaultHeight, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSizeConstraints(minWidth, minHeight, maxWidth, maxHeight)

    if not ImGui.BeginPopupModal(ammImportPresetPopup.popupId, true) then
        return
    end

    if type(ammImportPresetPopup.candidates) ~= "table" then
        refreshCandidates()
    end

    local candidates = ammImportPresetPopup.candidates or {}
    local presets = candidates.presets or {}
    local scanned = math.max(0, tonumber(candidates.jsonScanned) or 0)
    local skippedInvalid = math.max(0, tonumber(candidates.skippedInvalid) or 0)
    local totalObjects = math.max(0, tonumber(candidates.totalObjects) or 0)
    local importBlocked = ammImportPresetPopup.isBlocked()

    style.mutedText(string.format(
        "Importable presets: %d | Scanned JSON files: %d | Invalid JSON files skipped: %d",
        #presets,
        scanned,
        skippedInvalid))
    style.mutedText(string.format("Objects in importable presets: %d", totalObjects))
    ImGui.Dummy(0, 8 * style.viewSize)

    style.pushGreyedOut(#presets == 0)
    if ImGui.Button("Select All##ammImportPresetSelectAll") and #presets > 0 then
        setSelectionState(true)
    end
    style.popGreyedOut(#presets == 0)

    ImGui.SameLine()
    style.pushGreyedOut(#presets == 0)
    if ImGui.Button("Select None##ammImportPresetSelectNone") and #presets > 0 then
        setSelectionState(false)
    end
    style.popGreyedOut(#presets == 0)

    if importBlocked then
        style.mutedText("Import is currently unavailable while another pipeline action is active.")
    end

    ImGui.Dummy(0, 6 * style.viewSize)

    local listHeight = 320 * style.viewSize
    if ImGui.BeginChild("##ammImportPresetSelectionList", 0, listHeight, true) then
        if #presets == 0 then
            style.mutedText("No valid AMM presets found in data/AMMImport.")
        else
            for _, preset in ipairs(presets) do
                local fileName = tostring(preset.fileName or "")
                local displayName = tostring(preset.displayName or fileName)
                local displayLabel = displayName ~= fileName and (displayName .. " (" .. fileName .. ")") or displayName
                local objectCount = math.max(0, tonumber(preset.objectCount) or 0)
                local objectCountLabel = string.format("%d object%s", objectCount, objectCount == 1 and "" or "s")
                local objectCountWidth, _ = ImGui.CalcTextSize(objectCountLabel)
                local scrollBarAddition = ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0
                local objectCountX = ImGui.GetWindowWidth() - objectCountWidth - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()

                ImGui.PushID("ammImportPresetRow" .. fileName)
                local selected = ammImportPresetPopup.selection[fileName] == true
                local nextSelected, changed = ImGui.Checkbox("##ammImportPresetSelected", selected)
                if changed then
                    ammImportPresetPopup.selection[fileName] = nextSelected == true
                end

                ImGui.SameLine()
                ImGui.Text(displayLabel)

                ImGui.SameLine()
                ImGui.SetCursorPosX(objectCountX)
                style.mutedText(objectCountLabel)
                ImGui.PopID()
            end
        end

        ImGui.EndChild()
    end

    local selectedFiles, selectedCount, selectedObjects = getSelectedPresets()
    local importDisabled = importBlocked or selectedCount == 0

    ImGui.Dummy(0, 6 * style.viewSize)
    style.mutedText(string.format("Selected: %d preset%s | %d object%s",
        selectedCount,
        selectedCount == 1 and "" or "s",
        selectedObjects,
        selectedObjects == 1 and "" or "s"))
    ImGui.Dummy(0, 8 * style.viewSize)

    if ImGui.Button("Cancel##ammImportPresetSelectionCancel") then
        ImGui.CloseCurrentPopup()
    end

    ImGui.SameLine()
    style.pushGreyedOut(importDisabled)
    if ImGui.Button("Import Selected##ammImportPresetSelectionImport") and not importDisabled then
        local started = false
        if type(onImportSelected) == "function" then
            started = onImportSelected(selectedFiles) == true
        end

        if started then
            ammImportPresetPopup.candidates = nil
            ammImportPresetPopup.selection = {}
            ImGui.CloseCurrentPopup()
        else
            ImGui.ShowToast(ImGui.Toast.new(getErrorToastType(), 3500, "Failed to start AMM import."))
        end
    end
    style.popGreyedOut(importDisabled)

    if importBlocked then
        style.tooltip("Import cannot start while another pipeline operation is running.")
    elseif selectedCount == 0 then
        style.tooltip("Select at least one preset to import.")
    else
        style.tooltip("Start importing only the selected presets.")
    end

    ImGui.EndPopup()
end

return ammImportPresetPopup
