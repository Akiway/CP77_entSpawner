local utils = require("modules/utils/core/utils")
local style = require("modules/ui/style")
local history = require("modules/utils/project/history")
local settings = require("modules/utils/core/settings")
local visualizer = require("modules/utils/preview/visualizer")
local radiusSphere = require("modules/utils/preview/radiusSphere")
local componentKinds = require("modules/utils/data/componentKinds")
local light = require("modules/classes/spawn/light/light")
local sound = require("modules/classes/spawn/audio/audio")
local decal = require("modules/classes/spawn/visual/decal")
local colliderBase = require("modules/classes/spawn/collision/colliderBase")

---The preview helpers of an entity's components: the shapes World Builder draws for the matching
---spawnables (light shapes, range spheres, volume boxes, collider shapes, markers), bound to the
---component so they follow it.
---
---A component's helpers show while the entity's Visualize (`previewed`) is on and the component's own
---toggle is on. A toggle that was never set follows the settings `componentHelpersDefault` and
---`componentRadiusHelpersDefault`. They are added while the entity assembles, because a binding
---resolves only then, and switched on and off afterwards without a respawn. Installed onto the entity
---class via componentHelpers.install(entity).
local componentHelpers = {}

local SPHERE_MESH = "base\\spawner\\sphere.mesh"
local CUBE_MESH = "base\\spawner\\cube.mesh"
local CONE_MESH = "base\\spawner\\cone.mesh"
local CAPSULE_BODY_MESH = "base\\spawner\\capsule_body.mesh"
local CAPSULE_CAP_MESH = "base\\spawner\\capsule_cap.mesh"

---@param x number
---@param y number?
---@param z number?
---@return { x: number, y: number, z: number }
local function size(x, y, z)
    return { x = x, y = y or x, z = z or x }
end

---@param vector Vector3|Vector4|table?
---@param factor number
---@return { x: number, y: number, z: number }
local function scaled(vector, factor)
    vector = vector or {}
    return size(math.abs(tonumber(vector.X or vector.x) or 0) * factor, math.abs(tonumber(vector.Y or vector.y) or 0) * factor, math.abs(tonumber(vector.Z or vector.z) or 0) * factor)
end

---@param value any
---@return integer
local function enumIndex(value)
    if type(value) == "number" then return value end
    local ok, index = pcall(EnumInt, value)
    return ok and tonumber(index) or 0
end

---The three meshes of a capsule, as `visualizer.addCapsule` lays them out, turned by `orientation`.
---@param radius number
---@param height number
---@param color string
---@param orientation Quaternion
---@param bottomOrientation Quaternion
---@param position Vector4?
---@return table[]
local function capsuleParts(radius, height, color, orientation, bottomOrientation, position)
    position = position or Vector4.new(0, 0, 0, 0)

    return {
        { mesh = CAPSULE_BODY_MESH, color = color, scale = size(radius, radius, height / 2), orientation = orientation, position = position },
        { mesh = CAPSULE_CAP_MESH, color = color, scale = size(radius), orientation = orientation, position = utils.addVector(position, orientation:Transform(Vector4.new(0, 0, height / 2, 0))) },
        { mesh = CAPSULE_CAP_MESH, color = color, scale = size(radius), orientation = bottomOrientation, position = utils.addVector(position, orientation:Transform(Vector4.new(0, 0, -height / 2, 0))) }
    }
end

---Turns a light spawnable's preview spec into parts.
---@param spec table From `light:getPreviewSpec`
---@return table[]
local function lightSpecParts(spec)
    local orientation = spec.rotation and spec.rotation.kind == "quat" and spec.rotation.value or nil

    if spec.shape == "cone" then
        local parts = { { mesh = CONE_MESH, color = spec.color, scale = spec.size, orientation = orientation } }
        if spec.innerCone then
            table.insert(parts, { mesh = CONE_MESH, color = spec.innerCone.color, scale = spec.innerCone.size, orientation = orientation })
        end
        return parts
    end

    if spec.shape == "mesh" then
        local parts = { { mesh = spec.mesh, color = spec.meshAppearance, scale = spec.size, orientation = orientation } }
        if spec.innerMesh then
            table.insert(parts, { mesh = spec.innerMesh.mesh, color = spec.innerMesh.meshAppearance, scale = spec.innerMesh.size, orientation = orientation })
        end
        return parts
    end

    if spec.shape == "capsule" then
        -- The light spawnable lays its capsule along the light's length with this roll.
        return capsuleParts(spec.size.x, spec.size.z, spec.color, EulerAngles.new(90, 0, 0):ToQuat(), EulerAngles.new(90, 0, 180):ToQuat())
    end

    return { { mesh = SPHERE_MESH, color = spec.color, scale = spec.size } }
