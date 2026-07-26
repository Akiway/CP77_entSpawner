local entity = require("modules/classes/spawn/entity/entity")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local registry = require("modules/utils/nodeRefRegistry")
local history = require("modules/utils/history")
local visualizer = require("modules/utils/visualizer")
local Cron = require("modules/utils/Cron")
local quickElevatorSetupUI = require("modules/utils/ui/quickElevatorSetup")
local positionableGroup = require("modules/classes/editor/positionableGroup")
local spawnableElement = require("modules/classes/editor/spawnableElement")
local staticMarker = require("modules/classes/spawn/meta/staticMarker")

local POSITION_MARKER_COMPONENT = "sphere"
local POSITION_MARKER_SCALE = { x = 0.05, y = 0.05, z = 0.05 }
local POSITION_MARKER_COLOR = "blue"
local LIFT_CONTROLLER_CLASS = "LiftControllerPS"
local ELEVATOR_FLOOR_CONTROLLER_CLASS = "ElevatorFloorTerminalControllerPS"
local ELEVATOR_FLOOR_TERMINAL_PATH = "base\\gameplay\\devices\\elevators\\terminals\\elevator_floor_terminal_1.ent"
local ELEVATOR_FLOOR_TERMINAL_COMPONENT_ID = "1394923055520256000"
local DEFAULT_DOOR_CONNECTION_CLASS = "DoorControllerPS"
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

local ELEVATOR_DOOR_LAYOUTS = {
    common = {
        [1] = "left",
        [2] = "right"
    },
    megabuilding = {
        [1] = "right",
        [2] = "bottom",
        [3] = "top"
    },
    commonRiot = {
        [1] = "left",
        [2] = "bottom"
    },
    industrial = {
        [1] = "left",
        [2] = "right"
    },
    construction = {
        [1] = "right",
        [2] = "left"
    }
}

local ELEVATOR_DOOR_LAYOUT_ROTATIONS = {
    common = "ccw",
    industrial = "cw",
    construction = "ccw"
}

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

---@param spawnData string?
---@return table
---@return string
local function resolveLiftDoorLayout(spawnData)
    local normalized = string.lower(tostring(spawnData or ""))

    if string.find(normalized, "megabuilding", 1, true) then
        return ELEVATOR_DOOR_LAYOUTS.megabuilding, "megabuilding"
    end

    if string.find(normalized, "common_riot", 1, true) or string.find(normalized, "riot", 1, true) then
        return ELEVATOR_DOOR_LAYOUTS.commonRiot, "commonRiot"
    end

    if string.find(normalized, "industrial", 1, true) then
        return ELEVATOR_DOOR_LAYOUTS.industrial, "industrial"
    end

    if string.find(normalized, "construction", 1, true) then
        return ELEVATOR_DOOR_LAYOUTS.construction, "construction"
    end

    return ELEVATOR_DOOR_LAYOUTS.common, "common"
end

---@param side string?
---@param rotation string?
---@return string?
local function rotateDoorSide(side, rotation)
    if not side then
        return nil
    end

    if rotation == "cw" then
        local cw = {
            left = "top",
            top = "right",
            right = "bottom",
            bottom = "left"
        }

        return cw[side] or side
    end

    if rotation == "ccw" then
        local ccw = {
            left = "bottom",
            bottom = "right",
            right = "top",
            top = "left"
        }

        return ccw[side] or side
    end

    return side
end

---@param lift device
---@param side string
---@return Vector4?
local function getLiftDoorMarkerWorldPosition(lift, side)
    if not lift or not lift.position or not lift.rotation or not lift.getBBox then
        return nil
    end

    local bbox = lift:getBBox()
    if not bbox or not bbox.min or not bbox.max then
        return nil
    end

    local minX = tonumber(bbox.min.x) or -0.5
    local minY = tonumber(bbox.min.y) or -0.5
    local minZ = tonumber(bbox.min.z) or -0.5
    local maxX = tonumber(bbox.max.x) or 0.5
    local maxY = tonumber(bbox.max.y) or 0.5
    local maxZ = tonumber(bbox.max.z) or 0.5

    local sizeX = math.max(0.01, maxX - minX)
    local sizeY = math.max(0.01, maxY - minY)
    local sizeZ = math.max(0.01, maxZ - minZ)

    local padding = math.max(0.15, math.min(1.0, math.max(sizeX, sizeY) * 0.12))
    local localPoint = Vector4.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, minZ + sizeZ * 0.45, 0)

    if side == "left" then
        localPoint.x = minX - padding
    elseif side == "right" then
        localPoint.x = maxX + padding
    elseif side == "top" then
        localPoint.y = maxY + padding
    elseif side == "bottom" then
        localPoint.y = minY - padding
    end

    local worldPoint = lift.rotation:ToQuat():Transform(localPoint)
    return utils.addVector(lift.position, worldPoint)
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
    o.showPositionMarker = false
    o.showDoorsHelper = true

    setmetatable(o, { __index = self })
   	return o
end

function device:updatePositionMarker()
    local entityRef = self:getEntity()
    if not entityRef then return end

    local marker = entityRef:FindComponentByName(POSITION_MARKER_COMPONENT)

    if self.showPositionMarker then
        if not marker then
            visualizer.addSphere(entityRef, POSITION_MARKER_SCALE, POSITION_MARKER_COLOR)
        else
            visualizer.updateScale(entityRef, POSITION_MARKER_SCALE, POSITION_MARKER_COMPONENT)
            marker:Toggle(true)
        end
    elseif marker then
        marker:Toggle(false)
    end
end

function device:setPositionMarkerVisible(state)
    self.showPositionMarker = state
    self:updatePositionMarker()
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
end

function device:save()
    local data = entity.save(self)
    data.deviceConnections = utils.deepcopy(self.deviceConnections)
    data.persistent = self.persistent
    data.controllerComponent = self.controllerComponent
    data.showPositionMarker = self.showPositionMarker
    data.showDoorsHelper = self.showDoorsHelper

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

    local layout, layoutKey = resolveLiftDoorLayout(self.spawnData)
    if type(layout) ~= "table" then
        return nil
    end

    local side = rotateDoorSide(layout[doorIndex], ELEVATOR_DOOR_LAYOUT_ROTATIONS[layoutKey])
    if not side then
        return nil
    end

    return getLiftDoorMarkerWorldPosition(self, side)
end

---@return element?, table?
function device:ensureLiftParentGroup()
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
    local removeLift = history.getRemove({ self.object })
    self.object:setParent(wrapper)
    local insertLift = history.getInsert({ self.object })

    registry.invalidate()
    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end

    return wrapper, history.getMoveToNewGroup(insertGroup, removeLift, insertLift)
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

quickElevatorSetupUI.install(device, {
    liftControllerClass = LIFT_CONTROLLER_CLASS,
    elevatorFloorControllerClass = ELEVATOR_FLOOR_CONTROLLER_CLASS,
    elevatorFloorTerminalComponentID = ELEVATOR_FLOOR_TERMINAL_COMPONENT_ID,
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
