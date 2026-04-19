local settings = require("modules/utils/settings")
local style = require("modules/ui/style")
local Cron = require("modules/utils/Cron")
local config = require("modules/utils/config")
local utils = require("modules/utils/utils")
local gameUtils = require("modules/utils/gameUtils")

---@class rht
---@field public spawnUI spawnUI?
---@field public spawner spawner?
---@field public redHotTools any
---@field public removalEditor any
local rht = {
    spawnUI = nil,
    spawner = nil,
    redHotTools = nil,
    removalEditor = nil,
    removalAddTargetUpvalueIndex = nil,
    removalAddTargetUpvalueOwner = nil,
    removalAddTargetWarned = false,
    removalPresetPathCache = {}
}

local REPLACER_MODE_LABELS = {
    clone = "Clone",
    replace = "Replace",
    replace_hide = "Replace & Hide"
}

local VALID_REPLACER_MODES = {
    clone = true,
    replace = true,
    replace_hide = true
}

local VALID_MESH_TARGET_TYPES = {
    Auto = true,
    Static = true
}

local TYPE_MAP = {
    ["worldPopulationSpawnerNode"] = {
        data = "recordID",
        category = "Entity",
        sub = "Record",
        replacer = true
    },
    ["worldDeviceNode"] = {
        data = "templatePath",
        category = "Entity",
        sub = "Device",
        replacer = true
    },
    ["worldEntityNode"] = {
        data = "templatePath",
        category = "Entity",
        sub = "Template",
        replacer = true
    },
    ["worldPhysicalDestructionNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Dynamic Mesh",
        replacer = true
    },
    ["worldInstancedDestructibleMeshNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Dynamic Mesh",
        replacer = true
    },
    ["worldBendedMeshNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Mesh",
        replacer = true
    },
    ["worldFoliageNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Mesh",
        replacer = true
    },
    ["worldStaticMeshNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Mesh",
        replacer = true
    },
    ["worldInstancedMeshNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Mesh",
        replacer = true
    },
    ["worldMeshNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Mesh",
        replacer = true
    },
    ["worldStaticDecalNode"] = {
        data = "materialPath",
        category = "Deco",
        sub = "Decals",
        replacer = true
    },
    ["worldStaticParticleNode"] = {
        dataRetrieval = function(node)
            if not node or not node.nodeInstance or type(node.nodeInstance.GetNode) ~= "function" then
                return ""
            end

            local nativeNode = node.nodeInstance:GetNode()
            if not nativeNode or not nativeNode.particleSystem then
                return ""
            end

            return ResRef.FromHash(nativeNode.particleSystem.hash):ToString()
        end,
        category = "Deco",
        sub = "Particles",
        replacer = true
    },
    ["worldEffectNode"] = {
        data = "effectPath",
        category = "Deco",
        sub = "Effects",
        replacer = true
    },
    ["worldStaticLightNode"] = {
        dataRetrieval = function(node)
            local function safeGet(obj, key, defaultValue)
                local ok, value = pcall(function()
                    return obj[key]
                end)

                if ok and value ~= nil then
                    return value
                end

                return defaultValue
            end

            local function toBool(value)
                if type(value) == "boolean" then
                    return value
                end

                if type(value) == "number" then
                    return value ~= 0
                end

                local normalized = tonumber((tostring(value or ""):gsub("ULL", ""):gsub("LL", "")))
                return normalized == 1
            end

            local function getEnumIndex(enumName, targetValue)
                local targetName = tostring(targetValue or "")

                if type(targetValue) == "number" or type(targetValue) == "userdata" then
                    local text = tostring(targetValue)
                    local _, extractedValue = text:match(" : (.*) %((%d+)%)")
                    if extractedValue then
                        return tonumber(extractedValue) or 0
                    end

                    local clean = text:gsub("ULL", ""):gsub("LL", "")
                    local numericValue = tonumber(clean)
                    if numericValue ~= nil then
                        local ok, resolved = pcall(EnumValueToString, enumName, numericValue)
                        if ok and resolved and resolved ~= "" then
                            targetName = resolved
                        end
                    end
                end

                if not EnumGetMax(enumName) then
                    return 0
                end

                local maxValue = tonumber(EnumGetMax(enumName)) or 100
                local index = 0

                for i = -25, maxValue do
                    local name = EnumValueToString(enumName, i)
                    if name ~= "" then
                        if name == targetName then
                            return index
                        end
                        index = index + 1
                    end
                end

                return 0
            end

            local function getLightChannels(nativeChannel)
                if not nativeChannel then
                    return { true, true, true, true, true, true, true, true, true, false, false, false }
                end

                local isStruct, hasMember = pcall(function()
                    return nativeChannel.LC_Channel1
                end)

                if isStruct and hasMember ~= nil then
                    return {
                        nativeChannel.LC_Channel1,
                        nativeChannel.LC_Channel2,
                        nativeChannel.LC_Channel3,
                        nativeChannel.LC_Channel4,
                        nativeChannel.LC_Channel5,
                        nativeChannel.LC_Channel6,
                        nativeChannel.LC_Channel7,
                        nativeChannel.LC_Channel8,
                        nativeChannel.LC_ChannelWorld,
                        nativeChannel.LC_Character,
                        nativeChannel.LC_Player,
                        nativeChannel.LC_Automated
                    }
                end

                local function hasBit(value, bitIndex)
                    local text = tostring(value):gsub("ULL", ""):gsub("LL", "")
                    local numberValue = tonumber(text) or 0
                    local power = 2 ^ bitIndex
                    return (numberValue % (power * 2)) >= power
                end

                return {
                    hasBit(nativeChannel, 0),
                    hasBit(nativeChannel, 1),
                    hasBit(nativeChannel, 2),
                    hasBit(nativeChannel, 3),
                    hasBit(nativeChannel, 4),
                    hasBit(nativeChannel, 5),
                    hasBit(nativeChannel, 6),
                    hasBit(nativeChannel, 7),
                    hasBit(nativeChannel, 8),
                    hasBit(nativeChannel, 9),
                    hasBit(nativeChannel, 10),
                    hasBit(nativeChannel, 15)
                }
            end

            local native = node and (node.nodeDefinition or node.nodeInstance or node) or nil
            if not native then
                return nil
            end

            local flicker = safeGet(native, "flicker", nil)
            local color = safeGet(native, "color", nil)

            local data = {
                spawnData = "base\\spawner\\empty_entity.ent",
                radius = safeGet(native, "radius", 10),
                intensity = safeGet(native, "intensity", 100),
                innerAngle = safeGet(native, "innerAngle", 45),
                outerAngle = safeGet(native, "outerAngle", 90),
                color = { 1, 1, 1 },
                autoHideDistance = safeGet(native, "autoHideDistance", 45),
                capsuleLength = safeGet(native, "capsuleLength", 1),
                flickerStrength = flicker and safeGet(flicker, "flickerStrength", 0) or 0,
                flickerPeriod = flicker and safeGet(flicker, "flickerPeriod", 0) or 0,
                flickerOffset = flicker and safeGet(flicker, "positionOffset", 0) or 0,
                contactShadows = getEnumIndex("rendContactShadowReciever", safeGet(native, "contactShadows", 0)),
                shadowFadeDistance = safeGet(native, "shadowFadeDistance", 10),
                shadowFadeRange = safeGet(native, "shadowFadeRange", 5),
                ev = safeGet(native, "EV", 0),
                temperature = safeGet(native, "temperature", -1),
                lightType = getEnumIndex("ELightType", safeGet(native, "type", 1)),
                scaleVolFog = safeGet(native, "scaleVolFog", 0),
                sceneDiffuse = toBool(safeGet(native, "sceneDiffuse", true)),
                sceneSpecularScale = safeGet(native, "sceneSpecularScale", 100),
                roughnessBias = safeGet(native, "roughnessBias", 0),
                directional = toBool(safeGet(native, "directional", false)),
                attenuation = getEnumIndex("rendLightAttenuation", safeGet(native, "attenuation", 0)),
                localShadows = toBool(safeGet(native, "enableLocalShadows", true)),
                localShadowsForceStaticsOnly = toBool(safeGet(native, "enableLocalShadowsForceStaticsOnly", false)),
                sourceRadius = safeGet(native, "sourceRadius", 0.05),
                softness = safeGet(native, "softness", 2),
                spotCapsule = toBool(safeGet(native, "spotCapsule", false)),
                lightChannels = getLightChannels(safeGet(native, "lightChannel", nil))
            }

            if color then
                data.color = {
                    (safeGet(color, "Red", 255) / 255.0),
                    (safeGet(color, "Green", 255) / 255.0),
                    (safeGet(color, "Blue", 255) / 255.0)
                }
            end

            return data
        end,
        category = "Lighting",
        sub = "Static Light",
        replacer = true
    },
    ["worldStaticSoundEmitterNode"] = {
        dataRetrieval = function(node)
            if not node or not node.nodeInstance or type(node.nodeInstance.GetNode) ~= "function" then
                return ""
            end

            local nativeNode = node.nodeInstance:GetNode()
            if not nativeNode then
                return ""
            end

            local nodeSettings = nativeNode.Settings
            if not nodeSettings then
                return ""
            end

            if #nodeSettings.EventsOnActive < 1 then
                return ""
            end

            return nodeSettings.EventsOnActive[1].event.value
        end,
        category = "Deco",
        sub = "Static Audio Emitter",
        replacer = false
    },
    ["worldAISpotNode"] = {
        dataRetrieval = function(node)
            if not node or not node.nodeInstance or type(node.nodeInstance.GetNode) ~= "function" then
                return ""
            end

            local nativeNode = node.nodeInstance:GetNode()
            if not nativeNode or not nativeNode.spot or not nativeNode.spot.resource then
                return ""
            end

            return ResRef.FromHash(nativeNode.spot.resource.hash):ToString()
        end,
        category = "AI",
        sub = "AI Spot",
        replacer = false
    },
    ["worldReflectionProbeNode"] = {
        dataRetrieval = function(node)
            if not node or not node.nodeInstance or type(node.nodeInstance.GetNode) ~= "function" then
                return ""
            end

            local nativeNode = node.nodeInstance:GetNode()
            if not nativeNode then
                return ""
            end

            local probe = nativeNode.probeDataRef
            if not probe then
                return ""
            end

            return ResRef.FromHash(probe.hash):ToString()
        end,
        category = "Lighting",
        sub = "Reflection Probe",
        replacer = false
    }
}

