local spline = require("modules/classes/spawn/meta/spline")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
local field = require("modules/utils/field")
local projectedWireframe = require("modules/utils/editor/projectedWireframe")
local settings = require("modules/utils/settings")

-- worldSpeedSplineOrientationMarkerType, ordered by enum value.
-- The `value` is the exact RED enum name used on export, the rest drives the UI.
-- `axes` lists which orientation components (pitch/yaw/roll) this mode actually overrides;
-- only those are shown as inputs and applied to the gizmo.
local orientationModes = {
    { value = "UseSplineOrientation",        label = "Use spline orientation",        tooltip = "Keep the orientation defined by the spline itself. Target orientation is ignored.",  axes = {} },
    { value = "WorldSpace",                  label = "World space (absolute)",         tooltip = "Force an absolute world-space orientation, ignoring the spline direction.",           axes = { pitch = true, yaw = true, roll = true } },
    { value = "LocalSpace",                  label = "Local space (spline relative)",  tooltip = "Apply the target orientation relative to the spline's local frame.",                  axes = { pitch = true, yaw = true, roll = true } },
    { value = "KeepYawRoll_WorldSpacePitch", label = "Override pitch only",            tooltip = "Keep yaw & roll from the spline, override pitch in world space.",                     axes = { pitch = true } },
    { value = "KeepPitchYaw_WorldSpaceRoll", label = "Override roll only",             tooltip = "Keep pitch & yaw from the spline, override roll in world space.",                     axes = { roll = true } },
    { value = "KeepPitchRoll_WorldSpaceYaw", label = "Override yaw only",              tooltip = "Keep pitch & roll from the spline, override yaw in world space.",                     axes = { yaw = true } },
    { value = "KeepYaw_WorldSpacePitchRoll", label = "Override pitch & roll",          tooltip = "Keep yaw from the spline, override pitch & roll in world space.",                     axes = { pitch = true, roll = true } },
    { value = "KeepRoll_WorldSpacePitchYaw", label = "Override pitch & yaw",           tooltip = "Keep roll from the spline, override pitch & yaw in world space.",                     axes = { pitch = true, yaw = true } },
    { value = "KeepPitch_WorldSpaceYawRoll", label = "Override yaw & roll",            tooltip = "Keep pitch from the spline, override yaw & roll in world space.",                     axes = { yaw = true, roll = true } }
}

local orientationModeLabels = {}
local orientationModeIndexByValue = {}
for index, mode in ipairs(orientationModes) do
    orientationModeLabels[index] = mode.label
    orientationModeIndexByValue[mode.value] = index
end

---Resolves a mode entry (falls back to the first entry) from its enum value.
---@param modeValue string
---@return table
local function getOrientationMode(modeValue)
    return orientationModes[orientationModeIndexByValue[modeValue] or 1]
end

local maxSectionPosition = 100000

-- In-world gizmo used to preview rotation points. The prism model points along +Y after
-- the alignment offset below (same offset the light preview uses for this mesh).
local rotationGizmoMesh = "base\\spawner\\triangular_prism.mesh"
local rotationGizmoAppearance = "yellow"
local rotationGizmoScale = 0.5

---Packs an RGBA color into the IM_COL32 (0xAABBGGRR) integer used by ImGui draw lists.
---@param r number
---@param g number
---@param b number
---@param a number?
---@return integer
local function rgba(r, g, b, a)
    return (a or 255) * 0x1000000 + b * 0x10000 + g * 0x100 + r
end

-- On-screen point marker colors per type, in two variants selected by the global
-- "Wireframe color style" setting: 1 = darker markers + white text, 2 = lighter markers + black text.
local pointLabelColors = {
    [1] = {
        speed = rgba(45, 140, 60),       -- dark green
        rotation = rgba(180, 100, 20),   -- dark orange
        groundSnap = rgba(30, 105, 170)  -- dark blue
    },
    [2] = {
        speed = rgba(95, 220, 95),       -- light green
        rotation = rgba(245, 165, 45),   -- light orange
        groundSnap = rgba(70, 190, 235)  -- light blue
    }
}
local pointLabelTextColors = {
    [1] = rgba(220, 216, 209), -- near-white
    [2] = rgba(0, 0, 0)        -- black
}

