local config = require("modules/utils/core/config")
local bendedRig = require("modules/utils/game/bendedRig")

---Collision sources of bended meshes: convex pieces in rest pose with per-vertex bone weights,
---extracted offline into `data/static/bended_collision/`. Deforming them with the node's bone
---matrices gives the convex hull vertices of every piece in node space.
---@class bendedCollision
local collision = {}

local folder = "data/static/bended_collision/"
local index = nil
local loaded = {}

---@class bendedCollisionPiece
---@field class string `ground`, `raised` or `wall`.
---@field slice integer 0-based slice along the rig axis the piece belongs to.
---@field points number[] Flat rest positions `x, y, z, ...` in mesh space.
---@field weights number[] Per point `bone, secondBone, secondWeight` (0-based bones).
---@field faces integer[]? Hull triangles as flat 0-based point indices, counter-clockwise seen from outside.

---@class bendedCollisionSource
---@field bones integer
---@field tolerance number
---@field materials table<string, string> Physics material per class.
---@field pieces bendedCollisionPiece[]

---@class bendedCollisionShape
---@field class string
---@field material string
---@field points { x: number, y: number, z: number }[]
---@field faces integer[]? Same as the piece's.

---@return table<string, string>
local function getIndex()
    if not index then
        local data = config.loadFile(folder .. "index.json")
        index = type(data) == "table" and data or {}
    end
    return index
end

---Collision source of a mesh, or nil when the mesh has none.
---@param path string?
---@return bendedCollisionSource?
function collision.get(path)
    if not path or path == "" then return nil end

    local key = string.lower(path)
    local known = loaded[key]
    if known ~= nil then
        return known or nil
    end

    local name = getIndex()[key]
    local source = name and config.loadFile(folder .. name .. ".json") or nil
    if type(source) ~= "table" or type(source.pieces) ~= "table" or #source.pieces == 0 then
        source = nil
    end

    loaded[key] = source or false
    return source
end

-- Box corners: 0-3 at the start of the segment, 4-7 at its end, same order around the axis.
local boxFaces = {
    0, 1, 2, 0, 2, 3,
    4, 6, 5, 4, 7, 6,
    0, 1, 5, 0, 5, 4,
    1, 2, 6, 1, 6, 5,
    2, 3, 7, 2, 7, 6,
    3, 0, 4, 3, 4, 7
}

---@param a table
---@param b table
---@return table
local function cross(a, b)
    return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x }
end

---@param v table
---@return table
local function normalize(v)
    local length = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if length < 1e-9 then return { x = 0, y = 0, z = 0 } end
    return { x = v.x / length, y = v.y / length, z = v.z / length }
end

---Faces of a box, each wound counter-clockwise seen from outside.
---@param points number[] Flat x, y, z.
---@return integer[]
local function orientBoxFaces(points)
    local cx, cy, cz = 0, 0, 0
    for i = 1, 24, 3 do
        cx, cy, cz = cx + points[i] / 8, cy + points[i + 1] / 8, cz + points[i + 2] / 8
    end

    local faces = {}
    for f = 1, #boxFaces, 3 do
        local a, b, c = boxFaces[f], boxFaces[f + 1], boxFaces[f + 2]
        local ax, ay, az = points[a * 3 + 1], points[a * 3 + 2], points[a * 3 + 3]
        local u = { x = points[b * 3 + 1] - ax, y = points[b * 3 + 2] - ay, z = points[b * 3 + 3] - az }
        local v = { x = points[c * 3 + 1] - ax, y = points[c * 3 + 2] - ay, z = points[c * 3 + 3] - az }
        local n = cross(u, v)
        if n.x * (ax - cx) + n.y * (ay - cy) + n.z * (az - cz) < 0 then
            b, c = c, b
        end
        local n = #faces
        faces[n + 1], faces[n + 2], faces[n + 3] = a, b, c
    end
    return faces
end

