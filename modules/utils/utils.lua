local logger = require("modules/utils/logger")
local miscUtils = {
    data = {},
    archives = {}
}
local enumTableCache = {}
local nodeRefHashCache = {}
local bufferIdState = {
    nextId = 1
}

---@param str string
---@return table<string>
function miscUtils.split(str, sep)
    local result = {}
    for match in (str .. sep):gmatch("(.-)" .. sep) do
        table.insert(result, match)
    end
    return result
end

---Trims leading/trailing whitespace from any value converted to string.
---@param value any
---@return string
function miscUtils.trimString(value)
    local sanitized = tostring(value or "")
    sanitized = sanitized:gsub("^%s+", ""):gsub("%s+$", "")
    return sanitized
end

---Strips non-ASCII bytes from any value converted to string.
---@param value any
---@return string
function miscUtils.stripNonASCII(value)
    return tostring(value or ""):gsub("[\128-\255]", "")
end

---Normalizes free-form text for stable comparisons/storage (trim + ASCII-only).
---When fallback is provided, it is used if the normalized value is empty.
---@param value any
---@param fallback any?
---@return string
function miscUtils.sanitizeText(value, fallback)
    local sanitized = miscUtils.trimString(value)
    sanitized = miscUtils.stripNonASCII(sanitized)

    if sanitized == "" and fallback ~= nil then
        return miscUtils.sanitizeText(fallback)
    end

    return sanitized
end

---Normalizes a path-like string for comparisons and keys.
---@param path any
---@param options table? { separator: "backslash"|"slash", lowercase: boolean, asciiOnly: boolean, emptyAsNil: boolean }
---@return string|nil
function miscUtils.normalizePath(path, options)
    local opts = options or {}
    local normalized = miscUtils.trimString(path)

    if opts.separator == "backslash" then
        normalized = normalized:gsub("/", "\\")
    elseif opts.separator == "slash" then
        normalized = normalized:gsub("\\", "/")
    end

    if opts.asciiOnly then
        normalized = miscUtils.stripNonASCII(normalized)
    end

    if opts.lowercase then
        normalized = normalized:lower()
    end

    if opts.emptyAsNil and normalized == "" then
        return nil
    end

    return normalized
end

---@alias vec3Like { x: number, y: number, z: number }
---@alias vec4Like { x: number, y: number, z: number, w: number? }
---@alias eulerLike { roll: number, pitch: number, yaw: number }
---@alias axisAlignedBBox { min: vec3Like, max: vec3Like }

---Deep-copies a Lua value (including nested tables and metatables).
---@param origin any Value to clone.
---@return any copy
function miscUtils.deepcopy(origin)
	local orig_type = type(origin)
    local copy
    if orig_type == 'table' then
        copy = {}
        for origin_key, origin_value in next, origin, nil do
            copy[miscUtils.deepcopy(origin_key)] = miscUtils.deepcopy(origin_value)
        end
        setmetatable(copy, miscUtils.deepcopy(getmetatable(origin)))
    else
        copy = origin
    end
    return copy
end

---Returns the key of the first matching value in a table, or `-1` when not found.
---@param table table Table to search.
---@param value any Value to look for.
---@return integer|string keyOrMinusOne
function miscUtils.indexValue(table, value)
    local index={}
    for k,v in pairs(table) do
        index[v]=k
    end
    return index[value] or -1
end

---Returns whether an array-style table contains a value.
---@param tab table Sequence to inspect with `ipairs`.
---@param val any Value to check.
---@return boolean
function miscUtils.has_value(tab, val)
    for _, value in ipairs(tab) do
        if value == val then
            return true
        end
    end
    return false
end

---Returns whether a table contains a specific key.
---@param tab table Table to inspect.
---@param index any Key to check.
---@return boolean
function miscUtils.hasIndex(tab, index)
    for k, _ in pairs(tab) do
        if k == index then
            return true
        end
    end
    return false
end

---Counts the number of keys in a table.
---@param table table
---@return integer
function miscUtils.tableLength(table)
    local count = 0
    for _ in pairs(table) do count = count + 1 end
    return count
end

---Clears `locked` and `lockedByParent` flags recursively on serialized tree data.
---@param data table Serialized element/group table.
function miscUtils.clearLockStateRecursive(data)
    if type(data) ~= "table" then return end

    data.locked = false
    data.lockedByParent = false

    if data.childs then
        for _, child in pairs(data.childs) do
            miscUtils.clearLockStateRecursive(child)
        end
    end
end

---Removes the first matching value from an array-style table.
---@param tab table Sequence table.
---@param val any Value to remove.
function miscUtils.removeItem(tab, val)
    table.remove(tab, miscUtils.indexValue(tab, val))
end

---Adds two vectors component-wise.
---@param v1 vec4Like|Vector4
---@param v2 vec4Like|Vector4
---@return Vector4
function miscUtils.addVector(v1, v2)
    return Vector4.new(v1.x + v2.x, v1.y + v2.y, v1.z + v2.z, v1.w + v2.w)
end

---Subtracts `v2` from `v1` component-wise.
---@param v1 vec4Like|Vector4
---@param v2 vec4Like|Vector4
---@return Vector4
function miscUtils.subVector(v1, v2)
    return Vector4.new(v1.x - v2.x, v1.y - v2.y, v1.z - v2.z, v1.w - v2.w)
