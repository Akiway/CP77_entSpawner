local style = require("modules/ui/style")
local groupAMMImportManager = require("modules/utils/pipeline/groupAMMImportManager")

local ammImportReportPopup = {
    popupId = "AMM Import Report",
    openRequested = false,
    lastSeenReportVersion = 0
}

local AMM_IMPORT_ISSUE_META = {
    scan_failed = { label = "Scan failed", severity = "error" },
    missing_scan_entry = { label = "Missing scanned file entry", severity = "error" },
    invalid_preset_missing_props_table = { label = "Invalid preset (missing props table)", severity = "warning" },
    missing_props_table = { label = "Missing props table", severity = "warning" },
    cancel_callback_failed = { label = "Cancel callback failed", severity = "error" },
    prop_parse_failed = { label = "Prop parse failed", severity = "error" },
    light_import_failed = { label = "Light import failed", severity = "error" },
    vehicle_skipped = { label = "Vehicle skipped", severity = "warning" },
    resource_missing = { label = "Resource missing", severity = "warning" },
    temp_entity_despawn_failed = { label = "Temp entity despawn failed", severity = "warning" },
    spawn_data_load_failed = { label = "Spawn data load failed", severity = "error" },
    prop_import_failed = { label = "Prop import failed", severity = "error" },
    temp_entity_spawn_failed = { label = "Temp entity spawn failed", severity = "error" },
    save_failed = { label = "Save failed", severity = "error" }
}

---@param value any
---@return number
local function toNonNegativeNumber(value)
    return math.max(0, tonumber(value) or 0)
end

---@param durationMs number
---@return string
local function formatDurationMs(durationMs)
    local ms = toNonNegativeNumber(durationMs)
    if ms < 1000 then
        return string.format("%d ms", math.floor(ms + 0.5))
    end

    local seconds = ms / 1000
    if seconds < 60 then
        return string.format("%.2f s", seconds)
    end

    local minutes = math.floor(seconds / 60)
    local remSeconds = seconds - minutes * 60
    return string.format("%dm %.1fs", minutes, remSeconds)
end

---@param text string
---@param maxLen number
---@return string
local function clampText(text, maxLen)
    local source = tostring(text or "")
    if #source <= maxLen then
        return source
    end

    return source:sub(1, math.max(0, maxLen - 3)) .. "..."
end

---@param lines string[]
---@param label string
---@param value any
local function appendIssueSampleLine(lines, label, value)
    if value == nil then
        return
    end

    local text = tostring(value)
    if text == "" then
        return
    end

    table.insert(lines, string.format("%s: %s", label, clampText(text, 220)))
end

---@param sample table?
---@return string[]
local function formatIssueSampleLines(sample)
    if type(sample) ~= "table" then
        return {}
    end

    local lines = {}
    appendIssueSampleLine(lines, "File", sample.fileName)
    appendIssueSampleLine(lines, "Prop", sample.propName)
    appendIssueSampleLine(lines, "Path", sample.path)
    appendIssueSampleLine(lines, "Detail", sample.detail or sample.message or sample.error)
    appendIssueSampleLine(lines, "File index", sample.fileIndex)
    return lines
end

---@param severity string?
---@return integer
local function getSeverityOrder(severity)
    if severity == "error" then return 1 end
    if severity == "warning" then return 2 end
    return 3
end

---@param status string?
---@return integer
local function getFileStatusOrder(status)
    if status == "failed" then return 1 end
    if status == "cancelled" then return 2 end
    if status == "issues" then return 3 end
    if status == "skipped_invalid" then return 4 end
    if status == "success" then return 5 end
    return 6
end

---@param severity string?
---@return number
local function getSeverityColor(severity)
    if severity == "error" then
        return 0xFF0000FF
    end

    if severity == "warning" then
        return style.warnColor
    end

    return style.mutedColor
end

---@param status string?
---@return string
local function getFileStatusLabel(status)
    if status == "success" then return "Success" end
    if status == "failed" then return "Failed" end
    if status == "cancelled" then return "Cancelled" end
    if status == "issues" then return "Completed with issues" end
    if status == "skipped_invalid" then return "Skipped invalid preset" end
    return "Unknown"
end

---@param status string?
---@return number
local function getFileStatusColor(status)
    if status == "success" then
        return style.successColor
    end

    if status == "failed" then
        return 0xFF0000FF
    end

    if status == "cancelled" or status == "issues" or status == "skipped_invalid" then
        return style.warnColor
    end

    return style.mutedColor
end

