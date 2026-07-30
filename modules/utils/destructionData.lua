local config = require("modules/utils/config")
local utils = require("modules/utils/utils")
local destructibleData = require("modules/utils/destructibleData")

---Static data surveyed from the shipped streamingsectors by
---`script/extract_destruction_node_usage.wscript`, describing how the game configures the
---two authorable destruction nodes other than `worldInstancedDestructibleMeshNode`:
--- - `worldPhysicalDestructionNode`, 19539 placements over 425 meshes
--- - `worldBakedDestructionNode`, 4116 placements over 83 meshes
---
---Collision masks are not stored here: the survey confirmed they follow from the filter
---preset name alone, so they come from [[destructibleData]], which owns the shared
---preset -> masks map. Everything is loaded lazily, only the two spawnable types need it.
local destructionData = {
    physicalDefaultsPath = "data/static/physical_destruction_mesh_defaults.json",
    bakedDefaultsPath = "data/static/baked_destruction_mesh_defaults.json",
    listsPath = "data/static/destruction_lists.json",

    ---@type table?
    physicalDefaults = nil,
    ---@type string[]?
    physicalLevelEffects = nil,
    ---@type table?
    bakedDefaults = nil,
    ---@type string[]?
    fracturedMeshOptions = nil,
    ---@type string[]?
    fracturingEffects = nil,
    ---@type string[]?
    destructionEffects = nil,
    ---@type string[]?
    physicalAudioMetadata = nil,
    ---@type string[]?
    bakedAudioMetadata = nil,
    ---@type string[]?
    allAudioMetadata = nil
}

---Presets each node class was actually seen using, most used first. Offering the full
---13 entry preset map would list combinations the game never pairs with these nodes.
---
---`Custom` is deliberately absent: it means the author overrode the masks by hand, and the
---survey found its masks differ between placements, so they cannot be derived from the name.
---Four meshes carry it; `sanitizePreset` maps them onto the fallback instead of exporting a
---preset whose masks would be wrong.
destructionData.physicalPresets = { "Destructible", "Debris", "Foliage Debris", "Debris Cluster", "World Dynamic" }
destructionData.bakedPresets = { "Destructible", "Debris", "World Static" }

---Fallbacks used when a preset is unknown or a data file is missing.
destructionData.fallbackPhysicalPreset = "Destructible"
destructionData.fallbackBakedPreset = "Destructible"

---@param path string?
---@return string
local function normalizePath(path)
    return utils.trimString(path or ""):lower():gsub("/", "\\")
end

---@param value any
---@return table
local function asTable(value)
    return type(value) == "table" and value or {}
end

---@param list any
---@return string[]
local function toSelectableList(list)
    -- Leading empty entry is the "None" option of the dropdowns.
    local out = { "" }
    if type(list) ~= "table" then
        return out
    end

    local seen = {}
    for _, path in ipairs(list) do
        local text = utils.trimString(path or "")
        if text ~= "" and not seen[text:lower()] then
            seen[text:lower()] = true
            table.insert(out, text)
        end
    end

    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

---Maps a surveyed preset name onto one the class can actually express.
---
---The survey's rare outliers are not all usable: `Custom` means the masks were overridden by
---hand and differ between placements, and `<unset>` is not a preset at all. Both would export
---a filter whose masks do not match the name, so they collapse onto the fallback.
---@param name string?
---@param allowed string[]
---@param fallback string
---@return string
local function sanitizePreset(name, allowed, fallback)
    local text = utils.trimString(name or "")
    if text == "" or utils.indexValue(allowed, text) == -1 then
        return fallback
    end
    return text
end

---@param entries any
---@return table
local function keyByNormalizedPath(entries)
    local out = {}
    for path, entry in pairs(asTable(entries)) do
        if type(path) == "string" and type(entry) == "table" then
            out[normalizePath(path)] = entry
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Physical destruction
---------------------------------------------------------------------------

