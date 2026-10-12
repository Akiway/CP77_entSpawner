local settings = require("modules/utils/core/settings")

local visualizer = {}

---@alias visualizerScale { x: number, y: number, z: number }

local previewComponentNames = {
    "box",
    "sphere",
    "cone",
    "cone_inner",
    "capsule_body",
    "capsule_top",
    "capsule_bottom",
    "mesh",
    "mesh_inner"
}

---Create and attach an `entMeshComponent` used as preview geometry.
---The component is parent-bound to a placed component to preserve local transforms on existing components.
---@param entity entEntity Target entity that will receive the new mesh component.
---@param name string Component name (for example `"box"`, `"sphere"`, `"arrows"`).
---@param mesh string Depot mesh path.
---@param scale visualizerScale Visual scale applied through `component.visualScale`.
---@param app string? Mesh appearance name. `"green"` is remapped to `"lime"` for compatibility.
---@param enabled boolean? Initial enabled state (`component.isEnabled`).
---Find the component that runtime-added components should bind to.
---Ideally the placed component which is root (No parentTransform, no localTransform), alertnatively the first IPlacedComponent
---@param entity entEntity Target entity.
---@return entIComponent|nil
function visualizer.getPlacedParent(entity)
    if not entity then return nil end

    for _, component in pairs(entity:GetComponents()) do
        if component:IsA("entIPlacedComponent") then
            if not component.parentTransform and component.localTransform.Position:ToVector4():IsZero() and component.localTransform:GetOrientation():GetForward().y == 1 then
                return component
            end
        end
    end

    return entity:GetComponents()[1]
end

---Bind `component` to the entity's stable placed parent. Must be called before `AddComponent`.
---An unbound placed component becomes a root placed component: besides the weird bug where
---other components lose their localTransform, the game crashes once enough of them pile up on
---one entity. Anything adding components in bulk (curve/path previews) has to bind them.
---@param entity entEntity Target entity.
---@param component entIComponent Component that is about to be added.
function visualizer.bindToPlacedParent(entity, component)
    local parent = visualizer.getPlacedParent(entity)
    if not parent then return end

    local parentTransform = entHardTransformBinding.new()
    parentTransform.bindName = parent.name.value
    component.parentTransform = parentTransform
end

---Attach a preview mesh component.
---@param entity entEntity Target entity.
---@param name string Component name.
---@param mesh string Depot mesh path.
---@param scale visualizerScale Mesh scale.
---@param app string? Appearance name.
---@param enabled boolean? Initial visibility.
---@param bindName string? Component to bind to; the entity's placed parent when omitted.
---@return entMeshComponent
function visualizer.addMeshComponent(entity, name, mesh, scale, app, enabled, bindName)
    if app == "green" then app = "lime" end

    local component = entMeshComponent.new()
    component.name = name
    component.mesh = ResRef.FromString(mesh)
    component.visualScale = ToVector3(scale)
    component.meshAppearance = app
    component.isEnabled = enabled

    if bindName then
        local parentTransform = entHardTransformBinding.new()
        parentTransform.bindName = bindName
        component.parentTransform = parentTransform
    else
        visualizer.bindToPlacedParent(entity, component)
    end

    entity:AddComponent(component)
    return component
end

---Attach a generic preview mesh named `"mesh"`.
---@param entity entEntity Target entity.
---@param scale visualizerScale Mesh scale.
---@param mesh string Depot mesh path to render.
---@param app string? Optional appearance override. Defaults to `"default"`.
---@param name string? Optional component name override. Defaults to `"mesh"`.
function visualizer.addMesh(entity, scale, mesh, app, name)
    if not entity then return end

    visualizer.addMeshComponent(entity, name or "mesh", mesh, scale, app or "default", true)
end