local TYPE_PRIORITY = {
    "worldPopulationSpawnerNode",
    "worldDeviceNode",
    "worldEntityNode",
    "worldPhysicalDestructionNode",
    "worldInstancedDestructibleMeshNode",
    "worldBendedMeshNode",
    "worldFoliageNode",
    "worldStaticMeshNode",
    "worldInstancedMeshNode",
    "worldMeshNode",
    "worldStaticDecalNode",
    "worldStaticParticleNode",
    "worldEffectNode",
    "worldStaticLightNode",
    "worldStaticSoundEmitterNode",
    "worldAISpotNode",
    "worldReflectionProbeNode"
}

local function log(message)
    print("[entSpawner][RHT] " .. tostring(message))
end

local function sanitizeReplacerMode(mode)
    if VALID_REPLACER_MODES[mode] then
        return mode
    end
    return "clone"
end

local function sanitizeMeshTargetType(targetType)
    if VALID_MESH_TARGET_TYPES[targetType] then
        return targetType
    end
    return "Auto"
end

local function normalizeSettings()
    local changed = false

    local mode = sanitizeReplacerMode(settings.rhtAddonReplacerMode)
    if settings.rhtAddonReplacerMode ~= mode then
        settings.rhtAddonReplacerMode = mode
        changed = true
    end

    local targetType = sanitizeMeshTargetType(settings.rhtAddonMeshTargetType)
    if settings.rhtAddonMeshTargetType ~= targetType then
        settings.rhtAddonMeshTargetType = targetType
        changed = true
    end

    if changed then
        settings.save()
    end
