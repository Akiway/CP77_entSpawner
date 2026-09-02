local visualizer = require("modules/utils/preview/visualizer")

---Optional "show this node's radius at true scale" preview.
---
---`base\spawner\sphere.mesh` is unit-radius, so the radius goes in unscaled - the same convention the
---light radius preview and the speaker range sphere use. The component is deliberately not in
---`visualizer.toggleAll`'s list, so it is toggled explicitly and the small position marker can stay
---visible while the sphere is off.
---
---A spawnable opts in by declaring `radiusPreviewed`, calling `attach` from `onAfterPreviewAssemble`,
---`update` from `onAfterPreviewScale` and `setPreview`, and drawing `toggleButton` next to its radius
---field.
---@class radiusSphere
local radiusSphere = {}

radiusSphere.COMPONENT = "radius_sphere"
radiusSphere.COLOR = "ghostwhite"

---@param spawnable spawnable Must carry `radius`, `previewed` and `radiusPreviewed`.
---@return { x: number, y: number, z: number }
local function size(spawnable)
    local radius = math.max(tonumber(spawnable.radius) or 0, 0)

    return { x = radius, y = radius, z = radius }
end

---@param spawnable spawnable
---@return boolean
function radiusSphere.shouldShow(spawnable)
    return spawnable.previewed == true
        and spawnable.radiusPreviewed == true
        and (tonumber(spawnable.radius) or 0) > 0
end

---Rescales the sphere and settles its visibility. Safe on an unspawned element.
---@param spawnable spawnable
---@param entity entEntity? Defaults to the spawnable's live entity.
function radiusSphere.update(spawnable, entity)
    local target = entity or spawnable:getEntity()
    if not target then return end

    local sphere = target:FindComponentByName(radiusSphere.COMPONENT)
    if not sphere then return end

    -- `updateScale` re-toggles an enabled component to make the new scale take, so scale first and
    -- let the visibility check below settle the final state.
    visualizer.updateScale(target, size(spawnable), radiusSphere.COMPONENT)

    local shouldEnable = radiusSphere.shouldShow(spawnable)
    if sphere:IsEnabled() ~= shouldEnable then
        sphere:Toggle(shouldEnable)
    end
end

---@param spawnable spawnable
---@param entity entEntity
function radiusSphere.attach(spawnable, entity)
    visualizer.addSphere(entity, size(spawnable), radiusSphere.COLOR, radiusSphere.COMPONENT)
    radiusSphere.update(spawnable, entity)
end

---Draws the toggle that turns the sphere on and off. Call it right after the radius field.
---@param spawnable spawnable
---@param history table The project history module, for undo tracking.
---@param style table The UI style module.
function radiusSphere.toggleButton(spawnable, history, style)
    ImGui.SameLine()
    ImGui.BeginDisabled(not spawnable.previewed)
    local newState, toggled = style.toggleButton(IconGlyphs.RadiusOutline .. "##radiusPreview", spawnable.radiusPreviewed)
    ImGui.EndDisabled()

    if toggled then
        if spawnable.object then
            history.addAction(history.getElementChange(spawnable.object))
        end
        spawnable.radiusPreviewed = newState
        radiusSphere.update(spawnable)
    end

    style.tooltip(
        (not spawnable.previewed and "Enable visualization to preview the radius")
            or (spawnable.radiusPreviewed and "Hide the radius sphere" or "Show the radius at true scale")
    )
end

return radiusSphere
