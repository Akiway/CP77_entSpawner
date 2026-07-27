local entity = require("modules/classes/spawn/entity/entity")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")

local POSITION_MARKER_COLOR = "beige"

---Class for entity templates
local template = setmetatable({}, { __index = entity })

function template:new()
	local o = entity.new(self)

    o.dataType = "Entity Template"
    o.spawnDataPath = "data/spawnables/entity/templates/"
    o.node = "worldEntityNode"
    o.description = "Spawns an entity from a given .ent file"

    o.modulePath = "entity/entityTemplate"
    o.entryFilter = "deviceClass"
    o.positionMarkerColor = POSITION_MARKER_COLOR

    setmetatable(o, { __index = self })
   	return o
end

function template:onAssemble(entRef)
    entity.onAssemble(self, entRef)
    self:updatePositionMarker()
end

function template:save()
    local data = entity.save(self)
    data.showPositionMarker = self.showPositionMarker

    return data
end

function template:getProperties()
    local properties = entity.getProperties(self)
    table.insert(properties, {
        id = self.node .. "Visualization",
        name = "Visualization",
        defaultHeader = false,
        draw = function()
            style.mutedText("Visualize position")
            ImGui.SameLine()
            local changed
            self.showPositionMarker, changed = style.toggleButton(IconGlyphs.HospitalMarker, self.showPositionMarker)
            if changed then
                self:setPositionMarkerVisible(self.showPositionMarker)
                self:respawn()
            end
            style.tooltip("Draw a sphere marker at the entity position.")
        end
    })
    return properties
end

return template
