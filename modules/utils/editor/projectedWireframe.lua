local utils = require("modules/utils/utils")
local settings = require("modules/utils/settings")
local style = require("modules/ui/style")

local projectedWireframe = {}

---@alias screenPoint { x: number, y: number, behind: boolean?, visible: boolean? }
---@alias projectedNearPlane { normal: Vector4, point: Vector4 }
---@alias projectedScreenContext { width: number, height: number, centerX: number, centerY: number, fontSize: number, nearPlane: projectedNearPlane, cameraWorld: Vector4 }
---@class projectedWireframeBoxOptions
---@field frontColor integer|nil Color for front-facing edges.
---@field backColor integer|nil Color for back-facing edges.
---@field frontThickness number|nil Thickness for front-facing edges.
---@field backThickness number|nil Thickness for back-facing edges.
---@field thickness number|nil Fallback thickness when `frontThickness` is not provided.
---@field showOriginDistance boolean|nil Whether to draw center marker and distance badge.
---@field originColor integer|nil Color for center marker and badge background.
---@field originDistance number|nil Explicit distance for badge text; auto-computed when omitted.
---@field labelColor integer|nil Color for text and inner marker.
---@field originBadgeOffsetY number|nil Vertical offset for distance badge.
---@field fillColor integer|nil Fill color for visible faces.
---@field fillFadeLimit number|nil Max fill alpha fade factor over distance.
---@field minFillAlpha integer|nil Minimum fill alpha after fading.
---@field fadeNear number|nil Distance where edge/fill fading starts.
---@field fadeFar number|nil Distance where edge/fill fading reaches full factor.
---@field fadeLimit number|nil Max edge alpha fade factor over distance.
---@field minFrontAlpha integer|nil Minimum alpha for front edges after fade.
---@field minBackAlpha integer|nil Minimum alpha for back edges after fade.
---@class projectedWireframeMarkerOptions
---@field color integer|nil Marker fill/badge background color.
---@field labelColor integer|nil Marker inner dot and text color.
---@field text string|number|nil Optional badge text displayed near the marker.
---@field radius number|nil Outer marker radius in pixels.
---@field innerRadius number|nil Inner marker radius in pixels.
---@field badgeOffsetY number|nil Vertical offset for badge placement.
---@field fontRatio number|nil Text size multiplier relative to overlay font size.
---@field clampToScreen boolean|nil When true, marker is clamped to screen bounds.
---@class projectedWireframeCircleOptions
---@field color integer|nil Outline color for circle stroke.
---@field fillColor integer|nil Optional fill color for a projected fan.
---@field thickness number|nil Outline thickness in pixels.
---@field segments number|nil Number of circle segments (minimum 12).

local cubeEdgeVertices = {
    { 1, 2 }, { 2, 4 }, { 3, 4 }, { 1, 3 },
    { 5, 6 }, { 6, 8 }, { 7, 8 }, { 5, 7 },
    { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 }
}

local cubeFaceVertices = {
    { 1, 2, 4, 3 },
    { 1, 5, 6, 2 },
    { 7, 8, 6, 5 },
    { 3, 4, 8, 7 },
    { 2, 6, 8, 4 },
    { 1, 3, 7, 5 }
}

local cubeFaceEdges = {
    { 1, 2, 3, 4 },
    { 9, 5, 10, 1 },
    { 7, 6, 5, 8 },
    { 3, 12, 7, 11 },
    { 10, 6, 12, 2 },
    { 4, 11, 8, 9 }
}

---Clamps a numeric value to an inclusive range.
---@param value number Value to clamp.
---@param minValue number Lower bound.
---@param maxValue number Upper bound.
---@return number clamped
local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

---Extracts alpha channel from packed ARGB color.
---@param color integer Packed ARGB color.
---@return integer alpha Alpha channel in `[0, 255]`.
local function getAlpha(color)
    return math.floor(color / 0x1000000) % 0x100
end

---Replaces alpha channel on packed ARGB color.
---@param color integer Packed ARGB color.
---@param alpha number New alpha value.
---@return integer colorWithAlpha
local function withAlpha(color, alpha)
    local rgb = color % 0x1000000
    return clamp(math.floor(alpha + 0.5), 0, 255) * 0x1000000 + rgb
end

