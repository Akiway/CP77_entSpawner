local config = require("modules/utils/config")
local utils = require("modules/utils/utils")

---Static data surveyed from the shipped streamingsectors by
---`script/extract_destructible_node_usage.wscript`, describing how the game actually
---configures `worldInstancedDestructibleMeshNode`:
--- - which collision filter presets are used, and the masks that go with each of them
--- - which `.effect` resources are used as fracturing / idle effects
--- - the settings most commonly paired with each mesh
---Everything is loaded lazily on first use, since only the Destructible Mesh type needs it.
local destructibleData = {
    presetsPath = "data/static/destructible_filter_presets.json",
    effectsPath = "data/static/destructible_effects.json",
    meshDefaultsPath = "data/static/destructible_mesh_defaults.json",

    ---@type table?
    presets = nil,
    ---@type string[]?
    presetNames = nil,
    ---@type string[]?
    fracturingEffects = nil,
    ---@type string[]?
    idleEffects = nil,
    ---@type table?
    meshDefaults = nil
}

---Fallback masks, used when the preset data file is missing or a preset is unknown.
---Values of the "Debris" preset, which is the most common one by a wide margin.
destructibleData.fallbackMasks = {
    queryMask1 = "0",
    queryMask2 = "528384",
    simulationMask1 = "4096",
    simulationMask2 = "236"
}

destructibleData.fallbackPreset = "Debris"

---@param path string?
---@return string
local function normalizePath(path)
    return utils.trimString(path or ""):lower():gsub("/", "\\")
end

---@param value any
---@param fallback string
---@return string
local function maskString(value, fallback)
    local text = utils.trimString(value or "")
    if text == "" or not text:match("^%d+$") then
        return fallback
    end
    return text
end

function destructibleData.loadPresets()
    local data = config.loadFile(destructibleData.presetsPath)
    local entries = type(data) == "table" and data.presets or nil

    destructibleData.presets = {}
    destructibleData.presetNames = {}

    if type(entries) ~= "table" then
        destructibleData.presets[destructibleData.fallbackPreset] = utils.deepcopy(destructibleData.fallbackMasks)
        destructibleData.presetNames = { destructibleData.fallbackPreset }
        return
    end

    local ordered = {}
    for name, entry in pairs(entries) do
        if type(name) == "string" and type(entry) == "table" then
            destructibleData.presets[name] = {
                queryMask1 = maskString(entry.queryMask1, destructibleData.fallbackMasks.queryMask1),
                queryMask2 = maskString(entry.queryMask2, destructibleData.fallbackMasks.queryMask2),
                simulationMask1 = maskString(entry.simulationMask1, destructibleData.fallbackMasks.simulationMask1),
                simulationMask2 = maskString(entry.simulationMask2, destructibleData.fallbackMasks.simulationMask2)
            }
            table.insert(ordered, { name = name, uses = tonumber(entry.uses) or 0 })
        end
    end

    -- Most used presets first, so the common choices sit at the top of the dropdown.
    table.sort(ordered, function(a, b)
        if a.uses == b.uses then
            return a.name < b.name
        end
        return a.uses > b.uses
    end)

    for _, entry in ipairs(ordered) do
        table.insert(destructibleData.presetNames, entry.name)
    end

    if #destructibleData.presetNames == 0 then
        destructibleData.presets[destructibleData.fallbackPreset] = utils.deepcopy(destructibleData.fallbackMasks)
        destructibleData.presetNames = { destructibleData.fallbackPreset }
    end
end

---Ordered collision filter preset names, most used first.
---@return string[]
function destructibleData.getPresetNames()
    if not destructibleData.presetNames then
        destructibleData.loadPresets()
    end
    return destructibleData.presetNames
end

---Collision masks belonging to a preset. Always returns a usable table.
---@param name string?
---@return table {queryMask1, queryMask2, simulationMask1, simulationMask2}
function destructibleData.getPresetMasks(name)
    if not destructibleData.presets then
        destructibleData.loadPresets()
    end
    return destructibleData.presets[name or ""] or destructibleData.fallbackMasks
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

function destructibleData.loadEffects()
    local data = config.loadFile(destructibleData.effectsPath)

    destructibleData.fracturingEffects = toSelectableList(type(data) == "table" and data.fracturing or nil)
    destructibleData.idleEffects = toSelectableList(type(data) == "table" and data.idle or nil)
end

---Effect paths the game uses as `fracturingEffect`, prefixed with the "none" entry.
---@return string[]
function destructibleData.getFracturingEffects()
    if not destructibleData.fracturingEffects then
        destructibleData.loadEffects()
    end
    return destructibleData.fracturingEffects
end

---Effect paths the game uses as `idleEffect`, prefixed with the "none" entry.
---@return string[]
function destructibleData.getIdleEffects()
    if not destructibleData.idleEffects then
        destructibleData.loadEffects()
    end
    return destructibleData.idleEffects
end

function destructibleData.loadMeshDefaults()
    local data = config.loadFile(destructibleData.meshDefaultsPath)
    local entries = type(data) == "table" and data.meshes or nil

    destructibleData.meshDefaults = {}

    if type(entries) ~= "table" then
        return
    end

    for path, entry in pairs(entries) do
        if type(path) == "string" and type(entry) == "table" then
            destructibleData.meshDefaults[normalizePath(path)] = entry
        end
    end
end

---Settings the game most commonly uses with a given mesh, `nil` when it was never seen
---on a destructible node. Values are the raw strings from the survey, e.g. "Kinematic",
---"True", "30".
---@param meshPath string?
---@return table?
function destructibleData.getMeshDefaults(meshPath)
    if not destructibleData.meshDefaults then
        destructibleData.loadMeshDefaults()
    end

    local key = normalizePath(meshPath)
    if key == "" then
        return nil
    end

    return destructibleData.meshDefaults[key]
end

---Whether any surveyed settings exist for a mesh.
---@param meshPath string?
---@return boolean
function destructibleData.hasMeshDefaults(meshPath)
    return destructibleData.getMeshDefaults(meshPath) ~= nil
end

---Drops all cached data so the files are read again.
function destructibleData.reload()
    destructibleData.presets = nil
    destructibleData.presetNames = nil
    destructibleData.fracturingEffects = nil
    destructibleData.idleEffects = nil
    destructibleData.meshDefaults = nil
end

return destructibleData
