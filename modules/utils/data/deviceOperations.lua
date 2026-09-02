---Shared `DeviceOperationsContainer` data: paths, the class catalogues the quick setup builds its UI
---from, and the small value helpers both the popup and the device spawnable need.
---
---The container lives on the PS chunk of any device whose controller derives from
---`ScriptableDeviceComponentPS`, and ships null on effectively every device. It holds two arrays:
---`operations` (named effects) and `triggers` (conditions that run them by name). A trigger reaches
---an operation only through an exact, case-sensitive CName match, which is why the quick setup makes
---that reference a dropdown rather than a text field.
---
---Field schemas below are read from the RTTI dump, and the enum member lists are the RED JSON values
---(enums serialize as their member name, verified against shipped entities such as
---`ep1\gameplay\devices\lighting\industrial\spotlight\spotlight_maelstrom.ent`).
---@class deviceOperations
local deviceOperations = {}

deviceOperations.BASE_PS_CLASS = "ScriptableDeviceComponentPS"
deviceOperations.CONTAINER_CLASS = "DeviceOperationsContainer"
deviceOperations.OPERATION_BASE_CLASS = "DeviceOperationBase"
deviceOperations.TRIGGER_BASE_CLASS = "DeviceOperationsTrigger"
deviceOperations.EXECUTION_CLASS = "OperationExecutionData"
deviceOperations.SOUND_COMPONENT_CLASS = "gameaudioSoundComponent"

deviceOperations.CONTAINER_PATH = { "persistentState", "Data", "deviceOperationsSetup" }
deviceOperations.CONTAINER_DATA_PATH = { "persistentState", "Data", "deviceOperationsSetup", "Data" }
deviceOperations.OPERATIONS_PATH = { "persistentState", "Data", "deviceOperationsSetup", "Data", "operations" }
deviceOperations.TRIGGERS_PATH = { "persistentState", "Data", "deviceOperationsSetup", "Data", "triggers" }

---Enum member names, in declaration order. RED JSON stores the name, not the ordinal.
deviceOperations.ENUMS = {
    EEffectOperationType = { "START", "STOP", "BRAKE_LOOP" },
    EDeviceStatus = { "DISABLED", "UNPOWERED", "OFF", "ON", "INVALID" },
    EDoorStatus = { "SEALED", "LOCKED", "CLOSED", "OPENED" },
    EComparisonOperator = { "Equal", "NotEqual", "More", "MoreOrEqual", "Less", "LessOrEqual" },
    ETriggerOperationType = { "ENTER", "EXIT" },
    EComponentOperation = { "Enable", "Disable" },
    EMathOperationType = { "Add", "Set" },
    DeviceStimType = { "Distract", "VisualDistract", "Explosion", "VentilationAreaEffect", "None" },
    EItemOperationType = { "ADD", "REMOVE" },
    EWorkspotOperationType = { "ENTER", "LEAVE" },
    ETransformAnimationOperationType = { "PLAY", "PAUSE", "RESET", "SKIP" },
    EBinkOperationType = { "PLAY", "STOP" },
    ECLSForcedState = { "DEFAULT", "ForcedON", "ForcedOFF" },
    EPriority = { "VeryLow", "Low", "Medium", "High", "VeryHigh", "Absolute" },
    gameinteractionsEInteractionEventType = { "EIET_activate", "EIET_deactivate" }
}

-- Value helpers ---------------------------------------------------------------------------------

---@param value string?
---@return table
function deviceOperations.cname(value)
    return { ["$type"] = "CName", ["$storage"] = "string", ["$value"] = tostring(value or "") }
end

---@param data any
---@return string
function deviceOperations.readCName(data)
    if type(data) ~= "table" then return "" end
    local value = tostring(data["$value"] or "")
    -- Shipped CNames default to the literal "None"; showing that in an editable field invites
    -- someone to leave it there, where it reads as a real event/component name that does not exist.
    if value == "None" then return "" end
    return value
end

---@param value string?
---@return table
function deviceOperations.nodeRef(value)
    return { ["$type"] = "NodeRef", ["$storage"] = "string", ["$value"] = tostring(value or "") }
end

---@param value string?
---@return table
function deviceOperations.tweakDBID(value)
    return { ["$type"] = "TweakDBID", ["$storage"] = "string", ["$value"] = tostring(value or "") }