---Projects a world-space point to screen-space.
---@param screen projectedScreenContext Overlay projection context.
---@param point Vector4 World-space point.
---@return screenPoint|nil point Returns `nil` when projection fails.
local function projectWorldPoint(screen, point)
    local projected = Game.GetCameraSystem():ProjectPoint(point)
    if not projected then return nil end

    local w = projected.w or 1.0
    local x = projected.x
    local y = projected.y

    if w > 0.0 then
        x = x / w
        y = y / w
    end

    return {
        x = screen.centerX + (x * screen.centerX),
        y = screen.centerY - (y * screen.centerY),
        behind = w <= 0.0,
        visible = w > 0.0 and x >= -1.0 and x <= 1.0 and y >= -1.0 and y <= 1.0
    }
end

---Projects a world-space point and clamps to visible NDC range.
---Useful for keeping badges/markers near the screen edge.
---@param screen projectedScreenContext Overlay projection context.
---@param point Vector4 World-space point.
---@return screenPoint|nil point Returns `nil` when projection fails.
local function projectWorldPointClamped(screen, point)
    local projected = Game.GetCameraSystem():ProjectPoint(point)
    if not projected then return nil end

    local w = projected.w or 1.0
    local x = projected.x
    local y = projected.y

    if w > 0.0 then
        x = x / w
        y = y / w
    end

    x = clamp(x, -0.99, 0.99)
    y = clamp(y, -0.99, 0.99)

    return {
        x = screen.centerX + (x * screen.centerX),
        y = screen.centerY - (y * screen.centerY),
        behind = w <= 0.0
    }
end

---Formats a distance in meters for badge display.
---@param distance number Distance in meters.
---@return string label
local function formatDistance(distance)
    return ("%.1fm"):format(distance)
end

---Draws a circle marker on the ImGui draw list.
---When `thickness` is omitted, draws a filled circle.
---@param drawList table ImGui draw list.
---@param point screenPoint Screen-space center.
---@param color integer Packed ARGB color.
---@param radius number Radius in pixels.
---@param thickness number|nil Outline thickness for non-filled circle.
local function drawCircle(drawList, point, color, radius, thickness)
    if thickness == nil then
        ImGui.ImDrawListAddCircleFilled(drawList, point.x, point.y, radius, color, -1)
    else
        ImGui.ImDrawListAddCircle(drawList, point.x, point.y, radius, color, -1, thickness)
    end
end

---Draws a filled triangle in screen-space.
---@param drawList table ImGui draw list.
---@param triangle screenPoint[] Triangle vertices.
---@param color integer Packed ARGB color.
local function drawTriangle(drawList, triangle, color)
    ImGui.ImDrawListAddTriangleFilled(
        drawList,
        triangle[1].x, triangle[1].y,
        triangle[2].x, triangle[2].y,
        triangle[3].x, triangle[3].y,
        color
    )
end

---Draws a filled quad in screen-space.
---@param drawList table ImGui draw list.
---@param quad screenPoint[] Quad vertices in winding order.
---@param color integer Packed ARGB color.
local function drawQuad(drawList, quad, color)
    ImGui.ImDrawListAddQuadFilled(
        drawList,
        quad[1].x, quad[1].y,
        quad[2].x, quad[2].y,
        quad[3].x, quad[3].y,
        quad[4].x, quad[4].y,
        color
    )
end

---Draws a filled rounded rectangle.
---@param drawList table ImGui draw list.
---@param rect screenPoint[] Two corners `{min, max}`.
---@param color integer Packed ARGB color.
---@param radius number Corner radius in pixels.
local function drawRoundRect(drawList, rect, color, radius)
    ImGui.ImDrawListAddRectFilled(drawList, rect[1].x, rect[1].y, rect[2].x, rect[2].y, color, radius)
end

---Draws faux-bold text by rendering the label multiple times with sub-pixel offsets.
---@param drawList table ImGui draw list.
---@param position {x: number, y: number} Text anchor position.
---@param color integer Packed ARGB color.
---@param size number Font size in pixels.
---@param text string Text content.
local function drawTextBold(drawList, position, color, size, text)
    local content = tostring(text)

    -- Multi-pass slight offsets to emulate a bolder weight with the default font.
    local offset = 0.2
    ImGui.ImDrawListAddText(drawList, size, position.x + offset, position.y, color, content)
    ImGui.ImDrawListAddText(drawList, size, position.x, position.y + offset, color, content)
    ImGui.ImDrawListAddText(drawList, size, position.x + offset, position.y + offset, color, content)
    ImGui.ImDrawListAddText(drawList, size, position.x, position.y, color, content)
