local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local cache = require("modules/utils/cache")
local builder = require("modules/utils/entityBuilder")
local Cron = require("modules/utils/Cron")
local history = require("modules/utils/history")
local settings = require("modules/utils/settings")

---Class for worldSplineNode
---@class spline : visualized
---@field splinePath string
---@field points table
---@field reverse boolean
---@field looped boolean
---@field protected maxPropertyWidth number
---@field previewCharacter string
---@field splineFollowerSpeed number
---@field splineFollower boolean
---@field npcID entEntityID
---@field npcSpawning boolean
---@field cronID number
---@field rigs table
---@field apps table
local spline = setmetatable({}, { __index = visualized })

function spline:new()
	local o = visualized.new(self)

    o.spawnListType = "files"
    o.dataType = "Spline"
    o.spawnDataPath = "data/spawnables/meta/Spline/"
    o.modulePath = "meta/spline"
    o.node = "worldSplineNode"
    o.description = "Basic spline with auto-tangents, which can be referenced using its NodeRef."
    o.icon = IconGlyphs.VectorPolyline

    o.previewed = true
    o.previewColor = "violet"
    o.splinePath = ""

    o.reverse = false
    o.looped = false
    o.points = {}
    o.pointDefs = {}

    o.previewCharacter = settings.defaultAISpotNPC or ""
    o.splineFollowerSpeed = settings.defaultAISpotSpeed or 1.0
    o.splineFollower = false

    o.maxPropertyWidth = nil
    o.npcID = nil
    o.npcSpawning = false
    o.cronID = nil
    o.rigs = {}
    o.apps = {}
    o.splineMoveType = "Walk"
    o.splineReachDistance = 0.85
    o._currentPointIndex = nil
    o.curvePreviewSamples = settings.defaultSplineCurveQuality or 12
    o.maxCurvePreviewComponents = 256
    o._curvePreviewComponentCount = 0

    setmetatable(o, { __index = self })
   	return o
end

function spline:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    self.previewCharacter = string.gsub(self.previewCharacter, "[\128-\255]", "")
    self.curvePreviewSamples = math.floor(math.max(8, math.min(24, self.curvePreviewSamples or 12)))

    self.pointDefs = {}
    if data.pointDefs and #data.pointDefs > 0 then
        for _, pointDef in ipairs(data.pointDefs) do
            local tangentIn = pointDef.tangentIn or { x = 0, y = 0, z = 0 }
            local tangentOut = pointDef.tangentOut or { x = 0, y = 0, z = 0 }
            table.insert(self.pointDefs, {
                position = pointDef.position or { x = 0, y = 0, z = 0 },
                tangentIn = tangentIn,
                tangentOut = tangentOut,
                automaticTangents = pointDef.automaticTangents == nil and true or pointDef.automaticTangents
            })
        end
    elseif data.points and #data.points > 0 then
        for _, point in ipairs(data.points) do
            table.insert(self.pointDefs, {
                position = point,
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            })
        end
    end

    if self.splinePath and self.splinePath ~= "" and self.splinePath ~= "None" then
        Cron.After(0.5, function()
            self:refreshLinkedMarkerTangents(self.looped)
            self:respawn()
        end)
    end
end

function spline:getVisualizerSize()
    return { x = 0.25, y = 0.25, z = 0.25 }
end

function spline:getNPC()
    if not self.npcID then return end

    return Game.GetDynamicEntitySystem():GetEntity(self.npcID)
end