end

---Multiplies each vector component by a scalar.
---@param v1 vec4Like|Vector4
---@param factor number
---@return Vector4
function miscUtils.multVector(v1, factor)
    return Vector4.new(v1.x * factor, v1.y * factor, v1.z * factor, v1.w * factor)
end

---Multiplies two vectors component-wise.
---@param v1 vec4Like|Vector4
---@param v2 vec4Like|Vector4
---@return Vector4
function miscUtils.multVecXVec(v1, v2)
    return Vector4.new(v1.x * v2.x, v1.y * v2.y, v1.z * v2.z, v1.w * v2.w)
end

---Adds two Euler rotations component-wise.
---@param e1 eulerLike|EulerAngles
---@param e2 eulerLike|EulerAngles
---@return EulerAngles
function miscUtils.addEuler(e1, e2)
    return EulerAngles.new(e1.roll + e2.roll, e1.pitch + e2.pitch, e1.yaw + e2.yaw)
end

---Multiplies two quaternions (`a * b`), wrapping the verbose native operator call.
---@param a Quaternion
---@param b Quaternion
---@return Quaternion
function miscUtils.multQuat(a, b)
    return Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](a, b)
end

local SERIALIZED_SPAWNABLE_ELEMENT_PATH = "modules/classes/editor/spawnableElement"
local SERIALIZED_POSITIONABLE_GROUP_PATH = "modules/classes/editor/positionableGroup"
local SERIALIZED_RANDOMIZED_GROUP_PATH = "modules/classes/editor/randomizedGroup"

---Whether a serialized node (favorite/exported data) represents a single spawnable element.
---@param data table?
---@return boolean
function miscUtils.isSerializedSpawnable(data)
    return type(data) == "table"
        and (data.modulePath == SERIALIZED_SPAWNABLE_ELEMENT_PATH
            or data.type == "object"
            or data.type == "element"
            or data.spawnable ~= nil)
end

---Strict variant of `isSerializedSpawnable`: matches only explicit `type`/`modulePath` markers.
---Use this when classifying already-saved trees, where every node carries those markers;
---the lenient variant above also accepts payloads identified only by a `spawnable` field.
---@param data table?
---@return boolean
function miscUtils.isSerializedSpawnableStrict(data)
    return data and (data.modulePath == SERIALIZED_SPAWNABLE_ELEMENT_PATH
        or data.type == "object"
        or data.type == "element")
end

---Strict variant of `isSerializedGroup`: matches only explicit `type`/`modulePath` markers.
---The lenient variant below also treats any node carrying `childs` as a group.
---@param data table?
---@return boolean
function miscUtils.isSerializedGroupStrict(data)
    return data and (data.modulePath == SERIALIZED_POSITIONABLE_GROUP_PATH
        or data.modulePath == SERIALIZED_RANDOMIZED_GROUP_PATH
        or data.type == "group")
end

---Whether a serialized node (favorite/exported data) represents a group of elements.
---@param data table?
---@return boolean
function miscUtils.isSerializedGroup(data)
    if type(data) ~= "table" then
        return false
    end

    if data.modulePath == SERIALIZED_POSITIONABLE_GROUP_PATH
        or data.modulePath == SERIALIZED_RANDOMIZED_GROUP_PATH
        or data.type == "group" then
        return true
    end

    return data.childs ~= nil and not miscUtils.isSerializedSpawnable(data)
end

---Subtracts `e2` from `e1` component-wise.
---@param e1 eulerLike|EulerAngles
---@param e2 eulerLike|EulerAngles
---@return EulerAngles
function miscUtils.subEuler(e1, e2)
    return EulerAngles.new(e1.roll - e2.roll, e1.pitch - e2.pitch, e1.yaw - e2.yaw)
end

---Multiplies each Euler component by a scalar.
---@param e1 eulerLike|EulerAngles
---@param factor number
---@return EulerAngles
function miscUtils.multEuler(e1, factor)
    return EulerAngles.new(e1.roll * factor, e1.pitch * factor, e1.yaw * factor)
end

---Converts a `Vector4` into a serializable plain table.
---@param vector vec4Like|Vector4
---@return vec4Like
function miscUtils.fromVector(vector)
    return {x = vector.x, y = vector.y, z = vector.z, w = vector.w}
end

---Converts a `Quaternion` into a serializable plain table.
---@param quat Quaternion
---@return {i: number, j: number, k: number, r: number}
function miscUtils.fromQuaternion(quat)
    return {i = quat.i, j = quat.j, k = quat.k, r = quat.r}
end

---Builds a `Vector4` from a plain table.
---@param tab vec4Like
---@return Vector4
function miscUtils.getVector(tab)
    return(Vector4.new(tab.x, tab.y, tab.z, tab.w))
end

---Builds a `Quaternion` from a plain table.
---@param tab {i: number, j: number, k: number, r: number}
---@return Quaternion
function miscUtils.getQuaternion(tab)
    return(Quaternion.new(tab.i, tab.j, tab.k, tab.r))
end

---Converts `EulerAngles` into a serializable plain table.
---@param eul eulerLike|EulerAngles
---@return eulerLike
function miscUtils.fromEuler(eul)
    return {roll = eul.roll, pitch = eul.pitch, yaw = eul.yaw}
