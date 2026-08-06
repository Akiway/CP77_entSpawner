local Cron = require("modules/utils/vendor/Cron")
local config = require("modules/utils/core/config")
local amm = require("modules/utils/pipeline/ammUtils")
local pipelineCommon = require("modules/utils/pipeline/common")
local logger = require("modules/utils/core/logger")
local sessionSnapshot = require("modules/utils/pipeline/sessionSnapshot")

local groupAMMImportManager = {}
local AMM_IMPORT_REPORT_SAMPLE_LIMIT = math.huge

---@param selectedPresetFiles table?
---@return table<string, boolean>?
local function normalizeSelectedPresetFiles(selectedPresetFiles)
    if type(selectedPresetFiles) ~= "table" then
        return nil
    end

    local set = {}
    local hasEntries = false
    for key, value in pairs(selectedPresetFiles) do
        local fileName = nil
        if type(key) == "number" then
            fileName = tostring(value or "")
        elseif value == true then
            fileName = tostring(key or "")
        end

        if fileName and fileName ~= "" then
            set[fileName] = true
            hasEntries = true
        end
    end

    if not hasEntries then
        return nil
    end

    return set
end

---@param selectedSet table<string, boolean>?
---@param includeData boolean?
---@return table
local function collectPresetCandidates(selectedSet, includeData)
    local candidates = {
        entries = {},
        invalid = {},
        scannedJson = 0,
        skippedInvalid = 0,
        totalObjects = 0,
        validFiles = 0
    }

    for _, file in pairs(dir("data/AMMImport")) do
        if file.name:match("^.+(%..+)$") == ".json" then
            local fileName = tostring(file.name or "")
            local include = selectedSet == nil or selectedSet[fileName] == true
            if include then
                candidates.scannedJson = candidates.scannedJson + 1

                local data = config.loadFile("data/AMMImport/" .. fileName)
                data = type(data) == "table" and data or {}
                data.file_name = data.file_name or fileName

                if type(data.props) ~= "table" then
                    candidates.skippedInvalid = candidates.skippedInvalid + 1
                    table.insert(candidates.invalid, {
                        fileName = fileName,
                        displayName = tostring(data.file_name or fileName),
                        reason = "missing_props_table"
                    })
                else
                    local objectCount = #data.props
                    table.insert(candidates.entries, {
                        name = fileName,
                        fileLabel = tostring(data.file_name or fileName),
                        objectCount = objectCount,
                        data = includeData ~= false and data or nil
                    })
                    candidates.totalObjects = candidates.totalObjects + objectCount
                    candidates.validFiles = candidates.validFiles + 1
                end
            end
        end
    end

    return candidates
end

local function createImportReport()
    local startedAt = os.time()

    return {
        sampleLimit = AMM_IMPORT_REPORT_SAMPLE_LIMIT,
        status = "running",
        startedAt = startedAt,
        startedAtIso = os.date("%Y-%m-%d %H:%M:%S", startedAt),
        finishedAt = nil,
        finishedAtIso = nil,
        durationMs = 0,
        cancelReason = nil,
        scan = {
            jsonScanned = 0,
            validFiles = 0,
            skippedInvalidFiles = 0,
            failedFiles = 0
        },
        totals = {
            files = {
                valid = 0,
                completed = 0,
                failed = 0,
                skippedInvalid = 0
            },
            objects = {
                total = 0,
                processed = 0,
                imported = 0,
                skipped = 0,
                failed = 0
            }
        },
        issueCounts = {},
        issueSamples = {},
        files = {},
        _clockStartedMs = pipelineCommon.nowMs()
    }
end

---@param report table
---@param issueKey string
---@return table
local function ensureIssueBucket(report, issueKey)
    local bucket = report.issueSamples[issueKey]
    if bucket then
        return bucket
    end

    bucket = {
        sampleLimit = report.sampleLimit or AMM_IMPORT_REPORT_SAMPLE_LIMIT,
        truncated = 0,
        samples = {}
    }
    report.issueSamples[issueKey] = bucket
    return bucket
end