---Attach a cube preview mesh named `"box"`.
---@param entity entEntity Target entity.
---@param scale visualizerScale Box scale (half-extents-like usage depends on caller).
---@param color string? Appearance name. When omitted, randomizes between `"red"`, `"green"`, `"blue"`.
function visualizer.addBox(entity, scale, color)
    if not entity then return end

    if not color then
        local colors = { "red", "green", "blue" }
        color = colors[math.random(1, 3)]
    end

    visualizer.addMeshComponent(entity, "box", "base\\spawner\\cube.mesh", scale, color, true)
end

---Attach a sphere preview mesh named `"sphere"`.
---@param entity entEntity Target entity.
---@param scale visualizerScale Sphere scale.
---@param color string? Appearance name. When omitted, randomizes between `"red"`, `"green"`, `"blue"`.
---@param name string? Component name override. Defaults to `"sphere"`.
function visualizer.addSphere(entity, scale, color, name)
    if not entity then return end

    if not color then
        local colors = { "red", "green", "blue" }
        color = colors[math.random(1, 3)]
    end

    visualizer.addMeshComponent(entity, name or "sphere", "base\\spawner\\sphere.mesh", scale, color, true)
end

---Attach a cone preview mesh named `"cone"`.
---@param entity entEntity Target entity.
---@param scale visualizerScale Cone scale.
---@param color string? Appearance name. When omitted, randomizes between `"red"`, `"green"`, `"blue"`.
---@param name string? Component name override. Defaults to `"cone"`.
function visualizer.addCone(entity, scale, color, name)
    if not entity then return end

    if not color then
        local colors = { "red", "green", "blue" }
        color = colors[math.random(1, 3)]
    end

    visualizer.addMeshComponent(entity, name or "cone", "base\\spawner\\cone.mesh", scale, color, true)
end

---Attach a three-part capsule preview (`capsule_body`, `capsule_top`, `capsule_bottom`).
---`height` represents body height between caps (total visual height is `height + 2 * radius`).
---@param entity entEntity Target entity.
---@param radius number Capsule radius for body X/Y and cap size.
---@param height number Capsule body height.
---@param color string? Appearance name. When omitted, randomizes between `"red"`, `"green"`, `"blue"`.
function visualizer.addCapsule(entity, radius, height, color)
    if not entity then return end

    if not color then
        local colors = { "red", "green", "blue" }
        color = colors[math.random(1, 3)]
    end

    visualizer.addMeshComponent(entity, "capsule_body", "base\\spawner\\capsule_body.mesh", { x = radius, y = radius, z = height / 2 }, color, true)
    visualizer.addMeshComponent(entity, "capsule_bottom", "base\\spawner\\capsule_cap.mesh", { x = radius, y = radius, z = radius }, color, true)
    visualizer.addMeshComponent(entity, "capsule_top", "base\\spawner\\capsule_cap.mesh", { x = radius, y = radius, z = radius }, color, true)

    local component = entity:FindComponentByName("capsule_top")
    if component then
        component:SetLocalPosition(Vector4.new(0, 0, height / 2, 0))
    end
    component = entity:FindComponentByName("capsule_bottom")
    if component then
        component:SetLocalPosition(Vector4.new(0, 0, -height / 2, 0))
        component:SetLocalOrientation(EulerAngles.new(0, 180, 0):ToQuat())
    end
end

---Gizmo mode while move and rotate are split (`settings.gizmoRingMode == "split"`): `"move"` shows the
---arrows, `"rotate"` the rotation rings. Combined, both are shown and the mode is ignored.
visualizer.gizmoMode = "move"

---Radius of the rotation rings in `ring.mesh` units, before the gizmo scale is applied.
visualizer.ringRadius = 2.55

-- ring.mesh's radius as a multiple of the arrow length (1.96 in `arrow.mesh`).
local RING_MESH_SIZE = visualizer.ringRadius / 1.96

---Factor from the arrow scale to the ring scale, for `settings.gizmoRingSize`.
---@return number
function visualizer.getRingScaleFactor()
    return (settings.gizmoRingSize or RING_MESH_SIZE) / RING_MESH_SIZE
