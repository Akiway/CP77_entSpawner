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
local function addMesh(entity, name, mesh, scale, app, enabled)
    if app == "green" then app = "lime" end

    -- Ideally use placed component which is root (No parentTransform, no localTransform), alertnatively use first IPlacedComponent
    local parent = nil
    for _, component in pairs(entity:GetComponents()) do
        if component:IsA("entIPlacedComponent") then
            if not component.parentTransform and component.localTransform.Position:ToVector4():IsZero() and component.localTransform:GetOrientation():GetForward().y == 1 then
                parent = component
                break
            end
        end
    end
    if not parent then parent = entity:GetComponents()[1] end

    local component = entMeshComponent.new()
    component.name = name
    component.mesh = ResRef.FromString(mesh)
    component.visualScale = ToVector3(scale)
    component.meshAppearance = app
    component.isEnabled = enabled

    -- Bind to something, to avoid weird bug where other components would lose their localTransform
    if parent then
        local parentTransform = entHardTransformBinding.new()
        parentTransform.bindName = parent.name.value
        component.parentTransform = parentTransform
    end

    entity:AddComponent(component)
end

---Attach a generic preview mesh named `"mesh"`.
---@param entity entEntity Target entity.
---@param scale visualizerScale Mesh scale.
---@param mesh string Depot mesh path to render.
---@param app string? Optional appearance override. Defaults to `"default"`.
---@param name string? Optional component name override. Defaults to `"mesh"`.
function visualizer.addMesh(entity, scale, mesh, app, name)
    if not entity then return end

    addMesh(entity, name or "mesh", mesh, scale, app or "default", true)
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

    addMesh(entity, "box", "base\\spawner\\cube.mesh", scale, color, true)
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

    addMesh(entity, name or "sphere", "base\\spawner\\sphere.mesh", scale, color, true)
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

    addMesh(entity, name or "cone", "base\\spawner\\cone.mesh", scale, color, true)
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

    addMesh(entity, "capsule_body", "base\\spawner\\capsule_body.mesh", { x = radius, y = radius, z = height / 2 }, color, true)
    addMesh(entity, "capsule_bottom", "base\\spawner\\capsule_cap.mesh", { x = radius, y = radius, z = radius }, color, true)
    addMesh(entity, "capsule_top", "base\\spawner\\capsule_cap.mesh", { x = radius, y = radius, z = radius }, color, true)

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

---Attach axis arrows preview mesh named `"arrows"`.
---@param entity entEntity Target entity.
---@param scale visualizerScale Arrow mesh scale.
---@param active boolean? Initial visibility/enabled state.
---@param app string? Initial appearance (for example `"none"`, `"x"`, `"y"`, `"z"` depending on mesh setup). Defaults to engine/component default when nil.
function visualizer.attachArrows(entity, scale, active, app)
    if not entity then return end

    addMesh(entity, "arrows", "base\\spawner\\arrow.mesh", scale, app, active)
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

---Set visibility for the `"arrows"` component.
---Requires arrows to be already attached on the entity.
---@param entity entEntity Target entity.
---@param state boolean? Desired enabled state.
---Note: this function assumes `"arrows"` exists (usually attached in `spawnable:onAssemble`).
function visualizer.showArrows(entity, state)
    if not entity then return end

    local component = entity:FindComponentByName("arrows")
    if not component then return end

    component:Toggle(state)
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
---Note: this function assumes `"arrows"` exists (usually attached in `spawnable:onAssemble`).
function visualizer.highlightArrow(entity, app)
    if not entity then return end

    local component = entity:FindComponentByName("arrows")
    if not component then return end

    component.meshAppearance = CName.new(app)
    component:LoadAppearance()
end

return visualizer
