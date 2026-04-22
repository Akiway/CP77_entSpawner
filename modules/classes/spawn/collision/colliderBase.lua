local utils = require("modules/utils/utils")
local settings = require("modules/utils/settings")
local style = require("modules/ui/style")
local history = require("modules/utils/history")
local visualizer = require("modules/utils/visualizer")

local colliderGenerics = {
    -- it's cursed, but I ain't scrolling to the end of the line for that
    originalMaterials = { "meatbag.physmat","linoleum.physmat","trash.physmat","plastic.physmat","character_armor.physmat","furniture_upholstery.physmat","metal_transparent.physmat","tire_car.physmat","meat.physmat","metal_car_pipe_steam.physmat","character_flesh.physmat","brick.physmat","character_flesh_head.physmat","leaves.physmat","flesh.physmat","water.physmat","plastic_road.physmat","metal_hollow.physmat","cyberware_flesh.physmat","plaster.physmat","plexiglass.physmat","character_vr.physmat","vehicle_chassis.physmat","sand.physmat","glass_electronics.physmat","leaves_stealth.physmat","tarmac.physmat","metal_car.physmat","tiles.physmat","glass_car.physmat","grass.physmat","concrete.physmat","carpet_techpiercable.physmat","wood_hedge.physmat","stone.physmat","leaves_semitransparent.physmat","metal_catwalk.physmat","upholstery_car.physmat","cyberware_metal.physmat","paper.physmat","leather.physmat","metal_pipe_steam.physmat","metal_pipe_water.physmat","metal_semitransparent.physmat","neon.physmat","glass_dst.physmat","plastic_car.physmat","mud.physmat","dirt.physmat","metal_car_pipe_water.physmat","furniture_leather.physmat","asphalt.physmat","wood_bamboo_poles.physmat","glass_opaque.physmat","carpet.physmat","food.physmat","cyberware_metal_head.physmat","metal_road.physmat","wood_tree.physmat","wood_player_npc_semitransparent.physmat","wood.physmat","metal_car_ricochet.physmat","cardboard.physmat","wood_crown.physmat","metal_ricochet.physmat","plastic_electronics.physmat","glass_semitransparent.physmat","metal_painted.physmat","rubber.physmat","ceramic.physmat","glass_bulletproof.physmat","metal_car_electronics.physmat","trash_bag.physmat","character_cyberflesh.physmat","metal_heavypiercable.physmat","metal.physmat","plastic_car_electronics.physmat","oil_spill.physmat","fabrics.physmat","glass.physmat","metal_techpiercable.physmat","concrete_water_puddles.physmat","character_metal.physmat" },
    materials = {},
    presets = { "World Dynamic","Player Collision","Player Hitbox","NPC Collision","NPC Trace Obstacle","NPC Hitbox","Big NPC Collision","Player Blocker","Block Player and Vehicles","Vehicle Blocker","Block PhotoMode Camera","Ragdoll","Ragdoll Inner","RagdollVehicle","Terrain","Sight Blocker","Moving Kinematic","Interaction Object","Particle","Destructible","Debris","Debris Cluster","Foliage Debris","ItemDrop","Shooting","Moving Platform","Water","Window","Device transparent","Device solid visible","Vehicle Device","Environment transparent","Bullet logic","World Static","Simple Environment Collision","Complex Environment Collision","Foliage Trunk","Foliage Trunk Destructible","Foliage Low Trunk","Foliage Crown","Vehicle Part","Vehicle Proxy","Vehicle Part Query Only Exception","Vehicle Chassis","Chassis Bottom","Chassis Bottom Traffic","Vehicle Chassis Traffic","AV Chassis","Tank Chassis","Vehicle Chassis LOD3","Vehicle Chassis Traffic LOD3","Tank Chassis LOD3","Drone","Prop Interaction","Nameplate","Road Barrier Simple Collision","Road Barrier Complex Collision","Lootable Corpse","Spider Tank"},
    hints = { "Dynamic + Visibility + PhotoModeCamera + VehicleBlocker + TankBlocker + Shooting","Visibility","Player + Shooting","AI + PhotoModeCamera + NPCCollision","NPCTraceObstacle","AI","AI + PhotoModeCamera + VehicleBlocker + TankBlocker + NPCCollision","PlayerBlocker","PlayerBlocker + VehicleBlocker + TankBlocker","VehicleBlocker + TankBlocker","PhotoModeCamera","Ragdoll + Shooting","Ragdoll Inner","Ragdoll + Shooting","Terrain + Visibility + Shooting + PhotoModeCamera + VehicleBlocker + TankBlocker + PlayerBlocker","Visibility","Dynamic + PhotoModeCamera + Visibility + VehicleBlocker + TankBlocker + PlayerBlocker","Interaction","Particle","Destructible + PhotoModeCamera + Visibility + PlayerBlocker","Debris + Visibility","Destructible + PhotoModeCamera + Visibility + PlayerBlocker","Debris + Visibility","Interaction","Shooting","Visibility + Dynamic + Shooting + PhotoModeCamera + NPCBlocker + VehicleBlocker + TankBlocker + PlayerBlocker","Water","Collider + Visibility","Dynamic + Collider + Interaction + PhotoModeCamera + PlayerBlocker + VehicleBlocker + TankBlocker + Visibility","Dynamic + Collider + VehicleBlocker + TankBlocker + Visibility + Interaction + PhotoModeCamera + PlayerBlocker + NPCBlocker","Dynamic + Collider + Visibility + Interaction + PhotoModeCamera + PlayerBlocker","Collider + PlayerBlocker + VehicleBlocker + TankBlocker","Player + AI + Dynamic + Destructible + Terrain + Collider + Particle + Ragdoll + Debris + Shooting","Static + Visibility + Shooting + VehicleBlocker + PhotoModeCamera + VehicleBlocker + TankBlocker + PlayerBlocker","Static + VehicleBlocker + TankBlocker + PlayerBlocker + NPCBlocker + PhotoModeCamera","Shooting + Visibility","Shooting + PlayerBlocker + VehicleBlocker + Visibility + PhotoModeCamera","Shooting + PlayerBlocker + VehicleBlocker + Visibility + PhotoModeCamera + FoliageDestructible","Shooting + PlayerBlocker + Visibility + PhotoModeCamera","Visibility","Vehicle + Visibility + Shooting + PhotoModeCamera + Interaction","Visibility + Shooting + PhotoModeCamera","PlayerBlocker + Shooting + Visibility + Interaction","Vehicle + Interaction","Vehicle","Vehicle","Vehicle + Interaction","Vehicle + Interaction","Vehicle + Tank + Interaction","Vehicle + Interaction + Shooting","Vehicle + Interaction + Shooting","Vehicle + Tank + Interaction + Shooting","PlayerBlocker + Visibility + Shooting","Interaction + Visibility","NPCNameplate + Cloth","PlayerBlocker + VehicleBlocker + TankBlocker","Dynamic + Visibility + Shooting + PhotoModeCamera","Visibility + Interaction + PhotoModeCamera + Shooting","Tank + PlayerBlocker + VehicleBlocker + TankBlocker + Visibility + Shooting" },
    colors = { "red", "green", "blue" }
}