end

local function getTypeIndex(node)
    if not node or not node.nodeType then
        return nil
    end

    local okClass, nodeClass = pcall(function()
        return Reflection.GetClass(node.nodeType)
    end)

    if not okClass or not nodeClass then
        return nil
    end

    for _, typeName in ipairs(TYPE_PRIORITY) do
        local okIsA, isA = pcall(function()
            return nodeClass:IsA(typeName)
        end)

        if okIsA and isA then
            return typeName
        end
    end

    return nil
end

local function getDefinition(node)
    local typeIndex = getTypeIndex(node)
    if not typeIndex then
        return nil, nil
    end

    return TYPE_MAP[typeIndex], typeIndex
end

local function isWorldNode(node)
    local isNode = node and node.sectorPath and node.instanceIndex
    if not isNode then
        return false
    end

    local def = getDefinition(node)
    return def ~= nil
end

---@param fallback any
---@return any
local function getLiveInspectorNode(fallback)
    local mod = rht.redHotTools or GetMod("RedHotTools")
    if mod and type(mod.GetWorldInspectorTarget) == "function" then
        local inspectorNode = mod.GetWorldInspectorTarget()
        if isWorldNode(inspectorNode) then
            return inspectorNode
        end
    end

    return fallback
end

local function resolveData(node, definition)
    if not definition then
        return nil
    end

    if definition.dataRetrieval then
        local ok, value = pcall(definition.dataRetrieval, node)
        if ok then
            return value
        end

        log("Failed to resolve node data: " .. tostring(value))
        return nil
    end

    if definition.data then
        return node[definition.data]
    end

    return nil
end

local function toScaleVector(scale)
    if not scale then
        return nil
    end

    if scale.x ~= nil and scale.y ~= nil and scale.z ~= nil then
        return Vector4.new(scale.x, scale.y, scale.z, scale.w or 0)
    end

    if scale.X ~= nil and scale.Y ~= nil and scale.Z ~= nil then
        return Vector4.new(scale.X, scale.Y, scale.Z, scale.W or 0)
    end

    return nil
end