---Resolves the current point-label palette from the "Wireframe color style" setting.
---@return table colors Marker colors keyed by point type.
---@return integer textColor Badge text color.
local function getPointLabelPalette()
    local styleIndex = tonumber(settings.wireframeColorStyle) == 2 and 2 or 1
    return pointLabelColors[styleIndex], pointLabelTextColors[styleIndex]
end

-- Display units for speed, matching the `speedUnit` setting (1 = km/h, 2 = mph).
local speedUnitLabels = { "km/h", "mph" }
local speedUnitFactors = { 3.6, 2.2369363 } -- m/s -> unit

---Formats a speed (m/s) using the unit chosen in the appearance settings.
---@param speedMetersPerSecond number
---@return string
local function formatDisplaySpeed(speedMetersPerSecond)
    local unit = tonumber(settings.speedUnit) or 1
    if unit ~= 1 and unit ~= 2 then
        unit = 1
    end
    return string.format("%.0f %s", speedMetersPerSecond * speedUnitFactors[unit], speedUnitLabels[unit])
end

---Returns the world position and spline travel direction at a given distance (m) along a polyline.
---@param points table[] Ordered {x,y,z} points forming the polyline.
---@param distance number Distance in meters measured from the first point.
---@return table|nil position {x,y,z} world position, or nil when the polyline is empty.
---@return Vector4|nil forward Spline travel direction at that position.
local function positionAlongPolyline(points, distance)
    if #points == 0 then return nil end

    local function forwardAt(i)
        local a = points[i]
        local b = points[i + 1]
        return Vector4.new(b.x - a.x, b.y - a.y, b.z - a.z, 0)
    end

    if #points == 1 then
        return points[1], Vector4.new(0, 1, 0, 0)
    end

    if distance <= 0 then
        return points[1], forwardAt(1)
    end

    local traveled = 0
    for i = 1, #points - 1 do
        local a = points[i]
        local b = points[i + 1]
        local segmentLength = utils.distanceVector(a, b)
        if segmentLength > 0 and traveled + segmentLength >= distance then
            local t = (distance - traveled) / segmentLength
            return {
                x = a.x + (b.x - a.x) * t,
                y = a.y + (b.y - a.y) * t,
                z = a.z + (b.z - a.z) * t
            }, forwardAt(i)
        end
        traveled = traveled + segmentLength
    end

    return points[#points], forwardAt(#points - 1)
end

---Class for worldSpeedSplineNode. Reuses the whole basic spline pipeline (path,
---markers, curve/NPC preview) and layers the speed-spline specific runtime data on top:
---speed control, per-position rotation overrides and ground snapping.
---@class speedSpline : spline
---@field speedChangeSections table
---@field orientationChangeSections table
---@field roadAdjustmentFactorChangeSections table
---@field ignoreTerrain boolean
---@field protected speedPropertyWidth number
local speedSpline = setmetatable({}, { __index = spline })

function speedSpline:new()
    local o = spline.new(self)

    o.spawnListType = "files"
    o.dataType = "Speed Spline"
    o.spawnDataPath = "data/spawnables/meta/speedSpline/"
    o.modulePath = "meta/speedSpline"
    o.node = "worldSpeedSplineNode"
    o.description = "Spline that drives movement along it, with speed, rotation and ground-snap control at arbitrary positions. Reuses the basic spline for its path and can be referenced using its NodeRef."
    o.icon = IconGlyphs.Speedometer

    o.previewColor = "cyan"

    -- [Speed control]
    o.speedChangeSections = {}
    -- [Rotation]
    o.orientationChangeSections = {}
    -- [Ground Snap]
    o.roadAdjustmentFactorChangeSections = {}
    o.ignoreTerrain = false

    o.speedPropertyWidth = nil
    o._rotationGizmoCount = 0

    setmetatable(o, { __index = self })
    return o
end

---@param value any
---@param default number
---@return number
local function toNumber(value, default)
    local number = tonumber(value)
    if number == nil then
        return default
    end
    return number
end

function speedSpline:loadSpawnData(data, position, rotation)
    spline.loadSpawnData(self, data, position, rotation)

    self.speedChangeSections = self:normalizeSpeedSections(self.speedChangeSections)
    self.orientationChangeSections = self:normalizeOrientationSections(self.orientationChangeSections)
    self.roadAdjustmentFactorChangeSections = self:normalizeRoadSections(self.roadAdjustmentFactorChangeSections)
    self.ignoreTerrain = self.ignoreTerrain == true
end

---@param sections table?
---@return table
function speedSpline:normalizeSpeedSections(sections)
    local normalized = {}
    for _, section in ipairs(sections or {}) do
        table.insert(normalized, {
            start = toNumber(section.start, 0),
            endPos = toNumber(section.endPos, 0),
            speed = toNumber(section.speed, 0)
        })
    end
    return normalized
end

---@param sections table?
---@return table
function speedSpline:normalizeOrientationSections(sections)
    local normalized = {}
    for _, section in ipairs(sections or {}) do
        local mode = section.mode
        if not orientationModeIndexByValue[mode] then
            mode = orientationModes[1].value
        end
        table.insert(normalized, {
            pos = toNumber(section.pos, 0),
            mode = mode,
            pitch = toNumber(section.pitch, 0),
            yaw = toNumber(section.yaw, 0),
            roll = toNumber(section.roll, 0)
        })
    end
    return normalized
end

---@param sections table?
---@return table
function speedSpline:normalizeRoadSections(sections)
    local normalized = {}
    for _, section in ipairs(sections or {}) do
        table.insert(normalized, {
            pos = toNumber(section.pos, 0),
            factor = toNumber(section.factor, 1)
        })
    end
    return normalized
end

---Snapshots the element for undo before a structural (add/remove) list change.
function speedSpline:recordStructuralChange()
    if self.object then
        history.addAction(history.getElementChange(self.object))
    end
end

---Ordered curve polyline (first marker -> last marker), independent of the reverse
---preview flag, so a point's "position along the spline" is always measured from the
---first spline point.
---@return table[] points Ordered {x,y,z} world points.
function speedSpline:getMarkerOrderedPathPoints()
    local points = self:getFollowerPathPoints()
    if self.reverse and #points > 1 then
        local ordered = {}
        for i = #points, 1, -1 do
            table.insert(ordered, points[i])
        end
        return ordered
    end
    return points
end

---Creates (or fetches) the mesh component used as the in-world gizmo for rotation point `index`.
---@param index number
---@return entMeshComponent|nil
function speedSpline:getRotationGizmoComponent(index)
    local entity = self:getEntity()
    if not entity then return end

    local name = "rotationGizmo" .. tostring(index)
    local component = entity:FindComponentByName(name)
    if component then
        return component
    end

    component = entMeshComponent.new()
    component.name = name
    component.mesh = ResRef.FromString(rotationGizmoMesh)
    component.meshAppearance = rotationGizmoAppearance
    component.visualScale = Vector3.new(rotationGizmoScale, rotationGizmoScale, rotationGizmoScale)
    component.isEnabled = self.previewed
    entity:AddComponent(component)

    return component
end

---Combines the spline travel direction at a point with the point's target orientation and
---applies the prism alignment offset. `WorldSpace` uses the absolute target orientation only.
---@param forward Vector4? Spline travel direction at the point.
---@param section table Orientation change section.
---@return Quaternion
function speedSpline:getRotationGizmoOrientation(forward, section)
    -- Only the axes the mode actually overrides contribute; the rest follow the spline.
    -- This also makes "Use spline orientation" ignore any stale target values.
    local axes = getOrientationMode(section.mode).axes
    local pointRotation = EulerAngles.new(
        axes.roll and section.roll or 0,
        axes.pitch and section.pitch or 0,
        axes.yaw and section.yaw or 0
    )

    local combined
    if section.mode == "WorldSpace" or not (forward and forward:Length() > 0.0001) then
        combined = pointRotation
    else
        -- Overridden components applied relative to the spline heading (its local frame).
        combined = utils.addEulerRelative(forward:ToRotation(), pointRotation)
    end

    -- Align the prism model with the combined forward, mirroring the light preview's
    -- `entityRotation * meshLocalOffset` composition.
    local offset = EulerAngles.new(-90, 0, 90):ToQuat()
    return Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](combined:ToQuat(), offset)
