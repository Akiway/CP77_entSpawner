local cache = require("modules/utils/game/cache")
local builder = require("modules/utils/game/entityBuilder")

---Bone rigs of bended meshes, read from the mesh resource.
---Matrices are flat row-major arrays of 16 numbers (rows X, Y, Z, W), applied to row vectors:
---`p' = p * M`, so `a * b` applies `a` first.
---@class bendedRig
local rig = {}

local cachePrefix = "bendedRig_"
local loaded = {}
local waiting = {}

---@class bendedRigData
---@field inverseBind table[] `boneRigMatrices`, one flat matrix per bone.
---@field bind table[] Bone poses in model space.
---@field rest table[] Bone positions in model space, `{ x, y, z }`.
---@field distances number[] Cumulative distance along the bones, starting at 0.
---@field linear boolean Bones lie on one line, so a path can drive them.

---@return table
function rig.identity()
    return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

---@param a table
---@param b table
---@return table
function rig.mul(a, b)
    local out = {}
    for r = 0, 3 do
        for c = 1, 4 do
            out[r * 4 + c] = a[r * 4 + 1] * b[c] + a[r * 4 + 2] * b[4 + c] + a[r * 4 + 3] * b[8 + c] + a[r * 4 + 4] * b[12 + c]
        end
    end
    return out
end

---Inverse of an affine matrix (last column 0, 0, 0, 1).
---@param m table
---@return table
function rig.inverse(m)
    local a, b, c = m[1], m[2], m[3]
    local d, e, f = m[5], m[6], m[7]
    local g, h, i = m[9], m[10], m[11]

    local A, B, C = e * i - f * h, -(d * i - f * g), d * h - e * g
    local det = a * A + b * B + c * C
    if math.abs(det) < 1e-12 then
        return rig.identity()
    end
    local s = 1 / det

    local l = {
        A * s, -(b * i - c * h) * s, (b * f - c * e) * s,
        B * s, (a * i - c * g) * s, -(a * f - c * d) * s,
        C * s, -(a * h - b * g) * s, (a * e - b * d) * s
    }

    local tx, ty, tz = m[13], m[14], m[15]
    return {
        l[1], l[2], l[3], 0,
        l[4], l[5], l[6], 0,
        l[7], l[8], l[9], 0,
        -(tx * l[1] + ty * l[4] + tz * l[7]), -(tx * l[2] + ty * l[5] + tz * l[8]), -(tx * l[3] + ty * l[6] + tz * l[9]), 1
    }
end

---@param frame { position: table, right: table, forward: table, up: table }
---@return table
function rig.fromFrame(frame)
    local r, f, u, p = frame.right, frame.forward, frame.up, frame.position
    return { r.x, r.y, r.z, 0, f.x, f.y, f.z, 0, u.x, u.y, u.z, 0, p.x, p.y, p.z, 1 }
end

---@param m table
---@param p { x: number, y: number, z: number }
---@return { x: number, y: number, z: number }
function rig.transformPoint(m, p)
    return {
        x = p.x * m[1] + p.y * m[5] + p.z * m[9] + m[13],
        y = p.x * m[2] + p.y * m[6] + p.z * m[10] + m[14],
        z = p.x * m[3] + p.y * m[7] + p.z * m[11] + m[15]
    }
end

---@param inverseBind table[]
---@return bendedRigData
local function build(inverseBind)
    local data = { inverseBind = inverseBind, bind = {}, rest = {}, distances = {}, linear = true }

    for index, matrix in ipairs(inverseBind) do
        local bind = rig.inverse(matrix)
        data.bind[index] = bind
        data.rest[index] = { x = bind[13], y = bind[14], z = bind[15] }
    end

    local total = 0
    for index, point in ipairs(data.rest) do
        if index > 1 then
            local previous = data.rest[index - 1]
            total = total + math.sqrt((point.x - previous.x) ^ 2 + (point.y - previous.y) ^ 2 + (point.z - previous.z) ^ 2)
        end
        data.distances[index] = total
    end

    -- Grid rigs (bones laid on a plane) cannot follow a path.
    local first, last = data.rest[1], data.rest[#data.rest]
    if first and last and #data.rest > 2 then
        local axis = { x = last.x - first.x, y = last.y - first.y, z = last.z - first.z }
        local length = math.sqrt(axis.x ^ 2 + axis.y ^ 2 + axis.z ^ 2)
        if length < 1e-6 then
            data.linear = false
        else
            for _, point in ipairs(data.rest) do
                local v = { x = point.x - first.x, y = point.y - first.y, z = point.z - first.z }
                local t = (v.x * axis.x + v.y * axis.y + v.z * axis.z) / (length * length)
                local dx, dy, dz = v.x - axis.x * t, v.y - axis.y * t, v.z - axis.z * t
                if math.sqrt(dx * dx + dy * dy + dz * dz) > math.max(0.01, length * 0.001) then
                    data.linear = false
                    break
                end
            end
        end
    end

    return data
end

---@param path string
---@param data bendedRigData?
local function resolve(path, data)
    loaded[path] = data or false
    local callbacks = waiting[path] or {}
    waiting[path] = nil

    for _, callback in ipairs(callbacks) do
        pcall(callback, data)
    end
end

---Rig of a mesh, or nil while it loads. `onReady` runs once the rig arrives (not when cached).
---@param path string?
---@param onReady fun(data: bendedRigData?)?
---@return bendedRigData?
function rig.get(path, onReady)
    if not path or path == "" then return nil end

    local known = loaded[path]
    if known ~= nil then
        return known or nil
    end

    local cached = cache.getValue(cachePrefix .. path)
    if type(cached) == "table" and #cached > 0 then
        local data = build(cached)
        loaded[path] = data
        return data
    end

    if onReady then
        waiting[path] = waiting[path] or {}
        table.insert(waiting[path], onReady)
    end
    if waiting[path] and waiting[path].requested then return nil end
    waiting[path] = waiting[path] or {}
    waiting[path].requested = true

    local ok = pcall(builder.registerLoadResource, path, function (resource)
        local matrices = {}
        local readOk = pcall(function ()
            for index, m in ipairs(resource.boneRigMatrices) do
                matrices[index] = {
                    m.X.x, m.X.y, m.X.z, m.X.w,
                    m.Y.x, m.Y.y, m.Y.z, m.Y.w,
                    m.Z.x, m.Z.y, m.Z.z, m.Z.w,
                    m.W.x, m.W.y, m.W.z, m.W.w
                }
            end
        end)

        if not readOk or #matrices == 0 then
            resolve(path, nil)
            return
        end

        cache.addValue(cachePrefix .. path, matrices)
        resolve(path, build(matrices))
    end)

    if not ok then
        resolve(path, nil)
    end

    return nil
end

return rig
