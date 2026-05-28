local utils = require("modules/utils/utils")
local style = require("modules/ui/style")
local settings = require("modules/utils/settings")
local history = require("modules/utils/history")
local previewSyncManager = require("modules/utils/previewSyncManager")

---@class previewTimelineDragState
---@field active boolean
---@field id number
---@field mode string
---@field startMouseX number
---@field baseStart number
---@field baseInterval number
---@field baseGroupDelay number
---@field entry table?
---@field historyAdded boolean
---@field changed boolean

---@class previewTimeline
---@field open boolean
---@field spawnedUI spawnedUI?
---@field sectionDomainId string
---@field zoom number
---@field snapEnabled boolean
---@field snapSec number
---@field trackHeight number
---@field trackGap number
---@field headerHeight number
---@field labelWidth number
---@field dockWasBottom boolean
---@field drag previewTimelineDragState
local previewTimeline = {
    open = false,
    spawnedUI = nil,
    sectionDomainId = "",
    zoom = 90, -- pixels per second
    snapEnabled = true,
    snapSec = 0.1,
    trackHeight = 32,
    trackGap = 4,
    headerHeight = 28,
    labelWidth = 220,
    dockWasBottom = false,
    drag = {
        active = false,
        id = -1,
        mode = "move",
        startMouseX = 0,
        baseStart = 0,
        baseInterval = 0,
        baseGroupDelay = 0,
        entry = nil,
        historyAdded = false,
        changed = false
    }
}

local timelineDockButtonHovered = false
local timelineCloseButtonHovered = false
local timelineCategoryOrder = {
    "Effects",
    "Particles"
}
local timelineCategoryColors = {
    Effects = 0xFF2082F5,
    Particles = 0xFFB070C8
}
local timelineDisabledColor = 0xFF5A5A5A

---@param value number
---@param minValue number
---@param maxValue number
---@return number
local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(value, maxValue))
end

---@param value number?
---@return number
local function clampNonNegative(value)
    return math.max(0, tonumber(value) or 0)
end

---@param color number
---@param alpha number
---@return number
local function withAlpha(color, alpha)
    local rgb = (tonumber(color) or 0) % 0x1000000
    local a = clamp(math.floor(tonumber(alpha) or 255), 0, 255)
    return (a * 0x1000000) + rgb
end

