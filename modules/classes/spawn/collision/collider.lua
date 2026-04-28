local colliderBase = require("modules/classes/spawn/collision/colliderBase")
local style = require("modules/ui/style")
local visualizer = require("modules/utils/visualizer")
local settings = require("modules/utils/settings")
local utils = require("modules/utils/utils")
local intersection = require("modules/utils/editor/intersection")

local materials = colliderBase.getColliderGenerics().materials
local presets = colliderBase.getColliderGenerics().presets
local colors = colliderBase.getColliderGenerics().colors

---@param value string
---@return string
local function toReadableMaterialLabel(value)
    local label = tostring(value or "")
    label = label:gsub("%.physmat$", "")
    label = label:gsub("_", " ")
    label = label:gsub("%s+", " ")
    label = label:gsub("^%s*(.-)%s*$", "%1")

    return label:gsub("(%a)([%w']*)", function(first, rest)
        return string.upper(first) .. string.lower(rest)
    end)
end

local materialDisplayOptions = {}
local materialDisplayToIndex = {}
local presetToIndex = {}

for i, material in ipairs(materials) do
    local label = toReadableMaterialLabel(material)

    -- Keep labels stable/unique in case two source values normalize to the same text.
    if materialDisplayToIndex[label] ~= nil then
        label = string.format("%s (%s)", label, material)
    end

    materialDisplayOptions[i] = label
    materialDisplayToIndex[label] = i - 1
end

for i, preset in ipairs(presets) do
    presetToIndex[preset] = i - 1
end

---@param index number?
---@return string
local function getMaterialDisplayByIndex(index)
    local safeIndex = math.max(0, tonumber(index) or 0) + 1
    return materialDisplayOptions[safeIndex] or materialDisplayOptions[1] or ""
end

---Class for worldCollisionNode
---@class collider : colliderBase
---@field private shape integer
---@field private material integer
---@field private preset integer
---@field private shapeTypes table
---@field public previewed boolean
---@field public maxPropertyWidth number
local collider = setmetatable({}, { __index = colliderBase })

function collider:new()
	local o = colliderBase.new(self)

    o.spawnListType = "files"
    o.dataType = "Collision Shape"
    o.spawnDataPath = "data/spawnables/colliders/"
    o.modulePath = "collision/collider"
    o.node = "worldCollisionNode"
    o.description = "A collision shape, can be a box, capsule or sphere"

    o.shape = 0
    o.shapeTypes = { "Box", "Capsule", "Sphere" }

    o.scale = { x = 1, y = 1, z = 1 }
    o.currentAxis = 0
    o.materialSearch = ""
    o.presetSearch = ""

    setmetatable(o, { __index = self })
   	return o
end

function collider:loadSpawnData(data, position, rotation)
    colliderBase.loadSpawnData(self, data, position, rotation)

    if self.shape == 0 then
        if data.extents then
            self.scale = {
                x = tonumber(data.extents.x) or self.scale.x,
                y = tonumber(data.extents.y) or self.scale.y,
                z = tonumber(data.extents.z) or self.scale.z
            }
        end
    elseif self.shape == 1 then
        if data.radius ~= nil or data.height ~= nil then
            local radius = tonumber(data.radius) or self.scale.x
            self.scale = {
                x = radius,
                y = radius,
                z = tonumber(data.height) or self.scale.z
            }
        end
    elseif self.shape == 2 then
        if data.radius ~= nil then
            local radius = tonumber(data.radius) or self.scale.x
            self.scale = { x = radius, y = radius, z = radius }
        end
    end
end

