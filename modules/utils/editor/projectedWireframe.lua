local utils = require("modules/utils/utils")

local projectedWireframe = {}

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

local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function getAlpha(color)
    return math.floor(color / 0x1000000) % 0x100
end

local function withAlpha(color, alpha)
    local rgb = color % 0x1000000
    return clamp(math.floor(alpha + 0.5), 0, 255) * 0x1000000 + rgb
end

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

local function formatDistance(distance)
    return ("%.1fm"):format(distance)
end

local function drawCircle(drawList, point, color, radius, thickness)
    if thickness == nil then
        ImGui.ImDrawListAddCircleFilled(drawList, point.x, point.y, radius, color, -1)
    else
        ImGui.ImDrawListAddCircle(drawList, point.x, point.y, radius, color, -1, thickness)
    end
end

local function drawTriangle(drawList, triangle, color)
    ImGui.ImDrawListAddTriangleFilled(
        drawList,
        triangle[1].x, triangle[1].y,
        triangle[2].x, triangle[2].y,
        triangle[3].x, triangle[3].y,
        color
    )
end

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

local function drawRoundRect(drawList, rect, color, radius)
    ImGui.ImDrawListAddRectFilled(drawList, rect[1].x, rect[1].y, rect[2].x, rect[2].y, color, radius)
end

local function drawText(drawList, position, color, size, text)
    ImGui.ImDrawListAddText(drawList, size, position.x, position.y, color, tostring(text))
end

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
    drawText(drawList, label, textColor, fontSize, text)
    drawText(drawList, label, textColor, fontSize, text)
end

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

local function intersectLineWithPlane(a, b, plane)
    local ab = utils.subVector(b, a)
    local denom = Vector4.Dot(plane.normal, ab)
    if math.abs(denom) < 0.0001 then return nil end

    local numer = Vector4.Dot(plane.normal, utils.subVector(plane.point, a))
    local t = numer / denom
    if t < 0 or t > 1 then return nil end

    return utils.addVector(a, utils.multVector(ab, t))
end

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

    if not ImGui.Begin(windowId or "##projectedWireframeOverlay", flags) then
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

function projectedWireframe.endOverlay()
    ImGui.End()
end

---@param drawList any
---@param screen table
---@param position Vector4
---@param orientation Quaternion
---@param minCorner Vector4
---@param maxCorner Vector4
---@param options table?
function projectedWireframe.drawOrientedBox(drawList, screen, position, orientation, minCorner, maxCorner, options)
    options = options or {}
    local frontColor = options.frontColor or 0xFF0000FF
    local backColor = options.backColor or withAlpha(frontColor, 0x55)
    local frontThickness = options.frontThickness or options.thickness or 1.5
    local backThickness = options.backThickness or math.max(1.0, frontThickness * 0.8)
    local showOriginDistance = options.showOriginDistance ~= false
    local originColor = options.originColor or frontColor
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
            local distance = Vector4.Distance(screen.cameraWorld, position)
            drawCircle(drawList, origin, originColor, 5)
            drawCircle(drawList, origin, labelColor, 3)
            drawBadge(drawList, screen, origin, formatDistance(distance), true, originBadgeOffsetY, originColor, labelColor)
        end
    end
end

return projectedWireframe