---@param text string
---@param maxWidth number
---@param minPrefix string
---@param textScale number?
---@return string
local function truncateTimelineTextRight(text, maxWidth, minPrefix, textScale)
    maxWidth = math.max(1, maxWidth or 1)
    minPrefix = minPrefix or ""
    textScale = textScale or 1

    local function measureWidth(value)
        return ImGui.CalcTextSize(value) * textScale
    end

    if measureWidth(text) <= maxWidth then
        return text
    end

    if measureWidth(minPrefix) > maxWidth then
        return minPrefix
    end

    local ellipsis = "..."
    if measureWidth(minPrefix .. ellipsis) > maxWidth then
        return minPrefix
    end

    local trimmed = text
    while #trimmed > #minPrefix and measureWidth(trimmed .. ellipsis) > maxWidth do
        trimmed = trimmed:sub(1, #trimmed - 1)
    end

    if trimmed == minPrefix then
        return minPrefix
    end

    return trimmed .. ellipsis
end

---@param drawList any
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param color number
local function drawTimelineRectOutline(drawList, x1, y1, x2, y2, color)
    ImGui.ImDrawListAddLine(drawList, x1, y1, x2, y1, color, 1)
    ImGui.ImDrawListAddLine(drawList, x2, y1, x2, y2, color, 1)
    ImGui.ImDrawListAddLine(drawList, x2, y2, x1, y2, color, 1)
    ImGui.ImDrawListAddLine(drawList, x1, y2, x1, y1, color, 1)
end

---@param sec number
---@return string
local function formatTimelineTime(sec)
    sec = math.max(0, tonumber(sec) or 0)
    if sec >= 10 then
        return string.format("%.1fs", sec)
    elseif sec >= 1 then
        return string.format("%.2fs", sec)
    end

    return string.format("%dms", math.floor(sec * 1000 + 0.5))
end

---@param domainId string
---@return number?
local function parseDomainGroupId(domainId)
    if type(domainId) ~= "string" then
        return nil
    end

    local value = domainId:match("^group:(%d+)$")
    if not value then
        return nil
    end

    return tonumber(value)
end

---@param groupId number?
---@return element?, string?
local function findGroupById(groupId)
    if not groupId then
        return nil, nil
    end

    local spawnedUI = previewTimeline.spawnedUI
    if not spawnedUI then
        return nil, nil
    end

    for _, entry in pairs(spawnedUI.containerPaths or {}) do
        if entry.ref and entry.ref.id == groupId then
            return entry.ref, entry.path
        end
    end

    return nil, nil
end

---@param domainId string
---@return string
local function resolveDomainLabel(domainId)
    if domainId == "global" then
        return "Global"
    end

    local groupId = parseDomainGroupId(domainId)
    local group, path = findGroupById(groupId)
    if group then
        if path and path ~= "" then
            return path
        end

        return group.name or domainId
    end

    return domainId
end

---@param category string
---@return number
local function getTimelineCategoryColor(category)
    return timelineCategoryColors[category] or timelineCategoryColors.Effects
end

---@param zoom number
---@return number
local function getTimelineTickStep(zoom)
    local desired = 110 / math.max(zoom, 0.0001)
    local steps = { 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 30, 60 }

    for _, step in ipairs(steps) do
        if step >= desired then
            return step
        end
    end

    return steps[#steps]
end

---@param value number
---@return number
local function snapTimelineTime(value)
    if not previewTimeline.snapEnabled then
        return value
    end

    local snap = math.max(0.01, tonumber(previewTimeline.snapSec) or 0.1)
    return math.floor((value + (snap * 0.5)) / snap) * snap
end

local function saveTimelineSettings()
    settings.previewTimelineZoom = previewTimeline.zoom
    settings.previewTimelineSnapEnabled = previewTimeline.snapEnabled
    settings.previewTimelineSnapSec = previewTimeline.snapSec
    settings.save()
end

local function ensureSettings()
    local changed = false

    if settings.previewTimelineDockBottom == nil then
        settings.previewTimelineDockBottom = false
        changed = true
    end

    if settings.previewTimelineDockHeight == nil then
        settings.previewTimelineDockHeight = 320
        changed = true
    end

    if settings.previewTimelineZoom == nil then
        settings.previewTimelineZoom = previewTimeline.zoom
        changed = true
    end

    if settings.previewTimelineSnapEnabled == nil then
        settings.previewTimelineSnapEnabled = previewTimeline.snapEnabled
        changed = true
    end

    if settings.previewTimelineSnapSec == nil then
        settings.previewTimelineSnapSec = previewTimeline.snapSec
        changed = true
    end

    if changed then
        settings.save()
    end

    previewTimeline.zoom = clamp(tonumber(settings.previewTimelineZoom) or previewTimeline.zoom, 20, 360)
    previewTimeline.snapEnabled = settings.previewTimelineSnapEnabled ~= false
    previewTimeline.snapSec = clamp(tonumber(settings.previewTimelineSnapSec) or previewTimeline.snapSec, 0.01, 30)
end

local function endTimelineDrag()
    local drag = previewTimeline.drag
    if drag.active and drag.changed and drag.entry and drag.entry.spawnable then
        previewSyncManager.syncSpawnableDomain(drag.entry.spawnable)
    end

    drag.active = false
    drag.id = -1
    drag.mode = "move"
    drag.startMouseX = 0
    drag.baseStart = 0
    drag.baseInterval = 0
    drag.baseGroupDelay = 0
    drag.entry = nil
    drag.historyAdded = false
    drag.changed = false
end

---@param entry table
---@param mode string
---@param mouseX number
local function beginTimelineDrag(entry, mode, mouseX)
    if not entry or not entry.spawnable then
        return
    end

    local timing = previewSyncManager.getSpawnableTiming(entry.spawnable)
    if not timing then
        return
    end

    previewTimeline.drag.active = true
    previewTimeline.drag.id = entry.id
    previewTimeline.drag.mode = mode
    previewTimeline.drag.startMouseX = mouseX
    previewTimeline.drag.baseStart = timing.effectiveDelay
    previewTimeline.drag.baseInterval = timing.interval
    previewTimeline.drag.baseGroupDelay = timing.groupDelaySum
    previewTimeline.drag.entry = entry
    previewTimeline.drag.historyAdded = false
    previewTimeline.drag.changed = false
end

local function updateTimelineDrag()
    local drag = previewTimeline.drag
    if not drag.active or not drag.entry then
        return
    end

    if not ImGui.IsMouseDown(ImGuiMouseButton.Left) then
        endTimelineDrag()
        return
    end

    local entry = drag.entry
    local spawnable = entry.spawnable
    local element = entry.element
    if not spawnable or not element or spawnable.object ~= element then
        endTimelineDrag()
        return
    end

    local mouseX = select(1, ImGui.GetMousePos())
    local deltaSec = (mouseX - drag.startMouseX) / math.max(previewTimeline.zoom, 0.0001)

    if drag.mode == "resizeRight" then
        local newInterval = snapTimelineTime(drag.baseInterval + deltaSec)
        newInterval = clamp(newInterval, 0.1, 120)

        if math.abs((tonumber(spawnable.previewLoopInterval) or 0) - newInterval) > 0.0001 then
            if not drag.historyAdded then
                history.addAction(history.getElementChange(element))
                drag.historyAdded = true
            end

            spawnable.previewLoopInterval = newInterval
            drag.changed = true
        end
    else
        local newEffectiveDelay = snapTimelineTime(drag.baseStart + deltaSec)
        newEffectiveDelay = math.max(drag.baseGroupDelay, newEffectiveDelay)
        local newPreviewStartDelay = clamp(newEffectiveDelay - drag.baseGroupDelay, 0, 120)

        if math.abs((tonumber(spawnable.previewStartDelay) or 0) - newPreviewStartDelay) > 0.0001 then
            if not drag.historyAdded then
                history.addAction(history.getElementChange(element))
                drag.historyAdded = true
            end

            spawnable.previewStartDelay = newPreviewStartDelay
            drag.changed = true
        end
    end
end

---@return table[]
local function collectPreviewTimelineEntries()
    local entries = {}
    local spawnedUI = previewTimeline.spawnedUI
    if not spawnedUI then
        return entries
    end

    spawnedUI.ensureCache()

    for _, pathEntry in pairs(spawnedUI.paths or {}) do
        local element = pathEntry.ref
        if utils.isA(element, "spawnableElement") and element.spawnable and previewSyncManager.isManagedSpawnable(element.spawnable) then
            local timing = previewSyncManager.getSpawnableTiming(element.spawnable)
            if timing then
                local category = element.spawnable.node == "worldEffectNode" and "Effects" or "Particles"
                table.insert(entries, {
                    id = element.id,
                    element = element,
                    spawnable = element.spawnable,
                    path = pathEntry.path,
                    name = element.name,
                    domainId = timing.domainId or "global",
                    effectiveDelay = clampNonNegative(timing.effectiveDelay),
                    interval = math.max(0.1, tonumber(timing.interval) or 0.1),
                    previewStartDelay = clampNonNegative(timing.previewStartDelay),
                    groupDelaySum = clampNonNegative(timing.groupDelaySum),
                    restartDelay = clampNonNegative(element.spawnable.previewLoopRestartDelay or 0),
                    enabled = element.spawnable.previewLoop == true,
                    active = previewSyncManager.isSpawnableActiveForPreview(element.spawnable),
                    category = category,
                    color = getTimelineCategoryColor(category),
                    order = 0,
                    lane = 0
                })
            end
        end
    end

    return entries
end

---@param entries table[]
---@return table[]
local function getTimelineSections(entries)
    local sectionsByDomain = {}

    for _, entry in ipairs(entries) do
        local domainId = entry.domainId or "global"
        local section = sectionsByDomain[domainId]
        if not section then
            section = {
                domainId = domainId,
                path = resolveDomainLabel(domainId),
                count = 0,
                enabledCount = 0,
                duration = 0
            }
            sectionsByDomain[domainId] = section
        end

        section.count = section.count + 1
        if entry.enabled then
            section.enabledCount = section.enabledCount + 1
        end
        section.duration = math.max(section.duration, entry.effectiveDelay + math.max(entry.interval, 0.1))
    end

    local sections = {}
    for _, section in pairs(sectionsByDomain) do
        table.insert(sections, section)
    end

    table.sort(sections, function(a, b)
        return tostring(a.path or ""):lower() < tostring(b.path or ""):lower()
    end)

    return sections
end

---@param sections table[]
---@return table?
local function getPreferredTimelineSection(sections)
    if #sections == 0 then
        return nil
    end

    if previewTimeline.sectionDomainId ~= "" then
        for _, section in ipairs(sections) do
            if section.domainId == previewTimeline.sectionDomainId then
                return section
            end
        end
    end

    local spawnedUI = previewTimeline.spawnedUI
    if spawnedUI and #spawnedUI.selectedPaths == 1 then
        local selected = spawnedUI.selectedPaths[1].ref
        if selected and utils.isA(selected, "spawnableElement") and selected.spawnable and previewSyncManager.isManagedSpawnable(selected.spawnable) then
            local domainId = previewSyncManager.getDomainIdForSpawnable(selected.spawnable)
            if domainId then
                for _, section in ipairs(sections) do
                    if section.domainId == domainId then
                        previewTimeline.sectionDomainId = domainId
                        return section
                    end
                end
            end
        end
    end

    previewTimeline.sectionDomainId = sections[1].domainId
    return sections[1]
end

---@param domainId string
---@param entries table[]
---@return table[]
local function getEntriesForDomain(domainId, entries)
    local results = {}

    for _, entry in ipairs(entries) do
        if entry.domainId == domainId then
            table.insert(results, entry)
        end
    end

    return results
end

---@param entries table[]
---@return table[]
---@return number
---@return number
local function buildTimelineLayout(entries)
    local categories = {}
    local ordered = {}
    local totalDuration = 0

    for _, entry in ipairs(entries) do
        local categoryName = entry.category
        if not categories[categoryName] then
            categories[categoryName] = {
                name = categoryName,
                color = getTimelineCategoryColor(categoryName),
                entries = {},
                count = 0,
                laneCount = 1,
                y = 0,
                height = 0
            }
            table.insert(ordered, categories[categoryName])
        end

        local category = categories[categoryName]
        category.count = category.count + 1
        table.insert(category.entries, entry)
        totalDuration = math.max(totalDuration, entry.effectiveDelay + math.max(entry.interval, 0.1))
    end

    table.sort(ordered, function(a, b)
        local orderA = utils.indexValue(timelineCategoryOrder, a.name)
        local orderB = utils.indexValue(timelineCategoryOrder, b.name)
        if orderA == -1 then orderA = 9999 end
        if orderB == -1 then orderB = 9999 end
        if orderA == orderB then
            return a.name < b.name
        end

        return orderA < orderB
    end)

    local yCursor = previewTimeline.headerHeight + 6
    for _, category in ipairs(ordered) do
        table.sort(category.entries, function(a, b)
            if a.effectiveDelay == b.effectiveDelay then
                return a.id < b.id
            end

            return a.effectiveDelay < b.effectiveDelay
        end)

        local laneEnds = {}
        for idx, entry in ipairs(category.entries) do
            entry.order = idx

            local lane = 1
            local entryEnd = entry.effectiveDelay + math.max(entry.interval, 0.1)
            while laneEnds[lane] and entry.effectiveDelay < laneEnds[lane] do
                lane = lane + 1
            end

            laneEnds[lane] = entryEnd
            entry.lane = lane - 1
        end

        category.laneCount = math.max(1, #laneEnds)
        category.y = yCursor
        category.height = (category.laneCount * (previewTimeline.trackHeight + previewTimeline.trackGap)) + 8
        yCursor = yCursor + category.height + 4
    end

    local totalHeight = math.max(yCursor + 6, previewTimeline.headerHeight + previewTimeline.trackHeight + 16)
    return ordered, totalDuration, totalHeight
end

---@param barColor number
---@param enabled boolean
---@param active boolean
---@return number
local function resolveBarColor(barColor, enabled, active)
    if not enabled then
        return timelineDisabledColor
    end

    if active then
        return barColor
    end

    return 0xAA606060
end

---@param section table
---@return number
local function getDomainElapsed(section)
    local domainStart = previewSyncManager.getDomainStartTime(section.domainId)
    local currentTime = previewSyncManager.getCurrentTime()
    if not domainStart then
        return 0
    end

    return math.max(0, currentTime - domainStart)
end

---@param a number
---@param b number
---@return number
local function gcdInt(a, b)
    a = math.abs(math.floor(a or 0))
    b = math.abs(math.floor(b or 0))

    if a == 0 then return math.max(1, b) end
    if b == 0 then return math.max(1, a) end

    while b ~= 0 do
        local t = b
        b = a % b
        a = t
    end

    return math.max(1, a)
end

---@param a number
---@param b number
---@return number
local function lcmInt(a, b)
    a = math.max(1, math.floor(a or 1))
    b = math.max(1, math.floor(b or 1))

    local g = gcdInt(a, b)
    return math.max(1, math.floor((a / g) * b + 0.5))
end

---@param entries table[]
---@return number
local function computeCycleDuration(entries)
    local enabledEntries = {}
    local maxDuration = 1

    for _, entry in ipairs(entries) do
        maxDuration = math.max(maxDuration, entry.effectiveDelay + math.max(entry.interval, 0.1))
        if entry.enabled then
            table.insert(enabledEntries, entry)
        end
    end

    if #enabledEntries == 0 then
        return maxDuration
    end

    local quantum = math.max(0.01, tonumber(previewTimeline.snapSec) or 0.1)
    local maxCycleDuration = 300
    local lcmTicks = nil

    for _, entry in ipairs(enabledEntries) do
        local interval = math.max(0.1, tonumber(entry.interval) or 0.1)
        local ticks = math.max(1, math.floor((interval / quantum) + 0.5))
        if lcmTicks == nil then
            lcmTicks = ticks
        else
            lcmTicks = lcmInt(lcmTicks, ticks)
        end

        if (lcmTicks * quantum) > maxCycleDuration then
            return maxDuration
        end
    end

    local cycle = math.max(quantum, (lcmTicks or 1) * quantum)
    return math.max(maxDuration, cycle)
end

---@param entries table[]
---@return number
local function computePlaybackOffset(entries)
    local offset = 0

    for _, entry in ipairs(entries) do
        if entry.enabled then
            offset = math.max(offset, clampNonNegative(entry.restartDelay))
        end
    end

    return offset
end

---@param section table
---@param entries table[]
local function drawTimelineCanvas(section, entries)
    local categories, timelineDuration, timelineHeight = buildTimelineLayout(entries)
    timelineDuration = math.max(timelineDuration, 1)
    local cycleDuration = computeCycleDuration(entries)
    local repeatedDuration = timelineDuration
    for _, entry in ipairs(entries) do
        local interval = math.max(entry.interval, 0.1)
        local repeatCount = entry.enabled and 2 or 0
        repeatedDuration = math.max(repeatedDuration, entry.effectiveDelay + interval * (1 + repeatCount))
    end
    local canvasDuration = math.max(repeatedDuration, cycleDuration) + math.max(1, previewTimeline.snapSec * 4)

    local elapsed = getDomainElapsed(section)
    local playbackOffset = computePlaybackOffset(entries)
    style.mutedText(string.format("Domain Clock: %s", formatTimelineTime(elapsed)))
    ImGui.SameLine()
    style.mutedText(string.format("Cycle: %s", formatTimelineTime(cycleDuration)))
    ImGui.SameLine()
    style.mutedText(string.format("Duration: %s", formatTimelineTime(timelineDuration)))
    ImGui.SameLine()
    local syncLabel, syncHiddenText = style.resolveActionLabel(IconGlyphs.Restart, "Sync Now", "previewTimelineSyncNow", nil, true)
    if ImGui.Button(syncLabel) then
        previewSyncManager.syncDomain(section.domainId)
    end
    if syncHiddenText then
        style.tooltipActionLabel(syncHiddenText, syncHiddenText .. "\nRestart synchronized preview timing for this domain.")
    else
        style.tooltip("Restart synchronized preview timing for this domain.")
    end

    ImGui.SameLine()
    local snapEnabled, snapChanged = ImGui.Checkbox("Snap##previewTimelineSnap", previewTimeline.snapEnabled)
    if snapChanged then
        previewTimeline.snapEnabled = snapEnabled
        saveTimelineSettings()
    end

    ImGui.SameLine()
    ImGui.BeginDisabled(not previewTimeline.snapEnabled)
    ImGui.SetNextItemWidth(85 * style.viewSize)
    local newSnapSec, snapValueChanged = ImGui.InputFloat("##previewTimelineSnapSec", previewTimeline.snapSec, 0, 0, "%.2fs")
    if snapValueChanged then
        previewTimeline.snapSec = clamp(tonumber(newSnapSec) or previewTimeline.snapSec, 0.01, 30)
        saveTimelineSettings()
    end
    ImGui.EndDisabled()

    ImGui.SameLine()
    ImGui.SetNextItemWidth(150 * style.viewSize)
    local newZoom, zoomChanged = ImGui.DragFloat("Zoom##previewTimelineZoom", previewTimeline.zoom, 0.5, 20, 360, "%.1f px/s")
    if zoomChanged then
        previewTimeline.zoom = clamp(tonumber(newZoom) or previewTimeline.zoom, 20, 360)
        saveTimelineSettings()
    end

    ImGui.Separator()

    local _, ySpace = ImGui.GetContentRegionAvail()
    if ySpace < 160 * style.viewSize then
        ySpace = 160 * style.viewSize
    end

    if ImGui.BeginChild("##previewTimelineCanvas", 0, ySpace, false, ImGuiWindowFlags.HorizontalScrollbar) then
        local drawList = ImGui.GetWindowDrawList()
        local startX = ImGui.GetCursorPosX()
        local startY = ImGui.GetCursorPosY()
        local labelWidth = previewTimeline.labelWidth * style.viewSize
        local canvasWidth = labelWidth + (canvasDuration * previewTimeline.zoom) + (80 * style.viewSize)
        local canvasHeight = timelineHeight + 8
        local timelineX = startX + labelWidth

        ImGui.SetCursorPos(startX + canvasWidth, startY + canvasHeight)
        ImGui.Dummy(1, 1)
        ImGui.SetCursorPos(startX, startY)

        local windowX, windowY = ImGui.GetWindowPos()
        local scrollX = (ImGui.GetScrollX and ImGui.GetScrollX()) or 0
        local scrollY = (ImGui.GetScrollY and ImGui.GetScrollY()) or 0

        local function toTimelineScreen(localX, localY)
            return windowX + localX - scrollX, windowY + localY - scrollY
        end

        local function toLabelScreen(localX, localY)
            return windowX + localX, windowY + localY - scrollY
        end

        local bgX1, bgY1 = toTimelineScreen(startX, startY)
        local bgX2, bgY2 = toTimelineScreen(startX + canvasWidth, startY + canvasHeight)
        ImGui.ImDrawListAddRectFilled(drawList, bgX1, bgY1, bgX2, bgY2, 0x1A1E1E1E, 0)

        local labelHX1, labelHY1 = toLabelScreen(startX, startY)
        local labelHX2, labelHY2 = toLabelScreen(timelineX, startY + previewTimeline.headerHeight)
        ImGui.ImDrawListAddRectFilled(drawList, labelHX1, labelHY1, labelHX2, labelHY2, 0xFF1F1F1F, 0)

        local gridHX1, gridHY1 = toTimelineScreen(timelineX, startY)
        local gridHX2, gridHY2 = toTimelineScreen(startX + canvasWidth, startY + previewTimeline.headerHeight)
        ImGui.ImDrawListAddRectFilled(drawList, gridHX1, gridHY1, gridHX2, gridHY2, 0xFF252525, 0)

        local dividerX1, dividerY1 = toLabelScreen(timelineX, startY)
        local dividerX2, dividerY2 = toLabelScreen(timelineX, startY + canvasHeight)
        ImGui.ImDrawListAddLine(drawList, dividerX1, dividerY1, dividerX2, dividerY2, 0x44383838, 1)

        local tickStep = getTimelineTickStep(previewTimeline.zoom)
        local minorStep = math.max(0.01, tickStep / 5)

        local t = 0
        while t <= canvasDuration + 0.0001 do
            local lineX1, lineY1 = toTimelineScreen(timelineX + (t * previewTimeline.zoom), startY + previewTimeline.headerHeight)
            local lineX2, lineY2 = toTimelineScreen(timelineX + (t * previewTimeline.zoom), startY + canvasHeight)
            ImGui.ImDrawListAddLine(drawList, lineX1, lineY1, lineX2, lineY2, 0x1D4B4B4B, 1)
            t = t + minorStep
        end

        t = 0
        while t <= canvasDuration + 0.0001 do
            local lineX1, lineY1 = toTimelineScreen(timelineX + (t * previewTimeline.zoom), startY)
            local lineX2, lineY2 = toTimelineScreen(timelineX + (t * previewTimeline.zoom), startY + canvasHeight)
            ImGui.ImDrawListAddLine(drawList, lineX1, lineY1, lineX2, lineY2, 0x3D5F5F5F, 1)

            local labelX, labelY = toTimelineScreen(timelineX + (t * previewTimeline.zoom) + 3, startY + 4)
            ImGui.ImDrawListAddText(drawList, ImGui.GetFontSize() * 0.8, labelX, labelY, 0xFFA5A19B, formatTimelineTime(t))
            t = t + tickStep
        end

        local playhead = clamp(elapsed - playbackOffset, 0, canvasDuration)
        local playheadX1, playheadY1 = toTimelineScreen(timelineX + (playhead * previewTimeline.zoom), startY)
        local playheadX2, playheadY2 = toTimelineScreen(timelineX + (playhead * previewTimeline.zoom), startY + canvasHeight)
        ImGui.ImDrawListAddLine(drawList, playheadX1, playheadY1, playheadX2, playheadY2, 0xAA00D6FF, 2)

        for _, category in ipairs(categories) do
            local rowTop = startY + category.y
            local rowBottom = rowTop + category.height

            local lx1, ly1 = toLabelScreen(startX, rowTop)
            local lx2, ly2 = toLabelScreen(timelineX, rowBottom)
            ImGui.ImDrawListAddRectFilled(drawList, lx1, ly1, lx2, ly2, 0xFF202020, 0)

            local tx1, ty1 = toTimelineScreen(timelineX, rowTop)
            local tx2, ty2 = toTimelineScreen(startX + canvasWidth, rowBottom)
            ImGui.ImDrawListAddRectFilled(drawList, tx1, ty1, tx2, ty2, 0x132A2A2A, 0)

            local sepX1, sepY1 = toTimelineScreen(startX, rowBottom)
            local sepX2, sepY2 = toTimelineScreen(startX + canvasWidth, rowBottom)
            ImGui.ImDrawListAddLine(drawList, sepX1, sepY1, sepX2, sepY2, 0x2C3A3A3A, 1)

            local markerX1, markerY1 = toLabelScreen(startX + (8 * style.viewSize), rowTop + (10 * style.viewSize))
            local markerX2, markerY2 = toLabelScreen(startX + (12 * style.viewSize), rowTop + (24 * style.viewSize))
            ImGui.ImDrawListAddRectFilled(drawList, markerX1, markerY1, markerX2, markerY2, category.color, 2)

            local labelX, labelY = toLabelScreen(startX + (18 * style.viewSize), rowTop + (8 * style.viewSize))
            local categoryLabel = string.format("%s (%d)", category.name, category.count)
            ImGui.ImDrawListAddText(drawList, ImGui.GetFontSize() * 0.9, labelX, labelY, 0xFFD0D0D0, categoryLabel)

            for _, entry in ipairs(category.entries) do
                local barX = timelineX + (entry.effectiveDelay * previewTimeline.zoom)
                local barY = rowTop + 4 + (entry.lane * (previewTimeline.trackHeight + previewTimeline.trackGap))
                local timeWidth = math.max(entry.interval, 0.1) * previewTimeline.zoom
                local barW = math.max(22 * style.viewSize, timeWidth)
                local barH = previewTimeline.trackHeight
                local barSX1, barSY1 = toTimelineScreen(barX, barY)
                local barSX2, barSY2 = toTimelineScreen(barX + barW, barY + barH)

                local barColor = resolveBarColor(entry.color, entry.enabled, entry.active)
                local borderColor = entry.element.selected and 0xFF00D6FF or 0x99000000

                if entry.enabled then
                    for repeatIndex = 1, 2 do
                        local repeatX = barX + (timeWidth * repeatIndex)
                        local repeatSX1, repeatSY1 = toTimelineScreen(repeatX, barY)
                        local repeatSX2, repeatSY2 = toTimelineScreen(repeatX + barW, barY + barH)
                        local repeatAlpha = repeatIndex == 1 and 115 or 75
                        local repeatBorderAlpha = repeatIndex == 1 and 95 or 65

                        ImGui.ImDrawListAddRectFilled(drawList, repeatSX1, repeatSY1, repeatSX2, repeatSY2, withAlpha(barColor, repeatAlpha), 4)
                        drawTimelineRectOutline(drawList, repeatSX1, repeatSY1, repeatSX2, repeatSY2, withAlpha(borderColor, repeatBorderAlpha))
                    end
                end

                ImGui.ImDrawListAddRectFilled(drawList, barSX1, barSY1, barSX2, barSY2, barColor, 4)
                drawTimelineRectOutline(drawList, barSX1, barSY1, barSX2, barSY2, borderColor)

                local indexLabel = string.format("#%d", entry.order)
                local prefix = entry.enabled and indexLabel or (indexLabel .. " (Off)")
                local fullLabel = string.format("%s %s", prefix, entry.name)
                local titleX, titleY = toTimelineScreen(barX + 6, barY + 6)
                local textMaxWidth = barW - (10 * style.viewSize)
                local fittedTitle = truncateTimelineTextRight(fullLabel, textMaxWidth, indexLabel, 0.78)
                ImGui.ImDrawListAddText(drawList, ImGui.GetFontSize() * 0.78, titleX, titleY, 0xFFF5F5F5, fittedTitle)

                ImGui.SetCursorPos(barX, barY)
                ImGui.InvisibleButton("##previewTimelineEntry" .. tostring(entry.id), barW, barH)
                local itemHovered = ImGui.IsItemHovered()
                local hoverEdgeZone = math.min(10 * style.viewSize, barW * 0.35)
                local hoverLocalX = nil
                if itemHovered then
                    hoverLocalX = select(1, ImGui.GetMousePos()) - barSX1
                end

                if ImGui.IsItemClicked(ImGuiMouseButton.Left) then
                    local spawnedUI = previewTimeline.spawnedUI
                    if spawnedUI and spawnedUI.unselectAll then
                        spawnedUI.unselectAll()
                    end

                    if entry.element and entry.element.setSelected then
                        entry.element:setSelected(true)
                    end

                    if entry.element and entry.element.expandAllParents then
                        entry.element:expandAllParents()
                    end

                    if spawnedUI then
                        spawnedUI.scrollToSelected = true
                    end
                end

                local rightHandleHighlighted = itemHovered and hoverLocalX ~= nil and (barW - hoverLocalX) <= hoverEdgeZone
                if previewTimeline.drag.active and previewTimeline.drag.id == entry.id and previewTimeline.drag.mode == "resizeRight" then
                    rightHandleHighlighted = true
                end

                local rightHandleColor = rightHandleHighlighted and 0xFFFFFFFF or 0x66FFFFFF
                ImGui.ImDrawListAddLine(drawList, barSX2 - 3, barSY1 + 4, barSX2 - 3, barSY2 - 4, rightHandleColor, 4)

                if ImGui.IsItemActivated() then
                    local mouseX = select(1, ImGui.GetMousePos())
                    local localX = mouseX - barSX1
                    local mode = "move"
                    if (barW - localX) <= hoverEdgeZone then
                        mode = "resizeRight"
                    end

                    beginTimelineDrag(entry, mode, mouseX)
                end

                if previewTimeline.drag.active and previewTimeline.drag.id == entry.id then
                    if previewTimeline.drag.mode == "resizeRight" then
                        ImGui.SetMouseCursor(ImGuiMouseCursor.ResizeEW)
                    else
                        ImGui.SetMouseCursor(ImGuiMouseCursor.Hand)
                    end
                elseif itemHovered then
                    if rightHandleHighlighted then
                        ImGui.SetMouseCursor(ImGuiMouseCursor.ResizeEW)
                    else
                        ImGui.SetMouseCursor(ImGuiMouseCursor.Hand)
                    end

                    style.tooltip(string.format(
                        "%s\nPath: %s\nLoop: %s\nEffective Delay: %s\nStart Delay: %s\nGroup Delay: %s\nInterval: %s\n\nDrag bar to move start delay.\nDrag right edge to resize loop interval.",
                        entry.name,
                        entry.path,
                        entry.enabled and "On" or "Off",
                        formatTimelineTime(entry.effectiveDelay),
                        formatTimelineTime(entry.previewStartDelay),
                        formatTimelineTime(entry.groupDelaySum),
                        formatTimelineTime(entry.interval)
                    ))
                end
            end
        end

        updateTimelineDrag()
    end

    ImGui.EndChild()
end

function previewTimeline.bindSpawnedUI(spawnedUI)
    previewTimeline.spawnedUI = spawnedUI
end

---@param group element?
function previewTimeline.openForGroup(group)
    previewTimeline.open = true
    local domainId = previewSyncManager.getDomainIdForGroup(group)
    if domainId then
        previewTimeline.sectionDomainId = domainId
    end
end

---@param spawnable table?
function previewTimeline.openForSpawnable(spawnable)
    previewTimeline.open = true
    local domainId = previewSyncManager.getDomainIdForSpawnable(spawnable)
    if domainId then
        previewTimeline.sectionDomainId = domainId
    end
end

function previewTimeline.drawWindow()
    if not previewTimeline.open then
        endTimelineDrag()
        return
    end

    ensureSettings()

    local screenWidth, screenHeight = GetDisplayResolution()
    local timelineFlags = ImGuiWindowFlags.NoCollapse
    local dockStyleApplied = false

    if settings.previewTimelineDockBottom then
        local minHeight = 160 * style.viewSize
        local maxHeight = math.max(minHeight, screenHeight * 0.85)
        local targetHeight = settings.previewTimelineDockHeight or math.floor(screenHeight * 0.33)
        targetHeight = clamp(targetHeight, minHeight, maxHeight)

        ImGui.SetNextWindowPos(0, screenHeight, ImGuiCond.Always, 0, 1)
        ImGui.SetNextWindowSizeConstraints(screenWidth, minHeight, screenWidth, maxHeight)

        if not previewTimeline.dockWasBottom then
            ImGui.SetNextWindowSize(screenWidth, targetHeight, ImGuiCond.Always)
        end

        timelineFlags = timelineFlags + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoTitleBar

        style.pushStyleColor(true, ImGuiCol.WindowBg, 0, 0, 0, 1)
        style.pushStyleVar(true, ImGuiStyleVar.WindowRounding, 0)
        dockStyleApplied = true
    end

    previewTimeline.open = ImGui.Begin("Preview Timeline", true, timelineFlags)
    if not previewTimeline.open then
        endTimelineDrag()
        previewTimeline.dockWasBottom = settings.previewTimelineDockBottom
        style.popStyleVar(dockStyleApplied)
        style.popStyleColor(dockStyleApplied)
        return
    end

    local originalCursorX = ImGui.GetCursorPosX()
    local originalCursorY = ImGui.GetCursorPosY()
    local dockInIcon = (IconGlyphs.DockBottom and IconGlyphs.DockBottom ~= "") and IconGlyphs.DockBottom or "v"
    local dockOutIcon = (IconGlyphs.DockWindow and IconGlyphs.DockWindow ~= "") and IconGlyphs.DockWindow or "^"
    local dockIcon = settings.previewTimelineDockBottom and dockOutIcon or dockInIcon
    local showDockedClose = settings.previewTimelineDockBottom == true
    local closeIcon = (IconGlyphs.Close and IconGlyphs.Close ~= "") and IconGlyphs.Close or "x"
    local dockButtonWidth, _ = ImGui.CalcTextSize(dockIcon)
    local closeButtonWidth, _ = ImGui.CalcTextSize(closeIcon)
    local controlsSpacing = ImGui.GetStyle().ItemSpacing.x
    local totalControlWidth = dockButtonWidth + (showDockedClose and (controlsSpacing + closeButtonWidth) or 0)
    local availableWidth = ImGui.GetContentRegionAvail()
    local dockButtonX = originalCursorX + availableWidth - totalControlWidth
    local dockButtonY = math.max(0, originalCursorY - 4)
    local closeRequested = false

    ImGui.SetCursorPos(dockButtonX, dockButtonY)
    style.pushStyleColor(timelineDockButtonHovered, ImGuiCol.Text, style.mutedColor)
    ImGui.SetItemAllowOverlap()
    ImGui.Text(dockIcon)
    style.popStyleColor(timelineDockButtonHovered)
    timelineDockButtonHovered = ImGui.IsItemHovered()
    if ImGui.IsItemClicked(ImGuiMouseButton.Left) then
        settings.previewTimelineDockBottom = not settings.previewTimelineDockBottom
        settings.save()
    end
    style.tooltip(settings.previewTimelineDockBottom and "Dock panel as floating window" or "Dock panel to the bottom")

    if showDockedClose then
        local closeButtonX = dockButtonX + dockButtonWidth + controlsSpacing
        ImGui.SetCursorPos(closeButtonX, dockButtonY)
        style.pushStyleColor(timelineCloseButtonHovered, ImGuiCol.Text, style.mutedColor)
        ImGui.SetItemAllowOverlap()
        ImGui.Text(closeIcon)
        style.popStyleColor(timelineCloseButtonHovered)
        timelineCloseButtonHovered = ImGui.IsItemHovered()
        if ImGui.IsItemClicked(ImGuiMouseButton.Left) then
            closeRequested = true
        end
        style.tooltip("Close Preview Timeline")
    end

    ImGui.SetCursorPosX(originalCursorX)
    ImGui.SetCursorPosY(originalCursorY)

    if closeRequested then
        previewTimeline.open = false
        endTimelineDrag()
        previewTimeline.dockWasBottom = settings.previewTimelineDockBottom
        ImGui.End()
        style.popStyleVar(dockStyleApplied)
        style.popStyleColor(dockStyleApplied)
        return
    end

    local entries = collectPreviewTimelineEntries()
    updateTimelineDrag()
    local sections = getTimelineSections(entries)

    if #sections == 0 then
        style.mutedText("No effect or particle entries found for preview synchronization.")
        style.mutedText("Spawn Effect / Particle entries to use the Preview Timeline.")
        previewTimeline.dockWasBottom = settings.previewTimelineDockBottom
        ImGui.End()
        style.popStyleVar(dockStyleApplied)
        style.popStyleColor(dockStyleApplied)
        return
    end

    local activeSection = getPreferredTimelineSection(sections)
    local sectionNames = {}
    local sectionIndex = 0

    for idx, section in ipairs(sections) do
        sectionNames[idx] = string.format("%s (%d/%d)", section.path, section.enabledCount, section.count)
        if activeSection and section.domainId == activeSection.domainId then
            sectionIndex = idx - 1
        end
    end

    ImGui.SetNextItemWidth(500 * style.viewSize)
    local newSectionIndex, sectionChanged = ImGui.Combo("Preview Sync Domain", sectionIndex, sectionNames, #sectionNames)
    if sectionChanged then
        activeSection = sections[newSectionIndex + 1]
        previewTimeline.sectionDomainId = activeSection.domainId
    end

    if not activeSection then
        previewTimeline.dockWasBottom = settings.previewTimelineDockBottom
        ImGui.End()
        style.popStyleVar(dockStyleApplied)
        style.popStyleColor(dockStyleApplied)
        return
    end

    local sectionEntries = getEntriesForDomain(activeSection.domainId, entries)
    if #sectionEntries == 0 then
        style.mutedText("Selected domain currently has no preview-capable entries.")
        previewTimeline.dockWasBottom = settings.previewTimelineDockBottom
        ImGui.End()
        style.popStyleVar(dockStyleApplied)
        style.popStyleColor(dockStyleApplied)
        return
    end

    drawTimelineCanvas(activeSection, sectionEntries)

    if settings.previewTimelineDockBottom then
        local _, currentHeight = ImGui.GetWindowSize()
        local minHeight = 160 * style.viewSize
        local maxHeight = math.max(minHeight, screenHeight * 0.85)
        local clampedHeight = clamp(currentHeight, minHeight, maxHeight)
        if math.abs((settings.previewTimelineDockHeight or clampedHeight) - clampedHeight) > 0.5 then
            settings.previewTimelineDockHeight = clampedHeight
            settings.save()
        end
    end

    previewTimeline.dockWasBottom = settings.previewTimelineDockBottom
    ImGui.End()
    style.popStyleVar(dockStyleApplied)
    style.popStyleColor(dockStyleApplied)
end

return previewTimeline
