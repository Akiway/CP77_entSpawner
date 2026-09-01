local entity = require("modules/classes/spawn/entity/entity")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local registry = require("modules/utils/game/nodeRefRegistry")
local history = require("modules/utils/project/history")
local visualizer = require("modules/utils/preview/visualizer")
local Cron = require("modules/utils/vendor/Cron")
local quickElevatorSetupUI = require("modules/utils/ui/quickElevatorSetup")
local quickSoundSystemSetupUI = require("modules/utils/ui/quickSoundSystemSetup")
local positionableGroup = require("modules/classes/editor/positionableGroup")
local spawnableElement = require("modules/classes/editor/spawnableElement")
local staticMarker = require("modules/classes/spawn/meta/staticMarker")
local elevatorDoors = require("modules/utils/data/elevatorDoors")
local soundSystemData = require("modules/utils/data/soundSystem")

local POSITION_MARKER_COLOR = "blue"
local LIFT_CONTROLLER_CLASS = "LiftControllerPS"
local ELEVATOR_FLOOR_CONTROLLER_CLASS = "ElevatorFloorTerminalControllerPS"
local ELEVATOR_FLOOR_TERMINAL_PATH = "base\\gameplay\\devices\\elevators\\terminals\\elevator_floor_terminal_1.ent"
local ELEVATOR_FLOOR_TERMINAL_COMPONENT_ID = "1394923055520256000"
local DEFAULT_DOOR_CONNECTION_CLASS = "DoorControllerPS"
local SOUND_SYSTEM_CONTROLLER_CLASS = soundSystemData.SOUND_SYSTEM_CONTROLLER_CLASS
local SPEAKER_CONTROLLER_CLASS = soundSystemData.SPEAKER_CONTROLLER_CLASS
local LIFT_FLOOR_DOOR_DEFINITIONS = {
    common = {
        key = "common",
        label = "Common Lift Door",
        spawnData = "base\\gameplay\\devices\\doors\\elevator\\common_lift_door.ent",
        namePrefix = "Common_Lift_Door"
    },
    industrial = {
        key = "industrial",
        label = "Industrial Lift Door",
        spawnData = "base\\gameplay\\devices\\doors\\elevator\\industrial_lift_door_1.ent",
        namePrefix = "Industrial_Lift_Door"
    }
}
local LIFT_FLOOR_DOOR_BY_SPAWNDATA = {}
for key, definition in pairs(LIFT_FLOOR_DOOR_DEFINITIONS) do
    LIFT_FLOOR_DOOR_BY_SPAWNDATA[string.lower(definition.spawnData)] = key
end

local propertyNames = {
    "Device Class Name",
    "Persistent"
}

---Class for worldDeviceNode
---@class device : entity
---@field public deviceConnections {deviceClassName : string, nodeRef : string}[]
---@field public connectionNodeRefSearch table<string, string>
---@field public connectionsHeaderState boolean
---@field public persistent boolean
---@field private maxPropertyWidth number?
---@field public controllerComponent string
---@field public showSpeakerRangeSphere boolean Speaker only: draw the audible radius, as a sphere in the world and a ring on screen
local device = setmetatable({}, { __index = entity })

---@type fun(value: any, fallback: any?): string
local sanitizeConnectionValue = utils.sanitizeText

---@param value any
---@param defaultValue number?
---@return number
local function boolToInt(value, defaultValue)
    if value == nil then
        value = defaultValue
    end

    return (value == true or value == 1) and 1 or 0
end

---@param doorType string?
---@return table?
local function getLiftFloorDoorDefinition(doorType)
    local key = string.lower(tostring(doorType or ""))
    if key == "" then
        return nil
    end

    return LIFT_FLOOR_DOOR_DEFINITIONS[key]
end

---@param nodeRef string?
---@param storage string?
---@return "string"|"uint64"
local function normalizeNodeRefStorage(storage)
    local normalized = string.lower(tostring(storage or ""))
    if normalized == "string" then
        return "string"
    end

    return "uint64"
end

---@param nodeRef string?
---@param storage string?
---@return table
local function buildNodeRefHashValue(nodeRef, storage)
    local nodeRefStorage = normalizeNodeRefStorage(storage)
    local normalizedNodeRef = sanitizeConnectionValue(nodeRef)
    local value

    if nodeRefStorage == "string" then
        value = normalizedNodeRef
    else
        value = utils.nodeRefStringToHashString(normalizedNodeRef)
    end

    return {
        ["$type"] = "NodeRef",
        ["$storage"] = nodeRefStorage,
        ["$value"] = tostring(value or (nodeRefStorage == "string" and "" or "0"))
    }
end

---@param componentData table?
---@return string?
local function getPersistentStateClassName(componentData)
    if type(componentData) ~= "table" then
        return nil
    end

    local persistentState = componentData.persistentState
    if type(persistentState) ~= "table" then
        return nil
    end

    local data = persistentState.Data
    if type(data) == "table" and type(data["$type"]) == "string" then
        return data["$type"]
    end

    return nil
end

---Merges `override` onto a deep-copied `base` table recursively.
---Used to keep untouched default persistent-state properties when a partial override exists.
---@param base table
---@param override table
---@return table
local function mergeTableWithDefaults(base, override)
    local merged = utils.deepcopy(base or {})

    local function mergeIn(target, source)
        for key, value in pairs(source or {}) do
            if type(value) == "table" and type(target[key]) == "table" then
                mergeIn(target[key], value)
            else
                target[key] = utils.deepcopy(value)
            end
        end
    end

    mergeIn(merged, override or {})
    return merged
end

function device:new()
	local o = entity.new(self)

    o.dataType = "Device"
    o.modulePath = "entity/device"
    o.spawnDataPath = "data/spawnables/entity/device/"
    o.node = "worldDeviceNode"
    o.description = "Spawns an entity (.ent), as a worldDeviceNode. This allows it to be connected to other worldDeviceNodes."
    o.previewNote = "Device connections / functionality is not previewed."

    o.icon = IconGlyphs.AlphaDBoxOutline
    o.entryFilter = "deviceClass"

    o.deviceConnections = {}
    o.connectionNodeRefSearch = {}
    o.connectionsHeaderState = false
    o.persistent = false

    o.maxPropertyWidth = nil
    o.controllerComponent = ""
    o.positionMarkerColor = POSITION_MARKER_COLOR
    o.showDoorsHelper = true
    o.showSpeakerHelper = true
    o.showSpeakerRangeSphere = false

    setmetatable(o, { __index = self })
   	return o
end

function device:onAssemble(entRef)
    entity.onAssemble(self, entRef)

    for _, component in pairs(entRef:GetComponents()) do
        if component:IsA("gameDeviceComponent") then
            -- Is used to identify the correct component for the device, which is required for loading the persistent state of the device properly.
            -- The component name is used as part of the key when storing the persistent state in the .psrep file, so it needs to be consistent and correctly set.
            -- Otherwise the game will look for the wrong component in the .psrep file and fail to load it.
            self.controllerComponent = component.name.value

            break
        end
    end

    self:updatePositionMarker()

    -- Added on every speaker rather than on demand: `AddComponent` after the entity is attached is
    -- unreliable, and a disabled mesh component costs nothing. The real radius is only read when
    -- the sphere is actually wanted, so the common case never touches the persistent state here.
    if self.deviceClassName == SPEAKER_CONTROLLER_CLASS then
        local size = self.showSpeakerRangeSphere
            and self:getSpeakerRangeSphereSize()
            or { x = 0.01, y = 0.01, z = 0.01 }

        visualizer.addSphere(entRef, size, soundSystemData.RANGE_SPHERE_COLOR, soundSystemData.RANGE_SPHERE_COMPONENT)
        self:updateSpeakerRangeSphere(entRef)
    end
end

---Size of the audible-range preview sphere, read off this speaker's own `speakerSetup.range`.
---`base\spawner\sphere.mesh` is unit-radius, so the range goes in unscaled -- the same convention
---the light radius preview uses.
---@return { x: number, y: number, z: number }
function device:getSpeakerRangeSphereSize()
    local setup = self:getSpeakerSetup(self)
    local range = math.max(0, tonumber(setup and setup.range) or 0)

    return { x = range, y = range, z = range }
end

---Rescales and shows/hides the range sphere. Safe to call on a device that is not a speaker, or on
---one that is not spawned.
---@param entityRef entEntity? Defaults to this spawnable's live entity
---@param rangeOverride number? Live drag value, so the sphere follows the slider before it commits
function device:updateSpeakerRangeSphere(entityRef, rangeOverride)
    local target = entityRef or self:getEntity()
    if not target then
        return
    end

    local sphere = target:FindComponentByName(soundSystemData.RANGE_SPHERE_COMPONENT)
    if not sphere then
        return
    end

    -- Reading the radius means reading the persistent state, so it only happens when the sphere is
    -- going to be shown.
    if self.deviceClassName ~= SPEAKER_CONTROLLER_CLASS or self.showSpeakerRangeSphere ~= true then
        if sphere:IsEnabled() then
            sphere:Toggle(false)
        end

        return
    end

    local override = tonumber(rangeOverride)
    local size = override
        and { x = math.max(0, override), y = math.max(0, override), z = math.max(0, override) }
        or self:getSpeakerRangeSphereSize()

    -- `updateScale` re-toggles an enabled component to make the new scale take, so scale first and
    -- let the visibility check below settle the final state.
    visualizer.updateScale(target, size, soundSystemData.RANGE_SPHERE_COMPONENT)

    local shouldShow = size.x > 0
    if sphere:IsEnabled() ~= shouldShow then
        sphere:Toggle(shouldShow)
    end
end

