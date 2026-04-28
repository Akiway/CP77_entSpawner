local config = require("modules/utils/config")
local tasks = require("modules/utils/pipeline/tasks")
local utils = require("modules/utils/utils")
local settings = require("modules/utils/settings")

local sanitizeSpawnData = false
local data = {}

---@class cache
---@field staticData {ambientData : table, staticData : table, ambientQuad : table, ambientMetadata : table, staticMetadata : table, ambientMetadataAll : table, staticMetadataAll : table, signposts : table, bendedRigMatrices : table, spawnSets : table}
local cache = {
    staticData = {}
}

local version = 9

---@class cacheTryGetFoundStage
---@field found fun(foundCallback: fun())
---@class cacheTryGetChain
---@field notFound fun(notFoundCallback: fun(task: table)): cacheTryGetFoundStage

---Normalizes spawn/resource paths for cache comparisons.
---Converts `/` to `\\`, trims surrounding whitespace, and lowercases the result.
---@param path string|nil Raw path value.
---@return string normalizedPath Empty string when input is nil/blank.
local function normalizeSpawnPath(path)
    if not path then return "" end

    local normalized = path:gsub("/", "\\")
    normalized = normalized:gsub("^%s+", ""):gsub("%s+$", "")

    return string.lower(normalized)
end

local cacheKeySuffixes = {
    "_apps",
    "_rigs",
    "_infinite",
    "_tiling",
    "_bBox_max",
    "_bBox_min",
    "_collision",
    "_occluder",
    "_rig_matrices"
}

