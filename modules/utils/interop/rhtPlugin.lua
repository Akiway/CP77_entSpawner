local settings = require("modules/utils/core/settings")
local style = require("modules/ui/style")
local Cron = require("modules/utils/vendor/Cron")
local utils = require("modules/utils/core/utils")
local gameUtils = require("modules/utils/game/gameUtils")
local logger = require("modules/utils/core/logger")
local axl = require("modules/utils/interop/axl")
local registry = require("modules/utils/game/nodeRefRegistry")
local history = require("modules/utils/project/history")
local element = require("modules/classes/editor/element")
local red = require("modules/utils/interop/redConverter")

---@class rht
---@field public spawnUI spawnUI?
---@field public spawner spawner?
---@field public redHotTools any
---@field public removalEditor any
local rht = {
    spawnUI = nil,
    spawner = nil,
    redHotTools = nil,
    removalEditor = nil
}

local function log(message)
    logger:info("[RHT plugin] " .. tostring(message))
end

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

    -- Same ordered list of non-empty enum names the loop used to rebuild per call, but cached.
    for index, name in ipairs(utils.enumTable(enumName)) do
        if name == targetName then
            return index - 1
        end
    end

    return 0
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

---The node object behind a Red Hot Tools target. It is reachable through the loaded definition
---or through the streamed instance, and which of the two is filled in depends on how the
---target was picked, so take whichever actually reads back rather than assuming.
---@param node any
---@param probe string Property that must read back for the object to count as usable.
---@return any?
local function getNativeNode(node, probe)
    local function readable(candidate)
        return safeGet(candidate, probe) ~= nil and candidate or nil
    end

    local native = readable(node and node.nodeDefinition)
    if not native and node and node.nodeInstance and type(node.nodeInstance.GetNode) == "function" then
        native = readable(node.nodeInstance:GetNode())
    end

    return native
end

-- Notifier class -> the trigger type the editor lists it under. Only the ones the Trigger Area
-- variant can actually author: an area whose notifier is missing here keeps its class default,
-- which is what Ambient and Conversation areas rely on.
local TRIGGER_TYPE_BY_NOTIFIER = {
    ["worldInteriorAreaNotifier"] = "Interior",
    ["worldLocationAreaNotifier"] = "Location",
    ["questTriggerNotifier_Quest"] = "Quest Notifier",
    ["worldQuestPreventionNotifier"] = "Prevention",
    ["worldVehicleForbiddenAreaNotifier"] = "Vehicle Forbidden",
    ["questContentBlockTriggerAreaNotifier"] = "Content Block",
    ["worldEnvAreaNotifier"] = "Env Trigger"
}

---Channel checkboxes from the notifier's channel bitfield. The RED converter flattens it to its
---comma-separated member list, but falls back to a plain mask when the bitfield definition
---cannot be resolved, so both forms are accepted.
---@param includeChannels any
---@return table
local function toTriggerChannels(includeChannels)
    local channels = {}
    local text = tostring(includeChannels or "")
    local mask = tonumber((text:gsub("ULL", ""):gsub("LL", "")))
    local enabled = {}

    for name in text:gmatch("[^,%s]+") do
        enabled[name] = true
    end

    for index, name in ipairs(style.triggerChannelEnum) do
        if mask then
            channels[index] = math.floor(mask / 2 ^ (index - 1)) % 2 == 1
        else
            channels[index] = enabled[name] == true
        end
    end

    return channels
end

---Overlays converted notifier values onto the editor's own default trigger for that type.
---The default declares exactly which fields the trigger UI edits and in which Lua types, which
---the converted values cannot be trusted for: it produces export-shaped data, where booleans
---are already flattened to 1/0 and the checkboxes would choke on them.
---@param default table Default trigger table, mutated in place.
---@param converted table
---@return table default
local function applyConvertedTrigger(default, converted)
    for key, fallback in pairs(default) do
        local value = converted[key]

        if value ~= nil then
            if type(fallback) == "boolean" then
                default[key] = value == true or value == 1
            elseif type(fallback) == "number" then
                default[key] = tonumber(value) or fallback
            elseif type(fallback) == type(value) then
                default[key] = value
            end
        end
    end

    return default
end

