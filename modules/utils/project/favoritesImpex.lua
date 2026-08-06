local assetFavorites = require("modules/utils/project/assetFavorites")
local utils = require("modules/utils/core/utils")
local logger = require("modules/utils/core/logger")

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local PACKAGE_TYPE = "entSpawnerFavorites"
local PACKAGE_VERSION = 1

---Share layer for asset favorites: turns a set of favorites into a Base64 encoded
---JSON code that can be pasted back on another install.
---Codes are self contained, they carry the favorited assets plus the icon of every
---tag those assets use, so importing recreates the tags as well.
---@class favoritesImpex
local favoritesImpex = {}

local b64Indices = {}
for i = 1, #B64_CHARS do
    b64Indices[B64_CHARS:sub(i, i)] = i - 1
end

---@param data string
---@return string
local function encodeBase64(data)
    local encoded = {}

    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        b = b or 0
        c = c or 0

        -- Split the 3 byte group into 4 six bit indices, without bitwise operators
        local indices = {
            math.floor(a / 4),
            (a % 4) * 16 + math.floor(b / 16),
            (b % 16) * 4 + math.floor(c / 64),
            c % 64
        }

        for j = 1, 4 do
            table.insert(encoded, B64_CHARS:sub(indices[j] + 1, indices[j] + 1))
        end
    end

    -- Blank out the characters standing for the bytes the last group did not have
    for j = 0, (3 - #data % 3) % 3 - 1 do
        encoded[#encoded - j] = "="
    end

    return table.concat(encoded)
end

---@param data string
---@return string
local function decodeBase64(data)
    local sanitized = tostring(data or ""):gsub("[^" .. B64_CHARS .. "]", "")
    local decoded = {}

    for i = 1, #sanitized, 4 do
        local group = sanitized:sub(i, i + 3)
        local i1 = b64Indices[group:sub(1, 1)] or 0
        local i2 = b64Indices[group:sub(2, 2)] or 0
        local i3 = b64Indices[group:sub(3, 3)] or 0
        local i4 = b64Indices[group:sub(4, 4)] or 0

        table.insert(decoded, string.char(i1 * 4 + math.floor(i2 / 16)))

        -- A trailing group shorter than 4 characters carries fewer than 3 bytes
        if #group >= 3 then
            table.insert(decoded, string.char((i2 % 16) * 16 + math.floor(i3 / 4)))
        end
        if #group >= 4 then
            table.insert(decoded, string.char((i3 % 4) * 64 + i4))
        end
    end

    return table.concat(decoded)
end

---Condenses one favorite into the short keyed form used inside a code.
---@param entry assetFavoriteEntry
---@return table
local function minifyEntry(entry)
    local minified = {
        n = entry.name,
        m = entry.modulePath,
        p = entry.path
    }

    local tags = assetFavorites.getEntryTags(entry)
    if #tags > 0 then
        minified.t = tags
    end

    -- Path list entries only ever hold `{ spawnData = path }`, which the importer
    -- rebuilds from `p` alone. Only richer spawn data has to travel with the entry.
    local data = entry.data
    local isDefaultData = type(data) == "table" and data.spawnData == entry.path and utils.tableLength(data) == 1

    if type(data) == "table" and not isDefaultData then
        minified.d = data
    end

    return minified
end

---Restores one condensed entry, or nil when it lacks the fields identifying an asset.
---@param minified table
---@return {modulePath: string, path: string, name: string, data: table, tags: string[]}?
local function expandEntry(minified)
    if type(minified) ~= "table" then
        return nil
    end

    local modulePath = utils.trimString(minified.m)
    local path = utils.trimString(minified.p)

    if modulePath == "" or path == "" then
        return nil
    end

    local name = utils.trimString(minified.n)
    local tags = {}

    for _, tag in pairs(type(minified.t) == "table" and minified.t or {}) do
        if type(tag) == "string" and tag ~= "" then
            table.insert(tags, tag)
        end
    end

    return {
        modulePath = modulePath,
        path = path,
        name = name ~= "" and name or utils.getFileName(path),
        data = type(minified.d) == "table" and minified.d or { spawnData = path },
        tags = tags
    }
end

---Name + icon of every tag used by `entries`, so an import can recreate them.
---@param entries assetFavoriteEntry[]
---@return table[]
local function collectUsedTags(entries)
    local seen = {}
    local tags = {}

    for _, entry in ipairs(entries) do
        for _, tag in ipairs(assetFavorites.getEntryTags(entry)) do
            if not seen[tag] then
                seen[tag] = true
                table.insert(tags, { n = tag, i = assetFavorites.getTagIconKey(tag) })
            end
        end
    end

    return tags
end

---Encodes a list of favorites into a shareable code.
---@param entries assetFavoriteEntry[]
---@return string? code Nil when there is nothing to export.
---@return number count
function favoritesImpex.exportEntries(entries)
    if type(entries) ~= "table" or #entries == 0 then
        return nil, 0
    end

    local data = {}
    for _, entry in ipairs(entries) do
        table.insert(data, minifyEntry(entry))
    end

    local usedTags = collectUsedTags(entries)

    local payload = {
        v = PACKAGE_VERSION,
        type = PACKAGE_TYPE,
        tags = #usedTags > 0 and usedTags or nil,
        data = data
    }

    return encodeBase64(json.encode(payload)), #data
end

---Encodes every favorite carrying `tagName`.
---@param tagName string
---@return string? code Nil when no favorite uses the tag.
---@return number count
function favoritesImpex.exportTag(tagName)
    local entries = {}

    for _, entry in ipairs(assetFavorites.getEntries()) do
        if entry.tags[tagName] then
            table.insert(entries, entry)
        end
    end

    return favoritesImpex.exportEntries(entries)
end

---Decodes and validates a code without applying it.
---@param code string
---@return table? payload
---@return string? err Reason to show the user when decoding fails.
function favoritesImpex.decode(code)
    local sanitized = utils.trimString(code)
    if sanitized == "" then
        return nil, "Paste a favorites code first."
    end

    local decoded = decodeBase64(sanitized)
    if decoded == "" then
        return nil, "This is not a valid favorites code."
    end

    local success, payload = pcall(json.decode, decoded)
    if not success or type(payload) ~= "table" or type(payload.data) ~= "table" then
        return nil, "This is not a valid favorites code."
    end

    if payload.type ~= PACKAGE_TYPE then
        return nil, "This code does not contain favorites."
    end

    if (tonumber(payload.v) or 0) > PACKAGE_VERSION then
        return nil, "This code was made with a newer version of entSpawner."
    end

    return payload, nil
end

---@class favoritesImportReport
---@field imported number Assets newly added to the favorites.
---@field updated number Already favorited assets that gained tags from the code.
---@field skipped number Entries that were invalid or already up to date.
---@field tagsCreated number Tags the code introduced.
---@field err string? Set when the code could not be decoded, nothing was applied.

---Applies a code, adding its favorites and merging their tags into existing ones.
---Favorites already present keep their name and spawn data, only missing tags are added.
---@param code string
---@return favoritesImportReport report
function favoritesImpex.import(code)
    local report = { imported = 0, updated = 0, skipped = 0, tagsCreated = 0 }

    local payload, err = favoritesImpex.decode(code)
    if not payload then
        report.err = err
        return report
    end

    assetFavorites.runBatch(function ()
        -- Tags first, so the favorites below attach to tags carrying their icon.
        -- Tags already known keep the icon they were given locally.
        for _, tag in pairs(type(payload.tags) == "table" and payload.tags or {}) do
            local name = type(tag) == "table" and utils.trimString(tag.n) or ""

            if name ~= "" and not assetFavorites.hasTag(name) then
                assetFavorites.createTag(name, type(tag) == "table" and tag.i or nil)
                report.tagsCreated = report.tagsCreated + 1
            end
        end

        for _, minified in pairs(payload.data) do
            local imported = expandEntry(minified)
            local existing = imported and assetFavorites.get(imported.modulePath, imported.path) or nil
            local entry = existing

            if imported and not existing then
                entry = assetFavorites.add(imported.modulePath, imported.path, imported.name, imported.data)
            end

            if not entry then
                report.skipped = report.skipped + 1
            else
                local gainedTag = false

                for _, tag in ipairs(imported.tags) do
                    if not entry.tags[tag] then
                        assetFavorites.setEntryTag(entry, tag, true)
                        gainedTag = true
                    end
                end

                if not existing then
                    report.imported = report.imported + 1
                elseif gainedTag then
                    report.updated = report.updated + 1
                else
                    report.skipped = report.skipped + 1
                end
            end
        end
    end)

    logger:info(string.format(
        "[Asset Favorites] Imported code: %d added, %d updated, %d skipped, %d tag(s) created",
        report.imported, report.updated, report.skipped, report.tagsCreated
    ))

    return report
end

return favoritesImpex