end

---@param data any
---@return string
function deviceOperations.readRawValue(data)
    if type(data) ~= "table" then return "" end
    return tostring(data["$value"] or "")
end

---@param value any
---@return boolean
function deviceOperations.readBool(value)
    return value == 1 or value == true
end

-- Field schemas ---------------------------------------------------------------------------------
--
-- `path` is relative to the operation's / trigger data's own `Data` table. `kind` picks the widget:
-- cname | noderef | tweakdbid | bool | int | float | enum (with `enum`) | class (with `base`).
-- A `list` describes a repeated struct: the quick setup draws add/remove for its entries.

deviceOperations.OPERATION_TYPES = {
    {
        class = "PlaySoundDeviceOperation", label = "Play sound",
        hint = "Plays or stops a WWise event. The entity needs a gameaudioSoundComponent for this to route anywhere.",
        list = {
            path = { "SFXs" }, itemClass = "SSFXOperationData", label = "Sounds", singular = "sound",
            fields = {
                { path = { "sfxName" }, label = "WWise event", kind = "cname", width = 240 },
                { path = { "operationType" }, label = "Action", kind = "enum", enum = "EEffectOperationType" }
            }
        }
    },
    {
        class = "PlayEffectDeviceOperation", label = "Play effect (VFX)",
        hint = "Starts or stops a particle effect already registered on the entity, by name.",
        list = {
            path = { "VFXs" }, itemClass = "SVFXOperationData", label = "Effects", singular = "effect",
            fields = {
                { path = { "vfxName" }, label = "Effect name", kind = "cname", width = 240 },
                { path = { "operationType" }, label = "Action", kind = "enum", enum = "EEffectOperationType" },
                { path = { "shouldPersist" }, label = "Persist", kind = "bool" },
                { path = { "size" }, label = "Size", kind = "float" },
                { path = { "nodeRef" }, label = "Node ref", kind = "noderef" }
            }
        }
    },
    {
        class = "ToggleComponentsDeviceOperation", label = "Toggle components",
        hint = "Enables or disables named components on this entity.",
        list = {
            path = { "components" }, itemClass = "SComponentOperationData", label = "Components", singular = "component",
            fields = {
                { path = { "componentName" }, label = "Component", kind = "cname", width = 240 },
                { path = { "operationType" }, label = "Action", kind = "enum", enum = "EComponentOperation" }
            }
        }
    },
    {
        class = "PlayTransformAnimationDeviceOperation", label = "Transform animation",
        hint = "Plays, pauses or resets a transform animation on the entity.",
        list = {
            path = { "transformAnimations" }, itemClass = "STransformAnimationData", label = "Animations", singular = "animation",
            fields = {
                { path = { "animationName" }, label = "Animation", kind = "cname", width = 240 },
                { path = { "operationType" }, label = "Action", kind = "enum", enum = "ETransformAnimationOperationType" },
                { path = { "playData", "looping" }, label = "Looping", kind = "bool" },
                { path = { "playData", "timeScale" }, label = "Time scale", kind = "float" }
            }
        }
    },
    {
        class = "MeshAppearanceDeviceOperation", label = "Mesh appearance",
        hint = "Switches the mesh appearance of the entity.",
        fields = {
            { path = { "meshesAppearence" }, label = "Appearance", kind = "cname", width = 240 }
        }
    },
    {
        class = "FactsDeviceOperation", label = "Set quest fact",
        hint = "Writes a global quest fact. This is the supported way to reach another device: it reads the fact with a Fact trigger. Facts persist in the save and are shared with every other mod, so prefix them.",
        list = {
            path = { "facts" }, itemClass = "SFactOperationData", label = "Facts", singular = "fact",
            fields = {
                { path = { "factName" }, label = "Fact", kind = "cname", width = 240 },
                { path = { "factValue" }, label = "Value", kind = "int" },
                { path = { "operationType" }, label = "Mode", kind = "enum", enum = "EMathOperationType" }
            }
        }
    },
    {
        class = "StimDeviceOperation", label = "Broadcast stimulus",
        hint = "Broadcasts a distraction stimulus that NPC AI reacts to.",
        list = {
            path = { "stims" }, itemClass = "SStimOperationData", label = "Stimuli", singular = "stimulus",
            fields = {
                { path = { "stimType" }, label = "Type", kind = "enum", enum = "DeviceStimType" },
                { path = { "operationType" }, label = "Action", kind = "enum", enum = "EEffectOperationType" },
                { path = { "radius" }, label = "Radius", kind = "float" },
                { path = { "lifeTime" }, label = "Lifetime", kind = "float" },
                { path = { "nodeRef" }, label = "Node ref", kind = "noderef" }
            }
        }
    },
    {
        class = "ApplyStatusEffectDeviceOperation", label = "Apply status effect",
        list = {
            path = { "statusEffects" }, itemClass = "SStatusEffectOperationData", label = "Effects", singular = "effect",
            fields = {
                { path = { "effect", "statusEffect" }, label = "Status effect", kind = "tweakdbid", width = 240 },
                { path = { "range" }, label = "Range", kind = "float" },
                { path = { "duration" }, label = "Duration", kind = "float" }
            }
        }
    },
    {
        class = "ApplyDamageDeviceOperation", label = "Apply damage",
        list = {
            path = { "damages" }, itemClass = "SDamageOperationData", label = "Damages", singular = "damage",
            fields = {
                { path = { "damageType" }, label = "Damage type", kind = "tweakdbid", width = 240 },
                { path = { "range" }, label = "Range", kind = "float" }
            }
        }
    },
    {
        class = "ItemsDeviceOperation", label = "Grant / remove items",
        list = {
            path = { "items" }, itemClass = "SInventoryOperationData", label = "Items", singular = "item",
            fields = {
                { path = { "itemName" }, label = "Item", kind = "tweakdbid", width = 240 },
                { path = { "quantity" }, label = "Quantity", kind = "int" },
                { path = { "operationType" }, label = "Mode", kind = "enum", enum = "EItemOperationType" }
            }
        }
    },
    {
        class = "SetMessageDeviceOperation", label = "Set LCD screen message",
        hint = "One of only two operations that reach another node, and it is hardcoded to LcdScreenControllerPS.",
        fields = {
            { path = { "targetRef" }, label = "Target node", kind = "noderef" },
            { path = { "messageRecordID" }, label = "Message record", kind = "tweakdbid", width = 240 },
            { path = { "replaceTextWithCustomNumber" }, label = "Use number", kind = "bool" },
            { path = { "customNumber" }, label = "Number", kind = "int" }
        }
    },
    {
        class = "TeleportDeviceOperation", label = "Teleport",
        fields = {
            { path = { "teleport", "nodeRef" }, label = "Destination", kind = "noderef" }
        }
    },
    {
        class = "TeleportNodetoSlotOperation", label = "Teleport node to slot",
        hint = "The other operation that reaches another node, and it only ever moves an object onto a slot.",
        fields = {
            { path = { "gameObjectRef" }, label = "Object node", kind = "noderef" },
            { path = { "slotName" }, label = "Slot", kind = "cname", width = 240 }
        }
    },
    {
        class = "PlayerWokrspotDeviceOperation", label = "Player workspot",
        hint = "Engine spelling: PlayerWokrspot.",
        fields = {
            { path = { "playerWorkspot", "componentName" }, label = "Component", kind = "cname", width = 240 },
            { path = { "playerWorkspot", "operationType" }, label = "Action", kind = "enum", enum = "EWorkspotOperationType" },
            { path = { "playerWorkspot", "freeCamera" }, label = "Free camera", kind = "bool" }
        }
    },
    {
        class = "PlayBinkDeviceOperation", label = "Play Bink video",
        fields = {
            { path = { "bink", "componentName" }, label = "Component", kind = "cname", width = 240 },
            { path = { "bink", "operationType" }, label = "Action", kind = "enum", enum = "EBinkOperationType" },
            { path = { "bink", "loop" }, label = "Loop", kind = "bool" }
        }
    },
    {
        class = "ToggleCustomActionDeviceOperation", label = "Toggle custom action",
        fields = {
            { path = { "customActionID" }, label = "Action ID", kind = "cname", width = 240 },
            { path = { "enabled" }, label = "Enabled", kind = "bool" }
        }
    },
    {
        class = "ToggleOffMeshConnectionsDeviceOperation", label = "Toggle navmesh links",
        fields = {
            { path = { "enable" }, label = "Enable", kind = "bool" },
            { path = { "affectsPlayer" }, label = "Player", kind = "bool" },
            { path = { "affectsNPCs" }, label = "NPCs", kind = "bool" }
        }
    },
    {
        class = "RequestCLSStateChangeDeviceOperation", label = "Crowd lighting state",
        fields = {
            { path = { "state" }, label = "State", kind = "enum", enum = "ECLSForcedState" },
            { path = { "priority" }, label = "Priority", kind = "enum", enum = "EPriority" },
            { path = { "sourceName" }, label = "Source", kind = "cname", width = 240 },
            { path = { "removePreviousRequests" }, label = "Replace previous", kind = "bool" }
        }
    },
    {
        class = "GenericDeviceOperation", label = "Generic (combination)",
        hint = "Carries every payload at once. Too broad for this panel: edit its arrays under Entity Instance Data.",
        deferToInstanceData = true
    }
}

