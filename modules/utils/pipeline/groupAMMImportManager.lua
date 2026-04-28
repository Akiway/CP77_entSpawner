local Cron = require("modules/utils/Cron")
local config = require("modules/utils/config")
local amm = require("modules/utils/ammUtils")
local pipelineCommon = require("modules/utils/pipeline/common")

local groupAMMImportManager = {}

local function createImportState(previous)
    return {
        active = false,
        phase = "idle", -- idle|scan|import|finalize
        timer = nil,
        savedUI = nil,
        files = {},
        fileIndex = 1,
        totalFiles = 0,
        completedFiles = 0,
        skippedFiles = 0,
        failedFiles = 0,
        totalObjects = 0,
        processedObjects = 0,
        currentFileName = "",
        cancelRequested = false,
        cancelReason = nil,
        importingFile = false,
        lastScanCount = previous and previous.lastScanCount or 0,
        suppressCancelToast = false
    }
end

groupAMMImportManager.state = createImportState()
groupAMMImportManager.pendingToasts = {}

local function queueToast(kind, duration, text)
    pipelineCommon.queueToast(groupAMMImportManager.pendingToasts, kind, duration, text)
end

local function haltTimer(state)
    if state and state.timer then
        Cron.Halt(state.timer)
        state.timer = nil
    end
end

local function finishRuntime(runtime, cancelled)
    haltTimer(runtime)
    runtime.active = false
    runtime.importingFile = false
    amm.progress = runtime.processedObjects or amm.progress or 0
    amm.total = math.max(1, runtime.totalObjects or 0)
    amm.importing = false

    local completedFiles = runtime.completedFiles or 0
    local totalFiles = runtime.totalFiles or 0
    local processedObjects = runtime.processedObjects or 0
    local totalObjects = runtime.totalObjects or 0

    if cancelled and not runtime.suppressCancelToast then
        local reason = runtime.cancelReason and (" (" .. runtime.cancelReason .. ")") or ""
        queueToast("warning", 3500, string.format("AMM import cancelled%s", reason))
    elseif not cancelled and totalFiles == 0 then
        queueToast("warning", 5000, "No valid AMM preset exports found in data/AMMImport.")
    elseif not cancelled and runtime.failedFiles > 0 then
        queueToast("warning", 6000, string.format("AMM import finished with %d file failures (%d/%d files, %d/%d objects).", runtime.failedFiles, completedFiles, totalFiles, processedObjects, totalObjects))
    elseif not cancelled then
        queueToast("success", 5000, string.format("AMM import finished (%d/%d files, %d/%d objects).", completedFiles, totalFiles, processedObjects, totalObjects))
    end

    if runtime.savedUI and runtime.savedUI.reload then
        local ok, err = pcall(function ()
            runtime.savedUI.reload()
        end)
        if not ok then
            print(string.format("[AMMImport] Failed to reload Saved UI: %s", tostring(err)))
        end
    end

    if groupAMMImportManager.state == runtime then
        groupAMMImportManager.state = createImportState(runtime)
    end
end

local function scanImportFiles(runtime)
    runtime.phase = "scan"
    runtime.files = {}
    runtime.fileIndex = 1
    runtime.totalFiles = 0
    runtime.completedFiles = 0
    runtime.skippedFiles = 0
    runtime.failedFiles = 0
    runtime.totalObjects = 0
    runtime.processedObjects = 0
    runtime.currentFileName = ""
    runtime.lastScanCount = 0

    for _, file in pairs(dir("data/AMMImport")) do
        if runtime.cancelRequested then
            return false
        end

        if file.name:match("^.+(%..+)$") == ".json" then
            runtime.lastScanCount = runtime.lastScanCount + 1
            local data = config.loadFile("data/AMMImport/" .. file.name)
            data.file_name = data.file_name or file.name

            if type(data.props) ~= "table" then
                runtime.skippedFiles = runtime.skippedFiles + 1
                print("[AMMImport] Skipped \"" .. file.name .. "\" because it is not an AMM preset export.")
            else
                table.insert(runtime.files, {
                    name = file.name,
                    data = data,
                    objectCount = #data.props
                })
                runtime.totalObjects = runtime.totalObjects + #data.props
                runtime.totalFiles = runtime.totalFiles + 1
            end
        end
    end

    return true
end

