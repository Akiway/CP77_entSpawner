local config = require("modules/utils/config")
local utils = require("modules/utils/utils")
local logger = require("modules/utils/logger")

-- Lives in its own subfolder: `data/favorite` is scanned (non recursively) for prefab
-- categories by prefabsUI, so a sibling directory keeps both systems apart.
local FAVORITES_FILE_PATH = "data/favorite/assets/favoriteAssets.json"
local DEFAULT_TAG_ICON = "TagOutline"
local NO_TAG_GROUP_NAME = "No Tag"

---Storage / query layer for asset favorites.
---Favorites are plain bookmarks to one entry of a "Spawn New" list. Unlike prefabs
---they never store any configuration (transform, appearance, ...), only the asset
---reference itself plus user tags.
---@class assetFavorites
---@field entries assetFavoriteEntry[]
---@field byKey table<string, assetFavoriteEntry>
---@field tags table<string, {icon: string}>
---@field loaded boolean
local assetFavorites = {
    entries = {},
    byKey = {},
    tags = {},
    loaded = false
}

---@class assetFavoriteEntry
---@field modulePath string Spawnable module path, e.g. `mesh/mesh`
---@field path string Spawn list entry key (asset path for path lists, entry name otherwise)
---@field name string Display name
---@field data table Spawn data of the referenced list entry
---@field tags table<string, boolean>

assetFavorites.defaultTagIcon = DEFAULT_TAG_ICON
assetFavorites.noTagGroupName = NO_TAG_GROUP_NAME

-- Nesting depth of `runBatch`, and whether a save was asked for while inside one
local suspendedSaves = 0
local pendingSave = false

---Builds the unique lookup key of one favorited asset.
---@param modulePath string?
---@param path string?
---@return string
function assetFavorites.getKey(modulePath, path)
    return tostring(modulePath or "") .. "|" .. tostring(path or "")
end

---@param iconKey string?
---@return string
local function sanitizeTagIcon(iconKey)
    local key = tostring(iconKey or "")
    if key == "" or not IconGlyphs[key] then
        return DEFAULT_TAG_ICON
    end

    return key
end

---@param entry assetFavoriteEntry
local function indexEntry(entry)
    assetFavorites.byKey[assetFavorites.getKey(entry.modulePath, entry.path)] = entry
end

---Registers a tag in the tag registry, keeping any already configured icon.
---@param name string
---@param icon string?
---@return boolean created
local function registerTag(name, icon)
    local tagName = tostring(name or "")
    if tagName == "" then
        return false
    end

    if assetFavorites.tags[tagName] then
        if icon and icon ~= "" then
            assetFavorites.tags[tagName].icon = sanitizeTagIcon(icon)
        end
        return false
    end

    assetFavorites.tags[tagName] = { icon = sanitizeTagIcon(icon) }
    return true
end

---@param rawTags any
---@return table<string, boolean>
local function deserializeTags(rawTags)
    local tags = {}

    if type(rawTags) ~= "table" then
        return tags
    end

    for key, value in pairs(rawTags) do
        -- Supports both the array form (["a", "b"]) and the map form ({a = true}).
        local tagName = type(key) == "number" and value or key
        if type(tagName) == "string" and tagName ~= "" and value ~= false then
            tags[tagName] = true
            registerTag(tagName)
        end
    end

    return tags
end

---@param tags table<string, boolean>
---@return string[]
local function serializeTags(tags)
    local list = utils.getKeys(tags or {})
    table.sort(list)

    return list
end

---Loads favorites and the tag registry from disk.
function assetFavorites.load()
    assetFavorites.entries = {}
    assetFavorites.byKey = {}
    assetFavorites.tags = {}

    if not config.fileExists(FAVORITES_FILE_PATH) then
        assetFavorites.loaded = true
        return
    end

    local data = config.loadFile(FAVORITES_FILE_PATH)

    if type(data.tags) == "table" then
        for name, tagData in pairs(data.tags) do
            if type(name) == "string" then
                registerTag(name, type(tagData) == "table" and tagData.icon or nil)
            end
        end
    end

    for _, rawEntry in pairs(type(data.favorites) == "table" and data.favorites or {}) do
        local modulePath = type(rawEntry) == "table" and tostring(rawEntry.modulePath or "") or ""
        local path = type(rawEntry) == "table" and tostring(rawEntry.path or "") or ""

        if modulePath ~= "" and path ~= "" and not assetFavorites.byKey[assetFavorites.getKey(modulePath, path)] then
            local entry = {
                modulePath = modulePath,
                path = path,
                name = tostring(rawEntry.name or utils.getFileName(path)),
                data = type(rawEntry.data) == "table" and rawEntry.data or { spawnData = path },
                tags = deserializeTags(rawEntry.tags)
            }

            table.insert(assetFavorites.entries, entry)
            indexEntry(entry)
        end
    end

    assetFavorites.loaded = true
end