local function applyTransform(element, position, rotation, scale)
    if not element then
        return
    end

    if position and element.setPosition then
        element:setPosition(position)
    end

    local euler = gameUtils.toEulerAnglesSafe(rotation)
    if euler and element.setRotation then
        element:setRotation(euler)
    end

    local scaleVector = toScaleVector(scale)
    if scaleVector and element.setScale then
        element:setScale(scaleVector, true)
    end
end

local function setSpawnSelection(category, sub)
    if not rht.spawnUI then
        return false
    end

    local okCategory, categoryIndex = pcall(function()
        return rht.spawnUI.getCategoryIndex(category)
    end)
    if not okCategory or not categoryIndex then
        return false
    end

    rht.spawnUI.selectedType = categoryIndex - 1
    rht.spawnUI.updateCategory()

    local okVariant, variantIndex = pcall(function()
        return rht.spawnUI.getVariantIndex(category, sub)
    end)
    if not okVariant or not variantIndex then
        return false
    end

    rht.spawnUI.selectedVariant = variantIndex - 1
    rht.spawnUI.updateVariant()
    return true
end

local function isReplacementMode(mode)
    return mode == "replace" or mode == "replace_hide"
end

---@param fn function
---@param upvalueName string
---@return number?
local function findUpvalueIndex(fn, upvalueName)
    if not fn then
        return nil
    end

    if not debug or type(debug.getupvalue) ~= "function" then
        return nil
    end

    local index = 1
    while true do
        local ok, name = pcall(debug.getupvalue, fn, index)
        if not ok or not name then
            break
        end

        if name == upvalueName then
            return index
        end

        index = index + 1
    end

    return nil
end

---@param object any
---@param key string
---@return any
local function safeGet(object, key)
    if object == nil then
        return nil
    end

    local ok, value = pcall(function()
        return object[key]
    end)

    if ok then
        return value
    end

    return nil
end

---@param removalEditor any
---@return table?, string?
local function getActivePreset(removalEditor)
    local currentFile = removalEditor and removalEditor.currentFile or nil
    if not currentFile or currentFile == "" then
        return nil, nil
    end

    local presets = removalEditor.presets
    if type(presets) ~= "table" then
        return nil, currentFile
    end

    local preset = presets[currentFile]
    if type(preset) ~= "table" then
        return nil, currentFile
    end

    if type(preset.streaming) ~= "table" then
        preset.streaming = { sectors = {} }
    end

    if type(preset.streaming.sectors) ~= "table" then
        preset.streaming.sectors = {}
    end

    return preset, currentFile
end

---@param preset table?
---@param sectorPath string?
---@return table?
local function findSectorByPath(preset, sectorPath)
    if type(preset) ~= "table" or type(preset.streaming) ~= "table" then
        return nil
    end

    local sectors = preset.streaming.sectors
    if type(sectors) ~= "table" then
        return nil
    end

    for _, sector in pairs(sectors) do
        if sector and sector.path == sectorPath then
            sector.nodeDeletions = sector.nodeDeletions or {}
            sector.nodeMutations = sector.nodeMutations or {}
            return sector
        end
    end

    return nil
end

---@param sector table?
---@param instanceIndex number?
---@return table?
local function findRemovalByIndex(sector, instanceIndex)
    if type(sector) ~= "table" or type(sector.nodeDeletions) ~= "table" then
        return nil
    end

    for _, entry in pairs(sector.nodeDeletions) do
        if entry and entry.index == instanceIndex then
            return entry
        end
    end

    return nil
end

---@param removalEditor any
---@param node any
---@return boolean
local function isNodeRemovalComplete(removalEditor, node)
    if not node then
        return false
    end

    local preset = getActivePreset(removalEditor)
    if not preset then
        return false
    end

    local sector = findSectorByPath(preset, node.sectorPath)
    if not sector then
        return false
    end

    local entry = findRemovalByIndex(sector, node.instanceIndex)
    if not entry then
        return false
    end

    if node.nodeType == "worldCollisionNode" and node.collision then
        local expectedActor = node.physicsActorOffset + node.physicsActorIndex
        return type(entry.actorDeletions) == "table" and utils.has_value(entry.actorDeletions, expectedActor)
    end

    return true
end

