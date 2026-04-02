local spawnable = require("modules/classes/spawn/spawnable")
local style = require("modules/ui/style")
local visualizer = require("modules/utils/visualizer")
local settings = require("modules/utils/settings")
local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
local intersection = require("modules/utils/editor/intersection")

local colliderGenerics = require("modules/classes/spawn/collision/colliderGenerics")
local originalMaterials = colliderGenerics.originalMaterials
local materials = colliderGenerics.materials
local presets = colliderGenerics.presets
local hints = colliderGenerics.hints
local colors = colliderGenerics.colors

--- Class for worldCollisionNode with convex or triangle collision mesh
--- @see spawnable
--- @class meshCollider : spawnable
--- @field sectorHash string
--- @field shapeHash string
--- @field meshType string
--- @field material integer
--- @field preset integer
--- @field previewed boolean
--- @field maxPropertyWidth number
local meshCollider = setmetatable({}, { __index = spawnable })

---@param spawnUI spawnUI
function meshCollider:new(spawnUI)
    local o = spawnable:new(spawnUI)

    o.spawnListType = "list"
    o.dataType = "Collision Mesh"
    o.spawnDataPath = "data/spawnables/colliders/"
    o.modulePath = "collision/meshCollider"
    o.node = "worldCollisionNode"
    o.description = "A collision mesh."
    o.icon = IconGlyphs.TextureBox

    o.sectorHash = nil
    o.shapeHash = nil
    o.meshType = nil

    o.material = settings.defaultColliderMaterial
    o.preset = 33

    o.previewed = true
    o.maxPropertyWidth = nil

    self.__index = self
    return setmetatable(o, self)
end

---@param data table
---@param position Vector4
---@param rotation EulerAngles
function meshCollider:loadSpawnData(data, position, rotation)
    spawnable.loadSpawnData(self, data, position, rotation)

    --[[ 
    a bit cursed but eh, spawnUI sets the the display / index value which is intended to be a 
    resource path to the resource, but for collision meshes it's using the sectorHash, shapeHash and meshType
    instead so this needs to reparse it to avoid modifying spawnUI
    ]]--
    if (not string.find(data.spawnData, "%.")) then
        local split = utils.split(data.spawnData, " ")
        if #split == 3 then
            self.sectorHash = split[1]
            self.shapeHash = split[2]
            self.meshType = split[3]
        end
    end

    if self.sectorHash and self.shapeHash and self.meshType then
        self.spawnData = "scc\\generated\\geometry_cache\\collision\\" .. self.sectorHash .. "_" .. self.shapeHash .. "_" .. self.meshType:lower() .. ".ent"
    end
end

function meshCollider:onAssemble(entity)
    spawnable.onAssemble(self, entity)

    local component = entity:FindComponentByName("collision_mesh_0")
    if not component then
        print("Error: collision_mesh_0 component not found on entity. Cannot set up mesh collider.")
        return
    end
    component.filterData.preset = self.preset
    component.colliders[1].material = materials[self.material + 1]

    if not self.sectorHash or not self.shapeHash or not self.meshType then
        print("Error: Missing sectorHash, shapeHash, or meshType. Cannot add visualizer mesh.")
        return
    end

    visualizer.addMesh(entity,
        {x = 1, y = 1, z = 1},
        "scc\\generated\\geometry_cache\\visual\\" .. self.sectorHash .. "_" .. self.shapeHash .. "_" .. self.meshType:lower() .. ".mesh",
        colors[settings.colliderColor + 1])
end

function meshCollider:save()
    local data = spawnable.save(self)

    data.sectorHash = self.sectorHash
    data.shapeHash = self.shapeHash
    data.meshType = self.meshType

    data.material = self.material
    data.preset = self.preset

    data.previewed = self.previewed

    return data
end

function meshCollider:getPresetIndexByName(preset)
    return utils.indexValue(presets, preset) - 1
end

function meshCollider:getMaterialIndexByName(material)
    return utils.indexValue(materials, material) - 1
end

function meshCollider:getSize()
    return { x = 1, y = 1, z = 1 }
end

function meshCollider:getArrowSize()
    return { x = 1, y = 1, z = 1 }
end

function meshCollider:draw()
    spawnable.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Preview Shape", "Collision Preset", "Collision Material" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    style.mutedText("Preview Shape")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.previewed, changed = style.trackedCheckbox(self.object, "##collisionPreview", self.previewed)
    if changed then
        visualizer.toggleAll(self:getEntity(), self.previewed)
    end

    style.mutedText("Collision Preset")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.preset, changed = style.trackedCombo(self.object, "##preset", self.preset, presets, 100)
    self:updateFull(changed)
    style.tooltip(hints[self.preset + 1])

    style.mutedText("Collision Material")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.material, changed = style.trackedCombo(self.object, "##material", self.material, materials, 200)
    self:updateFull(changed)