---Writes favorites and the tag registry to disk.
---Inside `runBatch` the write is deferred and `true` is returned right away.
---@return boolean success
function assetFavorites.save()
    if suspendedSaves > 0 then
        pendingSave = true
        return true
    end

    local data = {
        version = 1,
        tags = {},
        favorites = {}
    }

    for name, tagData in pairs(assetFavorites.tags) do
        data.tags[name] = { icon = sanitizeTagIcon(tagData.icon) }
    end

    for _, entry in ipairs(assetFavorites.entries) do
        table.insert(data.favorites, {
            modulePath = entry.modulePath,
            path = entry.path,
            name = entry.name,
            data = entry.data,
            tags = serializeTags(entry.tags)
        })
    end

    local saved, err = config.saveFile(FAVORITES_FILE_PATH, data)
    if not saved then
        logger:error(string.format("[Asset Favorites] Could not save '%s' (%s). Make sure the folder exists.", FAVORITES_FILE_PATH, tostring(err)))
    end

    return saved
end

---Runs `action`, collapsing every save it triggers into a single write.
---Used by bulk operations, where saving per changed entry would rewrite the file
---(and diff it against its previous content) dozens of times.
---@param action fun()
function assetFavorites.runBatch(action)
    suspendedSaves = suspendedSaves + 1

    local success, err = pcall(action)

    suspendedSaves = suspendedSaves - 1

    if suspendedSaves == 0 and pendingSave then
        pendingSave = false
        assetFavorites.save()
    end

    if not success then
        -- Whatever the action managed to change before failing is kept and saved
        logger:error(string.format("[Asset Favorites] Batch operation failed (%s)", tostring(err)))
    end
end

---@return assetFavoriteEntry[]
function assetFavorites.getEntries()
    return assetFavorites.entries
end

---@return number
function assetFavorites.getCount()
    return #assetFavorites.entries
end

---@param modulePath string?
---@param path string?
---@return assetFavoriteEntry?
function assetFavorites.get(modulePath, path)
    return assetFavorites.byKey[assetFavorites.getKey(modulePath, path)]
end

---@param modulePath string?
---@param path string?
---@return boolean
function assetFavorites.isFavorite(modulePath, path)
    return assetFavorites.byKey[assetFavorites.getKey(modulePath, path)] ~= nil
end

---Marks one asset as favorite. Existing favorites are returned untouched.
---@param modulePath string
---@param path string
---@param name string?
---@param data table?
---@return assetFavoriteEntry?
function assetFavorites.add(modulePath, path, name, data)
    modulePath = tostring(modulePath or "")
    path = tostring(path or "")

    if modulePath == "" or path == "" then
        logger:warn("[Asset Favorites] Ignored favorite with missing module path or asset path")
        return nil
    end

    local existing = assetFavorites.get(modulePath, path)
    if existing then
        return existing
    end

    local entry = {
        modulePath = modulePath,
        path = path,
        name = tostring(name or utils.getFileName(path)),
        data = type(data) == "table" and utils.deepcopy(data) or { spawnData = path },
        tags = {}
    }

    table.insert(assetFavorites.entries, entry)
    indexEntry(entry)
    assetFavorites.save()

    return entry
end

---@param modulePath string?
---@param path string?
---@return boolean removed
function assetFavorites.remove(modulePath, path)
    local key = assetFavorites.getKey(modulePath, path)
    if not assetFavorites.byKey[key] then
        return false
    end

    for idx, entry in ipairs(assetFavorites.entries) do
        if assetFavorites.getKey(entry.modulePath, entry.path) == key then
            table.remove(assetFavorites.entries, idx)
            break
        end
    end

    assetFavorites.byKey[key] = nil
    assetFavorites.save()

    return true
end

---Toggles the favorite state of one asset.
---@param modulePath string
---@param path string
---@param name string?
---@param data table?
---@return boolean isFavoriteNow
function assetFavorites.toggle(modulePath, path, name, data)
    if assetFavorites.isFavorite(modulePath, path) then
        assetFavorites.remove(modulePath, path)
        return false
    end

    return assetFavorites.add(modulePath, path, name, data) ~= nil
end

---@param entry assetFavoriteEntry
---@return string[]
function assetFavorites.getEntryTags(entry)
    return serializeTags(entry and entry.tags or {})
end

---@param entry assetFavoriteEntry
---@param tagName string
---@param state boolean
function assetFavorites.setEntryTag(entry, tagName, state)
    if not entry then return end

    tagName = tostring(tagName or "")
    if tagName == "" then return end

    if state then
        registerTag(tagName)
        entry.tags[tagName] = true
    else
        entry.tags[tagName] = nil
    end

    assetFavorites.save()
end

---All tag names known to the favorites system, sorted alphabetically.
---@return string[]
function assetFavorites.getTagNames()
    local names = utils.getKeys(assetFavorites.tags)
    table.sort(names, function (a, b) return string.lower(a) < string.lower(b) end)

    return names
end

---@param tagName string?
---@return string iconKey
function assetFavorites.getTagIconKey(tagName)
    local tagData = assetFavorites.tags[tostring(tagName or "")]

    return sanitizeTagIcon(tagData and tagData.icon or nil)