end

---Positions and orients a triangular-prism gizmo at each rotation point, hiding unused ones.
---The gizmo shows the point's orientation combined with the spline direction for an accurate preview.
function speedSpline:updateRotationGizmos()
    local entity = self:getEntity()
    if not entity then return end

    local points = self:getMarkerOrderedPathPoints()
    local used = 0

    if #points >= 2 then
        for _, section in ipairs(self.orientationChangeSections) do
            local worldPos, forward = positionAlongPolyline(points, section.pos)
            if worldPos then
                used = used + 1
                local component = self:getRotationGizmoComponent(used)
                if component then
                    local localPos = utils.subVector(Vector4.new(worldPos.x, worldPos.y, worldPos.z, 0), self.position)
                    component:SetLocalPosition(Vector4.new(localPos.x, localPos.y, localPos.z, 0))
                    component:SetLocalOrientation(self:getRotationGizmoOrientation(forward, section))
                    component:Toggle(self.previewed)
                    component:RefreshAppearance()
                end
            end
        end
    end

    for i = used + 1, self._rotationGizmoCount or 0 do
        local component = entity:FindComponentByName("rotationGizmo" .. tostring(i))
        if component then
            component:Toggle(false)
        end
    end

    self._rotationGizmoCount = math.max(self._rotationGizmoCount or 0, used)
