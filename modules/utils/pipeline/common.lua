local utils = require("modules/utils/core/utils")
local settings = require("modules/utils/core/settings")

local pipelineCommon = {}

---Fragments written between clock checks. Reading the clock per fragment costs more than the write
---does on small fragments, and overshooting by a few hundred of them is far below one frame.
local FRAGMENTS_PER_CHECK = 256

---@alias pipelineToastKind "info"|"warning"|"error"|"success"|string

---@class pipelineToastEntry
---@field type integer Resolved `ImGui.ToastType` value.
---@field duration number Toast display time in milliseconds.
---@field text string Toast message.

---@class pipelineProgressStyle
---@field viewSize number UI scale multiplier.
---@field mutedText fun(text: string) Renders muted label/help text.
---@field spacedSeparator fun() Renders a separator with vertical spacing.

---@class pipelineProgressOptions
---@field style pipelineProgressStyle Rendering helpers and scale values.
---@field phaseText string? Main phase label.
---@field progress number? Progress ratio clamped to `[0, 1]`.
---@field counterText string? Optional counter shown on the same line as the bar.
---@field helpText string? Optional secondary/help line.
---@field cancelText string? Cancel button label. Defaults to `"Cancel"`.
---@field barWidth number? Progress bar width in pixels.
---@field barHeight number? Progress bar height in pixels.
---@field barOverlay string? Optional bar overlay text.
---@field showSeparator boolean? When `false`, omits the trailing separator.
---@field onCancel fun()? Optional callback fired when the cancel button is clicked.

---Returns current `os.clock` time in milliseconds.
---Used for short elapsed-time budget checks (`nowMs() - startedAt`).
---@return number milliseconds
function pipelineCommon.nowMs()
    return os.clock() * 1000
end

---How much wall clock a frame-budgeted pipeline step may spend, from the user setting.
---@return number milliseconds Clamped to a range that stays invisible but still makes progress.
function pipelineCommon.budgetMs()
    return math.max(0.5, math.min(tonumber(settings.persistenceBudgetMs) or 4, 16))
end

---`os.clock` value at which the current step must stop.
---@param milliseconds number? Overrides the configured budget.
---@return number deadline
function pipelineCommon.frameDeadline(milliseconds)
    return os.clock() + (milliseconds or pipelineCommon.budgetMs()) / 1000
end

---Budget left before a deadline, for passing on to a nested budgeted step.
---Never returns zero: a step that is handed no budget at all cannot make progress, so it would spin
---across frames without ever finishing.
---@param deadline number
---@return number milliseconds
function pipelineCommon.remainingMs(deadline)
    return math.max(0.5, (deadline - os.clock()) * 1000)
end

---Streams string fragments into an open file until the iterator runs dry or the deadline passes.
---
---Both the auto-save writer and the session snapshot push a rope (see `saveState.ropeIterator`) of a
---potentially multi-megabyte document through this, a slice per frame, so the document never has to
---exist as a single string.
---@param nextFragment fun(): string? Iterator yielding the next fragment, `nil` when exhausted.
---@param file file* Open write handle.
---@param deadline number `os.clock` value at which to pause.
---@param fragmentsPerCheck integer? Fragments between clock checks.
---@return "done"|"running"|"failed" status
---@return integer written Bytes written by this call, including those of a run that then failed.
---@return string? err Error text when the status is `"failed"`.
function pipelineCommon.streamFragments(nextFragment, file, deadline, fragmentsPerCheck)
    local limit = fragmentsPerCheck or FRAGMENTS_PER_CHECK
    local written = 0
    local exhausted = false

    -- One pcall around the whole chunk rather than one per fragment: a closure per fragment meant
    -- allocating hundreds of thousands of them for a large document, which cost more than the writing.
    -- `written` is an upvalue, so a partial run is still reported when a write throws.
    local ok, err = pcall(function()
        local sinceCheck = 0

        while true do
            local fragment = nextFragment()
            if fragment == nil then
                exhausted = true
                return
            end

            file:write(fragment)
            written = written + #fragment

            sinceCheck = sinceCheck + 1
            if sinceCheck >= limit then
                sinceCheck = 0
                if os.clock() >= deadline then return end
            end
        end
    end)

    if not ok then
        return "failed", written, tostring(err)
    end

    return exhausted and "done" or "running", written, nil
end