---Trigger data of a `worldTriggerAreaNode`, in the shape the editor's trigger UI edits and the
---exporter writes back. The notifier is converted whole by the project's RED converter, so no
---field of any notifier kind has to be read by hand; only the type label the UI selects on and
---the channel checkboxes are derived separately.
---@param node any
---@return table
local function readTriggerAreaData(node)
    local notifiers = safeGet(getNativeNode(node, "notifiers"), "notifiers")
    local notifier = type(notifiers) == "table" and notifiers[1] or nil
    if not notifier then
        return {}
    end

    local ok, converted = pcall(red.redDataToJSON, notifier)
    if not ok or type(converted) ~= "table" then
        log("Could not convert trigger notifier: " .. tostring(converted))
        return {}
    end

    local triggerType = TRIGGER_TYPE_BY_NOTIFIER[tostring(converted["$type"])]
    if not triggerType then
        return {}
    end

    -- Required late: the class pulls enum tables that are only there once the game is up.
    local probe = require("modules/classes/spawn/area/triggerArea"):new()
    local buildDefault = probe:getAvailableTriggers()[triggerType]
    if not buildDefault then
        return {}
    end
    buildDefault(probe, true)

    return {
        triggerType = triggerType,
        trigger = applyConvertedTrigger(probe.trigger, converted),
        channels = toTriggerChannels(converted.includeChannels)
    }
end

---Data of a `worldBendedMeshNode`, in the shape the Bended Mesh spawnable loads. What makes the
---node more than a static mesh is its deformation: one matrix per path point, which the
---spawnable's own converter reads back into the path it edits. The deformed box comes across as
---authored, even though the spawnable refits it to that path once the mesh bounds are known.
---@param node any
---@return table?
local function readBendedMeshData(node)
    local function toBool(value, defaultValue)
        if type(value) == "boolean" then
            return value
        end

        if value == nil then
            return defaultValue
        end

        return tonumber((tostring(value):gsub("ULL", ""):gsub("LL", ""))) == 1
    end

    local function toName(value)
        if type(value) == "string" then
            return value
        end

        local name = safeGet(value, "value")
        return type(name) == "string" and name or ""
    end

    local native = getNativeNode(node, "deformationData")

    local meshPath = type(node and node.meshPath) == "string" and node.meshPath or ""
    if meshPath == "" then
        local hash = safeGet(safeGet(native, "mesh"), "hash")
        if hash then
            meshPath = ResRef.FromHash(hash):ToString()
        end
    end

    if meshPath == "" then
        return nil
    end

    local data = { spawnData = meshPath }

    local appearance = toName(node and node.meshAppearance or safeGet(native, "meshAppearance"))
    if appearance ~= "" and appearance ~= "None" then
        data.app = appearance
    end

    if not native then
        return data
    end

    -- A deformation that cannot be read must not cost the clone its mesh, so the path falls back
    -- to the default the spawnable derives from the mesh itself.
    local matrices = safeGet(native, "deformationData")
    if type(matrices) == "table" and #matrices > 0 then
        local rebuild = require("modules/classes/spawn/mesh/bendedMesh").pathPointsFromMatrices
        local ok, pathPoints = pcall(rebuild, matrices)

        if ok and type(pathPoints) == "table" and #pathPoints > 0 then
            data.pathPoints = pathPoints
        else
            log("Could not rebuild the bended mesh path: " .. tostring(pathPoints))
        end
    end

    local boxMin = safeGet(safeGet(native, "deformedBox"), "Min")
    local boxMax = safeGet(safeGet(native, "deformedBox"), "Max")
    if boxMin and boxMax then
        data.deformedBox = {
            min = { x = boxMin.x, y = boxMin.y, z = boxMin.z, w = 1 },
            max = { x = boxMax.x, y = boxMax.y, z = boxMax.z, w = 1 }
        }
    end

    data.isBendedRoad = toBool(safeGet(native, "isBendedRoad"), true)
    data.removeFromRainMap = toBool(safeGet(native, "removeFromRainMap"), false)
    data.version = tonumber((tostring(safeGet(native, "version")):gsub("ULL", ""):gsub("LL", ""))) or 0

    -- Shadow modes keep the spawnable's own defaults when the node cannot be read, since index 0
    -- is a meaningful setting of its own ("Default") rather than an absent value.
    local castShadows = safeGet(native, "castShadows")
    if castShadows ~= nil then
        data.castShadows = getEnumIndex("shadowsShadowCastingMode", castShadows)
    end

    local castLocalShadows = safeGet(native, "castLocalShadows")
    if castLocalShadows ~= nil then
        data.castLocalShadows = getEnumIndex("shadowsShadowCastingMode", castLocalShadows)
    end

    local navmeshImpact = safeGet(safeGet(native, "navigationSetting"), "navmeshImpact")
    if navmeshImpact ~= nil then
        data.navigationImpact = getEnumIndex("NavGenNavmeshImpact", navmeshImpact)
    end

    return data
