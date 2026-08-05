local config = require("modules/utils/config")
local utils = require("modules/utils/utils")
local backup = require("modules/utils/backup")
local logger = require("modules/utils/logger")

---File-name identity for saved projects.
---
---A project's file name in `data/objects/` is its unique id: it is what the Projects tab lists, what
---auto-save writes to, and what a spawned root group is bound to. The group's `name` is free-form
---display text and is only consulted once, when a never-saved group needs a first file name.
local projectFiles = {}

projectFiles.directory = "data/objects/"
projectFiles.extension = ".json"

---Names Windows refuses regardless of extension.
local RESERVED_NAMES = {
    con = true, prn = true, aux = true, nul = true,
    com1 = true, com2 = true, com3 = true, com4 = true, com5 = true,
    com6 = true, com7 = true, com8 = true, com9 = true,
    lpt1 = true, lpt2 = true, lpt3 = true, lpt4 = true, lpt5 = true,
    lpt6 = true, lpt7 = true, lpt8 = true, lpt9 = true
}

---@param name string?
---@return string
local function trim(name)
    return tostring(name or ""):match("^%s*(.-)%s*$")
end

---Derives a file name from a free-form group name.
---
---Only used the first time a group is saved. Deliberately stricter than what the file system allows
---(spaces and apostrophes become underscores) so generated names stay consistent with every project
---file created before names were allowed to be free-form.
---@param name string? Free-form group name.
---@return string baseName Never empty, without extension.
function projectFiles.sanitizeBaseName(name)
    local base = utils.createFileName(trim(name))

    -- Windows rejects trailing dots and spaces, and a name made only of separators would leave
    -- nothing to write to.
    base = trim(base:gsub("[%.%s]+$", ""))

    if base == "" or RESERVED_NAMES[base:lower()] then
        base = "Group"
    end

    return base
end

---Checks a file name the user typed, which may keep spaces and other characters the derived form
---replaces. Only what the file system itself rejects is refused here.
---@param baseName string File name without extension.
---@return boolean valid
---@return string? error
function projectFiles.isValidBaseName(baseName)
    local base = tostring(baseName or "")

    if trim(base) == "" then
        return false, "File name cannot be empty"
    end

    local illegal = base:match('[<>:"/\\|%?%*]')
    if illegal then
        return false, string.format("\"%s\" is not allowed in a file name", illegal)
    end

    if base:match("%c") then
        return false, "File name contains control characters"
    end

    if base:match("[%.%s]$") then
        return false, "File name cannot end with a space or a dot"
    end

    if RESERVED_NAMES[base:lower()] then
        return false, string.format("\"%s\" is a reserved file name", base)
    end

    return true
end

---@param baseName string File name without extension.
---@return string fileName
function projectFiles.withExtension(baseName)
    return baseName .. projectFiles.extension
end

---@param fileName string? File name including extension.
---@return string baseName
function projectFiles.stripExtension(fileName)
    return (tostring(fileName or ""):gsub("%.json$", ""))
end

---@param fileName string File name including extension.
---@return string path
function projectFiles.getPath(fileName)
    return projectFiles.directory .. fileName
end

---@param fileName string? File name including extension.
---@return boolean
function projectFiles.exists(fileName)
    if type(fileName) ~= "string" or fileName == "" then
        return false
    end

    return config.fileExists(projectFiles.getPath(fileName))
end

---Finds the file that would collide with `fileName` on disk.
---
---Compared case-insensitively because the game runs on Windows, where `MyGroup.json` and
---`mygroup.json` are the same file -- renaming one onto the other would silently destroy a project.
---@param fileName string File name including extension.
---@param exceptFileName string? File name to ignore, normally the one being renamed.
---@return string? existingFileName The actual name on disk, when one collides.
function projectFiles.findColliding(fileName, exceptFileName)
    local target = tostring(fileName or ""):lower()
    if target == "" then
        return nil
    end

    local except = tostring(exceptFileName or ""):lower()

    for _, file in pairs(dir(projectFiles.directory)) do
        local name = tostring(file.name or "")
        local lowered = name:lower()

        if lowered == target and lowered ~= except then
            return name
        end
    end

    return nil
end

---Suggests a free file name derived from a group name.
---@param name string? Free-form group name.
---@return string fileName Including extension, guaranteed to be free at the time of the call.
---@return string? takenBy The colliding file, when the plain derived name was already in use.
function projectFiles.suggestFileName(name)
    local base = projectFiles.sanitizeBaseName(name)
    local candidate = projectFiles.withExtension(base)
    local collision = projectFiles.findColliding(candidate)

    if not collision then
        return candidate, nil
    end

    local index = 1
    while true do
        candidate = projectFiles.withExtension(string.format("%s_%d", base, index))
        if not projectFiles.findColliding(candidate) then
            return candidate, collision
        end

        index = index + 1
    end
end

---Validates a file name typed by the user, including its collision check.
---@param fileName string File name with or without extension.
---@param exceptFileName string? Existing file name being renamed, which may keep its own name.
---@return boolean valid
---@return string? error Human readable reason, when invalid.
function projectFiles.validateFileName(fileName, exceptFileName)
    local base = projectFiles.stripExtension(trim(fileName))

    local valid, err = projectFiles.isValidBaseName(base)
    if not valid then
        return false, err
    end

    local collision = projectFiles.findColliding(projectFiles.withExtension(base), exceptFileName)
    if collision then
        return false, string.format("\"%s\" already exists", collision)
    end

    return true
end

---Decides which file a save should write to.
---
---A group that already has a uID keeps it, whatever it is called now. One that has never been saved
---gets a file named after it -- once -- and only if that name is actually free: silently picking
---`name_1.json` would hide the fact that the user already has a project by that name, and writing
---over it would destroy it.
---@param projectUID string? The group's current uID, when it has one.
---@param groupName string? Free-form group name, used only to derive a first file name.
---@return string? fileName Ready to write to, or `nil` when the user has to decide.
---@return string? suggestion Free file name to offer when the derived one was taken.
---@return string? takenBy The existing file that blocked the derived name.
function projectFiles.resolveSaveTarget(projectUID, groupName)
    if type(projectUID) == "string" and projectUID ~= "" then
        return projectUID
    end

    local suggestion, takenBy = projectFiles.suggestFileName(groupName)
    if takenBy then
        return nil, suggestion, takenBy
    end

    return suggestion
end

---Renames a project file on disk, carrying its backups along.
---
---Backups are keyed by file name, so leaving them behind would silently detach "Restore previous
---save" from the project it belongs to.
---@param oldFileName string File name including extension.
---@param newFileName string File name including extension.
---@return boolean ok
---@return string? error
function projectFiles.rename(oldFileName, newFileName)
    if oldFileName == newFileName then
        return true
    end

    if not projectFiles.exists(oldFileName) then
        return false, string.format("\"%s\" no longer exists on disk", tostring(oldFileName))
    end

    local valid, err = projectFiles.validateFileName(newFileName, oldFileName)
    if not valid then
        return false, err
    end

    local renamed, renameErr = os.rename(projectFiles.getPath(oldFileName), projectFiles.getPath(newFileName))
    if not renamed then
        return false, tostring(renameErr or "rename failed")
    end

    backup.renameObjectBackups(oldFileName, newFileName)
    logger:info(string.format("[ProjectFiles] Renamed \"%s\" to \"%s\"", oldFileName, newFileName))

    return true
end

return projectFiles