function collider:onAssemble(entity)
    colliderBase.onAssemble(self, entity)

    local component = entColliderComponent.new()
    component.name = "collider"
    local actor
    local color = colors[settings.colliderColor + 1]

    if self.shape == 0 then
        actor = physicsColliderBox.new()
        actor.halfExtents = ToVector3(self.scale)
        visualizer.addBox(entity, self.scale, color)
    elseif self.shape == 1 then
        actor = physicsColliderCapsule.new()
        actor.height = self.scale.z
        actor.radius = self.scale.x
        visualizer.addCapsule(entity, self.scale.x, self.scale.z, color)
    elseif self.shape == 2 then
        actor = physicsColliderSphere.new()
        actor.radius = self.scale.x
        visualizer.addSphere(entity, self.scale, color)
    end

    actor.material = materials[self.material + 1]

    component.colliders = { actor }

    local filterData = physicsFilterData.new()
    filterData.preset = self.preset

    local query = physicsQueryFilter.new()
    query.mask1 = 0
    query.mask2 = 70107400

    local sim = physicsSimulationFilter.new()
    sim.mask1 = 114696
    sim.mask2 = 23627

    filterData.queryFilter = query
    filterData.simulationFilter = sim
    component.filterData = filterData

    entity:AddComponent(component)

    visualizer.toggleAll(entity, self.previewed)
end

function collider:save()
    local data = colliderBase.save(self)

    data.shape = self.shape
    data.material = self.material
    data.preset = self.preset
    data.previewed = self.previewed
    data.scale = { x = self.scale.x, y = self.scale.y, z = self.scale.z }
    if data.previewed == nil then data.previewed = true end

    return data
end

function collider:getSize()
    if self.shape == 1 then
        return { x = self.scale.x * 2, y = self.scale.x * 2, z = self.scale.z + self.scale.x * 2 }
    end
    return { x = self.scale.x * 2, y = self.scale.y * 2, z = self.scale.z * 2 }
end

function collider:getArrowSize()
    local max = math.max(self.scale.x, self.scale.y, self.scale.z)

    max = math.max(max, 1) * 0.5

    return { x = max, y = max, z = max }
end

function collider:setPreview(state)
    self.previewed = state
    visualizer.toggleAll(self:getEntity(), self.previewed)
end

function collider:calculateIntersection(origin, ray)
    if not self:getEntity() or not self.previewed then
        return { hit = false }
    end

    local scaledBBox = {
        min = {  x = - self.scale.x, y = - self.scale.y, z = - self.scale.z },
        max = {  x = self.scale.x, y = self.scale.y, z = self.scale.z }
    }
    local result

    if self.shape == 2 then
        result = intersection.getSphereIntersection(origin, ray, self.position, self.scale.x)
    else
        result = intersection.getBoxIntersection(origin, ray, self.position, self.rotation, scaledBBox)
    end

    return {
        hit = result.hit,
        position = result.position,
        unscaledHit = result.position,
        collisionType = "bbox",
        distance = result.distance,
        bBox = scaledBBox,
        objectOrigin = self.position,
        objectRotation = self.rotation,
        normal = result.normal
    }
end

---@protected
function collider:updateScale(finished, delta)
    self.scale.x = math.max(self.scale.x, 0)
    self.scale.y = math.max(self.scale.y, 0)
    self.scale.z = math.max(self.scale.z, 0)

    if self.shape == 1 then
        if math.abs(delta.y) > 0 then
            self.currentAxis = 0
        elseif math.abs(delta.x) > 0 then
            self.currentAxis = 1
        end

        if finished then
            if self.currentAxis == 0 then
                self.scale.x = self.scale.y
            else
                self.scale.y = self.scale.x
            end
        end
    elseif self.shape == 2 then
        local radius = math.max(self.scale.x, self.scale.y, self.scale.z)
        self.scale = { x = radius, y = radius, z = radius }
    end

    if finished then
        self:respawn()
        return
    end

    local entity = self:getEntity()
    if not entity then return end

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")

    if self.shape == 0 then
        visualizer.updateScale(entity, self.scale, "box")
    elseif self.shape == 1 then
        visualizer.updateCapsuleScale(self:getEntity(), self.currentAxis == 1 and self.scale.x or self.scale.y, self.scale.z)
    elseif self.shape == 2 then
        visualizer.updateScale(entity, self.scale, "sphere")
    end
end

function collider:draw()
    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Preview Shape", "Collision Shape", "Collision Preset", "Collision Material" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    style.mutedText("Preview Shape")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.previewed, changed = style.trackedCheckbox(self.object, "##collisionPreview", self.previewed)
    if changed then
        self:setPreview(self.previewed)
    end

    style.mutedText("Collision Shape")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.shape, changed = style.trackedCombo(self.object, "##type", self.shape, self.shapeTypes, 100)
    if changed then
        self:updateScale(true, { x = 0, y = 0, z = 0 })
    end

    colliderBase.draw(self)