deviceOperations.TRIGGER_TYPES = {
    {
        class = "BaseStateOperationsTrigger", dataClass = "BaseStateOperationTriggerData",
        label = "Device state changes",
        hint = "Fires on a change into the chosen state, not on every evaluation.",
        fields = {
            { path = { "state" }, label = "State", kind = "enum", enum = "EDeviceStatus" }
        }
    },
    {
        class = "DoorStateOperationsTrigger", dataClass = "DoorStateOperationTriggerData",
        label = "Door state changes",
        hint = "Fires on a change into the chosen state, not on every evaluation.",
        fields = {
            { path = { "state" }, label = "State", kind = "enum", enum = "EDoorStatus" }
        }
    },
    {
        class = "ActivatorOperationsTrigger", dataClass = "ActivatorOperationTriggerData",
        label = "On load (activator)",
        hint = "Fires once when the entity initialises.",
        fields = {}
    },
    {
        class = "FactOperationsTrigger", dataClass = "FactOperationTriggerData",
        label = "Quest fact changes",
        hint = "The supported way for one device to react to another: the other device writes the fact with a Set quest fact operation.",
        fields = {
            { path = { "factName" }, label = "Fact", kind = "cname", width = 240 },
            { path = { "comparisionType" }, label = "Compare", kind = "enum", enum = "EComparisonOperator" },
            { path = { "factValue" }, label = "Value", kind = "int" }
        }
    },
    {
        class = "DeviceActionOperationsTrigger", dataClass = "DeviceActionOperationTriggerData",
        label = "Device action performed",
        hint = "Matched on the action's class name only; the action instance carries nothing.",
        fields = {
            { path = { "action" }, label = "Action class", kind = "class", base = "ScriptableDeviceAction", required = true }
        }
    },
    {
        class = "CustomActionOperationsTriggers", dataClass = "CustomActionOperationTriggerData",
        label = "Custom action ID",
        fields = {
            { path = { "actionID" }, label = "Action ID", kind = "cname", width = 240 }
        }
    },
    {
        class = "TriggerVolumeOperationsTrigger", dataClass = "TriggerVolumeOperationTriggerData",
        label = "Trigger volume enter / exit",
        fields = {
            { path = { "componentName" }, label = "Component", kind = "cname", width = 240 },
            { path = { "operationType" }, label = "Direction", kind = "enum", enum = "ETriggerOperationType" },
            { path = { "isActivatorPlayer" }, label = "Player", kind = "bool" },
            { path = { "isActivatorNPC" }, label = "NPC", kind = "bool" },
            { path = { "canNPCBeDead" }, label = "Dead NPC counts", kind = "bool" }
        }
    },
    {
        class = "InteractionAreaOperationsTrigger", dataClass = "InteractionAreaOperationTriggerData",
        label = "Interaction area enter / exit",
        fields = {
            { path = { "areaTag" }, label = "Area tag", kind = "cname", width = 240 },
            { path = { "operationType" }, label = "Direction", kind = "enum", enum = "gameinteractionsEInteractionEventType" },
            { path = { "isActivatorPlayer" }, label = "Player", kind = "bool" },
            { path = { "isActivatorNPC" }, label = "NPC", kind = "bool" }
        }
    },
    {
        class = "SensesOperationsTrigger", dataClass = "SensesOperationTriggerData",
        label = "Sensed (seen / heard)",
        fields = {
            { path = { "attitudeGroup" }, label = "Attitude group", kind = "cname", width = 240 },
            { path = { "operationType" }, label = "Direction", kind = "enum", enum = "ETriggerOperationType" },
            { path = { "isActivatorPlayer" }, label = "Player", kind = "bool" },
            { path = { "isActivatorNPC" }, label = "NPC", kind = "bool" }
        }
    },
    {
        class = "HitOperationsTrigger", dataClass = "HitOperationTriggerData",
        label = "Damaged",
        hint = "Fires when health drops below the given percentage.",
        fields = {
            { path = { "healthPercentage" }, label = "Health %", kind = "float" },
            { path = { "bullets" }, label = "Bullets", kind = "bool" },
            { path = { "explosions" }, label = "Explosions", kind = "bool" },
            { path = { "melee" }, label = "Melee", kind = "bool" },
            { path = { "isAttackerPlayer" }, label = "Player", kind = "bool" },
            { path = { "isAttackerNPC" }, label = "NPC", kind = "bool" }
        }
    },
    {
        class = "FocusModeOperationsTrigger", dataClass = "FocusModeOperationTriggerData",
        label = "Scanner (focus mode)",
        fields = {
            { path = { "operationType" }, label = "Direction", kind = "enum", enum = "ETriggerOperationType" },
            { path = { "isLookedAt" }, label = "Looked at", kind = "bool" }
        }
    }
}

