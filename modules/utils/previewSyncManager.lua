local utils = require("modules/utils/utils")

---Centralized preview synchronization for effect/particle loop previews.
---Schedules loop restarts off shared domain clocks instead of per-node timers.
---@class previewSyncManager
---@field private time number
---@field private entries table<string, table>
---@field private domains table<string, table>
local previewSyncManager = {
    time = 0,
    entries = {},
    domains = {}
}

---@param spawnable table?
---@return string?
local function getSpawnableKey(spawnable)
    local object = spawnable and spawnable.object or nil
    if object and object.id then
        return tostring(object.id)
    end

    return nil
end

---@param spawnable table?
---@return boolean
local function canManageSpawnable(spawnable)
    return spawnable ~= nil
        and type(spawnable.restartPreviewLoopPlayback) == "function"
        and type(spawnable.preparePreviewSyncPlayback) == "function"
        and type(spawnable.isSpawned) == "function"
        and spawnable.previewLoop ~= nil
        and spawnable.previewLoopInterval ~= nil
end

---@param spawnable table
---@return element[]
local function collectAncestorGroups(spawnable)
    local groups = {}
    local current = spawnable.object and spawnable.object.parent or nil

    while current do
        if utils.isA(current, "positionableGroup") then
            table.insert(groups, current)
        end
        current = current.parent
    end

    return groups
end