end

---@param collider physicsICollider
---@param color string
---@return table[]
local function colliderParts(collider, color)
    local transform = collider.localToBody
    local position = transform and transform.position or Vector4.new(0, 0, 0, 0)
    local orientation = transform and transform.orientation or Quaternion.new(0, 0, 0, 1)

    if collider:IsA("physicsColliderBox") then
        return { { mesh = CUBE_MESH, color = color, scale = scaled(collider.halfExtents, 1), orientation = orientation, position = position } }
    elseif collider:IsA("physicsColliderCapsule") then
        local bottom = utils.multQuat(orientation, EulerAngles.new(0, 180, 0):ToQuat())
        return capsuleParts(collider.radius, collider.height, color, orientation, bottom, position)
    elseif collider:IsA("physicsColliderSphere") then
        return { { mesh = SPHERE_MESH, color = color, scale = size(collider.radius), orientation = orientation, position = position } }
    end

    return {}
end

---Helpers per component class, first match wins. `shape(get, component)` builds the parts, reading
---each field through `get`, which gives a value being dragged before the live component's.
---`radius` names the field a range sphere takes its radius from.
local specs = {
    {
        bases = { "entLightComponent" },
        radius = "radius",
        shape = function(get)
            return lightSpecParts(light.getPreviewSpec({
                lightType = enumIndex(get("type")),
                intensity = tonumber(get("intensity")) or 0,
                capsuleLength = tonumber(get("capsuleLength")) or 0,
                spotCapsule = utils.toBoolean(get("spotCapsule")),
                innerAngle = tonumber(get("innerAngle")) or 0,
                outerAngle = tonumber(get("outerAngle")) or 0,
                areaShape = enumIndex(get("areaShape"))
            }))
        end
    },
    {
        bases = { "gameaudioSoundComponentBase" },
        radius = "maxPlayDistance",
        shape = function(get)
            local markerSize = sound.getVisualizerSize({ radius = tonumber(get("maxPlayDistance")) or 0 })
            return { { mesh = SPHERE_MESH, color = "mediumvioletred", scale = markerSize } }
        end
    },
    {
        bases = { "entDecalComponent" },
        shape = function(get)
            local boxSize = decal.getVisualizerSize(setmetatable({ scale = get("visualScale") }, { __index = decal }))
            return { { mesh = CUBE_MESH, color = "violet", scale = boxSize } }
        end
    },
    {
        bases = { "entEnvProbeComponent" },
        shape = function(get)
            return { { mesh = CUBE_MESH, color = "seashell", scale = scaled(get("size"), 0.5) } }
        end
    },
    {
        bases = { "entFogVolumeComponent" },
        shape = function(get)
            return { { mesh = CUBE_MESH, color = "yellow", scale = scaled(get("size"), 0.5) } }
        end
    },
    {
        bases = { "entStaticOccluderMeshComponent" },
        shape = function(get)
            return { { mesh = CUBE_MESH, color = "lime", scale = scaled(get("scale"), 0.5) } }
        end
    },
    {
        bases = { "entColliderComponent" },
        shape = function(_, component)
            local colors = colliderBase.getColliderGenerics().colors
            local color = colors[settings.colliderColor + 1] or "red"
            local parts = {}
            for _, collider in ipairs(component.colliders or {}) do
                for _, part in ipairs(colliderParts(collider, color)) do
                    table.insert(parts, part)
                end
            end
            return parts
        end
    },
    {
        bases = { "entEffectSpawnerComponent" },
        shape = function()
            return { { mesh = SPHERE_MESH, color = "brown", scale = size(0.15) } }
        end
    },
    {
        bases = { "entParticlesComponent" },
        shape = function()
            return { { mesh = SPHERE_MESH, color = "magenta", scale = size(0.15) } }
        end
    }
}

