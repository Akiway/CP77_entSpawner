local utils = require("modules/utils/utils")
local history = require("modules/utils/history")
local style = require("modules/ui/style")
local input = require("modules/utils/input")
local projectedWireframe = require("modules/utils/editor/projectedWireframe")

local brushTool = {}

local BRUSH_DEFAULT_RADIUS = 10
local BRUSH_MIN_RADIUS = 1
local BRUSH_MAX_RADIUS = 200
local BRUSH_DEFAULT_INTENSITY = 12.5
local BRUSH_MIN_INTENSITY = 1
local BRUSH_MAX_INTENSITY = 40
local BRUSH_RANDOM_ROTATION_MIN = -180
local BRUSH_RANDOM_ROTATION_MAX = 180
local BRUSH_DEFAULT_SCALE_VARIATION = 0
local BRUSH_MIN_SCALE_VARIATION = 0
local BRUSH_MAX_SCALE_VARIATION = 2
local BRUSH_RNG_MODULUS = 2147483647
local BRUSH_RNG_MULTIPLIER = 48271
local BRUSH_DOWN_DIRECTION = nil
local BRUSH_COLOR = 0xFF00CC66
local BRUSH_FILL_COLOR = 0x3300CC66
local BRUSH_LABEL_COLOR = 0xFFE6F2EA
local BRUSH_TEMPLATE_SERIALIZE_REFRESH = 0.35
local BRUSH_SURFACE_LOCK_HALF_DEPTH = 4.0

---@param values table
local function clearArray(values)
    for index = #values, 1, -1 do
        values[index] = nil
    end
end

---@param editor editor
---@return table
local function getBrushRuntime(editor)
    editor.brushRuntime = editor.brushRuntime or {}
    local runtime = editor.brushRuntime

    runtime.targetCache = runtime.targetCache or {
        selectedGroup = nil,
        target = nil
    }
    runtime.targetExcludeCache = runtime.targetExcludeCache or {
        selectedGroup = nil,
        targetRef = nil,
        cacheEpoch = -1,
        excludeIds = nil
    }
    runtime.templateCache = runtime.templateCache or {
        sourceGroupId = nil,
        sourceGroupRef = nil,
        childsRef = nil,
        childCount = 0,
        ruleKey = nil,
        candidates = nil
    }
    runtime.moduleConstructors = runtime.moduleConstructors or {}
    runtime.scratchSelected = runtime.scratchSelected or {}
    runtime.scratchShown = runtime.scratchShown or {}
    runtime.scratchHidden = runtime.scratchHidden or {}

    return runtime
end

---@param editor editor
local function invalidateTemplateCache(editor)
    local runtime = getBrushRuntime(editor)
    runtime.templateCache.sourceGroupId = nil
    runtime.templateCache.sourceGroupRef = nil
    runtime.templateCache.childsRef = nil
    runtime.templateCache.childCount = 0
    runtime.templateCache.ruleKey = nil
    runtime.templateCache.candidates = nil
    clearArray(runtime.scratchSelected)
    clearArray(runtime.scratchShown)
    clearArray(runtime.scratchHidden)
end

---@param editor editor
local function ensureBrushState(editor)
    editor.brush = editor.brush or {}
    local brush = editor.brush

    if brush.active == nil then brush.active = false end
    if brush.sourceGroup == nil then brush.sourceGroup = nil end
    if brush.sourceGroupId == nil then brush.sourceGroupId = nil end
    if brush.strokeCooldown == nil then brush.strokeCooldown = 0 end
    if brush.randomizeRotX == nil then brush.randomizeRotX = false end
    if brush.randomizeRotY == nil then brush.randomizeRotY = false end
    if brush.randomizeRotZ == nil then brush.randomizeRotZ = false end
    if brush.rngState == nil then brush.rngState = nil end

    brush.radius = tonumber(brush.radius) or BRUSH_DEFAULT_RADIUS
    brush.intensity = tonumber(brush.intensity) or BRUSH_DEFAULT_INTENSITY
    brush.scaleVariation = tonumber(brush.scaleVariation) or BRUSH_DEFAULT_SCALE_VARIATION

    getBrushRuntime(editor)
end

---@return boolean
local function isWorldBuilderWindowHovered()
    if not input or not input.context then
        return false
    end

    local mainHovered = input.context.main and input.context.main.hovered
    local hierarchyHovered = input.context.hierarchy and input.context.hierarchy.hovered
    return mainHovered == true or hierarchyHovered == true
