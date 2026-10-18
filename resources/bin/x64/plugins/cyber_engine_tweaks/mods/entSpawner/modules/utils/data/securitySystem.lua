local utils = require("modules/utils/core/utils")
local redValue = require("modules/utils/data/redValue")
local outlineConsumer = require("modules/utils/game/outlineConsumer")

---Shared constants and helpers for the Quick Security System Setup.
---
---A network is a security system linked to one or more security areas. The system owns faction,
---minimap and access tiers; each area owns its volume, type, filters and schedule.
---@class securitySystem
local securitySystem = {}

securitySystem.SECURITY_SYSTEM_CONTROLLER_CLASS = "SecuritySystemControllerPS"
securitySystem.SECURITY_AREA_CONTROLLER_CLASS = "SecurityAreaControllerPS"
securitySystem.COMMUNITY_PROXY_CLASS = "CommunityProxyPS"

securitySystem.SECURITY_SYSTEM_PATH = "base\\gameplay\\devices\\security_systems\\security_system.ent"
securitySystem.SECURITY_AREA_PATH = "base\\gameplay\\devices\\security_systems\\security_area\\security_area_1.ent"

---Legacy empty templates that should not be offered.
securitySystem.LEGACY_STUB_PATHS = {
    ["base\\gameplay\\devices\\systems\\security_system\\security_system.ent"] = true,
    ["base\\gameplay\\devices\\systems\\security_system\\security_area.ent"] = true
}

---Fallback CRUIDs used before component data is fully loaded.
securitySystem.SECURITY_SYSTEM_COMPONENT_ID = "1425553149548834824"
securitySystem.SECURITY_AREA_COMPONENT_ID = "1395159393761816576"
---The trigger-volume component on `security_area_1.ent`.
securitySystem.AREA_SHAPE_COMPONENT_ID = "1508365491801698304"
securitySystem.AREA_SHAPE_COMPONENT_CLASS = "gameStaticTriggerAreaComponent"

-- Instance data paths ----------------------------------------------------------------------------

---System controller persistent-state paths.
securitySystem.ATTITUDE_GROUP_PATH = { "persistentState", "Data", "attitudeGroup" }
securitySystem.ATTITUDE_MODE_PATH = { "persistentState", "Data", "attitudeChangeMode" }
securitySystem.SUPPRESS_ATTITUDE_PATH = { "persistentState", "Data", "suppressAbilityToModifyAttitude" }
securitySystem.ALLOW_SELF_DISABLE_PATH = { "persistentState", "Data", "allowSecuritySystemToDisableItself" }
securitySystem.HIDE_ON_MINIMAP_PATH = { "persistentState", "Data", "hideAreasOnMinimap" }
securitySystem.AUTO_RESET_PATH = { "persistentState", "Data", "performAutomaticResetAfter" }

---Area controller persistent-state paths.
securitySystem.AREA_TYPE_PATH = { "persistentState", "Data", "securityAreaType" }
securitySystem.AREA_ACCESS_LEVEL_PATH = { "persistentState", "Data", "securityAccessLevel" }
securitySystem.AREA_TRANSITIONS_PATH = { "persistentState", "Data", "areaTransitions" }
securitySystem.EVENTS_FILTERS_PATH = { "persistentState", "Data", "eventsFilters" }

---Persistent-state paths shared by systems and areas.
securitySystem.DEVICE_STATE_PATH = { "persistentState", "Data", "deviceState" }
securitySystem.DEVICE_NAME_PATH = { "persistentState", "Data", "deviceName" }
securitySystem.BREACH_DIFFICULTY_PATH = { "persistentState", "Data", "backdoorBreachDifficulty" }

---Area trigger component outline path.
securitySystem.OUTLINE_PATH = { "outline", "Data" }

---`level_0` .. `level_4`, relative to the system's `controller` component.
---@param level number 0-4
---@return table
function securitySystem.getAccessLevelPath(level)
    return { "persistentState", "Data", "level_" .. tostring(math.floor(tonumber(level) or 0)) }
end

-- Enums ------------------------------------------------------------------------------------------

---`ESecurityAreaType` names. New areas default to the common world value: `RESTRICTED`.
securitySystem.AREA_TYPES = { "DISABLED", "SAFE", "RESTRICTED", "DANGEROUS" }
securitySystem.DEFAULT_AREA_TYPE = "RESTRICTED"

---Display metadata for area types.
securitySystem.AREA_TYPE_INFO = {
    DISABLED = {
        label = "Disabled",
        color = 0xFF948778,
        hint = "Inert. Reports nothing and shows nothing.\nUsually the resting state of a scheduled area."
    },
    SAFE = {
        label = "Safe",
        color = 0xFF6B7F2C,
        hint = "The system protects the player here.\nMeant for police-adjacent zones."
    },
    RESTRICTED = {
        label = "Restricted",
        color = 0xFF146EA9,
        hint = "Trespassing is illegal but not instantly lethal."
    },
    DANGEROUS = {
        label = "Dangerous",
        color = 0xFF2940AC,
        hint = "Shoot on sight."
    }
}