end

---Draws a rounded label badge near a screen-space origin point.
---@param drawList table ImGui draw list.
---@param screen projectedScreenContext Overlay projection context.
---@param origin {x: number, y: number} Screen-space anchor point.
---@param text string Label text to display.
---@param offsetX number|boolean|nil Horizontal anchor offset; non-number centers text around origin.
---@param offsetY number|boolean|nil Vertical anchor offset; non-number centers text around origin.
---@param badgeColor integer Packed ARGB color for badge background.
---@param textColor integer Packed ARGB color for label text.
---@param fontRatio number|nil Size multiplier relative to overlay font size.
local function drawBadge(drawList, screen, origin, text, offsetX, offsetY, badgeColor, textColor, fontRatio)
    fontRatio = fontRatio or 0.8

    local fontSize = screen.fontSize * fontRatio
    local textWidth, textHeight = ImGui.CalcTextSize(text)
    textWidth = textWidth * fontRatio
    textHeight = textHeight * fontRatio

    local position = { x = origin.x, y = origin.y }
    local paddingX = 5
    local paddingY = 2

    if type(offsetX) == "number" then
        position.x = position.x + (offsetX > 0 and offsetX or (offsetX - textWidth))
    else
        position.x = position.x - (textWidth / 2.0)
    end

    if type(offsetY) == "number" then
        position.y = position.y + (offsetY > 0 and offsetY or (offsetY - textHeight))
    else
        position.y = position.y - (textHeight / 2.0)
    end

    local label = { x = position.x, y = position.y - 1 }
    local badge = {
        { x = position.x - paddingX, y = position.y - paddingX },
        { x = position.x + paddingX + textWidth, y = position.y + paddingY + textHeight }
    }

    drawRoundRect(drawList, badge, badgeColor, 4)
    drawTextBold(drawList, label, textColor, fontSize, text)
end

---Builds a near clipping plane in front of the active first-person camera.
---@return projectedNearPlane nearPlane
local function buildNearPlane()
    local cameraTransform = GetPlayer():GetFPPCameraComponent():GetLocalToWorld()
    local forward = cameraTransform:GetRotation():GetForward()
    local origin = cameraTransform:GetTranslation()
    local nearDistance = 0.08

    return {
        normal = forward,
        point = utils.addVector(origin, utils.multVector(forward, nearDistance))
    }
end

---Intersects a line segment with a plane.
---@param a Vector4 Segment start point.
---@param b Vector4 Segment end point.
---@param plane projectedNearPlane Plane descriptor.
---@return Vector4|nil intersection Intersection point inside segment bounds.
local function intersectLineWithPlane(a, b, plane)
    local ab = utils.subVector(b, a)
    local denom = Vector4.Dot(plane.normal, ab)
    if math.abs(denom) < 0.0001 then return nil end

    local numer = Vector4.Dot(plane.normal, utils.subVector(plane.point, a))
    local t = numer / denom
    if t < 0 or t > 1 then return nil end

    return utils.addVector(a, utils.multVector(ab, t))
end

---Builds oriented box vertices in world-space from local min/max corners.
---@param position Vector4 Box center/world position.
---@param orientation Quaternion Box world orientation.
---@param minCorner Vector4 Local minimum corner.
---@param maxCorner Vector4 Local maximum corner.
---@return Vector4[] vertices
local function makeBoxVertices(position, orientation, minCorner, maxCorner)
    local vertices = {
        Vector4.new(minCorner.x, minCorner.y, minCorner.z, 0),
        Vector4.new(minCorner.x, minCorner.y, maxCorner.z, 0),
        Vector4.new(minCorner.x, maxCorner.y, minCorner.z, 0),
        Vector4.new(minCorner.x, maxCorner.y, maxCorner.z, 0),
        Vector4.new(maxCorner.x, minCorner.y, minCorner.z, 0),
        Vector4.new(maxCorner.x, minCorner.y, maxCorner.z, 0),
        Vector4.new(maxCorner.x, maxCorner.y, minCorner.z, 0),
        Vector4.new(maxCorner.x, maxCorner.y, maxCorner.z, 0)
    }

    for i, vertex in ipairs(vertices) do
        vertices[i] = utils.addVector(position, orientation:Transform(vertex))
    end

    return vertices
end