end

---@return Vector4?
local function getBrushDownDirection()
    if BRUSH_DOWN_DIRECTION then
        return BRUSH_DOWN_DIRECTION
    end

    if Vector4 and Vector4.new then
        BRUSH_DOWN_DIRECTION = Vector4.new(0, 0, -1, 0)
        return BRUSH_DOWN_DIRECTION
    end

    return nil
end

---@param editor editor
local function clearBrushSourceGroup(editor)
    local runtime = getBrushRuntime(editor)
    local sourceGroupId = editor.brush.sourceGroupId
    editor.brush.sourceGroup = nil
    editor.brush.sourceGroupId = nil
    editor.brush.rngState = nil
    runtime.selectionResolvedSourceId = nil

    if sourceGroupId ~= nil then
        invalidateTemplateCache(editor)
    end
end

---@param editor editor
local function validateBrushSourceGroup(editor)
    local source = editor.brush.sourceGroup
    if not source then
        return
    end

    if source.parent == nil or not utils.isA(source, "randomizedGroup") then
        clearBrushSourceGroup(editor)
    end
end

---@param editor editor
---@return randomizedGroup?
local function resolveSelectedRandomizedGroup(editor)
    if not editor.spawnedUI or type(editor.spawnedUI.selectedPaths) ~= "table" then
        return nil
    end

    for _, entry in ipairs(editor.spawnedUI.selectedPaths) do
        local ref = entry and entry.ref or nil
        if ref and ref.parent ~= nil and utils.isA(ref, "randomizedGroup") then
            return ref
        end
    end

    return nil
end

---@param editor editor
---@return positionableGroup?
local function resolveBrushTargetGroup(editor)
    local runtime = getBrushRuntime(editor)
    local spawnedUI = editor.spawnedUI
    local spawnUI = editor.spawnUI
    local root = spawnedUI and spawnedUI.root or nil
    if not root or not editor.spawnUI then
        return nil
    end

    local selectedGroup = spawnUI.selectedGroup or 0
    if selectedGroup == 0 then
        runtime.targetCache.selectedGroup = selectedGroup
        runtime.targetCache.target = nil
        return nil
    end

    if runtime.targetCache.selectedGroup == selectedGroup then
        local cachedTarget = runtime.targetCache.target
        if cachedTarget and cachedTarget.parent ~= nil and cachedTarget ~= root then
            return cachedTarget
        end
        if cachedTarget == nil and spawnedUI and not spawnedUI.cacheDirty then
            return nil
        end
    end

    if spawnedUI and spawnedUI.cacheDirty and spawnedUI.ensureCache then
        spawnedUI.ensureCache()
    end

    local containerEntry = spawnedUI.containerPaths and spawnedUI.containerPaths[selectedGroup] or nil
    local parent = containerEntry and containerEntry.ref or nil
    if not parent or parent == root then
        runtime.targetCache.selectedGroup = selectedGroup
        runtime.targetCache.target = nil
        return nil
    end

    runtime.targetCache.selectedGroup = selectedGroup
    runtime.targetCache.target = parent
    return parent
end

---@param editor editor
---@param targetGroup positionableGroup?
---@return table<number, boolean>?
local function getBrushTargetExcludeIds(editor, targetGroup)
    local runtime = getBrushRuntime(editor)
    local cache = runtime.targetExcludeCache
    local spawnedUI = editor.spawnedUI
    local selectedGroup = editor.spawnUI and editor.spawnUI.selectedGroup or 0
    local cacheEpoch = spawnedUI and tonumber(spawnedUI.cacheEpoch) or -1

    if cache.selectedGroup == selectedGroup
        and cache.targetRef == targetGroup
        and cache.cacheEpoch == cacheEpoch then
        return cache.excludeIds
    end

    local excludeIds = nil
    if targetGroup and targetGroup.getDescendants then
        excludeIds = {}
        for _, descendant in ipairs(targetGroup:getDescendants() or {}) do
            if descendant and descendant.id then
                excludeIds[descendant.id] = true
            end
        end
    end

    cache.selectedGroup = selectedGroup
    cache.targetRef = targetGroup
    cache.cacheEpoch = cacheEpoch
    cache.excludeIds = excludeIds

    return excludeIds
end

---@param base table<number, boolean>?
---@return table<number, boolean>
local function makeMutableExcludeIds(base)
    if not base then
        return {}
    end

    return setmetatable({}, { __index = base })
end

