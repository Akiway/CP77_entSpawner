local config = require("modules/utils/config")

local backup = {
    root = "backup",
    metadataPath = "backup/metadata.json",
    metadata = nil
}

---@alias BackupSource "on_save"|"on_game_load"
---@alias BackupMetadataEntry { editedAt: string, createdAt: string }

---Normalizes filesystem separators to forward slashes.
---@param path string|nil Raw path that may include Windows separators.
---@return string normalizedPath
local function normalizePath(path)
    return (path or ""):gsub("\\", "/")
end

---Checks whether a directory exists and can be listed.
---@param path string Directory path to test.
---@return boolean exists
local function dirExists(path)
    local ok, result = pcall(function()
        return dir(path)
    end)

    return ok and type(result) == "table"
end

---Validates that a directory exists.
---This function does not create directories because CET sandbox APIs are limited.
---@param path string Directory path to validate.
---@return boolean available True when directory already exists (or path is empty).
local function ensureDir(path)
    path = normalizePath(path)
    if path == "" then return true end

    -- CET sandbox does not reliably expose shell execution APIs.
    -- We only verify directory existence; folder tree must already exist on disk.
    return dirExists(path)
end

---Validates that the parent directory of a file path exists.
---@param path string File path whose parent should be checked.
---@return boolean available
local function ensureParentDir(path)
    local parent = normalizePath(path):match("^(.*)/[^/]+$")
    if parent and parent ~= "" then
        return ensureDir(parent)
    end

    return true
end

---Returns a safe directory listing.
---If listing fails or the folder does not exist, returns an empty table.
---@param path string Directory path to list.
---@return table entries
local function safeDir(path)
    if not dirExists(path) then
        return {}
    end

    local ok, result = pcall(function()
        return dir(path)
    end)

    if not ok or type(result) ~= "table" then
        return {}
    end

    return result
end

