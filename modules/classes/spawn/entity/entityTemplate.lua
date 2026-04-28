local entity = require("modules/classes/spawn/entity/entity")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")

local POSITION_MARKER_COMPONENT = "sphere"
local POSITION_MARKER_SCALE = { x = 0.05, y = 0.05, z = 0.05 }
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
    o.showPositionMarker = false

    setmetatable(o, { __index = self })
   	return o
end

function template:updatePositionMarker()
    local entityRef = self:getEntity()
    if not entityRef then return end

    local marker = entityRef:FindComponentByName(POSITION_MARKER_COMPONENT)

    if self.showPositionMarker then
        if not marker then
            visualizer.addSphere(entityRef, POSITION_MARKER_SCALE, POSITION_MARKER_COLOR)
        else
            visualizer.updateScale(entityRef, POSITION_MARKER_SCALE, POSITION_MARKER_COMPONENT)
            marker:Toggle(true)
        end
    elseif marker then
        marker:Toggle(false)
    end
end

function template:setPositionMarkerVisible(state)
    self.showPositionMarker = state
    self:updatePositionMarker()
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
            style.mutedText("Show Position Marker")
            ImGui.SameLine()
            local changed
            self.showPositionMarker, changed = style.trackedCheckbox(self.object, "##showPositionMarkerTemplate", self.showPositionMarker)
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
