local settings = require("modules/utils/settings")
local style = require("modules/ui/style")

local perf = {
    metrics = {},
    metricOrder = {},
    maxSamples = 180
}

---@return file*?, string, string?
local function openBenchmarkLogFile()
    local candidates = {
        "mods\\entSpawner\\benchmark.log",
        "benchmark.log"
    }

    for _, path in ipairs(candidates) do
        local file, err = io.open(path, "a")
        if file then
            return file, path, nil
        end
        if err then
            -- Continue trying fallbacks; keep the last error in case all fail.
            local lastErr = err
            if path == candidates[#candidates] then
                return nil, path, tostring(lastErr)
            end
        end
    end

    return nil, "benchmark.log", "Failed to resolve benchmark.log path"
end

---@return number
local function nowMs()
    return os.clock() * 1000
end

---@param metric table
---@return number
local function calculateP95(metric)
    if not metric or not metric.samples then
        return 0
    end

    local values = {}
    for _, sample in pairs(metric.samples) do
        table.insert(values, sample)
    end

    if #values == 0 then
        return 0
    end

    table.sort(values)
    local index = math.max(1, math.ceil(#values * 0.95))

    return values[index]
end

---@param name string
---@return table
local function getOrCreateMetric(name)
    if perf.metrics[name] then
        return perf.metrics[name]
    end

    local metric = {
        name = name,
        calls = 0,
        totalMs = 0,
        lastMs = 0,
        maxMs = 0,
        samples = {},
        sampleIndex = 1
    }

    perf.metrics[name] = metric
    table.insert(perf.metricOrder, name)

    return metric
end

---@param name string
---@param durationMs number
function perf.record(name, durationMs)
    local metric = getOrCreateMetric(name)

    metric.calls = metric.calls + 1
    metric.totalMs = metric.totalMs + durationMs
    metric.lastMs = durationMs
    metric.maxMs = math.max(metric.maxMs, durationMs)

    metric.samples[metric.sampleIndex] = durationMs
    metric.sampleIndex = metric.sampleIndex + 1
    if metric.sampleIndex > perf.maxSamples then
        metric.sampleIndex = 1
    end
end

---@param name string
---@param fn function
function perf.measure(name, fn)
    if not settings.spawnedUIPerfEnabled then
        return fn()
    end

    local startMs = nowMs()
    local a, b, c, d, e, f, g, h = fn()
    local durationMs = nowMs() - startMs
    perf.record(name, durationMs)

    return a, b, c, d, e, f, g, h
end

function perf.reset()
    perf.metrics = {}
    perf.metricOrder = {}
end

---@return string
function perf.getSummaryText()
    local lines = { "Spawned UI profiler snapshot" }

    for _, name in ipairs(perf.metricOrder) do
        local metric = perf.metrics[name]
        if metric and metric.calls > 0 then
            local avg = metric.totalMs / metric.calls
            local p95 = calculateP95(metric)
            table.insert(lines, string.format("%s | calls=%d avg=%.3fms p95=%.3fms max=%.3fms total=%.3fms", name, metric.calls, avg, p95, metric.maxMs, metric.totalMs))
        end
    end

    return table.concat(lines, "\n")
end

---@return boolean, integer, string, string?
function perf.exportSnapshotToLog()
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local snapshot = perf.getSummaryText()
    local file, logPath, err = openBenchmarkLogFile()

    if not file then
        return false, 0, logPath, tostring(err)
    end

    local count = 0
    file:write(string.format("Snapshot exported at %s\n", timestamp))

    for line in string.gmatch(snapshot, "([^\n]+)") do
        file:write(line .. "\n")
        count = count + 1
    end
    file:write("\n")
    file:close()

    return true, count, logPath, nil
end

function perf.drawPanel()
    if not settings.spawnedUIPerfEnabled or not settings.spawnedUIPerfShowPanel then
        return
    end

    ImGui.SetNextWindowSize(620 * style.viewSize, 360 * style.viewSize, ImGuiCond.FirstUseEver)
    if ImGui.Begin("Spawned UI Profiler", ImGuiWindowFlags.NoCollapse) then
        style.mutedText("Rolling window: " .. tostring(perf.maxSamples) .. " samples per metric")

        if ImGui.Button("Reset Metrics") then
            perf.reset()
        end

        ImGui.SameLine()
        if ImGui.Button("Copy Snapshot") then
            ImGui.SetClipboardText(perf.getSummaryText())
        end

        ImGui.SameLine()
        if ImGui.Button("Export Snapshot to log") then
            local ok, lines, _, err = perf.exportSnapshotToLog()
            if ok then
                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Exported profiler snapshot (%d lines)", lines)))
            else
                local warningType = (ImGui.ToastType and ImGui.ToastType.Warning) and ImGui.ToastType.Warning or ImGui.ToastType.Success
                ImGui.ShowToast(ImGui.Toast.new(warningType, 3500, "Failed to export profiler snapshot: " .. tostring(err)))
            end
        end
        style.tooltip("Append the current Spawned UI profiler snapshot to benchmark.log")

        if ImGui.BeginTable("##spawnedPerfTable", 7, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.ScrollY + ImGuiTableFlags.SizingStretchProp) then
            ImGui.TableSetupColumn("Metric")
            ImGui.TableSetupColumn("Calls")
            ImGui.TableSetupColumn("Last (ms)")
            ImGui.TableSetupColumn("Avg (ms)")
            ImGui.TableSetupColumn("P95 (ms)")
            ImGui.TableSetupColumn("Max (ms)")
            ImGui.TableSetupColumn("Total (ms)")
            ImGui.TableHeadersRow()

            for _, name in ipairs(perf.metricOrder) do
                local metric = perf.metrics[name]

                if metric then
                    local avg = metric.calls > 0 and (metric.totalMs / metric.calls) or 0
                    local p95 = calculateP95(metric)

                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    ImGui.Text(metric.name)
                    ImGui.TableSetColumnIndex(1)
                    ImGui.Text(tostring(metric.calls))
                    ImGui.TableSetColumnIndex(2)
                    ImGui.Text(string.format("%.3f", metric.lastMs))
                    ImGui.TableSetColumnIndex(3)
                    ImGui.Text(string.format("%.3f", avg))
                    ImGui.TableSetColumnIndex(4)
                    ImGui.Text(string.format("%.3f", p95))
                    ImGui.TableSetColumnIndex(5)
                    ImGui.Text(string.format("%.3f", metric.maxMs))
                    ImGui.TableSetColumnIndex(6)
                    ImGui.Text(string.format("%.3f", metric.totalMs))
                end
            end

            ImGui.EndTable()
        end

        ImGui.End()
    end
end

return perf