---Reads a file as raw binary text.
---@param path string File path to read.
---@return string|nil content Returns `nil` when the file cannot be opened.
local function readRaw(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end

    local data = file:read("*a")
    file:close()
    return data
end

---Writes raw binary text to a file.
---@param path string Destination file path.
---@param data string File content to write.
---@return boolean success
local function writeRaw(path, data)
    if not ensureParentDir(path) then
        return false
    end

    local file = io.open(path, "wb")
    if not file then
        return false
    end

    file:write(data)
    file:close()
    return true
end

---Copies a file by loading and writing raw content.
---@param sourcePath string Source file path.
---@param targetPath string Destination file path.
---@return boolean success
local function copyFile(sourcePath, targetPath)
    local content = readRaw(sourcePath)
    if content == nil then
        return false
    end

    return writeRaw(targetPath, content)
end

---Extracts `lastEditedAt` from a JSON file without full JSON parsing.
---@param path string JSON file path.
---@return string|nil editedAt
local function getEditedAtFromJsonFile(path)
    local raw = readRaw(path)
    if raw == nil or raw == "" then
        return nil
    end

    local editedAt = raw:match('"lastEditedAt"%s*:%s*"([^"]+)"')
    if editedAt and editedAt ~= "" then
        return editedAt
    end

    return nil
end

---Removes all files and subdirectories content inside a directory.
---@param path string Directory path to clear.
---@return boolean success Always true; operation is best-effort.
local function clearDirectory(path)
    path = normalizePath(path)
    if path == "" or not dirExists(path) then
        return true
    end

    for _, entry in pairs(safeDir(path)) do
        local fullPath = path .. "/" .. entry.name

        if entry.type == "directory" then
            clearDirectory(fullPath)
        else
            os.remove(fullPath)
        end
    end

    return true
end

---Returns the current local timestamp using backup metadata format.
---@return string timestamp
local function getNowTimestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

---Checks whether a timestamp value is considered usable.
---@param value string|nil Timestamp candidate.
---@return boolean valid
local function isValidTimestamp(value)
    return type(value) == "string" and value ~= "" and value ~= "-"
end

---Trims leading and trailing whitespace from a string.
---@param value string|nil Input value.
---@return string|nil trimmed Nil when input is not a non-empty string.
local function trimString(value)
    if type(value) ~= "string" then
        return nil
    end

    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end

    return trimmed
end

---Normalizes timestamp-like strings into `YYYY-MM-DD HH:MM:SS` when possible.
---@param value string|nil Timestamp candidate.
---@return string|nil normalizedTimestamp
local function normalizeTimestampString(value)
    local trimmed = trimString(value)
    if not trimmed then
        return nil
    end

    local normalized = trimmed:gsub("T", " "):gsub("Z$", "")
    local y, m, d, hh, mm, ss = normalized:match("^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)")
    if y then
        return string.format("%s-%s-%s %s:%s:%s", y, m, d, hh, mm, ss)
    end

    local asNumber = tonumber(trimmed)
    if asNumber then
        return nil
    end

    return trimmed
end

---Formats Unix epoch seconds into backup timestamp format.
---@param value number Unix epoch value in seconds.
---@return string|nil formattedTimestamp
local function formatFromEpoch(value)
    if type(value) ~= "number" or value <= 0 then
        return nil
    end

    local ok, formatted = pcall(function()
        return os.date("%Y-%m-%d %H:%M:%S", math.floor(value))
    end)

    if ok and isValidTimestamp(formatted) then
        return formatted
    end

    return nil
end

---Normalizes heterogeneous time values into backup timestamp format.
---Supports plain strings, Unix seconds, Unix milliseconds, Windows FILETIME,
---and os.date-like tables (`year`, `month`, `day`, optional `hour`, `min`, `sec`).
---@param value string|number|table|nil Time-like value from metadata or dir entries.
---@return string|nil normalizedTimestamp
local function normalizeTimeValue(value)
    if type(value) == "string" then
        local normalized = normalizeTimestampString(value)
        if normalized then
            return normalized
        end

        local numeric = tonumber(value)
        if numeric then
            value = numeric
        else
            return nil
        end
    end

    if type(value) == "number" then
        -- Unix milliseconds.
        if value > 1e12 and value < 1e15 then
            return formatFromEpoch(value / 1000)
        end

        -- Windows FILETIME (100ns since 1601-01-01).
        if value >= 1e15 then
            local unixSeconds = (value / 10000000) - 11644473600
            return formatFromEpoch(unixSeconds)
        end

        -- Unix seconds.
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

---Finds and normalizes the most relevant timestamp from a directory entry table.
---@param entry table Directory entry object returned by `dir()`.
---@return string|nil normalizedTimestamp
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

---Looks up a file entry in its parent directory and returns its normalized timestamp.
---@param path string File path to inspect.
---@return string|nil normalizedTimestamp
local function getFileTimeFromDir(path)
    local normalizedPath = normalizePath(path)
    local parent, fileName = normalizedPath:match("^(.*)/([^/]+)$")
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

---Loads backup metadata into memory and guarantees expected table shape.
local function ensureMetadata()
    if backup.metadata then
        return
    end

    ensureDir(backup.root)

    local loaded = config.fileExists(backup.metadataPath) and config.loadFile(backup.metadataPath) or nil
    if type(loaded) ~= "table" then
        loaded = {}
    end

    if type(loaded.on_game_load) ~= "table" then
        loaded.on_game_load = {}
    end

    if type(loaded.on_save) ~= "table" then
        loaded.on_save = {}
    end

    backup.metadata = loaded
end

---Returns cached edit timestamp for a relative path from metadata, if available.
---@param relativePath string Relative path key, usually under `data/...`.
---@return string|nil editedAt
local function getKnownEditedAt(relativePath)
    ensureMetadata()

    local normalizedPath = normalizePath(relativePath)
    local onSaveEntry = backup.metadata.on_save and backup.metadata.on_save[normalizedPath] or nil
    if type(onSaveEntry) == "table" and isValidTimestamp(onSaveEntry.editedAt) then
        return onSaveEntry.editedAt
    end

    local onLoadEntry = backup.metadata.on_game_load and backup.metadata.on_game_load[normalizedPath] or nil
    if type(onLoadEntry) == "table" and isValidTimestamp(onLoadEntry.editedAt) then
        return onLoadEntry.editedAt
    end

    return nil
end

---Resolves the best available edit timestamp for a source file.
---Priority: `lastEditedAt` field in file, remembered metadata, then filesystem time.
---@param path string Source file path.
---@return string|nil editedAt
local function resolveSourceEditedAt(path)
    local normalizedPath = normalizePath(path)

    local editedAtFromFile = getEditedAtFromJsonFile(normalizedPath)
    if isValidTimestamp(editedAtFromFile) then
        return editedAtFromFile
    end

    local rememberedEditedAt = getKnownEditedAt(normalizedPath)
    if isValidTimestamp(rememberedEditedAt) then
        return rememberedEditedAt
    end

    local fileTime = getFileTimeFromDir(normalizedPath)
    if isValidTimestamp(fileTime) then
        return fileTime
    end

    return nil
end

---Persists in-memory backup metadata to disk.
---@return boolean success
local function saveMetadata()
    ensureMetadata()

    if not ensureDir(backup.root) then
        return false
    end

    local ok, payload = pcall(function()
        return json.encode(backup.metadata)
    end)

    if not ok then
        return false
    end

    return writeRaw(backup.metadataPath, payload)
end

---Builds the standard relative object path used by backup APIs.
---@param fileName string Object file name including extension (for example `MyGroup.json`).
---@return string relativePath
local function getObjectsRelativePath(fileName)
    return "data/objects/" .. fileName
end

---Builds a backup destination path from source namespace and relative file path.
---@param source BackupSource Backup namespace (`on_save` or `on_game_load`).
---@param relativePath string Relative path under mod root.
---@return string backupPath
local function getBackupPath(source, relativePath)
    return "backup/" .. source .. "/" .. normalizePath(relativePath)
end

---Stores backup metadata for one file entry in memory.
---@param source BackupSource Backup namespace where the file was written.
---@param relativePath string Relative source path used as metadata key.
---@param editedAt string|nil Source file edit timestamp, if known.
---@param createdAt string|nil Backup creation timestamp, defaults to current time.
local function recordBackup(source, relativePath, editedAt, createdAt)
    ensureMetadata()

    if type(backup.metadata[source]) ~= "table" then
        backup.metadata[source] = {}
    end

    backup.metadata[source][normalizePath(relativePath)] = {
        editedAt = editedAt or "-",
        createdAt = createdAt or getNowTimestamp()
    }
end

---Recursively copies a directory tree and optionally records per-file metadata.
---@param fromDir string Source directory path.
---@param toDir string Destination directory path.
---@param source BackupSource|nil Backup namespace used for metadata recording.
---@param timestamp string Backup creation timestamp recorded for copied files.
local function copyDirectoryRecursive(fromDir, toDir, source, timestamp)
    fromDir = normalizePath(fromDir)
    toDir = normalizePath(toDir)

    if not ensureDir(toDir) then
        return
    end

    for _, entry in pairs(safeDir(fromDir)) do
        local sourcePath = fromDir .. "/" .. entry.name
        local targetPath = toDir .. "/" .. entry.name

        if entry.type == "directory" then
            copyDirectoryRecursive(sourcePath, targetPath, source, timestamp)
        else
            if copyFile(sourcePath, targetPath) and source then
                local editedAt = nil
                if sourcePath:sub(-5):lower() == ".json" then
                    editedAt = resolveSourceEditedAt(sourcePath)
                end
                recordBackup(source, sourcePath, editedAt, timestamp)
            end
        end
    end
end

---Initializes backup folders and metadata store.
function backup.init()
    local requiredDirs = {
        "backup",
        "backup/on_game_load",
        "backup/on_game_load/data",
        "backup/on_game_load/data/objects",
        "backup/on_game_load/data/favorite",
        "backup/on_game_load/data/exportTemplates",
        "backup/on_save",
        "backup/on_save/data",
        "backup/on_save/data/objects"
    }

    local available = true
    local missingPaths = {}
    for _, path in ipairs(requiredDirs) do
        if not ensureDir(path) then
            available = false
            table.insert(missingPaths, path)
        end
    end

    ensureMetadata()

    if not saveMetadata() then
        available = false
    end

    if not available then
        print("[entSpawner] Backup folders are unavailable; backup features may be limited.")
        if #missingPaths > 0 then
            print("[entSpawner] Missing backup folders: " .. table.concat(missingPaths, ", "))
        end
    end
end

---Takes a full snapshot of persisted data on game load.
---Copies objects, favorites, and export templates into `backup/on_game_load`.
---@return boolean success
function backup.snapshotOnGameLoad()
    ensureMetadata()

    local timestamp = getNowTimestamp()
    backup.metadata.on_game_load = {}

    if not ensureDir("backup/on_game_load/data") then
        print("[entSpawner] Backup path unavailable: backup/on_game_load/data")
        return false
    end

    clearDirectory("backup/on_game_load/data")

    copyDirectoryRecursive("data/objects", "backup/on_game_load/data/objects", "on_game_load", timestamp)
    copyDirectoryRecursive("data/favorite", "backup/on_game_load/data/favorite", "on_game_load", timestamp)
    copyDirectoryRecursive("data/exportTemplates", "backup/on_game_load/data/exportTemplates", "on_game_load", timestamp)

    backup.metadata.last_game_load = timestamp
    saveMetadata()
    return true
end

---Creates/refreshes the `on_save` backup copy for one object file.
---@param fileName string Object file name including extension (for example `MyGroup.json`).
---@return boolean success
function backup.backupObjectBeforeSave(fileName)
    local relativePath = getObjectsRelativePath(fileName)
    local sourcePath = normalizePath(relativePath)
    local targetPath = getBackupPath("on_save", relativePath)
    local editedAt = resolveSourceEditedAt(sourcePath)

    if not config.fileExists(sourcePath) then
        return false
    end

    if not ensureParentDir(targetPath) then
        print("[entSpawner] Backup path unavailable: " .. targetPath)
        return false
    end

    if config.fileExists(targetPath) then
        os.remove(targetPath)
    end

    local copied = copyFile(sourcePath, targetPath)

    if copied then
        recordBackup("on_save", relativePath, editedAt, getNowTimestamp())
        saveMetadata()
    end

    return copied
end

---Returns the absolute backup-relative path for one object file.
---@param source BackupSource Backup namespace to query.
---@param fileName string Object file name including extension.
---@return string backupPath
function backup.getObjectBackupPath(source, fileName)
    return getBackupPath(source, getObjectsRelativePath(fileName))
end

---Returns whether a backup exists and the best timestamp to display for it.
---@param source BackupSource Backup namespace to inspect.
---@param fileName string Object file name including extension.
---@return boolean exists True when backup file exists on disk.
---@return string timestamp Best available timestamp (`editedAt`, fallback `createdAt`, or `"Unknown"`/`"-"`).
function backup.getObjectBackupInfo(source, fileName)
    local backupPath = backup.getObjectBackupPath(source, fileName)
    local exists = config.fileExists(backupPath)

    if not exists then
        return false, "-"
    end

    ensureMetadata()

    local relativePath = getObjectsRelativePath(fileName)
    if type(backup.metadata[source]) ~= "table" then
        backup.metadata[source] = {}
    end

    local entry = backup.metadata[source][relativePath]
    if type(entry) ~= "table" then
        entry = {}
        backup.metadata[source][relativePath] = entry
    end

    local dirty = false
    local timestamp = nil

    -- Prefer original file edit timestamp for backup entries.
    if isValidTimestamp(entry.editedAt) then
        timestamp = entry.editedAt
    else
        local editedAt = getEditedAtFromJsonFile(backupPath)
        if isValidTimestamp(editedAt) then
            entry.editedAt = editedAt
            timestamp = editedAt
            dirty = true
        else
            local rememberedEditedAt = getKnownEditedAt(relativePath)
            if isValidTimestamp(rememberedEditedAt) then
                entry.editedAt = rememberedEditedAt
                timestamp = rememberedEditedAt
                dirty = true
            end
        end
    end

    if not isValidTimestamp(entry.editedAt) and entry.editedAt ~= "-" then
        entry.editedAt = "-"
        dirty = true
    end

    -- Keep creation time metadata for future operations, but do not display it as edit time.
    if not isValidTimestamp(entry.createdAt) then
        if isValidTimestamp(entry.timestamp) then
            entry.createdAt = entry.timestamp
            dirty = true
        elseif source == "on_game_load" and isValidTimestamp(backup.metadata.last_game_load) then
            entry.createdAt = backup.metadata.last_game_load
            dirty = true
        else
            entry.createdAt = getNowTimestamp()
            dirty = true
        end
    end

    if not isValidTimestamp(timestamp) then
        timestamp = isValidTimestamp(entry.createdAt) and entry.createdAt or nil
    end

    if dirty then
        saveMetadata()
    end

    return true, timestamp or "Unknown"
end

---Restores one object file from a selected backup namespace.
---@param source BackupSource Backup namespace to restore from.
---@param fileName string Object file name including extension.
---@return boolean success
function backup.restoreObjectBackup(source, fileName)
    local sourcePath = backup.getObjectBackupPath(source, fileName)
    local targetPath = getObjectsRelativePath(fileName)

    if not config.fileExists(sourcePath) then
        return false
    end

    return copyFile(sourcePath, targetPath)
end

return backup
