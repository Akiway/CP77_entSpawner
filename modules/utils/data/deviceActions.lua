---Which device actions a given controller can actually perform, for the `Device action performed`
---trigger.
---
---How a device's interactions come to exist, end to end:
---
---1. `ScriptableDeviceComponentPS.GetActions` (and the override every controller adds on top of it)
---   pushes one `ScriptableDeviceAction` per available choice. A radio's `MediaDeviceControllerPS`
---   pushes `ToggleON`, then `PreviousStation` and `NextStation` -- the three prompts the player sees
---   on `radio_1.ent`.
---2. Each of those actions calls `CreateInteraction()`, which is what puts the choice on the device's
---   `gameinteractionsComponent` layer. The component holds the *area*; the controller holds the
---   *list*, and it is rebuilt every time the device state changes.
---3. Performing one raises `PerformedAction`, and `deviceBase.OnPerformedAction` forwards
---   `evt.m_action.GetClassName()` to `EvaluateDeviceActionTriggers`.
---
---So the trigger fires for **any** action the device performs -- direct interaction, quickhack or
---quest -- matched on the class name alone. What it can never fire for is an action the controller
---never creates, and that is the whole point of this table: the generic picker offered all 325
---`ScriptableDeviceAction` subclasses in the game, of which a radio can raise 22.
---
---Extracted from the decompiled scripts by reading `GetActions` / `GetQuickHackActions` /
---`GetQuestActions` / `GetQuestActionByName` on every `*ControllerPS`, resolving each
---`ArrayPush(actions, this.ActionX())` to the class `ActionX` returns, and keeping only what each
---class adds over its parent -- `CLASSES` is walked through `parent` at lookup time.
---
---Caveats worth knowing before trusting a row:
--- * Availability is not conditionality. Most pushes sit behind an `IsDefaultConditionMet` check, so
---   a listed action is one the controller *can* raise, not one that is always offered.
--- * A controller that overrides `GetActions` without calling `super` still inherits here. Union by
---   inheritance is right for the great majority and wrong for a handful; the picker's "every device
---   action" toggle is the escape hatch either way.
---@class deviceActions
local deviceActions = {}

---Order matters: it is the order the picker lists categories in.
deviceActions.CATEGORIES = { "interaction", "quickhack", "quest" }

deviceActions.CATEGORY_LABELS = {
    interaction = "interaction",
    quickhack = "quickhack",
    quest = "quest"
}

deviceActions.CATEGORY_HINTS = {
    interaction = "Offered to the player as a prompt on the device, when its conditions are met.",
    quickhack = "Raised from the quickhack menu, so it needs the device to be hackable.",
    quest = "Only ever performed by a quest node or another device, never by the player directly."
}

---Plain-language notes for the actions shared by most devices. Anything without an entry falls back
---to its category hint: the class names are descriptive enough that inventing a label for all 221
---would add noise, not meaning.
deviceActions.NOTES = {
    ToggleActivation = "Enable or disable the device outright. The broadest on/off there is.",
    ToggleON = "The device's own on/off prompt -- what \"Activate\"/\"Deactivate\" runs.",
    TogglePower = "Cut or restore power, which is a different state from ON/OFF.",
    SetDeviceON = "Force ON, regardless of the current state.",
    SetDeviceOFF = "Force OFF, regardless of the current state.",
    SetDevicePowered = "Force powered.",
    SetDeviceUnpowered = "Force unpowered.",
    OpenFullscreenUI = "Open the device's fullscreen screen, on devices that have one.",
    TogglePersonalLink = "Connect or disconnect the personal link.",
    ToggleZoomInteraction = "The \"Examine\" prompt.",
    DisassembleDevice = "Break the device down for components.",
    FixDevice = "Repair a broken device.",
    ActionScavenge = "Scavenge the device for parts.",
    ToggleJuryrigTrap = "Arm or disarm the jury-rigged grenade trap.",
    SetAuthorizationModuleON = "Turn the authorization requirement on.",
    SetAuthorizationModuleOFF = "Turn the authorization requirement off.",
    NextStation = "Radio and TV: step to the next channel.",
    PreviousStation = "Radio and TV: step to the previous channel.",
    MediaDeviceStatus = "Reports the current channel; raised externally, not by the player.",
    ToggleOpen = "Doors: open or close.",
    ToggleLock = "Doors: lock or unlock.",
    ToggleSeal = "Doors: seal or unseal.",
    ForceOpen = "Doors: force open, ignoring the lock.",
    SetOpened = "Doors: set the open state directly.",
    CallElevator = "Doors: call the elevator this door belongs to.",
    CustomDeviceAction = "One of the generic device's own custom actions. The Custom action ID trigger reads the ID, which this class name cannot.",
    ActivateDevice = "The activation event. On a generic device this also fires the Activator trigger.",
    DeactivateDevice = "The deactivation counterpart of ActivateDevice.",
    QuickHackDistraction = "The distraction quickhack -- the usual way a device is made to make noise."
}