---@param className string `$type` of the component
---@return table? spec
function componentHelpers.getSpec(className)
    return componentKinds.findByBase(specs, className)
end

---@param componentID string|number
---@param kind string "shape" or "radius"
---@param index integer
---@return string
local function partName(componentID, kind, index)
    return string.format("wb_helper_%s_%s_%d", tostring(componentID), kind, index)
end

---@param entRef entEntity
---@param bindName string
---@param name string
---@param part table
---@param enabled boolean
local function addPart(entRef, bindName, name, part, enabled)
    local mesh = visualizer.addMeshComponent(entRef, name, part.mesh, part.scale, part.color, enabled, bindName)

    if part.orientation then
        mesh:SetLocalOrientation(part.orientation)
    end
    if part.position then
        mesh:SetLocalPosition(part.position)
    end
end

---Reads a component field: a value being dragged in its panel, else a number from the instance data,
---else the live component's value. A device can change its light's live intensity, so a helper sized
---from the live value would disagree with the value set and exported.
---@param entity table
---@param componentID string|number
---@param live entIComponent
---@return fun(field: string): any
local function valueReader(entity, componentID, live)
    return function(field)
        local value = entity:getComponentPendingValue(componentID, { field })
        if value ~= nil then return value end

        for _, source in ipairs({ entity.instanceDataChanges[componentID], entity.defaultComponentData[componentID] }) do
            local stored = type(source) == "table" and source[field]
            if type(stored) == "number" then return stored end
        end

        return live[field]
    end
end

---@param value any
---@return number
local function toRadius(value)
    return math.max(tonumber(value) or 0, 0)
end

local VISUALIZE_OFF_TOOLTIP = "Enable Visualize in Entity Instance Data to show component helpers"

---The sizes and placements of a helper's parts as text, to tell whether a refresh would change them.
---@param parts table[]
---@return string
local function partsSignature(parts)
    local out = {}
    for _, part in ipairs(parts) do
        local o, p = part.orientation, part.position
        table.insert(out, string.format("%.3f,%.3f,%.3f|%s|%s", part.scale.x, part.scale.y, part.scale.z,
            o and string.format("%.4f,%.4f,%.4f,%.4f", o.i, o.j, o.k, o.r) or "",
            p and string.format("%.3f,%.3f,%.3f", p.x, p.y, p.z) or ""))
    end
    return table.concat(out, ";")
end