---`ESecurityAccessLevel` names; `ESL_0`..`ESL_4` map to system `level_n` arrays.
securitySystem.ACCESS_LEVELS = { "ESL_NONE", "ESL_LOCAL", "ESL_0", "ESL_1", "ESL_2", "ESL_3", "ESL_4" }
securitySystem.ACCESS_LEVEL_LABELS = {
    ESL_NONE = "None",
    ESL_LOCAL = "Local (device's own code)",
    ESL_0 = "Level 0",
    ESL_1 = "Level 1",
    ESL_2 = "Level 2",
    ESL_3 = "Level 3",
    ESL_4 = "Level 4"
}

---Which `level_n` array on the system an access level reads from, or nil when it reads none.
---@param accessLevel string?
---@return number?
function securitySystem.getAccessLevelIndex(accessLevel)
    local index = tostring(accessLevel or ""):match("^ESL_(%d)$")

    return index and tonumber(index) or nil
end

---`EFilterType`, in enum order.
securitySystem.FILTER_TYPES = { "ALLOW_NONE", "ALLOW_COMBAT_ONLY", "ALLOW_ALL" }
securitySystem.FILTER_LABELS = {
    ALLOW_NONE = "Allow none",
    ALLOW_COMBAT_ONLY = "Combat only",
    ALLOW_ALL = "Allow all"
}

---`ETransitionMode`, in enum order.
securitySystem.TRANSITION_MODES = { "GENTLE", "FORCED" }
securitySystem.TRANSITION_MODE_LABELS = {
    GENTLE = "Gentle",
    FORCED = "Forced"
}

---`EShouldChangeAttitude` names. The script starts at `TEMPORARLY`; the quick setup seeds
---`DEFAULT_ATTITUDE_MODE` on any system without a mode of its own.
securitySystem.ATTITUDE_MODES = { "PERSISTENTLY", "TEMPORARLY" }
securitySystem.ATTITUDE_MODE_LABELS = {
    PERSISTENTLY = "Persistent",
    TEMPORARLY = "Temporary"
}
securitySystem.DEFAULT_ATTITUDE_MODE = "PERSISTENTLY"

---`EGameplayChallengeLevel`, in enum order.
securitySystem.BREACH_DIFFICULTIES = { "NONE", "TRIVIAL", "EASY", "MEDIUM", "HARD", "IMPOSSIBLE" }

---`EDeviceStatus` members a security node can be authored into; the rest are runtime results.
securitySystem.DEVICE_STATES = { "ON", "OFF", "DISABLED" }

---`ESecurityGateEntranceType`, in enum order.
securitySystem.GATE_ENTRANCE_TYPES = { "OnlySideA", "OnlySideB", "AnySide" }
securitySystem.GATE_ENTRANCE_LABELS = {
    OnlySideA = "Side A only",
    OnlySideB = "Side B only",
    AnySide = "Either side"
}

---`ESecurityGateResponseType`, in enum order.
securitySystem.GATE_RESPONSE_TYPES = { "AUDIOVISUAL_ONLY", "SEC_SYS_REPRIMAND", "SEC_SYS_COMBAT" }
securitySystem.GATE_RESPONSE_LABELS = {
    AUDIOVISUAL_ONLY = "Alert only",
    SEC_SYS_REPRIMAND = "Reprimand",
    SEC_SYS_COMBAT = "Combat"
}

-- Faction ----------------------------------------------------------------------------------------

---Attitude groups with controller script special cases, pinned in the picker.
securitySystem.PINNED_ATTITUDE_GROUPS = {
    "Attitudes.Group_Neutral",
    "Attitudes.Group_Hostile",
    "Attitudes.Group_Friendly",
    "Attitudes.Group_Police"
}

local pinnedAttitudeGroups = {}
for _, record in ipairs(securitySystem.PINNED_ATTITUDE_GROUPS) do
    pinnedAttitudeGroups[record] = true
end

---Static TweakDB record list; CET cannot enumerate these records live.
securitySystem.ATTITUDE_GROUPS_FILE = "data/static/attitude_groups.txt"

local attitudeGroups = nil
local attitudeGroupSet = nil