---@param excludeIds table<number, boolean>?
---@param entry element?
local function extendExcludedSubtree(excludeIds, entry)
    if not excludeIds or not entry or not entry.id then
        return
    end

    excludeIds[entry.id] = true
    if entry.getDescendants then
        for _, descendant in ipairs(entry:getDescendants() or {}) do
            if descendant and descendant.id then
                excludeIds[descendant.id] = true
            end
        end
    end
end

---@param editor editor
---@return number
local function nextBrushRandom(editor)
    local state = tonumber(editor.brush.rngState) or 0
    if state <= 0 then
        local timeSeconds = (os and os.time and tonumber(os.time())) or 0
        local clockSeconds = (os and os.clock and tonumber(os.clock())) or 0
        local sourceSalt = tonumber(editor.brush.sourceGroupId) or 0
        local radiusSalt = tonumber(editor.brush.radius) or BRUSH_DEFAULT_RADIUS
        local seed = math.floor((timeSeconds * 1000000) + (clockSeconds * 1000000) + (sourceSalt * 97) + (radiusSalt * 31))
        state = math.abs(seed) % (BRUSH_RNG_MODULUS - 1) + 1
    end

    state = (state * BRUSH_RNG_MULTIPLIER) % BRUSH_RNG_MODULUS
    editor.brush.rngState = state
    return state / BRUSH_RNG_MODULUS
end

---@param editor editor
---@param minValue number
---@param maxValue number
---@return number
local function nextBrushRandomRange(editor, minValue, maxValue)
    return minValue + (maxValue - minValue) * nextBrushRandom(editor)
end

---@param child element
---@return number
local function getRandomizationProbability(child)
    local probability = child
        and child.randomizationSettings
        and tonumber(child.randomizationSettings.probability)
        or 0.5

    return math.max(0, math.min(1, probability))
end

---@param group randomizedGroup
---@return string
local function getTemplateRuleKey(group)
    return table.concat({
        tostring(group.randomizationRule or 0),
        tostring(group.fixedAmountRule or 0),
        tostring(group.fixedAmountPercentage or 0),
        tostring(group.fixedAmountTotal or 0)
    }, "|")
end

---@param a table
---@param b table
---@return boolean
local function compareCandidatesByProbability(a, b)
    if a.probability ~= b.probability then
        return a.probability > b.probability
    end

    local aId = a.child and a.child.id or 0
    local bId = b.child and b.child.id or 0
    return aId < bId
end

---@param editor editor
---@param group randomizedGroup
---@return table
local function ensureTemplateCache(editor, group)
    local runtime = getBrushRuntime(editor)
    local templateCache = runtime.templateCache
    local childsRef = group.childs
    local childCount = #(group.childs or {})
    local ruleKey = getTemplateRuleKey(group)

    if templateCache.sourceGroupId == group.id
        and templateCache.sourceGroupRef == group
        and templateCache.childsRef == childsRef
        and templateCache.childCount == childCount
        and templateCache.ruleKey == ruleKey
        and templateCache.candidates then
        return templateCache
    end

    local candidates = {}
    for _, child in pairs(group.childs or {}) do
        if utils.isA(child, "positionable") then
            local modulePath = child.modulePath
            local serialized = child:serialize()
            modulePath = serialized.modulePath or modulePath

            local ctor = runtime.moduleConstructors[modulePath]
            if not ctor then
                ctor = require(modulePath)
                runtime.moduleConstructors[modulePath] = ctor
            end

            if modulePath == "modules/classes/editor/randomizedGroup" then
                serialized.seed = -1
            end

            table.insert(candidates, {
                child = child,
                modulePath = modulePath,
                ctor = ctor,
                serialized = serialized,
                serializedAt = (os and os.clock and os.clock()) or 0,
                probability = getRandomizationProbability(child)
            })
        end
    end

    table.sort(candidates, compareCandidatesByProbability)

    templateCache.sourceGroupId = group.id
    templateCache.sourceGroupRef = group
    templateCache.childsRef = childsRef
    templateCache.childCount = childCount
    templateCache.ruleKey = ruleKey
    templateCache.candidates = candidates

    clearArray(runtime.scratchSelected)
    clearArray(runtime.scratchShown)
    clearArray(runtime.scratchHidden)

    return templateCache
end