end

---Definition of one area node type. Area nodes hold nothing but a polygon plus whatever their
---own kind adds, and the polygon is rebuilt separately (see `attachAreaOutline`) because
---entSpawner keeps it in a group of outline markers instead of on the node itself.
---@param sub string Spawn New variant under the "Area" category.
---@param extras? fun(node: any, native: any): table Fields beyond the shape, for the kinds that have any.
---@return table
local function areaDefinition(sub, extras)
    return {
        dataRetrieval = function(node)
            if not extras then
                return {}
            end

            return extras(node, getNativeNode(node, "color"))
        end,
        category = "Area",
        sub = sub,
        outline = true,
        replacer = true
    }
end

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
    -- All three destruction nodes live in the one "Destructible Mesh" variant, so the module
    -- path has to say which of its hosted classes the clone becomes.
    ["worldPhysicalDestructionNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Destructible Mesh",
        modulePath = "physics/physicalDestruction",
        replacer = true
    },
    ["worldBakedDestructionNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Destructible Mesh",
        modulePath = "physics/bakedDestruction",
        replacer = true
    },
    ["worldInstancedDestructibleMeshNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Destructible Mesh",
        modulePath = "physics/destructibleMesh",
        replacer = true
    },
    ["worldBendedMeshNode"] = {
        dataRetrieval = readBendedMeshData,
        category = "Mesh",
        sub = "Bended Mesh",
        replacer = true
    },
    ["worldStaticOccluderMeshNode"] = {
        dataRetrieval = function(node)
            local meshPath = node and node.meshPath or ""
            if type(meshPath) ~= "string" or meshPath == "" then
                return nil
            end

            local normalizedPath = meshPath:lower():gsub("/", "\\")
            local occluderMesh = 1
            if normalizedPath:find("plane_occluder_onesided_xz.mesh", 1, true) then
                occluderMesh = 2
            elseif normalizedPath:find("plane_occluder_twosided_xz.mesh", 1, true) then
                occluderMesh = 3
            end

            return {
                spawnData = "",
                occluderMesh = occluderMesh,
                occluderType = getEnumIndex("visWorldOccluderType", node.occluderType)
            }
        end,
        category = "Meta",
        sub = "Occluder",
        replacer = true
    },
    ["worldFoliageNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Static Mesh",
        replacer = true
    },
    ["worldStaticMeshNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Static Mesh",
        replacer = true
    },
    ["worldInstancedMeshNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Static Mesh",
        replacer = true
    },
    ["worldMeshNode"] = {
        data = "meshPath",
        category = "Mesh",
        sub = "Static Mesh",
        replacer = true
    },
    -- Abstract base for every proxy mesh node (worldGenericProxyMeshNode, worldBuildingProxyMeshNode, ...).
    -- Matched via IsA before worldMeshNode so proxies clone as a Proxy Mesh instead of a plain Static Mesh.
    ["worldPrefabProxyMeshNode"] = {
        dataRetrieval = function(node)
            local meshPath = node and node.meshPath or ""
            if type(meshPath) ~= "string" or meshPath == "" then
                return nil
            end

            local data = { spawnData = meshPath }

            local native = node.nodeDefinition
            if native then
                local ok, value = pcall(function()
                    return native.nearAutoHideDistance
                end)
                if ok and value ~= nil then
                    local numeric = type(value) == "number" and value or tonumber(tostring(value))
                    if numeric then
                        data.nearAutoHideDistance = numeric
                    end
                end
            end

            return data
        end,
        category = "Mesh",
        sub = "Proxy Mesh",
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
                lightChannels = getLightChannels(safeGet(native, "lightChannel", nil)),
                unit = getEnumIndex("ELightUnit", safeGet(native, "unit", 0)),
                scaleGI = safeGet(native, "scaleGI", 100),
                scaleEnvProbes = safeGet(native, "scaleEnvProbes", 100),
                shadowRadius = safeGet(native, "shadowRadius", -1),
                shadowSoftnessMode = getEnumIndex("ELightShadowSoftnessMode", safeGet(native, "shadowSoftnessMode", 2)),
                areaShape = getEnumIndex("EAreaLightShape", safeGet(native, "areaShape", 1)),
                areaTwoSided = toBool(safeGet(native, "areaTwoSided", true)),
                areaRectSideA = safeGet(native, "areaRectSideA", 1),
                areaRectSideB = safeGet(native, "areaRectSideB", 1),
                lightGroup = getEnumIndex("rendLightGroup", safeGet(native, "group", 0)),
                envColorGroup = getEnumIndex("EEnvColorGroup", safeGet(native, "envColorGroup", 0)),
                colorGroupSaturation = safeGet(native, "colorGroupSaturation", 100),
                portalAngleCutoff = safeGet(native, "portalAngleCutoff", 0),
                allowDistantLight = toBool(safeGet(native, "allowDistantLight", false))
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
            local function getCNameValue(value)
                if type(value) == "string" then
                    return value
                end

                if not value then
                    return ""
                end

                local ok, name = pcall(function()
                    return value.value
                end)

                return ok and name and tostring(name) or ""
            end

            if not node or not node.nodeInstance or type(node.nodeInstance.GetNode) ~= "function" then
                return nil
            end

            local nativeNode = node.nodeInstance:GetNode()
            if not nativeNode then
                return nil
            end

            local nodeSettings = nativeNode.Settings
            if not nodeSettings then
                return nil
            end

            local activeEvents = nodeSettings.EventsOnActive
            if not activeEvents or #activeEvents < 1 then
                return nil
            end

            local soundEvent = getCNameValue(activeEvents[1] and activeEvents[1].event)
            if soundEvent == "" then
                return nil
            end

            return {
                spawnData = soundEvent,
                emitterMetadataName = getCNameValue(nativeNode.emitterMetadataName)
            }
        end,
        category = "Deco",
        sub = "Static Audio Emitter",
        replacer = true
    },
    ["worldAISpotNode"] = {
        dataRetrieval = function(node)
            local function toBool(value, defaultValue)
                if type(value) == "boolean" then
                    return value
                end

                if value == nil then
                    return defaultValue
                end

                return tonumber((tostring(value):gsub("ULL", ""):gsub("LL", ""))) == 1
            end

            -- markings is an array:CName, which CET hands over as a plain list of CName.
            local function toMarkings(value)
                local markings = {}
                if type(value) ~= "table" then
                    return markings
                end

                for _, marking in ipairs(value) do
                    local name = type(marking) == "string" and marking or safeGet(marking, "value")
                    if type(name) == "string" and name ~= "" and name ~= "None" then
                        table.insert(markings, name)
                    end
                end

                return markings
            end

            local native = getNativeNode(node, "spot")

            -- Red Hot Tools resolves the workspot itself; reading the node is the fallback.
            local workspot = type(node and node.workspotPath) == "string" and node.workspotPath or ""
            if workspot == "" then
                local hash = safeGet(safeGet(safeGet(native, "spot"), "resource"), "hash")
                if hash then
                    workspot = ResRef.FromHash(hash):ToString()
                end
            end

            -- Only an AIActionSpot carries a workspot; the other AISpot kinds have nothing to clone.
            if workspot == "" then
                return nil
            end

            return {
                spawnData = workspot,
                isWorkspotInfinite = toBool(safeGet(native, "isWorkspotInfinite"), true),
                isWorkspotStatic = toBool(safeGet(native, "isWorkspotStatic"), false),
                markings = toMarkings(safeGet(native, "markings"))
            }
        end,
        category = "AI",
        sub = "AI Spot",
        replacer = true,
        preserveNodeRef = true
    },
    ["worldStaticMarkerNode"] = {
        dataRetrieval = function(node)
            -- The node's only authored content is which marker kind sits in `data`; entSpawner
            -- models that as the one "quest marker" flag it can write back out.
            local marker = safeGet(getNativeNode(node, "isEnabled"), "data")
            local questMarker = false

            if marker then
                pcall(function()
                    questMarker = marker:IsA("worldQuestMarker")
                end)
            end

            return { questMarker = questMarker }
        end,
        category = "Meta",
        sub = "Static Marker",
        replacer = true
    },
    -- Areas are all one shape node underneath. Notifier/trigger contents are handles this
    -- addon does not reconstruct, so those variants clone with their editor defaults and only
    -- the shape (plus anything listed below) comes across.
    ["worldTriggerAreaNode"] = areaDefinition("Trigger Area", readTriggerAreaData),
    -- A location area is a trigger area carrying a district notifier. Its own `locationName`
    -- has no counterpart in the editor, which authors every trigger as worldTriggerAreaNode.
    ["worldLocationAreaNode"] = areaDefinition("Trigger Area", readTriggerAreaData),
    ["worldAmbientAreaNode"] = areaDefinition("Ambient Area"),
    ["worldInterestingConversationsAreaNode"] = areaDefinition("Conversation Area"),
    ["worldCrowdNullAreaNode"] = areaDefinition("Crowd Null Area"),
    ["worldPreventionFreeAreaNode"] = areaDefinition("Prevention Free"),
    ["worldWaterNullAreaNode"] = areaDefinition("Water Null"),
    ["gameKillTriggerNode"] = areaDefinition("Kill Area"),
    ["gameWorldBoundaryNode"] = areaDefinition("World Boundary", function(node)
        -- A boundary keeps its outline in the node's own frame, and entSpawner stores that
        -- frame as the yaw it re-applies on export.
        local euler = gameUtils.toEulerAnglesSafe(node.nodeOrientation)
        local yaw = euler and tonumber(euler.yaw) or 0

        return { orientation = (yaw % 360 + 360) % 360 }
    end),
    ["worldGuardAreaNode"] = areaDefinition("Guard Area", function(_, native)
        -- The connected communities and the pursuit area are NodeRefs pointing into the
        -- vanilla world, which a clone cannot resolve, so only the plain range comes across.
        return { pursuitRange = tonumber(safeGet(native, "pursuitRange")) or 0 }
    end),
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
        replacer = true
    }
}