---@param class string
---@return table?
function deviceOperations.getOperationType(class)
    for _, entry in ipairs(deviceOperations.OPERATION_TYPES) do
        if entry.class == class then return entry end
    end
    return nil
end

---@param class string
---@return table?
function deviceOperations.getTriggerType(class)
    for _, entry in ipairs(deviceOperations.TRIGGER_TYPES) do
        if entry.class == class then return entry end
    end
    return nil
end

---@param class string
---@return string
function deviceOperations.getOperationLabel(class)
    local entry = deviceOperations.getOperationType(class)
    return entry and entry.label or tostring(class)
end

---@param class string
---@return string
function deviceOperations.getTriggerLabel(class)
    local entry = deviceOperations.getTriggerType(class)
    return entry and entry.label or tostring(class)
end

-- Templates -------------------------------------------------------------------------------------

---Ready-made setups. Each returns `{ operations = {...}, triggers = {...} }` as plain descriptors,
---which the popup turns into real objects; keeping them declarative means the templates cannot drift
---from the schemas above.
deviceOperations.TEMPLATES = {
    {
        id = "soundOnOff",
        label = "Sound on ON / OFF",
        description = "The wiki's fan example: one WWise event started when the device turns on and stopped when it turns off.",
        needsSoundComponent = true,
        build = function (prefix)
            prefix = prefix ~= "" and prefix or "sound"
            local startName, stopName = prefix .. "_start", prefix .. "_stop"
            return {
                operations = {
                    { class = "PlaySoundDeviceOperation", name = startName,
                      set = { { path = { "SFXs" }, listItem = "SSFXOperationData",
                                values = { { path = { "operationType" }, value = "START" } } } } },
                    { class = "PlaySoundDeviceOperation", name = stopName,
                      set = { { path = { "SFXs" }, listItem = "SSFXOperationData",
                                values = { { path = { "operationType" }, value = "STOP" } } } } }
                },
                triggers = {
                    { class = "BaseStateOperationsTrigger", values = { { path = { "state" }, value = "ON" } }, runs = { startName } },
                    { class = "BaseStateOperationsTrigger", values = { { path = { "state" }, value = "OFF" } }, runs = { stopName } }
                }
            }
        end
    },
    {
        id = "vfxOnOff",
        label = "VFX on ON / OFF",
        description = "Starts a named effect when the device turns on and stops it when it turns off.",
        build = function (prefix)
            prefix = prefix ~= "" and prefix or "vfx"
            local startName, stopName = prefix .. "_start", prefix .. "_stop"
            return {
                operations = {
                    { class = "PlayEffectDeviceOperation", name = startName,
                      set = { { path = { "VFXs" }, listItem = "SVFXOperationData",
                                values = { { path = { "operationType" }, value = "START" } } } } },
                    { class = "PlayEffectDeviceOperation", name = stopName,
                      set = { { path = { "VFXs" }, listItem = "SVFXOperationData",
                                values = { { path = { "operationType" }, value = "STOP" } } } } }
                },
                triggers = {
                    { class = "BaseStateOperationsTrigger", values = { { path = { "state" }, value = "ON" } }, runs = { startName } },
                    { class = "BaseStateOperationsTrigger", values = { { path = { "state" }, value = "OFF" } }, runs = { stopName } }
                }
            }
        end
    },
    {
        id = "factRelay",
        label = "Write a quest fact on ON",
        description = "Sets a fact when the device turns on. Another device reads it with a Quest fact trigger, which is the only supported way to make one device affect another.",
        build = function (prefix)
            prefix = prefix ~= "" and prefix or "device"
            local name = prefix .. "_broadcast"
            return {
                operations = {
                    { class = "FactsDeviceOperation", name = name,
                      set = { { path = { "facts" }, listItem = "SFactOperationData",
                                values = {
                                    { path = { "factName" }, value = deviceOperations.cname(prefix .. "_is_on") },
                                    { path = { "factValue" }, value = 1 },
                                    { path = { "operationType" }, value = "Set" }
                                } } } }
                },
                triggers = {
                    { class = "BaseStateOperationsTrigger", values = { { path = { "state" }, value = "ON" } }, runs = { name } }
                }
            }
        end
    }
}

