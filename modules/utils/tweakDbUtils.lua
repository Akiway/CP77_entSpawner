local utils = require("modules/utils/utils")
local gameUtils = require("modules/utils/gameUtils")

---Helpers for reading live TweakDB data.
---Everything is resolved from the running games TweakDB, so records and flats added at runtime
---(e.g. by TweakXL) are included.
---
---Record classes do not expose RTTI properties, only generated getters (`DisplayName()`, `GetTagsCount()`, ...).
---Their flat names are the getter names with a lowercased first letter, so the getter list is used to
---probe `TweakDB:GetFlat("<record>.<flat>")`, which returns properly typed values for every flat.
local tweakDbUtils = {}

local MAX_ARRAY_ENTRIES = 24
local MAX_PARENT_DEPTH = 24
local MAX_CACHED_RECORDS = 256
local MAX_VALUE_LENGTH = 120

---@type table<string, string[]> Flat name candidates, keyed by record class name
local flatNamesByClass = {}
---@type table<string, table|false> Record info keyed by record ID, `false` for unresolvable IDs
local recordsByID = {}
local cachedRecords = 0
local locKeyCache = {}

---@param value string
---@return string
local function lowerFirst(value)
    if value == "" then return value end

    return value:sub(1, 1):lower() .. value:sub(2)
end

---Derives the flat name a record getter reads from, or `nil` for getters that are not flat backed.
---@param func any ReflectionMemberFunc
---@return string?
local function flatNameFromGetter(func)
    local okParams, params = pcall(function () return func:GetParameters() end)
    if not okParams then return nil end
    if params ~= nil and #params > 0 then return nil end

    local okReturn, returnType = pcall(function () return func:GetReturnType() end)
    if not okReturn or returnType == nil then return nil end

    local okName, name = pcall(function () return func:GetName().value end)
    if not okName or type(name) ~= "string" then return nil end

    name = name:match("^[^;]+") or name
    if name == "" or name == "GetID" or name == "GetRecordID" then return nil end

    -- Record arrays only expose `GetXCount()` / `GetXItem(index)`, the flat behind them is `x`
    local arrayBase = name:match("^Get(.+)Count$")
    if arrayBase then return lowerFirst(arrayBase) end

    -- `XHandle()` duplicates `X()`, the remaining shapes take parameters and never map to a flat
    if name:match("Handle$") or name:match("Contains$") or name:match("^Get.+Item$") then return nil end

    return lowerFirst(name)
end

---Collects flat name candidates for a record class, including the ones inherited from parent records.
---@param className string
---@return string[]
local function getFlatNames(className)
    if flatNamesByClass[className] then
        return flatNamesByClass[className]
    end

    local names = {}
    local seen = {}

    local okClass, class = pcall(function () return Reflection.GetClass(className) end)
    local current = okClass and class or nil
    local depth = 0

    while current ~= nil and depth < MAX_PARENT_DEPTH do
        depth = depth + 1

        local okName, currentName = pcall(function () return current:GetName().value end)
        if not okName or currentName == "IScriptable" or currentName == "ISerializable" then break end

        local okFuncs, funcs = pcall(function () return current:GetFunctions() end)
        if okFuncs and funcs then
            for _, func in pairs(funcs) do
                local flatName = flatNameFromGetter(func)
                if flatName and not seen[flatName] then
                    seen[flatName] = true
                    table.insert(names, flatName)
                end
            end
        end

        local okParent, parent = pcall(function () return current:GetParent() end)
        current = okParent and parent or nil
    end

    table.sort(names)

    -- Only cache successful lookups, an empty result usually means reflection was not ready yet
    if #names > 0 then
        flatNamesByClass[className] = names
    end

    return names
end

---@param record any Record handle
---@return string?
local function getClassName(record)
    local okClass, className = pcall(function () return Reflection.GetClassOf(ToVariant(record), true):GetName().value end)
    if okClass and type(className) == "string" and className ~= "" then
        return className
    end

    local okName, name = pcall(function () return record:GetClassName().value end)
    if okName and type(name) == "string" and name ~= "" then
        return name
    end

    return nil
end

---@param value number
---@return string
local function formatNumber(value)
    if value ~= value then return "NaN" end
    if value == math.huge then return "inf" end
    if value == -math.huge then return "-inf" end

    if value % 1 == 0 and math.abs(value) < 1e15 then
        return string.format("%d", value)
    end

    local text = string.format("%.4f", value)
    text = text:gsub("0+$", "")
    text = text:gsub("%.$", "")

    return text
end