---@param report table?
---@param issueKey string
---@param sample any
---@param count number?
local function addReportIssue(report, issueKey, sample, count)
    if type(report) ~= "table" or type(issueKey) ~= "string" or issueKey == "" then
        return
    end

    local increment = math.max(1, math.floor(tonumber(count) or 1))
    report.issueCounts[issueKey] = (report.issueCounts[issueKey] or 0) + increment

    if sample == nil then
        return
    end

    local normalizedSample = sample
    if type(normalizedSample) ~= "table" then
        normalizedSample = { message = tostring(sample) }
    end

    local bucket = ensureIssueBucket(report, issueKey)
    local cap = math.max(1, tonumber(bucket.sampleLimit) or AMM_IMPORT_REPORT_SAMPLE_LIMIT)
    if #bucket.samples < cap then
        table.insert(bucket.samples, normalizedSample)
    else
        bucket.truncated = (bucket.truncated or 0) + 1
    end
end

---@param report table?
---@param summary table
local function appendFileSummary(report, summary)
    if type(report) ~= "table" or type(summary) ~= "table" then
        return
    end

    report.files = report.files or {}
    table.insert(report.files, summary)
end

---@param report table?
---@param runtime table
local function syncReportFromRuntime(report, runtime)
    if type(report) ~= "table" or type(runtime) ~= "table" then
        return
    end

    report.scan.jsonScanned = runtime.lastScanCount or 0
    report.scan.validFiles = runtime.totalFiles or 0
    report.scan.skippedInvalidFiles = runtime.skippedFiles or 0
    report.scan.failedFiles = runtime.failedFiles or 0

    report.totals.files.valid = runtime.totalFiles or 0
    report.totals.files.completed = runtime.completedFiles or 0
    report.totals.files.failed = runtime.failedFiles or 0
    report.totals.files.skippedInvalid = runtime.skippedFiles or 0

    report.totals.objects.total = runtime.totalObjects or 0
    if (runtime.processedObjects or 0) > (report.totals.objects.processed or 0) then
        report.totals.objects.processed = runtime.processedObjects or 0
    end
end

---@param report table?
---@param entryName string?
---@param result table?
local function mergeFileResultIntoReport(report, entryName, result)
    if type(report) ~= "table" then
        return
    end

    local resultReport = result and result.report
    local fileStats = resultReport and resultReport.fileStats or {}
    local fileName = tostring(fileStats.fileName or (result and result.fileName) or entryName or "AMM_Preset")
    local processed = math.max(0, tonumber(fileStats.processed) or 0)
    local imported = math.max(0, tonumber(fileStats.imported) or 0)
    local skipped = math.max(0, tonumber(fileStats.skipped) or 0)
    local failed = math.max(0, tonumber(fileStats.failed) or 0)
    local totalProps = math.max(0, tonumber(fileStats.totalProps) or 0)
    local saveError = nil
    if result and result.saveError ~= nil then
        saveError = tostring(result.saveError)
    elseif fileStats.saveError ~= nil then
        saveError = tostring(fileStats.saveError)
    end

    local hasResult = type(result) == "table"
    local cancelled = hasResult and result.cancelled == true or false
    local success = hasResult and result.success == true or false
    local status = "issues"
    if not hasResult then
        status = "failed"
    elseif cancelled then
        status = "cancelled"
    elseif success then
        status = "success"
    elseif saveError ~= nil or failed > 0 then
        status = "failed"
    end

    appendFileSummary(report, {
        fileName = fileName,
        totalProps = totalProps,
        processed = processed,
        imported = imported,
        skipped = skipped,
        failed = failed,
        success = success,
        cancelled = cancelled,
        status = status,
        saveError = saveError
    })

    report.totals.objects.imported = (report.totals.objects.imported or 0) + imported
    report.totals.objects.skipped = (report.totals.objects.skipped or 0) + skipped
    report.totals.objects.failed = (report.totals.objects.failed or 0) + failed

    local issueCounts = resultReport and resultReport.issueCounts or nil
    if type(issueCounts) == "table" then
        for issueKey, issueCount in pairs(issueCounts) do
            report.issueCounts[issueKey] = (report.issueCounts[issueKey] or 0) + math.max(0, tonumber(issueCount) or 0)
        end
    end

    local issueSamples = resultReport and resultReport.issueSamples or nil
    if type(issueSamples) == "table" then
        for issueKey, sampleData in pairs(issueSamples) do
            local bucket = ensureIssueBucket(report, issueKey)
            local cap = math.max(1, tonumber(bucket.sampleLimit) or AMM_IMPORT_REPORT_SAMPLE_LIMIT)
            local sourceSamples = sampleData and sampleData.samples or {}
            for _, sample in ipairs(sourceSamples) do
                if #bucket.samples < cap then
                    table.insert(bucket.samples, sample)
                else
                    bucket.truncated = (bucket.truncated or 0) + 1
                end
            end
            local sourceTruncated = math.max(0, tonumber(sampleData and sampleData.truncated) or 0)
            bucket.truncated = (bucket.truncated or 0) + sourceTruncated
        end
    end