---@param editor editor
---@param group randomizedGroup
---@return table[]
local function collectBrushTemplates(editor, group)
    local templateCache = ensureTemplateCache(editor, group)
    local runtime = getBrushRuntime(editor)
    local candidates = templateCache.candidates or {}
    local selected = runtime.scratchSelected
    clearArray(selected)

    if #candidates == 0 then
        return selected
    end

    if group.randomizationRule == 0 then
        for _, candidate in ipairs(candidates) do
            local child = candidate.child
            if child and child.parent == group and not child:isLocked() then
                candidate.probability = getRandomizationProbability(child)
                if nextBrushRandom(editor) < candidate.probability then
                    table.insert(selected, candidate)
                end
            end
        end
        return selected
    end

    local shown = runtime.scratchShown
    local hidden = runtime.scratchHidden
    clearArray(shown)
    clearArray(hidden)

    local unlockedCount = 0
    local orderChanged = false
    for _, candidate in ipairs(candidates) do
        local child = candidate.child
        if child and child.parent == group and not child:isLocked() then
            unlockedCount = unlockedCount + 1
            local probability = getRandomizationProbability(child)
            if probability ~= candidate.probability then
                candidate.probability = probability
                orderChanged = true
            end

            if nextBrushRandom(editor) < probability then
                table.insert(shown, candidate)
            else
                table.insert(hidden, candidate)
            end
        end
    end

    if orderChanged then
        table.sort(candidates, compareCandidatesByProbability)
        table.sort(shown, compareCandidatesByProbability)
        table.sort(hidden, compareCandidatesByProbability)
    end

    local amount
    if group.fixedAmountRule == 0 then
        local percentage = tonumber(group.fixedAmountPercentage) or 0
        amount = math.floor(percentage * unlockedCount)
    else
        amount = math.floor(tonumber(group.fixedAmountTotal) or 0)
    end

    amount = math.max(0, math.min(amount, unlockedCount))

    for index = 1, #shown do
        if #selected >= amount then
            break
        end
        table.insert(selected, shown[index])
    end
    for index = 1, #hidden do
        if #selected >= amount then
            break
        end
        table.insert(selected, hidden[index])
    end

    return selected
end

---@param editor editor
---@param radius number
---@return number, number
local function getRandomDiskOffset(editor, radius)
    local angle = nextBrushRandom(editor) * math.pi * 2
    local distance = math.sqrt(nextBrushRandom(editor)) * radius

    return math.cos(angle) * distance, math.sin(angle) * distance
end

---@param hitData {hit: boolean, result: table?}
---@return Vector4
local function getBrushSurfaceNormal(hitData)
    local normal = hitData and hitData.result and hitData.result.normal or nil
    if normal then
        local candidate = Vector4.new(normal.x or 0, normal.y or 0, normal.z or 1, 0)
        if candidate:Length() > 0.0001 then
            return candidate:Normalize()
        end
    end

    return Vector4.new(0, 0, 1, 0)
end

---@param normal Vector4
---@return Vector4, Vector4
local function getSurfaceTangents(normal)
    local reference = math.abs(normal.z or 0) < 0.95 and Vector4.new(0, 0, 1, 0) or Vector4.new(1, 0, 0, 0)
    local tangent = reference:Cross(normal)
    if tangent:Length() <= 0.0001 then
        tangent = Vector4.new(0, 1, 0, 0):Cross(normal)
    end
    if tangent:Length() <= 0.0001 then
        tangent = Vector4.new(1, 0, 0, 0)
    else
        tangent = tangent:Normalize()
    end

    local bitangent = normal:Cross(tangent)
    if bitangent:Length() <= 0.0001 then
        bitangent = Vector4.new(0, 1, 0, 0)
    else
        bitangent = bitangent:Normalize()
    end

    return tangent, bitangent
end

---@param editor editor
---@param center Vector4
---@param tangent Vector4
---@param bitangent Vector4
---@param radius number
---@return Vector4
local function getRandomPointInBrushSurface(editor, center, tangent, bitangent, radius)
    local offsetX, offsetY = getRandomDiskOffset(editor, radius)

    return Vector4.new(
        center.x + tangent.x * offsetX + bitangent.x * offsetY,
        center.y + tangent.y * offsetX + bitangent.y * offsetY,
        center.z + tangent.z * offsetX + bitangent.z * offsetY,
        0
    )
end