local TYPE_PRIORITY = {
    "worldPopulationSpawnerNode",
    "worldDeviceNode",
    "worldEntityNode",
    "worldPhysicalDestructionNode",
    "worldBakedDestructionNode",
    "worldInstancedDestructibleMeshNode",
    "worldBendedMeshNode",
    "worldStaticOccluderMeshNode",
    "worldFoliageNode",
    "worldStaticMeshNode",
    "worldInstancedMeshNode",
    "worldPrefabProxyMeshNode",
    "worldMeshNode",
    "worldStaticDecalNode",
    "worldStaticParticleNode",
    "worldEffectNode",
    "worldStaticLightNode",
    "worldStaticSoundEmitterNode",
    "worldAISpotNode",
    "worldStaticMarkerNode",
    -- Ambient, conversation and location areas derive from worldTriggerAreaNode, so they have
    -- to be tried first for an unrecognized subclass to land on the closest match it really is.
    "worldAmbientAreaNode",
    "worldInterestingConversationsAreaNode",
    "worldLocationAreaNode",
    "worldTriggerAreaNode",
    "worldCrowdNullAreaNode",
    "worldPreventionFreeAreaNode",
    "worldWaterNullAreaNode",
    "gameKillTriggerNode",
    "gameWorldBoundaryNode",
    "worldGuardAreaNode",
    "worldReflectionProbeNode"
}

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

    if TYPE_MAP[node.nodeType] then
        return node.nodeType
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

