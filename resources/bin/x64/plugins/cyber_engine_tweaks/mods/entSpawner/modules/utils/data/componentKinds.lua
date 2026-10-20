---Sorts entity components into the kinds the Entity Instance Data list groups them by.
---A component belongs to the first kind with a base class it derives from, checked through Reflection,
---so a class not named here still lands with its base. Classes with none of these bases go to Other.
local componentKinds = {}

componentKinds.kinds = {
    { label = "Lights", bases = { "entLightComponent", "entLightBlockingComponent", "entLightChannelComponent" } },
    { label = "Effects", bases = { "entEffectSpawnerComponent", "entEffectAttachmentComponent", "entDecalComponent", "entParticlesComponent", "entFogVolumeComponent", "entEnvProbeComponent", "entVectorFieldComponent" } },
    { label = "Screens & UI", bases = { "WidgetBaseComponent", "gameBinkComponent", "entVirtualCameraViewComponent" } },
    { label = "Meshes", bases = { "entIVisualComponent" } },
    { label = "Occlusion", bases = { "entStaticOccluderMeshComponent" } },
    { label = "Audio", bases = { "gameaudioSoundComponentBase", "gameAudioEmitterComponent", "entAmbientSoundEmitterComponent", "entSoundListenerComponent", "gameaudioAcousticPortalComponent", "gameaudioMusicSyncComponent", "gameFootstepComponent" } },
    { label = "Physics", bases = { "entColliderComponent", "entSimpleColliderComponent", "entPhysicalTriggerComponent", "entTriggerActivatorComponent", "entDynamicActorRepellingComponent", "entRagdollComponent", "gameStaticAreaShapeComponent", "entPhysicalImpulseAreaComponent", "gameITriggerDestructionComponent", "gamePhysicalDestructionListenerComponent", "gameHitRepresentationComponent", "gameEnvironmentDamageReceiverComponent", "gameWeakspotComponent", "gameNavmeshDetector", "entMechanicalImpactComponent" } },
    { label = "Animation", bases = { "entISkinableComponent", "entAnimationControllerComponent", "entAnimationSetupExtensionComponent", "entTransformComponent", "gameTransformAnimatorComponent", "gameRootTransformAnimatorComponent", "entTransformHistoryComponent", "entInstancedAnimationComponent", "entAnimGraphResourceContainer", "entVertexAnimationComponent", "entVisualControllerComponent", "entWetnessComponent", "entMorphTargetManagerComponent" } },
    { label = "Slots", bases = { "entSlotComponent", "gameAttachmentSlots", "entPlaceholderComponent", "gameOccupantSlotComponent", "gameSimpleOccupantSlotSpawner", "entTargetPointComponent" } },
    { label = "Cameras", bases = { "entBaseCameraComponent" } },
    { label = "Interaction", bases = { "gameinteractionsComponent", "gameinteractionsReactionComponent", "workWorkspotResourceComponent", "WorkspotMapperComponent", "gamemappinsMappinComponent", "gamePlayerMappinComponent", "gameScanningComponent", "gameScanningActivatorComponent", "gameTargetingComponent", "gameTargetingActivatorComponent", "gameTargetingLocalizedEffectComponent", "gameVisionActivatorComponent", "gamePingComponent", "entLocalizationStringComponent" } },
    { label = "Vehicles", bases = { "vehicleController", "VehicleComponent", "vehicleChassisComponent", "vehicleVehicleMountableComponent", "vehicleVehicleCustomization", "vehicleVisualCustomizationComponent", "vehicleGarageComponent", "AIVehicleAgent", "AIVehicleCoversComponent", "vehicleCameraManagerComponent" } },
    { label = "Devices", bases = { "gameDeviceComponent", "gameMasterDeviceComponent", "DeviceTimetable", "DeviceConnectionHighlightComponent", "gameMovingPlatform", "gameMovingPlatformMountableComponent", "gameLadderComponent", "worldTrafficLightListenerComponent" } },
    { label = "NPC & AI", bases = { "AICAgent", "AITargetTrackerComponent", "gameSquadMemberComponent", "gameCrowdMemberComponent", "senseComponent", "senseVisibleObjectComponent", "senseSensorObjectComponent", "entIMoverComponent", "movePoliciesComponent", "moveIMotionPlannerComponent", "AISignalHandlerComponent", "AIObjectSelectionComponent", "AIOffMeshConnectionComponent", "gameinfluenceComponent", "gameinfluenceBumpComponent", "gameinfluenceObstacleComponent", "gameHumanoidBody", "gameDismembermentComponent", "gameEthnicityComponent", "gamePuppetMountableComponent", "gameObjectCarrierComponent", "gameSourceShootComponent", "gameTargetShootComponent", "gameprojectileSpawnComponent", "gameprojectileComponent", "gameBreachComponent", "gameBreachControllerComponent", "gameBreachFinderComponent", "scnVoicesetComponent", "NPCStatesComponent", "ReactionManagerComponent", "HitReactionComponent", "CombatHUDManager", "TargetTrackingExtension", "gameAttitudeAgent", "entCorpseComponent" } },
    { label = "Gameplay", bases = { "gameComponent", "entExternalComponent", "gameEntityStubComponentPlacedProxy", "gameuiICharacterCustomizationComponent", "gameComponentsStateSaveComponent" } },
    { label = "Other", bases = {} }
}

local other = componentKinds.kinds[#componentKinds.kinds]

---Match per list, then per class; `false` caches a miss.
local matchCache = setmetatable({}, { __mode = "k" })

---First entry of `entries` with a base class that `className` derives from, cached per list.
---@param entries { bases: string[] }[]
---@param className string RED class of the component, its `$type`
---@return table? entry
function componentKinds.findByBase(entries, className)
    local cache = matchCache[entries]
    if not cache then
        cache = {}
        matchCache[entries] = cache
    end

    local cached = cache[className]
    if cached ~= nil then return cached or nil end

    local found = false
    local class = type(className) == "string" and className ~= "" and Reflection.GetClass(className) or nil
    if class then
        for _, entry in ipairs(entries) do
            for _, base in ipairs(entry.bases) do
                if class:IsA(base) then
                    found = entry
                    break
                end
            end
            if found then break end
        end
    end

    cache[className] = found
    return found or nil
end

---Drops the cached matches of a list, after it changed.
---@param entries table
function componentKinds.clearCache(entries)
    matchCache[entries] = nil
end

---@param className string RED class of the component, its `$type`
---@return table kind Entry of `componentKinds.kinds`
function componentKinds.getKind(className)
    return componentKinds.findByBase(componentKinds.kinds, className) or other
end

return componentKinds