function spline:getInterpolatedPosition(t)
    if #self.points == 0 then
        self:loadSplinePoints()
    end

    -- t ranges from 0 to 1
    if #self.points == 0 then
        return self.position
    end

    if #self.points == 1 then
        return self.points[1]
    end

    local points = {}
    for i = 1, #self.points do
        table.insert(points, self.points[i])
    end

    -- Calculate which segment t falls into
    local segmentCount = #points - 1
    local scaledT = t * segmentCount
    local segmentIndex = math.floor(scaledT) + 1
    local localT = scaledT - math.floor(scaledT)

    if self.looped and segmentIndex > segmentCount then
        segmentIndex = 1
        localT = 0
    end

    if segmentIndex > segmentCount then
        return points[#points]
    end

    local p0 = points[segmentIndex]
    local p1 = points[segmentIndex + 1]

    -- Linear interpolation between two points
    local interpolated = Vector4.new(
        p0.x + (p1.x - p0.x) * localT,
        p0.y + (p1.y - p0.y) * localT,
        p0.z + (p1.z - p0.z) * localT,
        0
    )

    return interpolated
end

function spline:getOrderedPoints()
    if #self.points == 0 then
        self:loadSplinePoints()
    end

    local ordered = {}
    for i = 1, #self.points do
        table.insert(ordered, self.points[i])
    end

    return ordered
end

function spline:hasCurveTangents(pointDefs)
    local function lengthSq(tab)
        return tab.x * tab.x + tab.y * tab.y + tab.z * tab.z
    end

    if not pointDefs or #pointDefs < 2 then
        return false
    end

    for i = 1, #pointDefs - 1 do
        local current = pointDefs[i]
        local nxt = pointDefs[i + 1]
        if current and nxt and (lengthSq(current.tangentOut) > 0.00000001 or lengthSq(nxt.tangentIn) > 0.00000001) then
            return true
        end
    end

    if self.looped then
        local last = pointDefs[#pointDefs]
        local first = pointDefs[1]
        if last and first and (lengthSq(last.tangentOut) > 0.00000001 or lengthSq(first.tangentIn) > 0.00000001) then
            return true
        end
    end

    return false
end

function spline:getFollowerPathPoints()
    local pointDefs = self:getFollowerPreviewSplineMarkerDefs()
    local function applyPreviewDirection(points)
        if not self.reverse then
            return points
        end

        local reversed = {}
        for i = #points, 1, -1 do
            table.insert(reversed, points[i])
        end

        return reversed
    end

    if #pointDefs == 0 then
        self:loadSplinePoints()
        local points = {}
        for i = 1, #self.points do
            table.insert(points, self.points[i])
        end
        return applyPreviewDirection(points)
    end

    if not self:hasCurveTangents(pointDefs) then
        local points = {}
        for _, pointDef in ipairs(pointDefs) do
            table.insert(points, utils.fromVector(pointDef.position))
        end
        return applyPreviewDirection(points)
    end

    local pathPoints = {}
    local samples = math.max(8, math.min(24, self.curvePreviewSamples or 12))

    local function sampleSegment(defA, defB)
        local p0 = defA.position
        local p1 = defB.position
        local c0 = utils.addVector(p0, Vector4.new(defA.tangentOut.x, defA.tangentOut.y, defA.tangentOut.z, 0))
        local c1 = utils.addVector(p1, Vector4.new(defB.tangentIn.x, defB.tangentIn.y, defB.tangentIn.z, 0))

        if #pathPoints == 0 then
            table.insert(pathPoints, utils.fromVector(p0))
        end

        for i = 1, samples do
            local t = i / samples
            table.insert(pathPoints, utils.fromVector(self:getBezierPoint(p0, c0, c1, p1, t)))
        end
    end

    for i = 1, #pointDefs - 1 do
        sampleSegment(pointDefs[i], pointDefs[i + 1])
    end

    if self.looped and #pointDefs > 1 then
        sampleSegment(pointDefs[#pointDefs], pointDefs[1])
    end

    return applyPreviewDirection(pathPoints)
end

function spline:refreshLinkedMarkerTangents(refreshEdgeTangents)
    local paths = self:loadSplinePaths()
    if utils.indexValue(paths, self.splinePath) == -1 then return end

    local splineGroup = self.object.sUI.getElementByPath(self.splinePath)
    if not splineGroup then return end

    local markers = {}
    for _, child in ipairs(splineGroup.childs) do
        if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
            table.insert(markers, child.spawnable)
        end
    end

    for _, marker in ipairs(markers) do
        -- Always refresh marker connector transforms when spline topology changes
        -- (e.g. looped on/off), otherwise the last->first straight segment can stay stale.
        marker:updateTransform(splineGroup)
    end

    if refreshEdgeTangents and #markers > 1 then
        local first = markers[1]
        local last = markers[#markers]

        if first and first.symmetricTangents then
            first:applyAutoTangents(splineGroup)
            first:updateTransform(splineGroup)
        end

        if last and last.symmetricTangents then
            last:applyAutoTangents(splineGroup)
            last:updateTransform(splineGroup)
        end
    end
end

function spline:buildMoveCommand(targetPos)
    local dest = NewObject("WorldPosition")
    dest:SetVector4(dest, ToVector4(targetPos))

    local positionSpec = NewObject("AIPositionSpec")
    positionSpec:SetWorldPosition(positionSpec, dest)

    local cmd = NewObject("handle:AIMoveToCommand")
    cmd.movementTarget = positionSpec
    cmd.rotateEntityTowardsFacingTarget = false
    cmd.ignoreNavigation = false
    cmd.desiredDistanceFromTarget = self.splineReachDistance
    cmd.movementType = self.splineMoveType
    cmd.finishWhenDestinationReached = true

    return cmd
end

function spline:sendMoveCommand(npc, targetPos)
    if not npc then return false end
    local aiController = npc:GetAIControllerComponent()
    if not aiController then return false end

    aiController:SendCommand(self:buildMoveCommand(targetPos))
    return true
end

function spline:loadSplinePoints()
    self.points = {}
    local paths = self:loadSplinePaths()

    if utils.indexValue(paths, self.splinePath) ~= -1 then
        local splineGroup = self.object.sUI.getElementByPath(self.splinePath)
        if splineGroup then
            for _, child in pairs(splineGroup.childs) do
                if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
                    table.insert(self.points, utils.fromVector(child.spawnable.position))
                end
            end
        end
    end
end

function spline:collectSplineMarkerDefs()
    local defs = {}
    if not self.splinePath or self.splinePath == "" or self.splinePath == "None" then
        return defs
    end

    local splineGroup = self.object.sUI.getElementByPath(self.splinePath)
    if not splineGroup then
        return defs
    end

    for _, child in ipairs(splineGroup.childs) do
        if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
            local marker = child.spawnable
            local saved = marker.spawnData or {}
            local tangentIn = marker.tangentIn or saved.tangentIn or { x = 0, y = 0, z = 0 }
            local tangentOut = marker.tangentOut or saved.tangentOut or { x = 0, y = 0, z = 0 }

            table.insert(defs, {
                position = marker.position,
                tangentIn = {
                    x = tonumber(tangentIn.x) or 0,
                    y = tonumber(tangentIn.y) or 0,
                    z = tonumber(tangentIn.z) or 0
                },
                tangentOut = {
                    x = tonumber(tangentOut.x) or 0,
                    y = tonumber(tangentOut.y) or 0,
                    z = tonumber(tangentOut.z) or 0
                },
                automaticTangents = marker.automaticTangents == nil and true or marker.automaticTangents
            })
        end
    end

    return defs
end

function spline:getSplineMarkerDefs()
    return self:collectSplineMarkerDefs()
end

function spline:getFollowerPreviewSplineMarkerDefs()
    local defs = self:collectSplineMarkerDefs()
    if #defs == 0 then
        return defs
    end

    return self:buildPreviewSplineMarkerDefs(defs)
end

function spline:buildPreviewSplineMarkerDefs(defs)
    if #defs == 0 then
        return defs
    end

    local function toV4(tab)
        return Vector4.new(tab.x, tab.y, tab.z, 0)
    end

    local function toTable(v)
        return { x = v.x, y = v.y, z = v.z }
    end

    local previewDefs = utils.deepcopy(defs)

    for i, def in ipairs(previewDefs) do
        if def.automaticTangents then
            local prevIndex = i - 1
            local nextIndex = i + 1
            local prev = previewDefs[prevIndex]
            local nxt = previewDefs[nextIndex]

            if self.looped then
                if not prev then prev = previewDefs[#previewDefs] end
                if not nxt then nxt = previewDefs[1] end
            end

            local currentPos = toV4(def.position)
            local tangent = Vector4.new(0, 0, 0, 0)

            if prev and nxt then
                tangent = utils.subVector(toV4(nxt.position), toV4(prev.position))
                tangent = Vector4.new(tangent.x / 6, tangent.y / 6, tangent.z / 6, 0)
            elseif nxt then
                tangent = utils.subVector(toV4(nxt.position), currentPos)
                tangent = Vector4.new(tangent.x / 3, tangent.y / 3, tangent.z / 3, 0)
            elseif prev then
                tangent = utils.subVector(currentPos, toV4(prev.position))
                tangent = Vector4.new(tangent.x / 3, tangent.y / 3, tangent.z / 3, 0)
            end

            def.tangentIn = toTable(Vector4.new(-tangent.x, -tangent.y, -tangent.z, 0))
            def.tangentOut = toTable(tangent)
        end
    end

    return previewDefs
end

function spline:getPreviewSplineMarkerDefs()
    local defs = self:getSplineMarkerDefs()
    return self:buildPreviewSplineMarkerDefs(defs)
end

function spline:getBezierPoint(p0, c0, c1, p1, t)
    local u = 1 - t
    local uu = u * u
    local uuu = uu * u
    local tt = t * t
    local ttt = tt * t

    return Vector4.new(
        uuu * p0.x + 3 * uu * t * c0.x + 3 * u * tt * c1.x + ttt * p1.x,
        uuu * p0.y + 3 * uu * t * c0.y + 3 * u * tt * c1.y + ttt * p1.y,
        uuu * p0.z + 3 * uu * t * c0.z + 3 * u * tt * c1.z + ttt * p1.z,
        0
    )
end

function spline:getCurvePreviewComponent(index)
    local entity = self:getEntity()
    if not entity then return end

    local name = "curvePreview" .. tostring(index)
    local component = entity:FindComponentByName(name)
    if component then
        return component
    end

    component = entMeshComponent.new()
    component.name = name
    component.mesh = ResRef.FromString("base\\spawner\\cube_aligned.mesh")
    component.meshAppearance = self.previewColor or "violet"
    component.visualScale = Vector3.new(0.005, 0.005, 0.005)
    component.isEnabled = self.previewed
    entity:AddComponent(component)

    return component
end

function spline:getCurvePreviewSampling(pointDefs)
    local segmentCount = #pointDefs - 1
    if self.looped and #pointDefs > 1 then
        segmentCount = segmentCount + 1
    end

    local requestedSamples = math.floor(math.max(8, math.min(24, self.curvePreviewSamples or 12)))
    local maxComponents = math.max(1, self.maxCurvePreviewComponents or 256)
    local maxSamplesPerSegment = math.max(1, math.floor(maxComponents / math.max(1, segmentCount)))
    local samples = math.max(1, math.min(requestedSamples, maxSamplesPerSegment))

    return samples
end

function spline:renderCurveSegmentLine(startPos, endPos, index)
    local diff = utils.subVector(endPos, startPos)
    local length = diff:Length()
    if length <= 0.0001 then
        return false
    end

    local line = self:getCurvePreviewComponent(index)
    if not line then return false end

    local localStart = utils.subVector(startPos, self.position)
    local yaw = diff:ToRotation().yaw + 90
    local roll = diff:ToRotation().pitch

    line.visualScale = Vector3.new(math.max(0.0001, length / 2), 0.01, 0.01)
    line:SetLocalOrientation(EulerAngles.new(roll, 0, yaw):ToQuat())
    line:SetLocalPosition(Vector4.new(localStart.x, localStart.y, localStart.z, 0))
    line:Toggle(self.previewed)
    line:RefreshAppearance()

    return true
end

function spline:drawBezierPreviewSegment(defA, defB, samples, used)
    local p0 = defA.position
    local p1 = defB.position
    local c0 = utils.addVector(p0, Vector4.new(defA.tangentOut.x, defA.tangentOut.y, defA.tangentOut.z, 0))
    local c1 = utils.addVector(p1, Vector4.new(defB.tangentIn.x, defB.tangentIn.y, defB.tangentIn.z, 0))
    local prev = p0

    for i = 1, samples do
        local t = i / samples
        local current = self:getBezierPoint(p0, c0, c1, p1, t)
        local nextUsed = used + 1
        if self:renderCurveSegmentLine(prev, current, nextUsed) then
            used = nextUsed
        end
        prev = current
    end

    return used
end

function spline:updateCurvePreview()
    local entity = self:getEntity()
    if not entity then return end

    local pointDefs = self:getPreviewSplineMarkerDefs()
    local samples = self:getCurvePreviewSampling(pointDefs)
    local used = 0

    if #pointDefs > 1 then
        for i = 1, #pointDefs - 1 do
            used = self:drawBezierPreviewSegment(pointDefs[i], pointDefs[i + 1], samples, used)
        end

        if self.looped then
            used = self:drawBezierPreviewSegment(pointDefs[#pointDefs], pointDefs[1], samples, used)
        end
    end

    for i = used + 1, self._curvePreviewComponentCount do
        local line = entity:FindComponentByName("curvePreview" .. tostring(i))
        if line then
            line:Toggle(false)
        end
    end

    self._curvePreviewComponentCount = math.max(self._curvePreviewComponentCount, used)
end

function spline:onNPCSpawned(npc)
    -- Ensure we have a valid character record, fallback to saved default if current is empty
    if not self.previewCharacter or not self.previewCharacter:match("^Character.") then
        self.previewCharacter = settings.defaultAISpotNPC or ""
        if not self.previewCharacter or not self.previewCharacter:match("^Character.") then
            return
        end
    end

    local points = self:getFollowerPathPoints()
    if #points == 0 then return end

    npc:SetIndividualTimeDilation("", self.splineFollowerSpeed)

    if #points == 1 then
        Game.GetTeleportationFacility():Teleport(npc, ToVector4(points[1]), EulerAngles.new(0, 0, 0))
        return
    end

    -- Start at the first marker, then move marker-to-marker using AI navigation.
    Game.GetTeleportationFacility():Teleport(npc, ToVector4(points[1]), EulerAngles.new(0, 0, 0))
    self._currentPointIndex = 2
    self:sendMoveCommand(npc, points[self._currentPointIndex])
    self._activeTargetPos = utils.fromVector(ToVector4(points[self._currentPointIndex]))

    self.cronID = Cron.Every(0.1, function()
        if not self.npcID or not self:isSpawned() or not self.splineFollower then return end

        local follower = self:getNPC()
        if not follower then return end

        local ordered = self:getFollowerPathPoints()
        if #ordered < 2 then return end

        if not self._currentPointIndex then
            self._currentPointIndex = 2
        end

        if self._currentPointIndex > #ordered then
            if self.looped then
                self._currentPointIndex = 1
            else
                self._currentPointIndex = #ordered
                return
            end
        end

        local target = ordered[self._currentPointIndex]
        if not target then return end

        if not self._activeTargetPos or utils.distanceVector(self._activeTargetPos, target) > 0.01 then
            self:sendMoveCommand(follower, target)
            self._activeTargetPos = utils.fromVector(ToVector4(target))
        end

        if utils.distanceVector(follower:GetWorldPosition(), target) <= self.splineReachDistance then
            self._currentPointIndex = self._currentPointIndex + 1

            if self._currentPointIndex > #ordered then
                if self.looped then
                    self._currentPointIndex = 1
                else
                    self._currentPointIndex = #ordered
                    return
                end
            end

            self:sendMoveCommand(follower, ordered[self._currentPointIndex])
            self._activeTargetPos = utils.fromVector(ToVector4(ordered[self._currentPointIndex]))
        end
    end)
end

function spline:onAssemble(entity)
    visualized.onAssemble(self, entity)
    self:updateCurvePreview()

    if not self.splineFollower then return end

    local points = self:getFollowerPathPoints()
    local spawnPos = self.position
    if #points > 0 then
        spawnPos = ToVector4(points[1])
    end

    local spec = DynamicEntitySpec.new()
    spec.recordID = self.previewCharacter
    spec.position = spawnPos
    spec.orientation = EulerAngles.new(0, 0, 0):ToQuat()
    spec.alwaysSpawned = true
    self.npcID = Game.GetDynamicEntitySystem():CreateEntity(spec)
    self.npcSpawning = true

    builder.registerAttachCallback(self.npcID, function(entity)
        self:onNPCSpawned(entity)
    end)

    cache.tryGet(self.previewCharacter .. "_apps")
    .notFound(function(task)
        builder.registerLoadResource(ResRef.FromHash(TweakDB:GetFlat(self.previewCharacter .. ".entityTemplatePath").hash), function(resource)
            local apps = {}
            for _, appearance in ipairs(resource.appearances) do
                table.insert(apps, appearance.name.value)
            end

            cache.addValue(self.previewCharacter .. "_apps", apps)
            task:taskCompleted()
        end)
    end)
    .found(function()
        self.apps = cache.getValue(self.previewCharacter .. "_apps")
    end)
end

function spline:despawn()
    visualized.despawn(self)

    if self.cronID then
        Cron.Halt(self.cronID)
        self.cronID = nil
    end

    if not self.npcID then return end

    Game.GetDynamicEntitySystem():DeleteEntity(self.npcID)
    self.npcID = nil
    self.npcSpawning = false
    self._currentPointIndex = nil
    self._activeTargetPos = nil
end

function spline:spawn()
    self.rotation = EulerAngles.new(0, 0, 0)
    visualized.spawn(self)
end

function spline:update()
    self.rotation = EulerAngles.new(0, 0, 0)
    visualized.update(self)
    self:updateCurvePreview()
end

function spline:setPreview(state)
    visualized.setPreview(self, state)
    self:updateCurvePreview()
end

function spline:save()
    local data = visualized.save(self)

    local pointDefs = self:getSplineMarkerDefs()
    if #pointDefs == 0 and self.pointDefs and #self.pointDefs > 0 then
        pointDefs = utils.deepcopy(self.pointDefs)
    end
    if #pointDefs == 0 and self.points and #self.points > 0 then
        for _, point in ipairs(self.points) do
            table.insert(pointDefs, {
                position = point,
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            })
        end
    end

    local points = {}
    local savedPointDefs = {}
    for _, pointDef in ipairs(pointDefs) do
        local position = utils.fromVector(pointDef.position)
        local tangentIn = pointDef.tangentIn or { x = 0, y = 0, z = 0 }
        local tangentOut = pointDef.tangentOut or { x = 0, y = 0, z = 0 }

        table.insert(points, position)
        table.insert(savedPointDefs, {
            position = position,
            tangentIn = {
                x = tonumber(tangentIn.x) or 0,
                y = tonumber(tangentIn.y) or 0,
                z = tonumber(tangentIn.z) or 0
            },
            tangentOut = {
                x = tonumber(tangentOut.x) or 0,
                y = tonumber(tangentOut.y) or 0,
                z = tonumber(tangentOut.z) or 0
            },
            automaticTangents = pointDef.automaticTangents == nil and true or pointDef.automaticTangents
        })
    end

    data.splinePath = self.splinePath
    data.points = points
    data.pointDefs = savedPointDefs
    data.reverse = self.reverse
    data.looped = self.looped
    data.previewCharacter = self.previewCharacter
    data.splineFollowerSpeed = self.splineFollowerSpeed
    data.splineFollower = self.splineFollower
    data.splineMoveType = self.splineMoveType
    data.curvePreviewSamples = self.curvePreviewSamples

    return data
end

function spline:loadSplinePaths()
    local paths = {}
    local ownRoot = self.object:getRootParent()

    for _, container in pairs(self.object.sUI.containerPaths) do
        if container.ref:getRootParent() == ownRoot then
            local nMarkers = 0
            for _, child in pairs(container.ref.childs) do
                if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
                    nMarkers = nMarkers + 1
                end

                if nMarkers == 2 then
                    table.insert(paths, container.path)
                    break
                end
            end
        end
    end

    return paths
end

function spline:draw()
    visualized.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize position", "Curve Quality", "Spline Path", "Reverse", "Looped", "Preview NPC", "Preview NPC Record", "Movement Type", "Movement Speed" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    local paths = self:loadSplinePaths()
    table.insert(paths, 1, "None")

    local index = math.max(1, utils.indexValue(paths, self.splinePath))

    style.mutedText("Spline Path")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local idx, changed = style.trackedCombo(self.object, "##splinePath", index - 1, paths, 225)
    if changed then
        self.splinePath = paths[idx + 1]
        self:respawn()
    end
    style.tooltip("Path to the group containing the spline points.\nMust be contained within the same root group as this spline.")

    style.mutedText("Reverse")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local changed
    self.reverse, changed = style.trackedCheckbox(self.object, "##reverse", self.reverse)
    if changed then
        self:updateCurvePreview()
        if self.splineFollower then
            self:respawn()
        end
    end

    style.mutedText("Looped")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.looped, changed = style.trackedCheckbox(self.object, "##looped", self.looped)
    if changed then
        self:refreshLinkedMarkerTangents(true)
        self:respawn()
    end

    if ImGui.TreeNodeEx("Previewing Options", ImGuiTreeNodeFlags.SpanFullWidth) then
        local previewPropertyWidth = self.maxPropertyWidth + ImGui.GetTreeNodeToLabelSpacing()

        self:drawPreviewCheckbox("Visualize Spline", previewPropertyWidth)

        style.mutedText("Curve Quality")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        local finished
        self.curvePreviewSamples, changed, finished = style.trackedDragInt(self.object, "##curvePreviewSamples", self.curvePreviewSamples, 8, 24, 60)
        style.tooltip("Number of curve samples per segment for preview drawing.")
        if changed then
            self:updateCurvePreview()
        end
        if finished then
            self:respawn()
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        ImGui.PushID("saveCurveQuality")
        if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
            settings.defaultSplineCurveQuality = self.curvePreviewSamples
            settings.save()
        end
        ImGui.PopID()
        style.tooltip("Save this curve quality as the default for Spline previews.")
        style.pushButtonNoBG(false)

        style.mutedText("Preview NPC")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.splineFollower, changed = style.trackedCheckbox(self.object, "##splineFollower", self.splineFollower)
        if changed then
            self:respawn()
        end

        style.mutedText("Preview NPC Record")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.previewCharacter, _, finished = style.trackedTextField(self.object, "##previewCharacter", self.previewCharacter, "Character.", 200)
        if finished then
            self:respawn()
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
            settings.defaultAISpotNPC = self.previewCharacter
            settings.save()
        end
        style.tooltip("Save this character as the default for Spline previews.")
        style.pushButtonNoBG(false)

        if self.splineFollower then
            local npc = self:getNPC()
            local isNPC = self.previewCharacter:match("^Character.")

            if isNPC then
                local movementTypes = { "Walk", "Sprint" }
                local moveTypeIndex = math.max(1, utils.indexValue(movementTypes, self.splineMoveType))
                style.mutedText("Movement Type")
                ImGui.SameLine()
                ImGui.SetCursorPosX(previewPropertyWidth)
                local moveIdx
                moveIdx, changed = style.trackedCombo(self.object, "##splineMoveType", moveTypeIndex - 1, movementTypes, 120)
                if changed then
                    self.splineMoveType = movementTypes[moveIdx + 1]
                    self:respawn()
                end

                style.mutedText("Movement Speed")
                ImGui.SameLine()
                ImGui.SetCursorPosX(previewPropertyWidth)
                self.splineFollowerSpeed, changed, _ = style.trackedDragFloat(self.object, "##splineFollowerSpeed", self.splineFollowerSpeed, 0.1, 0, 5, "%.2f", 60)
                style.tooltip("Speed of the character movement along the spline. Preview only.")
                if changed and npc then
                    npc:SetIndividualTimeDilation("", self.splineFollowerSpeed)
                end
                ImGui.SameLine()
                style.pushButtonNoBG(true)

                ImGui.PushID("saveSpeed")
                if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
                    settings.defaultAISpotSpeed = self.splineFollowerSpeed
                    settings.save()
                end
                ImGui.PopID()

                style.tooltip("Save this speed as the default for Spline previews.")
                style.pushButtonNoBG(false)
            end
        end

        ImGui.TreePop()
    end
end

function spline:getProperties()
    local properties = visualized.getProperties(self)
    table.insert(properties, {
        id = self.node,
        name = self.dataType,
        defaultHeader = true,
        draw = function()
            self:draw()
        end
    })
    return properties
end

function spline:export()
    local data = visualized.export(self)
    data.type = "worldSplineNode"
    data.data = {}

    local pointDefs = {}
    if self.pointDefs and #self.pointDefs > 0 then
        pointDefs = utils.deepcopy(self.pointDefs)
    elseif self.points and #self.points > 0 then
        for _, point in pairs(self.points) do
            table.insert(pointDefs, {
                position = point,
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            })
        end
    end

    if #pointDefs == 0 then
        table.insert(self.object.sUI.spawner.baseUI.exportUI.exportIssues.noSplineMarker, self.object.name)

        return data
    end

    local points = {}

    for _, pointDef in pairs(pointDefs) do
        local position = utils.subVector(ToVector4(pointDef.position), self.position)
        local tangentIn = pointDef.tangentIn or { x = 0, y = 0, z = 0 }
        local tangentOut = pointDef.tangentOut or { x = 0, y = 0, z = 0 }
        local automaticTangents = pointDef.automaticTangents == nil and true or pointDef.automaticTangents

        table.insert(points, {
            ["$type"] = "SplinePoint",
            ["position"] = {
                ["$type"] = "Vector3",
                ["X"] = position.x,
                ["Y"] = position.y,
                ["Z"] = position.z
            },
            ["automaticTangents"] = automaticTangents and 1 or 0,
            ["tangents"] = {
                ["Elements"] = {
                    {
                        ["$type"] = "Vector3",
                        ["X"] = tonumber(tangentIn.x) or 0,
                        ["Y"] = tonumber(tangentIn.y) or 0,
                        ["Z"] = tonumber(tangentIn.z) or 0
                    },
                    {
                        ["$type"] = "Vector3",
                        ["X"] = tonumber(tangentOut.x) or 0,
                        ["Y"] = tonumber(tangentOut.y) or 0,
                        ["Z"] = tonumber(tangentOut.z) or 0
                    }
                }
            }
        })
    end

    data.data = {
        ["splineData"] = {
            ["Data"] = {
                ["$type"] = "Spline",
                ["points"] = points,
                ["reversed"] = self.reverse and 1 or 0,
                ["looped"] = self.looped and 1 or 0
            }
        }
    }

    return data
end

return spline
