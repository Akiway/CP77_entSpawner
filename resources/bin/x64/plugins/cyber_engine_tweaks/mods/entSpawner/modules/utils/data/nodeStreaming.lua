---Per node type `nodeFlags` and `streamingPriority`, the values the game 2.5 sectors use for that type.
---The sector category adds context: Interior sectors add `IsInterior`; Quest sectors add `Quest` and
---either drop `Building` (gameplay nodes) or keep it and add `AllowForceStreamIn` (geometry, volumes).
local nodeStreaming = {}

-- ENodeFlags, bit 0 first, without the `FLAG_` prefix.
local FLAGS = {
    "BoostedToPrefabDistance", "AllowForceStreamIn", "IsInterior", "NoCollision", "Quest", "PrefabProxyMesh",
    "Building", "Decoration", "Road", "Terrain", "VisualFluff", "IsExludedOnConsole", "2DCheck",
    "Culling_IsCullable", "Culling_IsForceCulledAlways", "Culling_IsForceCulledNearPeripheral",
    "Culling_IsAdvertisementBillboardEntity", "GlobalIllumination", "FallbackDrop", "AllowDistanceBoosting",
    "IsExludedOnNextGenConsoles"
}

---@class nodeStreamingEntry
---@field flags string[]
---@field priority integer
---@field quest string? "swap" (default): Building becomes Quest. "keep": Quest and AllowForceStreamIn are added. "none": unchanged
---@field priorities table<string, integer>? Priority per sector category, where it differs
---@field noContext boolean? Category never changes the flags

local LOGIC = { flags = { "AllowForceStreamIn", "Building" }, priority = 1 }
local AREA = { flags = { "AllowForceStreamIn", "Building" }, priority = 255 }
local VOLUME = { flags = { "AllowForceStreamIn", "Building" }, priority = 1, quest = "keep" }
local AREA_VOLUME = { flags = { "AllowForceStreamIn", "Building" }, priority = 255, quest = "keep" }
-- Vanilla sets BoostedToPrefabDistance exactly on the mesh nodes whose secondary reference point is
-- their own streaming reference point, which is how the import script writes every node.
local MESH_FLAGS = { "BoostedToPrefabDistance", "Building", "Culling_IsCullable", "AllowDistanceBoosting" }
local MESH = { flags = MESH_FLAGS, priority = 1, quest = "keep" }
local MESH_UNBOOSTED = { flags = { "Building", "Culling_IsCullable", "AllowDistanceBoosting" }, priority = 1, quest = "keep" }
local COMMUNITY = { flags = { "AllowForceStreamIn" }, priority = 1, noContext = true }

local DEFAULT = LOGIC

---@type table<string, nodeStreamingEntry>
local types = {
    gameKillTriggerNode = AREA,
    gameWorldBoundaryNode = LOGIC,
    worldAISpotNode = { flags = { "AllowForceStreamIn", "Building", "Culling_IsCullable", "Culling_IsForceCulledNearPeripheral", "FallbackDrop" }, priority = 1 },
    worldAmbientAreaNode = AREA_VOLUME,
    worldAreaShapeNode = LOGIC,
    worldAudioAttractAreaNode = AREA,
    worldAudioSignpostTriggerNode = AREA,
    worldAudioTagNode = VOLUME,
    worldBakedDestructionNode = MESH,
    worldBendedMeshNode = { flags = MESH_FLAGS, priority = 70, quest = "keep" },
    worldClothMeshNode = MESH,
    worldCollisionNode = { flags = { "Building" }, priority = 1, quest = "none", priorities = { Quest = 254 } },
    worldCompiledCommunityAreaNode = COMMUNITY,
    worldCompiledCommunityAreaNode_Streamable = COMMUNITY,
    worldCommunityRegistryNode = COMMUNITY,
    worldCrowdNullAreaNode = LOGIC,
    worldDeviceNode = { flags = { "Building", "Culling_IsCullable", "Culling_IsForceCulledNearPeripheral" }, priority = 21, priorities = { Interior = 50 } },
    worldDynamicMeshNode = MESH_UNBOOSTED,
    worldEffectNode = LOGIC,
    worldEntityNode = { flags = { "AllowForceStreamIn", "Building", "Culling_IsCullable", "Culling_IsForceCulledNearPeripheral" }, priority = 21 },
    worldGenericProxyMeshNode = { flags = { "BoostedToPrefabDistance", "PrefabProxyMesh", "Building", "AllowDistanceBoosting" }, priority = 50, quest = "keep" },
    worldGuardAreaNode = LOGIC,
    worldInstancedDestructibleMeshNode = MESH,
    worldInterestingConversationsAreaNode = AREA,
    worldLightChannelVolumeNode = VOLUME,
    worldMeshNode = MESH,
    worldPatrolSplineNode = LOGIC,
    worldPhysicalDestructionNode = VOLUME,
    worldPopulationSpawnerNode = LOGIC,
    worldPreventionFreeAreaNode = LOGIC,
    worldReflectionProbeNode = VOLUME,
    worldRotatingMeshNode = MESH,
    worldSpeedSplineNode = LOGIC,
    worldSplineNode = LOGIC,
    worldStaticDecalNode = { flags = { "Building", "Culling_IsCullable", "Culling_IsForceCulledAlways" }, priority = 1 },
    worldStaticFogVolumeNode = VOLUME,
    worldStaticLightNode = { flags = { "Building" }, priority = 1 },
    worldStaticMarkerNode = LOGIC,
    worldStaticOccluderMeshNode = { flags = { "AllowForceStreamIn", "Building", "AllowDistanceBoosting" }, priority = 1, quest = "keep" },
    worldStaticParticleNode = LOGIC,
    worldStaticSoundEmitterNode = VOLUME,
    worldTriggerAreaNode = AREA,
    worldWaterNullAreaNode = LOGIC,
    worldWaterPatchNode = MESH_UNBOOSTED
}

---@param nodeType string
---@param category string? `worldStreamingSectorCategory` name of the sector holding the node
---@return string flags `ENodeFlags` names, comma separated
---@return integer priority
function nodeStreaming.get(nodeType, category)
    local entry = types[nodeType] or DEFAULT
    local set = {}

    for _, flag in ipairs(entry.flags) do
        set[flag] = true
    end

    if not entry.noContext then
        if category == "Interior" then
            set.IsInterior = true
        elseif category == "Quest" then
            local quest = entry.quest or "swap"
            if quest == "swap" then
                set.Building = nil
                set.Decoration = nil
                set.Quest = true
            elseif quest == "keep" then
                set.Quest = true
                set.AllowForceStreamIn = true
            end
        end
    end

    local names = {}
    for _, flag in ipairs(FLAGS) do
        if set[flag] then
            table.insert(names, "FLAG_" .. flag)
        end
    end

    local priority = entry.priorities and entry.priorities[category] or entry.priority

    return #names > 0 and table.concat(names, ", ") or "FLAG_None", priority
end

---Sets `nodeFlags` and `streamingPriority` on every node of an export, from its type and its sector's category.
---@param sectors table[]
function nodeStreaming.applyToSectors(sectors)
    for _, sector in ipairs(sectors or {}) do
        for _, node in ipairs(sector.nodes or {}) do
            node.nodeFlags, node.streamingPriority = nodeStreaming.get(node.type, sector.category)
            node.uk10 = nil
            node.uk11 = nil
        end
    end
end

return nodeStreaming