end

local function ringScale(scale)
    local factor = visualizer.getRingScaleFactor()
    return { x = scale.x * factor, y = scale.y * factor, z = scale.z * factor }
end

-- ring.mesh has 16 sector chunks per ring, rings in the arrow mesh's order (z, y, x). Sector k
-- spans [k, k + 1) * 22.5 degrees in the ring's (u, v) basis (listed at `getRingQuarter`), so
-- quarter q is sectors 4q to 4q + 3. "rings" draws the half facing the camera and "rings_far",
-- with the `far_` appearances, the other half.
local RING_SECTORS = 16
local RING_CHUNK_OFFSET = { z = 0, y = RING_SECTORS, x = 2 * RING_SECTORS }

local function showsArrows()
    return settings.gizmoRingMode ~= "split" or visualizer.gizmoMode == "move"
end

local function showsRings()
    if settings.gizmoRingMode == "off" then return false end
    return settings.gizmoRingMode ~= "split" or visualizer.gizmoMode == "rotate"
end

local function quarterIndex(u, v)
    if u >= 0 then return v >= 0 and 0 or 3 end
    return v >= 0 and 1 or 2
end

---Converts a world-space offset into the gizmo's local axes.
---@param offset Vector4 World-space offset from the gizmo origin.
---@param rotation EulerAngles Gizmo world rotation.
---@return { x: number, y: number, z: number }
function visualizer.toGizmoLocal(offset, rotation)
    return {
        x = offset:Dot(rotation:GetRight()),
        y = offset:Dot(rotation:GetForward()),
        z = offset:Dot(rotation:GetUp())
    }
end

---Returns which quarter (0-3) of a ring a gizmo-local point lies in.
---Ring bases: x uses (y, z), y uses (x, z), z uses (x, y).
---@param axis string `"x"`, `"y"` or `"z"`.
---@param point { x: number, y: number, z: number } Gizmo-local point.
---@return integer
function visualizer.getRingQuarter(axis, point)
    if axis == "x" then return quarterIndex(point.y, point.z) end
    if axis == "y" then return quarterIndex(point.x, point.z) end
    return quarterIndex(point.x, point.y)
end

local function getCameraPosition()
    local player = GetPlayer()
    if not player then return nil end
    local camera = player:GetFPPCameraComponent()
    if not camera then return nil end

    return camera:GetLocalToWorld():GetTranslation()
end

---Returns the camera position in the gizmo's local axes, or nil without a camera.
---@param transform WorldTransform|Matrix Gizmo local-to-world.
---@return { x: number, y: number, z: number }?
function visualizer.getCameraInGizmoSpace(transform)
    local cameraPosition = getCameraPosition()
    if not cameraPosition then return nil end

    local origin = transform:GetTranslation()
    local offset = Vector4.new(cameraPosition.x - origin.x, cameraPosition.y - origin.y, cameraPosition.z - origin.z, 0)

    return visualizer.toGizmoLocal(offset, transform:GetRotation())
end

local function ringPlaneCoords(axis, point)
    if axis == "x" then return point.y, point.z end
    if axis == "y" then return point.x, point.z end
    return point.x, point.y
end

local function setChunkMask(component, mask)
    if tonumber(component.chunkMask) == mask then return end

    component.chunkMask = mask
    component:Toggle(false)
    component:Toggle(true)
end

