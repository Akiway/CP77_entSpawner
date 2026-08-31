local config = require("modules/utils/core/config")
local utils = require("modules/utils/core/utils")

---Loads and caches the depot path lists used by the Conversation Area spawnable: the
---`.conversations` group resources and the open world conversation `.scene` files. Both are
---plain `.txt` path lists under `data/spawnables/area/conversationArea/`, using the same list
---format as the IES profile and other spawnable path lists.
---
---The lists only exist to populate the dropdowns; custom paths stay authorable, so a modded
---resource that is not on either list can still be typed in.
local conversationData = {}

---Value used to represent "no resource selected".
conversationData.none = ""

---Actor counts per conversation resource, dumped from the shipped archives.
---
---A scene binds one workspot per `scnActorDef`; `playerActors` are excluded, since the player is
---never bound to one. Measured against the 218 shipped nodes that play exactly one inline scene,
---the actor count matches the node's workspot count on 208 of them (95.4%), and every mismatch but
---one has the node carrying *more* workspots than the scene needs. So the count is a floor, not an
---exact requirement, and the UI presents it that way.
---
---Group entries hold `count` or `{ min, max }` across the scenes in the group.
local actorCountsPath = "data/static/conversation_actor_counts.json"

---@type table<string, table<string, number|number[]>>?
local actorCounts = nil

---@return table<string, table<string, number|number[]>>
local function getActorCounts()
    if actorCounts then
        return actorCounts
    end

    local ok, data = pcall(config.loadFile, actorCountsPath)
    if not ok or type(data) ~= "table" then
        data = {}
    end

    actorCounts = {
        scenes = type(data.scenes) == "table" and data.scenes or {},
        groups = type(data.groups) == "table" and data.groups or {}
    }

    return actorCounts
end

---Folder names that only exist to bucket variants of the same scene. They carry no meaning for a
---reader, so they are skipped when a label needs a parent folder to stay unambiguous.
local skippedSegments = {
    versions = true
}

---Turns one path segment into a readable label.
---`conversation_club_bartender_01` -> `Conversation Club Bartender 01`.
---@param segment string
---@return string
local function prettifySegment(segment)
    local words = {}

    for word in string.gmatch(segment, "[^_%-%s]+") do
        table.insert(words, word:sub(1, 1):upper() .. word:sub(2))
    end

    return table.concat(words, " ")
end