---Every known attitude group, pinned entries first and the rest alphabetical. Loaded once.
---@return string[] groups
---@return table<string, boolean> known
function securitySystem.getAttitudeGroups()
    if attitudeGroups ~= nil and attitudeGroupSet ~= nil then
        return attitudeGroups, attitudeGroupSet
    end

    attitudeGroups = {}
    attitudeGroupSet = {}

    local rest = {}
    local file = io.open(securitySystem.ATTITUDE_GROUPS_FILE, "r")

    if file then
        for line in file:lines() do
            local record = utils.sanitizeText(line)
            if record:match("^Attitudes%.Group_") then
                attitudeGroupSet[record] = true
                table.insert(rest, record)
            end
        end

        file:close()
    end

    table.sort(rest)

    for _, pinned in ipairs(securitySystem.PINNED_ATTITUDE_GROUPS) do
        if attitudeGroupSet[pinned] then
            table.insert(attitudeGroups, pinned)
        end
    end

    for _, record in ipairs(rest) do
        if not pinnedAttitudeGroups[record] then
            table.insert(attitudeGroups, record)
        end
    end

    return attitudeGroups, attitudeGroupSet
end

---True when `record` names a shipped attitude group.
---@param record string?
---@return boolean
function securitySystem.isKnownAttitudeGroup(record)
    local _, known = securitySystem.getAttitudeGroups()

    return known[utils.sanitizeText(record)] == true
end

-- Struct builders --------------------------------------------------------------------------------

---A `SecurityAccessLevelEntry` keycard/password pair.
---@param password string?
---@param keycard string?
---@return table
function securitySystem.newAccessLevelEntry(password, keycard)
    return {
        ["$type"] = "SecurityAccessLevelEntry",
        keycard = redValue.tweakDBID(keycard, { sanitize = true, emptyAsZero = true }),
        password = redValue.cName(password, { sanitize = true, emptyAsNone = true })
    }
end

---An `AreaTypeTransition`: at `hour`, become `transitionTo`.
---Runtime-only fields are kept at their empty values.
---@param transitionTo string? `ESecurityAreaType` member
---@param hour number? 0-23
---@param mode string? `ETransitionMode` member
---@return table
function securitySystem.newAreaTransition(transitionTo, hour, mode)
    local hourValue = math.floor(utils.toNumber(hour, 0))

    return {
        ["$type"] = "AreaTypeTransition",
        transitionTo = tostring(transitionTo or securitySystem.DEFAULT_AREA_TYPE),
        transitionHour = math.max(0, math.min(23, hourValue)),
        transitionMode = tostring(mode or "GENTLE"),
        listenerID = 0,
        locked = 0
    }
end

---An `EventsFilters` pair.
---@param incoming string?
---@param outgoing string?
---@return table
function securitySystem.newEventsFilters(incoming, outgoing)
    return {
        ["$type"] = "EventsFilters",
        incomingEventsFilter = tostring(incoming or "ALLOW_ALL"),
        outgoingEventsFilter = tostring(outgoing or "ALLOW_ALL")
    }
end

---A `Time`, as `performAutomaticResetAfter` stores it.
---@param days number?
---@param hours number?
---@param minutes number?
---@return table
function securitySystem.newTime(days, hours, minutes)
    return {
        ["$type"] = "Time",
        days = math.max(0, math.floor(utils.toNumber(days, 0))),
        hours = math.max(0, math.floor(utils.toNumber(hours, 0))),
        minutes = math.max(0, math.floor(utils.toNumber(minutes, 0)))
    }
end

---An `AreaShapeOutline` for the `area` component's outline handle.
---
---`points` and `height` are the whole class: those are the only two properties RTTI carries. The
---`buffer` that WolvenKit shows on a shipped outline is the packed on-disk form of `points`, written
---by the CR2W serializer, and is not a property at all -- writing one made `JSONToRedData` fail on an
---unknown key, which took the area's entire instance data down with it at assemble time. Export was
---never affected, because it reads `points`; only the in-editor preview lost its overrides.
---@param points table[] Array of `Vector3` tables, relative to the device node
---@param height number?
---@return table
function securitySystem.newOutline(points, height)
    return {
        ["$type"] = "AreaShapeOutline",
        height = utils.toNumber(height, 0),
        points = points or {}
    }
end

---Whether a stored outline matches a freshly computed one, using a small float epsilon.
---@param current any The `AreaShapeOutline` read back from instance data
---@param candidate table
---@return boolean
function securitySystem.outlineMatches(current, candidate)
    if type(current) ~= "table" or type(candidate) ~= "table" then
        return false
    end

    local currentPoints = current.points
    local candidatePoints = candidate.points

    if type(currentPoints) ~= "table" or type(candidatePoints) ~= "table" then
        return false
    end

    if #currentPoints ~= #candidatePoints then
        return false
    end

    local epsilon = 0.0001

    if math.abs(utils.toNumber(current.height, 0) - utils.toNumber(candidate.height, 0)) > epsilon then
        return false
    end

    for index, point in ipairs(candidatePoints) do
        local other = currentPoints[index]

        if type(other) ~= "table" then
            return false
        end

        if math.abs(utils.toNumber(other.X, 0) - utils.toNumber(point.X, 0)) > epsilon
            or math.abs(utils.toNumber(other.Y, 0) - utils.toNumber(point.Y, 0)) > epsilon
            or math.abs(utils.toNumber(other.Z, 0) - utils.toNumber(point.Z, 0)) > epsilon then
            return false
        end
    end

    return true