---Clones a serialized node table while dropping its `childs` field.
---Useful when reconstructing node trees without recursively duplicating children.
---@param data table<string, any>? Source node data. `nil` yields an empty table.
---@param clearLocks boolean? When `true`, forces `locked` and `lockedByParent` to `false`.
---@return table<string, any> copied Shallow copy without the `childs` field.
function pipelineCommon.copyNodeDataWithoutChildren(data, clearLocks)
    local copied = {}

    for key, value in pairs(data or {}) do
        if key ~= "childs" then
            copied[key] = value
        end
    end

    if clearLocks then
        copied.locked = false
        copied.lockedByParent = false
    end

    return copied
end

---Resolves toast kind text to an `ImGui.ToastType` numeric value.
---Falls back to `0` if toast APIs are unavailable.
---@param kind pipelineToastKind Semantic toast kind.
---@return integer toastType Resolved enum value for `ImGui.Toast.new`.
function pipelineCommon.resolveToastType(kind)
    local toastType = ImGui and ImGui.ToastType
    if not toastType then
        return 0
    end

    if kind == "info" and toastType.Info then
        return toastType.Info
    end

    if kind == "warning" and toastType.Warning then
        return toastType.Warning
    end

    if kind == "error" and toastType.Error then
        return toastType.Error
    end

    return toastType.Success or toastType.Info or 0
end

---Enqueues a toast entry for deferred display.
---@param queue pipelineToastEntry[] Mutable FIFO queue table.
---@param kind pipelineToastKind Semantic toast kind (`info`, `warning`, `error`, `success`).
---@param duration number? Display duration in milliseconds. Defaults to `3000`.
---@param text string Toast message text.
function pipelineCommon.queueToast(queue, kind, duration, text)
    table.insert(queue, {
        type = pipelineCommon.resolveToastType(kind),
        duration = duration or 3000,
        text = text
    })
end

---Displays at most one queued toast and removes it from the queue.
---@param queue pipelineToastEntry[] Mutable FIFO queue table.
---@return boolean shown `true` when one toast was popped and processed.
function pipelineCommon.drawQueuedToasts(queue)
    if #queue > 0 then
        local toast = table.remove(queue, 1)
        if ImGui and ImGui.ShowToast and ImGui.Toast and ImGui.Toast.new then
            ImGui.ShowToast(ImGui.Toast.new(toast.type, toast.duration, toast.text))
        end
        return true
    end

    return false
end

---@param options pipelineProgressOptions
---Renders a shared cancelable progress block for long-running pipeline tasks.
---Draws phase text, progress bar, optional counters/help text, and optional cancel button.
function pipelineCommon.drawCancelableProgress(options)
    local style = options.style
    local phaseText = options.phaseText or ""
    local progress = math.max(0, math.min(1, options.progress or 0))
    local counterText = options.counterText or ""
    local helpText = options.helpText or ""
    local cancelText = options.cancelText or "Cancel"
    local barWidth = options.barWidth or (260 * style.viewSize)
    local barHeight = options.barHeight or (13 * style.viewSize)
    local barOverlay = options.barOverlay or ""
    local showSeparator = options.showSeparator ~= false

    ImGui.BeginGroup()
    style.mutedText(phaseText)
    ImGui.ProgressBar(progress, barWidth, barHeight, barOverlay)
    if counterText ~= "" then
        ImGui.SameLine()
        style.mutedText(counterText)
    end
    if helpText ~= "" then
        style.mutedText(helpText)
    end
    ImGui.EndGroup()

    if options.onCancel then
        local cancelTextWidth, _ = ImGui.CalcTextSize(cancelText)
        local cancelButtonWidth = cancelTextWidth + 2 * ImGui.GetStyle().FramePadding.x
        local rightX = ImGui.GetWindowWidth() - ImGui.GetStyle().WindowPadding.x - cancelButtonWidth

        ImGui.SameLine()
        if rightX > ImGui.GetCursorPosX() then
            ImGui.SetCursorPosX(rightX)
        end

        if ImGui.Button(cancelText) then
            options.onCancel()
        end
    end

    if showSeparator then
        style.spacedSeparator()
    end
end

---Normalizes an export variant name, collapsing empty/`"default"` spellings onto `"default"`.
---@param variantName string?
---@return string normalized
---@return boolean isDefault True when the name resolves to the default variant.
function pipelineCommon.normalizeVariantName(variantName)
    local normalized = utils.trimString(variantName)

    if normalized == "" or normalized:lower() == "default" then
        return "default", true
    end

    return normalized, false
end

return pipelineCommon