end

function speedSpline:updateCurvePreview()
    spline.updateCurvePreview(self)
    self:updateRotationGizmos()
end

---Whether point labels should currently be drawn: only while the spline is selected
---or its preview is enabled. Used by the editor to skip opening an empty overlay.
---@return boolean
function speedSpline:wantsViewportOverlay()
    return self.object ~= nil and (self.object.selected == true or self.previewed == true)
end

---Draws on-screen, color-coded labels for each point at its position along the spline.
---Shown while the spline is selected or its preview is enabled. Invoked once per frame
---by the editor viewport overlay pass.
---@param screen projectedScreenContext Projection context from `projectedWireframe.beginOverlay`.
---@param drawList table ImGui draw list from `projectedWireframe.beginOverlay`.
function speedSpline:drawViewportOverlay(screen, drawList)
    if not self:wantsViewportOverlay() then return end

    local points = self:getMarkerOrderedPathPoints()
    if #points < 2 then return end

    local colors, textColor = getPointLabelPalette()

    ---@param position number Distance along the spline (m).
    ---@param color integer Marker color.
    ---@param text string Badge text.
    ---@param below boolean? When true, the badge is placed under the point instead of above.
    local function drawLabel(position, color, text, below)
        local world = positionAlongPolyline(points, position)
        if not world then return end

        projectedWireframe.drawWorldMarker(drawList, screen, Vector4.new(world.x, world.y, world.z, 0), {
            color = color,
            labelColor = textColor,
            text = text,
            radius = 5 * style.viewSize,
            innerRadius = 2.5 * style.viewSize,
            badgeOffsetY = (below and 9 or -14) * style.viewSize,
            fontRatio = 0.85,
            clampToScreen = false
        })
    end

    for index, section in ipairs(self.speedChangeSections) do
        drawLabel(section.start, colors.speed, string.format("S%d  %s", index, formatDisplaySpeed(section.speed)))
        drawLabel(section.endPos, colors.speed, string.format("S%d end", index))
    end

    -- Rotation points are previewed with in-world prism gizmos (see updateRotationGizmos), not labels.

    for index, section in ipairs(self.roadAdjustmentFactorChangeSections) do
        drawLabel(section.pos, colors.groundSnap, string.format("G%d  %.2f", index, section.factor), true)
    end