end

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
        suppressCancelToast = false,
        report = nil,
        selectedPresetFiles = nil
    }
end

groupAMMImportManager.state = createImportState()
groupAMMImportManager.pendingToasts = {}
groupAMMImportManager.lastReport = nil
groupAMMImportManager.lastReportVersion = 0

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
    syncReportFromRuntime(runtime.report, runtime)

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

    if runtime.report then
        local finishedAt = os.time()
        runtime.report.finishedAt = finishedAt
        runtime.report.finishedAtIso = os.date("%Y-%m-%d %H:%M:%S", finishedAt)
        runtime.report.durationMs = math.max(0, math.floor((pipelineCommon.nowMs() - (runtime.report._clockStartedMs or pipelineCommon.nowMs())) + 0.5))
        runtime.report.cancelReason = runtime.cancelReason
        runtime.report._clockStartedMs = nil

        local issueCount = 0
        for _, count in pairs(runtime.report.issueCounts or {}) do
            issueCount = issueCount + math.max(0, tonumber(count) or 0)
        end

        if cancelled then
            runtime.report.status = "cancelled"
        elseif totalFiles == 0 then
            runtime.report.status = "no_valid_files"
        elseif runtime.failedFiles > 0 then
            runtime.report.status = "failed"
        elseif issueCount > 0 then
            runtime.report.status = "success_with_issues"
        else
            runtime.report.status = "success"
        end

        groupAMMImportManager.lastReport = runtime.report
        groupAMMImportManager.lastReportVersion = (groupAMMImportManager.lastReportVersion or 0) + 1
    end

    if runtime.savedUI and runtime.savedUI.reload then
        local ok, err = pcall(function ()
            runtime.savedUI.reload()
        end)
        if not ok then
            logger:error(string.format("[AMMImport] Failed to reload Saved UI: %s", tostring(err)))
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

    local candidates = collectPresetCandidates(runtime.selectedPresetFiles, true)
    if runtime.cancelRequested then
        return false
    end

    runtime.files = candidates.entries
    runtime.lastScanCount = candidates.scannedJson
    runtime.skippedFiles = candidates.skippedInvalid
    runtime.totalFiles = candidates.validFiles
    runtime.totalObjects = candidates.totalObjects

    for _, invalid in ipairs(candidates.invalid or {}) do
        logger:info("[AMMImport] Skipped \"" .. tostring(invalid.fileName or "unknown") .. "\" because it is not an AMM preset export.")
        addReportIssue(runtime.report, "invalid_preset_missing_props_table", {
            fileName = tostring(invalid.fileName or "unknown")
        })
        appendFileSummary(runtime.report, {
            fileName = tostring(invalid.fileName or "unknown"),
            totalProps = 0,
            processed = 0,
            imported = 0,
            skipped = 0,
            failed = 0,
            success = false,
            cancelled = false,
            status = "skipped_invalid",
            error = tostring(invalid.reason or "missing_props_table")
        })
    end

    syncReportFromRuntime(runtime.report, runtime)
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
        addReportIssue(runtime.report, "missing_scan_entry", {
            fileIndex = runtime.fileIndex
        })
        appendFileSummary(runtime.report, {
            fileName = string.format("entry_%d", runtime.fileIndex),
            totalProps = 0,
            processed = 0,
            imported = 0,
            skipped = 0,
            failed = 0,
            success = false,
            cancelled = false,
            status = "failed",
            error = "missing_scan_entry"
        })
        syncReportFromRuntime(runtime.report, runtime)
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
            syncReportFromRuntime(runtime.report, runtime)
        end,
        onFinished = function (result)
            if groupAMMImportManager.state ~= runtime or not runtime.active then
                return
            end

            runtime.importingFile = false

            if not result or result.success == false then
                runtime.failedFiles = runtime.failedFiles + 1
            end

            mergeFileResultIntoReport(runtime.report, entry.name, result)
            runtime.completedFiles = runtime.completedFiles + 1
            runtime.fileIndex = runtime.fileIndex + 1
            runtime.currentFileName = ""
            syncReportFromRuntime(runtime.report, runtime)

            if result and result.cancelled then
                runtime.cancelRequested = true
            end

            beginNextFile(runtime)
        end
    })