---@param status string?
---@return string
---@return number
local function getReportStatusDisplay(status)
    if status == "success" then
        return "Success", style.successColor
    end

    if status == "success_with_issues" then
        return "Success with issues", style.warnColor
    end

    if status == "failed" then
        return "Failed", 0xFF0000FF
    end

    if status == "cancelled" then
        return "Cancelled", style.warnColor
    end

    if status == "no_valid_files" then
        return "No valid AMM presets found", style.warnColor
    end

    return "Unknown", style.mutedColor
end

function ammImportReportPopup.syncAutoOpen()
    local latestReportVersion = groupAMMImportManager.getLastReportVersion()
    if latestReportVersion > (ammImportReportPopup.lastSeenReportVersion or 0) then
        ammImportReportPopup.lastSeenReportVersion = latestReportVersion
        ammImportReportPopup.openRequested = true
    end
end

---@return boolean
function ammImportReportPopup.hasReport()
    return type(groupAMMImportManager.getLastReport()) == "table"
end

function ammImportReportPopup.requestOpen()
    ammImportReportPopup.openRequested = true
end

---@return boolean drawn
function ammImportReportPopup.draw()
    if ammImportReportPopup.openRequested then
        ImGui.OpenPopup(ammImportReportPopup.popupId)
        ammImportReportPopup.openRequested = false
    end

    local defaultWidth = 820 * style.viewSize
    local defaultHeight = 700 * style.viewSize
    local minWidth = 620 * style.viewSize
    local minHeight = 460 * style.viewSize
    local screenWidth, screenHeight = GetDisplayResolution()
    local maxWidth = math.max(minWidth, screenWidth - 40 * style.viewSize)
    local maxHeight = math.max(minHeight, screenHeight - 40 * style.viewSize)
    ImGui.SetNextWindowSize(defaultWidth, defaultHeight, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSizeConstraints(minWidth, minHeight, maxWidth, maxHeight)

    if not ImGui.BeginPopupModal(ammImportReportPopup.popupId, true) then
        return false
    end

    local report = groupAMMImportManager.getLastReport()
    if type(report) ~= "table" then
        ImGui.Text("No AMM import report is available yet.")
        ImGui.Dummy(0, 8 * style.viewSize)
        if ImGui.Button("Close##ammImportReportCloseEmpty") then
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
        return true
    end

    local statusText, statusColor = getReportStatusDisplay(report.status)
    style.styledText("Status: " .. statusText, statusColor)

    local startedAtText = tostring(report.startedAtIso or "-")
    local finishedAtText = tostring(report.finishedAtIso or "-")
    local durationText = formatDurationMs(report.durationMs or 0)
    style.mutedText(string.format("Started: %s | Finished: %s | Duration: %s", startedAtText, finishedAtText, durationText))
    if report.cancelReason and tostring(report.cancelReason) ~= "" then
        style.mutedText("Cancel reason: " .. tostring(report.cancelReason))
    end

    ImGui.Dummy(0, 8 * style.viewSize)
    style.mutedText("Overview")
    ImGui.Separator()

    local scan = report.scan or {}
    local fileTotals = report.totals and report.totals.files or {}
    local objectTotals = report.totals and report.totals.objects or {}
    ImGui.Text(string.format(
        "Files: %d valid | %d completed | %d failed | %d skipped invalid | %d scanned",
        toNonNegativeNumber(scan.validFiles or fileTotals.valid),
        toNonNegativeNumber(fileTotals.completed),
        toNonNegativeNumber(fileTotals.failed),
        toNonNegativeNumber(scan.skippedInvalidFiles or fileTotals.skippedInvalid),
        toNonNegativeNumber(scan.jsonScanned)))
    ImGui.Text(string.format(
        "Objects: %d total | %d processed | %d imported | %d skipped | %d failed",
        toNonNegativeNumber(objectTotals.total),
        toNonNegativeNumber(objectTotals.processed),
        toNonNegativeNumber(objectTotals.imported),
        toNonNegativeNumber(objectTotals.skipped),
        toNonNegativeNumber(objectTotals.failed)))

    ImGui.Dummy(0, 8 * style.viewSize)
    style.mutedText("Issues")
    ImGui.Separator()

    local issueRows = {}
    for issueKey, issueCount in pairs(report.issueCounts or {}) do
        local count = toNonNegativeNumber(issueCount)
        if count > 0 then
            local meta = AMM_IMPORT_ISSUE_META[issueKey] or {
                label = tostring(issueKey),
                severity = "warning"
            }
            local sampleData = report.issueSamples and report.issueSamples[issueKey] or {}
            local samples = {}
            for _, issueSample in ipairs(sampleData.samples or {}) do
                table.insert(samples, issueSample)
            end

            table.insert(issueRows, {
                key = issueKey,
                count = count,
                meta = meta,
                samples = samples,
                truncated = toNonNegativeNumber(sampleData.truncated)
            })
        end
    end

    table.sort(issueRows, function(a, b)
        local aSeverity = getSeverityOrder(a.meta and a.meta.severity)
        local bSeverity = getSeverityOrder(b.meta and b.meta.severity)
        if aSeverity == bSeverity then
            if a.count == b.count then
                return tostring(a.meta and a.meta.label or a.key):lower() < tostring(b.meta and b.meta.label or b.key):lower()
            end
            return a.count > b.count
        end
        return aSeverity < bSeverity
    end)

    local issueHeight = 240 * style.viewSize
    ImGui.BeginChild("##ammImportReportIssues", 0, issueHeight, true)
    if #issueRows == 0 then
        style.mutedText("No issues recorded.")
    else
        for _, row in ipairs(issueRows) do
            local label = tostring(row.meta and row.meta.label or row.key)
            local severity = tostring(row.meta and row.meta.severity or "warning")
            local header = string.format("[%s] %s (%d)##ammImportIssueType:%s", severity, label, row.count, row.key)
            style.pushStyleColor(true, ImGuiCol.Text, getSeverityColor(severity))
            local opened = ImGui.TreeNodeEx(header)
            style.popStyleColor(true)
            if opened then
                if #row.samples == 0 then
                    style.mutedText("No issue details recorded.")
                else
                    for sampleIndex, sample in ipairs(row.samples) do
                        local sampleLines = formatIssueSampleLines(sample)
                        if #sampleLines == 0 then
                            sampleLines = { "Detail: (empty issue payload)" }
                        end

                        style.mutedText(string.format("Issue %d", sampleIndex))
                        ImGui.Indent(8 * style.viewSize)
                        for _, sampleLine in ipairs(sampleLines) do
                            style.styledTextWrapped(sampleLine, style.mutedColor)
                        end
                        ImGui.Unindent(8 * style.viewSize)
                        ImGui.Separator()
                    end
                end

                if row.truncated > 0 then
                    style.mutedText(string.format("Missing %d issue entries in this snapshot.", row.truncated))
                end

                ImGui.TreePop()
            end

            ImGui.Separator()
        end
    end
    ImGui.EndChild()

    ImGui.Dummy(0, 8 * style.viewSize)
    style.mutedText("Per-file outcomes")
    ImGui.Separator()

    local fileRows = {}
    for _, row in ipairs(report.files or {}) do
        table.insert(fileRows, row)
    end

    table.sort(fileRows, function(a, b)
        local statusA = getFileStatusOrder(a and a.status)
        local statusB = getFileStatusOrder(b and b.status)
        if statusA == statusB then
            return tostring(a and a.fileName or ""):lower() < tostring(b and b.fileName or ""):lower()
        end
        return statusA < statusB
    end)

    local fileHeight = 220 * style.viewSize
    ImGui.BeginChild("##ammImportReportFiles", 0, fileHeight, true)
    if #fileRows == 0 then
        style.mutedText("No file entries recorded.")
    else
        for _, row in ipairs(fileRows) do
            local status = tostring(row.status or "unknown")
            local statusLabel = getFileStatusLabel(status)
            local title = string.format("%s - %s", tostring(row.fileName or "unknown"), statusLabel)
            style.styledText(title, getFileStatusColor(status))

            style.mutedText(string.format(
                "Objects: %d total | %d processed | %d imported | %d skipped | %d failed",
                toNonNegativeNumber(row.totalProps),
                toNonNegativeNumber(row.processed),
                toNonNegativeNumber(row.imported),
                toNonNegativeNumber(row.skipped),
                toNonNegativeNumber(row.failed)))

            if row.saveError then
                style.mutedText("Save error: " .. clampText(tostring(row.saveError), 220))
            end

            if row.error then
                style.mutedText("Reason: " .. clampText(tostring(row.error), 220))
            end

            ImGui.Separator()
        end
    end
    ImGui.EndChild()

    ImGui.Dummy(0, 8 * style.viewSize)
    if ImGui.Button("Close##ammImportReportClose") then
        ImGui.CloseCurrentPopup()
    end

    ImGui.EndPopup()
    return true
end

return ammImportReportPopup