end

-- Normalizers ------------------------------------------------------------------------------------

---Coerce a read-back transition into the full struct shape.
---@param entry table?
---@return table
function securitySystem.normalizeAreaTransition(entry)
    entry = type(entry) == "table" and entry or {}

    return securitySystem.newAreaTransition(
        utils.indexValue(securitySystem.AREA_TYPES, tostring(entry.transitionTo or "")) ~= -1
            and entry.transitionTo
            or securitySystem.DEFAULT_AREA_TYPE,
        entry.transitionHour,
        utils.indexValue(securitySystem.TRANSITION_MODES, tostring(entry.transitionMode or "")) ~= -1
            and entry.transitionMode
            or "GENTLE"
    )
end

---@param entry table?
---@return table
function securitySystem.normalizeAccessLevelEntry(entry)
    entry = type(entry) == "table" and entry or {}

    return securitySystem.newAccessLevelEntry(
        redValue.readCName(entry.password),
        redValue.readTweakDBID(entry.keycard)
    )
end

---@param filters table?
---@return table
function securitySystem.normalizeEventsFilters(filters)
    filters = type(filters) == "table" and filters or {}

    local function pick(value)
        return utils.indexValue(securitySystem.FILTER_TYPES, tostring(value or "")) ~= -1 and value or "ALLOW_ALL"
    end

    return securitySystem.newEventsFilters(pick(filters.incomingEventsFilter), pick(filters.outgoingEventsFilter))
end

---@param time table?
---@return table
function securitySystem.normalizeTime(time)
    time = type(time) == "table" and time or {}

    return securitySystem.newTime(time.days, time.hours, time.minutes)
end

-- Graph ------------------------------------------------------------------------------------------

---Graph icons shared with the device hierarchy where possible.
securitySystem.SYSTEM_ICON = IconGlyphs.SecurityNetwork
securitySystem.AREA_ICON = IconGlyphs.SelectionMarker
securitySystem.COMMUNITY_ICON = IconGlyphs.AccountGroupOutline

---Network graph colours, packed ABGR for ImGui.
securitySystem.CHAIN_COLORS = {
    system = { normal = 0xFF8A5A2B, contrast = 0xFFD9A05B },
    area = { normal = 0xFF146EA9, contrast = 0xFF4FB0E8 },
    community = { normal = 0xFF6B7F2C, contrast = 0xFF9BC44F },
    device = { normal = 0xFF7A5C8A, contrast = 0xFFC08FD4 }
}

---@param role string `system`, `area`, `community` or `device`
---@param highContrast boolean?
---@return integer
function securitySystem.getChainColor(role, highContrast)
    local pair = securitySystem.CHAIN_COLORS[tostring(role or "")] or securitySystem.CHAIN_COLORS.system

    return highContrast and pair.contrast or pair.normal
end

---@param areaType string?
---@return integer
function securitySystem.getAreaTypeColor(areaType)
    local info = securitySystem.AREA_TYPE_INFO[tostring(areaType or "")]

    return info and info.color or securitySystem.CHAIN_COLORS.area.normal
end

---@param areaType string?
---@return string
function securitySystem.getAreaTypeLabel(areaType)
    local info = securitySystem.AREA_TYPE_INFO[tostring(areaType or "")]

    return info and info.label or tostring(areaType or "")
end

-- Connected devices ------------------------------------------------------------------------------

---Device controllers offered by the graph, most commonly networked first.
---`variants` lists alternate entity bodies for the same controller class.
securitySystem.SLAVE_CLASSES = {
    {
        key = "camera",
        class = "SurveillanceCameraControllerPS",
        label = "Surveillance camera",
        namePrefix = "Camera",
        spawnData = "base\\gameplay\\devices\\security_systems\\surveillance_cameras\\surveillance_camera.ent"
    },
    {
        key = "turret",
        class = "SecurityTurretControllerPS",
        label = "Security turret",
        namePrefix = "Turret",
        spawnData = "base\\gameplay\\devices\\security_systems\\security_turret\\ceiling_turret.ent",
        variants = {
            { label = "Ceiling turret", spawnData = "base\\gameplay\\devices\\security_systems\\security_turret\\ceiling_turret.ent" },
            { label = "Mounted turret", spawnData = "base\\gameplay\\devices\\security_systems\\security_turret\\security_turret_1.ent" }
        }
    },
    {
        key = "alarm",
        class = "SecurityAlarmControllerPS",
        label = "Security alarm",
        namePrefix = "Alarm",
        spawnData = "base\\gameplay\\devices\\masters\\alarm_security\\alarm.ent"
    },
    {
        key = "detector",
        class = "DoorProximityDetectorControllerPS",
        label = "Proximity detector",
        namePrefix = "Detector",
        spawnData = "base\\gameplay\\devices\\security_systems\\detectors\\detector_base.ent"
    },
    {
        key = "accessPoint",
        class = "AccessPointControllerPS",
        label = "Access point",
        namePrefix = "AccessPoint",
        spawnData = "ep1\\gameplay\\devices\\masters\\access_points\\accesspoint.ent"
    },
    {
        key = "gate",
        class = "SecurityGateControllerPS",
        label = "Security gate",
        namePrefix = "SecurityGate",
        spawnData = "base\\gameplay\\devices\\security_systems\\security_gate_and_locker\\security_gate.ent"
    },
    { key = "door", class = "DoorControllerPS", label = "Door" },
    { key = "explosive", class = "ExplosiveTriggerDeviceControllerPS", label = "Explosive trigger" }
}