end

function meshCollider:getProperties()
    local properties = spawnable.getProperties(self)
    table.insert(properties, {
        id = self.node,
        name = "Collider",
        defaultHeader = true,
        draw = function()
            self:draw()
        end
    })
    return properties
end

function meshCollider:getGroupedProperties()
    local properties = spawnable.getGroupedProperties(self)

    properties["visualization"] = {
		name = "Visualization",
        id = "colliderVisualization",
		data = {},
		draw = function(_, entries)
            ImGui.Text("Collider")

            ImGui.SameLine()

            ImGui.PushID("collider")

			if ImGui.Button("Off") then
                history.addAction(history.getMultiSelectChange(entries))

				for _, entry in ipairs(entries) do
                    if entry.spawnable.node == "worldCollisionNode" then
                        entry.spawnable.previewed = false
                        visualizer.toggleAll(entry.spawnable:getEntity(), entry.spawnable.previewed)
                    end
				end
			end

            ImGui.SameLine()

            if ImGui.Button("On") then
                history.addAction(history.getMultiSelectChange(entries))

				for _, entry in ipairs(entries) do
                    if entry.spawnable.node == "worldCollisionNode" then
                        entry.spawnable.previewed = true
                        visualizer.toggleAll(entry.spawnable:getEntity(), entry.spawnable.previewed)
                    end
				end
			end

            ImGui.PopID()
		end,
		entries = { self.object }
	}

    properties["collider"] = {
		name = "Collider",
        id = "colliderMaterial",
		data = {
            material = settings.defaultColliderMaterial
        },
		draw = function(element, entries)
            style.mutedText("Collision Material")
            ImGui.SameLine()
            ImGui.SetNextItemWidth(150 * style.viewSize)
            element.groupOperationData["collider"].material, _ = ImGui.Combo("##collisionMaterial", element.groupOperationData["collider"].material, materials, #materials)

            ImGui.SameLine()

            if ImGui.Button("Apply") then
                history.addAction(history.getMultiSelectChange(entries))
                local nApplied = 0

                for _, entry in ipairs(entries) do
                    if entry.spawnable.node == self.node then
                        entry.spawnable.material = element.groupOperationData["collider"].material
                        entry.spawnable:updateFull(true)
                        nApplied = nApplied + 1
                    end
                end

                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Applied collision material to %s nodes", nApplied)))
            end
            style.tooltip("Apply the selected collision material to all selected colliders.")

            if ImGui.Button("Fix Material Indices") then
                history.addAction(history.getMultiSelectChange(entries))
                local nApplied = 0

                for _, entry in ipairs(entries) do
                    if entry.spawnable.node == self.node then
                        local oldMaterial = originalMaterials[entry.spawnable.material + 1]
                        local newIndex = utils.indexValue(materials, oldMaterial) - 1
                        entry.spawnable.material = newIndex
                        entry.spawnable:updateFull(true)
                        nApplied = nApplied + 1
                    end
                end

                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Fixed collision material for %s nodes", nApplied)))
            end
            style.tooltip("Recalculates selected material indices, to fix an oversight with 1.0.7's material sorting\nIf you do not know what this means, ignore it.")
        end,
		entries = { self.object }
	}

    return properties
end

---Respawn the collider to update parameters, if changed
---@param changed boolean
---@protected
function meshCollider:updateFull(changed)
    if changed and self:isSpawned() then self:respawn() end
end

function meshCollider:export()
    local rotation = self.rotation:ToQuat()
    local shapeType = self.meshType
    local extends = self:getSize()

    if shapeType == "BV4TriangleMesh" then
        shapeType = "TriangleMesh"
    end

    local data = spawnable.export(self)
    data.type = "worldCollisionNode"
    data.data = {
		["compiledData"] = {
			["BufferId"] = tostring(tonumber(FNV1a64("CollisionBuffer" .. math.random(1, 10000000)))),
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
                                ["Hash"] = self.shapeHash,
                                ["Position"] = {
									["$type"] = "Vector3",
									["X"] = 0,
									["Y"] = 0,
									["Z"] = 0
								},
                                ["Rotation"] = {
                                    ["$type"] = "Quaternion",
                                    ["i"] = rotation.i,
                                    ["j"] = rotation.j,
                                    ["k"] = rotation.k,
                                    ["r"] = rotation.r
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
								},
                                ["Uk1"] = 0,
                                ["Uk2"] = 0,
                                ["Uk3"] = 0
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
			["X"] = extends.x,
			["Y"] = extends.y,
			["Z"] = extends.z
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
        ["sectorHash"] = self.sectorHash,
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

return meshCollider