end

---@param tagName string?
---@return string glyph
function assetFavorites.getTagGlyph(tagName)
    return IconGlyphs[assetFavorites.getTagIconKey(tagName)] or IconGlyphs[DEFAULT_TAG_ICON]
end

---@param tagName string
---@param iconKey string
function assetFavorites.setTagIcon(tagName, iconKey)
    local tagData = assetFavorites.tags[tostring(tagName or "")]
    if not tagData then return end

    tagData.icon = sanitizeTagIcon(iconKey)
    assetFavorites.save()
end

---Creates a tag in the registry, or updates the icon of an existing one.
---@param tagName string
---@param iconKey string?
---@return boolean created False when the tag already existed (its icon is still updated).
function assetFavorites.createTag(tagName, iconKey)
    local created = registerTag(tagName, iconKey)

    if tostring(tagName or "") ~= "" then
        assetFavorites.save()
    end

    return created
end

---@param tagName string?
---@return boolean exists
function assetFavorites.hasTag(tagName)
    return assetFavorites.tags[tostring(tagName or "")] ~= nil
end

---Removes one tag from the registry and from every favorite using it.
---@param tagName string
function assetFavorites.deleteTag(tagName)
    tagName = tostring(tagName or "")
    if tagName == "" or not assetFavorites.tags[tagName] then return end

    assetFavorites.tags[tagName] = nil

    for _, entry in ipairs(assetFavorites.entries) do
        entry.tags[tagName] = nil
    end

    assetFavorites.save()
end

---Whether a favorite carries at least one tag besides `tagName`.
---@param entry assetFavoriteEntry
---@param tagName string
---@return boolean
local function hasOtherTag(entry, tagName)
    for tag, isSet in pairs(entry.tags or {}) do
        if isSet and tag ~= tagName then
            return true
        end
    end

    return false
end

---Number of favorites carrying this tag and no other one, which `deleteTagWithOrphans` removes.
---@param tagName string?
---@return number
function assetFavorites.getTagOrphanCount(tagName)
    tagName = tostring(tagName or "")
    local count = 0

    for _, entry in ipairs(assetFavorites.entries) do
        if entry.tags[tagName] and not hasOtherTag(entry, tagName) then
            count = count + 1
        end
    end

    return count
end

---Removes one tag, along with every favorite it was the only tag of.
---Favorites carrying other tags are kept, and only lose this one.
---@param tagName string
---@return number removed Favorites removed along with the tag
function assetFavorites.deleteTagWithOrphans(tagName)
    tagName = tostring(tagName or "")
    if tagName == "" or not assetFavorites.tags[tagName] then return 0 end

    local removed = 0

    -- Single write for the whole operation, instead of one per removed favorite.
    assetFavorites.runBatch(function ()
        -- Backwards, so removing an entry cannot skip the next one.
        for idx = #assetFavorites.entries, 1, -1 do
            local entry = assetFavorites.entries[idx]

            if entry.tags[tagName] and not hasOtherTag(entry, tagName) then
                table.remove(assetFavorites.entries, idx)
                assetFavorites.byKey[assetFavorites.getKey(entry.modulePath, entry.path)] = nil
                removed = removed + 1
            end
        end

        -- Drops the tag off the favorites that survived, and off the registry.
        assetFavorites.deleteTag(tagName)
    end)

    return removed
end

---@param oldName string
---@param newName string
---@return boolean changed
function assetFavorites.renameTag(oldName, newName)
    return assetFavorites.mergeTags({ [tostring(oldName or "")] = true }, newName)
end

---Merges every tag in `tagNames` into `newName`, on the registry and on all favorites.
---@param tagNames table<string, boolean>
---@param newName string
---@return boolean changed
function assetFavorites.mergeTags(tagNames, newName)
    newName = tostring(newName or "")
    if newName == "" or type(tagNames) ~= "table" then
        return false
    end

    local changed = false
    local iconKey = nil

    for tagName, isSelected in pairs(tagNames) do
        if isSelected and tagName ~= newName and assetFavorites.tags[tagName] then
            iconKey = iconKey or assetFavorites.tags[tagName].icon
            assetFavorites.tags[tagName] = nil
            changed = true
        end
    end

    if changed then
        registerTag(newName, iconKey)
    end

    for _, entry in ipairs(assetFavorites.entries) do
        local hasSource = false

        for tagName, isSelected in pairs(tagNames) do
            if isSelected and tagName ~= newName and entry.tags[tagName] then
                entry.tags[tagName] = nil
                hasSource = true
            end
        end

        if hasSource then
            entry.tags[newName] = true
            changed = true
        end
    end

    if changed then
        assetFavorites.save()
    end

    return changed
end

---Number of favorites carrying one tag.
---@param tagName string
---@return number
function assetFavorites.getTagUsageCount(tagName)
    local count = 0

    for _, entry in ipairs(assetFavorites.entries) do
        if entry.tags[tagName] then
            count = count + 1
        end
    end

    return count
end

return assetFavorites