local slaveDefinitionsByKey = {}
local slaveDefinitionsByClass = {}
for _, definition in ipairs(securitySystem.SLAVE_CLASSES) do
    slaveDefinitionsByKey[definition.key] = definition
    slaveDefinitionsByClass[definition.class] = definition
end

securitySystem.COMMUNITY_MODULE_PATH = "ai/communityArea"

---Glyph for a device class on this network.
---The entity module is required lazily to avoid a load-time dependency cycle.
---@param className string?
---@return string
function securitySystem.getSlaveIcon(className)
    local entity = require("modules/classes/spawn/entity/entity")
    local icon = entity.getDeviceSecondaryIcon and entity.getDeviceSecondaryIcon(className) or ""

    if icon ~= "" then
        return icon
    end

    return IconGlyphs.Chip
end

---Resolves the default or variant entity path for a slave definition.
---@param definition table? Entry from `securitySystem.SLAVE_CLASSES`
---@param spawnData string? Variant path, or nil for the entry's default
---@return string?
function securitySystem.resolveSlaveSpawnData(definition, spawnData)
    if not definition or not definition.spawnData then
        return nil
    end

    if not spawnData or spawnData == definition.spawnData then
        return definition.spawnData
    end

    for _, variant in ipairs(definition.variants or {}) do
        if variant.spawnData == spawnData then
            return variant.spawnData
        end
    end

    return nil
end

---Finds a slave definition by menu key.
---@param key string
---@return table?
function securitySystem.getSlaveDefinition(key)
    return slaveDefinitionsByKey[tostring(key or "")]
end

---@param className string?
---@return table?
function securitySystem.getSlaveDefinitionByClass(className)
    return slaveDefinitionsByClass[utils.sanitizeText(className)]
end

-- Connected device settings ----------------------------------------------------------------------

---Struct valued persistent-state properties a driven device carries. Each is written whole.
securitySystem.DEVICE_STRUCTS = {
    detection = {
        path = { "persistentState", "Data", "detectionParameters" },
        type = "DetectionParameters"
    },
    targeting = {
        path = { "persistentState", "Data", "targetingBehaviour" },
        type = "TargetingBehaviour"
    },
    illegal = {
        path = { "persistentState", "Data", "illegalActions" },
        type = "IllegalActionTypes"
    },
    camera = {
        path = { "persistentState", "Data", "cameraProperties" },
        type = "CameraSetup"
    },
    alarm = {
        path = { "persistentState", "Data", "securityAlarmSetup" },
        type = "SecurityAlarmSetup"
    },
    gateDetection = {
        path = { "persistentState", "Data", "securityGateDetectionProperties" },
        type = "SecurityGateDetectionProperties"
    },
    gateResponse = {
        path = { "persistentState", "Data", "securityGateResponseProperties" },
        type = "SecurityGateResponseProperties"
    }
}

---Stamps `$type` on a struct read back from instance data, keeping every member it carries.
---@param current any Value read through `getComponentPathValue`
---@param typeName string RED class name
---@return table
function securitySystem.normalizeDeviceStruct(current, typeName)
    local struct = type(current) == "table" and utils.deepcopy(current) or {}

    struct["$type"] = typeName

    return struct
end

local SENSOR_CLASSES = {
    SurveillanceCameraControllerPS = true,
    SecurityTurretControllerPS = true
}