---@param state boolean
function device:setSpeakerRangeSphereVisible(state)
    self.showSpeakerRangeSphere = state == true
    self:updateSpeakerRangeSphere()
end

function device:save()
    local data = entity.save(self)
    data.deviceConnections = utils.deepcopy(self.deviceConnections)
    data.persistent = self.persistent
    data.controllerComponent = self.controllerComponent
    data.showPositionMarker = self.showPositionMarker
    data.showDoorsHelper = self.showDoorsHelper
    data.showSpeakerHelper = self.showSpeakerHelper
    data.showSpeakerRangeSphere = self.showSpeakerRangeSphere

    return data
end

---@param currentValue string
---@return table
function device:getConnectionNodeRefOptions(currentValue)
    registry.update()

    local options = {}
    local root = self.object and self.object:getRootParent()
    local rootRefs = root and registry.refs[root.name] or nil

    if rootRefs then
        for ref, _ in pairs(rootRefs) do
            if ref ~= self.nodeRef then
                table.insert(options, ref)
            end
        end
    end

    table.sort(options)

    local cleanCurrentValue = sanitizeConnectionValue(currentValue)
    if cleanCurrentValue ~= "" and utils.indexValue(options, cleanCurrentValue) == -1 then
        table.insert(options, 1, cleanCurrentValue)
    end

    return options
end

---@param nodeRef string
---@return string?
function device:resolveConnectionClassName(nodeRef)
    local spawnable = registry.getSpawnableByNodeRef(self.object, nodeRef)
    local className = spawnable and sanitizeConnectionValue(spawnable.deviceClassName) or ""

    if className ~= "" then
        return className
    end

    return nil
end

---@param nodeRef string
---@return spawnable?, string
function device:resolveConnectionTargetSpawnable(nodeRef)
    local cleanNodeRef = sanitizeConnectionValue(nodeRef)
    if cleanNodeRef == "" then
        return nil, cleanNodeRef
    end

    registry.update()

    local spawnable = registry.getSpawnableByNodeRef(self.object, cleanNodeRef)
    local resolvedNodeRef = cleanNodeRef

    -- Support connections stored as hash strings by resolving back to the root-local NodeRef text.
    if not spawnable and not string.find(cleanNodeRef, "%D") then
        local root = self.object and self.object:getRootParent()
        local rootRefs = root and registry.refs[root.name] or nil

        if rootRefs then
            for ref, entry in pairs(rootRefs) do
                if utils.nodeRefStringToHashString(ref) == cleanNodeRef then
                    spawnable = entry.spawnable
                    resolvedNodeRef = ref
                    break
                end
            end
        end
    end

    -- Last-resort hierarchy walk, useful if registry cache is stale.
    if not spawnable and self.object and self.object.getRootParent then
        local root = self.object:getRootParent()
        if root and root.getPathsRecursive then
            for _, path in ipairs(root:getPathsRecursive(true)) do
                local ref = path.ref
                if utils.isA(ref, "spawnableElement") and ref.spawnable then
                    local candidate = sanitizeConnectionValue(ref.spawnable.nodeRef)
                    if candidate ~= "" and (candidate == cleanNodeRef or utils.nodeRefStringToHashString(candidate) == cleanNodeRef) then
                        spawnable = ref.spawnable
                        resolvedNodeRef = candidate
                        break
                    end
                end
            end
        end
    end

    return spawnable, resolvedNodeRef
end

---@param targetSpawnable entity
---@param className string
---@param fallbackComponentID string?
---@return string?
function device:getPersistentComponentID(targetSpawnable, className, fallbackComponentID)
    if not targetSpawnable then
        return nil
    end

    className = sanitizeConnectionValue(className)

    local function scanComponentData(source)
        for componentID, componentData in pairs(source or {}) do
            if getPersistentStateClassName(componentData) == className then
                return tostring(componentID)
            end
        end

        return nil
    end

    local componentID = scanComponentData(targetSpawnable.defaultComponentData)
    if componentID then
        return componentID
    end

    componentID = scanComponentData(targetSpawnable.instanceDataChanges)
    if componentID then
        return componentID
    end

    if targetSpawnable.getEntity and targetSpawnable.loadInstanceData then
        local entityRef = targetSpawnable:getEntity()
        if entityRef then
            pcall(function()
                targetSpawnable:loadInstanceData(entityRef, true)
            end)

            componentID = scanComponentData(targetSpawnable.defaultComponentData)
            if componentID then
                return componentID
            end

            componentID = scanComponentData(targetSpawnable.instanceDataChanges)
            if componentID then
                return componentID
            end
        end
    end

    if fallbackComponentID then
        fallbackComponentID = tostring(fallbackComponentID)
        if (targetSpawnable.defaultComponentData and targetSpawnable.defaultComponentData[fallbackComponentID])
            or (targetSpawnable.instanceDataChanges and targetSpawnable.instanceDataChanges[fallbackComponentID]) then
            return fallbackComponentID
        end
    end

    return nil
end

---@param targetSpawnable entity
---@param componentID string
---@param path table
---@return any
function device:getComponentPathValue(targetSpawnable, componentID, path)
    if not targetSpawnable or not componentID then
        return nil
    end

    componentID = tostring(componentID)
    local defaultRoot = targetSpawnable.defaultComponentData and targetSpawnable.defaultComponentData[componentID]

    local changedRoot = targetSpawnable.instanceDataChanges and targetSpawnable.instanceDataChanges[componentID]
    if changedRoot then
        local changedValue = utils.getNestedValue(changedRoot, path)
        if changedValue ~= nil then
            local defaultValue = defaultRoot and utils.getNestedValue(defaultRoot, path) or nil
            if type(changedValue) == "table" and type(defaultValue) == "table" then
                return mergeTableWithDefaults(defaultValue, changedValue)
            end
            return changedValue
        end
    end

    if defaultRoot then
        return utils.getNestedValue(defaultRoot, path)
    end

    return nil
end

---Reads an array valued path without merging it onto the default.
---`getComponentPathValue` merges by key, which is right for a struct but wrong for a variable
---length array: an override holding one entry would keep the defaults second entry trailing behind
---it, so deleting the last sound system entry would silently bring a shipped one back. An array is
---owned whole by whichever source last wrote it.
---@param targetSpawnable entity
---@param componentID string
---@param path table
---@return table
function device:getComponentPathArray(targetSpawnable, componentID, path)
    if not targetSpawnable or not componentID then
        return {}
    end

    componentID = tostring(componentID)

    local changedRoot = targetSpawnable.instanceDataChanges and targetSpawnable.instanceDataChanges[componentID]
    if changedRoot then
        local changedValue = utils.getNestedValue(changedRoot, path)
        if type(changedValue) == "table" then
            return utils.deepcopy(changedValue)
        end
    end

    local defaultRoot = targetSpawnable.defaultComponentData and targetSpawnable.defaultComponentData[componentID]
    if defaultRoot then
        local defaultValue = utils.getNestedValue(defaultRoot, path)
        if type(defaultValue) == "table" then
            return utils.deepcopy(defaultValue)
        end
    end

    return {}
end

