local connectedMarker = require("modules/classes/spawn/connectedMarker")
local spawnable = require("modules/classes/spawn/spawnable")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
local visualizer = require("modules/utils/visualizer")

---Class for outline marker (Not a node, meta class used for area nodes)
---@class outlineMarker : connectedMarker
---@field private height number
---@field private dragBeingEdited boolean
---@field private heightZLocked boolean
local outlineMarker = setmetatable({}, { __index = connectedMarker })
local boundaryOrientationCacheByRoot = setmetatable({}, { __mode = "k" })

local function normalizeYaw(value)
    if value == nil then
        return nil
    end

    return ((value % 360) + 360) % 360
end

local function getBoundaryOrientationMap(root, sUI)
    if not root or not root.getPathsRecursive then
        return {}
    end

    local stamp = string.format("%s:%s", tostring(sUI and sUI.cacheEpoch or 0), tostring(sUI and sUI.boundaryOrientationEpoch or 0))
    local cached = boundaryOrientationCacheByRoot[root]
    if cached and cached.stamp == stamp then
        return cached.map
    end

    local grouped = {}
    for _, entry in ipairs(root:getPathsRecursive(false)) do
        if utils.isA(entry.ref, "spawnableElement") and entry.ref.spawnable and entry.ref.spawnable.modulePath == "area/worldBoundary" then
            local outlinePath = entry.ref.spawnable.outlinePath
            if outlinePath and outlinePath ~= "" and outlinePath ~= "None" then
                local yaw = tonumber(entry.ref.spawnable.orientation)

                yaw = normalizeYaw(yaw)
                if yaw ~= nil then
                    local bucket = grouped[outlinePath]
                    if not bucket then
                        grouped[outlinePath] = { yaw = yaw, ambiguous = false }
                    else
                        local delta = math.abs(bucket.yaw - yaw)
                        if math.min(delta, 360 - delta) > 0.0001 then
                            bucket.ambiguous = true
                        end
                    end
                end
            end
        end
    end

    local resolved = {}
    for path, bucket in pairs(grouped) do
        if not bucket.ambiguous then
            resolved[path] = bucket.yaw
        end
    end

    boundaryOrientationCacheByRoot[root] = {
        stamp = stamp,
        map = resolved
    }

    return resolved
end

function outlineMarker:new()
	local o = connectedMarker.new(self)

    o.spawnListType = "files"
    o.dataType = "Outline Marker"
    o.spawnDataPath = "data/spawnables/area/outlineMarker/"
    o.modulePath = "area/outlineMarker"
    o.node = "---"
    o.description = "Places a marker for an outline. Automatically connects with other outline markers in the same group, to form an outline. The parent group can be used to reference the contained outline, and use it in worldAreaShapeNode's"
    o.icon = IconGlyphs.SelectMarker

    o.height = 2
    o.dragBeingEdited = false
    o.heightZLocked = false
    o.previewText = "Preview Outline"

    setmetatable(o, { __index = self })
   	return o
end

function outlineMarker:midAssemble()
    self:inheritLinkedState(self.object and self.object.parent or nil)
    self:enforceSameZ()
    self:setPreview(self.previewed)
end

function outlineMarker:onParentChanged(oldParent)
    self:inheritLinkedState(self.object and self.object.parent or nil)
    connectedMarker.onParentChanged(self, oldParent)
    self:setPreview(self.previewed)
end

function outlineMarker:save()
    local data = connectedMarker.save(self)

    data.height = self.height
    data.heightZLocked = self.heightZLocked

    return data
end

function outlineMarker:update()
    self.rotation = EulerAngles.new(0, 0, 0)
    local parent = self.object and self.object.parent or nil
    local orientationYaw = self:getLinkedBoundaryOrientation(parent)

    self:enforceSameZ()
    self:updateTransform(parent, orientationYaw)
    self:updateHeight()

    for _, neighbor in pairs(self:getNeighbors().neighbors) do
        neighbor:updateTransform(neighbor.object.parent, orientationYaw)
        neighbor.height = self.height
        neighbor:updateHeight()
    end