---Settings offered per driven device, as the sections the panel renders.
---Group: `classes` limits it to those controllers, absent means all.
---Field: `path` under the controller's persistent data, or `struct` from `DEVICE_STRUCTS` + `field`;
---`inline` continues the previous row; `classDefaults` overrides `default` per controller.
securitySystem.DEVICE_SETTING_GROUPS = {
    {
        key = "security",
        label = "Security",
        fields = {
            {
                key = "deviceState",
                label = "Device State",
                kind = "enum",
                path = securitySystem.DEVICE_STATE_PATH,
                values = securitySystem.DEVICE_STATES,
                default = "ON",
                width = 120,
                tooltip = "State this device starts in.\nOff and Disabled both stop it feeding the network until something turns it back on."
            },
            {
                key = "breach",
                label = "Breach",
                kind = "enum",
                path = securitySystem.BREACH_DIFFICULTY_PATH,
                values = securitySystem.BREACH_DIFFICULTIES,
                default = "EASY",
                width = 120,
                tooltip = "Difficulty of the breach protocol minigame started from this device."
            },
            {
                key = "backdoor",
                label = "Backdoor",
                checkbox = "Network backdoor",
                kind = "bool",
                inline = true,
                path = { "persistentState", "Data", "hasNetworkBackdoor" },
                default = false,
                classDefaults = { AccessPointControllerPS = true },
                tooltip = "Makes this device a jack-in point, so the player can breach the whole network through it."
            },
            {
                key = "illegalRegular",
                label = "Illegal",
                checkbox = "Actions",
                kind = "bool",
                struct = "illegal",
                field = "regularActions",
                default = false,
                tooltip = "Using this device the normal way counts as a crime inside a security area."
            },
            {
                key = "illegalQuickHacks",
                checkbox = "Quickhacks",
                kind = "bool",
                inline = true,
                struct = "illegal",
                field = "quickHacks",
                default = false,
                tooltip = "Quickhacking this device counts as a crime inside a security area."
            },
            {
                key = "illegalSkillChecks",
                checkbox = "Skill checks",
                kind = "bool",
                inline = true,
                struct = "illegal",
                field = "skillChecks",
                default = true,
                tooltip = "Forcing this device open counts as a crime inside a security area."
            },
            {
                key = "disableQuickHacks",
                label = "Quickhacks",
                checkbox = "Disabled",
                kind = "bool",
                path = { "persistentState", "Data", "disableQuickHacks" },
                default = false,
                tooltip = "Strips every quickhack off this device, so it cannot be taken over remotely."
            }
        }
    },
    {
        key = "detection",
        label = "Detection",
        classes = SENSOR_CLASSES,
        fields = {
            {
                key = "canDetectIntruders",
                label = "Intruders",
                checkbox = "Detects intruders",
                kind = "bool",
                struct = "detection",
                field = "canDetectIntruders",
                default = true,
                tooltip = "Off leaves the device on the network as a prop: it still takes orders, but reports nobody."
            },
            {
                key = "isPartOfPrevention",
                checkbox = "Reports to prevention",
                kind = "bool",
                inline = true,
                path = { "persistentState", "Data", "isPartOfPrevention" },
                default = false,
                tooltip = "Escalates what it sees to the prevention system, so the police respond rather than just this network."
            },
            {
                key = "canRotate",
                label = "Rotation",
                checkbox = "Can rotate",
                kind = "bool",
                struct = "targeting",
                field = "canRotate",
                default = true,
                tooltip = "Lets the device sweep its cone instead of staring down its mount direction."
            },
            {
                key = "maxRotationAngle",
                kind = "float",
                inline = true,
                prefix = "yaw",
                suffix = "deg",
                struct = "detection",
                field = "maxRotationAngle",
                default = 90,
                min = -2,
                max = 360,
                step = 1,
                format = "%.0f",
                tooltip = "How wide the sweep is. 0 pins the device to its mount direction,\n-1 turns a full circle to the left and -2 a full circle to the right."
            },
            {
                key = "pitchAngle",
                kind = "float",
                inline = true,
                prefix = "pitch",
                suffix = "deg",
                struct = "detection",
                field = "pitchAngle",
                default = -15,
                min = -90,
                max = 90,
                step = 1,
                format = "%.0f",
                tooltip = "Tilt of the detection cone, positive looking up."
            },
            {
                key = "timeToActionAfterSpot",
                label = "Reaction",
                kind = "float",
                struct = "detection",
                field = "timeToActionAfterSpot",
                default = 2,
                min = 0,
                max = 60,
                step = 0.1,
                format = "%.1f",
                suffix = "s",
                tooltip = "Grace period between spotting an intruder and acting on it.\nZero reacts the moment the target enters the cone."
            },
            {
                key = "lostTargetLookAtTime",
                label = "Lost Target",
                kind = "float",
                prefix = "look",
                suffix = "s",
                struct = "targeting",
                field = "lostTargetLookAtTime",
                default = 2,
                min = 0,
                max = 60,
                step = 0.1,
                format = "%.1f",
                tooltip = "How long the device keeps staring at the spot where it lost its target."
            },
            {
                key = "lostTargetSearchTime",
                kind = "float",
                inline = true,
                prefix = "search",
                suffix = "s",
                struct = "targeting",
                field = "lostTargetSearchTime",
                default = 10,
                min = 0,
                max = 60,
                step = 0.1,
                format = "%.1f",
                tooltip = "How long it sweeps for the target afterwards before going back to idle."
            }
        }
    },
    {
        key = "camera",
        label = "Camera",
        classes = { SurveillanceCameraControllerPS = true },
        fields = {
            {
                key = "canStreamVideo",
                label = "Video Feed",
                checkbox = "Can be watched",
                kind = "bool",
                struct = "camera",
                field = "canStreamVideo",
                default = false,
                tooltip = "Lets the player take the camera over and see through it."
            }
        }
    },
    {
        key = "alarm",
        label = "Alarm",
        classes = { SecurityAlarmControllerPS = true },
        fields = {
            {
                key = "useSound",
                label = "Sound",
                checkbox = "Play alarm sound",
                kind = "bool",
                struct = "alarm",
                field = "useSound",
                default = false,
                tooltip = "Off leaves a silent alarm: the network is alerted, the player hears nothing."
            }
        }
    },
    {
        key = "gate",
        label = "Gate",
        classes = { SecurityGateControllerPS = true },
        fields = {
            {
                key = "performWeaponCheck",
                label = "Scans",
                checkbox = "Weapons",
                kind = "bool",
                struct = "gateDetection",
                field = "performWeaponCheck",
                default = true,
                tooltip = "Flags anyone carrying a weapon through the gate."
            },
            {
                key = "performCyberwareCheck",
                checkbox = "Cyberware",
                kind = "bool",
                inline = true,
                struct = "gateDetection",
                field = "performCyberwareCheck",
                default = false,
                tooltip = "Flags illegal cyberware on anyone passing through."
            },
            {
                key = "performCheckOnPlayerOnly",
                checkbox = "Player only",
                kind = "bool",
                inline = true,
                struct = "gateDetection",
                field = "performCheckOnPlayerOnly",
                default = true,
                tooltip = "Lets NPCs walk through unscanned, so only the player can trip the gate."
            },
            {
                key = "scannerEntranceType",
                label = "Entrance",
                kind = "enum",
                struct = "gateDetection",
                field = "scannerEntranceType",
                values = securitySystem.GATE_ENTRANCE_TYPES,
                labels = securitySystem.GATE_ENTRANCE_LABELS,
                default = "OnlySideA",
                width = 130,
                tooltip = "Which way through the gate is scanned. Sides are the gate entity's own A and B."
            },
            {
                key = "securityGateResponseType",
                label = "Response",
                kind = "enum",
                struct = "gateResponse",
                field = "securityGateResponseType",
                values = securitySystem.GATE_RESPONSE_TYPES,
                labels = securitySystem.GATE_RESPONSE_LABELS,
                default = "SEC_SYS_REPRIMAND",
                width = 130,
                tooltip = "What a failed scan costs: a noise, a warning from the network, or an immediate fight.\nReprimand and Combat need the gate wired to a security system, which it is here."
            },
            {
                key = "securityLevelAccessGranted",
                label = "Clearance",
                kind = "enum",
                struct = "gateResponse",
                field = "securityLevelAccessGranted",
                values = securitySystem.ACCESS_LEVELS,
                labels = securitySystem.ACCESS_LEVEL_LABELS,
                default = "ESL_3",
                width = 190,
                tooltip = "Clearance a clean pass hands out, letting the player through doors on the same tier."
            }
        }
    },
    {
        key = "accessPoint",
        label = "Access Point",
        classes = { AccessPointControllerPS = true },
        fields = {
            {
                key = "isVirtual",
                label = "Virtual",
                checkbox = "No physical device",
                kind = "bool",
                path = { "persistentState", "Data", "isVirtual" },
                default = false,
                tooltip = "Marks the access point as a network fixture with nothing to walk up to and jack into."
            }
        }
    }
}