---Begins a full-screen no-input overlay window and returns projection helpers.
---@param windowId string|nil Optional ImGui window id.
---@return projectedScreenContext|nil screen Projection context, or `nil` when window cannot begin.
---@return table|nil drawList ImGui draw list matching the overlay window.
function projectedWireframe.beginOverlay(windowId)
    local width, height = GetDisplayResolution()
    ImGui.SetNextWindowPos(0, 0, ImGuiCond.Always)
    ImGui.SetNextWindowSize(width, height, ImGuiCond.Always)

    local flags = ImGuiWindowFlags.NoResize
        + ImGuiWindowFlags.NoMove
        + ImGuiWindowFlags.NoTitleBar
        + ImGuiWindowFlags.NoScrollbar
        + ImGuiWindowFlags.NoInputs
        + ImGuiWindowFlags.NoBackground
        + ImGuiWindowFlags.NoNav
        + ImGuiWindowFlags.NoFocusOnAppearing
        + ImGuiWindowFlags.NoBringToFrontOnFocus
        + ImGuiWindowFlags.NoSavedSettings

    if not ImGui.Begin(windowId or "##wb-wireframe-overlay-wui", flags) then
        ImGui.End()
        return nil, nil
    end

    local cameraTransform = GetPlayer():GetFPPCameraComponent():GetLocalToWorld()
    local screen = {
        width = width,
        height = height,
        centerX = width / 2,
        centerY = height / 2,
        fontSize = ImGui.GetFontSize(),
        nearPlane = buildNearPlane(),
        cameraWorld = cameraTransform:GetTranslation()
    }

    return screen, ImGui.GetWindowDrawList()
end

---Ends the overlay window started by `beginOverlay`.
function projectedWireframe.endOverlay()
    ImGui.End()
end

---Draws a projected world-space marker with optional badge text.
---@param drawList table ImGui draw list obtained from `beginOverlay`.
---@param screen projectedScreenContext Projection context obtained from `beginOverlay`.
---@param position Vector4 Marker world-space position.
---@param options projectedWireframeMarkerOptions|nil Rendering options.
---@return boolean drawn True when marker was projected and rendered.
function projectedWireframe.drawWorldMarker(drawList, screen, position, options)
    options = options or {}

    local markerColor = options.color or 0xFF0000FF
    local labelColor = options.labelColor or 0xFFDCD8D1
    local text = options.text
    local radius = options.radius or 5
    local innerRadius = options.innerRadius or math.max(1, radius * 0.6)
    local badgeOffsetY = options.badgeOffsetY or -12
    local fontRatio = options.fontRatio or 0.8
    local clampToScreen = options.clampToScreen ~= false

    local origin = clampToScreen and projectWorldPointClamped(screen, position) or projectWorldPoint(screen, position)
    if not origin or origin.behind then
        return false
    end

    drawCircle(drawList, origin, markerColor, radius)
    drawCircle(drawList, origin, labelColor, innerRadius)

    if text ~= nil and tostring(text) ~= "" then
        drawBadge(drawList, screen, origin, tostring(text), true, badgeOffsetY, markerColor, labelColor, fontRatio)
    end

    return true
end