end

---Builds `EulerAngles` from a plain table.
---@param tab eulerLike
---@return EulerAngles
function miscUtils.getEuler(tab)
    return(EulerAngles.new(tab.roll, tab.pitch, tab.yaw))
end

---Returns Euclidean distance between two 3D points (`x/y/z`).
---@param from vec3Like|vec4Like|Vector4
---@param to vec3Like|vec4Like|Vector4
---@return number
function miscUtils.distanceVector(from, to)
    return math.sqrt((to.x - from.x)^2 + (to.y - from.y)^2 + (to.z - from.z)^2)
end

---Sanitizes text so it can be safely used as a file name.
---@param name string
---@return string
function miscUtils.createFileName(name)
    name = name:gsub("<", "_")
    name = name:gsub(">", "_")
    name = name:gsub(":", "_")
    name = name:gsub("\"", "_")
    name = name:gsub("/", "_")
    name = name:gsub("\\", "_")
    name = name:gsub("|", "_")
    name = name:gsub("?", "_")
    name = name:gsub("*", "_")
    name = name:gsub("'", "_")
    name = name:gsub(" ", "_")

    return name
end

---Rotates a vector around the roll/X axis by degrees.
---@param vec vec4Like|Vector4
---@param deg number Degrees.
---@return Vector4
function miscUtils.rotateRoll(vec, deg)
    local deg = math.rad(deg)

    local row1 = Vector3.new(1, 0, 0)
    local row2 = Vector3.new(0, math.cos(deg), -math.sin(deg))
    local row3 = Vector3.new(0, math.sin(deg), math.cos(deg))

    local rotated = Vector4.new(0, 0, 0, 0)

    rotated.x = row1.x * vec.x + row1.y * vec.y + row1.z * vec.z
    rotated.y = row2.x * vec.x + row2.y * vec.y + row2.z * vec.z
    rotated.z = row3.x * vec.x + row3.y * vec.y + row3.z * vec.z

    return rotated
end

---Rotates a vector around the pitch/Y axis by degrees.
---@param vec vec4Like|Vector4
---@param deg number Degrees.
---@return Vector4
function miscUtils.rotatePitch(vec, deg)
    local deg = math.rad(deg)

    local row1 = Vector3.new(math.cos(deg), 0, math.sin(deg))
    local row2 = Vector3.new(0, 1, 0)
    local row3 = Vector3.new(-math.sin(deg), 0, math.cos(deg))

    local rotated = Vector4.new(0, 0, 0, 0)

    rotated.x = row1.x * vec.x + row1.y * vec.y + row1.z * vec.z
    rotated.y = row2.x * vec.x + row2.y * vec.y + row2.z * vec.z
    rotated.z = row3.x * vec.x + row3.y * vec.y + row3.z * vec.z

    return rotated
end

---Applies yaw/pitch/roll rotation to a vector.
---@param vec vec4Like|Vector4
---@param rot eulerLike|EulerAngles
---@return Vector4
function miscUtils.rotatePoint(vec, rot)
    local yaw = math.rad(rot.yaw) -- α
    local pitch = math.rad(rot.pitch) -- β
    local roll = math.rad(rot.roll) -- γ

    local r1_1 = math.cos(yaw) * math.cos(pitch)
    local r1_2 = (math.cos(yaw) * math.sin(pitch) * math.sin(roll)) - (math.sin(yaw) * math.cos(roll))
    local r1_3 = (math.cos(yaw) * math.sin(pitch) * math.cos(roll)) + (math.sin(yaw) * math.sin(roll))

    local r2_1 = math.sin(yaw) * math.cos(pitch)
    local r2_2 = (math.sin(yaw) * math.sin(pitch) * math.sin(roll)) + (math.cos(yaw) * math.cos(roll))
    local r2_3 = (math.sin(yaw) * math.sin(pitch) * math.cos(roll)) - (math.cos(yaw) * math.sin(roll))

    local r3_1 = -math.sin(pitch)
    local r3_2 = math.cos(pitch) * math.sin(roll)
    local r3_3 = math.cos(pitch) * math.cos(roll)

    local row1 = Vector3.new(r1_1, r1_2, r1_3)
    local row2 = Vector3.new(r2_1, r2_2, r2_3)
    local row3 = Vector3.new(r3_1, r3_2, r3_3)

    local rotated = Vector4.new(0, 0, 0, 0)

    rotated.x = row1.x * vec.x + row1.y * vec.y + row1.z * vec.z
    rotated.y = row2.x * vec.x + row2.y * vec.y + row2.z * vec.z
    rotated.z = row3.x * vec.x + row3.y * vec.y + row3.z * vec.z

    return rotated
end

---Computes axis-aligned min/max points for a list of vectors.
---@param vectors (vec4Like|Vector4)[]
---@return Vector4 min
---@return Vector4 max
function miscUtils.getVector4BBox(vectors)
    local minX = 9999999999
    local minY = 9999999999
    local minZ = 9999999999
    local maxX = -9999999999
    local maxY = -9999999999
    local maxZ = -9999999999

    for _, vector in ipairs(vectors) do
        if vector.x < minX then
            minX = vector.x
        end
        if vector.y < minY then
            minY = vector.y
        end
        if vector.z < minZ then
            minZ = vector.z
        end
        if vector.x > maxX then
            maxX = vector.x
        end
        if vector.y > maxY then
            maxY = vector.y
        end
        if vector.z > maxZ then
            maxZ = vector.z
        end
    end

    if #vectors == 0 then
        return Vector4.new(0, 0, 0, 0), Vector4.new(0, 0, 0, 0)
    end

    return Vector4.new(minX, minY, minZ, 0), Vector4.new(maxX, maxY, maxZ, 0)