---@param removalEditor any
---@param currentFile string
---@return string
local function getRemovalPresetPath(removalEditor, currentFile)
    local cachedPath = rht.removalPresetPathCache[currentFile]
    if cachedPath and config.fileExists(cachedPath) then
        return cachedPath
    end

    local candidates = {}

    local addRemoval = removalEditor and removalEditor.addRemoval or nil
    if debug and type(debug.getinfo) == "function" and type(addRemoval) == "function" then
        local ok, info = pcall(debug.getinfo, addRemoval, "S")
        if ok and info and type(info.source) == "string" then
            local source = tostring(info.source):gsub("^@", ""):gsub("\\", "/")
            local modRoot = source:match("^(.*)/init%.lua$")
            if modRoot then
                table.insert(candidates, modRoot .. "/data/" .. currentFile)
            end
        end
    end

    table.insert(candidates, "../removalEditor/data/" .. currentFile)
    table.insert(candidates, "data/" .. currentFile)

    for _, path in ipairs(candidates) do
        if config.fileExists(path) then
            rht.removalPresetPathCache[currentFile] = path
            return path
        end
    end

    local fallback = candidates[1] or ("../removalEditor/data/" .. currentFile)
    rht.removalPresetPathCache[currentFile] = fallback
    return fallback
end

---@param removalEditor any
---@param preset table
---@param currentFile string
---@return boolean
local function saveRemovalPreset(removalEditor, preset, currentFile)
    local path = getRemovalPresetPath(removalEditor, currentFile)
    local ok, err = config.saveFile(path, preset)
    if not ok then
        log("RemovalEditor fallback save failed for '" .. tostring(path) .. "': " .. tostring(err))
        return false
    end

    return true
end

---@param removalEditor any
---@param node any
---@return boolean
local function manualAddRemoval(removalEditor, node)
    local preset, currentFile = getActivePreset(removalEditor)
    if not preset or not currentFile then
        return false
    end

    if not node or not node.sectorPath or node.instanceIndex == nil then
        return false
    end

    local sector = nil
    if type(removalEditor.addSector) == "function" then
        local ok, result = pcall(removalEditor.addSector, removalEditor, preset, node.sectorPath, node.instanceCount or 0)
        if ok and result then
            sector = result
        end
    end

    if not sector then
        sector = findSectorByPath(preset, node.sectorPath)
    end

    if not sector then
        sector = {
            path = node.sectorPath,
            nodeDeletions = {},
            nodeMutations = {},
            expectedNodes = node.instanceCount or 0
        }
        table.insert(preset.streaming.sectors, sector)
    end

    sector.nodeDeletions = sector.nodeDeletions or {}
    sector.nodeMutations = sector.nodeMutations or {}
    sector.expectedNodes = sector.expectedNodes or node.instanceCount or 0

    local existing = findRemovalByIndex(sector, node.instanceIndex)
    if existing then
        if existing.actorDeletions then
            local actorIndex = node.physicsActorOffset + node.physicsActorIndex
            if not utils.has_value(existing.actorDeletions, actorIndex) then
                table.insert(existing.actorDeletions, actorIndex)
            end
        end

        return saveRemovalPreset(removalEditor, preset, currentFile)
    end

    local removal = {
        type = node.nodeType,
        index = node.instanceIndex,
        nodeRef = node.nodeRef or "",
        resource = node.meshPath or node.templatePath or node.materialPath or node.effectPath or node.recordID or "",
        debugName = node.debugName or ""
    }

    local proxyID = node.nodeProxyID
    if proxyID and proxyID ~= 0 and type(removalEditor.createProxyMutation) == "function" then
        local okProxy, proxy = pcall(removalEditor.createProxyMutation, removalEditor, proxyID)
        if okProxy and proxy then
            local diff = 1
            local nodeDefinition = node.nodeDefinition
            if nodeDefinition then
                local okInstanced, isInstanced = pcall(function()
                    return type(nodeDefinition.IsA) == "function" and nodeDefinition:IsA("worldInstancedMeshNode")
                end)
                if okInstanced and isInstanced then
                    local transformsBuffer = safeGet(nodeDefinition, "worldTransformsBuffer")
                    local elements = tonumber(safeGet(transformsBuffer, "numElements"))
                    if elements and elements > 0 then
                        diff = elements
                    end
                end
            end

            if type(proxy.nbNodesUnderProxyDiff) == "number" then
                proxy.nbNodesUnderProxyDiff = proxy.nbNodesUnderProxyDiff - diff
            end

            removal.proxyHash = proxy.nodeRefHash
            removal.proxyDiff = diff
        end
    end

    if node.nodeType == "worldCollisionNode" then
        local actorDeletions = {}
        local numActors = tonumber(safeGet(node.nodeDefinition, "numActors")) or 0

        if numActors > 0 then
            if node.collision then
                table.insert(actorDeletions, node.physicsActorOffset + node.physicsActorIndex)
            else
                for actor = 0, numActors - 1 do
                    table.insert(actorDeletions, actor)
                end
            end
        end

        removal.expectedActors = numActors
        removal.actorDeletions = actorDeletions
    end

    local position = node.nodePosition or node.entityPosition or node.position
    local orientation = node.nodeOrientation or node.entityOrientation or node.orientation

    local serializedPosition = (position and position.x ~= nil and position.y ~= nil and position.z ~= nil)
        and utils.fromVector(position)
        or { x = 0, y = 0, z = 0 }
    local serializedOrientation = (orientation and orientation.i ~= nil and orientation.j ~= nil and orientation.k ~= nil and orientation.r ~= nil)
        and utils.fromQuaternion(orientation)
        or { i = 0, j = 0, k = 0, r = 1 }

    removal.position = serializedPosition
    removal.orientation = serializedOrientation

    table.insert(sector.nodeDeletions, 1, removal)
    return saveRemovalPreset(removalEditor, preset, currentFile)