-- Validation ------------------------------------------------------------------------------------

---@param name string
---@return string? problem
function deviceOperations.checkOperationName(name)
    if name == "" then
        return "Empty name: no trigger can reference this operation."
    end
    if name:find("%s") then
        -- The wiki's headline failure: the trigger fires, the name never matches, and nothing is logged.
        return "Contains whitespace. The match is exact, so this operation will never run."
    end
    return nil
end

---Cross-reference the two arrays.
---@param operationNames string[] Names in `operations` order
---@param referencedNames table<string, boolean> Names any trigger asks for
---@return table<string, boolean> unused Operations nothing references
---@return table<string, boolean> orphans References with no matching operation
---@return table<string, number> duplicates Names carried by more than one operation
function deviceOperations.crossReference(operationNames, referencedNames)
    local counts, unused, orphans, duplicates = {}, {}, {}, {}

    for _, name in ipairs(operationNames) do
        counts[name] = (counts[name] or 0) + 1
    end

    for name, count in pairs(counts) do
        if not referencedNames[name] then unused[name] = true end
        -- Not a fault: `Execute` runs *every* operation whose name matches, so sharing a name is how
        -- one trigger fans out to several operations. Surfaced as information, not a warning.
        if count > 1 then duplicates[name] = count end
    end

    for name, _ in pairs(referencedNames) do
        if not counts[name] then orphans[name] = true end
    end

    return unused, orphans, duplicates