---@param editor editor
---@param point Vector4
---@param normal Vector4
---@return Vector4
local function projectPointToSurface(editor, point, normal)
    if not editor.interface then
        return Vector4.new(point.x, point.y, point.z, 0)
    end

    local offset = utils.multVector(normal, BRUSH_SURFACE_LOCK_HALF_DEPTH)
    local origin = Vector4.new(point.x + offset.x, point.y + offset.y, point.z + offset.z, 0)
    local target = Vector4.new(point.x - offset.x, point.y - offset.y, point.z - offset.z, 0)

    local raycast = editor.interface:RaycastWithASingleGroup(origin, target, "PlayerBlocker")
    if raycast and raycast:IsValid() then
        local hitPoint = Vector4.Vector3To4(raycast.position)
        return Vector4.new(hitPoint.x, hitPoint.y, hitPoint.z, 0)
    end

    raycast = editor.interface:RaycastWithASingleGroup(target, origin, "PlayerBlocker")

    if raycast and raycast:IsValid() then
        local hitPoint = Vector4.Vector3To4(raycast.position)
        return Vector4.new(hitPoint.x, hitPoint.y, hitPoint.z, 0)
    end

    return Vector4.new(point.x, point.y, point.z, 0)
end

---@param instance positionable
---@return positionable[]
local function getBrushVariationTargets(instance)
    if not instance or not utils.isA(instance, "positionable") then
        return {}
    end

    if utils.isA(instance, "positionableGroup") and instance.getPositionableLeafs then
        local leafs = instance:getPositionableLeafs()
        if leafs and #leafs > 0 then
            return leafs
        end
    end

    return { instance }
end

---@param editor editor
---@param instance positionable
local function applyBrushTransformVariation(editor, instance)
    local targets = getBrushVariationTargets(instance)
    if #targets == 0 then
        return
    end

    local randomizeX = editor.getBrushRandomizeRotationAxis("x")
    local randomizeY = editor.getBrushRandomizeRotationAxis("y")
    local randomizeZ = editor.getBrushRandomizeRotationAxis("z")
    local scaleVariation = editor.getBrushScaleVariation and editor.getBrushScaleVariation() or BRUSH_DEFAULT_SCALE_VARIATION

    for _, target in ipairs(targets) do
        if not target or not utils.isA(target, "positionable") then
            goto continue
        end

        if target.isLocked and target:isLocked() then
            goto continue
        end

        if (randomizeX or randomizeY or randomizeZ) and EulerAngles and EulerAngles.new then
            local deltaRoll = randomizeY and nextBrushRandomRange(editor, BRUSH_RANDOM_ROTATION_MIN, BRUSH_RANDOM_ROTATION_MAX) or 0
            local deltaPitch = randomizeX and nextBrushRandomRange(editor, BRUSH_RANDOM_ROTATION_MIN, BRUSH_RANDOM_ROTATION_MAX) or 0
            local deltaYaw = randomizeZ and nextBrushRandomRange(editor, BRUSH_RANDOM_ROTATION_MIN, BRUSH_RANDOM_ROTATION_MAX) or 0

            if deltaRoll ~= 0 or deltaPitch ~= 0 or deltaYaw ~= 0 then
                if target.setRotationDelta then
                    target:setRotationDelta(EulerAngles.new(deltaRoll, deltaPitch, deltaYaw))
                else
                    local currentRotation = target.getRotation and target:getRotation() or nil
                    if currentRotation and target.setRotation then
                        local randomizedRotation = EulerAngles.new(
                            currentRotation.roll + deltaRoll,
                            currentRotation.pitch + deltaPitch,
                            currentRotation.yaw + deltaYaw
                        )
                        target:setRotation(randomizedRotation)
                    end
                end
            end
        end

        if scaleVariation > 0 and target.hasScale and target.setScale and target.getScale then
            local scale = target:getScale()
            if scale then
                local factor = 1 + ((nextBrushRandom(editor) * 2 - 1) * scaleVariation)
                factor = math.max(0.001, factor)

                target:setScale({
                    x = scale.x * factor,
                    y = scale.y * factor,
                    z = scale.z * factor
                }, true)
            end
        end

        ::continue::
    end
end