---@param targetSpawnable entity
---@param componentID string
---@param path table
---@param value any
---@param options table?
function device:updateComponentPathValue(targetSpawnable, componentID, path, value, options)
    if not targetSpawnable or not componentID then
        return
    end

    options = options or {}
    local suppressRespawn = options.suppressRespawn == true

    componentID = tostring(componentID)

    local hasDefaultComponent = targetSpawnable.defaultComponentData
        and targetSpawnable.defaultComponentData[componentID]
    if not hasDefaultComponent and targetSpawnable.getEntity and targetSpawnable.loadInstanceData then
        local entityRef = targetSpawnable:getEntity()
        if entityRef then
            pcall(function()
                targetSpawnable:loadInstanceData(entityRef, true)
            end)
        end
    end

    targetSpawnable.instanceDataChanges = targetSpawnable.instanceDataChanges or {}
    targetSpawnable.instanceDataChanges[componentID] = targetSpawnable.instanceDataChanges[componentID] or {}

    local rootKey = path[1]
    local defaultRoot = targetSpawnable.defaultComponentData
        and targetSpawnable.defaultComponentData[componentID]
        and targetSpawnable.defaultComponentData[componentID][rootKey]

    if rootKey == "persistentState" then
        local persistentState = targetSpawnable.instanceDataChanges[componentID][rootKey]
        if defaultRoot ~= nil and type(persistentState) == "table" then
            persistentState = mergeTableWithDefaults(defaultRoot, persistentState)
            targetSpawnable.instanceDataChanges[componentID][rootKey] = persistentState
        elseif defaultRoot ~= nil and persistentState ~= nil and type(persistentState) ~= "table" then
            persistentState = utils.deepcopy(defaultRoot)
            targetSpawnable.instanceDataChanges[componentID][rootKey] = persistentState
        end

        if type(persistentState) == "table" then
            if persistentState.HandleId == nil then
                persistentState.HandleId = "0"
            end
            if type(persistentState.Data) ~= "table" then
                persistentState.Data = {}
            end
        end
    end

    if not suppressRespawn
        and targetSpawnable.defaultComponentData
        and targetSpawnable.defaultComponentData[componentID]
        and targetSpawnable.updatePropValue then
        -- Heal legacy/partial persistentState overrides by merging onto default root.
        if rootKey == "persistentState" and defaultRoot ~= nil then
            local changedRoot = targetSpawnable.instanceDataChanges[componentID][rootKey]
            if type(changedRoot) == "table" then
                targetSpawnable.instanceDataChanges[componentID][rootKey] = mergeTableWithDefaults(defaultRoot, changedRoot)
            elseif changedRoot ~= nil then
                targetSpawnable.instanceDataChanges[componentID][rootKey] = nil
            end
        end

        targetSpawnable:updatePropValue(componentID, path, value)
        return
    end

    if targetSpawnable.instanceDataChanges[componentID][rootKey] == nil then
        if defaultRoot ~= nil then
            targetSpawnable.instanceDataChanges[componentID][rootKey] = utils.deepcopy(defaultRoot)
        else
            if rootKey == "persistentState" then
                targetSpawnable.instanceDataChanges[componentID][rootKey] = {
                    HandleId = "0",
                    Data = {}
                }
            else
                targetSpawnable.instanceDataChanges[componentID][rootKey] = {}
            end
        end
    end

    if rootKey == "persistentState" then
        local persistentState = targetSpawnable.instanceDataChanges[componentID][rootKey]
        if type(persistentState) ~= "table" then
            persistentState = { HandleId = "0", Data = {} }
            targetSpawnable.instanceDataChanges[componentID][rootKey] = persistentState
        end
        if persistentState.HandleId == nil then
            persistentState.HandleId = "0"
        end
        if type(persistentState.Data) ~= "table" then
            persistentState.Data = {}
        end
    end

    local nested = targetSpawnable.instanceDataChanges[componentID]
    for i = 1, #path - 1 do
        local key = path[i]
        if type(nested[key]) ~= "table" then
            nested[key] = {}
        end
        nested = nested[key]
    end
    nested[path[#path]] = value

    if defaultRoot ~= nil and utils.deepcompare(defaultRoot, targetSpawnable.instanceDataChanges[componentID][rootKey], false) then
        targetSpawnable.instanceDataChanges[componentID][rootKey] = nil
        if utils.tableLength(targetSpawnable.instanceDataChanges[componentID]) == 0 then
            targetSpawnable.instanceDataChanges[componentID] = nil
        end
    end

    if not suppressRespawn then
        targetSpawnable:respawn()
    end
end

---@param terminalSpawnable entity
---@param markerNodeRef string
function device:applyLiftFloorSetupToTerminal(terminalSpawnable, markerNodeRef)
    if not terminalSpawnable then
        return
    end

    local function applyNow(options)
        options = options or {}

        local componentID = self:getPersistentComponentID(
            terminalSpawnable,
            ELEVATOR_FLOOR_CONTROLLER_CLASS,
            ELEVATOR_FLOOR_TERMINAL_COMPONENT_ID
        )
        if not componentID then
            return false
        end

        local setupPath = { "persistentState", "Data", "elevatorFloorSetup" }
        local currentSetup = self:getComponentPathValue(terminalSpawnable, componentID, setupPath)
        local normalizedSetup = self:normalizeElevatorFloorSetup(currentSetup, markerNodeRef)
        self:updateComponentPathValue(terminalSpawnable, componentID, setupPath, normalizedSetup, {
            suppressRespawn = options.suppressRespawn == true
        })
        return true
    end

    if applyNow() then
        return
    end

    if terminalSpawnable._pendingLiftFloorSetupCallback then
        return
    end

    terminalSpawnable._pendingLiftFloorSetupCallback = true
    if terminalSpawnable.registerSpawnedAndAttachedCallback then
        terminalSpawnable:registerSpawnedAndAttachedCallback(function ()
            -- Defer setup work out of the engine attach callback to avoid hard-crash respawn timing.
            Cron.After(0.05, function ()
                terminalSpawnable._pendingLiftFloorSetupCallback = nil
                if terminalSpawnable.object then
                    applyNow({ suppressRespawn = true })
                end
            end)
        end)
    else
        terminalSpawnable._pendingLiftFloorSetupCallback = nil
    end
end

---@param markerNodeRef string?
---@return table
function device:createDefaultElevatorFloorSetup(markerNodeRef)
    return {
        ["$type"] = "ElevatorFloorSetup",
        floorName = "",
        floorDisplayName = {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = "None"
        },
        authorizationTextOverride = "",
        isHidden = 0,
        isInactive = 0,
        doorShouldOpenFrontLeftRight = { 1, 1, 1 },
        floorMarker = buildNodeRefHashValue(markerNodeRef)
    }
end

---@param floorSetup table?
---@param markerNodeRef string?
---@return table
function device:normalizeElevatorFloorSetup(floorSetup, markerNodeRef)
    local normalized = utils.deepcopy(floorSetup or {})
    normalized["$type"] = "ElevatorFloorSetup"
    normalized.floorName = tostring(normalized.floorName or "")
    normalized.authorizationTextOverride = tostring(normalized.authorizationTextOverride or "")
    normalized.isHidden = boolToInt(normalized.isHidden, 0)
    normalized.isInactive = boolToInt(normalized.isInactive, 0)

    local doors = normalized.doorShouldOpenFrontLeftRight or { 1, 1, 1 }
    normalized.doorShouldOpenFrontLeftRight = {
        boolToInt(doors[1], 1),
        boolToInt(doors[2], 1),
        boolToInt(doors[3], 1)
    }

    if type(normalized.floorDisplayName) ~= "table" then
        normalized.floorDisplayName = {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = "None"
        }
    else
        normalized.floorDisplayName["$type"] = "CName"
        normalized.floorDisplayName["$storage"] = normalized.floorDisplayName["$storage"] or "string"
        normalized.floorDisplayName["$value"] = tostring(normalized.floorDisplayName["$value"] or "None")
    end

    local existingFloorMarkerStorage = type(normalized.floorMarker) == "table"
        and normalizeNodeRefStorage(normalized.floorMarker["$storage"])
        or "uint64"

    if markerNodeRef then
        normalized.floorMarker = buildNodeRefHashValue(markerNodeRef, existingFloorMarkerStorage)
    elseif type(normalized.floorMarker) ~= "table" then
        normalized.floorMarker = buildNodeRefHashValue("", "uint64")
    else
        local markerStorage = normalizeNodeRefStorage(normalized.floorMarker["$storage"])
        normalized.floorMarker["$type"] = "NodeRef"
        normalized.floorMarker["$storage"] = markerStorage

        if markerStorage == "string" then
            normalized.floorMarker["$value"] = sanitizeConnectionValue(normalized.floorMarker["$value"])
        else
            local markerValue = tostring(normalized.floorMarker["$value"] or "0")
            markerValue = utils.trimString(markerValue)
            if markerValue == "" then
                markerValue = "0"
            elseif string.find(markerValue, "%D") then
                markerValue = utils.nodeRefStringToHashString(markerValue)
            end
            normalized.floorMarker["$value"] = markerValue
        end
    end

    return normalized
end

---@param doorIndex number
---@return Vector4?
function device:getLiftDoorWorldPosition(doorIndex)
    if tostring(self.deviceClassName or "") ~= LIFT_CONTROLLER_CLASS then
        return nil
    end

    local layout, layoutKey = elevatorDoors.resolveLayout(self.spawnData)
    if type(layout) ~= "table" then
        return nil
    end

    local side = elevatorDoors.rotateSide(layout[doorIndex], elevatorDoors.LAYOUT_ROTATIONS[layoutKey])
    if not side then
        return nil
    end

    return elevatorDoors.getMarkerWorldPosition(self, side)
end

---Guarantees this device sits inside a `positionableGroup`, wrapping it in a new one when it does
---not, so quick setup has somewhere to put the nodes it creates.
---@return element?, table? group, history action for the wrap (nil when no wrap was needed)
function device:ensureOwnParentGroup()
    if not self.object or not self.object.parent then
        return nil, nil
    end

    local parent = self.object.parent
    if utils.isA(parent, "positionableGroup") then
        return parent, nil
    end

    local index = utils.indexValue(parent.childs, self.object)
    if type(index) ~= "number" or index < 1 then
        index = #parent.childs + 1
    end

    local wrapper = positionableGroup:new(self.object.sUI)
    wrapper.name = self.object.name .. "_Group"
    wrapper.headerOpen = true
    wrapper:setParent(parent, index)
    parent.headerOpen = true

    local insertGroup = history.getInsert({ wrapper })
    local removeDevice = history.getRemove({ self.object })
    self.object:setParent(wrapper)
    local insertDevice = history.getInsert({ self.object })

    registry.invalidate()
    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end

    return wrapper, history.getMoveToNewGroup(insertGroup, removeDevice, insertDevice)
end

---@return element?, table?
function device:ensureLiftParentGroup()
    return self:ensureOwnParentGroup()
end

---@param parent element
---@return number
function device:getNextElevatorFloorIndex(parent)
    local used = {}

    for _, child in ipairs(parent.childs or {}) do
        local suffix = tostring(child.name or ""):match("^Elevator_Floor_(%d+)$")
        if suffix then
            used[tonumber(suffix)] = true
        end
    end

    local nextIndex = 0
    while used[nextIndex] do
        nextIndex = nextIndex + 1
    end

    return nextIndex
end

---@return table[]
function device:getLiftFloorEntries()
    registry.update()

    local entries = {}

    for connectionIndex, connection in ipairs(self.deviceConnections) do
        local className = sanitizeConnectionValue(connection.deviceClassName)
        local rawNodeRef = sanitizeConnectionValue(connection.nodeRef)

        if className == ELEVATOR_FLOOR_CONTROLLER_CLASS and rawNodeRef ~= "" then
            local terminalSpawnable, resolvedNodeRef = self:resolveConnectionTargetSpawnable(rawNodeRef)
            local terminalElement = terminalSpawnable and terminalSpawnable.object or nil
            local folderElement = terminalElement and terminalElement.parent or nil
            local markerElement = nil

            if folderElement and folderElement.childs then
                for _, child in ipairs(folderElement.childs) do
                    if child ~= terminalElement
                        and utils.isA(child, "spawnableElement")
                        and child.spawnable
                        and child.spawnable.modulePath == "meta/staticMarker" then
                        markerElement = child
                        break
                    end
                end
            end

            table.insert(entries, {
                connection = connection,
                connectionIndex = connectionIndex,
                rawNodeRef = rawNodeRef,
                nodeRef = resolvedNodeRef,
                terminalSpawnable = terminalSpawnable,
                terminalElement = terminalElement,
                folderElement = folderElement,
                markerElement = markerElement
            })
        end
    end

    return entries
end

---@return table[]
function device:getLiftFloorDoorDefinitions()
    local ordered = { "common", "industrial" }
    local definitions = {}

    for _, key in ipairs(ordered) do
        local definition = LIFT_FLOOR_DOOR_DEFINITIONS[key]
        if definition then
            table.insert(definitions, {
                key = definition.key,
                label = definition.label,
                spawnData = definition.spawnData
            })
        end
    end

    return definitions
end

---@param parent element
---@param namePrefix string
---@return string
function device:getNextLiftFloorDoorName(parent, namePrefix)
    local prefix = tostring(namePrefix or "Lift_Door")
    local nextIndex = 0

    while true do
        local candidate = prefix .. "_" .. tostring(nextIndex)
        local exists = false

        for _, child in ipairs(parent.childs or {}) do
            if tostring(child.name or "") == candidate then
                exists = true
                break
            end
        end

        if not exists then
            return candidate
        end

        nextIndex = nextIndex + 1
    end
end

---@param entry table
---@return table[]
function device:getLiftFloorDoorEntries(entry)
    local floorDoorEntries = {}
    if not entry or not entry.terminalSpawnable then
        return floorDoorEntries
    end

    registry.update()

    local terminalSpawnable = entry.terminalSpawnable
    terminalSpawnable.deviceConnections = terminalSpawnable.deviceConnections or {}

    local seenNodeRefs = {}
    local floorGroup = entry.folderElement

    local function appendDoorEntry(connection, connectionIndex, rawNodeRef, resolvedNodeRef, doorSpawnable)
        local doorElement = doorSpawnable and doorSpawnable.object or nil
        local spawnData = string.lower(tostring(doorSpawnable and doorSpawnable.spawnData or ""))
        local definitionKey = LIFT_FLOOR_DOOR_BY_SPAWNDATA[spawnData]
        local definition = definitionKey and LIFT_FLOOR_DOOR_DEFINITIONS[definitionKey] or nil

        local finalNodeRef = sanitizeConnectionValue(resolvedNodeRef)
        if finalNodeRef == "" then
            finalNodeRef = sanitizeConnectionValue(rawNodeRef)
        end

        local className = sanitizeConnectionValue(connection and connection.deviceClassName or "")
        if className == "" and doorSpawnable then
            className = sanitizeConnectionValue(doorSpawnable.deviceClassName)
        end

        table.insert(floorDoorEntries, {
            connection = connection,
            connectionIndex = connectionIndex,
            rawNodeRef = sanitizeConnectionValue(rawNodeRef),
            nodeRef = finalNodeRef,
            doorSpawnable = doorSpawnable,
            doorElement = doorElement,
            doorType = definition and definition.key or "custom",
            doorLabel = definition and definition.label or "Custom Door",
            doorSpawnData = doorSpawnable and doorSpawnable.spawnData or (definition and definition.spawnData or ""),
            doorClassName = className
        })

        if finalNodeRef ~= "" then
            seenNodeRefs[finalNodeRef] = true
        end
    end

    for connectionIndex, connection in ipairs(terminalSpawnable.deviceConnections) do
        local className = sanitizeConnectionValue(connection.deviceClassName)
        local rawNodeRef = sanitizeConnectionValue(connection.nodeRef)
        if rawNodeRef ~= "" then
            local doorSpawnable, resolvedNodeRef = self:resolveConnectionTargetSpawnable(rawNodeRef)
            local doorElement = doorSpawnable and doorSpawnable.object or nil
            local spawnData = string.lower(tostring(doorSpawnable and doorSpawnable.spawnData or ""))
            local definitionKey = LIFT_FLOOR_DOOR_BY_SPAWNDATA[spawnData]
            local hasKnownSpawnData = definitionKey ~= nil
            local inFloorGroup = floorGroup and doorElement and doorElement.parent == floorGroup
            local classNameLower = string.lower(className)
            local looksLikeDoorConnection = classNameLower ~= "" and string.find(classNameLower, "door", 1, true) ~= nil

            if hasKnownSpawnData or inFloorGroup or looksLikeDoorConnection then
                appendDoorEntry(connection, connectionIndex, rawNodeRef, resolvedNodeRef, doorSpawnable)
            end
        end
    end

    if floorGroup and floorGroup.childs then
        for _, child in ipairs(floorGroup.childs) do
            if child ~= entry.terminalElement
                and utils.isA(child, "spawnableElement")
                and child.spawnable then
                local spawnData = string.lower(tostring(child.spawnable.spawnData or ""))
                local definitionKey = LIFT_FLOOR_DOOR_BY_SPAWNDATA[spawnData]
                if definitionKey then
                    local childNodeRef = sanitizeConnectionValue(child.spawnable.nodeRef)
                    if childNodeRef ~= "" and not seenNodeRefs[childNodeRef] then
                        appendDoorEntry(nil, nil, childNodeRef, childNodeRef, child.spawnable)
                    end
                end
            end
        end
    end

    return floorDoorEntries
end

---@param entry table
---@param doorType string
function device:addLiftFloorDoor(entry, doorType)
    if not entry or not entry.folderElement or not entry.terminalSpawnable then
        return
    end

    if self.object and self.object.isLocked and self.object:isLocked() then
        return
    end

    local doorDefinition = getLiftFloorDoorDefinition(doorType)
    if not doorDefinition then
        return
    end

    local floorGroup = entry.folderElement
    local terminalSpawnable = entry.terminalSpawnable
    terminalSpawnable.deviceConnections = terminalSpawnable.deviceConnections or {}

    local terminalPosition = (entry.terminalSpawnable and entry.terminalSpawnable.position) or self.position
    local markerPosition = (entry.markerElement and entry.markerElement.spawnable and entry.markerElement.spawnable.position) or terminalPosition
    local sourceRotation = (entry.terminalSpawnable and entry.terminalSpawnable.rotation) or self.rotation

    local markerX = tonumber(markerPosition and markerPosition.x) or tonumber(terminalPosition and terminalPosition.x) or 0
    local markerY = tonumber(markerPosition and markerPosition.y) or tonumber(terminalPosition and terminalPosition.y) or 0
    local markerZ = tonumber(markerPosition and markerPosition.z) or tonumber(terminalPosition and terminalPosition.z) or 0
    local terminalX = tonumber(terminalPosition and terminalPosition.x) or markerX
    local terminalY = tonumber(terminalPosition and terminalPosition.y) or markerY
    local towardTerminalFactor = 0.8

    local doorPosition = Vector4.new(
        markerX + (terminalX - markerX) * towardTerminalFactor,
        markerY + (terminalY - markerY) * towardTerminalFactor,
        markerZ,
        0
    )
    local doorRotation = EulerAngles.new(
        tonumber(sourceRotation and sourceRotation.roll) or 0,
        tonumber(sourceRotation and sourceRotation.pitch) or 0,
        tonumber(sourceRotation and sourceRotation.yaw) or 0
    )

    local doorSeed = device:new()
    doorSeed:loadSpawnData({
        spawnData = doorDefinition.spawnData,
        app = "default",
        nodeRef = "",
        persistent = false,
        deviceClassName = DEFAULT_DOOR_CONNECTION_CLASS,
        deviceConnections = {},
        instanceDataChanges = {},
        defaultComponentData = {}
    }, doorPosition, doorRotation)

    local doorElement = spawnableElement:new(self.object.sUI)
    doorElement:load({
        name = self:getNextLiftFloorDoorName(floorGroup, doorDefinition.namePrefix),
        spawnable = doorSeed:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    doorElement:setParent(floorGroup)
    floorGroup.headerOpen = true

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
    registry.invalidate()

    local doorSpawnable = doorElement.spawnable
    doorSpawnable.nodeRef = registry.generate(doorElement)
    registry.invalidate()

    local doorNodeRef = sanitizeConnectionValue(doorSpawnable.nodeRef)
    local connectionClassName = sanitizeConnectionValue(doorSpawnable.deviceClassName)
    if connectionClassName == "" then
        connectionClassName = sanitizeConnectionValue(self:resolveConnectionClassName(doorNodeRef))
    end
    if connectionClassName == "" then
        connectionClassName = DEFAULT_DOOR_CONNECTION_CLASS
    end

    local alreadyConnected = false
    for _, connection in ipairs(terminalSpawnable.deviceConnections) do
        if sanitizeConnectionValue(connection.nodeRef) == doorNodeRef then
            alreadyConnected = true
            if sanitizeConnectionValue(connection.deviceClassName) == "" then
                connection.deviceClassName = connectionClassName
            end
            break
        end
    end

    if not alreadyConnected then
        table.insert(terminalSpawnable.deviceConnections, {
            deviceClassName = connectionClassName,
            nodeRef = doorNodeRef
        })
    end

    local actions = {}
    local terminalOwner = entry.terminalElement or self.object
    if terminalOwner then
        table.insert(actions, history.getElementChange(terminalOwner))
    end
    table.insert(actions, history.getInsert({ doorElement }))

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    else
        history.addAction(actions[1])
    end

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
    registry.invalidate()
end

---@param entry table
---@param doorEntry table
---@param newNodeRef string
function device:updateLiftFloorDoorNodeRef(entry, doorEntry, newNodeRef)
    if not entry or not doorEntry or not entry.terminalSpawnable then
        return
    end

    local normalizedNodeRef = sanitizeConnectionValue(newNodeRef)
    if normalizedNodeRef == "" then
        return
    end
    local currentNodeRef = sanitizeConnectionValue(doorEntry.connection and doorEntry.connection.nodeRef or doorEntry.nodeRef or doorEntry.rawNodeRef or "")
    if normalizedNodeRef == currentNodeRef then
        return
    end

    local actions = {}
    local terminalOwner = entry.terminalElement or self.object
    if terminalOwner then
        table.insert(actions, history.getElementChange(terminalOwner))
    end
    if doorEntry.doorElement then
        table.insert(actions, history.getElementChange(doorEntry.doorElement))
    end

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end

    local terminalConnections = entry.terminalSpawnable.deviceConnections or {}
    entry.terminalSpawnable.deviceConnections = terminalConnections

    local connection = doorEntry.connection
    if not connection then
        local className = sanitizeConnectionValue(doorEntry.doorClassName)
        if className == "" then
            className = sanitizeConnectionValue(doorEntry.doorSpawnable and doorEntry.doorSpawnable.deviceClassName)
        end
        if className == "" then
            className = sanitizeConnectionValue(self:resolveConnectionClassName(normalizedNodeRef))
        end
        if className == "" then
            className = DEFAULT_DOOR_CONNECTION_CLASS
        end

        connection = {
            deviceClassName = className,
            nodeRef = normalizedNodeRef
        }
        table.insert(terminalConnections, connection)
        doorEntry.connection = connection
        doorEntry.connectionIndex = #terminalConnections
    else
        connection.nodeRef = normalizedNodeRef
        if sanitizeConnectionValue(connection.deviceClassName) == "" then
            local className = sanitizeConnectionValue(self:resolveConnectionClassName(normalizedNodeRef))
            if className == "" then
                className = sanitizeConnectionValue(doorEntry.doorClassName)
            end
            if className == "" then
                className = DEFAULT_DOOR_CONNECTION_CLASS
            end
            connection.deviceClassName = className
        end
    end

    if doorEntry.doorSpawnable then
        doorEntry.doorSpawnable.nodeRef = normalizedNodeRef
    end
    doorEntry.nodeRef = normalizedNodeRef
    doorEntry.rawNodeRef = normalizedNodeRef

    registry.invalidate()
    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
end

---@param entry table
---@param doorEntry table
function device:generateLiftFloorDoorNodeRef(entry, doorEntry)
    if not doorEntry or not doorEntry.doorElement then
        return
    end

    self:updateLiftFloorDoorNodeRef(entry, doorEntry, registry.generate(doorEntry.doorElement))
end

---@param entry table
---@param doorEntry table
function device:removeLiftFloorDoor(entry, doorEntry)
    if not entry or not doorEntry or not entry.terminalSpawnable then
        return
    end

    local terminalConnections = entry.terminalSpawnable.deviceConnections or {}
    entry.terminalSpawnable.deviceConnections = terminalConnections

    local targetNodeRef = sanitizeConnectionValue(doorEntry.connection and doorEntry.connection.nodeRef or doorEntry.nodeRef or doorEntry.rawNodeRef or "")
    local removedConnection = false

    for index = #terminalConnections, 1, -1 do
        local connection = terminalConnections[index]
        local sameConnection = doorEntry.connection and connection == doorEntry.connection
        local sameNodeRef = targetNodeRef ~= "" and sanitizeConnectionValue(connection.nodeRef) == targetNodeRef

        if sameConnection or sameNodeRef then
            table.remove(terminalConnections, index)
            removedConnection = true
            if sameConnection then
                break
            end
        end
    end

    local removeAction = nil
    if doorEntry.doorElement then
        removeAction = history.getRemove({ doorEntry.doorElement })
        doorEntry.doorElement:remove()
    end

    if not removedConnection and not removeAction then
        return
    end

    local actions = {}
    local terminalOwner = entry.terminalElement or self.object
    if terminalOwner then
        table.insert(actions, history.getElementChange(terminalOwner))
    end
    if removeAction then
        table.insert(actions, removeAction)
    end

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end

    registry.invalidate()
    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
end

function device:addLiftFloor()
    if not self.object or not self.object.parent or self.object:isLocked() then
        return
    end

    local parent = self.object.parent
    local actions = {}

    if not utils.isA(parent, "positionableGroup") then
        local wrappedParent, wrapAction = self:ensureLiftParentGroup()
        if wrappedParent then
            parent = wrappedParent
        end
        if wrapAction then
            table.insert(actions, wrapAction)
        end
    end

    if not parent then
        return
    end

    local floorIndex = self:getNextElevatorFloorIndex(parent)
    local suffix = tostring(floorIndex)
    local elevatorPosition = Vector4.new(self.position.x, self.position.y, self.position.z, 0)
    local markerPosition = Vector4.new(elevatorPosition.x, elevatorPosition.y, elevatorPosition.z, 0)
    local terminalPosition = self:getLiftDoorWorldPosition(1) or markerPosition
    local rotation = EulerAngles.new(self.rotation.roll, self.rotation.pitch, self.rotation.yaw)

    local group = positionableGroup:new(self.object.sUI)
    group.name = "Elevator_Floor_" .. suffix
    group.headerOpen = true
    group:setParent(parent)
    parent.headerOpen = true

    local markerSeed = staticMarker:new()
    markerSeed:loadSpawnData({
        app = "default",
        nodeRef = "",
        questMarker = false,
        previewed = true
    }, markerPosition, rotation)

    local markerElement = spawnableElement:new(self.object.sUI)
    markerElement:load({
        name = "Ground_Marker_Floor_" .. suffix,
        spawnable = markerSeed:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    markerElement:setParent(group)

    local terminalSeed = device:new()
    terminalSeed:loadSpawnData({
        spawnData = ELEVATOR_FLOOR_TERMINAL_PATH,
        app = "default",
        nodeRef = "",
        persistent = true,
        deviceClassName = ELEVATOR_FLOOR_CONTROLLER_CLASS,
        deviceConnections = {},
        instanceDataChanges = {},
        defaultComponentData = {}
    }, terminalPosition, rotation)

    local terminalElement = spawnableElement:new(self.object.sUI)
    terminalElement:load({
        name = "Terminal_Floor_" .. suffix,
        spawnable = terminalSeed:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    terminalElement:setParent(group)

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
    registry.invalidate()

    local markerSpawnable = markerElement.spawnable
    markerSpawnable.nodeRef = registry.generate(markerElement)
    registry.invalidate()

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end

    local terminalSpawnable = terminalElement.spawnable
    terminalSpawnable.nodeRef = registry.generate(terminalElement)
    terminalSpawnable.persistent = true
    terminalSpawnable.deviceClassName = ELEVATOR_FLOOR_CONTROLLER_CLASS
    registry.invalidate()

    self:applyLiftFloorSetupToTerminal(terminalSpawnable, markerSpawnable.nodeRef)

    local objectChange = history.getElementChange(self.object)
    table.insert(self.deviceConnections, {
        deviceClassName = ELEVATOR_FLOOR_CONTROLLER_CLASS,
        nodeRef = terminalSpawnable.nodeRef
    })

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end

    local insertAction = history.getInsert({ group })
    table.insert(actions, objectChange)
    table.insert(actions, insertAction)

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    else
        history.addAction(actions[1])
    end
end

---@param entries table[]
---@param index number
---@param direction number
function device:moveLiftFloor(entries, index, direction)
    local targetIndex = index + direction
    if targetIndex < 1 or targetIndex > #entries then
        return
    end

    local ownConnectionIndex = entries[index].connectionIndex
    local targetConnectionIndex = entries[targetIndex].connectionIndex
    if not ownConnectionIndex or not targetConnectionIndex then
        return
    end

    history.addAction(history.getElementChange(self.object))
    self.deviceConnections[ownConnectionIndex], self.deviceConnections[targetConnectionIndex]
        = self.deviceConnections[targetConnectionIndex], self.deviceConnections[ownConnectionIndex]
end

---@param entry table
function device:removeLiftFloor(entry)
    if not entry or not entry.connectionIndex then
        return
    end

    local actions = { history.getElementChange(self.object) }
    local removalTarget = entry.folderElement or entry.terminalElement

    if removalTarget then
        table.insert(actions, history.getRemove({ removalTarget }))
    end

    local connection = self.deviceConnections[entry.connectionIndex]
    if connection then
        self.connectionNodeRefSearch[tostring(connection)] = nil
        table.remove(self.deviceConnections, entry.connectionIndex)
    end

    if removalTarget then
        removalTarget:remove()
    end

    registry.invalidate()
    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    else
        history.addAction(actions[1])
    end
end

---@param entry table
---@param componentID string
---@param floorSetup table
---@return table
function device:updateElevatorFloorSetup(entry, componentID, floorSetup)
    local markerNodeRef = entry.markerElement
        and entry.markerElement.spawnable
        and entry.markerElement.spawnable.nodeRef
        or nil

    local normalized = self:normalizeElevatorFloorSetup(floorSetup, markerNodeRef)
    self:updateComponentPathValue(
        entry.terminalSpawnable,
        componentID,
        { "persistentState", "Data", "elevatorFloorSetup" },
        normalized
    )

    return normalized
end

-- Sound system / speaker chain -------------------------------------------------------------------

---@return string?
function device:getSoundSystemComponentID()
    return self:getPersistentComponentID(
        self,
        SOUND_SYSTEM_CONTROLLER_CLASS,
        soundSystemData.SOUND_SYSTEM_COMPONENT_ID
    )
end

---Normalized `soundSystemSettings` entries, plus the component they live on.
---@return table[], string?
function device:getSoundSystemEntries()
    local componentID = self:getSoundSystemComponentID()
    if not componentID then
        return {}, nil
    end

    local raw = self:getComponentPathArray(self, componentID, soundSystemData.SETTINGS_PATH)
    local entries = {}

    for index = 1, #raw do
        table.insert(entries, soundSystemData.normalizeEntry(raw[index]))
    end

    return entries, componentID
end

---Writes the whole entry array back, clamping `defaultAction` so it can never point past the end.
---@param entries table[]
---@param componentID string?
function device:setSoundSystemEntries(entries, componentID)
    componentID = componentID or self:getSoundSystemComponentID()
    if not componentID then
        return
    end

    local normalized = {}
    for index = 1, #entries do
        table.insert(normalized, soundSystemData.normalizeEntry(entries[index]))
    end

    -- `defaultAction` indexes this array, so a delete has to pull it back in range. Suppressed here
    -- so the array write below stays the single respawn of the operation.
    local defaultAction = math.floor(tonumber(
        self:getComponentPathValue(self, componentID, soundSystemData.DEFAULT_ACTION_PATH)
    ) or 0)
    local clampedAction = math.max(0, math.min(defaultAction, math.max(0, #normalized - 1)))

    if clampedAction ~= defaultAction then
        self:updateComponentPathValue(
            self,
            componentID,
            soundSystemData.DEFAULT_ACTION_PATH,
            clampedAction,
            { suppressRespawn = true }
        )
    end

    self:updateComponentPathValue(self, componentID, soundSystemData.SETTINGS_PATH, normalized)
end

---@param options table?
function device:addSoundSystemEntry(options)
    local entries, componentID = self:getSoundSystemEntries()
    if not componentID then
        return
    end

    history.addAction(history.getElementChange(self.object))
    table.insert(entries, soundSystemData.createEntry(options))
    self:setSoundSystemEntries(entries, componentID)
end

---@param index number
function device:removeSoundSystemEntry(index)
    local entries, componentID = self:getSoundSystemEntries()
    if not componentID or not entries[index] then
        return
    end

    history.addAction(history.getElementChange(self.object))
    table.remove(entries, index)
    self:setSoundSystemEntries(entries, componentID)
end

---@param index number
---@param direction number
function device:moveSoundSystemEntry(index, direction)
    local targetIndex = index + direction
    local entries, componentID = self:getSoundSystemEntries()

    if not componentID or targetIndex < 1 or targetIndex > #entries or not entries[index] then
        return
    end

    history.addAction(history.getElementChange(self.object))
    entries[index], entries[targetIndex] = entries[targetIndex], entries[index]
    self:setSoundSystemEntries(entries, componentID)
end

---Replaces one entry in place. The caller hands back a whole entry rather than a path, because the
---`musicSettings` handle has to be written as a unit.
---@param index number
---@param entry table
function device:updateSoundSystemEntry(index, entry)
    local entries, componentID = self:getSoundSystemEntries()
    if not componentID or not entries[index] then
        return
    end

    entries[index] = soundSystemData.normalizeEntry(entry)
    self:setSoundSystemEntries(entries, componentID)
end

---Speaker connections of this sound system, resolved to their spawnables where possible.
---@return table[]
function device:getSpeakerEntries()
    registry.update()

    local entries = {}

    for connectionIndex, connection in ipairs(self.deviceConnections) do
        local className = sanitizeConnectionValue(connection.deviceClassName)
        local rawNodeRef = sanitizeConnectionValue(connection.nodeRef)

        if className == SPEAKER_CONTROLLER_CLASS and rawNodeRef ~= "" then
            local speakerSpawnable, resolvedNodeRef = self:resolveConnectionTargetSpawnable(rawNodeRef)
            local definition = speakerSpawnable
                and soundSystemData.resolveSpeakerDefinition(speakerSpawnable.spawnData)
                or nil

            table.insert(entries, {
                connection = connection,
                connectionIndex = connectionIndex,
                rawNodeRef = rawNodeRef,
                nodeRef = resolvedNodeRef ~= "" and resolvedNodeRef or rawNodeRef,
                speakerSpawnable = speakerSpawnable,
                speakerElement = speakerSpawnable and speakerSpawnable.object or nil,
                definition = definition,
                label = definition and definition.label or "Speaker"
            })
        end
    end

    return entries
end

---Connections on this sound system that point at something the game will not drive.
---`SoundSystemControllerPS.RefreshSlaves` casts every immediate slave to `SpeakerControllerPS` and
---skips the rest, so a radio or a jukebox wired here is silently ignored -- which looks exactly like
---a broken speaker and is worth saying out loud.
---@return { nodeRef: string, className: string, reason: string, element: element? }[]
function device:getIgnoredSlaveConnections()
    registry.update()

    local ignored = {}

    for _, connection in ipairs(self.deviceConnections) do
        local className = sanitizeConnectionValue(connection.deviceClassName)
        local rawNodeRef = sanitizeConnectionValue(connection.nodeRef)
        local reason = className ~= "" and soundSystemData.getSlaveRejectionReason(className) or nil

        if reason and rawNodeRef ~= "" then
            local targetSpawnable, resolvedNodeRef = self:resolveConnectionTargetSpawnable(rawNodeRef)

            table.insert(ignored, {
                nodeRef = resolvedNodeRef ~= "" and resolvedNodeRef or rawNodeRef,
                className = className,
                reason = reason,
                element = targetSpawnable and targetSpawnable.object or nil
            })
        end
    end

    return ignored
end

---First free `<prefix>_<n>` name under `parent`. Used for both speakers and masters.
---@param parent element
---@param namePrefix string
---@return string
function device:getNextChildName(parent, namePrefix)
    local prefix = tostring(namePrefix or "Node")
    local nextIndex = 0

    while true do
        local candidate = prefix .. "_" .. tostring(nextIndex)
        local exists = false

        for _, child in ipairs(parent.childs or {}) do
            if tostring(child.name or "") == candidate then
                exists = true
                break
            end
        end

        if not exists then
            return candidate
        end

        nextIndex = nextIndex + 1
    end
end

---Spawns a speaker next to this sound system, gives it a NodeRef and connects it.
---@param speakerType string `speaker` or `virtual`
function device:addSpeaker(speakerType)
    if not self.object or not self.object.parent or self.object:isLocked() then
        return
    end

    local definition = soundSystemData.SPEAKER_DEFINITIONS[string.lower(tostring(speakerType or ""))]
    if not definition then
        return
    end

    local actions = {}
    local parent = self.object.parent

    if not utils.isA(parent, "positionableGroup") then
        local wrappedParent, wrapAction = self:ensureOwnParentGroup()
        if wrappedParent then
            parent = wrappedParent
        end
        if wrapAction then
            table.insert(actions, wrapAction)
        end
    end

    if not parent then
        return
    end

    -- Nothing in the data says where a speaker belongs, so it starts on the system and gets dragged.
    local position = Vector4.new(self.position.x, self.position.y, self.position.z, 0)
    local rotation = EulerAngles.new(self.rotation.roll, self.rotation.pitch, self.rotation.yaw)

    local speakerSeed = device:new()
    speakerSeed:loadSpawnData({
        spawnData = definition.spawnData,
        app = definition.defaultApp,
        nodeRef = "",
        persistent = false,
        deviceClassName = SPEAKER_CONTROLLER_CLASS,
        deviceConnections = {},
        instanceDataChanges = {},
        defaultComponentData = {}
    }, position, rotation)

    local speakerElement = spawnableElement:new(self.object.sUI)
    speakerElement:load({
        name = self:getNextChildName(parent, definition.namePrefix),
        spawnable = speakerSeed:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    speakerElement:setParent(parent)
    parent.headerOpen = true

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
    registry.invalidate()

    local speakerSpawnable = speakerElement.spawnable
    speakerSpawnable.nodeRef = registry.generate(speakerElement)
    speakerSpawnable.deviceClassName = SPEAKER_CONTROLLER_CLASS
    registry.invalidate()

    table.insert(actions, history.getElementChange(self.object))
    table.insert(self.deviceConnections, {
        deviceClassName = SPEAKER_CONTROLLER_CLASS,
        nodeRef = sanitizeConnectionValue(speakerSpawnable.nodeRef)
    })

    table.insert(actions, history.getInsert({ speakerElement }))

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
    registry.invalidate()

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end
end

---Keeps the speaker node and this systems connection row on the same NodeRef.
---@param speakerEntry table
---@param newNodeRef string
function device:updateSpeakerNodeRef(speakerEntry, newNodeRef)
    if not speakerEntry then
        return
    end

    local normalizedNodeRef = sanitizeConnectionValue(newNodeRef)
    if normalizedNodeRef == "" then
        return
    end

    local currentNodeRef = sanitizeConnectionValue(
        speakerEntry.connection and speakerEntry.connection.nodeRef
        or speakerEntry.nodeRef
        or speakerEntry.rawNodeRef
        or ""
    )
    if normalizedNodeRef == currentNodeRef then
        return
    end

    local changes = { history.getElementChange(self.object) }
    if speakerEntry.speakerElement then
        table.insert(changes, history.getElementChange(speakerEntry.speakerElement))
    end

    if #changes > 1 then
        history.addAction(history.getComposite(changes))
    else
        history.addAction(changes[1])
    end

    if speakerEntry.connection then
        speakerEntry.connection.nodeRef = normalizedNodeRef
    end
    if speakerEntry.speakerSpawnable then
        speakerEntry.speakerSpawnable.nodeRef = normalizedNodeRef
    end
    speakerEntry.nodeRef = normalizedNodeRef
    speakerEntry.rawNodeRef = normalizedNodeRef

    registry.invalidate()
    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
end

---@param speakerEntry table
function device:generateSpeakerNodeRef(speakerEntry)
    if not speakerEntry or not speakerEntry.speakerElement then
        return
    end

    self:updateSpeakerNodeRef(speakerEntry, registry.generate(speakerEntry.speakerElement))
end

---Removes the speaker node and its connection row.
---@param speakerEntry table
function device:removeSpeaker(speakerEntry)
    if not speakerEntry then
        return
    end

    local targetNodeRef = sanitizeConnectionValue(
        speakerEntry.connection and speakerEntry.connection.nodeRef
        or speakerEntry.nodeRef
        or speakerEntry.rawNodeRef
        or ""
    )
    local removedConnection = false

    for index = #self.deviceConnections, 1, -1 do
        local connection = self.deviceConnections[index]
        local sameConnection = speakerEntry.connection and connection == speakerEntry.connection
        local sameNodeRef = targetNodeRef ~= "" and sanitizeConnectionValue(connection.nodeRef) == targetNodeRef

        if sameConnection or sameNodeRef then
            self.connectionNodeRefSearch[tostring(connection)] = nil
            table.remove(self.deviceConnections, index)
            removedConnection = true
            if sameConnection then
                break
            end
        end
    end

    local removeAction = nil
    if speakerEntry.speakerElement then
        removeAction = history.getRemove({ speakerEntry.speakerElement })
        speakerEntry.speakerElement:remove()
    end

    if not removedConnection and not removeAction then
        return
    end

    local actions = { history.getElementChange(self.object) }
    if removeAction then
        table.insert(actions, removeAction)
    end

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    else
        history.addAction(actions[1])
    end

    registry.invalidate()
    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
end

---@param speakerSpawnable entity
---@return table?, string? setup, componentID
function device:getSpeakerSetup(speakerSpawnable)
    if not speakerSpawnable then
        return nil, nil
    end

    local componentID = self:getPersistentComponentID(
        speakerSpawnable,
        SPEAKER_CONTROLLER_CLASS,
        soundSystemData.SPEAKER_COMPONENT_ID
    )
    if not componentID then
        return nil, nil
    end

    local setup = self:getComponentPathValue(speakerSpawnable, componentID, soundSystemData.SPEAKER_SETUP_PATH)

    return soundSystemData.normalizeSpeakerSetup(setup), componentID
end

---@param speakerSpawnable entity
---@param componentID string
---@param setup table
---@return table
function device:updateSpeakerSetup(speakerSpawnable, componentID, setup)
    local normalized = soundSystemData.normalizeSpeakerSetup(setup)

    self:updateComponentPathValue(
        speakerSpawnable,
        componentID,
        soundSystemData.SPEAKER_SETUP_PATH,
        normalized
    )

    return normalized
end

---Devices in this project that drive this sound system.
---The connection lives on the master, not here, so this is a reverse lookup over the hierarchy
---rather than a read of `self.deviceConnections`.
---@return table[]
function device:getSoundSystemMasters()
    local ownNodeRef = sanitizeConnectionValue(self.nodeRef)
    if ownNodeRef == "" or not self.object or not self.object.getRootParent then
        return {}
    end

    local ownHash = utils.nodeRefStringToHashString(ownNodeRef)
    local root = self.object:getRootParent()
    if not root or not root.getPathsRecursive then
        return {}
    end

    local entries = {}

    for _, path in ipairs(root:getPathsRecursive(true)) do
        local ref = path.ref
        local spawnable = utils.isA(ref, "spawnableElement") and ref.spawnable or nil

        if spawnable and spawnable ~= self and type(spawnable.deviceConnections) == "table" then
            for connectionIndex, connection in ipairs(spawnable.deviceConnections) do
                local className = sanitizeConnectionValue(connection.deviceClassName)
                local targetNodeRef = sanitizeConnectionValue(connection.nodeRef)

                if className == SOUND_SYSTEM_CONTROLLER_CLASS
                    and targetNodeRef ~= ""
                    and (targetNodeRef == ownNodeRef or utils.nodeRefStringToHashString(targetNodeRef) == ownHash) then
                    local definition = soundSystemData.resolveMasterDefinition(spawnable.spawnData)

                    table.insert(entries, {
                        connection = connection,
                        connectionIndex = connectionIndex,
                        nodeRef = sanitizeConnectionValue(spawnable.nodeRef),
                        masterSpawnable = spawnable,
                        masterElement = ref,
                        definition = definition,
                        label = definition and definition.label or sanitizeConnectionValue(spawnable.deviceClassName),
                        isComputer = definition and definition.isComputer == true
                    })

                    break
                end
            end
        end
    end

    return entries
end

---Updates the NodeRef on a master node. The link to this sound system is stored on the master's
---connection row, so changing the master's own NodeRef does not touch the graph edge.
---@param masterEntry table
---@param newNodeRef string
function device:updateSoundSystemMasterNodeRef(masterEntry, newNodeRef)
    if not masterEntry or not masterEntry.masterSpawnable then
        return
    end

    local normalizedNodeRef = sanitizeConnectionValue(newNodeRef)
    if normalizedNodeRef == "" then
        return
    end

    local currentNodeRef = sanitizeConnectionValue(masterEntry.masterSpawnable.nodeRef)
    if normalizedNodeRef == currentNodeRef then
        return
    end

    history.addAction(history.getElementChange(masterEntry.masterElement or self.object))

    masterEntry.masterSpawnable.nodeRef = normalizedNodeRef
    masterEntry.nodeRef = normalizedNodeRef

    if self.soundSystemSelection and self.soundSystemSelection.kind == "master" then
        self.soundSystemSelection = { kind = "master", key = "nodeRef:" .. normalizedNodeRef }
    end

    registry.invalidate()
    if self.object and self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
end

---@param masterEntry table
function device:generateSoundSystemMasterNodeRef(masterEntry)
    if not masterEntry or not masterEntry.masterElement then
        return
    end

    self:updateSoundSystemMasterNodeRef(masterEntry, registry.generate(masterEntry.masterElement))
end

---Spawns a master next to this sound system, wires it up, and -- for a computer -- sets it to open
---straight onto the sound system page.
---@param masterType string Key from `soundSystemData.MASTER_DEFINITIONS`
function device:addSoundSystemMaster(masterType)
    if not self.object or not self.object.parent or self.object:isLocked() then
        return
    end

    local definition = soundSystemData.MASTER_DEFINITIONS[tostring(masterType or "")]
    if not definition then
        return
    end

    -- The connection is stored on the master and points here, so this system needs a NodeRef first.
    local ownNodeRef = sanitizeConnectionValue(self.nodeRef)
    if ownNodeRef == "" then
        return
    end

    local actions = {}
    local parent = self.object.parent

    if not utils.isA(parent, "positionableGroup") then
        local wrappedParent, wrapAction = self:ensureOwnParentGroup()
        if wrappedParent then
            parent = wrappedParent
        end
        if wrapAction then
            table.insert(actions, wrapAction)
        end
    end

    if not parent then
        return
    end

    local position = Vector4.new(self.position.x, self.position.y, self.position.z, 0)
    local rotation = EulerAngles.new(self.rotation.roll, self.rotation.pitch, self.rotation.yaw)

    local masterSeed = device:new()
    masterSeed:loadSpawnData({
        spawnData = definition.spawnData,
        app = definition.defaultApp,
        nodeRef = "",
        persistent = true,
        deviceClassName = definition.controllerClass,
        deviceConnections = {},
        instanceDataChanges = {},
        defaultComponentData = {}
    }, position, rotation)

    local masterElement = spawnableElement:new(self.object.sUI)
    masterElement:load({
        name = self:getNextChildName(parent, definition.namePrefix),
        spawnable = masterSeed:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    masterElement:setParent(parent)
    parent.headerOpen = true

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
    registry.invalidate()

    local masterSpawnable = masterElement.spawnable
    masterSpawnable.nodeRef = registry.generate(masterElement)
    masterSpawnable.deviceClassName = definition.controllerClass
    masterSpawnable.persistent = true
    masterSpawnable.deviceConnections = {
        {
            deviceClassName = SOUND_SYSTEM_CONTROLLER_CLASS,
            nodeRef = ownNodeRef
        }
    }
    registry.invalidate()

    if definition.isComputer then
        self:applyComputerTerminalPreset(masterSpawnable)
    end

    table.insert(actions, history.getInsert({ masterElement }))

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
    registry.invalidate()

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end
end

---@param masterEntry table
function device:removeSoundSystemMaster(masterEntry)
    if not masterEntry or not masterEntry.masterElement then
        return
    end

    local removeAction = history.getRemove({ masterEntry.masterElement })
    masterEntry.masterElement:remove()
    history.addAction(removeAction)

    registry.invalidate()
    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
end

---@param masterSpawnable entity
---@return table?, string? setup, componentID
function device:getComputerSetup(masterSpawnable)
    if not masterSpawnable then
        return nil, nil
    end

    local componentID = self:getPersistentComponentID(
        masterSpawnable,
        soundSystemData.COMPUTER_CONTROLLER_CLASS,
        soundSystemData.COMPUTER_COMPONENT_ID
    )
    if not componentID then
        return nil, nil
    end

    local setup = self:getComponentPathValue(masterSpawnable, componentID, soundSystemData.COMPUTER_SETUP_PATH)

    return soundSystemData.normalizeComputerSetup(setup), componentID
end

---@param masterSpawnable entity
---@param componentID string
---@param setup table
---@return table
function device:updateComputerSetup(masterSpawnable, componentID, setup)
    local normalized = soundSystemData.normalizeComputerSetup(setup)

    self:updateComponentPathValue(
        masterSpawnable,
        componentID,
        soundSystemData.COMPUTER_SETUP_PATH,
        normalized
    )

    return normalized
end

---Writes the sound-system terminal flags onto a computer, deferring until its persistent state is
---readable when it has only just been spawned.
---@param masterSpawnable entity
function device:applyComputerTerminalPreset(masterSpawnable)
    if not masterSpawnable then
        return
    end

    local function applyNow(applyOptions)
        local setup, componentID = self:getComputerSetup(masterSpawnable)
        if not setup or not componentID then
            return false
        end

        self:updateComponentPathValue(
            masterSpawnable,
            componentID,
            soundSystemData.COMPUTER_SETUP_PATH,
            soundSystemData.applyComputerTerminalPreset(setup),
            { suppressRespawn = (applyOptions or {}).suppressRespawn == true }
        )

        return true
    end

    if applyNow() then
        return
    end

    if masterSpawnable._pendingComputerTerminalPreset then
        return
    end

    masterSpawnable._pendingComputerTerminalPreset = true
    if masterSpawnable.registerSpawnedAndAttachedCallback then
        masterSpawnable:registerSpawnedAndAttachedCallback(function ()
            -- Deferred out of the attach callback, the way the lift floor setup is, to avoid the
            -- respawn timing that hard-crashes the game there.
            Cron.After(0.05, function ()
                masterSpawnable._pendingComputerTerminalPreset = nil
                if masterSpawnable.object then
                    applyNow({ suppressRespawn = true })
                end
            end)
        end)
    else
        masterSpawnable._pendingComputerTerminalPreset = nil
    end
end

quickElevatorSetupUI.install(device, {
    liftControllerClass = LIFT_CONTROLLER_CLASS,
    elevatorFloorControllerClass = ELEVATOR_FLOOR_CONTROLLER_CLASS,
    elevatorFloorTerminalComponentID = ELEVATOR_FLOOR_TERMINAL_COMPONENT_ID,
    sanitizeConnectionValue = sanitizeConnectionValue,
    boolToInt = boolToInt
})

-- The class names live on the device methods, not in the popup, so only the two shared helpers
-- need passing across.
quickSoundSystemSetupUI.install(device, {
    sanitizeConnectionValue = sanitizeConnectionValue,
    boolToInt = boolToInt
})

function device:draw()
    self:drawEntityBaseProperties()

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth(propertyNames) + 4 * ImGui.GetStyle().ItemSpacing.x
    end

    if self.deviceClassName == LIFT_CONTROLLER_CLASS then
        if ImGui.Button("Quick Elevator Setup##openLiftSetupPopup") then
            ImGui.OpenPopup(quickElevatorSetupUI.POPUP_ID)
        end
        style.tooltip("Open quick setup for LiftControllerPS and connected elevator floor terminals.")
        self:drawLiftSetupPopup()
    end

    if self.deviceClassName == SOUND_SYSTEM_CONTROLLER_CLASS then
        if ImGui.Button("Quick Sound System Setup##openSoundSystemSetupPopup") then
            ImGui.OpenPopup(quickSoundSystemSetupUI.POPUP_ID)
        end
        style.tooltip("Open quick setup for SoundSystemControllerPS entries and connected speakers.")
        self:drawSoundSystemSetupPopup()
    end

    style.mutedText("Persistent")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.persistent, _, _ = style.trackedCheckbox(self.object, "##persistent", self.persistent)
    if self.nodeRef == "" then
        self.persistent = false
        style.tooltip("Requires NodeRef to be set.")
    else
        style.tooltip("If true, the device will get an entry in the .psrep file. Not all devices need this, still subject to more testing.")
    end
    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload) then
        Game.GetPersistencySystem():ForgetObject(PersistentID.ForComponent(entEntityID.new({ hash = loadstring("return " .. utils.nodeRefStringToHashString(self.nodeRef) .. "ULL", "")() }), self.controllerComponent), true)
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reloads the devices persistent state.\nApplies to the actual device in the world (Imported), not the editor.")

    self.connectionsHeaderState = ImGui.TreeNodeEx("Device Connections")

    if self.connectionsHeaderState then
        for index, connection in ipairs(self.deviceConnections) do
            ImGui.PushID(index)

            connection.deviceClassName = sanitizeConnectionValue(connection.deviceClassName)
            connection.nodeRef = sanitizeConnectionValue(connection.nodeRef)

            connection.deviceClassName, _, _ = style.trackedTextField(self.object, "##className", connection.deviceClassName, "gameDeviceComponentPS", 150)
            style.tooltip("Device class name of the connected device. Name of the gameDeviceComponentPS used in the devices gameDeviceComponent")

            ImGui.SameLine()
            local searchKey = tostring(connection)
            local searchValue = sanitizeConnectionValue(self.connectionNodeRefSearch[searchKey] or "")
            local nodeRefOptions = self:getConnectionNodeRefOptions(connection.nodeRef)
            local nodeRefChanged
            connection.nodeRef, searchValue, nodeRefChanged = style.trackedSearchDropdown(
                "##nodeRef",
                "Search node ref...",
                connection.nodeRef,
                searchValue,
                nodeRefOptions,
                {
                    element = self.object,
                    width = style.getMaxWidth(250) - 30,
                    matchContentWidth = true,
                    allowCustom = true,
                    tooltip = "NodeRef of the connected device. Select one from this root group, or type and choose 'Use custom: ...'."
                }
            )
            connection.nodeRef = sanitizeConnectionValue(connection.nodeRef)
            self.connectionNodeRefSearch[searchKey] = searchValue
            if nodeRefChanged then
                local resolvedClassName = self:resolveConnectionClassName(connection.nodeRef)
                if resolvedClassName and resolvedClassName ~= connection.deviceClassName then
                    connection.deviceClassName = resolvedClassName
                end
            end

            ImGui.SameLine()
            if style.dangerButton(IconGlyphs.DeleteOutline .. "##deleteDeviceConnection") then
                history.addAction(history.getElementChange(self.object))
                self.connectionNodeRefSearch[searchKey] = nil
                table.remove(self.deviceConnections, index)
                ImGui.PopID()
                break
            end
            style.tooltip("Delete")

            ImGui.PopID()
        end

        if ImGui.Button("+") then
            history.addAction(history.getElementChange(self.object))
            table.insert(self.deviceConnections, { deviceClassName = "", nodeRef = "" })
        end

        ImGui.TreePop()
    end

    self:drawRescaleEntityAction()
end

function device:getPSData()
    for _, data in pairs(self.instanceDataChanges) do
        if data.persistentState and data.persistentState.Data then
            self:prepareInstanceData(data.persistentState.Data)
            return data.persistentState.Data
        end
    end
end

function device:getProperties()
    local properties = entity.getProperties(self)
    table.insert(properties, {
        id = self.node .. "Visualization",
        name = "Visualization",
        defaultHeader = false,
        draw = function()
            style.mutedText("Visualize position")
            ImGui.SameLine()
            local changed
            self.showPositionMarker, changed = style.toggleButton(IconGlyphs.HospitalMarker, self.showPositionMarker)
            if changed then
                self:setPositionMarkerVisible(self.showPositionMarker)
                self:respawn()
            end
            style.tooltip("Draw a sphere marker at the entity position.")

            if self.deviceClassName == "LiftControllerPS" then
                style.mutedText("Show doors helper")
                ImGui.SameLine()
                self.showDoorsHelper, _ = style.toggleButton(IconGlyphs.Door, self.showDoorsHelper)
                style.tooltip("Draw numbered door helper markers around the lift.")
            end

            if self.deviceClassName == SOUND_SYSTEM_CONTROLLER_CLASS then
                style.mutedText("Show speaker helper")
                ImGui.SameLine()
                self.showSpeakerHelper, _ = style.toggleButton(IconGlyphs.Speaker, self.showSpeakerHelper)
                style.tooltip("Draw a link line and numbered badge for each connected speaker.\nEach speaker's audible range follows that speaker's own range toggle.")
            elseif self.deviceClassName == SPEAKER_CONTROLLER_CLASS then
                -- One toggle for one thing: the sphere in the world and the ring on screen are two
                -- renderings of the same audible radius, so they switch together.
                style.mutedText("Show range")
                ImGui.SameLine()
                local newRangeSphere, rangeSphereToggled = style.toggleButton(IconGlyphs.HospitalMarker, self.showSpeakerRangeSphere)
                if rangeSphereToggled then
                    history.addAction(history.getElementChange(self.object))
                    self:setSpeakerRangeSphereVisible(newRangeSphere)
                end
                style.tooltip("Draw this speaker's audible radius: a solid sphere in the world, the way the light radius preview does, and a ring on screen.")
            end
        end
    })
    return properties
end

function device:export(index, length)
    local data = entity.export(self, index, length)

    data.type = "worldDeviceNode"
    data.data.deviceConnections = {}

    local connections = {}
    local classOrder = {}

    -- Group by deviceClassName
    for _, connection in ipairs(self.deviceConnections) do
        if not connections[connection.deviceClassName] then
            connections[connection.deviceClassName] = {}
            table.insert(classOrder, connection.deviceClassName)
        end

        table.insert(connections[connection.deviceClassName], connection.nodeRef)
    end

    for _, className in ipairs(classOrder) do
        local connection = connections[className] or {}
        local nodeRefs = {}

        for _, nodeRef in ipairs(connection) do
            table.insert(nodeRefs, {
                ["$type"] = "NodeRef",
                ["$storage"] = "string",
                ["$value"] = nodeRef
            })
        end

        table.insert(data.data.deviceConnections, {
            ["$type"] = "worldDeviceConnections",
            ["deviceClassName"] = {
                ["$type"] = "CName",
                ["$storage"] = "string",
                ["$value"] = className
            },
            ["nodeRefs"] = nodeRefs
        })
    end

    return data
end

return device
