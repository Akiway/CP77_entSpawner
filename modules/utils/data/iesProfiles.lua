local config = require("modules/utils/core/config")
local utils = require("modules/utils/core/utils")

---Loads and caches the list of IES light projection profile paths from the `.txt`
---list files under `data/spawnables/lights/iesProfiles/`. Each line in those files is
---one depot resource path (e.g. `base\lighting\ies\29.ies`), matching the same list
---format used by other spawnable path lists.
local iesProfiles = {
    path = "data/spawnables/lights/iesProfiles/",
    ---@type string[]?
    list = nil,
    ---@type string[]?
    selectable = nil
}

---Value used to represent "no IES profile".
iesProfiles.none = ""

---(Re)builds the sorted, de-duplicated list of IES profile paths from disk.
---@return string[]
function iesProfiles.reload()
    local seen = {}
    local paths = {}

    local ok, entries = pcall(config.loadLists, iesProfiles.path)
    if ok and type(entries) == "table" then
        for _, entry in ipairs(entries) do
            local path = entry and entry.data and entry.data.spawnData or entry and entry.name
            path = utils.trimString(path or "")
            if path ~= "" then
                local key = string.lower(path)
                if not seen[key] then
                    seen[key] = true
                    table.insert(paths, path)
                end
            end
        end
    end

    table.sort(paths, function(a, b) return string.lower(a) < string.lower(b) end)

    iesProfiles.list = paths

    -- Selectable list is the profiles prefixed with the "none" sentinel.
    local selectable = { iesProfiles.none }
    for _, path in ipairs(paths) do
        table.insert(selectable, path)
    end
    iesProfiles.selectable = selectable

    return paths
end

---Returns the cached IES profile paths (no "none" entry), loading them on first use.
---@return string[]
function iesProfiles.get()
    if not iesProfiles.list then
        iesProfiles.reload()
    end
    return iesProfiles.list
end

---Returns the selectable options for a dropdown: the "none" sentinel followed by all profiles.
---@return string[]
function iesProfiles.getSelectable()
    if not iesProfiles.selectable then
        iesProfiles.reload()
    end
    return iesProfiles.selectable
end

---Human readable label for a profile path, mapping the empty "none" sentinel to "None".
---@param path string?
---@return string
function iesProfiles.displayName(path)
    if path == nil or path == "" then
        return "None"
    end
    return tostring(path)
end

---Returns the profile that follows `current` in the selectable list, wrapping around.
---The "none" sentinel is part of the cycle (position 0), so cycling from the last profile
---returns to "None" and cycling from "None" selects the first profile. Mirrors the mesh
---appearance cycle logic.
---@param current string?
---@return string next
---@return boolean changed
function iesProfiles.getNext(current)
    local list = iesProfiles.get()
    local count = #list
    if count == 0 then
        return current or iesProfiles.none, false
    end

    current = current or iesProfiles.none

    -- Virtual index: 0 = none, 1..count = profiles.
    local currentIndex = 0
    for index, path in ipairs(list) do
        if path == current then
            currentIndex = index
            break
        end
    end

    local nextIndex = currentIndex + 1
    if nextIndex > count then
        nextIndex = 0
    end

    local nextValue = nextIndex == 0 and iesProfiles.none or list[nextIndex]
    return nextValue, nextValue ~= current
end

---Extracts the readable depot path from a raRef:CIESDataResource value as stored in
---component instance data, i.e. `{ Flags = ..., DepotPath = { $value = ... } }`.
---Returns "" when unset. Falls back to hash resolution when the path is stored as a hash.
---@param value any
---@return string
function iesProfiles.extractPath(value)
    if type(value) == "string" then
        return value
    end
    if type(value) ~= "table" then
        return ""
    end

    local depot = value.DepotPath
    if depot == nil then
        return ""
    end

    local raw = depot
    if type(depot) == "table" then
        raw = depot["$value"]
    end

    if type(raw) == "string" then
        return raw
    end
    if type(raw) == "number" then
        if raw == 0 then
            return ""
        end
        local ok, str = pcall(function() return ResRef.FromHash(raw):ToString() end)
        if ok and type(str) == "string" then
            return str
        end
    end

    return ""
end

---Builds a raRef:CIESDataResource instance-data value for the given depot path, preserving
---any existing sibling fields (e.g. `Flags`) from `existing`.
---@param existing any The current value (table) to derive flags/shape from.
---@param path string? The new depot path ("" clears the profile).
---@return table
function iesProfiles.buildRef(existing, path)
    local ref = utils.deepcopy(type(existing) == "table" and existing or {})
    ref.Flags = ref.Flags or "Default"
    ref.DepotPath = {
        ["$type"] = "ResourcePath",
        ["$storage"] = "string",
        ["$value"] = path or ""
    }
    return ref
end

---Export representation of a raRef:CIESDataResource for the WScript importer.
---@param path string?
---@return table
function iesProfiles.exportRef(path)
    return {
        DepotPath = {
            ["$type"] = "ResourcePath",
            ["$storage"] = "string",
            ["$value"] = path or ""
        },
        Flags = "Default"
    }
end

return iesProfiles