---@param editor editor
---@param candidate table
---@param parent positionableGroup
---@param position Vector4
---@param excludeIds table<number, boolean>
---@return element?
local function spawnBrushTemplate(editor, candidate, parent, position, excludeIds)
    if not candidate or not candidate.child then
        return nil
    end

    local now = (os and os.clock and os.clock()) or 0
    if not candidate.serialized
        or candidate.child.parent == nil
        or (now - (tonumber(candidate.serializedAt) or 0)) >= BRUSH_TEMPLATE_SERIALIZE_REFRESH then
        candidate.serialized = candidate.child:serialize()
        candidate.modulePath = candidate.serialized.modulePath or candidate.modulePath or candidate.child.modulePath

        local runtime = getBrushRuntime(editor)
        local ctor = runtime.moduleConstructors[candidate.modulePath]
        if not ctor then
            ctor = require(candidate.modulePath)
            runtime.moduleConstructors[candidate.modulePath] = ctor
        end
        candidate.ctor = ctor

        if candidate.modulePath == "modules/classes/editor/randomizedGroup" then
            candidate.serialized.seed = -1
        end

        candidate.serializedAt = now
    end

    local serialized = utils.deepcopy(candidate.serialized)
    serialized.visible = true
    serialized.hiddenByParent = false
    serialized.selected = false
    serialized.locked = false
    serialized.lockedByParent = false

    if (serialized.modulePath or candidate.modulePath) == "modules/classes/editor/randomizedGroup" then
        serialized.seed = -1
    end

    local ctor = candidate.ctor or require(serialized.modulePath)
    local new = ctor:new(editor.spawnedUI)
    new:load(serialized, true)

    if utils.isA(new, "positionable") then
        new:setPosition(position)
    end

    new:setSilent(false)
    new:setVisible(true, true)
    new:setParent(parent)

    local downDirection = getBrushDownDirection()
    if utils.isA(new, "spawnableElement") then
        new:updateRandomization()
        if downDirection then
            new:dropToSurface(true, downDirection, excludeIds)
        end
    elseif utils.isA(new, "positionableGroup") then
        if downDirection then
            new:dropChildrenToSurface(false, downDirection, true, excludeIds)
        end
        if utils.isA(new, "randomizedGroup") then
            new:applyRandomization(true)
        end
    end

    applyBrushTransformVariation(editor, new)

    return new
end

---@param editor editor
---@param hitData {hit: boolean, result: table?}
local function paintBrushStroke(editor, hitData)
    local sourceGroup = editor.brush.sourceGroup
    if not sourceGroup or not sourceGroup.parent then
        return
    end

    local targetParent = resolveBrushTargetGroup(editor)
    if not targetParent then
        return
    end

    local candidates = collectBrushTemplates(editor, sourceGroup)
    if #candidates == 0 then
        return
    end

    local center = hitData.result and hitData.result.position or nil
    if not center then
        return
    end

    local created = {}
    local targetExcludeIds = getBrushTargetExcludeIds(editor, targetParent)
    local excludeIds = makeMutableExcludeIds(targetExcludeIds)
    local radius = tonumber(editor.brush.radius) or BRUSH_DEFAULT_RADIUS
    local surfaceNormal = getBrushSurfaceNormal(hitData)
    local tangent, bitangent = getSurfaceTangents(surfaceNormal)

    for _, candidate in ipairs(candidates) do
        local randomPoint = getRandomPointInBrushSurface(editor, center, tangent, bitangent, radius)
        local surfacePoint = projectPointToSurface(editor, randomPoint, surfaceNormal)
        local spawned = spawnBrushTemplate(editor, candidate, targetParent, surfacePoint, excludeIds)
        if spawned and spawned.parent then
            table.insert(created, spawned)
            excludeIds[spawned.id] = true
            extendExcludedSubtree(targetExcludeIds, spawned)
        end
    end

    if #created > 0 then
        history.addAction(history.getInsert(created))
    end
end

---@param editor editor
---@param hitData {hit: boolean, result: table?}
local function drawBrushPreview(editor, hitData)
    if not hitData or not hitData.hit or not hitData.result or not hitData.result.position then
        return
    end

    local screen, drawList = projectedWireframe.beginOverlay("##brushOverlay")
    if not screen then
        return
    end

    local radius = tonumber(editor.brush.radius) or BRUSH_DEFAULT_RADIUS
    local center = hitData.result.position
    projectedWireframe.drawWorldCircle(drawList, screen, center, radius, {
        color = BRUSH_COLOR,
        fillColor = BRUSH_FILL_COLOR,
        thickness = 2.0,
        segments = 56
    })
    projectedWireframe.drawWorldMarker(drawList, screen, center, {
        color = BRUSH_COLOR,
        labelColor = BRUSH_LABEL_COLOR,
        text = string.format("Brush %.1f m", radius),
        radius = 4.5 * style.viewSize,
        innerRadius = 2.2 * style.viewSize,
        badgeOffsetY = -16 * style.viewSize,
        fontRatio = 0.78
    })

    projectedWireframe.endOverlay()
end