end

---Returns scaled box dimensions from an AABB and scale.
---@param box axisAlignedBBox?
---@param scale vec3Like?
---@return vec3Like
function miscUtils.getBoxSize(box, scale)
    local safeBox = box or { min = { x = -0.5, y = -0.5, z = -0.5 }, max = { x = 0.5, y = 0.5, z = 0.5 } }
    local safeScale = scale or { x = 1, y = 1, z = 1 }

    return {
        x = (safeBox.max.x - safeBox.min.x) * math.abs(safeScale.x or 1),
        y = (safeBox.max.y - safeBox.min.y) * math.abs(safeScale.y or 1),
        z = (safeBox.max.z - safeBox.min.z) * math.abs(safeScale.z or 1)
    }
end

---Applies absolute scale to an AABB.
---@param box axisAlignedBBox?
---@param scale vec3Like?
---@return axisAlignedBBox
function miscUtils.getScaledBBox(box, scale)
    local safeBox = box or { min = { x = -0.5, y = -0.5, z = -0.5 }, max = { x = 0.5, y = 0.5, z = 0.5 } }
    local safeScale = scale or { x = 1, y = 1, z = 1 }

    return {
        min = {
            x = safeBox.min.x * math.abs(safeScale.x or 1),
            y = safeBox.min.y * math.abs(safeScale.y or 1),
            z = safeBox.min.z * math.abs(safeScale.z or 1)
        },
        max = {
            x = safeBox.max.x * math.abs(safeScale.x or 1),
            y = safeBox.max.y * math.abs(safeScale.y or 1),
            z = safeBox.max.z * math.abs(safeScale.z or 1)
        }
    }
end

---Applies scale and additional per-axis factor to an AABB.
---@param box axisAlignedBBox?
---@param scale vec3Like?
---@param scaleFactor vec3Like?
---@return axisAlignedBBox
function miscUtils.getScaledBBoxWithFactor(box, scale, scaleFactor)
    local scaledBBox = miscUtils.getScaledBBox(box, scale)
    local factor = scaleFactor or { x = 1, y = 1, z = 1 }

    scaledBBox.min.x = scaledBBox.min.x * (factor.x or 1)
    scaledBBox.min.y = scaledBBox.min.y * (factor.y or 1)
    scaledBBox.min.z = scaledBBox.min.z * (factor.z or 1)
    scaledBBox.max.x = scaledBBox.max.x * (factor.x or 1)
    scaledBBox.max.y = scaledBBox.max.y * (factor.y or 1)
    scaledBBox.max.z = scaledBBox.max.z * (factor.z or 1)

    return scaledBBox
end

---Returns the world-space center of a local AABB.
---@param box axisAlignedBBox?
---@param scale vec3Like?
---@param rotation EulerAngles
---@param position vec4Like|Vector4
---@return Vector4
function miscUtils.getBoxCenter(box, scale, rotation, position)
    local safeBox = box or { min = { x = -0.5, y = -0.5, z = -0.5 }, max = { x = 0.5, y = 0.5, z = 0.5 } }
    local safeScale = scale or { x = 1, y = 1, z = 1 }
    local size = miscUtils.getBoxSize(safeBox, safeScale)
    local offset = Vector4.new(
        (safeBox.min.x * (safeScale.x or 1)) + size.x / 2,
        (safeBox.min.y * (safeScale.y or 1)) + size.y / 2,
        (safeBox.min.z * (safeScale.z or 1)) + size.z / 2,
        0
    )
    offset = rotation:ToQuat():Transform(offset)

    return Vector4.new(
        position.x + offset.x,
        position.y + offset.y,
        position.z + offset.z,
        0
    )
end

---Applies relative Euler delta using quaternion multiplication.
---@param current EulerAngles
---@param delta eulerLike Rotation delta in degrees.
---@return EulerAngles
function miscUtils.addEulerRelative(current, delta)
    local result = miscUtils.multQuat(current:ToQuat(), Quaternion.SetAxisAngle(Vector4.new(0, 1, 0, 0), Deg2Rad(delta.roll)))
    result = miscUtils.multQuat(result, Quaternion.SetAxisAngle(Vector4.new(1, 0, 0, 0), Deg2Rad(delta.pitch)))
    result = miscUtils.multQuat(result, Quaternion.SetAxisAngle(Vector4.new(0, 0, 1, 0), Deg2Rad(delta.yaw)))

    return result:ToEulerAngles()
end

---Builds and caches the display-name list of a RED enum.
---@param enumName string RED enum type name.
---@return string[]
function miscUtils.enumTable(enumName)
    local cached = enumTableCache[enumName]
    if cached then
        return cached
    end

    local enums = {}

    for i = -25, tonumber(EnumGetMax(enumName)) do
        local name = EnumValueToString(enumName, i)
        if name ~= "" then
            table.insert(enums, name)
        end
    end

    enumTableCache[enumName] = enums
    return enums