function destructionData.loadPhysicalDefaults()
    local data = config.loadFile(destructionData.physicalDefaultsPath)

    destructionData.physicalDefaults = keyByNormalizedPath(type(data) == "table" and data.meshes or nil)

    -- Each level stores its fracturing effect as an index into this shared table; the same
    -- path repeats across a mesh's 3 or 4 levels, so storing it once keeps the file small.
    destructionData.physicalLevelEffects = {}
    for _, path in ipairs(asTable(type(data) == "table" and data.levelEffects or nil)) do
        table.insert(destructionData.physicalLevelEffects, utils.trimString(path or ""))
    end
end

---Settings the game most commonly uses with a mesh placed as a physical destruction node,
---`nil` when it was never seen on one. Values are the raw survey strings, e.g. "Kinematic",
---"True", "0.246153995".
---@param meshPath string?
---@return table?
function destructionData.getPhysicalDefaults(meshPath)
    if not destructionData.physicalDefaults then
        destructionData.loadPhysicalDefaults()
    end

    local key = normalizePath(meshPath)
    if key == "" then
        return nil
    end

    return destructionData.physicalDefaults[key]
end

---@param meshPath string?
---@return boolean
function destructionData.hasPhysicalDefaults(meshPath)
    return destructionData.getPhysicalDefaults(meshPath) ~= nil
end

---Destruction levels the game uses for a mesh, decoded from the stored signature.
---Each level is `{ preset = string, fracturingEffect = string }`, `fracturingEffect` being
---an empty string when that level plays nothing.
---
---The level count is not a free choice: it follows the fracture hierarchy baked into the
---mesh, so callers should take the length from here rather than letting the user pick.
---@param meshPath string?
---@return table[]?
function destructionData.getPhysicalLevels(meshPath)
    local defaults = destructionData.getPhysicalDefaults(meshPath)
    if not defaults or type(defaults.levels) ~= "table" then
        return nil
    end

    local levels = {}
    for _, encoded in ipairs(defaults.levels) do
        local text = tostring(encoded or "")
        local preset, index = text:match("^(.-)#(%d+)$")

        if not preset then
            preset = text
        end

        local effect = ""
        if index then
            effect = destructionData.physicalLevelEffects[tonumber(index) + 1] or ""
        end

        table.insert(levels, {
            preset = sanitizePreset(preset, destructionData.physicalPresets, destructionData.fallbackPhysicalPreset),
            fracturingEffect = effect
        })
    end

    return #levels > 0 and levels or nil
end

---------------------------------------------------------------------------
-- Baked destruction
---------------------------------------------------------------------------

function destructionData.loadBakedDefaults()
    local data = config.loadFile(destructionData.bakedDefaultsPath)
    destructionData.bakedDefaults = keyByNormalizedPath(type(data) == "table" and data.meshes or nil)
end

---@param meshPath string?
---@return table?
function destructionData.getBakedDefaults(meshPath)
    if not destructionData.bakedDefaults then
        destructionData.loadBakedDefaults()
    end

    local key = normalizePath(meshPath)
    if key == "" then
        return nil
    end

    return destructionData.bakedDefaults[key]
end

---@param meshPath string?
---@return boolean
function destructionData.hasBakedDefaults(meshPath)
    return destructionData.getBakedDefaults(meshPath) ~= nil
end

---The distinct fractured meshes the game uses, prefixed with the "none" entry. Derived from
---the per mesh defaults rather than stored separately, since it is just their value set.
---@return string[]
function destructionData.getFracturedMeshOptions()
    if not destructionData.fracturedMeshOptions then
        if not destructionData.bakedDefaults then
            destructionData.loadBakedDefaults()
        end

        local paths = {}
        for _, entry in pairs(destructionData.bakedDefaults) do
            local path = utils.trimString(entry.meshFractured or "")
            if path ~= "" then
                table.insert(paths, path)
            end
        end

        destructionData.fracturedMeshOptions = toSelectableList(paths)
    end

    return destructionData.fracturedMeshOptions
end