---Draws a horizontal world-space circle projected to screen-space.
---Circle points are sampled on the XY plane at `center.z`.
---@param drawList table ImGui draw list obtained from `beginOverlay`.
---@param screen projectedScreenContext Projection context obtained from `beginOverlay`.
---@param center Vector4 Circle world-space center.
---@param radius number Circle radius in world units.
---@param options projectedWireframeCircleOptions|nil Rendering options.
---@return boolean drawn True when all circle points were projected and rendered.
function projectedWireframe.drawWorldCircle(drawList, screen, center, radius, options)
    options = options or {}

    radius = tonumber(radius) or 0
    if radius <= 0 then
        return false
    end

    local color = options.color or 0xFF00CC66
    local fillColor = options.fillColor
    local thickness = tonumber(options.thickness) or 2.0
    local segments = math.max(12, math.floor(tonumber(options.segments) or 48))

    local points = {}
    for i = 0, segments - 1 do
        local angle = (i / segments) * math.pi * 2
        local worldPoint = Vector4.new(
            center.x + math.cos(angle) * radius,
            center.y + math.sin(angle) * radius,
            center.z,
            center.w or 0
        )

        local projected = projectWorldPoint(screen, worldPoint)
        if not projected or projected.behind then
            return false
        end

        table.insert(points, projected)
    end

    if fillColor then
        for i = 2, #points - 1 do
            drawTriangle(drawList, { points[1], points[i], points[i + 1] }, fillColor)
        end
    end

    for i = 1, #points do
        local nextIndex = (i % #points) + 1
        ImGui.ImDrawListAddLine(
            drawList,
            points[i].x, points[i].y,
            points[nextIndex].x, points[nextIndex].y,
            color,
            thickness
        )
    end

    return true
end

---Draws an oriented 3D box projected to screen-space with edge/fill fading and distance badge.
---@param drawList table ImGui draw list obtained from `beginOverlay`.
---@param screen projectedScreenContext Projection context obtained from `beginOverlay`.
---@param position Vector4 Box center/world position.
---@param orientation Quaternion Box world orientation.
---@param minCorner Vector4 Local-space minimum corner.
---@param maxCorner Vector4 Local-space maximum corner.
---@param options projectedWireframeBoxOptions|nil Rendering options.
function projectedWireframe.drawOrientedBox(drawList, screen, position, orientation, minCorner, maxCorner, options)
    options = options or {}
    local frontColor = options.frontColor or 0xFF0000FF
    local backColor = options.backColor or withAlpha(frontColor, 0x55)
    local frontThickness = options.frontThickness or options.thickness or 1.5
    local backThickness = options.backThickness or math.max(1.0, frontThickness * 0.8)
    local showOriginDistance = options.showOriginDistance ~= false
    local originColor = options.originColor or frontColor
    local originDistance = options.originDistance
    local labelColor = options.labelColor or 0xFFDCD8D1
    local originBadgeOffsetY = options.originBadgeOffsetY or -12
    local fillColor = options.fillColor or withAlpha(frontColor, 0x16)
    local fillFadeLimit = options.fillFadeLimit or 0.65
    local minFillAlpha = options.minFillAlpha or 0x10
    local fadeNear = options.fadeNear or 45
    local fadeFar = options.fadeFar or 175
    local fadeLimit = options.fadeLimit or 0.8
    local minFrontAlpha = options.minFrontAlpha or 0x88
    local minBackAlpha = options.minBackAlpha or 0x44

    local vertices = makeBoxVertices(position, orientation, minCorner, maxCorner)
    local points = {}
    for i, vertex in ipairs(vertices) do
        local projected = projectWorldPoint(screen, vertex)
        if not projected then return end
        projected.id = i
        points[i] = projected
    end

    local clippings = {}
    local edges = {}

    for edgeId, indices in ipairs(cubeEdgeVertices) do
        local aIdx = indices[1]
        local bIdx = indices[2]
        local edge = {
            id = edgeId,
            indices = indices,
            points = { points[aIdx], points[bIdx] },
            vertices = { vertices[aIdx], vertices[bIdx] }
        }

        edge.behind = edge.points[1].behind and edge.points[2].behind

        if edge.points[1].behind ~= edge.points[2].behind then
            local backPos = edge.points[1].behind and 1 or 2
            local frontPos = 3 - backPos
            local backIndex = indices[backPos]
            local frontIndex = indices[frontPos]

            local clipped = intersectLineWithPlane(vertices[frontIndex], vertices[backIndex], screen.nearPlane)
            if clipped then
                local clippedPoint = projectWorldPoint(screen, clipped)
                edge.points[backPos] = clippedPoint
                clippings[backIndex] = clippings[backIndex] or {}
                clippings[backIndex][frontIndex] = clippedPoint
            else
                edge.behind = true
            end
        end

        edge.distance = Vector4.DistanceToEdge(screen.cameraWorld, edge.vertices[1], edge.vertices[2])
        edge.fading = clamp((edge.distance - fadeNear) / (fadeFar - fadeNear), 0, 1)
        table.insert(edges, edge)
    end

    local inside = true
    local faces = {}
    for faceId, indices in ipairs(cubeFaceVertices) do
        local facePoints = {}

        for b = 1, #indices do
            local a = b > 1 and b - 1 or #indices
            local c = b < #indices and b + 1 or 1

            local aIndex = indices[a]
            local bIndex = indices[b]
            local cIndex = indices[c]

            local abClip = clippings[bIndex] and clippings[bIndex][aIndex]
            local bcClip = clippings[bIndex] and clippings[bIndex][cIndex]

            if abClip then table.insert(facePoints, abClip) end
            if not points[bIndex].behind and (abClip ~= bcClip or not abClip) then
                table.insert(facePoints, points[bIndex])
            end
            if bcClip then table.insert(facePoints, bcClip) end
        end

        if #facePoints >= 3 then
            local a = Vector4.new(facePoints[1].x, facePoints[1].y, 0, 0)
            local b = Vector4.new(facePoints[2].x, facePoints[2].y, 0, 0)
            local c = Vector4.new(facePoints[3].x, facePoints[3].y, 0, 0)
            local ab = utils.subVector(b, a)
            local ac = utils.subVector(c, a)
            local normal = Vector4.Cross(ab, ac)
            local front = normal.z <= 0

            if front then
                inside = false
                for _, edgeId in ipairs(cubeFaceEdges[faceId]) do
                    edges[edgeId].front = true
                end
            end

            local faceDistance = math.huge
            for _, edgeId in ipairs(cubeFaceEdges[faceId]) do
                faceDistance = math.min(faceDistance, edges[edgeId].distance)
            end
            local faceFading = clamp((faceDistance - fadeNear) / (fadeFar - fadeNear), 0, 1)
            table.insert(faces, {
                front = front,
                points = facePoints,
                fading = faceFading
            })
        end
    end

    for _, face in ipairs(faces) do
        if face.front then
            local color = fillColor
            local baseAlpha = getAlpha(color)
            local fadedAlpha = clamp(baseAlpha * (1 - face.fading * fillFadeLimit), minFillAlpha, 0xFF)
            if not inside then
                color = withAlpha(color, fadedAlpha)
            end

            if #face.points >= 4 then
                drawQuad(drawList, { face.points[1], face.points[2], face.points[3], face.points[4] }, color)
                for i = 4, #face.points - 1 do
                    drawTriangle(drawList, { face.points[1], face.points[i], face.points[i + 1] }, color)
                end
            else
                drawTriangle(drawList, { face.points[1], face.points[2], face.points[3] }, color)
            end
        end
    end

    for _, edge in ipairs(edges) do
        if not edge.behind then
            local color = edge.front and frontColor or backColor
            if edge.fading then
                local baseAlpha = getAlpha(color)
                local minAlpha = edge.front and minFrontAlpha or minBackAlpha
                local fadedAlpha = clamp(baseAlpha * (1 - edge.fading * fadeLimit), minAlpha, 0xFF)
                if not inside then
                    color = withAlpha(color, fadedAlpha)
                end
            end

            ImGui.ImDrawListAddLine(
                drawList,
                edge.points[1].x, edge.points[1].y,
                edge.points[2].x, edge.points[2].y,
                color,
                edge.front and frontThickness or backThickness
            )
        end
    end

    if showOriginDistance then
        local origin = projectWorldPointClamped(screen, position)
        if origin and not origin.behind then
            local distance = originDistance or Vector4.Distance(screen.cameraWorld, position)
            drawCircle(drawList, origin, originColor, 5)
            drawCircle(drawList, origin, labelColor, 3)
            drawBadge(drawList, screen, origin, formatDistance(distance), true, originBadgeOffsetY, originColor, labelColor)
        end
    end
end

---Tests whether a point lies inside an axis-aligned streaming box given per-axis half-extents.
---@param point Vector4 Point to test.
---@param center Vector4 Center of the streaming box.
---@param extentX number Half-extent on X.
---@param extentY number Half-extent on Y.
---@param extentZ number Half-extent on Z.
---@return boolean inside True when point lies inside the box bounds.
function projectedWireframe.isInsideStreamingExtents(point, center, extentX, extentY, extentZ)
    return point.x >= (center.x - extentX) and point.x <= (center.x + extentX)
        and point.y >= (center.y - extentY) and point.y <= (center.y + extentY)
        and point.z >= (center.z - extentZ) and point.z <= (center.z + extentZ)
end

---Resolves streaming-range colors based on whether the player is inside the range.
---@param inside boolean True when the player is inside the streaming range.
---@return number color Wireframe edge color.
---@return number labelColor Label color used by overlay text.
function projectedWireframe.getStreamingThemeColors(inside)
    local wireframeColorStyle = settings.wireframeColorStyle or 1
    if wireframeColorStyle == 2 then
        return inside and 0xFF50FF50 or 0xFF5050FF, 0xFF000000
    end

    return inside and style.successColor or 0xFF0000B2, 0xFFDCD8D1
end

return projectedWireframe