end

---@param addRemoval function
---@param node any
---@return boolean
local function injectRemovalTarget(addRemoval, node)
    if not debug or type(debug.getupvalue) ~= "function" or type(debug.setupvalue) ~= "function" then
        return false
    end

    local targetIndex = rht.removalAddTargetUpvalueIndex
    if targetIndex and rht.removalAddTargetUpvalueOwner ~= addRemoval then
        targetIndex = nil
    end

    if targetIndex then
        local okName, upvalueName = pcall(debug.getupvalue, addRemoval, targetIndex)
        if not okName or upvalueName ~= "target" then
            targetIndex = nil
        end
    end

    if not targetIndex then
        targetIndex = findUpvalueIndex(addRemoval, "target")
        rht.removalAddTargetUpvalueIndex = targetIndex
        rht.removalAddTargetUpvalueOwner = addRemoval
    end

    if not targetIndex then
        return false
    end

    local okSet, setName = pcall(debug.setupvalue, addRemoval, targetIndex, node)
    if not okSet or setName ~= "target" then
        return false
    end

    local okRead, _, currentValue = pcall(debug.getupvalue, addRemoval, targetIndex)
    if not okRead then
        return true
    end

    return currentValue == node
end

---@param removalEditor any
---@param node any
---@return boolean
local function bridgeAddRemoval(removalEditor, node)
    local addRemoval = removalEditor and removalEditor.addRemoval or nil
    if type(addRemoval) ~= "function" then
        return false
    end

    local injectedTarget = injectRemovalTarget(addRemoval, node)

    if not injectedTarget and not rht.removalAddTargetWarned then
        rht.removalAddTargetWarned = true
        log("RemovalEditor bridge warning: internal target upvalue was not injected before addRemoval; fallback path may be used.")
    end

    local wasComplete = isNodeRemovalComplete(removalEditor, node)
    local ok, err = pcall(addRemoval, removalEditor, node)
    if not ok then
        log("RemovalEditor addRemoval failed: " .. tostring(err))
    end

    if isNodeRemovalComplete(removalEditor, node) then
        return true
    end

    if wasComplete then
        return true
    end

    local fallbackOk = manualAddRemoval(removalEditor, node)
    if fallbackOk then
        if ok then
            log("RemovalEditor addRemoval was incomplete; WB fallback append succeeded.")
        else
            log("WB fallback append succeeded after addRemoval failure.")
        end
        return true
    end

    if ok then
        log("RemovalEditor addRemoval did not produce a complete removal entry, and WB fallback append failed.")
    end

    return false
end

function rht.getRemovalEditor()
    local removalEditor = GetMod("removalEditor")
    if rht.removalEditor ~= removalEditor then
        rht.removalEditor = removalEditor
        rht.removalAddTargetUpvalueIndex = nil
        rht.removalAddTargetUpvalueOwner = nil
        rht.removalAddTargetWarned = false
        rht.removalPresetPathCache = {}
    end

    return rht.removalEditor
end

function rht.getRemovalStatus()
    local removalEditor = rht.getRemovalEditor()
    if not removalEditor then
        return false, false, nil
    end

    local currentFile = removalEditor.currentFile
    local hasActivePreset = currentFile ~= nil and currentFile ~= ""
    return true, hasActivePreset, currentFile
end

function rht.hasActiveRemovalPreset()
    local _, active = rht.getRemovalStatus()
    return active
end

function rht.getEffectiveReplacerMode()
    normalizeSettings()

    local mode = sanitizeReplacerMode(settings.rhtAddonReplacerMode)
    return mode, false
end

function rht.getModeLabel(mode)
    local key = sanitizeReplacerMode(mode)
    return REPLACER_MODE_LABELS[key] or REPLACER_MODE_LABELS.clone
end

function rht.sendToSearch(node)
    if not rht.spawnUI then
        return
    end

    local definition = getDefinition(node)
    if not definition then
        return
    end

    local resolved = resolveData(node, definition)
    local searchText = type(resolved) == "string" and resolved or ""

    if searchText ~= "" then
        rht.spawnUI.filter = searchText
    else
        rht.spawnUI.filter = ""
    end

    if not setSpawnSelection(definition.category, definition.sub) then
        return
    end

    rht.spawnUI.updateFilter()