end

---Generates an incremented copy name (`Name` -> `Name_1`, `Name1` -> `Name2`).
---@param name string
---@return string
function miscUtils.generateCopyName(name)
    local num = name:match("%d*$")

    if #num ~= 0 then
        return name:sub(1, -#num - 1) .. tostring(tonumber(num) + 1)
    else
        return name .. "_1"
    end
end

---Extracts filename stem from a path; leaves non-path record IDs unchanged.
---@param path string
---@return string
function miscUtils.getFileName(path)
    -- Only strip extension when this is an actual path.
    -- Record IDs (e.g. Character.xxx) are dot-separated but have no path separators.
    if string.match(path, "[/\\]") then
        return path:match("([^/\\]+)%..*$") or path:match("([^/\\]+)$") or path
    end

    return path
end

---Appends values from `data` into array `target` (using `pairs` + `table.insert`).
---@param target table
---@param data table
---@return table target
function miscUtils.combine(target, data)
    for _, v in pairs(data) do
        table.insert(target, v)
    end

    return target
end

---Copies key/value pairs from `data` into `target`.
---@param target table
---@param data table
---@return table target
function miscUtils.combineHashTable(target, data)
    for k, v in pairs(data) do
        target[k] = v
    end

    return target
end

---Returns whether `object.class` contains the provided class name.
---@param object { class: string[] }
---@param class string
---@return boolean
function miscUtils.isA(object, class)
    return miscUtils.has_value(object.class, class)
end

---Sets a nested value by key path.
---@param tbl table Root table.
---@param keys (string|number)[] Path of keys.
---@param data any Value to assign at the final key.
---@return nil
function miscUtils.setNestedValue(tbl, keys, data)
    local value = tbl
    for i, key in ipairs(keys) do
        if i == #keys then
            value[key] = data
            return
        else
            value = value[key]
        end
    end
end

---Gets a nested value by key path, returning `nil` when any segment is missing.
---@param tbl table Root table.
---@param keys (string|number)[] Path of keys.
---@return any
function miscUtils.getNestedValue(tbl, keys)
    local value = tbl
    for _, key in ipairs(keys) do
        if value[key] == nil then
            return nil
        end
        value = value[key]
    end
    return value
end

--https://web.archive.org/web/20131225070434/http://snippets.luacode.org/snippets/Deep_Comparison_of_Two_Values_3
---Recursively compares two values/tables for deep equality.
---@param t1 any
---@param t2 any
---@param ignore_mt boolean? Ignore `__eq` metamethod when true.
---@return boolean
function miscUtils.deepcompare(t1,t2,ignore_mt)
    local ty1 = type(t1)
    local ty2 = type(t2)
    if ty1 ~= ty2 then return false end
    -- non-table types can be directly compared
    if ty1 ~= 'table' and ty2 ~= 'table' then return t1 == t2 end
    -- as well as tables which have the metamethod __eq
    local mt = getmetatable(t1)
    if not ignore_mt and mt and mt.__eq then return t1 == t2 end
    for k1,v1 in pairs(t1) do
        local v2 = t2[k1]
        if v2 == nil or not miscUtils.deepcompare(v1,v2) then return false end
    end
    for k2,v2 in pairs(t2) do
        local v1 = t1[k2]
        if v1 == nil or not miscUtils.deepcompare(v1,v2) then return false end
    end
    return true
end

--https://web.archive.org/web/20131225070434/http://snippets.luacode.org/snippets/Deep_Comparison_of_Two_Values_3
---Deep-compare variant that ignores mismatches for excluded top-level keys.
---@param t1 any
---@param t2 any
---@param ignore_mt boolean? Ignore `__eq` metamethod when true.
---@param exclusions (string|number)[] Keys to ignore when values differ.
---@return boolean
function miscUtils.deepcompareExclusions(t1,t2,ignore_mt,exclusions)
    local ty1 = type(t1)
    local ty2 = type(t2)
    if ty1 ~= ty2 then return false end
    -- non-table types can be directly compared
    if ty1 ~= 'table' and ty2 ~= 'table' then return t1 == t2 end
    -- as well as tables which have the metamethod __eq
    local mt = getmetatable(t1)
    if not ignore_mt and mt and mt.__eq then return t1 == t2 end
    for k1,v1 in pairs(t1) do
        local v2 = t2[k1]
        if v2 == nil or (not miscUtils.deepcompare(v1,v2) and not miscUtils.has_value(exclusions, k1)) then
            return false
        end
    end
    for k2,v2 in pairs(t2) do
        local v1 = t1[k2]
        if v1 == nil or (not miscUtils.deepcompare(v1,v2) and not miscUtils.has_value(exclusions, k2)) then
            return false
        end
    end
    return true
end

---Returns whether two favorite payloads are merge-compatible.
---@param a table
---@param b table
---@return boolean
function miscUtils.canMergeFavorites(a, b)
    local exclusions = {
		"name",
		"hiddenByParent",
		"propertyHeaderStates",
		"visible",
		"rotationRelative",
		"scaleLocked",
		"baseTransform",
		"transformExpanded",
		"primaryRange",
		"secondaryRange",
		"position",
		"pos",
		"selected",
		"headerOpen"
	}

    return miscUtils.deepcompareExclusions(a, b, false, exclusions)
end

---Queues a highlight-outline event on an entity.
---@param entity entEntity?
---@param color integer Outline index.
---@return nil
function miscUtils.sendOutlineEvent(entity, color)
    if not entity then return end

    entity:QueueEvent(entRenderHighlightEvent.new({
        seeThroughWalls = true,
        outlineIndex = color,
        opacity = 1
    }))
end

---Returns the maximum rendered width among the provided text labels.
---@param texts string[]
---@return number
function miscUtils.getTextMaxWidth(texts)
    local max = 0

    for _, text in ipairs(texts) do
        local x, _ = ImGui.CalcTextSize(text)
        max = math.max(max, x)
    end

    return max
end

---Recursively collects class names derived from a RED base class.
---@param base string Base class name.
---@return string[]
function miscUtils.getDerivedClasses(base)
    local classes = { base }

    for _, derived in pairs(Reflection.GetDerivedClasses(base)) do
        if derived:GetName().value ~= base then
            for _, class in pairs(miscUtils.getDerivedClasses(derived:GetName().value)) do
                table.insert(classes, class)
            end
        end
    end

    return classes
end

---Converts node-ref text/number into a normalized FNV1a64 hash string.
---@param data string|number
---@return string Hash without `#` or `ULL` suffix.
function miscUtils.nodeRefStringToHashString(data)
    if not data then
        return ""
    end

    local cached = nodeRefHashCache[data]
    if cached then
        return cached
    end

    local normalized, _ = tostring(data):gsub("#", "")
    local hash, _ = tostring(FNV1a64(normalized)):gsub("ULL", "")
    nodeRefHashCache[data] = hash

    return hash
end

---Resets the sequential export buffer-id counter.
---@return nil
function miscUtils.resetExportBufferIds()
    bufferIdState.nextId = 1
end

---Generates the next deterministic hash-based export buffer id.
---@param prefix string? Prefix namespace used in hash input.
---@return string
function miscUtils.nextExportBufferId(prefix)
    local label = prefix or "BufferId"
    local nextId = bufferIdState.nextId
    bufferIdState.nextId = bufferIdState.nextId + 1

    local hashInput = label .. ":" .. tostring(nextId)
    local candidate, _ = tostring(FNV1a64(hashInput)):gsub("ULL", "")
    return candidate
end

---Stores a value in the module-local clipboard table.
---@param key string|number
---@param data any
---@return nil
function miscUtils.insertClipboardValue(key, data)
    miscUtils.data[key] = data
end

---Reads a value from the module-local clipboard table.
---@param key string|number
---@return any
function miscUtils.getClipboardValue(key)
    return miscUtils.data[key]
end

--https://stackoverflow.com/questions/18886447/convert-signed-ieee-754-float-to-hexadecimal-representation
--https://stackoverflow.com/questions/72783502/how-does-one-reverse-the-items-in-a-table-in-lua
---Converts a Lua number to little-endian IEEE754 float32 hex.
---@param n number
---@return string
function miscUtils.floatToHex(n)
    if n == 0.0 then return "00000000" end

    local sign = 0
    if n < 0.0 then
        sign = 0x80
        n = -n
    end

    local mant, expo = math.frexp(n)
    local hext = {}

    if mant ~= mant then
        hext[#hext+1] = string.char(0xFF, 0x88, 0x00, 0x00)

    elseif mant == math.huge or expo > 0x80 then
        if sign == 0 then
            hext[#hext+1] = string.char(0x7F, 0x80, 0x00, 0x00)
        else
            hext[#hext+1] = string.char(0xFF, 0x80, 0x00, 0x00)
        end

    elseif (mant == 0.0 and expo == 0) or expo < -0x7E then
        hext[#hext+1] = string.char(sign, 0x00, 0x00, 0x00)

    else
        expo = expo + 0x7E
        mant = (mant * 2.0 - 1.0) * math.ldexp(0.5, 24)
        hext[#hext+1] = string.char(sign + math.floor(expo / 0x2),
                                    (expo % 0x2) * 0x80 + math.floor(mant / 0x10000),
                                    math.floor(mant / 0x100) % 0x100,
                                    mant % 0x100)
    end

    local str = string.gsub(table.concat(hext),"(.)", function (c) return string.format("%02X%s",string.byte(c),"") end)
    local reversed = ""

    for i = 1, #str, 2 do
        reversed = str:sub(i, i + 1) .. reversed
    end

    if #reversed < 8 then
        reversed = reversed .. string.rep("0", 8 - #reversed)
    end

    return reversed
end

--https://stackoverflow.com/questions/18886447/convert-signed-ieee-754-float-to-hexadecimal-representation
---Converts an integer to hexadecimal (minimum 2 chars).
---@param IN integer
---@return string
function miscUtils.intToHex(IN)
    local B,K,OUT,I,D=16,"0123456789ABCDEF","",0
    while IN>0 do
        I=I+1
        IN,D=math.floor(IN/B),(IN % B)+1
        OUT=string.sub(K,D,D)..OUT
    end

    if OUT == "" then
        OUT = "00"
    end

    if #OUT == 1 then
        OUT = "0" .. OUT
    end

    return OUT
end

---Converts a hex string payload into Base64.
---@param hex string Hexadecimal string with even length.
---@return string
function miscUtils.hexToBase64(hex)
    -- Convert hex string to binary data
    local binary = hex:gsub('..', function(byte)
        return string.char(tonumber(byte, 16))
    end)

    -- Base64 character set
    local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local b64 = {}
    local padding = #binary % 3 -- Determine the padding needed

    -- Encode binary to base64 without bitwise operations
    ---Converts up to three bytes into four base64 table indices.
    ---@param bytes integer[]
    ---@return integer[]
    local function toBase64Index(bytes)
        local a = bytes[1] or 0
        local b = bytes[2] or 0
        local c = bytes[3] or 0

        -- Calculate the base64 indices manually
        local i1 = math.floor(a / 4)
        local i2 = (a % 4) * 16 + math.floor(b / 16)
        local i3 = (b % 16) * 4 + math.floor(c / 64)
        local i4 = c % 64

        return {i1, i2, i3, i4}
    end

    for i = 1, #binary, 3 do
        local bytes = {binary:byte(i, i + 2)}
        local indices = toBase64Index(bytes)

        for j = 1, 4 do
            table.insert(b64, b64chars:sub(indices[j] + 1, indices[j] + 1))
        end
    end

    -- Add padding if needed
    for _ = 1, (3 - padding) % 3 do
        b64[#b64] = '='
    end

    return table.concat(b64)
end

---Returns a list containing all keys from a table.
---@param tab table
---@return table
function miscUtils.getKeys(tab)
    local keys = {}

    for k, _ in pairs(tab) do
        table.insert(keys, k)
    end

    return keys
end

---Removes keys from a selection map that are absent from the available key set.
---Used by every multi-select filter to drop options that no longer exist.
---@param selections table<string, boolean>?
---@param availableKeys table<string, boolean>? Set of still-valid keys.
---@return boolean changed
function miscUtils.pruneKeys(selections, availableKeys)
    if not selections then
        return false
    end

    availableKeys = availableKeys or {}
    local changed = false

    for key, _ in pairs(selections) do
        if not availableKeys[key] then
            selections[key] = nil
            changed = true
        end
    end

    return changed
end

---Builds a set from a list of keys, for use with `miscUtils.pruneKeys`.
---@param list any[]?
---@return table<string, boolean>
function miscUtils.toKeySet(list)
    local set = {}

    for _, value in ipairs(list or {}) do
        set[tostring(value)] = true
    end

    return set
end

---Creates a debounced-save pair for a settings field edited by typing.
---`schedule` coalesces rapid edits into one write, `flush` writes immediately.
---@param delay number? Debounce delay in seconds (default `0.35`).
---@param save fun()? Save function (defaults to `settings.save`).
---@return fun() schedule
---@return fun() flush
function miscUtils.makeDebouncedSave(delay, save)
    local Cron = require("modules/utils/Cron")
    local timer = nil

    delay = delay or 0.35
    save = save or function ()
        require("modules/utils/settings").save()
    end

    local function halt()
        if timer then
            Cron.Halt(timer)
            timer = nil
        end
    end

    return function ()
        halt()
        timer = Cron.After(delay, function ()
            timer = nil
            save()
        end)
    end, function ()
        halt()
        save()
    end
end

---Shortens a path to fit UI width by trimming leading segments and prefixing `...`.
---@param path string
---@param width number Maximum allowed rendered width.
---@param backwardsSlash boolean? Use backslash separators when true.
---@return string
function miscUtils.shortenPath(path, width, backwardsSlash)
    if ImGui.CalcTextSize(path) <= width then return path end

    local pattern = backwardsSlash and "^\\?[^\\]*" or "^%/?[^%/]*"
    local dotsWidth = ImGui.CalcTextSize("...")
    while ImGui.CalcTextSize(path) + dotsWidth > width do
        local stripped = path:gsub(pattern, "")
        if #stripped == 0 then
            break
        end
        path = stripped
    end

    while ImGui.CalcTextSize(path) + dotsWidth > width and #path > 0 do
        path = path:sub(2, #path)
    end

    return "..." .. path
end

---Builds a comma-separated bitfield enum string from boolean channel toggles.
---@param bitTable boolean[]
---@param bitTableNames string[]
---@return string
function miscUtils.buildBitfieldString(bitTable, bitTableNames)
    local bitfieldString = ""

    for i, channel in ipairs(bitTable) do
        if channel then
            bitfieldString = bitfieldString .. bitTableNames[i] .. ","
        end
    end

    if bitfieldString ~= "" then
        bitfieldString = bitfieldString:sub(1, -2)
    else
        bitfieldString = "0"
    end

    return bitfieldString
end

---Matches search query against text.
---Supports direct Lua-pattern match, and token operators: `|` (OR), `&` (AND), `!` (NOT).
---When the provided pattern is malformed, falls back to plain-text substring search.
---@param text string
---@param pattern string?
---@return boolean
function miscUtils.safePatternMatch(text, pattern)
    if not pattern or pattern == "" then
        return true
    end

    local ok, matched = pcall(function ()
        return text:match(pattern)
    end)
    if ok then
        return matched ~= nil
    end

    return text:find(pattern, 1, true) ~= nil
end

---Matches search query against text.
---Supports direct Lua-pattern match, and token operators: `|` (OR), `&` (AND), `!` (NOT).
---@param text string
---@param query string?
---@return boolean
function miscUtils.matchSearch(text, query)
    if not query or query == "" then
        return true
    end

    text = text:lower()
    query = query:lower()

    if miscUtils.safePatternMatch(text, query) then
        return true
    end

    local anyMatch = false
    local word = ""
    local operation = "|"

    for i = 1, #query + 1 do
        local char = i <= #query and query:sub(i, i) or operation

        if char == "|" or char == "!" or char == "&" then
            if operation == "|" then
                if not anyMatch and word ~= "" and miscUtils.safePatternMatch(text, word) then
                    anyMatch = true
                end
            elseif operation == "&" then
                if word ~= "" and not miscUtils.safePatternMatch(text, word) then
                    return false
                end
            else
                if word ~= "" and miscUtils.safePatternMatch(text, word) then
                    return false
                end
            end

            word = ""
            operation = char
        else
            word = word .. char
        end
    end

    return anyMatch
end

function miscUtils.archiveInstalled(name)
    if not miscUtils.archives[name] then
        miscUtils.archives[name] = ModArchiveExists(name)
    end

    return miscUtils.archives[name]
end

---@param value any
---@param search string
---@return boolean
function miscUtils.matchesInstanceDataSearch(value, search)
    return string.find(string.lower(tostring(value or "")), search, 1, true) ~= nil
end

---Keys that should never be treated as user-facing instance data properties.
---@param key any
---@return boolean
function miscUtils.shouldSkipInstanceDataPropertyKey(key)
    return key == "$type" or key == "$storage" or key == "Flags"
end

---Recursively checks whether a key/value pair (or any of its nested children) matches a search string.
---@param key any
---@param value any
---@param search string
---@param visited table<table, boolean>
---@return boolean hasMatch
---@return boolean directMatch
function miscUtils.matchesPropertySearchEntry(key, value, search, visited)
    if miscUtils.shouldSkipInstanceDataPropertyKey(key) then
        return false, false
    end

    local directMatch = miscUtils.matchesInstanceDataSearch(key, search)
    local valueType = type(value)

    if valueType == "table" then
        if visited[value] then
            return directMatch, directMatch
        end
        visited[value] = true

        local hasChildMatch = false
        for childKey, childValue in pairs(value) do
            local childHasMatch = miscUtils.matchesPropertySearchEntry(childKey, childValue, search, visited)
            if childHasMatch then
                hasChildMatch = true
                break
            end
        end

        return directMatch or hasChildMatch, directMatch
    end

    if valueType ~= "nil" and valueType ~= "function" and valueType ~= "thread" then
        if miscUtils.matchesInstanceDataSearch(value, search) then
            directMatch = true
        end
    end

    return directMatch, directMatch
end

---Checks whether any top-level property of a component (or its pending changes) matches a search string.
---@param component table
---@param componentChanges table?
---@param search string
---@return boolean
function miscUtils.matchesComponentPropertiesSearch(component, componentChanges, search)
    local topLevelKeys = {}

    if type(component) == "table" then
        for key, _ in pairs(component) do
            topLevelKeys[key] = true
        end
    end

    if type(componentChanges) == "table" then
        for key, _ in pairs(componentChanges) do
            topLevelKeys[key] = true
        end
    end

    for key, _ in pairs(topLevelKeys) do
        local value = nil
        if type(componentChanges) == "table" and componentChanges[key] ~= nil then
            value = componentChanges[key]
        elseif type(component) == "table" then
            value = component[key]
        end

        local hasMatch = miscUtils.matchesPropertySearchEntry(key, value, search, {})
        if hasMatch then
            return true
        end
    end

    return false
end

---Coerces a value read back from surveyed data or a serialized payload to a boolean.
---Survey values arrive as the raw strings the RED types printed, so "True" and "1" have to
---read as true just like a real boolean or a non-zero number.
---@param value any
---@return boolean
function miscUtils.toBoolean(value)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end

    local text = miscUtils.trimString(value or ""):lower()
    return text == "true" or text == "1"
end

---Zero-based index of an enum member name inside its ordered member list.
---Written for settings restored from surveyed data, where the stored value is the member
---name and the class keeps the index the combo boxes use.
---@param list string[] Ordered enum member names.
---@param name any Member name to look up; `nil` yields the fallback.
---@param fallback integer Returned when `name` is absent or unknown to the list.
---@return integer
function miscUtils.enumIndex(list, name, fallback)
    if name == nil then
        return fallback
    end

    local index = miscUtils.indexValue(list, name)
    if type(index) == "number" and index > 0 then
        return index - 1
    end

    return fallback
end

---Builds the option list of a resource dropdown: trimmed, de-duplicated case-insensitively,
---sorted, and led by an empty entry standing for "none".
---@param list any Array of paths or names; anything else yields just the empty entry.
---@return string[]
function miscUtils.toSelectableList(list)
    local out = { "" }
    if type(list) ~= "table" then
        return out
    end

    local seen = {}
    for _, path in ipairs(list) do
        local text = miscUtils.trimString(path or "")
        if text ~= "" and not seen[text:lower()] then
            seen[text:lower()] = true
            table.insert(out, text)
        end
    end

    table.sort(out, function (a, b) return a:lower() < b:lower() end)

    return out
end

return miscUtils
