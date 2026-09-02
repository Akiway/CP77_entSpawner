local utils = require("modules/utils/core/utils")
local logger = require("modules/utils/core/logger")
local red = {}

--GetMod("entSpawner").e(Game.GetTargetingSystem():GetLookAtObject(Game.GetPlayer(), false, false):FindComponentByName("spotlight_lightsource"))
--GetMod("entSpawner").e(Game.GetTargetingSystem():GetLookAtObject(Game.GetPlayer(), false, false):FindComponentByName("Collider8411"))
-- print(FromVariant(Reflection.GetClassOf(ToVariant(FixedPoint.new())):GetProperty("Bits"):GetValue(ToVariant(Game.GetTargetingSystem():GetLookAtObject(Game.GetPlayer(), false, false):FindComponentByName("spotlight_lightsource").localTransform.Position.z))))
--GetMod("entSpawner").e(entColliderComponent.new( { colliders = { physicsColliderBox.new() } } ))
-- print(propType, prop:GetType():GetName().value, " | Name: ", prop:GetName().value, " | Value: ", propValue, " | Class: ", class:GetName().value, " | Value directly ", data[prop:GetName().value])
--GetMod("entSpawner").e(Game.FindEntityByID(entEntityID.new({hash=12264210ULL})):FindComponentByName("Light2103"))

--- EXPORT

--TODO: TweakDBID strings

local exportExludes = {
    "appearancePath",
    "meshResource",
    "worldTransform",
    "appearanceName",
    "blackboard",
    "stealthRunnerQuest",
    "betterNetrunningBreachedNPCs",
    "betterNetrunningBreachedCameras",
    "betterNetrunningBreachedTurrets",
    "betterNetrunningBreachedBasic"
}

-- If this handle is nil, generate a new instance for it
local handleIncludes = {
    "journalPath"
}

-- Same, but ONLY while converting an object the editor just constructed (`ctx.synthesizeNullHandles`).
-- These must never be synthesized into `defaultComponentData`: `entity:updatePropValue` deep-copies
-- the whole `persistentState` root out of the defaults the first time any property under it is
-- edited, so a handle invented here would ride along into `instanceDataChanges` and be applied to
-- the live device -- turning an unrelated edit into a silent change of what the game is told.
-- Only safe for properties whose declared inner type is concrete: constructing an abstract base
-- yields nothing the editor can fill in (see `nullHandlePickers` in entity.lua for those).
local synthesizedHandleIncludes = {
    -- Every `XOperationsTrigger` declares its own concrete `XOperationTriggerData`, so materialising
    -- by name is unambiguous. Only those 11 trigger classes declare a property called this.
    "triggerData"
}

local handleClassExcludes = {
    "gameIScriptableSystem",
    "gameIGameSystem"
}

local CONVERSION_MAX_DEPTH = 64
local CONVERSION_MAX_GUARD_WARNINGS = 10
local CONVERSION_LOG_PATH_SEGMENTS = 24

local function classIsA(class, typeName)
    local ok, isA = pcall(function ()
        return class and class:IsA(typeName)
    end)

    return ok and isA == true
end

local function getRedClass(data)
    local class = nil

    pcall(function ()
        class = Reflection.GetClassOf(ToVariant(data), true)
    end)

    return class
end

local function getConversionObjectKey(data, className)
    local ok, value = pcall(function ()
        return tostring(data)
    end)

    if ok and value then
        return tostring(className or "unknown") .. ":" .. value
    end

    return nil
end

local function getConversionPathSegment(key)
    if type(key) == "number" then
        return "[" .. tostring(key) .. "]"
    end

    return tostring(key)
end

local function pushConversionPath(ctx, key)
    if not ctx then return end

    ctx.path = ctx.path or {}
    table.insert(ctx.path, getConversionPathSegment(key))
end

local function popConversionPath(ctx)
    if not ctx or not ctx.path then return end

    table.remove(ctx.path)
end