end

local function getCloneDefinition(definition)
    local targetType = sanitizeMeshTargetType(settings.rhtAddonMeshTargetType)
    if targetType == "Static" and definition and definition.category == "Mesh" then
        return TYPE_MAP["worldStaticMeshNode"]
    end

    return definition
end

local function spawnClone(node, definition)
    if not rht.spawnUI then
        return nil
    end

    local cloneDefinition = getCloneDefinition(definition)
    local resolvedData = resolveData(node, cloneDefinition)
    if not resolvedData or resolvedData == "" then
        log("No path/data could be resolved for node.")
        return nil
    end

    if not setSpawnSelection(cloneDefinition.category, cloneDefinition.sub) then
        log("Could not select Spawn New category/variant for " .. tostring(cloneDefinition.category) .. " / " .. tostring(cloneDefinition.sub))
        return nil
    end

    local activeList = rht.spawnUI.getActiveSpawnList()
    if not activeList or not activeList.class then
        log("Could not resolve Spawn New class for clone operation.")
        return nil
    end

    local entry = {
        name = "Clone",
        data = {}
    }

    if type(resolvedData) == "table" then
        entry.data = resolvedData
        entry.name = tostring(cloneDefinition.sub or "Node") .. " (Clone)"
    else
        entry.data = { spawnData = resolvedData }
        entry.name = tostring(resolvedData)
    end

    local clone = rht.spawnUI.spawnNew(entry, activeList.class, false)
    if not clone then
        return nil
    end

    local position = node and (node.nodePosition or node.entityPosition) or nil
    local rotation = node and (node.nodeOrientation or node.entityOrientation) or nil
    local scale = node and (node.nodeScale or Vector4.new(1, 1, 1, 1)) or nil

    local function applyCloneTransform()
        if not clone or not clone.parent then
            return
        end

        applyTransform(clone, position, rotation, scale)
    end

    -- Apply immediately for responsiveness.
    applyCloneTransform()

    -- Apply once attached and then force a one-time refresh.
    -- Some node types finish internal component setup after attach; this refresh makes
    -- the visualized rotation match the already-correct stored rotation.
    local didRefreshForRotation = false
    if clone.spawnable and clone.spawnable.registerSpawnedAndAttachedCallback then
        local function onAttached()
            applyCloneTransform()
            Cron.After(0.05, applyCloneTransform)

            if not didRefreshForRotation and rotation and clone.spawnable and clone.spawnable.respawn then
                didRefreshForRotation = true
                Cron.After(0.01, function()
                    if not clone or not clone.parent or not clone.spawnable then
                        return
                    end

                    clone.spawnable:respawn()
                end)
            end
        end

        clone.spawnable:registerSpawnedAndAttachedCallback(onAttached)

        if clone.spawnable.isSpawned and clone.spawnable:isSpawned() then
            onAttached()
        end
    else
        Cron.After(0.1, applyCloneTransform)
    end

    return clone
end

function rht.executeReplacer(node)
    local actionNode = getLiveInspectorNode(node)
    if not actionNode then
        return
    end

    local definition = getDefinition(actionNode)
    if not definition or not definition.replacer then
        return
    end

    local mode = select(1, rht.getEffectiveReplacerMode())

    local clone = spawnClone(actionNode, definition)
    if not clone then
        return
    end

    if isReplacementMode(mode) then
        local removalEditor = rht.getRemovalEditor()
        if removalEditor and removalEditor.addRemoval then
            if rht.hasActiveRemovalPreset() then
                local added = bridgeAddRemoval(removalEditor, actionNode)
                if not added then
                    log("Replacement addRemoval did not complete.")
                end
            else
                log("Replace mode selected but no Removal Editor preset is active, skipping addRemoval.")
            end
        else
            log("Replace mode selected but Removal Editor is not loaded.")
        end
    end

    if mode == "replace_hide" then
        local inspector = Game.GetWorldInspector()
        local hideNode = actionNode
        if (not hideNode.nodeInstance) and node and node.nodeInstance then
            hideNode = node
        end

        if inspector and hideNode and hideNode.nodeInstance then
            inspector:ToggleNodeVisibility(hideNode.nodeInstance)
        else
            log("Replace-hide warning: nodeInstance not available on inspector target.")
        end
    end
end

function rht.getTargetActions(node)
    if not isWorldNode(node) then
        return nil
    end

    local actions = {
        {
            type = "button",
            label = "[WB] Send to search",
            callback = function()
                rht.sendToSearch(node)
            end
        }
    }

    local definition = getDefinition(node)
    if definition and definition.replacer then
        local mode = select(1, rht.getEffectiveReplacerMode())
        table.insert(actions, {
            type = "button",
            label = "[WB] Replacer: " .. rht.getModeLabel(mode),
            callback = function()
                rht.executeReplacer(node)
            end
        })
    end

    return actions
