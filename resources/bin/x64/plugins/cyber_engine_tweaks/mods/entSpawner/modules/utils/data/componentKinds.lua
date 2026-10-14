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
local kindByClass = {}

---@param className string RED class of the component, its `$type`
---@return table kind Entry of `componentKinds.kinds`
function componentKinds.getKind(className)
    local cached = kindByClass[className]
    if cached then return cached end

    local found = other
    local class = type(className) == "string" and Reflection.GetClass(className) or nil
    if class then
        for _, kind in ipairs(componentKinds.kinds) do
            for _, base in ipairs(kind.bases) do
                if class:IsA(base) then
                    found = kind
                    break
                end
            end
            if found ~= other then break end
        end
    end

    kindByClass[className] = found
    return found
end

local isACache = {}

---@param className string RED class of the component, its `$type`
---@param base string
---@return boolean
function componentKinds.isA(className, base)
    local key = tostring(className) .. ">" .. base
    local cached = isACache[key]
    if cached ~= nil then return cached end

    local class = type(className) == "string" and className ~= "" and Reflection.GetClass(className) or nil
    local result = class ~= nil and class:IsA(base) == true

    isACache[key] = result
    return result
end

return componentKinds
