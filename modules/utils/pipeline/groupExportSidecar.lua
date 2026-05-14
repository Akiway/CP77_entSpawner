local config = require("modules/utils/config")
local utils = require("modules/utils/utils")

local groupExportSidecar = {}
groupExportSidecar.SCHEMA_VERSION = 1

local function safeDir(path)
    local ok, listed = pcall(function ()
        return dir(path)
    end)

    if ok and type(listed) == "table" then
        return listed
    end

    return {}
end

local function normalizeTimestampString(value)
    local trimmed = utils.trimString(value)
    if trimmed == "" then
        return nil
    end

    local normalized = trimmed:gsub("T", " "):gsub("Z$", "")
    local y, m, d, hh, mm, ss = normalized:match("^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)")
    if y then
        return string.format("%s-%s-%s %s:%s:%s", y, m, d, hh, mm, ss)
    end

    return trimmed
end

local function formatFromEpoch(value)
    if type(value) ~= "number" or value <= 0 then
        return nil
    end

    local ok, formatted = pcall(function ()
        return os.date("%Y-%m-%d %H:%M:%S", math.floor(value))
    end)
    if ok and type(formatted) == "string" and formatted ~= "" then
        return formatted
    end

    return nil
end

local function normalizeTimeValue(value)
    if value == nil then
        return nil
    end

    if type(value) == "string" then
        local normalized = normalizeTimestampString(value)
        if normalized then
            return normalized
        end

        local asNumber = tonumber(value)
        if asNumber then
            return normalizeTimeValue(asNumber)
        end

        return nil
    end

    if type(value) == "number" then
        if value >= 1e18 then
            return formatFromEpoch(value / 1000000000)
        end

        if value >= 1e15 then
            local unixSeconds = (value / 10000000) - 11644473600
            return formatFromEpoch(unixSeconds)
        end

        if value >= 1e12 then
            return formatFromEpoch(value / 1000)
        end

        return formatFromEpoch(value)
    end

    if type(value) == "table" then
        local year = tonumber(value.year)
        local month = tonumber(value.month)
        local day = tonumber(value.day)
        local hour = tonumber(value.hour) or 0
        local min = tonumber(value.min) or 0
        local sec = tonumber(value.sec) or 0

        if year and month and day then
            return string.format("%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, min, sec)
        end
    end

    return nil
end

local function getEntryTimeValue(entry)
    if type(entry) ~= "table" then
        return nil
    end

    local candidateKeys = {
        "modified",
        "modifiedAt",
        "lastModified",
        "lastModifiedAt",
        "modificationTime",
        "writeTime",
        "lastWriteTime",
        "mtime",
        "time",
        "timestamp"
    }

    for _, key in ipairs(candidateKeys) do
        local normalized = normalizeTimeValue(entry[key])
        if normalized then
            return normalized
        end
    end

    for key, value in pairs(entry) do
        if type(key) == "string" then
            local lowered = key:lower()
            if lowered:find("time", 1, true) or lowered:find("date", 1, true) or lowered:find("modif", 1, true) then
                local normalized = normalizeTimeValue(value)
                if normalized then
                    return normalized
                end
            end
        end
    end

    return nil
end

local function getFileTimeFromDir(path)
    local parent, fileName = path:match("^(.*)/([^/]+)$")
    if not parent or not fileName then
        return nil
    end

    for _, entry in pairs(safeDir(parent)) do
        if entry and entry.name == fileName then
            return getEntryTimeValue(entry)
        end
    end

    return nil
end

local function readAll(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()
    return content
end

---@param variantName string?
---@return string
local function normalizeVariantName(variantName)
    local normalized = utils.trimString(variantName)
    if normalized == "" or normalized:lower() == "default" then
        return "default"
    end

    return normalized
end

local function normalizeNumber(value)
    local num = tonumber(value) or 0
    return string.format("%.17g", num)
end

function groupExportSidecar.resolveGroupSourceRevision(groupName)
    local normalizedName = utils.trimString(groupName)
    if normalizedName == "" then
        return "missing"
    end

    local path = "data/objects/" .. normalizedName .. ".json"
    if not config.fileExists(path) then
        return "missing"
    end

    local raw = readAll(path)
    if raw and raw ~= "" then
        local editedAt = raw:match('"lastEditedAt"%s*:%s*"([^"]+)"')
        editedAt = normalizeTimestampString(editedAt)
        if editedAt and editedAt ~= "" then
            return editedAt
        end
    end

    local fileTime = getFileTimeFromDir(path)
    if fileTime and fileTime ~= "" then
        return fileTime
    end

    return "unknown"
end

function groupExportSidecar.getExportPath(projectSlug)
    return "export/" .. tostring(projectSlug) .. "_exported.json"
end

function groupExportSidecar.getSidecarPath(projectSlug)
    return "export/" .. tostring(projectSlug) .. "_metadata.json"
end

---@param group table
---@param options table?
---@return string signature
function groupExportSidecar.buildGroupSignature(group, options)
    local opts = options or {}
    local parts = {}
    local variantKeys = {}
    local variantData = group and group.variantData or {}

    for key, _ in pairs(variantData or {}) do
        table.insert(variantKeys, tostring(key))
    end

    table.sort(variantKeys, function (a, b)
        local al = a:lower()
        local bl = b:lower()
        if al == bl then
            return a < b
        end
        return al < bl
    end)

    table.insert(parts, "sourceRevision=" .. groupExportSidecar.resolveGroupSourceRevision(group and group.name or ""))
    table.insert(parts, "scriptVersion=" .. tostring(opts.version or ""))
    table.insert(parts, "ignoreHiddenDuringExport=" .. ((opts.ignoreHiddenDuringExport and true) and "1" or "0"))
    table.insert(parts, "name=" .. tostring(group and group.name or ""))
    table.insert(parts, "category=" .. tostring(group and group.category or ""))
    table.insert(parts, "level=" .. tostring(group and group.level or ""))
    table.insert(parts, "streamingX=" .. normalizeNumber(group and group.streamingX))
    table.insert(parts, "streamingY=" .. normalizeNumber(group and group.streamingY))
    table.insert(parts, "streamingZ=" .. normalizeNumber(group and group.streamingZ))
    table.insert(parts, "prefabRef=" .. tostring(group and group.prefabRef or ""))
    table.insert(parts, "variantRef=" .. tostring(group and group.variantRef or ""))
    table.insert(parts, "variantCount=" .. tostring(#variantKeys))

    for _, key in ipairs(variantKeys) do
        local variant = variantData[key] or {}
        table.insert(parts, string.format(
            "variant:%s|name=%s|defaultOn=%s|ref=%s",
            key,
            normalizeVariantName(variant.name),
            variant.defaultOn and "1" or "0",
            tostring(variant.ref or "")
        ))
    end

    return table.concat(parts, "\n")
end

---@param nodes table?
---@return table
function groupExportSidecar.extractNodeRefs(nodes)
    local result = {}

    for _, node in ipairs(nodes or {}) do
        if node and node.nodeRef and node.nodeRef ~= "" then
            table.insert(result, {
                nodeRef = node.nodeRef,
                name = node.name or ""
            })
        end
    end

    return result
end

---@param exported table?
---@param devices table?
---@param psEntries table?
---@param childs table?
---@param communities table?
---@param spotNodes table?
---@return table
function groupExportSidecar.buildContribution(exported, devices, psEntries, childs, communities, spotNodes)
    local deviceHashes = {}
    local psEntryIds = {}

    for hash, _ in pairs(devices or {}) do
        table.insert(deviceHashes, tostring(hash))
    end
    table.sort(deviceHashes)

    for psid, _ in pairs(psEntries or {}) do
        table.insert(psEntryIds, tostring(psid))
    end
    table.sort(psEntryIds)

    return {
        sectorName = exported and exported.name or "",
        deviceHashes = deviceHashes,
        psEntryIds = psEntryIds,
        childs = utils.deepcopy(childs or {}),
        communities = utils.deepcopy(communities or {}),
        spotNodes = utils.deepcopy(spotNodes or {}),
        nodeRefs = groupExportSidecar.extractNodeRefs(exported and exported.nodes or {})
    }
end

---@param projectName string
---@param version string
---@param exportSettings table?
---@return table
function groupExportSidecar.createDocument(projectName, version, exportSettings)
    return {
        schemaVersion = groupExportSidecar.SCHEMA_VERSION,
        projectName = projectName,
        version = version,
        exportSettings = {
            ignoreHiddenDuringExport = exportSettings and exportSettings.ignoreHiddenDuringExport == true or false
        },
        groups = {}
    }
end

return groupExportSidecar