---Sets which ring sectors show: with `settings.gizmoRingQuarters` only the quarter of each ring
---facing the camera; otherwise the half facing the camera on "rings" and the far half, fainter,
---on "rings_far". Refreshes a component only when its chunk mask changes.
---@param entity entEntity Target entity.
function visualizer.updateRingQuarters(entity)
    if not entity then return end

    local rings = entity:FindComponentByName("rings")
    local far = entity:FindComponentByName("rings_far")
    if not rings then return end

    local showFar = rings:IsEnabled() and not settings.gizmoRingQuarters
    if far and far:IsEnabled() ~= showFar then
        if showFar then far.visualScale = rings.visualScale end
        far:Toggle(showFar)
    end
    if not rings:IsEnabled() then return end

    local camera = visualizer.getCameraInGizmoSpace(rings:GetLocalToWorld())
    if not camera then return end

    local near, farMask = 0, 0
    for axis, offset in pairs(RING_CHUNK_OFFSET) do
        if settings.gizmoRingQuarters then
            local first = visualizer.getRingQuarter(axis, camera) * RING_SECTORS / 4
            for k = first, first + RING_SECTORS / 4 - 1 do
                near = near + 2 ^ (offset + k)
            end
        else
            local u, v = ringPlaneCoords(axis, camera)
            local facing = math.atan2(v, u)
            for k = 0, RING_SECTORS - 1 do
                local center = (k + 0.5) * 2 * math.pi / RING_SECTORS
                if math.cos(center - facing) > 0 then
                    near = near + 2 ^ (offset + k)
                else
                    farMask = farMask + 2 ^ (offset + k)
                end
            end
        end
    end

    setChunkMask(rings, near)
    if far and showFar then
        setChunkMask(far, farMask)
    end
end

---Attach axis arrows preview mesh named `"arrows"`, and the rotation rings named `"rings"`.
---@param entity entEntity Target entity.
---@param scale visualizerScale Arrow mesh scale.
---@param active boolean? Initial visibility/enabled state.
---@param app string? Initial appearance (for example `"none"`, `"x"`, `"y"`, `"z"` depending on mesh setup). Defaults to engine/component default when nil.
function visualizer.attachArrows(entity, scale, active, app)
    if not entity then return end

    visualizer.addMeshComponent(entity, "arrows", "base\\spawner\\arrow.mesh", scale, app, active and showsArrows())
    visualizer.addMeshComponent(entity, "rings", "base\\spawner\\ring.mesh", ringScale(scale), app, active and showsRings())
    visualizer.addMeshComponent(entity, "rings_far", "base\\spawner\\ring.mesh", ringScale(scale), "far_" .. (app or "none"), false, "rings")
end

---Update scale of one preview mesh component.
---If the component is currently enabled, it is toggled off/on to refresh rendering.
---@param entity entEntity Target entity.
---@param scale visualizerScale New scale.
---@param componentName string Existing component name (commonly `"box"`, `"sphere"`, `"cone"`, `"mesh"`, or `"arrows"`).
function visualizer.updateScale(entity, scale, componentName)
    if not entity then return end

    local component = entity:FindComponentByName(componentName)
    if not component then return end
    component.visualScale = ToVector3(scale)

    if component:IsEnabled() then
        component:Toggle(false)
        component:Toggle(true)
    end

    if componentName == "arrows" then
        visualizer.updateScale(entity, ringScale(scale), "rings")
        visualizer.updateScale(entity, ringScale(scale), "rings_far")
    end
end

---Update scales/transforms of existing capsule preview components.
---Requires `capsule_top`, `capsule_bottom`, and `capsule_body` to already exist on the entity.
---@param entity entEntity Target entity.
---@param radius number Capsule radius.
---@param height number Capsule body height.
function visualizer.updateCapsuleScale(entity, radius, height)
    if not entity then return end

    local top = entity:FindComponentByName("capsule_top")
    if top then
        top.visualScale = ToVector3({ x = radius, y = radius, z = radius })
        top:SetLocalPosition(Vector4.new(0, 0, height / 2, 0))

        if top:IsEnabled() then
            top:Toggle(false)
            top:Toggle(true)
        end
    end

    local bottom = entity:FindComponentByName("capsule_bottom")
    if bottom then
        bottom.visualScale = ToVector3({ x = radius, y = radius, z = radius })
        bottom:SetLocalPosition(Vector4.new(0, 0, -height / 2, 0))
        bottom:SetLocalOrientation(EulerAngles.new(0, 180, 0):ToQuat())

        if bottom:IsEnabled() then
            bottom:Toggle(false)
            bottom:Toggle(true)
        end
    end

    local body = entity:FindComponentByName("capsule_body")
    if body then
        body.visualScale = ToVector3({ x = radius, y = radius, z = height / 2 })

        if body:IsEnabled() then
            body:Toggle(false)
            body:Toggle(true)
        end
    end