local function beginNextFile(runtime)
    if groupAMMImportManager.state ~= runtime or not runtime.active then
        return
    end

    if runtime.cancelRequested then
        finishRuntime(runtime, true)
        return
    end

    if runtime.fileIndex > runtime.totalFiles then
        runtime.phase = "finalize"
        finishRuntime(runtime, false)
        return
    end

    local entry = runtime.files[runtime.fileIndex]
    if not entry then
        runtime.failedFiles = runtime.failedFiles + 1
        runtime.completedFiles = runtime.completedFiles + 1
        runtime.fileIndex = runtime.fileIndex + 1
        beginNextFile(runtime)
        return
    end

    runtime.phase = "import"
    runtime.importingFile = true
    runtime.currentFileName = entry.name or "AMM_Preset"

    amm.importSinglePreset(entry.data, runtime.savedUI, {
        chunkQuantity = 60,
        timeBudgetMs = 15,
        maxInFlight = 20,
        shouldCancel = function ()
            local state = groupAMMImportManager.state
            return state ~= runtime or not runtime.active or runtime.cancelRequested
        end,
        onProgress = function (count)
            if groupAMMImportManager.state ~= runtime or not runtime.active then
                return
            end

            runtime.processedObjects = runtime.processedObjects + math.max(0, tonumber(count) or 0)
            amm.progress = runtime.processedObjects
        end,
        onFinished = function (result)
            if groupAMMImportManager.state ~= runtime or not runtime.active then
                return
            end

            runtime.importingFile = false

            if not result or result.success == false then
                runtime.failedFiles = runtime.failedFiles + 1
            end

            runtime.completedFiles = runtime.completedFiles + 1
            runtime.fileIndex = runtime.fileIndex + 1
            runtime.currentFileName = ""

            if result and result.cancelled then
                runtime.cancelRequested = true
            end

            beginNextFile(runtime)
        end
    })
end

---Start AMM preset import from data/AMMImport.
---@param request { savedUI: any }?
---@return boolean started
function groupAMMImportManager.start(request)
    if groupAMMImportManager.state.active then return false end
    if amm.importing then return false end
    if not request or not request.savedUI then return false end

    local runtime = createImportState(groupAMMImportManager.state)
    runtime.active = true
    runtime.phase = "scan"
    runtime.savedUI = request.savedUI
    amm.progress = 0
    amm.total = 1
    amm.importing = true
    groupAMMImportManager.state = runtime

    -- Delay one tick so UI can draw progress bar before heavy work begins.
    Cron.NextTick(function ()
        if groupAMMImportManager.state ~= runtime or not runtime.active then
            return
        end

        local ok, scanOk = pcall(function ()
            return scanImportFiles(runtime)
        end)

        if not ok then
            runtime.failedFiles = runtime.failedFiles + 1
            print(string.format("[AMMImport] Failed while scanning presets: %s", tostring(scanOk)))
            finishRuntime(runtime, false)
            return
        end

        if not scanOk then
            finishRuntime(runtime, true)
            return
        end

        amm.total = math.max(1, runtime.totalObjects or 0)
        beginNextFile(runtime)
    end)

    return true
end

---@return boolean
function groupAMMImportManager.isActive()
    return groupAMMImportManager.state.active == true
end

---@param reason string?
---@param suppressToast boolean?
---@return boolean cancelled
function groupAMMImportManager.cancel(reason, suppressToast)
    local runtime = groupAMMImportManager.state
    if not runtime.active then return false end

    runtime.cancelRequested = true
    runtime.cancelReason = reason
    runtime.suppressCancelToast = suppressToast == true

    if runtime.phase == "scan" or not runtime.importingFile then
        finishRuntime(runtime, true)
    end

    return true
end

function groupAMMImportManager.drawToasts()
    pipelineCommon.drawQueuedToasts(groupAMMImportManager.pendingToasts)
end

---@param style style
---@return boolean drawn
function groupAMMImportManager.drawProgress(style)
    local runtime = groupAMMImportManager.state
    if not runtime.active then return false end

    local progress = 0
    local phaseText = ""
    local counterText = ""
    local helpText = ""

    if runtime.phase == "scan" then
        progress = (math.sin(Cron.time * 4) + 1) * 0.5
        phaseText = "Scanning AMMImport presets"
        counterText = string.format("%d scanned", runtime.lastScanCount or 0)
        helpText = "Validating .json files before import."
    elseif runtime.phase == "import" then
        local totalObjects = math.max(1, runtime.totalObjects or 0)
        progress = math.min(1, (runtime.processedObjects or 0) / totalObjects)
        phaseText = string.format("Importing \"%s\"", runtime.currentFileName ~= "" and runtime.currentFileName or "AMM preset")
        counterText = string.format("%d/%d objects | %d/%d files", runtime.processedObjects or 0, runtime.totalObjects or 0, runtime.completedFiles or 0, runtime.totalFiles or 0)
        helpText = "Converting props to Saved groups in chunks."
    else
        progress = 1
        phaseText = "Finalizing AMM import"
        counterText = string.format("%d/%d files", runtime.completedFiles or 0, runtime.totalFiles or 0)
        helpText = "Writing imported groups to disk."
    end

    pipelineCommon.drawCancelableProgress({
        style = style,
        phaseText = phaseText,
        progress = progress,
        counterText = counterText,
        helpText = helpText,
        onCancel = function ()
            groupAMMImportManager.cancel("user request")
        end
    })

    return true
end

return groupAMMImportManager