---Collision source made of boxes between consecutive bones, sized to the mesh bounds across the rig
---axis. Corners are weighted between the two bones, so they deform like the mesh.
---@param rigData bendedRigData
---@param bounds { min: table, max: table } Mesh bounds in model space.
---@param splits integer Boxes per bone segment.
---@param overlap number Extra length per box, as a share of its length.
---@param material string
---@return bendedCollisionSource?
function collision.buildBoxSource(rigData, bounds, splits, overlap, material)
    local rest = rigData.rest
    if #rest < 2 then return nil end

    local axis = normalize({ x = rest[#rest].x - rest[1].x, y = rest[#rest].y - rest[1].y, z = rest[#rest].z - rest[1].z })
    local u = normalize(cross(axis, { x = 0, y = 0, z = 1 }))
    if u.x == 0 and u.y == 0 and u.z == 0 then
        u = normalize(cross(axis, { x = 1, y = 0, z = 0 }))
    end
    local v = normalize(cross(u, axis))

    -- Cross-section: the mesh bounds measured along u and v from the bone line.
    local uMin, uMax, vMin, vMax = math.huge, -math.huge, math.huge, -math.huge
    for _, x in ipairs({ bounds.min.x, bounds.max.x }) do
        for _, y in ipairs({ bounds.min.y, bounds.max.y }) do
            for _, z in ipairs({ bounds.min.z, bounds.max.z }) do
                local dx, dy, dz = x - rest[1].x, y - rest[1].y, z - rest[1].z
                local du = dx * u.x + dy * u.y + dz * u.z
                local dv = dx * v.x + dy * v.y + dz * v.z
                uMin, uMax = math.min(uMin, du), math.max(uMax, du)
                vMin, vMax = math.min(vMin, dv), math.max(vMax, dv)
            end
        end
    end
    local section = { { uMin, vMin }, { uMax, vMin }, { uMax, vMax }, { uMin, vMax } }

    splits = math.max(1, math.floor(splits or 1))
    overlap = math.max(0, overlap or 0)

    local pieces = {}
    for bone = 1, #rest - 1 do
        local a, b = rest[bone], rest[bone + 1]
        for split = 1, splits do
            local t0, t1 = (split - 1) / splits, split / splits
            local extra = (t1 - t0) * overlap * 0.5
            t0, t1 = t0 - extra, t1 + extra

            local points, weights = {}, {}
            for _, t in ipairs({ t0, t1 }) do
                local ex, ey, ez = a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t
                for _, s in ipairs(section) do
                    local n = #points
                    points[n + 1] = ex + u.x * s[1] + v.x * s[2]
                    points[n + 2] = ey + u.y * s[1] + v.y * s[2]
                    points[n + 3] = ez + u.z * s[1] + v.z * s[2]
                    weights[n + 1] = bone - 1
                    weights[n + 2] = bone
                    weights[n + 3] = math.max(0, math.min(1, t))
                end
            end

            pieces[#pieces + 1] = { class = "ground", slice = bone - 1, points = points, weights = weights, faces = orientBoxFaces(points) }
        end
    end

    return { bones = #rest, tolerance = 0, materials = { ground = material }, pieces = pieces }
end

---Skinning matrices (`inverseBind * deformation`) of every bone, as flat row-major matrices.
---@param rigData bendedRigData
---@param deformation table[] Per bone `{ X, Y, Z, W }` rows (Vector4 or `{ x, y, z, w }`).
---@return table[]
function collision.getSkinMatrices(rigData, deformation)
    local skin = {}
    for bone, inverseBind in ipairs(rigData.inverseBind) do
        local d = deformation[bone]
        if not d then break end
        skin[bone] = bendedRig.mul(inverseBind, {
            d.X.x, d.X.y, d.X.z, 0,
            d.Y.x, d.Y.y, d.Y.z, 0,
            d.Z.x, d.Z.y, d.Z.z, 0,
            d.W.x, d.W.y, d.W.z, 1
        })
    end
    return skin
end

---@param m table
---@param x number
---@param y number
---@param z number
---@return number, number, number
local function transform(m, x, y, z)
    return x * m[1] + y * m[5] + z * m[9] + m[13],
        x * m[2] + y * m[6] + z * m[10] + m[14],
        x * m[3] + y * m[7] + z * m[11] + m[15]
end

---Deformed convex pieces in node space, or nil when the skin does not cover the source's bones.
---@param source bendedCollisionSource
---@param skin table[] From `getSkinMatrices`.
---@return bendedCollisionShape[]?
function collision.deform(source, skin)
    if #skin < source.bones then return nil end

    local shapes = {}
    for _, piece in ipairs(source.pieces) do
        local points = {}
        local p, w = piece.points, piece.weights

        for i = 1, #p / 3 do
            local x, y, z = p[i * 3 - 2], p[i * 3 - 1], p[i * 3]
            local b0, b1, w1 = w[i * 3 - 2], w[i * 3 - 1], w[i * 3]
            local ax, ay, az = transform(skin[b0 + 1], x, y, z)

            if w1 > 0 and b1 ~= b0 then
                local bx, by, bz = transform(skin[b1 + 1], x, y, z)
                local w0 = 1 - w1
                ax, ay, az = ax * w0 + bx * w1, ay * w0 + by * w1, az * w0 + bz * w1
            end

            points[i] = { x = ax, y = ay, z = az }
        end

        shapes[#shapes + 1] = {
            class = piece.class,
            material = source.materials and source.materials[piece.class] or "concrete.physmat",
            points = points,
            faces = piece.faces
        }
    end

    return shapes
end

return collision