end

function outlineMarker:getNeighbors(parent)
    parent = parent or self.object.parent
    if not parent or not parent.childs then
        return { neighbors = {}, selfIndex = 1, previous = nil, nxt = nil }
    end

    local neighbors = {}
    local selfIndex = 0

    for _, entry in ipairs(parent.childs) do
        if utils.isA(entry, "spawnableElement") and entry.spawnable.modulePath == self.modulePath and entry ~= self.object then
            table.insert(neighbors, entry.spawnable)
        elseif entry == self.object then
            selfIndex = #neighbors + 1
        end
    end

    local previous = selfIndex == 1 and neighbors[#neighbors] or neighbors[selfIndex - 1]
    local nxt = selfIndex > #neighbors and neighbors[1] or neighbors[selfIndex]

    return { neighbors = neighbors, selfIndex = selfIndex, previous = previous, nxt = nxt }
end

---@private
---@param parent element?
---@return outlineMarker[], integer
function outlineMarker:getOrderedMarkers(parent)
    parent = parent or self.object.parent
    if not parent or not parent.childs then
        return {}, -1
    end

    local markers = {}
    local selfIndex = -1

    for _, child in ipairs(parent.childs) do
        if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == self.modulePath then
            table.insert(markers, child.spawnable)
            if child == self.object then
                selfIndex = #markers
            end
        end
    end

    return markers, selfIndex
end

---@private
---@param parent element?
---@return number?
function outlineMarker:getLinkedBoundaryOrientation(parent)
    parent = parent or self.object.parent
    if not parent or not self.object or not self.object.getRootParent then
        return nil
    end

    local outlinePath = parent.getPath and parent:getPath() or nil
    if not outlinePath then
        return nil
    end

    local root = self.object:getRootParent()
    if not root then
        return nil
    end

    local map = getBoundaryOrientationMap(root, self.object.sUI)
    return map[outlinePath]
end

---@private
---@param markers outlineMarker[]
---@param point table { x:number, y:number }
---@return boolean
function outlineMarker:isPointInsidePolygon(markers, point)
    if #markers < 3 then
        return false
    end

    local inside = false
    local j = #markers

    for i = 1, #markers do
        local xi = markers[i].position.x
        local yi = markers[i].position.y
        local xj = markers[j].position.x
        local yj = markers[j].position.y

        if (yi > point.y) ~= (yj > point.y) then
            local denom = yj - yi
            if math.abs(denom) < 0.0000001 then
                denom = denom >= 0 and 0.0000001 or -0.0000001
            end

            local xOnEdge = ((xj - xi) * (point.y - yi) / denom) + xi
            if point.x < xOnEdge then
                inside = not inside
            end
        end

        j = i
    end

    return inside
end

---@private
---@param markers outlineMarker[]
---@return number, number
function outlineMarker:getPolygonCenter2D(markers)
    local centerX = 0
    local centerY = 0

    if #markers == 0 then
        return 0, 0
    end

    for _, marker in ipairs(markers) do
        centerX = centerX + marker.position.x
        centerY = centerY + marker.position.y
    end

    return centerX / #markers, centerY / #markers
end

---@private
---@param markers outlineMarker[]
---@param selfIndex integer
---@param edgeX number
---@param edgeY number
---@param edgeLen number
---@return number, number
function outlineMarker:getEdgeOutwardNormal(markers, selfIndex, edgeX, edgeY, edgeLen)
    local midX = (self.position.x + markers[selfIndex % #markers + 1].position.x) * 0.5
    local midY = (self.position.y + markers[selfIndex % #markers + 1].position.y) * 0.5
    local normalAX = edgeY / edgeLen
    local normalAY = -edgeX / edgeLen
    local normalBX = -normalAX
    local normalBY = -normalAY
    local epsilon = math.max(0.05, math.min(1.5, edgeLen * 0.1))

    -- Pick the normal whose offset sample point is outside the polygon.
    for _ = 1, 4 do
        local sampleAInside = self:isPointInsidePolygon(markers, {
            x = midX + normalAX * epsilon,
            y = midY + normalAY * epsilon
        })
        local sampleBInside = self:isPointInsidePolygon(markers, {
            x = midX + normalBX * epsilon,
            y = midY + normalBY * epsilon
        })

        if sampleAInside ~= sampleBInside then
            if sampleAInside then
                return normalBX, normalBY
            end

            return normalAX, normalAY
        end

        epsilon = epsilon * 2
    end

    -- Fallback for ambiguous/self-intersecting outlines: prefer the normal pointing away from polygon center.
    local centerX, centerY = self:getPolygonCenter2D(markers)
    local toEdgeX = midX - centerX
    local toEdgeY = midY - centerY
    local dotA = normalAX * toEdgeX + normalAY * toEdgeY
    local dotB = normalBX * toEdgeX + normalBY * toEdgeY

    if dotA >= dotB then
        return normalAX, normalAY
    end

    return normalBX, normalBY
end

---@private
---@param parent element?
---@param orientationYawOverride number?
---@return boolean
function outlineMarker:isExternalFace(parent, orientationYawOverride)
    local orientationYaw = normalizeYaw(orientationYawOverride)
    if orientationYaw == nil then
        orientationYaw = self:getLinkedBoundaryOrientation(parent)
    end
    if orientationYaw == nil then
        return false
    end

    local markers, selfIndex = self:getOrderedMarkers(parent)
    if #markers < 2 or selfIndex < 1 then
        return false
    end

    local nextMarker = markers[selfIndex % #markers + 1]
    if not nextMarker then
        return false
    end

    local edgeX = nextMarker.position.x - self.position.x
    local edgeY = nextMarker.position.y - self.position.y
    local edgeLen = math.sqrt(edgeX * edgeX + edgeY * edgeY)
    if edgeLen < 0.00001 then
        return false
    end

    local normalX, normalY = self:getEdgeOutwardNormal(markers, selfIndex, edgeX, edgeY, edgeLen)
    local direction = EulerAngles.new(0, 0, orientationYaw):GetForward()
    local dirX = direction.x
    local dirY = direction.y
    local dirLen = math.sqrt(dirX * dirX + dirY * dirY)
    if dirLen < 0.00001 then
        return false
    end
    dirX = dirX / dirLen
    dirY = dirY / dirLen

    -- 180 degree window around orientation => same half-plane as orientation direction.
    return normalX * dirX + normalY * dirY >= 0
end

---@protected
---@param parent element?
function outlineMarker:inheritLinkedState(parent)
    local neighbors = self:getNeighbors(parent).neighbors
    if #neighbors == 0 then return end

    local template = neighbors[1]
    if not template then return end

    self.height = template.height
    self.heightZLocked = template.heightZLocked == true
    self.previewed = template.previewed ~= false

    if self.heightZLocked then
        self.position.z = template.position.z
    end
end

function outlineMarker:getTransform(parent)
    local neighbors = self:getNeighbors(parent)
    local width = 0.005
    local yaw = self.rotation.yaw

    if #neighbors.neighbors > 1 then
        local diff = utils.subVector(neighbors.nxt.position, self.position)
        yaw = diff:ToRotation().yaw + 90
        width = diff:Length() / 2
    end

    return {
        scale = { x = width, y = 0.005, z = self.height },
        rotation = { roll = 0, pitch = 0, yaw = yaw },
    }
end

---Refreshes preview color based on boundary orientation and face direction.
---@param parent element?
---@param orientationYawOverride number?
function outlineMarker:refreshBoundaryFacePreview(parent, orientationYawOverride)
    local entity = self:getEntity()
    if not entity then return end

    local mesh = entity:FindComponentByName("mesh")
    if not mesh then return end

    local appearance = self:isExternalFace(parent, orientationYawOverride) and "red" or self.connectorApp
    if mesh.meshAppearance ~= appearance then
        mesh.meshAppearance = appearance
        mesh:RefreshAppearance()
    end
end

---Updates the x scale and yaw rotation of the outline marker based on the neighbors
---@param parent element?
---@param orientationYawOverride number?
function outlineMarker:updateTransform(parent, orientationYawOverride)
    spawnable.update(self)

    local entity = self:getEntity()
    if not entity then return end

    local transform = self:getTransform(parent)
    local mesh = entity:FindComponentByName("mesh")
    if not mesh then return end

    mesh.visualScale = Vector3.new(transform.scale.x, 0.005, transform.scale.z / 2)
    mesh:SetLocalOrientation(EulerAngles.new(0, 0, transform.rotation.yaw):ToQuat())
    self:refreshBoundaryFacePreview(parent, orientationYawOverride)
end

-- Enforce same z for all neighbors
---@protected
function outlineMarker:enforceSameZ()
    local neighbors = self:getNeighbors().neighbors
    if #neighbors == 0 then return end

    local targetZ = self.position.z
    local lockedTargetZ = self.heightZLocked and self.position.z or nil

    -- If a linked marker is lock-enabled, its existing Z stays authoritative.
    for _, neighbor in pairs(neighbors) do
        if neighbor.heightZLocked then
            lockedTargetZ = neighbor.position.z
            break
        end
    end

    if lockedTargetZ ~= nil then
        targetZ = lockedTargetZ
        self.position.z = targetZ

        local selfEntity = self:getEntity()
        if selfEntity then
            spawnable.update(self)
        end
    end

    for _, neighbor in pairs(neighbors) do
        neighbor.position.z = targetZ
        local entity = neighbor:getEntity()

        if entity then
            spawnable.update(neighbor)
        end
    end
end

function outlineMarker:updateHeight()
    local entity = self:getEntity()
    if not entity then return end

    local mesh = entity:FindComponentByName("mesh")
    mesh.visualScale = Vector3.new(mesh.visualScale.x, 0.005, self.height / 2)
    mesh:RefreshAppearance()
    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
end

---@protected
function outlineMarker:setLinkedHeightZLock(state)
    self.heightZLocked = state

    for _, neighbor in pairs(self:getNeighbors().neighbors) do
        neighbor.heightZLocked = state
    end
end

---@param axis string
---@return boolean
function outlineMarker:isTransformAxisLocked(axis)
    if not self.heightZLocked then
        return false
    end

    return axis == "z" or axis == "relZ"
end

function outlineMarker:draw()
    connectedMarker.draw(self)

    style.mutedText("Height")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    ImGui.SetNextItemWidth(110 * style.viewSize)
    ImGui.BeginDisabled(self.heightZLocked)
    local newValue, changed = ImGui.DragFloat("##height", self.height, 0.01, 0, 250, "%.2f Height")
    ImGui.EndDisabled()
    ImGui.SameLine()

    local lockIcon = self.heightZLocked and IconGlyphs.LockOutline or IconGlyphs.LockOpenVariantOutline
    local nextHeightZLocked, lockChanged = style.toggleButton(lockIcon .. "##heightZLock" .. tostring(self.object.id), self.heightZLocked)
    if lockChanged then
        local elements = { self.object }
        for _, neighbor in pairs(self:getNeighbors().neighbors) do
            table.insert(elements, neighbor.object)
        end

        history.addAction(history.getMultiSelectChange(elements))
        self:setLinkedHeightZLock(nextHeightZLocked)
    end
    style.tooltip("Lock Height and Z/Rel Z transforms for all linked outline markers")

    local finished = ImGui.IsItemDeactivatedAfterEdit()
	if finished then
		self.dragBeingEdited = false
	end
	if changed and not self.dragBeingEdited then
        local elements = { self.object }
        for _, neighbor in pairs(self:getNeighbors().neighbors) do
            table.insert(elements, neighbor.object)
        end

        history.addAction(history.getMultiSelectChange(elements))
		self.dragBeingEdited = true
	end

    if changed or finished then
        newValue = math.max(newValue, 0)
        newValue = math.min(newValue, 250)

        self.height = newValue
        self:updateHeight()

        for _, neighbor in pairs(self:getNeighbors().neighbors) do
            neighbor.height = self.height
            neighbor:updateHeight()
        end
    end
end

return outlineMarker