local function applyTransform(target, position, rotation, scale)
    if not target then
        return
    end

    if position and target.setPosition then
        target:setPosition(position)
    end

    local euler = gameUtils.toEulerAnglesSafe(rotation)
    if euler and target.setRotation then
        target:setRotation(euler)
    end

    local scaleVector = toScaleVector(scale)
    if scaleVector and target.setScale then
        target:setScale(scaleVector, true)
    end
end

local function setSpawnSelection(category, sub)
    if not rht.spawnUI then
        return false
    end

    local okSelect, wasSelected = pcall(function()
        return rht.spawnUI.selectTypeAndVariant(category, sub)
    end)
    if not okSelect or not wasSelected then
        return false
    end

    return true
end

local function isReplacementMode(mode)
    return mode == "replace" or mode == "replace_hide"
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

---Inserts a removal entry straight into Removal Editor's live preset table
---(`removalEditor.presets[currentFile]`), so it shows in its window immediately.
---We can't call Removal Editor's own `addRemoval`: it needs a file-local `target`
---upvalue we can't set (CET has no `debug.setupvalue`), and CET's io sandbox blocks
---writing its `.xl`. Reusing its `addSector`/`createProxyMutation` (parameter-based,
---no `target`) plus a table insert is the only route that works. See
---`persistViaDeleteRemoval` for disk persistence.
---@param removalEditor any
---@param node any
---@return boolean
local function insertRemovalInMemory(removalEditor, node)
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

        return true
    end

    local removal = {
        type = node.nodeType,
        index = node.instanceIndex,
        nodeRef = node.nodeRef or "",
        resource = node.meshPath or node.templatePath or node.materialPath or node.effectPath or node.recordID or node.workspotPath or "",
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
    return true
end

---Persists Removal Editor's active preset to disk. We can't write its `.xl` (io sandbox)
---or drive its `addRemoval` (needs `target`), so we call `removal:deleteRemoval` — its only
---public method that ends in a save — with args crafted so every step before the save is a
---no-op and the real preset is only read, never mutated (see inline comments). Best-effort:
---the sandbox blocks reading the file back, so the on-disk result can't be confirmed here.
---@param removalEditor any
---@param preset table
---@return boolean persisted
local function persistViaDeleteRemoval(removalEditor, preset)
    if type(removalEditor.deleteRemoval) ~= "function" then
        return false
    end

    if type(preset) ~= "table" or type(preset.streaming) ~= "table" or type(preset.streaming.sectors) ~= "table" then
        return false
    end

    -- Refuse unless this is the genuine active preset; deleteRemoval saves whatever we pass.
    local currentFile = removalEditor.currentFile
    if not currentFile or currentFile == "" then
        return false
    end
    if type(removalEditor.presets) ~= "table" or removalEditor.presets[currentFile] ~= preset then
        return false
    end

    local sectorCountBefore = #preset.streaming.sectors

    -- Decoy stays non-empty after deleteRemoval's internal table.remove, so its branch that
    -- prunes the real sector list never fires.
    local decoySector = { nodeDeletions = { false, false }, nodeMutations = {} }
    -- No proxyHash, so its updateProxyMutation call returns early.
    local decoyEntry = {}
    -- Out-of-range index: even if the prune branch runs, table.remove(list, #list+1) is a no-op.
    local safeSectorKey = sectorCountBefore + 1

    local ok, err = pcall(removalEditor.deleteRemoval, removalEditor, preset, decoySector, decoyEntry, nil, safeSectorKey)
    if not ok then
        log("Removal preset persist via deleteRemoval failed: " .. tostring(err))
        return false
    end

    -- Detection net: the crafted args must not have altered the real structure.
    if #preset.streaming.sectors ~= sectorCountBefore then
        log("WARNING: Removal preset persist changed sector count ("
            .. tostring(sectorCountBefore) .. " -> " .. tostring(#preset.streaming.sectors)
            .. "); Removal Editor internals may have changed - persistence disabled for safety is advised.")
        return false
    end

    return true
end

---@param removalEditor any
---@param node any
---@return boolean
local function bridgeAddRemoval(removalEditor, node)
    if not removalEditor then
        return false
    end

    if isNodeRemovalComplete(removalEditor, node) then
        return true
    end

    if not insertRemovalInMemory(removalEditor, node) then
        return false
    end

    -- The in-memory insert already makes the removal appear in the Removal Editor window.
    -- Persisting to disk is best-effort and never gates success.
    local preset = getActivePreset(removalEditor)
    if preset then
        persistViaDeleteRemoval(removalEditor, preset)
    end

    return true
end

function rht.getRemovalEditor()
    local removalEditor = GetMod("removalEditor")
    if rht.removalEditor ~= removalEditor then
        rht.removalEditor = removalEditor
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

    -- Table-returning resolvers (e.g. Proxy Mesh, AI Spot) don't hand back a plain path, but
    -- the node still carries the one the browser is filtered by.
    if searchText == "" and type(node.meshPath) == "string" then
        searchText = node.meshPath
    end

    if searchText == "" and type(node.workspotPath) == "string" then
        searchText = node.workspotPath
    end

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

---@param position Vector4|table?
---@return boolean
local function isRHTNodePositionVisible(position)
    return position ~= nil and (position.x ~= 0 or position.y ~= 0 or position.z ~= 0)
end

---@param orientation Quaternion|table?
---@return boolean
local function isRHTNodeOrientationVisible(orientation)
    return orientation ~= nil
        and (orientation.i ~= 0 or orientation.j ~= 0 or orientation.k ~= 0 or orientation.r ~= 1)
end

---@param scale Vector4|table?
---@return boolean
local function isRHTNodeScaleVisible(scale)
    return scale ~= nil and (scale.x ~= 1 or scale.y ~= 1 or scale.z ~= 1)
end

---@param node any
function rht.copyAXLNodeMutation(node)
    if not node then
        return
    end

    local definition = getDefinition(node)
    local resolvedResource = resolveData(node, definition)
    local resource = type(resolvedResource) == "string" and resolvedResource or nil
    resource = resource
        or node.meshPath
        or node.templatePath
        or node.materialPath
        or node.effectPath
        or node.recordID
        or node.workspotPath
        or ""

    local position = isRHTNodePositionVisible(node.nodePosition) and node.nodePosition or node.entityPosition
    local orientation = isRHTNodeOrientationVisible(node.nodeOrientation) and node.nodeOrientation or node.entityOrientation
    local scale = isRHTNodeScaleVisible(node.nodeScale) and node.nodeScale or nil
    local appearance = node.meshAppearance or node.appearanceName or ""

    ImGui.SetClipboardText(axl.formatNodeMutation({
        sectorPath = node.sectorPath,
        expectedNodes = node.instanceCount,
        index = node.instanceIndex,
        debugName = node.debugName,
        nodeType = node.nodeType,
        resource = resource,
        appearance = appearance,
        position = position,
        orientation = orientation,
        scale = scale
    }, {
        position = position ~= nil,
        orientation = orientation ~= nil,
        scale = scale ~= nil
    }))
end

---World-space outline of an area node. The node stores its polygon as points local to its own
---transform plus one height for the extruded volume; the editor expresses the same shape as a
---group of outline markers standing in the world.
---@param node any
---@return Vector4[] points
---@return number height
local function readAreaOutline(node)
    local points = {}

    local outline = safeGet(getNativeNode(node, "outline"), "outline")
    local rawPoints = safeGet(outline, "points")
    local origin = node and (node.nodePosition or node.entityPosition or node.position) or nil

    if type(rawPoints) ~= "table" or not origin then
        return points, 0
    end

    local orientation = node.nodeOrientation or node.entityOrientation or node.orientation
    local lowestZ = nil

    for _, point in ipairs(rawPoints) do
        local offset = Vector4.new(tonumber(point.x) or 0, tonumber(point.y) or 0, tonumber(point.z) or 0, 0)

        if orientation then
            local ok, rotated = pcall(function()
                return orientation:Transform(offset)
            end)
            if ok and rotated then
                offset = rotated
            end
        end

        local world = utils.addVector(origin, offset)
        if lowestZ == nil or world.z < lowestZ then
            lowestZ = world.z
        end

        table.insert(points, world)
    end

    -- Outline markers force one shared Z across their whole group as they assemble, so settle
    -- on the base of the volume instead of letting spawn order decide which point wins.
    for _, point in ipairs(points) do
        point.z = lowestZ
    end

    return points, tonumber(safeGet(outline, "height")) or 0
end

---Rebuilds an area's shape as the group of outline markers the editor derives it from, and
---points the clone at that group. An area spawnable holds no geometry of its own, so the clone
---is only a copy of the node once the group exists.
---
---Both end up under a wrapper group because an area only accepts outlines sharing its own root:
---dropped side by side under the tree root, each would be a root of its own and the outline
---would never show up in the area's picker.
---@param node any
---@param clone any spawnableElement
---@return boolean
local function attachAreaOutline(node, clone)
    local spawnable = clone and clone.spawnable
    local parent = clone and clone.parent
    if not spawnable or not parent then
        return false
    end

    local points, height = readAreaOutline(node)
    if #points < 3 then
        log("Area node exposes no usable outline, the clone is spawned without one.")
        return false
    end

    local groupClass = require("modules/classes/editor/positionableGroup")
    local markerClass = require("modules/classes/spawn/area/outlineMarker")
    local elementClass = require("modules/classes/editor/spawnableElement")

    local wrapper = groupClass:new(clone.sUI)
    wrapper.name = clone.name
    local index = utils.indexValue(parent.childs, clone)
    wrapper:setParent(parent, index > 0 and index or nil)

    local outline = groupClass:new(clone.sUI)
    outline.name = "outline"
    outline:setParent(wrapper)

    for markerIndex, point in ipairs(points) do
        local marker = markerClass:new()
        marker:loadSpawnData({ height = height }, point, EulerAngles.new(0, 0, 0))

        local markerElement = elementClass:new(clone.sUI)
        markerElement:load({
            name = string.format("marker_%02d", markerIndex),
            modulePath = markerElement.modulePath,
            spawnable = marker:save()
        })
        markerElement:setParent(outline)
    end

    -- Snapshot the wrapper while it still holds only the outline: the clone moving in is the
    -- separate phase `getMoveToNewGroup` expects, and `spawnNew` already recorded its insert.
    local insertWrapper = history.getInsert({ wrapper })
    local removeClone = history.getRemove({ clone })
    clone:setParent(wrapper)

    -- Read the path back instead of rebuilding it: `addChild` renames on collision, so the
    -- names set above are not necessarily the ones the path ends up being built from.
    spawnable.outlinePath = outline:getPath()
    element.bumpWireframeEpoch(clone)

    history.addAction(history.getMoveToNewGroup(insertWrapper, removeClone, history.getInsert({ clone })))

    return true
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

    local debugName = node and node.debugName and tostring(node.debugName) or ""
    if debugName ~= "" then
        entry.name = debugName
    end

    -- Variants hosting several spawnable classes need the clone to say which one it is;
    -- resolveEntryClass falls back to the variant's own class when nothing is set.
    entry.modulePath = cloneDefinition.modulePath

    local clone = rht.spawnUI.spawnNew(entry, rht.spawnUI.resolveEntryClass(activeList, entry), false)
    if not clone then
        return nil
    end

    local actorIndex = node and tonumber(node.actorIndex) or nil
    local actorCount = node and tonumber(node.actorCount) or nil
    local hasResolvedActor = actorIndex ~= nil and actorIndex >= 0
        and actorCount ~= nil and actorCount > 0

    -- Instanced nodes expose the resolved actor transform through position/orientation.
    -- nodePosition/nodeOrientation describe the parent streaming node instead.
    local position = node and ((hasResolvedActor and node.position)
        or node.nodePosition or node.entityPosition or node.position) or nil
    local rotation = node and ((hasResolvedActor and node.orientation)
        or node.nodeOrientation or node.entityOrientation or node.orientation) or nil
    local scale = node and (node.nodeScale or Vector4.new(1, 1, 1, 1)) or nil

    -- The node in the world is what this clone is a copy of, so its transform is the one the
    -- transform reset actions in the Spawned tab restore to.
    if clone.setBaseTransform then
        clone:setBaseTransform(gameUtils.toEulerAnglesSafe(rotation), toScaleVector(scale), "original node")
    end

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
    local didInitializeCloneTransform = false
    if clone.spawnable and clone.spawnable.registerSpawnedAndAttachedCallback then
        local function onAttached()
            -- Hide/unhide respawns should preserve user edits instead of replaying
            -- the original World Inspector clone transform every time.
            if didInitializeCloneTransform then
                return
            end
            didInitializeCloneTransform = true

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

---An AI Spot is only reached through the NodeRef its community points at, so a replacement
---that answers to a different ref is dead weight. Replacement modes only: in Clone mode the
---original stays in the world and two nodes would claim the same ref.
---@param node any
---@param definition table
---@param clone any
local function applyPreservedNodeRef(node, definition, clone)
    if not definition.preserveNodeRef then
        return
    end

    local spawnable = clone and clone.spawnable
    if not spawnable or spawnable.nodeRef == nil then
        return
    end

    -- Red Hot Tools hands back the raw node hash when a ref doesn't resolve to a path,
    -- which is not something the editor can write out.
    local nodeRef = type(node.nodeRef) == "string" and utils.trimString(node.nodeRef) or ""
    if not nodeRef:match("^%$/") then
        log("Node has no resolvable NodeRef, the replacement keeps an empty one.")
        return
    end

    spawnable.nodeRef = nodeRef
    registry.invalidate()
end

function rht.executeReplacer(node)
    if not node then
        return
    end

    local definition = getDefinition(node)
    if not definition or not definition.replacer then
        return
    end

    local mode = select(1, rht.getEffectiveReplacerMode())

    local clone = spawnClone(node, definition)
    if not clone then
        return
    end

    -- The shape is the area, not a mode-specific extra, so it is rebuilt for every mode.
    if definition.outline then
        attachAreaOutline(node, clone)
    end

    if isReplacementMode(mode) then
        applyPreservedNodeRef(node, definition, clone)

        local removalEditor = rht.getRemovalEditor()
        if removalEditor and removalEditor.addRemoval then
            if rht.hasActiveRemovalPreset() then
                local added = bridgeAddRemoval(removalEditor, node)
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
        if inspector and node.nodeInstance then
            inspector:ToggleNodeVisibility(node.nodeInstance)
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

    table.insert(actions, {
        type = "button",
        label = "[WB] Copy AXL node mutation",
        callback = function()
            rht.copyAXLNodeMutation(node)
        end
    })

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
            local ok, actions = pcall(rht.getTargetActions, node)
            if not ok then
                local message = tostring(actions)
                if rht.targetActionsError ~= message then
                    rht.targetActionsError = message
                    log("Failed to build World Inspector actions: " .. message)
                end
                return nil
            end

            rht.targetActionsError = nil
            return actions
        end
    })
end

return rht