-- Interaction area tags --------------------------------------------------------------------------

---Layer tags the `Interaction area enter / exit` trigger can match, in the order the picker lists
---them. The tag is not free-form: it comes from the `.interaction` descriptor on the entity's
---`gameinteractionsComponent`, and 1,012 of the 1,086 device interaction components in the game
---point at the same one -- `base\gameplay\devices\interactions\default_device_interaction.interaction`,
---whose four layers are the first four rows here. The rest are the descriptors the remaining devices
---use, read out of the shipped resources.
---
---`enabled = false` means the layer ships switched off in the descriptor, so it raises nothing until
---something turns it on. `radius` is the shipped sphere, which `interaction.layerOverrides` can
---resize per instance under Entity Instance Data.
deviceActions.AREA_TAGS = {
    { tag = "LogicArea", radius = 35, enabled = true,
      note = "Proximity. The widest layer on almost every device, and the one to use for \"player is nearby\"." },
    { tag = "direct", radius = 2.85, enabled = true,
      note = "The interaction prompt's own area: close, and gated on looking at the device." },
    { tag = "ForceShowIcon", radius = 12, enabled = false,
      note = "Ships disabled on the default descriptor." },
    { tag = "ForceReveal", radius = 6, enabled = false,
      note = "Ships disabled on the default descriptor." },
    { tag = "LadderEntrance", enabled = true,
      note = "Ladders. Two box layers, one per end of the ladder." },
    { tag = "Loot", radius = 2, enabled = true, note = "Containers." },
    { tag = "LootGenerator", radius = 15, enabled = true, note = "Containers." },
    { tag = "QualityRange_Short", radius = 5, enabled = false, note = "Containers, ships disabled." },
    { tag = "QualityRange_Medium", radius = 15, enabled = false, note = "Containers, ships disabled." },
    { tag = "QualityRange_Max", radius = 25, enabled = false, note = "Containers, ships disabled." },
    { tag = "Mount", radius = 1.3, enabled = true, note = "Bikes." },
    { tag = "layer1", radius = 2, enabled = true, note = "The basic area interaction descriptor." }
}

---@return string[]
function deviceActions.getAreaTags()
    local tags = {}
    for _, entry in ipairs(deviceActions.AREA_TAGS) do
        table.insert(tags, entry.tag)
    end

    return tags
end

---@param tag string
---@return string
function deviceActions.describeAreaTag(tag)
    for _, entry in ipairs(deviceActions.AREA_TAGS) do
        if entry.tag == tag then
            local parts = {}
            if entry.radius then table.insert(parts, string.format("%.2gm sphere", entry.radius)) end
            if not entry.enabled then table.insert(parts, "disabled in the descriptor") end

            if #parts > 0 then
                return entry.note .. "\n(" .. table.concat(parts, ", ") .. ")"
            end

            return entry.note
        end
    end

    return ""