end

local function setGizmoComponentScale(entity, name, scale)
    local component = entity:FindComponentByName(name)
    if not component or not component:IsEnabled() then return end

    local current = component.visualScale
    if current and math.abs(current.x - scale.x) < 1e-3 and math.abs(current.y - scale.y) < 1e-3 and math.abs(current.z - scale.z) < 1e-3 then
        return
    end

    component.visualScale = ToVector3(scale)
    component:Toggle(false)
    component:Toggle(true)
end

---Apply a new scale to the `"arrows"` and `"rings"` gizmo, but only refresh it when the scale actually changed.
---The refresh (`Toggle` off/on) is what makes an updated `visualScale` take effect, so skipping it
---when nothing changed is what lets this be called every frame (for distance scaling) without flicker.
---No-op for a part that is absent or currently hidden.
---@param entity entEntity Target entity.
---@param scale visualizerScale New arrow scale.
function visualizer.setArrowScale(entity, scale)
    if not entity then return end

    setGizmoComponentScale(entity, "arrows", scale)
    setGizmoComponentScale(entity, "rings", ringScale(scale))
    setGizmoComponentScale(entity, "rings_far", ringScale(scale))
end

---Set visibility for the `"arrows"` and `"rings"` gizmo. With move and rotate split, only the
---part for the current `visualizer.gizmoMode` is shown.
---@param entity entEntity Target entity.
---@param state boolean? Desired enabled state.
---Note: this function assumes the gizmo exists (usually attached in `spawnable:onAssemble`).
function visualizer.showArrows(entity, state)
    if not entity then return end

    local arrows = entity:FindComponentByName("arrows")
    if arrows then
        arrows:Toggle(state and showsArrows())
    end

    local rings = entity:FindComponentByName("rings")
    if rings then
        rings:Toggle(state and showsRings())
        visualizer.updateRingQuarters(entity)
    end
end

---Toggle visibility of all preview components except arrows.
---Affects: `box`, `sphere`, `cone`, `cone_inner`, `capsule_body`, `capsule_top`, `capsule_bottom`, `mesh`.
---@param entity entEntity Target entity.
---@param state boolean? Desired enabled state for each preview component found.
function visualizer.toggleAll(entity, state)
    if not entity then return end

    for _, name in pairs(previewComponentNames) do
        local component = entity:FindComponentByName(name)

        if component then
            component:Toggle(state)
        end
    end
end

---Change arrows appearance (axis highlight) and reload it.
---Requires arrows to be already attached on the entity.
---@param entity entEntity Target entity.
---@param app string Appearance name (typically `"none"`, `"x"`, `"y"`, or `"z"`).
---@param ringApp string? Appearance for the rotation rings. Defaults to `app`.
---Note: this function assumes `"arrows"` exists (usually attached in `spawnable:onAssemble`).
function visualizer.highlightArrow(entity, app, ringApp)
    if not entity then return end

    ringApp = ringApp or app
    for name, ringAppearance in pairs({ rings = ringApp, rings_far = "far_" .. ringApp }) do
        local rings = entity:FindComponentByName(name)
        if rings and rings.meshAppearance.value ~= ringAppearance then
            rings.meshAppearance = CName.new(ringAppearance)
            rings:LoadAppearance()
        end
    end

    local component = entity:FindComponentByName("arrows")
    if not component then return end

    component.meshAppearance = CName.new(app)
    component:LoadAppearance()
end

return visualizer