---@param value any Userdata value returned by `TweakDB:GetFlat`
---@return string
local function formatUserdata(value)
    local okText, text = pcall(function () return tostring(value) end)

    -- LocKeys stringify as `LocKey(1234ull)`, normalize them to the key format used everywhere else
    if okText and type(text) == "string" then
        local locKeyHash = text:match("^LocKey%((%d+)ull%)$")
        if locKeyHash then
            return "LocKey#" .. locKeyHash
        end
    end

    -- CName, TweakDBID and enums
    local okValue, named = pcall(function () return value.value end)
    if okValue and type(named) == "string" then
        return named ~= "" and named or "None"
    end

    local okVector, vector = pcall(function ()
        if type(value.x) == "number" and type(value.y) == "number" and type(value.z) == "number" then
            return string.format("%s, %s, %s", formatNumber(value.x), formatNumber(value.y), formatNumber(value.z))
        end

        return nil
    end)
    if okVector and vector then
        return vector
    end

    -- Resource references only carry their hash, CET resolves it back to the path when it is known
    local okHash, hash = pcall(function () return value.hash end)
    if okHash and hash then
        local okPath, path = pcall(function () return ResRef.FromHash(hash):ToString() end)
        if okPath and type(path) == "string" and path ~= "" then
            return path
        end

        local hashText = tostring(hash)
        if hashText == "0" or hashText == "0ULL" then
            return "None"
        end

        return hashText
    end

    if okText and type(text) == "string" then
        return text
    end

    return "?"
end

local formatValue

---Formats the entries of an array flat, capped at `MAX_ARRAY_ENTRIES`.
---@param value table Array flat
---@return string[] items
local function formatArrayItems(value)
    local count = #value

    local items = {}
    for index = 1, math.min(count, MAX_ARRAY_ENTRIES) do
        table.insert(items, formatValue(value[index]))
    end

    if count > MAX_ARRAY_ENTRIES then
        table.insert(items, string.format("... (+%d)", count - MAX_ARRAY_ENTRIES))
    end

    return items
end

---@param value table Array flat
---@return string
local function formatArray(value)
    local count = #value
    if count == 0 then
        return "[0]"
    end

    return string.format("[%d] %s", count, table.concat(formatArrayItems(value), ", "))
end

---@param value any Value returned by `TweakDB:GetFlat`
---@return string
function formatValue(value)
    local valueType = type(value)

    if value == nil then return "nil" end
    if valueType == "boolean" then return value and "true" or "false" end
    if valueType == "number" then return formatNumber(value) end
    if valueType == "string" then return value end
    if valueType == "table" then return formatArray(value) end

    return formatUserdata(value)
end

---Resolves a TweakDBID to a live record, without reading any of its data.
---@param id any Record ID, e.g. `GameplayRestriction.NoCombat`
---@return table? info `{ id: string, className: string }`, or `nil` when the ID is not a record
function tweakDbUtils.resolveRecord(id)
    if type(id) ~= "string" then return nil end

    id = utils.trimString(id)
    if id == "" then return nil end

    local cached = recordsByID[id]
    if cached ~= nil then
        return cached or nil
    end

    local info = false
    local okRecord, record = pcall(function () return TweakDB:GetRecord(id) end)
    if okRecord and record then
        local className = getClassName(record)
        if className then
            info = { id = id, className = className, flats = nil }
        end
    end

    if cachedRecords >= MAX_CACHED_RECORDS then
        recordsByID = {}
        cachedRecords = 0
    end

    recordsByID[id] = info
    cachedRecords = cachedRecords + 1

    return info or nil
end

---Reads every flat of a record. Results are cached per record ID.
---Array flats carry their entries in `items`, so they can be listed one per row instead of inline.
---@param id any Record ID
---@return table? flats Array of `{ name: string, text: string, raw: string, localized: string?, items: string[]? }`
function tweakDbUtils.getRecordFlats(id)
    local info = tweakDbUtils.resolveRecord(id)
    if not info then return nil end
    if info.flats then return info.flats end

    local flats = {}
    local flatNames = getFlatNames(info.className)

    for _, name in ipairs(flatNames) do
        local okFlat, value = pcall(function () return TweakDB:GetFlat(info.id .. "." .. name) end)

        if okFlat and value ~= nil then
            local raw = formatValue(value)
            local items = nil
            local text = raw

            if type(value) == "table" and #value > 0 then
                items = formatArrayItems(value)
                text = string.format("[%d]", #value)
            elseif #text > MAX_VALUE_LENGTH then
                text = text:sub(1, MAX_VALUE_LENGTH) .. "..."
            end

            local localized = nil
            if raw:match("^LocKey#") then
                localized = gameUtils.resolveLocKey(raw, locKeyCache)
            end

            table.insert(flats, { name = name, text = text, raw = raw, localized = localized, items = items })
        end
    end

    if #flatNames > 0 then
        info.flats = flats
    end

    return flats
end

return tweakDbUtils