---Installs the component helper methods onto the entity spawnable class.
---@param entity table The entity spawnable class table
function componentHelpers.install(entity)
    ---@param componentID string|number
    ---@param kind string
    ---@return boolean
    function entity:isComponentHelperShown(componentID, kind)
        return self.previewed == true and self:isComponentHelperOn(componentID, kind)
    end

    ---Whether a component's helper is switched on: its own toggle once set, else the default setting.
    ---@param componentID string|number
    ---@param kind string
    ---@return boolean
    function entity:isComponentHelperOn(componentID, kind)
        local state = self.componentHelpers[componentID]
        if state and state[kind] ~= nil then
            return state[kind] == true
        end
        if kind == "radius" then
            return settings.componentRadiusHelpersDefault == true
        end
        return settings.componentHelpersDefault == true
    end

    ---Adds the helpers switched on for each component, to a freshly assembled entity. They are added
    ---whether or not Visualize is on, so that switching it later needs no respawn.
    ---@param entRef entEntity
    function entity:attachComponentHelpers(entRef)
        self.componentHelperParts = {}

        for _, live in ipairs(entRef:GetComponents()) do
            local spec = componentHelpers.getSpec(live:GetClassName().value)
            if spec then
                local componentID = utils.CRUIDToString(live.id)
                local liveName = live.name.value
                local read = valueReader(self, componentID, live)
                -- `hasRadius`, and an empty `shape` list when building it fails, keep a refresh from
                -- respawning for a part the component can never have.
                local parts = { name = liveName, hasRadius = spec.radius ~= nil }

                if self:isComponentHelperOn(componentID, "shape") then
                    parts.shape = {}
                    local ok, shapeParts = pcall(spec.shape, read, live)
                    if ok then
                        parts.shapeSignature = partsSignature(shapeParts)
                        for index, part in ipairs(shapeParts) do
                            local name = partName(componentID, "shape", index)
                            addPart(entRef, liveName, name, part, self:isComponentHelperShown(componentID, "shape"))
                            table.insert(parts.shape, name)
                        end
                    end
                end

                if spec.radius and self:isComponentHelperOn(componentID, "radius") then
                    local radius = toRadius(read(spec.radius))
                    local name = partName(componentID, "radius", 1)
                    addPart(entRef, liveName, name, { mesh = SPHERE_MESH, color = radiusSphere.COLOR, scale = size(radius) },
                        self:isComponentHelperShown(componentID, "radius") and radius > 0)
                    parts.radius = { name }
                    parts.radiusValue = radius
                end

                self.componentHelperParts[componentID] = parts
            end
        end
    end

    ---Shows or hides the helpers of one component, or of all of them, on the live entity. A helper
    ---switched on that the entity does not carry yet needs a respawn, which adds it.
    ---@param componentID string|number?
    function entity:refreshComponentHelpers(componentID)
        local entRef = self:getEntity()
        if not entRef then return end

        local ids = {}
        if componentID then
            ids[componentID] = true
        else
            for id, _ in pairs(self.componentHelperParts or {}) do ids[id] = true end
        end

        for id, _ in pairs(ids) do
            local parts = self.componentHelperParts and self.componentHelperParts[id] or {}
            for _, kind in ipairs({ "shape", "radius" }) do
                local shown = self:isComponentHelperShown(id, kind) and (kind ~= "radius" or parts.hasRadius ~= false)
                if shown and not parts[kind] then
                    self:respawn()
                    return
                end

                for _, name in ipairs(parts[kind] or {}) do
                    local part = entRef:FindComponentByName(name)
                    local enabled = shown and (kind ~= "radius" or (parts.radiusValue or 0) > 0)
                    if part and part:IsEnabled() ~= enabled then
                        part:Toggle(enabled)
                    end
                end
            end
        end
    end

    ---Resizes the shown shape helpers in place while their fields are dragged, before the edit
    ---respawns the entity. A helper whose number of parts would change waits for the respawn.
    function entity:updateComponentHelperShapes()
        local entRef = self.previewed and self:getEntity()
        if not entRef or not self.componentHelperParts then return end

        for componentID, parts in pairs(self.componentHelperParts) do
            local live = parts.shape and #parts.shape > 0 and entRef:FindComponentByName(parts.name)
            local spec = live and componentHelpers.getSpec(live:GetClassName().value)
            if spec then
                local ok, shapeParts = pcall(spec.shape, valueReader(self, componentID, live), live)
                if ok and #shapeParts == #parts.shape then
                    local signature = partsSignature(shapeParts)
                    if signature ~= parts.shapeSignature then
                        parts.shapeSignature = signature
                        for index, part in ipairs(shapeParts) do
                            local mesh = entRef:FindComponentByName(parts.shape[index])
                            if mesh then
                                if part.orientation then mesh:SetLocalOrientation(part.orientation) end
                                if part.position then mesh:SetLocalPosition(part.position) end
                                visualizer.updateScale(entRef, part.scale, parts.shape[index])
                            end
                        end
                    end
                end
            end
        end
    end

    ---@param state boolean
    function entity:setPreview(state)
        self.previewed = state == true
        self:refreshComponentHelpers()
    end

    ---The entity's Visualize toggle, the switch every component helper sits behind, without a label.
    function entity:drawPreviewToggle()
        local changed
        self.previewed, changed = style.toggleButton(IconGlyphs.HospitalMarker .. "##entityPreview", self.previewed)
        style.tooltip(self.previewed and "Visualize: hide the component helpers" or "Visualize: show the helpers switched on for each component")
        if changed then
            if self.object then
                history.addAction(history.getElementChange(self.object))
            end
            self:setPreview(self.previewed)
        end
    end

    ---The Visualize toggle with its label, as the other spawnables draw it.
    ---@param text string?
    ---@param textX number?
    function entity:drawPreviewCheckbox(text, textX)
        style.mutedText(text or "Visualize")
        ImGui.SameLine()
        if textX and textX ~= -1 then
            ImGui.SetCursorPosX(textX)
        end
        self:drawPreviewToggle()
    end

    ---@param componentID string|number
    ---@param component table
    ---@param kind string
    ---@param state boolean
    local function setHelper(self, componentID, component, kind, state)
        if self.object then
            history.addAction(history.getElementChange(self.object))
        end

        -- Stored as an explicit on or off, so the component keeps it when the default setting changes.
        local current = self.componentHelpers[componentID] or { name = component.name and component.name["$value"] }
        current[kind] = state == true
        self.componentHelpers[componentID] = current

        self:refreshComponentHelpers(componentID)
    end

    ---Draws the toggle for a component's shape helper, when its class has one. Call it on the row.
    ---@param componentID string|number
    ---@param component table
    function entity:drawComponentHelperToggle(componentID, component)
        if not componentHelpers.getSpec(tostring(component["$type"] or "")) then return end

        local state = self:isComponentHelperOn(componentID, "shape")

        -- Drawn as the Spawned tab's rows draw their visualization button, with no vertical padding so
        -- it keeps the tree row's height.
        ImGui.SameLine()
        ImGui.BeginDisabled(not self.previewed)
        style.pushButtonNoBG(true)
        style.pushStyleColor(not state, ImGuiCol.Text, style.mutedColor)
        ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 1 * style.viewSize, 0)
        local clicked = ImGui.Button((state and IconGlyphs.HospitalMarker or IconGlyphs.MapMarkerOffOutline) .. "##componentHelper" .. tostring(componentID))
        ImGui.PopStyleVar()
        style.popStyleColor(not state)
        style.pushButtonNoBG(false)
        ImGui.EndDisabled()
        style.tooltip((not self.previewed and VISUALIZE_OFF_TOOLTIP)
            or (state and "Hide this component's helper" or "Show this component's helper"))

        if clicked then
            setHelper(self, componentID, component, "shape", not state)
        end
    end

    ---Draws the toggle for a component's range sphere. Call it right after the radius row.
    ---@param componentID string|number
    ---@param component table
    function entity:drawComponentRadiusToggle(componentID, component)
        local spec = componentHelpers.getSpec(tostring(component["$type"] or ""))
        if not spec or not spec.radius then return end

        local state = self:isComponentHelperOn(componentID, "radius")

        ImGui.SameLine()
        ImGui.BeginDisabled(not self.previewed)
        local newState, toggled = style.toggleButton(IconGlyphs.RadiusOutline .. "##componentHelperradius" .. tostring(componentID), state)
        ImGui.EndDisabled()
        style.tooltip((not self.previewed and VISUALIZE_OFF_TOOLTIP)
            or (state and "Hide the radius sphere" or "Show the radius at true scale"))

        if toggled then
            setHelper(self, componentID, component, "radius", newState)
        end

        -- Follows the value while it is dragged, before the edit respawns the entity.
        local parts = self.componentHelperParts and self.componentHelperParts[componentID]
        local pending = self:getComponentPendingValue(componentID, { spec.radius })
        if parts and parts.radius and pending ~= nil then
            local radius = toRadius(pending)
            if radius ~= parts.radiusValue then
                parts.radiusValue = radius
                local entRef = self:getEntity()
                if entRef then
                    visualizer.updateScale(entRef, size(radius), parts.radius[1])
                    self:refreshComponentHelpers(componentID)
                end
            end
        end
    end
end

return componentHelpers