---@param groups element[]
---@return element?
local function resolveDomainGroupFromAncestors(groups)
    if #groups == 0 then
        return nil
    end

    for _, group in ipairs(groups) do
        if group.previewSyncDomain == true then
            return group
        end
    end

    -- Fallback: topmost parent group (root group in hierarchy).
    return groups[#groups]
end

---@param spawnable table
---@return string domainId
---@return number delay
---@return number interval
local function resolveTimingProfile(spawnable)
    local groups = collectAncestorGroups(spawnable)
    local domainGroup = resolveDomainGroupFromAncestors(groups)
    local domainId = domainGroup and ("group:" .. tostring(domainGroup.id)) or "global"

    local delay = tonumber(spawnable.previewStartDelay) or 0
    for _, group in ipairs(groups) do
        delay = delay + (tonumber(group.previewSyncDelay) or 0)
        if group == domainGroup then
            break
        end
    end

    local interval = tonumber(spawnable.previewLoopInterval) or 0
    delay = math.max(delay, 0)
    interval = math.max(interval, 0.01)

    return domainId, delay, interval
end

---@param domainId string
---@return table
local function getOrCreateDomain(domainId)
    local domain = previewSyncManager.domains[domainId]
    if not domain then
        domain = {
            startTime = previewSyncManager.time
        }
        previewSyncManager.domains[domainId] = domain
    end

    return domain
end

---@param spawnable table
---@return boolean
local function isSpawnableActive(spawnable)
    if not canManageSpawnable(spawnable) then
        return false
    end

    if spawnable.previewLoop ~= true then
        return false
    end

    if (tonumber(spawnable.previewLoopInterval) or 0) <= 0 then
        return false
    end

    if spawnable.isAssetPreview then
        return false
    end

    if not spawnable:isSpawned() then
        return false
    end

    local entity = spawnable.getEntity and spawnable:getEntity() or nil
    if not entity then
        return false
    end

    return true
end

---@param spawnable table
---@param group element
---@return boolean
local function isSpawnableUnderGroup(spawnable, group)
    if not spawnable or not group then
        return false
    end

    local current = spawnable.object and spawnable.object.parent or nil
    while current do
        if current == group then
            return true
        end
        current = current.parent
    end

    return false
end

---@param spawnable table
---@return string?
local function resolveDomainIdForSpawnable(spawnable)
    if not canManageSpawnable(spawnable) then
        return nil
    end

    local domainId = select(1, resolveTimingProfile(spawnable))
    return domainId
end

---@param group element?
---@return string?
local function resolveDomainIdForGroup(group)
    if not group or not utils.isA(group, "positionableGroup") then
        return nil
    end

    local current = group
    local topmost = group
    while current do
        if utils.isA(current, "positionableGroup") then
            topmost = current
            if current.previewSyncDomain == true then
                return "group:" .. tostring(current.id)
            end
        end
        current = current.parent
    end

    return "group:" .. tostring(topmost.id)
end

---@param entry table
---@param forcePrepare boolean?
local function resetEntrySchedule(entry, forcePrepare)
    entry.lastCycle = nil
    if forcePrepare == true and isSpawnableActive(entry.spawnable) then
        entry.spawnable:preparePreviewSyncPlayback()
    end
end

---@param domainId string
---@param forcePrepare boolean?
local function resetEntriesForDomain(domainId, forcePrepare)
    for _, entry in pairs(previewSyncManager.entries) do
        local entryDomainId = resolveDomainIdForSpawnable(entry.spawnable)
        if entryDomainId == domainId then
            resetEntrySchedule(entry, forcePrepare)
        end
    end
end

---@param domainId string?
---@param forcePrepare boolean?
local function resyncDomain(domainId, forcePrepare)
    if not domainId then
        return
    end

    local domain = getOrCreateDomain(domainId)
    domain.startTime = previewSyncManager.time
    resetEntriesForDomain(domainId, forcePrepare)
end

---Resets all runtime sync state.
function previewSyncManager.reset()
    previewSyncManager.time = 0
    previewSyncManager.entries = {}
    previewSyncManager.domains = {}
end

---@param spawnable table
function previewSyncManager.registerSpawnable(spawnable)
    local key = getSpawnableKey(spawnable)
    if not key or not canManageSpawnable(spawnable) then
        return
    end

    local entry = previewSyncManager.entries[key] or {
        key = key
    }
    entry.spawnable = spawnable
    previewSyncManager.entries[key] = entry

    resetEntrySchedule(entry, true)
end

---@param spawnable table
function previewSyncManager.unregisterSpawnable(spawnable)
    local key = getSpawnableKey(spawnable)
    if not key then
        return
    end

    previewSyncManager.entries[key] = nil
end

---@param spawnable table
function previewSyncManager.refreshSpawnable(spawnable)
    local key = getSpawnableKey(spawnable)
    if not key then
        return
    end

    if not canManageSpawnable(spawnable) then
        previewSyncManager.entries[key] = nil
        return
    end

    local entry = previewSyncManager.entries[key]
    if not entry then
        previewSyncManager.registerSpawnable(spawnable)
        return
    end

    entry.spawnable = spawnable
    resetEntrySchedule(entry, true)
end

---@param group element
function previewSyncManager.onGroupSettingsChanged(group)
    if not group then
        return
    end

    local domainId = resolveDomainIdForGroup(group)
    if domainId then
        resyncDomain(domainId, true)
        return
    end

    -- Fallback for unexpected non-group inputs.
    for _, entry in pairs(previewSyncManager.entries) do
        if isSpawnableUnderGroup(entry.spawnable, group) then
            resetEntrySchedule(entry, true)
        end
    end
end

---@param group element
function previewSyncManager.syncGroupDomain(group)
    local domainId = resolveDomainIdForGroup(group)
    resyncDomain(domainId, true)
end

---@param dt number
function previewSyncManager.update(dt)
    local delta = tonumber(dt) or 0
    if delta < 0 then
        delta = 0
    end

    previewSyncManager.time = previewSyncManager.time + delta

    for key, entry in pairs(previewSyncManager.entries) do
        local spawnable = entry.spawnable
        if not spawnable or spawnable.object == nil then
            previewSyncManager.entries[key] = nil
            goto continue
        end

        if not isSpawnableActive(spawnable) then
            entry.lastCycle = nil
            goto continue
        end

        local domainId, delay, interval = resolveTimingProfile(spawnable)
        local domain = getOrCreateDomain(domainId)
        local firstTrigger = domain.startTime + delay
        local currentTime = previewSyncManager.time

        if currentTime < firstTrigger then
            goto continue
        end

        local cycle = math.floor((currentTime - firstTrigger) / interval)
        if entry.lastCycle == nil or cycle > entry.lastCycle then
            entry.lastCycle = cycle
            spawnable:restartPreviewLoopPlayback()
        end

        ::continue::
    end
end

return previewSyncManager
