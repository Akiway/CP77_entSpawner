config = {}

---@class ConfigSpawnFileEntry
---@field data any spawn payload extracted from `spawnable` in a JSON file
---@field lastSpawned any always initialized to `nil` by the loader
---@field name string display name read from the JSON payload
---@field fileName string logical file identifier (currently the same value as `name`)

---@class ConfigSpawnPathEntry
---@field data ConfigSpawnPathData wrapper holding one list line as spawn data
---@field lastSpawned any always initialized to `nil` by the loader
---@field name string parsed spawn path
---@field fileName string file name extracted from `name`

---@class ConfigSpawnPathData
---@field spawnData string raw spawn path read from a `.txt` line
---@field deviceClassName string? optional device class name parsed from list line (`{className} {path}`)

---Checks whether a file can be opened for reading.
---@param filename string Relative or absolute file path.
---@return boolean exists `true` when the file exists and is readable.
function config.fileExists(filename)
    local f=io.open(filename,"r")
    if (f~=nil) then io.close(f) return true else return false end
end

---Reads the full text content of a file.
---@param path string Relative or absolute file path.
---@return string? content Full file content, or `nil` when the file cannot be opened.
local function readAll(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()
    return content
end

---Writes text content to a file in one pass.
---@param path string Relative or absolute destination path.
---@param content string Raw text to write.
---@return boolean success `true` when write completes.
---@return string? err Error code/message when write fails (`open_failed` or runtime error text).
local function writeAll(path, content)
    local file = io.open(path, "w")
    if not file then
        return false, "open_failed"
    end

    local ok, err = pcall(function ()
        file:write(content)
    end)
    file:close()

    if not ok then
        os.remove(path)
        return false, tostring(err)
    end

    return true
end

---Promotes a temporary file to the final target path.
---Attempts direct rename first, then falls back to a `.swap` replacement flow.
---@param path string Final destination path.
---@param tmpPath string Temporary file path created by `saveFile`.
---@return boolean success `true` when the temporary file becomes the target file.
---@return string? err Error code when replacement fails (`swap_failed` or `promote_failed`).
local function replaceFile(path, tmpPath)
    if os.rename(tmpPath, path) then
        return true
    end

    local swapPath = path .. ".swap"
    local hasTarget = config.fileExists(path)

    if hasTarget then
        if config.fileExists(swapPath) then
            os.remove(swapPath)
        end

        if not os.rename(path, swapPath) then
            return false, "swap_failed"
        end
    end

    if os.rename(tmpPath, path) then
        if hasTarget then
            os.remove(swapPath)
        end
        return true
    end

    if hasTarget and config.fileExists(swapPath) then
        os.rename(swapPath, path)
    end

    return false, "promote_failed"
end

---Recovers from interrupted swap-based replacement.
---If `path.swap` exists and `path` is missing, the swap file is restored.
---@param path string Final destination path without the `.swap` suffix.
local function recoverSwapFile(path)
    local swapPath = path .. ".swap"
    if not config.fileExists(swapPath) then
        return
    end

    if config.fileExists(path) then
        os.remove(swapPath)
        return
    end

    os.rename(swapPath, path)
end

---Creates a JSON config file only when it does not already exist.
---@param path string Destination JSON path.
---@param data table<string, any> Default payload used when creating the file.
function config.tryCreateConfig(path, data)
	if not config.fileExists(path) then
        config.saveFile(path, data)
    end
end

---Loads and decodes a JSON file.
---Returns an empty table when the file is missing, invalid, or not a JSON object/array.
---@param path string Source JSON path.
---@return table<string, any> decoded Decoded JSON table, or `{}` on failure.
function config.loadFile(path)
    recoverSwapFile(path)

    local raw = readAll(path)
    if raw == nil then
        print("Failed to load file: " .. path .. ", restoring empty state")
        return {}
    end

    local decoded = {}
    local success = pcall(function ()
        decoded = json.decode(raw)
    end)
    if not success then
        print("Failed to load file: " .. path .. ", restoring empty state")
        return {}
    end
    if type(decoded) ~= "table" then
        print("Failed to load file: " .. path .. ", restoring empty state")
        return {}
    end

    return decoded
end

---Encodes and saves a Lua table as JSON using temp-file replacement.
---This method is resilient to partial writes by using `.tmp` and `.swap` files.
---@param path string Destination JSON path.
---@param data table<string, any> Lua table to serialize as JSON.
---@return boolean success `true` when save completes.
---@return string? err Error text/code when encoding, writing, or replacement fails.
function config.saveFile(path, data)
    recoverSwapFile(path)

    local encoded
    local encodedOk, encodedErr = pcall(function ()
        encoded = json.encode(data)
    end)
    if not encodedOk then
        print("Failed to encode file: " .. path .. " (" .. tostring(encodedErr) .. ")")
        return false, tostring(encodedErr)
    end
    if type(encoded) ~= "string" then
        print("Failed to encode file: " .. path .. " (invalid payload)")
        return false, "invalid_payload"
    end

    local tmpPath = path .. ".tmp"
    if config.fileExists(tmpPath) then
        os.remove(tmpPath)
    end

    local written, writeErr = writeAll(tmpPath, encoded)
    if not written then
        os.remove(tmpPath)
        print("Failed to write temp file: " .. tmpPath .. " (" .. tostring(writeErr) .. ")")
        return false, tostring(writeErr)
    end

    local replaced, replaceErr = replaceFile(path, tmpPath)
    if not replaced then
        os.remove(tmpPath)
        print("Failed to replace file: " .. path .. " (" .. tostring(replaceErr) .. ")")
        return false, tostring(replaceErr)
    end

    return true
end

---Recursively loads spawn definitions from `.json` files in a directory.
---Each JSON file is expected to contain `name` and `spawnable` keys.
---@param path string Directory path (callers pass a trailing `/`).
---@param files ConfigSpawnFileEntry[]? Optional accumulator for recursive calls.
---@return ConfigSpawnFileEntry[] files Sorted by `name` in ascending order.
function config.loadFiles(path, files)
    local files = files or {}

    for _, file in pairs(dir(path)) do
        if file.name:match("^.+(%..+)$") == ".json" then
            local data = config.loadFile(path .. file.name)
            table.insert(files, {data = data.spawnable, lastSpawned = nil, name = data.name, fileName = data.name })
        elseif file.type == "directory" then
            config.loadFiles(path .. file.name .. "/", files)
        end
    end

    table.sort(files, function(a, b) return a.name < b.name end)

    return files
end

---Recursively loads spawn paths from `.txt` files in a directory.
---Each line becomes one spawn entry with `data.spawnData` and optional `data.deviceClassName`.
---Accepted line formats:
--- - `{path}`
--- - `{className} {path}`
--- - ` {path}` (explicit empty class name)
---@param path string Directory path (callers pass a trailing `/`).
---@param paths ConfigSpawnPathEntry[]? Optional accumulator for recursive calls.
---@return ConfigSpawnPathEntry[] paths Sorted by `name` in ascending order.
function config.loadLists(path, paths)
    local utils = require("modules/utils/utils")
    local paths = paths or {}

    ---Parses one list line into optional class name + spawn path.
    ---@param line string
    ---@return string className
    ---@return string spawnPath
    local function parseSpawnListLine(line)
        local raw = tostring(line or "")
        local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")

        if trimmed == "" then
            return "", ""
        end

        if trimmed:find("//", 1, true) == 1 or trimmed:find("#", 1, true) == 1 or trimmed:find(";", 1, true) == 1 then
            return "", ""
        end

        local firstToken, rest = trimmed:match("^(%S+)%s+(.+)$")
        if not firstToken or not rest then
            return "", trimmed
        end

        -- Path-only line with no class prefix.
        if firstToken:find("\\", 1, true) or firstToken:find("/", 1, true) then
            return "", trimmed
        end

        return firstToken, rest:gsub("^%s+", ""):gsub("%s+$", "")
    end

    for _, file in pairs(dir(path)) do
        local extension = file.name:match("^.+(%..+)$")
        if extension and extension:lower() == ".txt" then
            local data = io.open(path .. file.name)
            for line in data:lines() do
                local className, spawnPath = parseSpawnListLine(line)
                if spawnPath ~= "" then
                    table.insert(paths, {
                        data = { spawnData = spawnPath, deviceClassName = className },
                        lastSpawned = nil,
                        name = spawnPath,
                        fileName = utils.getFileName(spawnPath)
                    })
                end
            end

            data:close()
        elseif file.type == "directory" then
            config.loadLists(path .. file.name .. "/", paths)
        end
    end

    table.sort(paths, function(a, b) return a.name < b.name end)

    return paths
end

---Copies keys from `source` into `target` only when missing in `target`.
---Nested tables are merged recursively when both sides are tables.
---@param source table Table containing default values.
---@param target table Table to patch in place.
local function recursiveAddMissingKeys(source, target)
    for k, v in pairs(source) do
        if type(v) == "table" and type(target[k]) == "table" then
            recursiveAddMissingKeys(v, target[k])
        elseif target[k] == nil then
            target[k] = v
        end
    end
end

---Backfills missing keys in an existing JSON file to preserve backward compatibility.
---@param path string Target JSON path to update.
---@param data table Table containing default keys and values.
function config.backwardComp(path, data)
    local f = config.loadFile(path)

    recursiveAddMissingKeys(data, f)

    config.saveFile(path, f)
end

---Loads a plain text file into a list of lines.
---@param path string Source text file path.
---@return string[] lines One element per line in file order.
function config.loadText(path)
    local lines = {}
    for line in io.lines(path) do
        table.insert(lines, line)
    end
    return lines
end

---Loads a full file as raw text without JSON decoding.
---@param path string Source file path.
---@return string content Full file contents.
function config.loadRaw(path)
    local file = io.open(path, "r")
    local content = file:read("*a")
    file:close()
    return content
end

---Writes raw text to a file without JSON encoding.
---@param path string Destination file path.
---@param data string Raw content to write.
function config.saveRaw(path, data)
    local file = io.open(path, "w")
    file:write(data)
    file:close()
end

---Writes each value from `data` to a new line in a text file.
---@param path string Destination file path.
---@param data table Values to write (each value is converted with Lua concatenation rules).
function config.saveRawTable(path, data)
    local file = io.open(path, "w")
    for _, line in pairs(data) do
        file:write(line .. "\n")
    end
    file:close()
end

return config