end

-- Width (unscaled) reserved for the leading index cell of each table row.
local rowIndexColumnWidth = 20

---Draws the leading index cell of a table-style row and aligns the cursor to the field columns.
---@param prefix string Unique ImGui id prefix for the row.
---@param index number Row number shown in the index cell.
---@param fieldStartX number Absolute cursor X where the field columns start.
local function beginTableRow(prefix, index, fieldStartX)
    ImGui.PushID(prefix .. index)
    ImGui.AlignTextToFramePadding()
    ImGui.SetCursorPosX(8 * style.viewSize)
    style.mutedText(string.format("%d", index))
    ImGui.SameLine()
    ImGui.SetCursorPosX(fieldStartX)
end

---Draws a red delete button at the end of a table-style row. Returns true when clicked.
---@return boolean
local function drawRowDeleteButton()
    ImGui.SameLine()
    local clicked = style.dangerButton(IconGlyphs.DeleteOutline)
    style.tooltip("Remove this entry")
    return clicked
end

---Absolute X where a table row's value columns start (after the index cell).
---@return number
local function getRowFieldStartX()
    return rowIndexColumnWidth * (style.viewSize or 1)
end

---Editable "position along the spline" cell.
---A fixed generous max is used (never the live spline length) so stored positions
---are never silently clamped/mutated when the spline geometry changes.
---@param self speedSpline
---@param id string
---@param value number
---@param suffix string
---@return number newValue
local function positionCell(self, id, value, suffix)
    local newValue = field.advancedTrackedFloat(self.object, id, value, {
        min = 0,
        max = maxSectionPosition,
        step = 0.1,
        format = "%.2f",
        suffix = suffix,
        width = 68
    })
    return newValue
end