---Removes known cache-key suffixes to recover the base spawn path key.
---@param name string Cache key, optionally ending with known suffixes (for example `_apps`).
---@return string baseName
local function stripCacheKeySuffix(name)
    for _, suffix in ipairs(cacheKeySuffixes) do
        if #name > #suffix and name:sub(-#suffix) == suffix then
            return name:sub(1, #name - #suffix)
        end
    end

    return name
end

---Converts a wildcard expression (`*`, `?`) to a Lua pattern.
---@param glob string Wildcard expression.
---@return string pattern Anchored Lua pattern (`^...$`).
local function wildcardToPattern(glob)
    local pattern = { "^" }

    for i = 1, #glob do
        local ch = glob:sub(i, i)

        if ch == "*" then
            table.insert(pattern, ".*")
        elseif ch == "?" then
            table.insert(pattern, ".")
        elseif ch:match("[%^%$%(%)%%%.%[%]%+%-]") then
            table.insert(pattern, "%" .. ch)
        else
            table.insert(pattern, ch)
        end
    end

    table.insert(pattern, "$")
    return table.concat(pattern)
end

---Checks whether a normalized cache key matches one exclusion rule.
---@param normalizedName string Normalized cache key/path.
---@param exclusion string Exclusion rule from settings; supports `*` and `?`.
---@return boolean matches
local function matchesCacheExclusion(normalizedName, exclusion)
    local normalizedExclusion = normalizeSpawnPath(exclusion)
    if normalizedExclusion == "" then
        return false
    end

    if normalizedExclusion:find("*", 1, true) or normalizedExclusion:find("?", 1, true) then
        return normalizedName:match(wildcardToPattern(normalizedExclusion)) ~= nil
    end

    return normalizedName == normalizedExclusion
end

---Checks whether a cache key is excluded by `settings.cacheExclusions`.
---Suffixes used by derived cache entries are stripped before matching.
---@param name string Cache key to evaluate.
---@return boolean excluded
local function isExcludedCacheKey(name)
    local normalizedName = normalizeSpawnPath(stripCacheKeySuffix(name))
    if normalizedName == "" then
        return false
    end

    for _, exclusion in pairs(settings.cacheExclusions or {}) do
        if matchesCacheExclusion(normalizedName, exclusion) then
            return true
        end
    end

    return false
end

---Loads dynamic cache data from disk and refreshes static cache datasets.
---If cache schema version is outdated, resets `data/cache.json` to current version.
function cache.load()
    config.tryCreateConfig("data/cache.json", { version = version })
    data = config.loadFile("data/cache.json")

    if not data.version or data.version < version then
        data = { version = version }
        config.saveFile("data/cache.json", data)
        print("[entSpawner] Cache is outdated, resetting cache")
    end

    cache.loadStaticData()

    if not sanitizeSpawnData then return end
    cache.generateDevicePSClassList()
    cache.generateRecordsList()
    cache.generateAudioFiles()

    cache.removeDuplicates("data/spawnables/ai/aiSpot/paths_workspot.txt")
    cache.removeDuplicates("data/spawnables/entity/templates/paths_ent.txt")
    cache.removeDuplicates("data/spawnables/mesh/all/paths_mesh.txt")
    cache.removeDuplicates("data/spawnables/mesh/physics/paths_filtered_mesh.txt")
    cache.removeDuplicates("data/spawnables/visual/particles/paths_particle.txt")
    cache.removeDuplicates("data/spawnables/visual/decals/paths_mi.txt")
    cache.removeDuplicates("data/spawnables/visual/effects/paths_effect.txt")
end

---Loads static audio datasets and bended-rig defaults into `cache.staticData`.
---Also normalizes and indexes default bended rig matrix definitions by mesh path.
function cache.loadStaticData()
    cache.staticData.ambientData = config.loadFile("data/audio/ambientDataFull.json")
    cache.staticData.staticData = config.loadFile("data/audio/staticDataFull.json")
    cache.staticData.ambientQuad = config.loadFile("data/audio/ambientQuadFull.json")
    cache.staticData.ambientMetadata = config.loadFile("data/audio/ambientMetadataFull.json")
    cache.staticData.staticMetadata = config.loadFile("data/audio/staticMetadataFull.json")
    cache.staticData.ambientMetadataAll = config.loadFile("data/audio/ambientMetadataAll.json")
    cache.staticData.staticMetadataAll = config.loadFile("data/audio/staticMetadataAll.json")
    cache.staticData.signposts = config.loadFile("data/audio/signpostsData.json")
    cache.staticData.spawnSets = cache.staticData.spawnSets or {}
    cache.staticData.bendedRigMatrices = cache.staticData.bendedRigMatrices or {}

    local rigMatrixDefaults = config.loadFile("data/static/bended_rig_matrices.json")
    cache.staticData.bendedRigMatrices = {}

    for _, entry in ipairs(rigMatrixDefaults) do
        local path = normalizeSpawnPath(entry and entry.meshPath)
        if path ~= "" then
            local points = {}
            local matrixCount = tonumber(entry and entry.matrixCount)
            if matrixCount ~= nil then
                matrixCount = math.max(0, math.floor(matrixCount))
            end

            for pointIndex, point in ipairs(entry.positions or {}) do
                local order = tonumber(point and (point.index or point.Index))
                if order == nil then
                    order = pointIndex - 1
                end

                table.insert(points, {
                    order = order,
                    x = tonumber(point and (point.x or point.X)) or 0,
                    -- Static preset data uses opposite Y orientation for CET path editing space.
                    y = -(tonumber(point and (point.y or point.Y)) or 0),
                    z = tonumber(point and (point.z or point.Z)) or 0,
                    roll = tonumber(point and (point.roll or point.Roll)) or 0
                })
            end

            table.sort(points, function(a, b)
                return a.order < b.order
            end)

            local pathPoints = {}
            for _, point in ipairs(points) do
                table.insert(pathPoints, {
                    x = point.x,
                    y = point.y,
                    z = point.z,
                    roll = point.roll
                })
            end

            if matrixCount == nil or matrixCount <= 0 then
                matrixCount = #pathPoints
            end

            if #pathPoints > 0 or (matrixCount and matrixCount > 0) then
                cache.staticData.bendedRigMatrices[path] = {
                    pathPoints = pathPoints,
                    matrixCount = matrixCount
                }
            end
        end
    end
end

---Builds cache keys used to store mesh-derived resources.
---@param spawnData string Mesh depot path key.
---@return {apps: string, bBoxMax: string, bBoxMin: string, occluder: string, rigMatrices: string} keys
local function getMeshResourceKeys(spawnData)
    return {
        apps = spawnData .. "_apps",
        bBoxMax = spawnData .. "_bBox_max",
        bBoxMin = spawnData .. "_bBox_min",
        occluder = spawnData .. "_occluder",
        rigMatrices = spawnData .. "_rig_matrices"
    }
end

---Loads and memoizes a spawn-set file as a normalized lookup table.
---@param path string Path to a text file containing one spawn path per line.
---@return table<string, boolean> set
function cache.getSpawnSet(path)
    cache.staticData.spawnSets = cache.staticData.spawnSets or {}

    if cache.staticData.spawnSets[path] then
        return cache.staticData.spawnSets[path]
    end

    local set = {}
    local file = io.open(path, "r")
    if file then
        for line in file:lines() do
            if line and line ~= "" then
                set[normalizeSpawnPath(line)] = true
            end
        end
        file:close()
    end

    cache.staticData.spawnSets[path] = set
    return set
end

---Checks whether one spawn path exists in a cached spawn-set file.
---@param spawnData string Spawn/resource path to test.
---@param path string Spawn-set file path.
---@return boolean isInSet
function cache.isSpawnDataInSet(spawnData, path)
    local set = cache.getSpawnSet(path)
    return set[normalizeSpawnPath(spawnData)] == true
end

---Gets default bended path points for a mesh, if known.
---@param spawnData string Mesh spawn path.
---@return table[]|nil pathPoints Deep-copied list of path points.
function cache.getDefaultBendedPathPoints(spawnData)
    local key = normalizeSpawnPath(spawnData)
    if key == "" then
        return nil
    end

    local entry = cache.staticData.bendedRigMatrices and cache.staticData.bendedRigMatrices[key]
    if type(entry) ~= "table" then
        return nil
    end

    local points = entry.pathPoints
    if type(points) ~= "table" or #points == 0 then
        -- Backward compatibility with older in-memory shape.
        points = entry
    end

    if type(points) ~= "table" or #points == 0 then
        return nil
    end

    return utils.deepcopy(points)
end

---Gets default matrix count for a bended mesh, if known.
---@param spawnData string Mesh spawn path.
---@return integer|nil matrixCount
function cache.getDefaultBendedMatrixCount(spawnData)
    local key = normalizeSpawnPath(spawnData)
    if key == "" then
        return nil
    end

    local entry = cache.staticData.bendedRigMatrices and cache.staticData.bendedRigMatrices[key]
    if type(entry) ~= "table" then
        return nil
    end

    local matrixCount = tonumber(entry.matrixCount)
    if matrixCount ~= nil and matrixCount > 0 then
        return math.floor(matrixCount)
    end

    local points = entry.pathPoints
    if type(points) == "table" and #points > 0 then
        return #points
    end

    -- Backward compatibility with older in-memory shape.
    if #entry > 0 then
        return #entry
    end

    return nil
end

---Creates an async lookup chain for all mesh resource cache keys.
---@param spawnData string Mesh spawn path.
---@return cacheTryGetChain chain
function cache.tryGetMeshResource(spawnData)
    local keys = getMeshResourceKeys(spawnData)
    return cache.tryGet(keys.apps, keys.bBoxMax, keys.bBoxMin, keys.occluder)
end

---Stores mesh resource data in cache for one spawn path.
---@param spawnData string Mesh spawn path.
---@param value {apps: table|nil, bBoxMax: table|nil, bBoxMin: table|nil, occluder: boolean|nil, rigMatrices: any|nil} Mesh cache payload.
function cache.addMeshResource(spawnData, value)
    local keys = getMeshResourceKeys(spawnData)
    cache.addValue(keys.apps, value.apps or {})
    cache.addValue(keys.bBoxMax, value.bBoxMax or { x = 0.5, y = 0.5, z = 0.5, w = 0 })
    cache.addValue(keys.bBoxMin, value.bBoxMin or { x = -0.5, y = -0.5, z = -0.5, w = 0 })
    cache.addValue(keys.occluder, value.occluder == true)
    if value.rigMatrices ~= nil then
        cache.addValue(keys.rigMatrices, value.rigMatrices)
    end
end

---Retrieves a complete mesh resource payload from cache.
---@param spawnData string Mesh spawn path.
---@return {apps: table, bBoxMax: table, bBoxMin: table, occluder: boolean, rigMatrices: any}|nil resource
function cache.getMeshResource(spawnData)
    local keys = getMeshResourceKeys(spawnData)
    local apps = cache.getValue(keys.apps)
    local bBoxMax = cache.getValue(keys.bBoxMax)
    local bBoxMin = cache.getValue(keys.bBoxMin)
    local occluder = cache.getValue(keys.occluder)
    local rigMatrices = cache.getValue(keys.rigMatrices)

    if apps == nil or bBoxMax == nil or bBoxMin == nil or occluder == nil then
        return nil
    end

    return {
        apps = apps,
        bBoxMax = bBoxMax,
        bBoxMin = bBoxMin,
        occluder = occluder,
        rigMatrices = rigMatrices
    }
end

---Stores one cache value and persists cache data to disk.
---@param key string Cache key.
---@param value any Value to store.
function cache.addValue(key, value)
    data[key] = value
    config.saveFile("data/cache.json", data)
end

---Removes one cache value (if present) and persists cache data to disk.
---@param key string|nil Cache key to remove.
function cache.removeValue(key)
    if not key then
        return
    end

    if data[key] ~= nil then
        data[key] = nil
        config.saveFile("data/cache.json", data)
    end
end

---Gets a cached value by key.
---Table values are deep-copied to avoid accidental mutation of cached data.
---@param key string Cache key.
---@return any value
function cache.getValue(key)
    local value = data[key]
    if type(value) == "table" then
        return utils.deepcopy(value)
    end
    return value
end

---Resets persisted cache file to version-only structure.
function cache.reset()
    config.saveFile("data/cache.json", { version = version })
end

---Deduplicates a text-list file in-place.
---@param path string Path to text file containing list entries.
function cache.removeDuplicates(path)
    local data = config.loadText(path)

    local new = {}

    for _, entry in pairs(data) do
        new[entry] = entry
    end

    config.saveRawTable(path, new)
end

---Generates `records.txt` from selected TweakDB record classes if missing.
function cache.generateRecordsList()
    if config.fileExists("data/spawnables/entity/records/records.txt") then return end

    local records = {
        "gamedataAttachableObject_Record",
        "gamedataCarriableObject_Record",
        "gamedataCharacter_Record",
        "gamedataProp_Record",
        "gamedataSpawnableObject_Record",
        "gamedataSubCharacter_Record",
        "gamedataVehicle_Record",
    }

    local file = io.open("data/spawnables/entity/records/records.txt", "w")

    for _, record in pairs(records) do
        for _, entry in pairs(TweakDB:GetRecords(record)) do
            file:write(entry:GetID().value .. "\n")
        end
    end

    file:close()
end

---Generates static sound event list file if missing.
function cache.generateStaticAudioList()
    if config.fileExists("data/spawnables/visual/sounds/sounds.txt") then return end

    local data = config.loadFile("data.json")["Data"]["RootChunk"]["root"]["Data"]["events"]
    local sounds = {}

    for _, entry in pairs(data) do
        table.insert(sounds, entry["redId"]["$value"])
    end

    config.saveRawTable("data/spawnables/visual/sounds/sounds.txt", sounds)
end

---Generates a list of classes derived from `gameDeviceComponent`.
function cache.generateDevicePSClassList()
    config.saveFile("deviceComponentPSClasses.json", utils.getDerivedClasses("gameDeviceComponent"))
end

---Removes duplicate scalar entries while preserving first-seen order.
---@param data table Source array-like table.
---@return table deduplicated
local function removeDuplicatesTable(data)
    local new = {}
    local hash = {}

    for _, entry in pairs(data) do
        if not hash[entry] then
            table.insert(new, entry)
            hash[entry] = true
        end
    end

    return new
end

---Builds event-keyed metadata lists and aggregate metadata list.
---@param metaData table Source metadata table with `events` and `metadata`.
---@return table metadataByEvent
---@return table allMetadata
local function extractMetadata(metaData)
    local meta = {}
    local all = {}

    for _, data in pairs(metaData) do
        for _, event in pairs(data.events) do
            if not meta[event] then
                meta[event] = {}
            end
            table.insert(meta[event], data.metadata)
            table.insert(all, data.metadata)
        end
    end

    for key, data in pairs(meta) do
        meta[key] = removeDuplicatesTable(data)
    end

    all = removeDuplicatesTable(all)
    return meta, all
end

---Builds normalized full audio datasets from raw extracted audio files.
function cache.generateAudioFiles()
    local ambientData = config.loadFile("data/audio/ambientData.json")
    local ambientMetadata = config.loadFile("data/audio/ambientMetadata.json")
    local ambientQuad = config.loadFile("data/audio/ambientQuad.json")
    local signposts = config.loadFile("data/audio/signposts.json")
    local staticData = config.loadFile("data/audio/staticData.json")
    local staticMetadata = config.loadFile("data/audio/staticMetadata.json")

    config.saveFile("data/audio/signpostsData.json", {
        enter = removeDuplicatesTable(signposts.enter),
        exit = removeDuplicatesTable(signposts.exit)
    })

    config.saveFile("data/audio/ambientDataFull.json", {
        onEnter = removeDuplicatesTable(ambientData.onEnter),
        onActive = removeDuplicatesTable(ambientData.onActive),
        onExit = removeDuplicatesTable(ambientData.onExit),
        parameters = removeDuplicatesTable(ambientData.parameters),
        reverb = removeDuplicatesTable(ambientData.reverb)
    })

    config.saveFile("data/audio/staticDataFull.json", {
        onEnter = removeDuplicatesTable(staticData.onEnter),
        onActive = removeDuplicatesTable(staticData.onActive),
        onExit = removeDuplicatesTable(staticData.onExit),
        parameters = removeDuplicatesTable(staticData.parameters),
        reverb = removeDuplicatesTable(staticData.reverb)
    })

    local quads = {}
    for _, entry in pairs(ambientQuad) do
        if not quads[entry.events[1]] then
            quads[entry.events[1]] = entry.events
        end
    end
    config.saveFile("data/audio/ambientQuadFull.json", quads)

    local amb, ambAll = extractMetadata(ambientMetadata)
    local stat, statAll = extractMetadata(staticMetadata)
    config.saveFile("data/audio/ambientMetadataFull.json", amb)
    config.saveFile("data/audio/staticMetadataFull.json", stat)
    config.saveFile("data/audio/ambientMetadataAll.json", ambAll)
    config.saveFile("data/audio/staticMetadataAll.json", statAll)
end

---Checks whether any key in a lookup request is excluded from cache reuse.
---@param args string[] Cache keys to evaluate.
---@return boolean excluded
local function shouldExclude(args)
    for _, arg in pairs(args) do
        if isExcludedCacheKey(arg) then
            return true
        end
    end

    return false
end

---Creates an async cache lookup chain for one or more keys.
---If any key is missing (or excluded), `notFound` callback is run with a task object.
---The callback must call `task:taskCompleted()` exactly once after cache fill finishes.
---@param ... string List of cache keys to check.
---@return cacheTryGetChain chain
function cache.tryGet(...)
    local arg = {...}
    local missing = false

    for _, key in pairs(arg) do
        local value = cache.getValue(key)

        if value == nil then
            missing = true
        end
    end

    if shouldExclude(arg) then
        missing = true
    end

    return {
        ---Registers callback for missing-cache path.
        ---@param notFoundCallback fun(task: table) Invoked only when at least one key is missing or excluded.
        ---@return cacheTryGetFoundStage
        notFound = function (notFoundCallback)
            local task = tasks:new()
            if missing then
                task:addTask(function ()
                    notFoundCallback(task)
                end)
            end

            return {
                ---Registers callback for post-resolution path (after cache hit or fill).
                ---@param foundCallback fun()
                found = function (foundCallback)
                    task:onFinalize(function ()
                        foundCallback()
                    end)
                    task:run()
                end
            }
        end
    }
end

return cache