---Setting groups that apply to a controller class, in panel order.
---@param className string?
---@return table[]
function securitySystem.getDeviceSettingGroups(className)
    local name = utils.sanitizeText(className)
    local groups = {}

    for _, group in ipairs(securitySystem.DEVICE_SETTING_GROUPS) do
        if not group.classes or group.classes[name] then
            table.insert(groups, group)
        end
    end

    return groups
end

---Default outline group name and square marker layout for new areas.
securitySystem.NEW_OUTLINE_GROUP_NAME = "outline"
securitySystem.NEW_OUTLINE_RADIUS = 4
securitySystem.NEW_OUTLINE_HEIGHT = 6

---Corner offsets, counter-clockwise from -X/-Y, matching the winding of the shipped entity's box.
---@param radius number?
---@return table[] offsets `{x, y}` pairs
function securitySystem.getNewOutlineOffsets(radius)
    return outlineConsumer.getSquareOffsets(tonumber(radius) or securitySystem.NEW_OUTLINE_RADIUS)
end

-- Schedule ---------------------------------------------------------------------------------------

---Transitions fire on whole hours, letting the UI disable duplicate-hour choices.
securitySystem.HOURS_PER_DAY = 24

---@type string[]
securitySystem.HOUR_OPTIONS = (function()
    local hours = {}

    for hour = 0, 23 do
        table.insert(hours, string.format("%02d:00", hour))
    end

    return hours
end)()