function speedSpline:draw()
    -- Reuse the entire basic spline UI (path, length, reverse, looped, previewing options).
    spline.draw(self)

    if not self.speedPropertyWidth then
        self.speedPropertyWidth = utils.getTextMaxWidth({ "Ignore Terrain" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    ImGui.Spacing()
    self:drawSpeedControlSection()
    self:drawRotationSection()
    self:drawGroundSnapSection()
end

function speedSpline:drawSpeedControlSection()
    if not ImGui.TreeNodeEx("Speed Control (" .. #self.speedChangeSections .. ")###speedControl", ImGuiTreeNodeFlags.SpanFullWidth) then
        return
    end

    style.mutedText("Sets the target speed along ranges of the spline.\nPositions are distances in meters from the spline start.")
    ImGui.Spacing()

    local fieldStartX = getRowFieldStartX()
    local removeIndex = nil

    for index, section in ipairs(self.speedChangeSections) do
        beginTableRow("speedSection", index, fieldStartX)

        section.start = positionCell(self, "##start", section.start, " start")
        style.tooltip("Start position of this speed range (m along the spline).")

        ImGui.SameLine()
        section.endPos = positionCell(self, "##end", section.endPos, " end")
        style.tooltip("End position of this speed range (m along the spline).")

        ImGui.SameLine()
        section.speed = field.advancedTrackedFloat(self.object, "##speed", section.speed, { min = 0, max = 1000, step = 0.1, format = "%.2f", suffix = " m/s", width = 80 })
        style.tooltip("Desired speed inside this range, in meters per second.")

        ImGui.SameLine()
        style.mutedText(string.format("(%s)", formatDisplaySpeed(section.speed)))

        if drawRowDeleteButton() then
            removeIndex = index
        end

        ImGui.PopID()
    end

    if removeIndex then
        self:recordStructuralChange()
        table.remove(self.speedChangeSections, removeIndex)
    end

    if ImGui.Button(IconGlyphs.Plus .. " Add speed range") then
        self:recordStructuralChange()
        local length = self:getTotalLength()
        table.insert(self.speedChangeSections, {
            start = 0,
            endPos = length > 0.01 and length or 10,
            speed = 10
        })
    end

    ImGui.TreePop()
end

function speedSpline:drawRotationSection()
    if not ImGui.TreeNodeEx("Rotation (" .. #self.orientationChangeSections .. ")###rotation", ImGuiTreeNodeFlags.SpanFullWidth) then
        return
    end

    style.mutedText("Overrides orientation at specific positions along the spline.")
    ImGui.Spacing()

    local fieldStartX = getRowFieldStartX()
    local removeIndex = nil
    local dirty = false

    for index, section in ipairs(self.orientationChangeSections) do
        beginTableRow("orientationSection", index, fieldStartX)

        local previousPos = section.pos
        section.pos = positionCell(self, "##pos", section.pos, " m")
        style.tooltip("Position where this orientation is applied (m along the spline).")
        if section.pos ~= previousPos then dirty = true end

        ImGui.SameLine()
        local modeIndex = orientationModeIndexByValue[section.mode] or 1
        -- Pass the description through the combo's own tooltip (value + helper) instead of a
        -- second style.tooltip call, which would render an overlapping/clipped tooltip window.
        local newModeIndex, modeChanged = style.trackedCombo(self.object, "##mode", modeIndex - 1, orientationModeLabels, 168, {
            tooltip = getOrientationMode(section.mode).tooltip
        })
        if modeChanged then
            section.mode = orientationModes[newModeIndex + 1].value
            dirty = true
        end

        local axes = getOrientationMode(section.mode).axes
        local changedP, changedY, changedR
        if axes.pitch then
            ImGui.SameLine()
            section.pitch, changedP = field.advancedTrackedFloat(self.object, "##pitch", section.pitch, { min = -360, max = 360, step = 0.5, format = "%.1f", suffix = " P", width = 52 })
            style.tooltip("Overridden pitch, in degrees.")
        end
        if axes.yaw then
            ImGui.SameLine()
            section.yaw, changedY = field.advancedTrackedFloat(self.object, "##yaw", section.yaw, { min = -360, max = 360, step = 0.5, format = "%.1f", suffix = " Y", width = 52 })
            style.tooltip("Overridden yaw, in degrees.")
        end
        if axes.roll then
            ImGui.SameLine()
            section.roll, changedR = field.advancedTrackedFloat(self.object, "##roll", section.roll, { min = -360, max = 360, step = 0.5, format = "%.1f", suffix = " R", width = 52 })
            style.tooltip("Overridden roll, in degrees.")
        end
        if changedP or changedY or changedR then dirty = true end

        if drawRowDeleteButton() then
            removeIndex = index
        end

        ImGui.PopID()
    end

    if removeIndex then
        self:recordStructuralChange()
        table.remove(self.orientationChangeSections, removeIndex)
        dirty = true
    end

    if ImGui.Button(IconGlyphs.Plus .. " Add rotation point") then
        self:recordStructuralChange()
        table.insert(self.orientationChangeSections, {
            pos = 0,
            mode = orientationModes[1].value,
            pitch = 0,
            yaw = 0,
            roll = 0
        })
        dirty = true
    end

    if dirty then
        self:updateCurvePreview()
    end

    ImGui.TreePop()
end

function speedSpline:drawGroundSnapSection()
    if not ImGui.TreeNodeEx("Ground Snap (" .. #self.roadAdjustmentFactorChangeSections .. ")###groundSnap", ImGuiTreeNodeFlags.SpanFullWidth) then
        return
    end

    style.mutedText("Ignore Terrain")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.speedPropertyWidth + ImGui.GetTreeNodeToLabelSpacing())
    self.ignoreTerrain = style.trackedCheckbox(self.object, "##ignoreTerrain", self.ignoreTerrain)
    style.tooltip("When enabled, the spline no longer snaps its height to the terrain / road below it.")

    ImGui.Spacing()
    style.mutedText("Adjusts how strongly the spline snaps to the ground at specific positions.\n1 = fully snapped, 0 = keep the spline height.")
    ImGui.Spacing()

    local fieldStartX = getRowFieldStartX()
    local removeIndex = nil

    for index, section in ipairs(self.roadAdjustmentFactorChangeSections) do
        beginTableRow("roadSection", index .. ".", fieldStartX)

        section.pos = positionCell(self, "##pos", section.pos, " m")
        style.tooltip("Position where this ground-snap strength is applied (m along the spline).")

        ImGui.SameLine()
        section.factor = field.advancedTrackedFloat(self.object, "##factor", section.factor, { min = 0, max = 1, step = 0.01, format = "%.2f", suffix = " snap", width = 80 })
        style.tooltip("Ground snap blend factor. 1 = fully snapped to the ground, 0 = keep the spline's own height.")

        if drawRowDeleteButton() then
            removeIndex = index
        end

        ImGui.PopID()
    end

    if removeIndex then
        self:recordStructuralChange()
        table.remove(self.roadAdjustmentFactorChangeSections, removeIndex)
    end

    if ImGui.Button(IconGlyphs.Plus .. " Add ground-snap point") then
        self:recordStructuralChange()
        table.insert(self.roadAdjustmentFactorChangeSections, {
            pos = 0,
            factor = 1
        })
    end

    ImGui.TreePop()
end

function speedSpline:save()
    local data = spline.save(self)

    data.speedChangeSections = utils.deepcopy(self.speedChangeSections)
    data.orientationChangeSections = utils.deepcopy(self.orientationChangeSections)
    data.roadAdjustmentFactorChangeSections = utils.deepcopy(self.roadAdjustmentFactorChangeSections)
    data.ignoreTerrain = self.ignoreTerrain

    return data
end

function speedSpline:export()
    local data = spline.export(self)
    data.type = "worldSpeedSplineNode"

    local speedChangeSections = {}
    for _, section in ipairs(self.speedChangeSections) do
        table.insert(speedChangeSections, {
            ["$type"] = "worldSpeedSplineNodeSpeedChangeSection",
            ["start"] = section.start,
            ["end"] = section.endPos,
            ["targetSpeed_M_P_S"] = section.speed
        })
    end

    local orientationChangeSections = {}
    for _, section in ipairs(self.orientationChangeSections) do
        table.insert(orientationChangeSections, {
            ["$type"] = "worldSpeedSplineNodeOrientationChangeSection",
            ["pos"] = section.pos,
            ["type"] = section.mode,
            ["targetOrientation"] = {
                ["$type"] = "EulerAngles",
                ["Pitch"] = section.pitch,
                ["Yaw"] = section.yaw,
                ["Roll"] = section.roll
            }
        })
    end

    local roadAdjustmentFactorChangeSections = {}
    for _, section in ipairs(self.roadAdjustmentFactorChangeSections) do
        table.insert(roadAdjustmentFactorChangeSections, {
            ["$type"] = "worldSpeedSplineNodeRoadAdjustmentFactorChangeSection",
            ["pos"] = section.pos,
            ["targetFactor"] = section.factor
        })
    end

    data.data.speedChangeSections = speedChangeSections
    data.data.orientationChangeSections = orientationChangeSections
    data.data.roadAdjustmentFactorChangeSections = roadAdjustmentFactorChangeSections
    data.data.ignoreTerrain = self.ignoreTerrain and 1 or 0

    return data
end

return speedSpline