end

function rht.drawSettings()
    normalizeSettings()

    if not ImGui.TreeNodeEx("Red Hot Tools - World Inspector addon", ImGuiTreeNodeFlags.SpanFullWidth) then
        return
    end

    local redHotToolsLoaded = GetMod("RedHotTools") ~= nil
    local hasRemovalEditor, hasRemovalPreset, presetName = rht.getRemovalStatus()

    if not redHotToolsLoaded then
        ImGui.TextColored(1, 0.15, 0.15, 1, "WARNING: Red Hot Tools is not loaded.")
    else
        style.styledText("Red Hot Tools detected.", style.successColor)
    end

    if not hasRemovalEditor then
        style.styledText("Removal Editor is not loaded. Replace modes cannot add removals.", style.warnColor)
    elseif hasRemovalPreset then
        style.styledText("Active Removal preset: " .. tostring(presetName), style.successColor)
    else
        style.styledText("No Removal Editor preset selected.", style.warnColor)
        style.styledTextWrapped("Replace modes stay available, but they cannot add removals without an active preset.", style.mutedColor)
    end

    ImGui.Dummy(0, 8 * style.viewSize)
    style.sectionHeaderStart("Replacer mode", "Defines the behavior of the Replacer action in Red Hot Tools World Inspector.\n - Clone: Spawns a copy only.\n - Replace: Spawns a copy and adds the original to Removal Editor.\n - Replace & Hide: Spawns a copy, adds the original to Removal Editor, and hides the original immediately.")

    local mode = sanitizeReplacerMode(settings.rhtAddonReplacerMode)

    if ImGui.RadioButton("Clone", mode == "clone") then
        settings.rhtAddonReplacerMode = "clone"
        settings.save()
        mode = "clone"
    end
    style.tooltip("Spawn a copy only.")

    if ImGui.RadioButton("Replace", mode == "replace") then
        settings.rhtAddonReplacerMode = "replace"
        settings.save()
        mode = "replace"
    end
    if hasRemovalPreset then
        style.tooltip("Spawn a copy and add the original to Removal Editor.")
    else
        style.tooltip("Spawn a copy. No active Removal Editor preset means no removal entry will be added.")
    end
    if not hasRemovalPreset then
        ImGui.SameLine()
        style.styledText(IconGlyphs.AlertOutline, style.warnColor)
        style.tooltip("No active Removal Editor preset: nodes won't be added to removal list.")
    end

    if ImGui.RadioButton("Replace & Hide", mode == "replace_hide") then
        settings.rhtAddonReplacerMode = "replace_hide"
        settings.save()
        mode = "replace_hide"
    end
    if hasRemovalPreset then
        style.tooltip("Spawn a copy, add the original to Removal Editor, and hide the original immediately.")
    else
        style.tooltip("Spawn a copy and hide the original now. No active preset means no removal entry will be added.")
    end
    if not hasRemovalPreset then
        ImGui.SameLine()
        style.styledText(IconGlyphs.AlertOutline, style.warnColor)
        style.tooltip("No active Removal Editor preset: nodes won't be added to removal list.")
    end

    ImGui.Dummy(0, 8 * style.viewSize)
    style.sectionHeaderStart("Mesh target type", "Defines how meshes are cloned.")

    local targetType = sanitizeMeshTargetType(settings.rhtAddonMeshTargetType)

    if ImGui.RadioButton("Auto (Match Source)", targetType == "Auto") then
        settings.rhtAddonMeshTargetType = "Auto"
        settings.save()
        targetType = "Auto"
    end
    style.tooltip("Clone using the source node type.")

    if ImGui.RadioButton("Force Static", targetType == "Static") then
        settings.rhtAddonMeshTargetType = "Static"
        settings.save()
        targetType = "Static"
    end
    style.tooltip("Force mesh-like targets to spawn as Static Mesh.")

    ImGui.Dummy(0, 8 * style.viewSize)
    style.styledTextWrapped("Adds one-click World Inspector actions in Red Hot Tools for search and replace workflows.", style.mutedColor)
    
    ImGui.Dummy(0, 4 * style.viewSize)
    ImGui.TreePop()
end

function rht.init(spawner)
    normalizeSettings()

    rht.spawner = spawner
    rht.spawnUI = spawner and spawner.baseUI and spawner.baseUI.spawnUI or nil
    rht.redHotTools = GetMod("RedHotTools")
    rht.removalEditor = GetMod("removalEditor")

    if not rht.redHotTools then
        return
    end

    rht.redHotTools.RegisterExtension({
        getTargetActions = function(node)
            return rht.getTargetActions(node)
        end
    })
end

return rht