---The fractured mesh the game pairs with an intact mesh. The survey found this mapping to
---be one to one for the 58 meshes that have one, so it can be filled in automatically.
---@param meshPath string?
---@return string path Empty when the mesh has no known counterpart.
---@return boolean ambiguous True when the game used several fractured meshes for it.
function destructionData.getFracturedMesh(meshPath)
    local defaults = destructionData.getBakedDefaults(meshPath)
    if not defaults then
        return "", false
    end

    return utils.trimString(defaults.meshFractured or ""), defaults.fracturedAmbiguous == true
end

---------------------------------------------------------------------------
-- Effects and audio metadata
---------------------------------------------------------------------------

---Audio metadata names keep their surveyed order, most used first, rather than being
---sorted: "phys_set_dst_trash_barrel" being near the top is more useful than alphabetical.
---@param list any
---@return string[]
local function toOrderedList(list)
    local out = { "None" }
    local seen = { none = true }

    for _, name in ipairs(asTable(list)) do
        local text = utils.trimString(name or "")
        if text ~= "" and not seen[text:lower()] then
            seen[text:lower()] = true
            table.insert(out, text)
        end
    end

    return out
end

function destructionData.loadLists()
    local data = config.loadFile(destructionData.listsPath)
    local root = asTable(data)

    destructionData.fracturingEffects = toSelectableList(root.physicalFracturing)
    destructionData.destructionEffects = toSelectableList(root.bakedDestruction)
    destructionData.physicalAudioMetadata = toOrderedList(root.physicalAudioMetadata)
    destructionData.bakedAudioMetadata = toOrderedList(root.bakedAudioMetadata)
end

---Every .effect in the game, prefixed with "none". The effect selectors are deliberately not
---restricted to the paths the survey saw on a given node type: nothing in the engine ties an
---effect to one node class, so any of them is a valid choice. The surveyed lists are still
---below, for reference and for pre-filling per mesh defaults.
---@return string[]
function destructionData.getAllEffects()
    return destructibleData.getAllEffects()
end

---Effect paths the game hangs off a physical destruction level, prefixed with "none".
---@return string[]
function destructionData.getFracturingEffects()
    if not destructionData.fracturingEffects then
        destructionData.loadLists()
    end
    return destructionData.fracturingEffects
end

---Effect paths the game uses as `destructionEffect` on baked nodes, prefixed with "none".
---@return string[]
function destructionData.getDestructionEffects()
    if not destructionData.destructionEffects then
        destructionData.loadLists()
    end
    return destructionData.destructionEffects
end

---Every audio metadata set seen on either destruction node type, "None" first, most used
---first after that. Unlike the effects there is no enumerable list of all of them in the
---depot, so this union is the widest set available; anything else can still be typed in.
---@return string[]
function destructionData.getAllAudioMetadata()
    if destructionData.allAudioMetadata then
        return destructionData.allAudioMetadata
    end

    if not destructionData.physicalAudioMetadata then
        destructionData.loadLists()
    end

    local merged = {}
    local seen = {}
    for _, list in ipairs({ destructionData.physicalAudioMetadata, destructionData.bakedAudioMetadata }) do
        for _, name in ipairs(list) do
            if not seen[name:lower()] then
                seen[name:lower()] = true
                table.insert(merged, name)
            end
        end
    end

    destructionData.allAudioMetadata = merged
    return merged
end

---------------------------------------------------------------------------
-- Shared
---------------------------------------------------------------------------

---Collision masks of a preset, from the shared map in [[destructibleData]].
---@param name string?
---@return table {queryMask1, queryMask2, simulationMask1, simulationMask2}
function destructionData.getPresetMasks(name)
    return destructibleData.getPresetMasks(name)
end

---Drops all cached data so the files are read again.
function destructionData.reload()
    destructionData.physicalDefaults = nil
    destructionData.physicalLevelEffects = nil
    destructionData.bakedDefaults = nil
    destructionData.fracturedMeshOptions = nil
    destructionData.fracturingEffects = nil
    destructionData.destructionEffects = nil
    destructionData.physicalAudioMetadata = nil
    destructionData.bakedAudioMetadata = nil
    destructionData.allAudioMetadata = nil
    destructibleData.reload()
end

return destructionData