---Splits a depot path into its meaningful segments, with the extension dropped from the file name.
---@param path string
---@return string[]
local function splitPath(path)
    local parts = {}

    for part in string.gmatch(path, "[^/\\]+") do
        if not skippedSegments[string.lower(part)] then
            table.insert(parts, part)
        end
    end

    if #parts > 0 then
        parts[#parts] = utils.getFileName(path)
    end

    return parts
end

---Builds a label from the last `depth` segments of a path, parent folders first.
---@param parts string[]
---@param depth number
---@return string
local function buildLabel(parts, depth)
    local pieces = {}

    for index = math.max(1, #parts - depth + 1), #parts do
        table.insert(pieces, prettifySegment(parts[index]))
    end

    return table.concat(pieces, " / ")
end

---Builds the display label of every path in a list.
---
---Labels start at the file name alone, which is what reads best, and only the paths that would
---then collide pull in another parent folder. The shipped scene list needs this: 215 of its 639
---entries share a file name with a `versions\gold` variant of themselves.
---@param paths string[]
---@return table<string, string>
local function buildLabels(paths)
    local segments = {}
    local depths = {}

    for _, path in ipairs(paths) do
        segments[path] = splitPath(path)
        depths[path] = 1
    end

    local labels = {}

    -- Bounded: every pass either separates a collision or gives up because the path ran out of
    -- segments, and no shipped list needs more than three.
    for _ = 1, 8 do
        local counts = {}

        for _, path in ipairs(paths) do
            local label = buildLabel(segments[path], depths[path])
            labels[path] = label
            counts[label] = (counts[label] or 0) + 1
        end

        local collided = false

        for _, path in ipairs(paths) do
            if counts[labels[path]] > 1 and depths[path] < #segments[path] then
                depths[path] = depths[path] + 1
                collided = true
            end
        end

        if not collided then
            break
        end
    end

    return labels
end

---@class ConversationPathList
---@field path string Directory holding the `.txt` lists.
---@field list string[]? Cached paths, without the "none" sentinel.
---@field selectable string[]? Cached paths, prefixed with the "none" sentinel.
---@field labels table<string, string>? Cached display label per path.
---@field countKey string Key into the actor count table.
---@field reload fun(): string[]
---@field get fun(): string[]
---@field getSelectable fun(): string[]
---@field displayName fun(path: string?): string
---@field actorRange fun(path: string?): number?, number?

---@param path string Directory holding the `.txt` lists.
---@param countKey string Section of `conversation_actor_counts.json` holding this list's counts.
---@return ConversationPathList
local function newList(path, countKey)
    local store = {
        path = path,
        countKey = countKey,
        list = nil,
        selectable = nil,
        labels = nil
    }

    ---(Re)builds the sorted, de-duplicated path list from disk, and its display labels.
    ---@return string[]
    function store.reload()
        local seen = {}
        local paths = {}

        local ok, entries = pcall(config.loadLists, store.path)
        if ok and type(entries) == "table" then
            for _, entry in ipairs(entries) do
                local entryPath = entry and entry.data and entry.data.spawnData or entry and entry.name
                entryPath = utils.trimString(entryPath or "")
                if entryPath ~= "" then
                    local key = string.lower(entryPath)
                    if not seen[key] then
                        seen[key] = true
                        table.insert(paths, entryPath)
                    end
                end
            end
        end

        store.labels = buildLabels(paths)

        -- Sorted by what the user actually reads, not by the depot path.
        table.sort(paths, function(a, b)
            local labelA, labelB = string.lower(store.labels[a]), string.lower(store.labels[b])
            if labelA == labelB then
                return string.lower(a) < string.lower(b)
            end
            return labelA < labelB
        end)

        store.list = paths

        local selectable = { conversationData.none }
        for _, entryPath in ipairs(paths) do
            table.insert(selectable, entryPath)
        end
        store.selectable = selectable

        return paths
    end

    ---Returns the cached paths (no "none" entry), loading them on first use.
    ---@return string[]
    function store.get()
        if not store.list then
            store.reload()
        end
        return store.list
    end

    ---Returns the selectable options for a dropdown: the "none" sentinel followed by all paths.
    ---@return string[]
    function store.getSelectable()
        if not store.selectable then
            store.reload()
        end
        return store.selectable
    end

    ---Readable label for a path. A path that is not on the list, i.e. one the user typed in
    ---themselves, still gets a label, just without the collision check.
    ---@param path string?
    ---@return string
    function store.displayName(path)
        if path == nil or path == "" then
            return "None"
        end

        if not store.labels then
            store.reload()
        end

        return store.labels[path] or buildLabel(splitPath(path), 1)
    end

    ---Number of scene actors a resource needs to bind, i.e. how many workspots the area is
    ---expected to carry. A group spans several scenes, so it reports the range across them.
    ---Returns `nil` for a path that is not in the dump, which includes every modded resource.
    ---@param path string?
    ---@return number? min
    ---@return number? max
    function store.actorRange(path)
        if type(path) ~= "string" or path == "" then
            return nil, nil
        end

        local entry = getActorCounts()[store.countKey][string.lower(path)]

        if type(entry) == "number" then
            return entry, entry
        end

        -- Groups whose scenes disagree are stored as a `{ min, max }` pair.
        if type(entry) == "table" and type(entry[1]) == "number" and type(entry[2]) == "number" then
            return entry[1], entry[2]
        end

        return nil, nil
    end

    return store
end

---`scnInterestingConversationsResource` group resources (`.conversations`).
conversationData.groups = newList("data/spawnables/area/conversationArea/groups/", "groups")

---Open world conversation scenes (`.scene`) usable as an inline conversation.
conversationData.scenes = newList("data/spawnables/area/conversationArea/scenes/", "scenes")

---Formats an actor range as the workspot count hint shown next to a resource selector.
---@param min number?
---@param max number?
---@return string? label `nil` when the resource has no dumped count.
function conversationData.formatActorRange(min, max)
    if not min then
        return nil
    end

    if max and max ~= min then
        return string.format("%d - %d", min, max)
    end

    return tostring(min)
end

---Reloads both lists from disk.
function conversationData.reloadAll()
    conversationData.groups.reload()
    conversationData.scenes.reload()
end

---Export representation of an `rRef` / `raRef` resource reference for the WScript importer.
---@param path string?
---@param flags string? Reference flags, defaults to `"Default"`.
---@return table
function conversationData.exportRef(path, flags)
    return {
        ["DepotPath"] = {
            ["$type"] = "ResourcePath",
            ["$storage"] = "string",
            ["$value"] = path or ""
        },
        ["Flags"] = flags or "Default"
    }
end

return conversationData