end

---Short right-hand note for the picker: the shipped radius, which is the thing an author is choosing
---between when two layers do the same job at different ranges.
---@param tag string
---@return string
function deviceActions.annotateAreaTag(tag)
    for _, entry in ipairs(deviceActions.AREA_TAGS) do
        if entry.tag == tag then
            if not entry.enabled then return "off" end
            return entry.radius and string.format("%.2gm", entry.radius) or ""
        end
    end

    return ""
end

-- Actions ------------------------------------------------------------------------------------------

---Own contribution per controller, walked through `parent`. A class listed with only a parent adds
---nothing of its own and exists so the chain stays resolvable from any device in the catalogue.
deviceActions.CLASSES = {
    AOEAreaControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "ActivateDevice", "DeactivateDevice" },
        quest = { "ActivateDevice", "DeactivateDevice" },
    },
    AOEEffectorControllerPS = {
        parent = "ActivatedDeviceControllerPS",
        interaction = { "ToggleAOEEffect" },
    },
    AccessPointControllerPS = {
        parent = "MasterControllerPS",
        quest = { "QuestBreachAccessPoint", "ResetNetworkBreachState" },
    },
    ActionsSequencerControllerPS = {
        parent = "MasterControllerPS",
        quest = { "ActivateDevice", "DeactivateDevice" },
    },
    ActivatedDeviceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ActivateDevice", "SetExposeQuickHacks" },
        quickhack = { "ActivateDevice", "QuickHackDistraction" },
        quest = { "ActivateDevice", "QuestSetIndustrialArmAnimationOverride", "QuestToggleAutomaticAttack" },
    },
    ActivatedDeviceNPCControllerPS = {
        parent = "ActivatedDeviceControllerPS",
    },
    ActivatorControllerPS = {
        parent = "MasterControllerPS",
        quickhack = { "ToggleActivation" },
        quest = { "QuestForceActivate" },
    },
    AlarmLightControllerPS = {
        parent = "BasicDistractionDeviceControllerPS",
    },
    ApartmentScreenControllerPS = {
        parent = "LcdScreenControllerPS",
    },
    ArcadeMachineControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "BeginArcadeMinigameUI" },
        quickhack = { "GlitchScreen", "QuickHackDistraction" },
    },
    BarbedWireControllerPS = {
        parent = "ActivatedDeviceControllerPS",
    },
    BaseAnimatedDeviceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ToggleActivate" },
        quickhack = { "QuickHackToggleActivate" },
        quest = { "QuestForceActivate", "QuestForceDeactivate" },
    },
    BaseDestructibleControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    BaseNetworkSystemControllerPS = {
        parent = "MasterControllerPS",
    },
    BasicDistractionDeviceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = { "QuickHackDistraction" },
    },
    BillboardDeviceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = { "GlitchScreen", "QuickHackDistraction" },
    },
    BlindingLightControllerPS = {
        parent = "BasicDistractionDeviceControllerPS",
        quickhack = { "OverloadDevice" },
    },
    BunkerComputerControllerPS = {
        parent = "ComputerControllerPS",
    },
    BunkerDoorControllerPS = {
        parent = "DoorControllerPS",
    },
    C4ControllerPS = {
        parent = "ExplosiveDeviceControllerPS",
        interaction = { "ActivateC4", "DeactivateC4" },
        quickhack = { "DetonateC4" },
    },
    CandleControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ToggleON" },
    },
    ChestPressControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = { "ChestPressWeightHack" },
        quest = { "E3Hack_QuestPlayAnimationKillNPC", "E3Hack_QuestPlayAnimationWeightLift" },
    },
    CleaningMachineControllerPS = {
        parent = "BasicDistractionDeviceControllerPS",
    },
    CoderControllerPS = {
        parent = "BasicDistractionDeviceControllerPS",
        interaction = { "AuthorizeUser" },
    },
    ComputerControllerPS = {
        parent = "TerminalControllerPS",
        interaction = { "ToggleOpenComputer" },
        quickhack = { "FactQuickHack", "ToggleTakeOverControl" },
        quest = { "ToggleOpenComputer" },
    },
    ConfessionBoothControllerPS = {
        parent = "BasicDistractionDeviceControllerPS",
        interaction = { "Confess" },
        quickhack = { "GlitchScreen" },
    },
    ConveyorControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ToggleON" },
    },
    CrossingLightControllerPS = {
        parent = "TrafficLightControllerPS",
    },
    DataTermControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "OpenWorldMapDeviceAction" },
    },
    DestructibleMasterDeviceControllerPS = {
        parent = "MasterControllerPS",
    },
    DestructibleMasterLightControllerPS = {
        parent = "DestructibleMasterDeviceControllerPS",
        interaction = { "ToggleON" },
    },
    DeviceSystemBaseControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "GetAccess" },
    },
    DisassembleMasterControllerPS = {
        parent = "MasterControllerPS",
    },
    DisplayGlassControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ToggleGlassTint" },
        quickhack = { "ToggleGlassTintHack" },
        quest = { "QuestForceClearGlass", "QuestForceTintGlass" },
    },
    DisposalDeviceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "DisposeBody", "OverchargeDevice", "TakedownAndDisposeBody" },
        quickhack = { "QuickHackDistraction" },
    },
    DoorControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = {
            "CallElevator", "DoorStatus", "ForceOpen", "PlayerUnauthorized", "SetOpened", "ToggleLock",
            "ToggleOpen", "ToggleSeal"
        },
        quickhack = { "QuickHackToggleOpen" },
        quest = {
            "QuestForceClose", "QuestForceCloseImmediate", "QuestForceCloseScene", "QuestForceLock",
            "QuestForceOpen", "QuestForceOpenScene", "QuestForceSeal", "QuestForceUnlock",
            "QuestForceUnseal"
        },
    },
    DoorProximityDetectorControllerPS = {
        parent = "ProximityDetectorControllerPS",
    },
    DoorSystemControllerPS = {
        parent = "BaseNetworkSystemControllerPS",
    },
    DropPointControllerPS = {
        parent = "BasicDistractionDeviceControllerPS",
        interaction = { "CollectDropPointRewards", "DepositQuestItems", "OpenVendorUI" },
    },
    ElectricBoxControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "ActionOverride" },
    },
    ElectricLightControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ToggleON" },
    },
    ElevatorFloorTerminalControllerPS = {
        parent = "TerminalControllerPS",
        interaction = { "AuthorizeUser", "CallElevator", "SetExposeQuickHacks" },
        quickhack = { "QuickHackAuthorization", "QuickHackCallElevator" },
    },
    ExitLightControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    ExplosiveDeviceControllerPS = {
        parent = "BasicDistractionDeviceControllerPS",
        interaction = { "ForceDetonate" },
        quickhack = { "OverloadDevice", "QuickHackExplodeExplosive", "QuickHackToggleON" },
        quest = { "QuestForceDetonate" },
    },
    ExplosiveTriggerDeviceControllerPS = {
        parent = "ExplosiveDeviceControllerPS",
        interaction = { "ToggleON" },
        quickhack = { "SetDeviceAttitude" },
        quest = { "QuestSetPlayerSafePass" },
    },
    FactInvokerControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "AuthorizeUser" },
    },
    FanControllerPS = {
        parent = "BasicDistractionDeviceControllerPS",
        interaction = { "ToggleON" },
    },
    ForkliftControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ActivateDevice" },
        quickhack = { "QuickHackDistraction" },
    },
    FrameControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "FrameSwitcher" },
    },
    FridgeControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ToggleOpenFridge" },
    },
    FuseBoxControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "ToggleON" },
        quickhack = { "OverloadDevice", "QuickHackDistraction", "QuickHackToggleON" },
    },
    FuseControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "ToggleON" },
    },
    GameplayLightControllerPS = {
        parent = "ElectricLightControllerPS",
        quickhack = { "QuickHackDistraction", "QuickHackToggleON" },
    },
    GenericDeviceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "CustomDeviceAction", "ToggleON" },
        quickhack = { "CustomDeviceAction", "ToggleON", "TogglePower" },
        quest = { "QuestCustomAction", "QuestToggleCustomAction" },
    },
    GlitchedTurretControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quest = { "QuestForceGlitch" },
    },
    HoloDeviceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "TogglePlay" },
    },
    HoloFeederControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ToggleON" },
    },
    HoloTableControllerPS = {
        parent = "MediaDeviceControllerPS",
        quickhack = { "QuickHackDistraction" },
    },
    IceMachineControllerPS = {
        parent = "VendingMachineControllerPS",
    },
    InteractiveAdControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ShowVendor" },
    },
    InteractiveSignControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    IntercomControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "StartCall" },
        quickhack = { "QuickHackDistraction" },
        quest = { "QuestHangUpCall", "QuestPickUpCall" },
    },
    InvisibleSceneStashControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    JukeboxControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "NextStation", "PreviousStation", "TogglePlay" },
        quickhack = { "QuickHackDistraction" },
    },
    LadderControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "EnterLadder" },
    },
    LaserDetectorControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    LcdScreenControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = { "GlitchScreen", "QuickHackDistraction" },
    },
    LiftControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "AuthorizeUser", "CallElevator", "GoToFloor", "LiftStatus", "SetExposeQuickHacks" },
        quickhack = { "QuickHackAuthorization" },
        quest = {
            "QuestCloseAllDoors", "QuestDisableLiftTravelTimeOverride", "QuestDisableRadio",
            "QuestEnableLiftTravelTimeOverride", "QuestForceGoToFloor", "QuestForceTeleportToFloor",
            "QuestGoToFloor", "QuestHideFloor", "QuestResumeElevator", "QuestSetFloorActive",
            "QuestSetFloorInactive", "QuestSetLiftSpeed", "QuestSetLiftTravelTimeOverride",
            "QuestSetRadioStation", "QuestShowFloor", "QuestStopElevator", "QuestToggleAds"
        },
    },
    LootContainerAccessPointControllerPS = {
        parent = "AccessPointControllerPS",
    },
    MainframeControllerPS = {
        parent = "BaseAnimatedDeviceControllerPS",
    },
    MaintenancePanelControllerPS = {
        parent = "MasterControllerPS",
    },
    MasterControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    MediaDeviceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "MediaDeviceStatus", "NextStation", "PreviousStation", "ToggleON" },
        quest = {
            "QuestDefaultStation", "QuestDisableInteraction", "QuestEnableInteraction", "QuestNextStation",
            "QuestPreviousStation", "QuestSetChannel"
        },
    },
    MovableDeviceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ActionDemolition", "MoveObstacle" },
    },
    MovableWallScreenControllerPS = {
        parent = "DoorControllerPS",
    },
    NcartTimetableControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = { "GlitchScreen", "QuickHackDistraction" },
    },
    NetrunnerChairControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = { "OverloadDevice" },
    },
    NetrunnerControlPanelControllerPS = {
        parent = "BasicDistractionDeviceControllerPS",
        quickhack = { "FactQuickHack" },
    },
    NetworkAreaControllerPS = {
        parent = "MasterControllerPS",
    },
    NumericDisplayControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quest = { "QuestDecreaseNumber", "QuestIdle", "QuestIncreaseNumber" },
    },
    OdaCementBagControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    PachinkoMachineControllerPS = {
        parent = "ArcadeMachineControllerPS",
    },
    PerkTrainingControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    PersonnelSystemControllerPS = {
        parent = "DeviceSystemBaseControllerPS",
    },
    PlatformControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "QuestMoveToNextFloor", "QuestMoveToPrevFloor", "ToggleON" },
        quest = { "QuestMoveToFloor", "QuestMoveToNextFloor", "QuestMoveToPrevFloor", "QuestPause", "QuestResume" },
    },
    PortalControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    ProximityDetectorControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ToggleON" },
    },
    RadioControllerPS = {
        parent = "MediaDeviceControllerPS",
        quickhack = { "QuickHackAoeDamage", "QuickHackDistraction", "QuickHackHighPitchNoise" },
    },
    ReflectorControllerPS = {
        parent = "BlindingLightControllerPS",
        interaction = { "Distraction", "ToggleON" },
    },
    RetractableAdControllerPS = {
        parent = "BaseAnimatedDeviceControllerPS",
        quickhack = { "QuickHackDistraction" },
    },
    RoadBlockControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ToggleBlockade" },
        quickhack = { "QuickHackToggleBlockade" },
        quest = { "QuestForceRoadBlockadeActivate", "QuestForceRoadBlockadeDeactivate" },
    },
    RoadBlockTrapControllerPS = {
        parent = "MasterControllerPS",
    },
    RoboticArmsControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = { "QuickHackDistraction" },
    },
    ScriptableDeviceComponentPS = {
        parent = "SharedGameplayPS",
        interaction = {
            "ActionScavenge", "DisassembleDevice", "FixDevice", "OpenFullscreenUI",
            "SetAuthorizationModuleOFF", "SetAuthorizationModuleON", "SetDeviceOFF", "SetDeviceON",
            "SetDevicePowered", "SetDeviceUnpowered", "ToggleActivation", "ToggleJuryrigTrap",
            "TogglePersonalLink", "TogglePower", "ToggleZoomInteraction"
        },
        quest = {
            "QuestDisableFixing", "QuestEnableFixing", "QuestForceAuthorizationDisabled",
            "QuestForceAuthorizationEnabled", "QuestForceCameraZoom", "QuestForceDestructible",
            "QuestForceDisabled", "QuestForceDisconnectPersonalLink", "QuestForceEnabled",
            "QuestForceIndestructible", "QuestForceInvulnerable", "QuestForceJuryrigTrapArmed",
            "QuestForceJuryrigTrapDeactivated", "QuestForceOFF", "QuestForceON",
            "QuestForcePersonalLinkUnderStrictQuestControl", "QuestForcePower", "QuestForceUnpower",
            "QuestRemoveQuickHacks", "QuestResetDeviceToInitialState", "QuestResetPerformedActionsStorage",
            "QuestRestoreQuickHacks", "QuestStartGlitch", "QuestStopGlitch"
        },
    },
    SecurityAlarmControllerPS = {
        parent = "MasterControllerPS",
        quickhack = { "QuickHackDistraction", "ToggleAlarm" },
        quest = { "QuestForceSecuritySystemArmed", "QuestForceSecuritySystemSafe" },
    },
    SecurityAreaControllerPS = {
        parent = "MasterControllerPS",
    },
    SecurityGateControllerPS = {
        parent = "MasterControllerPS",
        quickhack = { "QuickHackAuthorization", "QuickHackDistraction" },
    },
    SecurityGateLockControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    SecurityLockerControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "UseSecurityLocker" },
    },
    SecuritySystemControllerPS = {
        parent = "DeviceSystemBaseControllerPS",
        interaction = { "FullSystemRestart" },
    },
    SecurityTurretControllerPS = {
        parent = "SensorDeviceControllerPS",
        interaction = { "RipOff", "ToggleON", "ToggleTakeOverControl" },
        quickhack = { "SetDeviceAttitude", "SetDeviceTagKillMode", "ToggleTakeOverControl" },
        quest = {
            "QuestFollowTarget", "QuestForceAttitude", "QuestForceOverheat", "QuestForceReload",
            "QuestForceStopTakeControlOverCamera", "QuestForceTakeControlOverCamera", "QuestLookAtTarget",
            "QuestRemoveWeapon", "QuestSetDetectionToFalse", "QuestSetDetectionToTrue",
            "QuestSpotTargetReference", "QuestStopFollowingTarget", "QuestStopLookAtTarget"
        },
    },
    SensorDeviceControllerPS = {
        parent = "ExplosiveDeviceControllerPS",
    },
    ServerNodeControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = { "OverloadDevice", "ServerOverload" },
        quest = { "QuestClose", "QuestExplode", "QuestOpen", "QuestStartHacking", "QuestStopHacking" },
    },
    SimpleOnTurnOnPlayEffectDeviceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    SimpleSwitchControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "ToggleON" },
        quickhack = { "QuickHackToggleON" },
    },
    SlidingLadderControllerPS = {
        parent = "BaseAnimatedDeviceControllerPS",
        interaction = { "EnterLadder" },
    },
    SmartHouseControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "OpenInteriorManager", "PresetAction" },
    },
    SmartWindowControllerPS = {
        parent = "ComputerControllerPS",
    },
    SmokeMachineControllerPS = {
        parent = "BasicDistractionDeviceControllerPS",
        quickhack = { "OverloadDevice" },
    },
    SniperNestControllerPS = {
        parent = "SensorDeviceControllerPS",
        interaction = { "ToggleTakeOverControl" },
        quest = { "QuestEjectPlayer", "QuestEnterNoAnimation", "QuestEnterPlayer" },
    },
    SoundSystemControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "ChangeMusicAction" },
        quickhack = { "ChangeMusicAction" },
    },
    SpeakerControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = { "QuickHackDistraction" },
    },
    StashControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "OpenStash" },
    },
    StaticPlatformControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    StillageControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ThrowStuff" },
    },
    SurveillanceCameraControllerPS = {
        parent = "SensorDeviceControllerPS",
        interaction = { "SurveillanceCameraStatus", "ToggleON", "ToggleStreamFeed", "ToggleTakeOverControl" },
        quickhack = { "ForceIgnoreTargets", "ToggleTakeOverControl" },
        quest = {
            "QuestFollowTarget", "QuestForceAttitude", "QuestForceReplaceStreamWithVideo",
            "QuestForceScanEffect", "QuestForceScanEffectStop", "QuestForceStopReplacingStream",
            "QuestForceStopTakeControlOverCamera", "QuestForceTakeControlOverCamera",
            "QuestForceTakeControlOverCameraWithChain", "QuestLookAtTarget", "QuestSetDetectionToFalse",
            "QuestSetDetectionToTrue", "QuestSpotTargetReference", "QuestStopFollowingTarget",
            "QuestStopLookAtTarget"
        },
    },
    SurveillanceSystemControllerPS = {
        parent = "DeviceSystemBaseControllerPS",
        interaction = { "RevealEnemies" },
    },
    TVControllerPS = {
        parent = "MediaDeviceControllerPS",
        quickhack = { "GlitchScreen", "QuickHackDistraction" },
        quest = { "QuestMuteSounds", "QuestToggleInteractivity" },
    },
    TerminalControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "BaseDeviceStatus", "ToggleON" },
        quickhack = { "GlitchScreen", "InstallKeylogger", "QuickHackDistraction", "QuickHackToggleOpen" },
        quest = { "QuestForceFakeElevatorArrows", "QuestResetFakeElevatorArrows" },
    },
    ToiletControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "Flush" },
    },
    TrafficIntersectionManagerControllerPS = {
        parent = "MasterControllerPS",
        quest = { "InitiateTrafficLightChange" },
    },
    TrafficLightControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    TrafficZebraControllerPS = {
        parent = "TrafficLightControllerPS",
    },
    VehicleComponentPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = {
            "ToggleTakeOverControl", "VehicleOverrideAccelerate", "VehicleOverrideExplode",
            "VehicleOverrideForceBrakes"
        },
    },
    VendingMachineControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        quickhack = { "GlitchScreen", "QuickHackDistraction" },
    },
    VendingTerminalControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    VentilationAreaControllerPS = {
        parent = "MasterControllerPS",
        interaction = { "ActivateDevice" },
    },
    VentilationEffectorControllerPS = {
        parent = "ActivatedDeviceControllerPS",
        interaction = { "ToggleEffect" },
    },
    WallScreenControllerPS = {
        parent = "TVControllerPS",
        interaction = { "ToggleShow" },
    },
    WardrobeControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "OpenWardrobeUI" },
    },
    WeakFenceControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ActivateDevice" },
    },
    WeaponTrainingControllerPS = {
        parent = "ScriptableDeviceComponentPS",
    },
    WeaponVendingMachineControllerPS = {
        parent = "VendingMachineControllerPS",
    },
    WindowBlindersControllerPS = {
        parent = "ScriptableDeviceComponentPS",
        interaction = { "ToggleOpen", "ToggleTiltBlinders" },
        quickhack = { "QuickHackToggleOpen", "ToggleTiltBlinders" },
        quest = { "QuestForceClose", "QuestForceOpen" },
    },
    WindowControllerPS = {
        parent = "DoorControllerPS",
    },
}