colliderGenerics.materials = utils.deepcopy(colliderGenerics.originalMaterials)
table.sort(colliderGenerics.materials, function(a, b) return a < b end)

local spawnable = require("modules/classes/spawn/spawnable")

---Base class for colliders
---@class colliderBase : spawnable
---@field material number
---@field preset number
---@field previewed boolean
---@field maxPropertyWidth number?
local colliderBase = setmetatable({}, { __index = spawnable })

function colliderBase:new()
	local o = spawnable.new(self)

    o.modulePath = "entity/colliderBase"
    o.icon = IconGlyphs.TextureBox

    o.material = settings.defaultColliderMaterial
    o.preset = 33

    o.previewed = true

    setmetatable(o, { __index = self })
   	return o
end

function colliderBase.getColliderGenerics()
    return colliderGenerics
end

---Respawn the collider to update parameters, if changed
---@param changed boolean
---@protected
function colliderBase:updateFull(changed)
    if changed and self:isSpawned() then self:respawn() end
end

function colliderBase:draw()
    spawnable.draw(self)

    style.mutedText("Collision Preset")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.preset, changed = style.trackedCombo(self.object, "##preset", self.preset, colliderGenerics.presets, 125)
    self:updateFull(changed)
    style.tooltip(colliderGenerics.hints[self.preset + 1])

    style.mutedText("Collision Material")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.material, changed = style.trackedCombo(self.object, "##material", self.material, colliderGenerics.materials, 200)
    self:updateFull(changed)
end

function colliderBase:getProperties()
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

function colliderBase:getGroupedProperties()
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
            element.groupOperationData["collider"].material, _ = ImGui.Combo("##collisionMaterial", element.groupOperationData["collider"].material, colliderGenerics.materials, #colliderGenerics.materials)

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
                        local oldMaterial = colliderGenerics.originalMaterials[entry.spawnable.material + 1]
                        local newIndex = utils.indexValue(colliderGenerics.materials, oldMaterial) - 1
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

return colliderBase