end

---@param spawnable table entity spawnable
---@return boolean
function deviceOperations.hasSoundComponent(spawnable)
    for _, component in pairs(spawnable.defaultComponentData or {}) do
        if type(component) == "table" and component["$type"] == deviceOperations.SOUND_COMPONENT_CLASS then
            return true
        end
    end
    return false
end

---@param spawnable table entity spawnable
---@return string[]
function deviceOperations.getComponentNames(spawnable)
    local names = {}
    for _, component in pairs(spawnable.defaultComponentData or {}) do
        if type(component) == "table" and type(component.name) == "table" then
            local name = tostring(component.name["$value"] or "")
            if name ~= "" then table.insert(names, name) end
        end
    end
    table.sort(names, function (a, b) return a:lower() < b:lower() end)
    return names
end

---Does `psClass` derive from `ScriptableDeviceComponentPS`, i.e. can it hold a container at all?
---@param psClass string
---@return boolean
function deviceOperations.supportsDeviceOperations(psClass)
    if type(psClass) ~= "string" or psClass == "" then return false end

    local supported = false
    pcall(function ()
        local class = Reflection.GetClass(psClass)
        while class do
            if class:GetName().value == deviceOperations.BASE_PS_CLASS then
                supported = true
                return
            end
            class = class:GetParent()
        end
    end)

    return supported
end

return deviceOperations