-- Lookup -----------------------------------------------------------------------------------------

---Resolved lists are keyed by controller class and never change during a session.
local resolvedCache = {}

---Nearest ancestor of `className` that `CLASSES` knows, for controllers a mod added.
---@param className string
---@return string?
local function knownAncestor(className)
    if deviceActions.CLASSES[className] then return className end

    local found = nil
    pcall(function ()
        local class = Reflection.GetClass(className)
        while class do
            local name = class:GetName().value
            if deviceActions.CLASSES[name] then
                found = name
                return
            end
            class = class:GetParent()
        end
    end)

    return found
end

---Every action class the given controller can raise, ordered interaction -> quickhack -> quest and
---alphabetically inside each. An action reachable through more than one route keeps the first
---category it appears under, which is the one the author is most likely to be aiming at.
---@param className string? Controller PS class, i.e. `spawnable.deviceClassName`
---@return { options: string[], category: table<string, string>, counts: table<string, number>, resolved: boolean }
function deviceActions.forDevice(className)
    className = type(className) == "string" and className or ""
    if resolvedCache[className] then return resolvedCache[className] end

    local result = { options = {}, category = {}, counts = {}, resolved = false }
    local entry = knownAncestor(className)

    if entry then
        result.resolved = true

        local collected = { interaction = {}, quickhack = {}, quest = {} }
        local seen = {}
        local guard = 0

        while entry and guard < 64 do
            guard = guard + 1
            local class = deviceActions.CLASSES[entry]
            if not class then break end

            for _, category in ipairs(deviceActions.CATEGORIES) do
                local list = class[category]

                if type(list) == "table" then
                    for _, action in ipairs(list) do
                        if not seen[action] then
                            seen[action] = category
                            table.insert(collected[category], action)
                        end
                    end
                end
            end

            entry = class.parent
        end

        for _, category in ipairs(deviceActions.CATEGORIES) do
            table.sort(collected[category])
            result.counts[category] = #collected[category]

            for _, action in ipairs(collected[category]) do
                table.insert(result.options, action)
                result.category[action] = category
            end
        end
    end

    resolvedCache[className] = result

    return result
end

---@param actionClass string
---@param category string? Category the action was listed under, when it is known
---@return string
function deviceActions.describe(actionClass, category)
    local note = deviceActions.NOTES[actionClass]
    local hint = category and deviceActions.CATEGORY_HINTS[category] or nil

    if note and hint then return note .. "\n\n" .. hint end

    return note or hint or ""
end

return deviceActions
