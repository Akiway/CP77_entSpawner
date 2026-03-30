local spawnable = require("modules/classes/spawn/spawnable")
local visualizer = require("modules/utils/visualizer")
local style = require("modules/ui/style")
local intersection = require("modules/utils/editor/intersection")

---Class for any spawnable that has a "basic" visualizer. Intersection uses a sphere bound (capsules use a larger bounding sphere).
---@class visualized : spawnable
---@field public previewed boolean
---@field private previewShape string
---@field private previewColor string
---@field private previewMesh string
---@field private intersectionMultiplier number
local visualized = setmetatable({}, { __index = spawnable })

function visualized:new()
	local o = spawnable.new(self)

    o.dataType = "Visualized"
    o.modulePath = "visualized"

    o.previewed = false
    o.previewShape = "sphere"
    o.previewMesh = ""
    o.intersectionMultiplier = 1
    o.previewColor = "blue"

    setmetatable(o, { __index = self })
   	return o
end

function visualized:onAssemble(entity)
    spawnable.onAssemble(self, entity)

    local visualizerSize = self:getVisualizerSize()

    if self.previewShape == "sphere" then
        visualizer.addSphere(entity, visualizerSize, self.previewColor)
    elseif self.previewShape == "box" then
        visualizer.addBox(entity, visualizerSize, self.previewColor)
    elseif self.previewShape == "capsule" then
        visualizer.addCapsule(entity, visualizerSize.x, visualizerSize.z, self.previewColor)
    elseif self.previewShape == "mesh" then
        visualizer.addMesh(entity, visualizerSize, self.previewMesh)
    end

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    visualizer.toggleAll(entity, self.previewed)
end

function visualized:save()
    local data = spawnable.save(self)

    data.previewed = self.previewed

    return data
end

---@protected
function visualized:updateScale()
    local entity = self:getEntity()
    if not entity then return end

    local visualizerSize = self:getVisualizerSize()
    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    if self.previewShape == "capsule" then
        visualizer.updateCapsuleScale(entity, visualizerSize.x, visualizerSize.z)
    else
        visualizer.updateScale(entity, visualizerSize, self.previewShape)
    end
end

function visualized:getVisualizerSize()
    return self:getArrowSize()
end

function visualized:calculateIntersection(origin, ray)
    if not self:getEntity() or not self.previewed then
        return { hit = false }
    end

    if self.previewShape == "sphere" or self.previewShape == "mesh" or self.previewShape == "capsule" then
        local visualizerSize = self:getVisualizerSize()
        local radius = visualizerSize.x * self.intersectionMultiplier
        if self.previewShape == "capsule" then
            -- Use a bounding sphere large enough to cover the capsule body and caps.
            radius = (visualizerSize.x + visualizerSize.z / 2) * self.intersectionMultiplier
        end
        local result = intersection.getSphereIntersection(origin, ray, self.position, radius)
        local bbox = {
            min = { x = -radius, y = -radius, z = -radius },
            max = { x = radius, y = radius, z = radius }
        }

        return {
            hit = result.hit,
            position = result.position,
            unscaledHit = result.position,
            collisionType = "shape",
            distance = result.distance,
            bBox = bbox,
            objectOrigin = self.position,
            objectRotation = self.rotation,
            normal = result.normal
        }
    else
        return spawnable.calculateIntersection(self, origin, ray)
    end
end

function visualized:setPreview(state)
    self.previewed = state

    local entity = self:getEntity()
    if not entity then return end

    visualizer.toggleAll(entity, self.previewed)
end

function visualized:drawPreviewCheckbox(text, textX)
    if textX then
        style.mutedText(text)
        ImGui.SameLine()
        if textX ~= -1 then
            ImGui.SetCursorPosX(textX)
        end
        text = "##" .. text
    end

    self.previewed, changed = style.trackedCheckbox(self.object, text or "Visualize", self.previewed)
    if changed then
        self:setPreview(self.previewed)
    end
end

function visualized:getGroupedProperties()
    local properties = spawnable.getGroupedProperties(self)

    properties["visualization"] = {
		name = "Visualization",
        id = self.dataType,
		data = {},
		draw = function(_, entries)
            ImGui.Text(self.dataType)

            ImGui.SameLine()

            ImGui.PushID(self.dataType)

			if ImGui.Button("Off") then
				for _, entry in ipairs(entries) do
                    if entry.spawnable.node == self.node then
                        entry.spawnable:setPreview(false)
                    end
				end
			end

            ImGui.SameLine()

            if ImGui.Button("On") then
				for _, entry in ipairs(entries) do
                    if entry.spawnable.node == self.node then
                        entry.spawnable:setPreview(true)
                    end
				end
			end

            ImGui.PopID()
		end,
		entries = { self.object }
	}

    return properties
end

return visualized
