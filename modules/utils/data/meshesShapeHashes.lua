local config = require("modules/utils/core/config")
local utils = require("modules/utils/core/utils")

---@class MeshesShapeHashesDataMeshItem
---@field meshPath string
---@field shapeHashes string[]

---@class MeshesShapeHashesData
---@field meshes MeshesShapeHashesDataMeshItem[]


local module = {}

---@param path string
---@return MeshesShapeHashesData
function module.parseMeshesShapeHashesFile(path)
    local meshesShapeHashesData = config.loadFile(path)
    if type(meshesShapeHashesData) ~= "table" or type(meshesShapeHashesData.meshes) ~= "table" then
        return { meshes = {} }
    end

    return meshesShapeHashesData
end

---@param meshesShapeHashesData MeshesShapeHashesData
---@param collisionShapesDatas { [string]: CollisionShapeData }
---@return { [string]: { [string]: string[] } }
function module.mapMeshesPathsToShapesHashesByTypes(meshesShapeHashesData, collisionShapesDatas)
    local normalizePathOpts = {
        separator = "backslash",
        lowercase = true
    }

    local meshesPathsToShapesHashesByTypes = {}
    for _, item in ipairs(meshesShapeHashesData.meshes) do
        local meshPath = utils.normalizePath(item.meshPath, normalizePathOpts)
        if meshPath ~= "" then
            local shapeHashes = item.shapeHashes
            if shapeHashes and #shapeHashes > 0 then
                local meshShapesHashesByTypes = {}
                for _, shapeHash in ipairs(shapeHashes) do
                    local collisionShapeData = collisionShapesDatas[shapeHash]
                    if collisionShapeData then
                        if meshShapesHashesByTypes[collisionShapeData.type] == nil then
                            meshShapesHashesByTypes[collisionShapeData.type] = {}
                        end
                        table.insert(meshShapesHashesByTypes[collisionShapeData.type], shapeHash)
                    end
                end
                meshesPathsToShapesHashesByTypes[meshPath] = meshShapesHashesByTypes
            end
        end
    end

    return meshesPathsToShapesHashesByTypes
end

return module