end

---Start AMM preset import from data/AMMImport.
---@param request { savedUI: any, selectedPresetFiles: table? }?
---@return boolean started
function groupAMMImportManager.start(request)
    if groupAMMImportManager.state.active then return false end
    if amm.importing then return false end
    if not request or not request.savedUI then return false end

    sessionSnapshot.consume("imported AMM presets")

    local runtime = createImportState(groupAMMImportManager.state)
    runtime.active = true
    runtime.phase = "scan"
    runtime.savedUI = request.savedUI
    runtime.report = createImportReport()
    runtime.selectedPresetFiles = normalizeSelectedPresetFiles(request.selectedPresetFiles)
    if type(request.selectedPresetFiles) == "table" and runtime.selectedPresetFiles == nil then
        runtime.selectedPresetFiles = {}
    end
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
            logger:warn(string.format("[AMMImport] Failed while scanning presets: %s", tostring(scanOk)))
            addReportIssue(runtime.report, "scan_failed", {
                detail = tostring(scanOk)
            })
            syncReportFromRuntime(runtime.report, runtime)
            finishRuntime(runtime, false)
            return
        end

        if not scanOk then
            finishRuntime(runtime, true)
            return
        end

        amm.total = math.max(1, runtime.totalObjects or 0)
        beginNextFile(runtime)
    end, {})

    return true
end

---@return boolean
function groupAMMImportManager.isActive()
    return groupAMMImportManager.state.active == true
end

---@return table?
function groupAMMImportManager.getLastReport()
    return groupAMMImportManager.lastReport
end

---@return integer
function groupAMMImportManager.getLastReportVersion()
    return tonumber(groupAMMImportManager.lastReportVersion) or 0
end

---@param selectedPresetFiles table?
---@return table
function groupAMMImportManager.listImportablePresets(selectedPresetFiles)
    local selectedSet = normalizeSelectedPresetFiles(selectedPresetFiles)
    if type(selectedPresetFiles) == "table" and selectedSet == nil then
        selectedSet = {}
    end
    local candidates = collectPresetCandidates(selectedSet, false)
    local presets = {}

    for _, entry in ipairs(candidates.entries or {}) do
        table.insert(presets, {
            fileName = tostring(entry.name or ""),
            displayName = tostring(entry.fileLabel or entry.name or ""),
            objectCount = math.max(0, tonumber(entry.objectCount) or 0)
        })
    end

    table.sort(presets, function (a, b)
        local aName = tostring(a.displayName or a.fileName or ""):lower()
        local bName = tostring(b.displayName or b.fileName or ""):lower()
        if aName == bName then
            return tostring(a.fileName or ""):lower() < tostring(b.fileName or ""):lower()
        end
        return aName < bName
    end)

    return {
        presets = presets,
        jsonScanned = math.max(0, tonumber(candidates.scannedJson) or 0),
        skippedInvalid = math.max(0, tonumber(candidates.skippedInvalid) or 0),
        totalObjects = math.max(0, tonumber(candidates.totalObjects) or 0)
    }
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