end

function collider:export()
	local extents
    local shapeType
    local size
	if self.shape == 0 then
		local max = math.max(self.scale.x, self.scale.y, self.scale.z)
		extents = Vector4.new(max, max, max)
        shapeType = "Box"
        size = self.scale
	elseif self.shape == 1 then
		local max = math.max(self.scale.y, self.scale.z)
		extents = Vector4.new(max, max, max)
        shapeType = "Capsule"
        size = Vector4.new(self.scale.y, self.scale.z, 0, 0)
	elseif self.shape == 2 then
		extents = Vector4.new(self.scale.x, self.scale.x, self.scale.x)
        shapeType = "Sphere"
        size = Vector4.new(self.scale.x, 0, 0, 0)
	end

    local rotation = self.rotation:ToQuat()

    local data = colliderBase.export(self)
    data.type = "worldCollisionNode"
    data.data = {
		["compiledData"] = {
			["BufferId"] = utils.nextExportBufferId("CollisionBuffer"),
			["Flags"] = 4063232,
			["Type"] = "WolvenKit.RED4.Archive.Buffer.CollisionBuffer, WolvenKit.RED4, Version=8.14.1.0, Culture=neutral, PublicKeyToken=null",
			["Data"] = {
				["Actors"] = {
					{
						["Position"] = {
							["$type"] = "WorldPosition",
							["x"] = {
								["$type"] = "FixedPoint",
								["Bits"] = math.floor(self.position.x * 131072)
							},
							["y"] = {
								["$type"] = "FixedPoint",
								["Bits"] = math.floor(self.position.y * 131072)
							},
							["z"] = {
								["$type"] = "FixedPoint",
								["Bits"] = math.floor(self.position.z * 131072)
							}
						},
						["Shapes"] = {
							{
								["ShapeType"] = shapeType,
                                ["Rotation"] = {
                                    ["$type"] = "Quaternion",
                                    ["i"] = rotation.i,
                                    ["j"] = rotation.j,
                                    ["k"] = rotation.k,
                                    ["r"] = rotation.r
                                  },
								["Size"] = {
									["$type"] = "Vector3",
									["X"] = size.x,
									["Y"] = size.y,
									["Z"] = size.z
								},
								["Preset"] = {
									["$type"] = "CName",
									["$storage"] = "string",
									["$value"] = presets[self.preset + 1]
								},
								["ProxyType"] = "CharacterObstacle",
								["Materials"] = {
									{
										["$type"] = "CName",
										["$storage"] = "string",
										["$value"] = materials[self.material + 1]
									}
								}
							}
						},
						["Scale"] = {
							["$type"] = "Vector3",
							["X"] = 1,
							["Y"] = 1,
							["Z"] = 1
						}
					}
				}
			}
		},
		["extents"] = {
			["$type"] = "Vector4",
			["W"] = 0,
			["X"] = extents.x,
			["Y"] = extents.y,
			["Z"] = extents.z
		},
		["lod"] = 1,
		["numActors"] = 1,
		["numMaterialIndices"] = 1,
		["numMaterials"] = 1,
		["numPresets"] = 1,
		["numScales"] = 1,
		["numShapeIndices"] = 1,
		["numShapeInfos"] = 1,
		["numShapePositions"] = 0,
		["numShapeRotations"] = 1,
        ["resourceVersion"] = 2, -- You little shit
		["staticCollisionShapeCategories"] = {
			["$type"] = "worldStaticCollisionShapeCategories_CollisionNode",
			["arr"] = {
				["Elements"] = {
					{ ["Elements"] = {0, 0, 0, 0, 0, 0} },
					{ ["Elements"] = {0, 1, 0, 0, 0, 0} },
					{ ["Elements"] = {0, 0, 0, 0, 0, 0} },
					{ ["Elements"] = {0, 0, 0, 0, 0, 0} },
					{ ["Elements"] = {0, 1, 0, 0, 0, 0} }
				}
			}
		}
	}


    return data
end

return collider