local function getConversionPath(ctx)
    if not ctx or not ctx.path or #ctx.path == 0 then
        return "<root>"
    end

    local first = math.max(1, #ctx.path - CONVERSION_LOG_PATH_SEGMENTS + 1)
    local parts = {}

    for i = first, #ctx.path do
        table.insert(parts, ctx.path[i])
    end

    local path = table.concat(parts, ".")
    if first > 1 then
        return "... " .. path
    end

    return path
end

local function warnConversionGuard(ctx, message)
    if not ctx then
        logger:warn(message)
        return
    end

    ctx.guardWarnings = ctx.guardWarnings or {}
    ctx.guardWarningCount = ctx.guardWarningCount or 0
    ctx.maxGuardWarnings = ctx.maxGuardWarnings or CONVERSION_MAX_GUARD_WARNINGS

    local fullMessage = string.format("%s at %s", message, getConversionPath(ctx))
    if ctx.guardWarnings[fullMessage] then return end

    ctx.guardWarnings[fullMessage] = true

    if ctx.guardWarningCount < ctx.maxGuardWarnings then
        logger:warn(fullMessage)
    elseif ctx.guardWarningCount == ctx.maxGuardWarnings then
        logger:warn("[Red Converter] Additional conversion guard warnings suppressed")
    end

    ctx.guardWarningCount = ctx.guardWarningCount + 1
end

local function getActiveConversionClass(ctx, class)
    if not ctx or not ctx.classStack or not class then return nil end

    local okName, targetClassName = pcall(function ()
        return class:GetName().value
    end)

    if not okName or not targetClassName then return nil end

    for className, count in pairs(ctx.classStack) do
        if count and count > 0 then
            if classIsA(class, className) then
                return className
            end

            local activeClass = nil
            pcall(function ()
                activeClass = Reflection.GetClass(className)
            end)

            if classIsA(activeClass, targetClassName) then
                return className
            end
        end
    end

    return nil
end

local function isExcludedHandleClass(class)
    if not class then return false end

    for _, typeName in pairs(handleClassExcludes) do
        if classIsA(class, typeName) then
            return true
        end
    end

    return false
end

local bitFieldDefinitionCache = {}
local knownBitFieldDefinitions = {
    rendLightChannel = {
        order = {
            "LC_Channel1",
            "LC_Channel2",
            "LC_Channel3",
            "LC_Channel4",
            "LC_Channel5",
            "LC_Channel6",
            "LC_Channel7",
            "LC_Channel8",
            "LC_ChannelWorld",
            "LC_Character",
            "LC_Player",
            "LC_Automated"
        },
        values = {
            LC_Channel1 = 1,
            LC_Channel2 = 2,
            LC_Channel3 = 4,
            LC_Channel4 = 8,
            LC_Channel5 = 16,
            LC_Channel6 = 32,
            LC_Channel7 = 64,
            LC_Channel8 = 128,
            LC_ChannelWorld = 256,
            LC_Character = 512,
            LC_Player = 1024,
            LC_Automated = 32768
        }
    }
}

local function getBitFieldDefinition(propType)
    if bitFieldDefinitionCache[propType] ~= nil then
        return bitFieldDefinitionCache[propType] or nil
    end

    if knownBitFieldDefinitions[propType] then
        bitFieldDefinitionCache[propType] = knownBitFieldDefinitions[propType]
        return knownBitFieldDefinitions[propType]
    end

    local typeRef = nil

    if BitField and BitField.new then
        pcall(function ()
            typeRef = Reflection.GetTypeOf(ToVariant(BitField.new(propType, 0)))
        end)
    end

    if not typeRef then
        pcall(function ()
            typeRef = Reflection.GetTypeOf(ToVariant(Enum.new(propType, 0)))
        end)
    end

    local definition = {
        order = {},
        values = {}
    }

    if typeRef then
        local constants = nil
        pcall(function ()
            constants = typeRef:GetConstants()
        end)

        if constants then
            local entries = {}

            for _, constant in pairs(constants) do
                local name = constant:GetName().value
                local rawValue = tostring(constant:GetValue()):gsub("ULL", "")
                local value = tonumber(rawValue)

                if name and value and value > 0 then
                    table.insert(entries, {
                        name = name,
                        value = value
                    })
                end
            end

            table.sort(entries, function (a, b)
                return a.value < b.value
            end)

            for _, entry in ipairs(entries) do
                table.insert(definition.order, entry.name)
                definition.values[entry.name] = entry.value
            end
        end
    end

    if #definition.order == 0 then
        bitFieldDefinitionCache[propType] = false
        return nil
    end

    bitFieldDefinitionCache[propType] = definition

    return definition
end

---Parses a numeric string, stripping a trailing 64-bit integer literal suffix (e.g. "511ULL", "42LL")
---if a plain tonumber() fails, since CET's tostring() of bitfield/uint64 handles includes that suffix.
---@param str string
---@return number?
local function parseUnsignedLiteralNumber(str)
    local numeric = tonumber(str)
    if numeric then
        return numeric
    end

    return tonumber((str:gsub("[UuLl]+$", "")))
end

local function bitFieldMaskToString(propType, mask)
    if type(mask) ~= "number" then
        return nil
    end

    local normalizedMask = math.floor(mask)
    local definition = getBitFieldDefinition(propType)

    if not definition then
        return tostring(normalizedMask)
    end

    local names = {}

    for _, name in ipairs(definition.order) do
        local bitValue = definition.values[name]

        if bitValue and bitValue > 0 then
            local set = math.floor(normalizedMask / bitValue) % 2 == 1

            if set then
                table.insert(names, name)
            end
        end
    end

    if #names == 0 then
        return "0"
    end

    return table.concat(names, ",")
end

local function parseBitFieldMask(propType, value)
    if type(value) == "number" then
        return math.floor(value)
    end

    if type(value) ~= "string" then
        return nil
    end

    local normalized = utils.trimString(value)

    if normalized == "" or normalized == "0" then
        return 0
    end

    local numeric = parseUnsignedLiteralNumber(normalized)
    if numeric then
        return math.floor(numeric)
    end

    local definition = getBitFieldDefinition(propType)
    if not definition then
        return nil
    end

    local mask = 0
    local anyMatch = false
    local used = {}

    for token in normalized:gmatch("[^,]+") do
        local key = utils.trimString(token)
        local bitValue = definition.values[key]

        if bitValue and not used[key] then
            mask = mask + bitValue
            used[key] = true
            anyMatch = true
        end
    end

    if anyMatch then
        return mask
    end

    return nil
end

local function convertCName(propValue)
    if propValue then
        return {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = propValue.value
        }
    end
    return nil
end

local function convertFundamental(propValue, propClass)
    local propData = propValue
    if type(propValue) == "boolean" then
        propData = propValue and 1 or 0
    elseif propClass == "uint64" or propClass == "Uint64" then
        propData = tostring(propValue):gsub("ULL", "")
    end

    return propData
end

local function convertSimple(propValue, propClass, prop)
    local propData = tostring(propValue)

    if propClass == "LocalizationString" then
        propData = {
            ["unk1"] = "0",
            ["value"] = GameDump(propValue)
        }
    elseif propClass == "CRUID" then
        propData = tostring(CRUIDToHash(propValue)):gsub("ULL", "")
    elseif propClass == "TweakDBID" then
        if propValue then
            if propValue.value:match("<TDBID:") then
                local hash = propValue.value:match(":.*:"):gsub(":", "")
                local length = propValue.value:match(":..>"):gsub(":", ""):gsub(">", "")
                local hex = "0x" .. length .. hash

                propData = {
                    ["$type"] = "TweakDBID",
                    ["$storage"] = "uint64",
                    ["$value"] = tostring(tonumber(hex))
                }
            else
                propData = {
                    ["$type"] = "TweakDBID",
                    ["$storage"] = "string",
                    ["$value"] = propValue.value
                }
            end
        else
            propData = nil
        end
    elseif propClass == "NodeRef" then
        local hash = NodeRefToHash(propValue)
        if propValue then
            propData = {
                ["$type"] = "NodeRef",
                ["$storage"] = "uint64",
                ["$value"] = tostring(hash):gsub("ULL", "")
            }
        else
            propData = nil
        end
    elseif propClass == "String" then
        propData = propValue
    else
        logger:warn(string.format("[Red Converter] [%s] Unsupported simple type: %s", prop:GetName().value, propClass))
    end

    return propData
end

local function convertBitField(propValue, propType)
    if propValue == nil then
        return nil
    end

    if type(propValue) == "number" then
        return bitFieldMaskToString(propType, propValue)
    end

    if type(propValue) == "string" then
        local normalized = utils.trimString(propValue)

        if normalized == "" then
            return "0"
        end

        local numeric = parseUnsignedLiteralNumber(normalized)
        if numeric then
            return bitFieldMaskToString(propType, numeric)
        end

        return normalized
    end

    local okValue, directValue = pcall(function ()
        return propValue.value
    end)

    if okValue and directValue ~= nil then
        if type(directValue) == "number" then
            return bitFieldMaskToString(propType, directValue)
        end

        if type(directValue) == "string" then
            local normalized = utils.trimString(directValue)

            if normalized ~= "" then
                local numeric = parseUnsignedLiteralNumber(normalized)
                if numeric then
                    return bitFieldMaskToString(propType, numeric)
                end

                return normalized
            end
        end
    end

    local okString, asString = pcall(function ()
        return tostring(propValue)
    end)

    if okString and asString and asString ~= "" then
        local numeric = parseUnsignedLiteralNumber(asString)
        if numeric then
            return bitFieldMaskToString(propType, numeric)
        end

        return asString
    end

    return nil
end

local function convertArray(propValue, prop, ctx)
    if not prop:GetType():GetInnerType() then return end

    local propData = {}
    local innerType = prop:GetType():GetInnerType():GetMetaType()

    -- Sometimes (static?) arrays are userdata, e.g. https://nativedb.red4ext.com/c/1589593404660993 - vehicleDoors
    if type(propValue) ~= "table" then
        return propData
    end

    for index, entry in pairs(propValue) do
        pushConversionPath(ctx, index)
        local innerData = red.convertAny(innerType, prop:GetType():GetInnerType():GetName().value, entry, prop, propValue, ctx)
        popConversionPath(ctx)

        table.insert(propData, innerData)
    end

    return propData
end

---Construct an instance of a handle property's inner type, for a handle that is null.
---
---Deliberately NOT `ReflectionType:MakeInstance()`. That returns `Red::Variant{type}`, which
---default-constructs the object *owned by the Variant* with no `Handle<>` wrapper. For an
---`ISerializable` descendant -- which every device-operations class is -- the instance is freed when
---that Variant dies, so walking its properties afterwards reads freed memory: a native crash with no
---log line. CET's `NewObject` goes through `RTTIHelper::NewHandle`, which wraps `ISerializable`
---descendants in a real `Handle<>` and hands Lua an owning reference.
---@param prop ReflectionProp
---@return ISerializable?
local function makeHandleInstance(prop)
    local typeName = nil

    local ok = pcall(function ()
        typeName = prop:GetType():GetInnerType():GetName().value
    end)

    if not ok or type(typeName) ~= "string" or typeName == "" then
        return nil
    end

    local instance = nil
    local created = pcall(function ()
        instance = NewObject(typeName)
    end)

    if not created then
        return nil
    end

    return instance
end

local function convertHandle(propValue, prop, name, ctx)
    if propValue == nil then
        local synthesize = utils.has_value(handleIncludes, name)
            or (ctx and ctx.synthesizeNullHandles and utils.has_value(synthesizedHandleIncludes, name))

        if synthesize then
            propValue = makeHandleInstance(prop)
        end
    end
    if propValue ~= nil then
        local handleClass = getRedClass(propValue)
        if classIsA(handleClass, "entEntity") then -- Will very likely lead to infinite recursion
            return nil
        end

        if isExcludedHandleClass(handleClass) then
            return nil
        end

        local activeClassName = getActiveConversionClass(ctx, handleClass)
        if activeClassName then
            local okName, handleClassName = pcall(function ()
                return handleClass:GetName().value
            end)

            if not okName then
                handleClassName = "unknown"
            end

            warnConversionGuard(ctx, string.format("[Red Converter] Skipping recursive handle %s -> %s already active as %s", tostring(name), tostring(handleClassName), tostring(activeClassName)))
            return nil
        end

        pushConversionPath(ctx, "Data")
        local handleData = red.redDataToJSON(propValue, ctx)
        popConversionPath(ctx)

        if not handleData then return nil end

        return {
            HandleId = "0",
            Data = handleData
        }
    end

    return nil
end

local function convertResRef(data, key)
    local value = ""

    if data then
        if Reflection.GetClassOf(ToVariant(data)):IsA("ISerializable") then
            value = ResourceHelper.GetReferencePath(data, key):ToString()
        else
            return nil
        end
    end

    return {
        DepotPath = {
            ["$type"] = "ResourcePath",
            ["$storage"] = "string",
            ["$value"] = value
        },
        Flags = "Default"
    }
end

local function convertResRefAsync(propValue)
    local hash = propValue.hash

    local str = ""
    if hash then
        str = ResRef.FromHash(hash):ToString()
    end

    local storage = "string"

    if str == "" then
        return nil
    end

    return {
        DepotPath = {
            ["$type"] = "ResourcePath",
            ["$storage"] = storage,
            ["$value"] = str
        },
        Flags = "Default"
    }
end

---@private
---@param metaType ERTTIType
---@param propType string
---@param value ISerializable
---@param prop ReflectionProp
---@param data ISerializable Parent of value
---@param ctx table?
function red.convertAny(metaType, propType, value, prop, data, ctx)
    local propData = nil

    if metaType == ERTTIType.Name then
        propData = convertCName(value)
    elseif metaType == ERTTIType.Fundamental then
        propData = convertFundamental(value, propType)
    elseif metaType == ERTTIType.Class then
        propData = red.redDataToJSON(value, ctx)
    elseif metaType == ERTTIType.Simple then -- LocalizationString, Buffers, CRUID
        propData = convertSimple(value, propType, prop)
    elseif metaType == ERTTIType.Enum then
        propData = value.value
    elseif metaType == ERTTIType.BitField then
        propData = convertBitField(value, propType)
    elseif metaType == ERTTIType.Array or metaType == ERTTIType.StaticArray or metaType == ERTTIType.NativeArray or metaType == ERTTIType.FixedArray then
        propData = convertArray(value, prop, ctx)
    elseif metaType == ERTTIType.Handle or metaType == ERTTIType.WeakHandle then
        propData = convertHandle(value, prop, prop:GetName().value, ctx)
    elseif metaType == ERTTIType.ResourceReference then
        propData = convertResRef(data, prop:GetName().value)
    elseif metaType == ERTTIType.ResourceAsyncReference then
        propData = convertResRefAsync(value)
    else
        logger:warn(string.format("[Red Converter] [%s] Unsupported type: %s", prop:GetName().value, metaType))
    end

    return propData
end

---Converts a ISerializable instance to json data
---@param data ISerializable
---@param ctx table?
---@return table
function red.redDataToJSON(data, ctx)
    if not data then return nil end

    ctx = ctx or {}
    ctx.stack = ctx.stack or {}
    ctx.objectStack = ctx.objectStack or {}
    ctx.classStack = ctx.classStack or {}
    ctx.depth = ctx.depth or 0
    ctx.maxDepth = ctx.maxDepth or CONVERSION_MAX_DEPTH

    local root = getRedClass(data)

    if not root then return nil end

    local className = root:GetName().value
    local objectKey = getConversionObjectKey(data, className)

    if ctx.stack[data] or (objectKey and ctx.objectStack[objectKey]) then
        warnConversionGuard(ctx, string.format("[Red Converter] Skipping cyclic reference while converting %s", tostring(className)))
        return nil
    end

    if ctx.depth >= ctx.maxDepth then
        warnConversionGuard(ctx, string.format("[Red Converter] Max conversion depth reached (%d) while converting %s", ctx.maxDepth, tostring(className)))
        return nil
    end

    ctx.stack[data] = true
    if objectKey then
        ctx.objectStack[objectKey] = true
    end
    ctx.classStack[className] = (ctx.classStack[className] or 0) + 1
    ctx.depth = ctx.depth + 1

    local converted = {
        ["$type"] = className
    }

    local classes = {root}
    while root:GetParent() do
        root = root:GetParent()
        table.insert(classes, root)
    end

    for _, class in pairs(classes) do
        for _, prop in pairs(class:GetProperties()) do
            local propData = nil
            local propName = prop:GetName().value
            local metaType = prop:GetType():GetMetaType()
            local propType = prop:GetType():GetName().value
            local value = FromVariant(prop:GetValue(ToVariant(data)))

            if not utils.has_value(exportExludes, propName) then
                pushConversionPath(ctx, propName)
                propData = red.convertAny(metaType, propType, value, prop, data, ctx)
                popConversionPath(ctx)
            end

            if propData then
                converted[propName] = propData
            end
        end
    end

    ctx.depth = ctx.depth - 1
    ctx.classStack[className] = ctx.classStack[className] - 1
    if ctx.classStack[className] <= 0 then
        ctx.classStack[className] = nil
    end
    if objectKey then
        ctx.objectStack[objectKey] = nil
    end
    ctx.stack[data] = nil

    return converted
end

--- IMPORT

-- GetMod("entSpawner").i(entColliderComponent.new())
-- GetMod("entSpawner").i(Color.new())

local function importCName(value)
    CName.add(value["$value"])
    return value["$value"]
end

local function importFundamental(value, propType)
    local propData = nil

    if propType == "Bool" then
        propData = value == 1
    elseif propType == "uint64" or propType == "Uint64" then
        propData = loadstring("return " .. value .. "ULL", "")()
    else
        local succ = pcall(function()
            propData = value
        end)
        if not succ then
            propData = value
        end
    end

    return propData
end

local function importSimple(value, propType)
    local propData = nil

    if propType == "LocalizationString" then
        propData = ToLocalizationString(value["value"])
    elseif propType == "CRUID" then
        propData = CreateCRUID(loadstring("return " .. value .. "ULL", "")())
    elseif propType == "TweakDBID" then
        propData = TweakDBID.new(value["$value"])
    elseif propType == "NodeRef" then
        if value["$storage"] == "string" then
            propData = CreateNodeRef(value["$value"])
        else
            propData = HashToNodeRef(loadstring("return " .. value["$value"] .. "ULL", "")())
        end
    end

    return propData
end

local function importClass(value, propType)
    local propData = nil

    if propType == "Vector3" then
        propData = Vector3.new(value.X, value.Y, value.Z)
    elseif propType == "Vector4" then
        propData = Vector4.new(value.X, value.Y, value.Z, 0)
    elseif propType == "WorldPosition" then
        local pos = WorldPosition.new()
        pos:SetVector4(Vector4.new(value.x.Bits / 131072, value.y.Bits / 131072, value.z.Bits / 131072))
        propData = pos
    else
        propData = NewObject(propType)
        red.JSONToRedData(value, propData)
    end

    return propData
end

local function importEnum(value, propType, enumName)
    local propData = nil

    for _, enum in pairs(Reflection.GetTypeOf(ToVariant(Enum.new(propType, 0))):GetConstants()) do
        if enum:GetName().value == value then
            propData = Enum.new(enumName, tonumber(enum:GetValue()))
            break
        end
    end

    return propData
end

local function importBitField(value, propType)
    local rawValue = value

    if type(value) == "table" then
        rawValue = value["$value"] or value["Flags"] or value["value"] or value
    end

    local mask = parseBitFieldMask(propType, rawValue)
    if mask == nil then
        return nil
    end

    local propData = nil

    if BitField and BitField.new then
        local ok, result = pcall(function ()
            return BitField.new(propType, mask)
        end)

        if ok then
            propData = result
        end
    end

    if not propData then
        local ok, result = pcall(function ()
            return Enum.new(propType, mask)
        end)

        if ok then
            propData = result
        end
    end

    if not propData then
        propData = mask
    end

    return propData
end

local function importArray(value, data, key, prop)
    local propData = {}

    for index, entry in pairs(value) do
        local innerType = prop:GetType():GetInnerType()

        if type(entry) == "table" and entry.HandleId then
            entry = entry.Data
            innerType = innerType:GetInnerType()
        end

        local entryInstance
        if innerType:GetMetaType() == ERTTIType.Class then
            entryInstance = data[key][index] or NewObject(entry["$type"])
        end

        local propType = type(entry) == "table" and entry["$type"] or nil

        if not propType then
            propType = innerType:GetName().value
        end

        local entryData = red.importAny(innerType:GetMetaType(), propType, entry, nil, entryInstance, index)

        table.insert(propData, entryData)
    end

    return propData
end

local function importHandle(value, data, key)
    local propData = data[key] or NewObject(value.Data["$type"])
    red.JSONToRedData(value.Data, propData)
    return propData
end

local function importResourceRef(data, value, key)
    ResourceHelper.LoadReferenceResource(data, key, value["DepotPath"]["$value"], true)
end

local function importResourceRefAsync(value)
    if value["DepotPath"]["$storage"] == "string" then
        return ResRef.FromString(value["DepotPath"]["$value"])
    else
        return ResRef.FromHash(loadstring("return " .. value["DepotPath"]["$value"] .. "ULL", "")())
    end
end

---@private
---@param metaType ERTTIType
---@param propType string
---@param value table
---@param prop ReflectionProp
---@param data ISerializable Parent of value
---@param key string
---@return any
function red.importAny(metaType, propType, value, prop, data, key)
    local propData = nil

    if metaType == ERTTIType.Name then
        propData = importCName(value)
    elseif metaType == ERTTIType.Fundamental then
        propData = importFundamental(value, propType)
    elseif metaType == ERTTIType.Simple then
        propData = importSimple(value, propType)
    elseif metaType == ERTTIType.Class then
        propData = importClass(value, propType)
    elseif metaType == ERTTIType.Enum then
        propData = importEnum(value, propType, propType)
    elseif metaType == ERTTIType.BitField then
        propData = importBitField(value, propType)
    elseif metaType == ERTTIType.Array or metaType == ERTTIType.StaticArray or metaType == ERTTIType.NativeArray or metaType == ERTTIType.FixedArray then
        propData = importArray(value, data, key, prop)
    elseif metaType == ERTTIType.Handle or metaType == ERTTIType.WeakHandle then
        propData = importHandle(value, data, key)
    elseif metaType == ERTTIType.ResourceReference then
        propData = importResourceRef(data, value, key)
    elseif metaType == ERTTIType.ResourceAsyncReference then
        propData = importResourceRefAsync(value)
    else
        logger:warn("[Red Converter] Unsupported type: ", metaType)
    end

    return propData
end

function red.JSONToRedData(json, data)
    json["$type"] = nil

    for key, value in pairs(json) do
        local prop = Reflection.GetClassOf(ToVariant(data), true):GetProperty(key)
        local propType = prop:GetType():GetName().value
        local metaType = prop:GetType():GetMetaType()

        local propData = red.importAny(metaType, propType, value, prop, data, key)

        if propData then
            data[key] = propData
        end
    end
end

return red