---@param editor editor
function brushTool.attach(editor)
    ensureBrushState(editor)

    function editor.clearBrushSourceGroup()
        clearBrushSourceGroup(editor)
    end

    ---Refreshes brush source from current hierarchy selection.
    ---@param clearWhenMissing boolean? Clears source when no randomized group is selected.
    ---@return randomizedGroup?
    function editor.captureBrushSourceFromSelection(clearWhenMissing)
        local runtime = getBrushRuntime(editor)
        local selectedPaths = editor.spawnedUI and editor.spawnedUI.selectedPaths or nil
        local selectedCount = selectedPaths and #selectedPaths or 0
        local firstId = selectedCount > 0 and selectedPaths[1] and selectedPaths[1].ref and selectedPaths[1].ref.id or -1
        local lastEntry = selectedCount > 0 and selectedPaths[selectedCount] or nil
        local lastId = lastEntry and lastEntry.ref and lastEntry.ref.id or -1

        if runtime.selectionCount == selectedCount
            and runtime.selectionFirstId == firstId
            and runtime.selectionLastId == lastId then
            if runtime.selectionResolvedSourceId == false then
                if clearWhenMissing then
                    clearBrushSourceGroup(editor)
                end
                return editor.brush.sourceGroup
            end

            local source = editor.brush.sourceGroup
            if source
                and source.parent ~= nil
                and utils.isA(source, "randomizedGroup")
                and runtime.selectionResolvedSourceId == source.id then
                return source
            end
        end

        runtime.selectionCount = selectedCount
        runtime.selectionFirstId = firstId
        runtime.selectionLastId = lastId

        local selected = resolveSelectedRandomizedGroup(editor)
        if selected then
            if editor.brush.sourceGroupId ~= selected.id then
                editor.brush.rngState = nil
                invalidateTemplateCache(editor)
            end
            editor.brush.sourceGroup = selected
            editor.brush.sourceGroupId = selected.id
            runtime.selectionResolvedSourceId = selected.id
            return selected
        end

        runtime.selectionResolvedSourceId = false
        if clearWhenMissing then
            clearBrushSourceGroup(editor)
        end

        return editor.brush.sourceGroup
    end

    ---Returns whether brush painting mode is currently active.
    ---@return boolean
    function editor.isBrushActive()
        return editor.active and editor.brush and editor.brush.active == true
    end

    ---Returns the active brush source randomized group id, if any.
    ---@return number?
    function editor.getBrushSourceGroupId()
        if not editor.isBrushActive() then
            return nil
        end

        validateBrushSourceGroup(editor)
        return editor.brush.sourceGroupId
    end

    ---Returns how many unlocked positionable entries are available in the brush source group.
    ---@return number
    function editor.getBrushSourceEntryCount()
        if not editor.isBrushActive() then
            return 0
        end

        validateBrushSourceGroup(editor)
        local source = editor.brush.sourceGroup
        if not source then
            return 0
        end

        local count = 0
        for _, child in pairs(source.childs or {}) do
            if utils.isA(child, "positionable") and not child:isLocked() then
                count = count + 1
            end
        end

        return count
    end

    ---Returns whether Spawn New target is a valid non-root group for brush painting.
    ---@return boolean
    function editor.hasBrushValidTargetGroup()
        return resolveBrushTargetGroup(editor) ~= nil
    end

    ---Returns active brush target group id, or nil when target is invalid/root.
    ---@return number?
    function editor.getBrushTargetGroupId()
        local target = resolveBrushTargetGroup(editor)
        return target and target.id or nil
    end

    ---Sets brush mode state.
    ---@param state boolean
    function editor.setBrushActive(state)
        local runtime = getBrushRuntime(editor)
        local nextState = state == true and editor.active
        editor.brush.active = nextState
        editor.brush.strokeCooldown = 0
        editor.brush.rngState = nil
        runtime.selectionCount = nil
        runtime.selectionFirstId = nil
        runtime.selectionLastId = nil
        runtime.selectionResolvedSourceId = nil

        if not nextState then
            return
        end

        editor.captureBrushSourceFromSelection(false)
    end

    ---Adjusts brush radius by delta and clamps to allowed limits.
    ---@param delta number
    function editor.adjustBrushRadius(delta)
        if not editor.brush then
            return
        end

        local radius = tonumber(editor.brush.radius) or BRUSH_DEFAULT_RADIUS
        radius = radius + (tonumber(delta) or 0)
        editor.brush.radius = math.max(BRUSH_MIN_RADIUS, math.min(BRUSH_MAX_RADIUS, radius))
    end

    ---Returns brush radius.
    ---@return number
    function editor.getBrushRadius()
        return tonumber(editor.brush and editor.brush.radius) or BRUSH_DEFAULT_RADIUS
    end

    ---Sets brush radius.
    ---@param value number
    function editor.setBrushRadius(value)
        local radius = tonumber(value) or BRUSH_DEFAULT_RADIUS
        editor.brush.radius = math.max(BRUSH_MIN_RADIUS, math.min(BRUSH_MAX_RADIUS, radius))
    end

    ---Returns brush intensity in strokes per second.
    ---@return number
    function editor.getBrushIntensity()
        return tonumber(editor.brush and editor.brush.intensity) or BRUSH_DEFAULT_INTENSITY
    end

    ---Sets brush intensity in strokes per second.
    ---@param value number
    function editor.setBrushIntensity(value)
        local intensity = tonumber(value) or BRUSH_DEFAULT_INTENSITY
        editor.brush.intensity = math.max(BRUSH_MIN_INTENSITY, math.min(BRUSH_MAX_INTENSITY, intensity))
    end

    ---Returns whether random rotation for a specific axis is enabled.
    ---@param axis "x"|"y"|"z"
    ---@return boolean
    function editor.getBrushRandomizeRotationAxis(axis)
        if axis == "x" then
            return editor.brush.randomizeRotX == true
        elseif axis == "y" then
            return editor.brush.randomizeRotY == true
        elseif axis == "z" then
            return editor.brush.randomizeRotZ == true
        end

        return false
    end

    ---Enables/disables random rotation for a specific axis.
    ---@param axis "x"|"y"|"z"
    ---@param state boolean
    function editor.setBrushRandomizeRotationAxis(axis, state)
        local nextState = state == true
        if axis == "x" then
            editor.brush.randomizeRotX = nextState
        elseif axis == "y" then
            editor.brush.randomizeRotY = nextState
        elseif axis == "z" then
            editor.brush.randomizeRotZ = nextState
        end
    end

    ---Returns brush scale variation factor (applied as random +/- multiplier).
    ---@return number
    function editor.getBrushScaleVariation()
        return tonumber(editor.brush and editor.brush.scaleVariation) or BRUSH_DEFAULT_SCALE_VARIATION
    end

    ---Sets brush scale variation factor.
    ---@param value number
    function editor.setBrushScaleVariation(value)
        local variation = tonumber(value) or BRUSH_DEFAULT_SCALE_VARIATION
        editor.brush.scaleVariation = math.max(BRUSH_MIN_SCALE_VARIATION, math.min(BRUSH_MAX_SCALE_VARIATION, variation))
    end

    ---Returns current stroke interval in seconds based on brush intensity.
    ---@return number
    function editor.getBrushStrokeInterval()
        local intensity = editor.getBrushIntensity()
        return 1 / math.max(0.001, intensity)
    end

    function editor.updateBrush()
        if not editor.isBrushActive() then
            return
        end

        if isWorldBuilderWindowHovered() then
            editor.brush.strokeCooldown = 0
            return
        end

        validateBrushSourceGroup(editor)
        editor.captureBrushSourceFromSelection(false)

        if not editor.brush.sourceGroup then
            editor.brush.strokeCooldown = 0
            return
        end

        local player = GetPlayer()
        if not player then
            editor.brush.strokeCooldown = 0
            return
        end

        local ray = editor.getScreenToWorldRay()
        local origin = player:GetFPPCameraComponent():GetLocalToWorld():GetTranslation()
        local targetGroup = resolveBrushTargetGroup(editor)
        local targetExcludeIds = getBrushTargetExcludeIds(editor, targetGroup)
        local hit = editor.getRaySceneIntersection(ray, origin, targetExcludeIds, true)
        if not hit.hit or not hit.result then
            editor.brush.strokeCooldown = 0
            return
        end

        drawBrushPreview(editor, hit)

        local dt = editor.camera and editor.camera.deltaTime or 0.016
        editor.brush.strokeCooldown = math.max(0, editor.brush.strokeCooldown - dt)

        if ImGui.IsMouseDown(ImGuiMouseButton.Left) then
            if editor.brush.strokeCooldown <= 0 then
                paintBrushStroke(editor, hit)
                editor.brush.strokeCooldown = editor.getBrushStrokeInterval()
            end
        else
            editor.brush.strokeCooldown = 0
        end
    end
end

return brushTool
