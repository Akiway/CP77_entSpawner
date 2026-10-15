local logger = require("modules/utils/core/logger")
local utils = require("modules/utils/core/utils")

---Exports the collision of bended meshes. The pieces of the bended meshes sharing a parent group become
---`worldEntityNode`s of a vanilla collider entity whose collider component is replaced through instance
---data, so the import script needs nothing new. The engine cooks the convex vertices itself.
---@class bendedCollisionExport
local collisionExport = {}

-- Vanilla entity holding one entColliderComponent and nothing visible.
local template = "base\\quest\\main_quests\\part1\\q103\\entities\\q103_bodyguard_collision.ent"
local componentId = "1815393882021453824"
local componentName = "Collider1461"
local collidersPerNode = 256

---@class bendedCollisionExportSource
---@field pieces table[] `{ class, material, points = { x, y, z, ... } }` in world space.
---@field reference table Streaming reference point of the mesh.
---@field range number Streaming range of the mesh.

---@param value string
---@return table
local function cname(value)
    return { ["$type"] = "CName", ["$storage"] = "string", ["$value"] = value }
end

---@return table
local function identityTransform()
    return {
        ["$type"] = "Transform",
        orientation = { ["$type"] = "Quaternion", i = 0, j = 0, k = 0, r = 1 },
        position = { ["$type"] = "Vector4", X = 0, Y = 0, Z = 0, W = 0 }
    }
end

---@param piece table
---@param origin table
---@return table
local function createConvex(piece, origin)
    local vertices = {}
    local points = piece.points
    for i = 1, #points - 2, 3 do
        table.insert(vertices, {
            ["$type"] = "Vector3",
            X = points[i] - origin.x,
            Y = points[i + 1] - origin.y,
            Z = points[i + 2] - origin.z
        })
    end

    return {
        Data = {
            ["$type"] = "physicsColliderConvex",
            indexBuffer = {},
            polygonVertices = {},
            isImported = 0,
            isQueryShapeOnly = 0,
            localToBody = identityTransform(),
            material = cname(piece.material or "concrete.physmat"),
            materialApperanceOverrides = {},
            tag = cname("None"),
            volumeModifier = 1,
            vertices = vertices
        }
    }
end

---Complete collider component replacing the template's, as an instance data chunk.
---@param pieces table[]
---@param origin table
---@return table
local function createComponent(pieces, origin)
    local colliders = {}
    for _, piece in ipairs(pieces) do
        table.insert(colliders, createConvex(piece, origin))
    end

    return {
        ["$type"] = "entColliderComponent",
        id = componentId,
        name = cname(componentName),
        colliders = colliders,
        comOffset = identityTransform(),
        dynamicTrafficSetting = { ["$type"] = "TrafficGenDynamicTrafficSetting", impact = "Ignored" },
        filterData = {
            Data = {
                ["$type"] = "physicsFilterData",
                preset = cname("World Static"),
                queryFilter = { ["$type"] = "physicsQueryFilter", mask1 = "0", mask2 = "70107400" },
                simulationFilter = { ["$type"] = "physicsSimulationFilter", mask1 = "114696", mask2 = "23627" }
            }
        },
        inertia = { ["$type"] = "Vector3", X = 1, Y = 1, Z = 1 },
        isEnabled = 1,
        isReplicable = 0,
        mass = 1,
        massOverride = -1,
        volume = 1,
        localTransform = {
            ["$type"] = "WorldTransform",
            Orientation = { ["$type"] = "Quaternion", i = 0, j = 0, k = 0, r = 1 },
            Position = {
                ["$type"] = "WorldPosition",
                x = { ["$type"] = "FixedPoint", Bits = 0 },
                y = { ["$type"] = "FixedPoint", Bits = 0 },
                z = { ["$type"] = "FixedPoint", Bits = 0 }
            }
        },
        simulationType = "Kinematic",
        startInactive = 0,
        useCCD = 0
    }
end

---Collision source of an exported bended mesh, or nil when it has none.
---@param element table Spawnable element of a bended mesh.
---@return bendedCollisionExportSource?
function collisionExport.collect(element)
    local spawnable = element.spawnable
    local collision, issue = spawnable:getExportCollision()
    if not collision or #collision.pieces == 0 then
        logger:warn(string.format("[bendedCollisionExport] %s exported without collision: %s", tostring(element.name), tostring(issue)))
        return nil
    end

    return {
        pieces = collision.pieces,
        reference = utils.fromVector(spawnable:getStreamingReferencePoint()),
        range = spawnable.primaryRange or 0
    }
end

---Collision nodes of one group: one per `collidersPerNode` pieces, each streamed whenever one of the
---group's meshes is.
---@param name string Group name, for the node names.
---@param sources bendedCollisionExportSource[]
---@return table[] nodes
function collisionExport.buildNodes(name, sources)
    local pieces = {}
    for _, source in ipairs(sources) do
        for _, piece in ipairs(source.pieces) do
            table.insert(pieces, piece)
        end
    end

    local nodes = {}
    local count = math.ceil(#pieces / collidersPerNode)

    for part = 1, count do
        local slice = {}
        local minimum = { math.huge, math.huge, math.huge }
        local maximum = { -math.huge, -math.huge, -math.huge }

        for index = (part - 1) * collidersPerNode + 1, math.min(#pieces, part * collidersPerNode) do
            local piece = pieces[index]
            table.insert(slice, piece)
            for i = 1, #piece.points - 2, 3 do
                for axis = 1, 3 do
                    local value = piece.points[i + axis - 1]
                    minimum[axis] = math.min(minimum[axis], value)
                    maximum[axis] = math.max(maximum[axis], value)
                end
            end
        end

        local origin = {
            x = (minimum[1] + maximum[1]) / 2,
            y = (minimum[2] + maximum[2]) / 2,
            z = (minimum[3] + maximum[3]) / 2
        }

        local range = 0
        for _, source in ipairs(sources) do
            local dx, dy, dz = source.reference.x - origin.x, source.reference.y - origin.y, source.reference.z - origin.z
            range = math.max(range, math.sqrt(dx * dx + dy * dy + dz * dz) + source.range)
        end

        table.insert(nodes, {
            position = origin,
            streamingRefPoint = origin,
            rotation = { i = 0, j = 0, k = 0, r = 1 },
            scale = { x = 1, y = 1, z = 1 },
            primaryRange = range,
            secondaryRange = range * 0.85,
            uk10 = 1024,
            uk11 = 512,
            nodeRef = "",
            type = "worldEntityNode",
            name = "[Bended Collision] " .. name .. (count > 1 and (" " .. part) or ""),
            data = {
                entityTemplate = {
                    DepotPath = { ["$type"] = "ResourcePath", ["$storage"] = "string", ["$value"] = template }
                },
                appearanceName = cname("default"),
                instanceData = {
                    Data = {
                        ["$type"] = "entEntityInstanceData",
                        buffer = {
                            BufferId = utils.nextExportBufferId("EntityBuffer"),
                            Type = "WolvenKit.RED4.Archive.Buffer.RedPackage, WolvenKit.RED4",
                            Data = {
                                Version = 4,
                                Sections = 6,
                                CruidIndex = -1,
                                CruidDict = { ["0"] = componentId },
                                Chunks = { createComponent(slice, origin) }
                            }
                        }
                    }
                }
            }
        })
    end

    return nodes
end

return collisionExport