---@param hour number?
---@return string
function securitySystem.getHourLabel(hour)
    return securitySystem.HOUR_OPTIONS[(math.floor(utils.toNumber(hour, 0)) % securitySystem.HOURS_PER_DAY) + 1]
end

---Hours already claimed by transitions, keyed by hour.
---@param transitions table[]?
---@param ignoreIndex number? Row being edited, excluded so it never disables its own current hour
---@return table<number, boolean>
function securitySystem.getUsedTransitionHours(transitions, ignoreIndex)
    local used = {}

    for index, entry in ipairs(transitions or {}) do
        if index ~= ignoreIndex and type(entry) == "table" then
            used[math.floor(utils.toNumber(entry.transitionHour, 0)) % securitySystem.HOURS_PER_DAY] = true
        end
    end

    return used
end

---@param transitions table[]?
---@return number? hour Nil when all 24 hours are taken
function securitySystem.getFirstFreeTransitionHour(transitions)
    local used = securitySystem.getUsedTransitionHours(transitions)

    for hour = 0, securitySystem.HOURS_PER_DAY - 1 do
        if not used[hour] then
            return hour
        end
    end

    return nil
end

---Area type for each hour of day one. Schedules do not reset at midnight.
---@param baseType string? The area's own `securityAreaType`
---@param transitions table[]?
---@return string[] hours 24 `ESecurityAreaType` member names, index 1 = 00:00
function securitySystem.getScheduleTimeline(baseType, transitions)
    local sorted = {}

    for _, entry in ipairs(transitions or {}) do
        if type(entry) == "table" then
            table.insert(sorted, securitySystem.normalizeAreaTransition(entry))
        end
    end

    -- Keep duplicate-hour ordering stable.
    table.sort(sorted, function(a, b) return a.transitionHour < b.transitionHour end)

    local timeline = {}
    local current = tostring(baseType or securitySystem.DEFAULT_AREA_TYPE)
    local nextEntry = 1

    for hour = 0, securitySystem.HOURS_PER_DAY - 1 do
        while sorted[nextEntry] and sorted[nextEntry].transitionHour == hour do
            current = sorted[nextEntry].transitionTo
            nextEntry = nextEntry + 1
        end

        table.insert(timeline, current)
    end

    return timeline
end

---Returns day one, following days, and whether they match.
---Following days start from the type left at the end of day one.
---@param baseType string? The area's own `securityAreaType`
---@param transitions table[]?
---@return string[] firstDay
---@return string[] followingDays
---@return boolean loops True when the two readings match, i.e. the schedule repeats cleanly
function securitySystem.getScheduleTimelines(baseType, transitions)
    local firstDay = securitySystem.getScheduleTimeline(baseType, transitions)
    local followingDays = securitySystem.getScheduleTimeline(
        firstDay[securitySystem.HOURS_PER_DAY],
        transitions
    )

    for hour = 1, securitySystem.HOURS_PER_DAY do
        if firstDay[hour] ~= followingDays[hour] then
            return firstDay, followingDays, false
        end
    end

    return firstDay, followingDays, true
end

-- Access codes -----------------------------------------------------------------------------------

---The five code tiers a system carries, as `level_0` .. `level_4`.
securitySystem.ACCESS_LEVEL_COUNT = 5

---`ESL_n` for a tier index, the inverse of `getAccessLevelIndex`.
---@param index number 0-4
---@return string
function securitySystem.accessLevelForIndex(index)
    return "ESL_" .. tostring(math.floor(utils.toNumber(index, 0)))
end

---Whether an access level entry authorizes nobody.
---@param entry table?
---@return boolean
function securitySystem.accessLevelEntryIsEmpty(entry)
    entry = type(entry) == "table" and entry or {}

    return redValue.readCName(entry.password) == ""
        and redValue.readTweakDBID(entry.keycard) == ""
end

---Reason an area should always be linked to a system, surfaced by validation.
securitySystem.SECURITY_AREA_NEEDS_SYSTEM =
    "No security system connects to this area. SetAreaType() dereferences its system unguarded, so the area should always be linked."

---@param deviceClassName string?
---@return boolean
function securitySystem.isSecuritySystem(deviceClassName)
    return utils.sanitizeText(deviceClassName) == securitySystem.SECURITY_SYSTEM_CONTROLLER_CLASS
end

---@param deviceClassName string?
---@return boolean
function securitySystem.isSecurityArea(deviceClassName)
    return utils.sanitizeText(deviceClassName) == securitySystem.SECURITY_AREA_CONTROLLER_CLASS
end

---Whether to offer the quick setup at all.
---@param deviceClassName string?
---@return boolean
function securitySystem.supportsSecuritySetup(deviceClassName)
    return securitySystem.isSecuritySystem(deviceClassName) or securitySystem.isSecurityArea(deviceClassName)
end

return securitySystem
