local intersection = require("modules/utils/editor/intersection")
local spawnable = require("modules/classes/spawn/spawnable")
local builder = require("modules/utils/game/entityBuilder")
local utils = require("modules/utils/core/utils")
local gameUtils = require("modules/utils/game/gameUtils")
local cache = require("modules/utils/game/cache")
local visualizer = require("modules/utils/preview/visualizer")
local red = require("modules/utils/interop/redConverter")
local style = require("modules/ui/style")
local history = require("modules/utils/project/history")
local registry = require("modules/utils/game/nodeRefRegistry")
local Cron = require("modules/utils/vendor/Cron")
local preview = require("modules/utils/preview/previewUtils")
local previewControls = require("modules/utils/preview/previewControls")
local appearanceHelper = require("modules/utils/ui/appearanceHelper")
local logger = require("modules/utils/core/logger")
local colorUtil = require("modules/utils/ui/color")
local lightComponentUI = require("modules/utils/ui/lightComponentUI")
local tweakDb = require("modules/utils/game/tweakDbUtils")
local saveState = require("modules/utils/project/saveState")

local POSITION_MARKER_COMPONENT = "sphere"
local POSITION_MARKER_SCALE = { x = 0.05, y = 0.05, z = 0.05 }
local POSITION_MARKER_DEFAULT_COLOR = "blue"

local deviceClassSecondaryIconByName = {
    LiftControllerPS = IconGlyphs.ElevatorPassengerOutline,
    ForkliftControllerPS = IconGlyphs.Forklift,
    ComputerControllerPS = IconGlyphs.DesktopClassic,
    SpeakerControllerPS = IconGlyphs.Speaker,
    RadioControllerPS = IconGlyphs.Radio,
    TVControllerPS = IconGlyphs.TelevisionClassic,
    LcdScreenControllerPS = IconGlyphs.Television,
    DoorControllerPS = IconGlyphs.Door,
    ReflectorControllerPS = IconGlyphs.Spotlight,
    ElectricLightControllerPS = IconGlyphs.LightbulbSpot,
    DataTermControllerPS = IconGlyphs.DoorSlidingOpen,
    SecurityGateControllerPS = IconGlyphs.MagnifyScan,
    SecurityLockerControllerPS = IconGlyphs.Locker,
    BaseDestructibleControllerPS = IconGlyphs.GlassFragile,
    DestructibleMasterDeviceControllerPS = IconGlyphs.GlassFragile,
    TrafficIntersectionManagerControllerPS = IconGlyphs.TrafficLightOutline,
    CrossingLightControllerPS = IconGlyphs.TrafficLightOutline,
    TrafficZebraControllerPS = IconGlyphs.Walk,
    IceMachineControllerPS = IconGlyphs.IceCream,
    ArcadeMachineControllerPS = IconGlyphs.GamepadVariantOutline,
    VendingMachineControllerPS = IconGlyphs.Store,
    VentilationEffectorControllerPS = IconGlyphs.Hvac,
    VentilationAreaControllerPS = IconGlyphs.Hvac,
    DoorProximityDetectorControllerPS = IconGlyphs.MotionSensor,
    RoadBlockControllerPS = IconGlyphs.BoomGate,
    SecurityAreaControllerPS = IconGlyphs.Security,
    SecurityAlarmControllerPS = IconGlyphs.AlarmBell,
    SecuritySystemControllerPS = IconGlyphs.SecurityNetwork,
    SecurityTurretControllerPS = IconGlyphs.Pistol,
    SecurityGateLockControllerPS = IconGlyphs.DoorClosedLock,
    AccessPointControllerPS = IconGlyphs.AccessPointNetwork,
    LaserDetectorControllerPS = IconGlyphs.LaserPointer,
    RoadBlockTrapControllerPS = IconGlyphs.BoomGateAlert,
    HoloFeederControllerPS = IconGlyphs.Projector,
    HoloTableControllerPS = IconGlyphs.TableFurniture,
    RetractableAdControllerPS = IconGlyphs.Advertisements,
    AlarmLightControllerPS = IconGlyphs.AlarmLightOutline,
    BillboardDeviceControllerPS = IconGlyphs.Billboard,
    FanControllerPS = IconGlyphs.Fan,
    FrameControllerPS = IconGlyphs.ImageFrame,
    FuseBoxControllerPS = IconGlyphs.FuseBlade,
    FuseControllerPS = IconGlyphs.Fuse,
    LadderControllerPS = IconGlyphs.Ladder,
    SlidingLadderControllerPS = IconGlyphs.Ladder,
    SmokeMachineControllerPS = IconGlyphs.Smoke,
    SoundSystemControllerPS = IconGlyphs.SurroundSound,
    JukeboxControllerPS = IconGlyphs.Music,
    StashControllerPS = IconGlyphs.TreasureChestOutline,
    C4ControllerPS = IconGlyphs.Bomb,
    CandleControllerPS = IconGlyphs.Candle,
    CleaningMachineControllerPS = IconGlyphs.WashingMachine,
    DisposalDeviceControllerPS = IconGlyphs.Coffin,
    RoboticArmsControllerPS = IconGlyphs.RobotIndustrial,
    ServerNodeControllerPS = IconGlyphs.ServerNetworkOutline,
    InvisibleSceneStashControllerPS = IconGlyphs.TreasureChestOutline,
    ToiletControllerPS = IconGlyphs.Toilet,
    NcartTimetableControllerPS = IconGlyphs.TimelineClockOutline,
    NetrunnerChairControllerPS = IconGlyphs.Seat,
    ExplosiveDeviceControllerPS = IconGlyphs.Bomb,
    TrafficLightControllerPS = IconGlyphs.TrafficLightOutline,
    vehicleControllerPS = IconGlyphs.CarEstate,
    WardrobeControllerPS = IconGlyphs.WardrobeOutline,
    SurveillanceCameraControllerPS = IconGlyphs.Cctv,
    SimpleSwitchControllerPS = IconGlyphs.ToggleSwitchOffOutline,
    TerminalControllerPS = IconGlyphs.GestureTapButton,
    ElevatorFloorTerminalControllerPS = IconGlyphs.GestureSwipeVertical,
    VendingTerminalControllerPS = IconGlyphs.CartOutline,
    SmartHouseControllerPS = IconGlyphs.HomeAutomation,
    ElectricBoxControllerPS = IconGlyphs.MeterElectricOutline,
    SmartWindowControllerPS = IconGlyphs.WindowOpenVariant,
    WindowBlindersControllerPS = IconGlyphs.BlindsHorizontal,
    WindowControllerPS = IconGlyphs.WindowClosedVariant
}

local deviceClassSourceByModulePath = {
    ["entity/entityTemplate"] = true,
    ["entity/device"] = true,
    ["entity/ammEntity"] = true
}

---Class for base entity handling
---@class entity : spawnable
---@field public apps table
---@field public appsLoaded boolean
---@field public appIndex integer
---@field private assetPreviewAppIndex integer Index the asset preview's automatic appearance cycle last reached
---@field private bBoxCallback function
---@field public bBox table {min: Vector4, max: Vector4}
---@field public bBoxLoaded boolean
---@field public meshes table
---@field public instanceDataChanges table Changes to the default data, regardless of app (Matched by ID)
---@field public defaultComponentData table Default data for each component, regardless of whether it was changed. Keeps up to date with app changes
---@field public deviceClassName string
---@field public propertiesWidth table?
---@field protected appSearch string
---@field protected assetPreviewTimer number
---@field protected assetPreviewBackplane mesh?
---@field protected instanceDataSearch string
---@field protected instanceDataSearchInProperties boolean
---@field protected psControllerID string
local entity = setmetatable({}, { __index = spawnable })

function entity:new()
	local o = spawnable.new(self)

    o.spawnListType = "list"
    o.dataType = "Entity"
    o.modulePath = "entity/entity"
    o.icon = IconGlyphs.AlphaEBoxOutline

    o.apps = {}
    o.appsLoaded = false
    o.appIndex = 0
    o.assetPreviewAppIndex = 0
    o.appSearch = ""
    o.bBoxCallback = nil
    o.bBox = { min = Vector4.new(-0.5, -0.5, -0.5, 0), max = Vector4.new( 0.5, 0.5, 0.5, 0) }
    o.bBoxLoaded = false
    o.meshes = {}

    o.instanceDataChanges = {}
    o.defaultComponentData = {}
    o.typeInfo = {}
    o.enumInfo = {}
    o.locKeyPreviewCache = {}
    o.deviceClassName = ""
    o.secondaryIcon = ""
    o.instanceDataSearch = ""
    o.instanceDataSearchInProperties = false
    o.psControllerID = ""
    o.rescaleEntityMultiplier = 1
    o.componentOverridesByName = {}

    o.showPositionMarker = false
    o.positionMarkerColor = POSITION_MARKER_DEFAULT_COLOR

    o.assetPreviewType = "backdrop"
    o.assetPreviewDelay = 0.15
    o.assetPreviewTimer = 0
    o.assetPreviewBackplane = nil

    o.uk10 = 1056

    setmetatable(o, { __index = self })
   	return o
end

---Normalizes a device class name for lookup/caching (trim + strip non-ASCII).
---@type fun(value: any, fallback: any?): string
local sanitizeDeviceClassName = utils.sanitizeText

---Public wrapper for device class normalization used across modules.
---@param value any
---@return string
function entity.sanitizeDeviceClassName(value)
    return sanitizeDeviceClassName(value)
end

---Returns whether a spawn module can provide/resolve device class names.
---@param modulePath string?
---@return boolean
function entity.supportsDeviceClassSource(modulePath)
    return modulePath ~= nil and deviceClassSourceByModulePath[modulePath] == true
end

---Resolves a device class name for a spawn-list entry.
---Primary source is list metadata (`deviceClassName`), fallback is runtime cache by spawn path.
---@param entry table?
---@param modulePath string?
---@return string
function entity.resolveDeviceClassNameForEntry(entry, modulePath)
    if not entry or not entity.supportsDeviceClassSource(modulePath) then
        return ""
    end

    local listClassName = entity.sanitizeDeviceClassName(entry.data and entry.data.deviceClassName or nil)
    if listClassName ~= "" then
        return listClassName
    end

    local spawnPath = entry.data and entry.data.spawnData or nil
    if type(spawnPath) ~= "string" or spawnPath == "" then
        return ""
    end

    return entity.sanitizeDeviceClassName(cache.getValue(spawnPath .. "_deviceClassName"))
end

---Maps a device class name to the configured secondary icon glyph.
---@param className string?
---@return string
function entity.getDeviceSecondaryIcon(className)
    return deviceClassSecondaryIconByName[entity.sanitizeDeviceClassName(className)] or ""
end

---Resolves the secondary icon shown next to a spawn-list entry label.
---Empty for modules that carry no device class information.
---@param entry table?
---@param modulePath string?
---@return string
function entity.getEntrySecondaryIcon(entry, modulePath)
    return entity.getDeviceSecondaryIcon(entity.resolveDeviceClassNameForEntry(entry, modulePath))
end

---Refreshes instance secondary icon state and keeps the class-name cache in sync.
function entity:updateDeviceSecondaryIcon()
    self.secondaryIcon = entity.getDeviceSecondaryIcon(self.deviceClassName)

    local cacheKey = (self.spawnData and self.spawnData ~= "") and (self.spawnData .. "_deviceClassName") or nil
    if cacheKey then
        local currentClassName = entity.sanitizeDeviceClassName(self.deviceClassName)
        local cachedClassName = cache.getValue(cacheKey)

        if currentClassName ~= "" and cachedClassName ~= currentClassName then
            cache.addValue(cacheKey, currentClassName)
        elseif currentClassName == "" and cachedClassName ~= nil then
            cache.removeValue(cacheKey)
        end
    end

    if self.object then
        self.object.secondaryIcon = self.secondaryIcon
    end
end

---@protected
---@param forceRefresh boolean?
function entity:loadAppearanceData(forceRefresh)
    local requestedSpawnData = self.spawnData
    local cacheKey = requestedSpawnData .. "_apps"

    if forceRefresh then
        cache.removeValue(cacheKey)
    end

    self.apps = {}
    self.appsLoaded = false

    cache.tryGet(cacheKey)
    .notFound(function (task)
        builder.registerLoadResource(requestedSpawnData, function (resource)
            if requestedSpawnData ~= self.spawnData then
                task:taskCompleted()
                return
            end

            local apps = {}

            for _, appearance in ipairs(resource.appearances) do
                table.insert(apps, appearance.name.value)
            end

            cache.addValue(cacheKey, apps)
            task:taskCompleted()
        end)
    end)
    .found(function ()
        if requestedSpawnData ~= self.spawnData then
            return
        end

        local previousApp = self.app
        self.apps = cache.getValue(cacheKey) or {}
        self.appIndex = math.max(utils.indexValue(self.apps, self.app) - 1, 0)
        self.appsLoaded = true

        if utils.indexValue(self.apps, self.app) - 1 < 0 then
            self.app = self.apps[1] or "default"
        end

        if self.app ~= previousApp and self:isSpawned() then
            self.defaultComponentData = {}
            self:respawn()
            return
        end

        if self.spawning then
            self:spawn(true)
        end
    end)
end

function entity:reloadAppearances()
    if not self.spawnData or self.spawnData == "" then
        return
    end

    self:loadAppearanceData(true)
end

---Selects the next appearance in the loaded list, wrapping at the end.
---@return boolean changed
function entity:cycleAppearance()
    local appCount = #(self.apps or {})
    if appCount <= 1 then
        return false
    end

    local currentIndex = utils.indexValue(self.apps, self.app)
    if type(currentIndex) ~= "number" or currentIndex < 1 or currentIndex > appCount then
        currentIndex = 0
    end

    local nextIndex = (currentIndex % appCount) + 1
    local nextApp = self.apps[nextIndex]
    if not nextApp or nextApp == self.app then
        return false
    end

    if self.object then
        history.addAction(history.getElementChange(self.object))
    end

    self.app = nextApp
    self.appIndex = nextIndex - 1
    self.defaultComponentData = {}

    if self:getEntity() then
        self:respawn()
    end

    return true
end

function entity:loadSpawnData(data, position, rotation)
    spawnable.loadSpawnData(self, data, position, rotation)
    self.appSearch = self.appSearch or ""
    self.appSearch = utils.stripNonASCII(self.appSearch)
    self.deviceClassName = sanitizeDeviceClassName(self.deviceClassName)
    self:updateDeviceSecondaryIcon()
    self:loadAppearanceData(false)
end

function entity:spawn(ignoreSpawning)
    if not self.appsLoaded then -- Delay spawning until list of apps is loaded, so we dont spawn with random/default appearance
        self.spawning = true
    else
        spawnable.spawn(self, ignoreSpawning)
    end
end

local function CRUIDToString(id)
    return tostring(CRUIDToHash(id)):gsub("ULL", "")
end

local customNumericPropertyRanges = {
    colorGroupSaturation = { min = 0, max = 100, integer = true },
    _patterns = {
        {
            contains = "angle",
            min = -360,
            max = 360,
            exclude = { highBeamPitchAngle = true }
        }
    }
}

-- Explicit path allow-list for LocKey previews in Instance Data.
-- Add more entries as needed:
-- [ComponentType]["path/to/property"] = true
local locKeyPreviewTargets = {
    ElevatorFloorTerminalController = {
        ["persistentState/elevatorFloorSetup/floorDisplayName"] = true
    },
    ElevatorFloorTerminalControllerPS = {
        ["persistentState/elevatorFloorSetup/floorDisplayName"] = true
    }
}

local function normalizeInstanceDataPath(path)
    local normalized = {}

    for _, segment in ipairs(path or {}) do
        local key = tostring(segment)

        if key ~= "Data" and key ~= "$value" then
            table.insert(normalized, key)
        end
    end

    return normalized
end

---@param object positionable?
---@return string?
local function resolveElevatorFloorMarkerNodeRefFromSibling(object)
    if not object or not object.parent or not object.spawnable then
        return nil
    end

    if tostring(object.spawnable.deviceClassName or "") ~= "ElevatorFloorTerminalControllerPS" then
        return nil
    end

    for _, sibling in ipairs(object.parent.childs or {}) do
        if sibling ~= object
            and utils.isA(sibling, "spawnableElement")
            and sibling.spawnable
            and sibling.spawnable.modulePath == "meta/staticMarker" then
            local nodeRef = utils.trimString(sibling.spawnable.nodeRef)
            if nodeRef ~= "" then
                return nodeRef
            end
        end
    end

    return nil
end

local function clampCustomNumericProperty(key, value)
    if type(value) ~= "number" then
        return value
    end

    local keyName = tostring(key)
    local range = customNumericPropertyRanges[keyName]

    if not range then
        for _, pattern in ipairs(customNumericPropertyRanges._patterns or {}) do
            if
                pattern.contains
                and string.find(string.lower(keyName), string.lower(pattern.contains), 1, true)
                and not (pattern.exclude and pattern.exclude[keyName])
            then
                range = pattern
                break
            end
        end
    end

    if not range then
        return value
    end

    if range.wrap and range.wrap > 0 then
        local wrapped = value % range.wrap
        if range.integer then
            wrapped = math.floor(wrapped)
        end
        return wrapped
    end

    local clamped = math.min(range.max, math.max(range.min, value))
    if range.integer then
        clamped = math.floor(clamped)
    end

    return clamped
end

function entity:loadInstanceData(entity, forceLoadDefault)
    -- Only generate upon change
    if not forceLoadDefault then -- Called during assemble
        self.defaultComponentData = {}
        -- Always load default data for PS controllers, as these must be serialized during attachment, to prevent values being set from PS data
        for _, component in pairs(entity:GetComponents()) do
            if component:IsA("gameDeviceComponent") and component.persistentState then
                self.defaultComponentData[CRUIDToString(component.id)] = red.redDataToJSON(component)
                self.psControllerID = CRUIDToString(component.id)
            end
        end

        if utils.tableLength(self.instanceDataChanges) == 0 then
            return
        end
    end

    for key, _ in pairs(self.defaultComponentData) do
        if key ~= self.psControllerID then
            self.defaultComponentData[key] = nil
        end
    end

    -- Gotta go through all components, even such with identicaly IDs, due to AMM props using the same ID for all components
    local components = entity:GetComponents()
    self.defaultComponentData["0"] = red.redDataToJSON(entity)

    for _, component in pairs(components) do
        local ignore = false

        if component:IsA("entMeshComponent") or component:IsA("entSkinnedMeshComponent") then
            ignore = ResRef.FromHash(component.mesh.hash):ToString():match("base\\spawner") or ResRef.FromHash(component.mesh.hash):ToString():match("base\\amm_props\\mesh\\invis_")
        end
        ignore = ignore or CRUIDToString(component.id) == "0"

        if not ignore then
            if not component.name.value:match("amm_prop_slot") and not CRUIDToString(component.id) == self.psControllerID then
                self.defaultComponentData[CRUIDToString(component.id)] = red.redDataToJSON(component)
            elseif not self.defaultComponentData[CRUIDToString(component.id)] then
                self.defaultComponentData[CRUIDToString(component.id)] = red.redDataToJSON(component)
            end

            for key, data in pairs(utils.deepcopy(self.instanceDataChanges)) do
                if key == CRUIDToString(component.id) then
                    red.JSONToRedData(data, component)
                end
            end
        end
    end

    -- `defaultComponentData` is serialized, and `save` drops any `instanceDataChanges` entry that has
    -- no matching default -- so a node whose JSON was cached before the entity finished assembling
    -- holds this entity with its instance data stripped, and nothing else would ever invalidate it.
    --
    -- Which of the two marks depends on who asked. `forceLoadDefault` is the explicit path -- the
    -- instance data UI, a device PS lookup, an AMM import -- and those are user actions. The assemble
    -- path is the engine re-deriving what the file already described, so it is only derived state.
    if forceLoadDefault then
        saveState.markDirty(self.object)
    else
        saveState.markDerived(self.object)
    end
end

local function fixInstanceData(data, parent)
    for key, value in pairs(data) do
        if type(value) == "table" then
            if value["$type"] == "ResourcePath" and value["$storage"] and value["$storage"] == "uint64" then
                parent = nil
            elseif value["$type"] == "FixedPoint" and value["Bits"] then
                value["Bits"] = math.floor(value["Bits"])
            elseif value["Flags"] and not value["DepotPath"] and not value["$type"] then
                data[key] = nil
            elseif value["$type"] == "Color" then
                value.Red = math.min(value.Red, 255)
                value.Green = math.min(value.Green, 255)
                value.Blue = math.min(value.Blue, 255)
                value.Alpha = math.min(value.Alpha, 255)
            elseif key == "stealthRunnerQuest" then
                data[key] = nil
            end

            if data ~= nil then
                fixInstanceData(value, data)
            end
        elseif key == "betterNetrunningBreachedCameras" or key == "betterNetrunningBreachedNPCs" or key == "betterNetrunningBreachedBasic" or key == "betterNetrunningBreachedTurrets" then
            data[key] = nil
        elseif type(value) == "number" then
            data[key] = clampCustomNumericProperty(key, value)
        end
    end
end

function entity:applyComponentOverrides(entRef)
    if not entRef or not self.componentOverridesByName then return end

    for _, component in pairs(entRef:GetComponents()) do
        local name = component and component.name and component.name.value or nil
        if name and self.componentOverridesByName[name] then
            local override = utils.deepcopy(self.componentOverridesByName[name])
            pcall(function ()
                red.JSONToRedData(override, component)
            end)
        end
    end
end

---Adds/updates/hides the sphere marker that visualizes the entity origin.
---Subclasses opt in by toggling `showPositionMarker`, and pick their own `positionMarkerColor`.
function entity:updatePositionMarker()
    local entityRef = self:getEntity()
    if not entityRef then return end

    local marker = entityRef:FindComponentByName(POSITION_MARKER_COMPONENT)

    if self.showPositionMarker then
        if not marker then
            visualizer.addSphere(entityRef, POSITION_MARKER_SCALE, self.positionMarkerColor or POSITION_MARKER_DEFAULT_COLOR)
        else
            visualizer.updateScale(entityRef, POSITION_MARKER_SCALE, POSITION_MARKER_COMPONENT)
            marker:Toggle(true)
        end
    elseif marker then
        marker:Toggle(false)
    end
end

---@param state boolean
function entity:setPositionMarkerVisible(state)
    self.showPositionMarker = state
    self:updatePositionMarker()
end

function entity:onAssemble(entRef)
    spawnable.onAssemble(self, entRef)

    for _, component in pairs(self.instanceDataChanges) do
        fixInstanceData(component, {})
    end

    local loadOk, loadErr = pcall(function ()
        self:loadInstanceData(entRef, false)
    end)
    if not loadOk then
        logger:error(string.format("[entity] Failed to apply instance data for \"%s\": %s", self.spawnData or "unknown", tostring(loadErr)))
    end

    self:applyComponentOverrides(entRef)

    for _, component in pairs(entRef:GetComponents()) do
        if component:IsA("gameDeviceComponent") then
            if self.deviceClassName == "" and component.persistentState then
                self.deviceClassName = sanitizeDeviceClassName(component.persistentState:GetClassName().value)
            end
        end
    end

    -- Assembly is asynchronous and rewrites serialized state: `instanceDataChanges` (fixed up in
    -- place above), `defaultComponentData`, and `deviceClassName`. Marked here as well as inside
    -- `loadInstanceData`, which returns early when there is nothing to apply.
    --
    -- Derived, not edited: this lands frames after a group load has released change-tracking
    -- suppression, so marking it as an edit reported every freshly loaded project as unsaved as soon
    -- as its entities finished spawning. Real edits to this data are tracked by `updatePropValue`.
    saveState.markDerived(self.object)

    self:updateDeviceSecondaryIcon()

    self:assetPreviewAssemble(entRef)
end

function entity:onAttached(entRef)
    spawnable.onAttached(self, entRef)
    local spawnToken = self.getSpawnLifetimeToken and self:getSpawnLifetimeToken() or nil

    Cron.AfterTicks(10, function ()
        if spawnToken and (not self.isSpawnLifetimeTokenCurrent or not self:isSpawnLifetimeTokenCurrent(spawnToken, entRef)) then
            logger:info(string.format("[Entity] Skipped stale attach callback for %s", tostring(self.spawnData or "unknown")))
            return
        end

        local success = pcall(function ()
            entRef:GetTemplatePath()
        end)

        if not success then return end

        builder.getEntityBBox(entRef, function (data)
            if spawnToken and (not self.isSpawnLifetimeTokenCurrent or not self:isSpawnLifetimeTokenCurrent(spawnToken, entRef)) then
                logger:info(string.format("[Entity] Skipped stale BBOX callback for %s", tostring(self.spawnData or "unknown")))
                return
            end

            -- logger:info("[Entity] Loaded initial BBOX for entity " .. self.spawnData .. " with " .. #data.meshes .. " meshes.")
            self.bBox = data.bBox
            self.meshes = data.meshes

            visualizer.updateScale(entRef, self:getArrowSize(), "arrows")

            if self.bBoxCallback then
                self.bBoxCallback(entRef)
            end
            self.bBoxLoaded = true

            if self.isAssetPreview then
                self:assetPreviewSetPosition()
                self:setAssetPreviewTextPostition()
            end
        end)
    end, {})
end

---@param vertical number? 1 for the top left corner (default), -1 for the bottom left one
function entity:getAssetPreviewTextAnchor(vertical)
    if not self.assetPreviewBackplane then
        return Vector4.new(1, 1, 0, 0)
    end

    local pos = preview.getTopLeft(0.275)
    return utils.addVector(self.assetPreviewBackplane.position, utils.addEulerRelative(self.assetPreviewBackplane.rotation, EulerAngles.new(0, 90, 0)):ToQuat():Transform(Vector4.new(pos, 0, pos * (vertical or 1), 0)))
end

function entity:getAssetPreviewPosition()
    if self.assetPreviewBackplane and self.assetPreviewBackplane:isSpawned() then
        local meshPosition, _ = spawnable.getAssetPreviewPosition(self, 0.25)
        self.assetPreviewBackplane.position = meshPosition
        self.assetPreviewBackplane:update()
    end

    -- Not yet ready, leave off screen
    if not self.bBoxLoaded or not self:isSpawned() then
        return self.position, Vector4.new(0, 1, 0, 0)
    end

    local size = self:getSize()
    local distance = (math.max(size.x, size.y, size.z) * 1.6) / previewControls.zoom

    local diff = utils.subVector(self.position, self:getCenter())
    local position, forward = spawnable.getAssetPreviewPosition(self, distance)

    -- The cycle walks "default" plus every appearance, hence the +1
    local appCount = #self.apps + 1
    local targetIndex = self.appIndex

    self.assetPreviewTimer = self.assetPreviewTimer + Cron.deltaTime
    if previewControls.appearanceLocked then
        targetIndex = previewControls.getAppearanceIndex(self.assetPreviewAppIndex, appCount)
    elseif self.assetPreviewTimer > 1.5 then
        self.assetPreviewTimer = 0
        targetIndex = (self.appIndex + 1) % appCount
        self.assetPreviewAppIndex = targetIndex
    else
        self.assetPreviewAppIndex = self.appIndex
    end

    if targetIndex ~= self.appIndex then
        self.appIndex = targetIndex
        local new = self.apps[self.appIndex] or "default"
        if new ~= self.app then
            self.app = new
            self.bBoxLoaded = false
            self:respawn()
        end
    end

    previewControls.updateTurntable(self, 50)

    if size.z < math.max(size.x, size.y, size.z) * 0.1 then
        diff = utils.addVector(diff, self.rotation:ToQuat():Transform(Vector4.new(0, 0, -0.1, 0)))
    end

    local label = "Appearance"
    if #self.apps > 0 then
        label = ("Appearance (%d/%d)"):format(self.appIndex + 1, appCount)
    end
    preview.elements["previewFirstLine"]:SetText(label .. ": " .. self.app)
    preview.elements["previewSecondLine"]:SetText(("Size: X=%.2fm Y=%.2fm Z=%.2fm"):format(size.x, size.y, size.z))
    -- Appearances load asynchronously, so the hint is refreshed here rather than on assemble
    preview.setControlsHint(previewControls.getHintLines(appCount))
    position = utils.addVector(position, diff)

    return position, forward
end

function entity:assetPreviewAssemble(entRef)
    if not self.isAssetPreview then return end

    for _, component in pairs(entRef:GetComponents()) do
        if component:IsA("entMeshComponent") then
            component.renderingPlane = ERenderingPlane.RPl_Weapon
        end
        if component:IsA("entPhysicalMeshComponent") or component:IsA("entColliderComponent") then
            component.filterData = physicsFilterData.new()
        end
        if component:IsA("entISkinTargetComponent") or component:IsA("entPhysicalDestructionComponent") then
            component:Toggle(false)

            local mesh = entMeshComponent.new()
            mesh.name = component.name.value .. "_copy"
            mesh.id = component.id
            mesh.mesh = component.mesh
            mesh.meshAppearance = component.meshAppearance
            mesh.renderingPlane = ERenderingPlane.RPl_Weapon
            mesh:SetLocalTransform(component:GetLocalPosition(), component:GetLocalOrientation())
            mesh.parentTransform = component.parentTransform
            entRef:AddComponent(mesh)
        end
        if component:IsA("gameStaticAreaShapeComponent") or component:IsA("entDynamicActorRepellingComponent") then
            component:Toggle(false)
        end
        if component:IsA("entSimpleColliderComponent") then
            component:SetLocalPosition(Vector4.new(0, 0, -150, 0))
        end
    end

    preview.elements["previewFirstLine"]:SetVisible(true)
    preview.elements["previewSecondLine"]:SetVisible(true)
    preview.elements["previewThirdLine"]:SetVisible(true)
    preview.elements["previewFirstLine"]:SetText("Appearance: Loading...")
    preview.elements["previewSecondLine"]:SetText("Size: Loading...")
    preview.elements["previewThirdLine"]:SetText("Experimental preview")
end

function entity:assetPreview(state)
    if self.assetPreviewType == "none" then return end

    spawnable.assetPreview(self, state)

    if state then
        self.assetPreviewBackplane = require("modules/classes/spawn/mesh/mesh"):new()
        local rot = utils.addEulerRelative(self.rotation, EulerAngles.new(0, -90, 0))

        local size = preview.getBackplaneSize(0.275)
        local meshPosition, _ = spawnable.getAssetPreviewPosition(self, 0.25)
        self.assetPreviewBackplane:loadSpawnData({ spawnData = "base\\spawner\\base_grid.w2mesh", scale = { x = size, y = size, z = size } }, meshPosition, rot)
        self.assetPreviewBackplane:spawn()
    else
        if self.assetPreviewBackplane then
            self.assetPreviewBackplane:despawn()
            self.assetPreviewBackplane = nil
        end
    end

    self.spawnedAndCachedCallback = {}
end

function entity:save()
    local data = spawnable.save(self)
    data.instanceDataChanges = utils.deepcopy(self.instanceDataChanges)

    local default = {}
    for key, _ in pairs(self.instanceDataChanges) do
        local wrongData = false
        if key == "0" and self.defaultComponentData["0"] then
            for propKey, _ in pairs(self.instanceDataChanges["0"]) do
                if not self.defaultComponentData["0"][propKey] then
                    wrongData = true
                    break
                end
            end
        end

        if not wrongData then
            default[key] = utils.deepcopy(self.defaultComponentData[key])

            if not self.defaultComponentData[key] then
                data.instanceDataChanges[key] = nil
            end
        else
            logger:warn("Something went wrong with instance data for entity " .. self.object.name .. " had to reset some data...")
            data.instanceDataChanges[key] = nil
        end
    end
    data.defaultComponentData = default
    data.deviceClassName = self.deviceClassName
    data.componentOverridesByName = utils.deepcopy(self.componentOverridesByName)

    return data
end

---Gets called once the entity is spawned and the BBox is cached. Gets passed the entity as param
---@param callback any
function entity:onBBoxLoaded(callback)
    self.bBoxCallback = callback
end

---@param entity entity?
---@return table
function entity:getSize()
    return { x = self.bBox.max.x - self.bBox.min.x, y = self.bBox.max.y - self.bBox.min.y, z = self.bBox.max.z - self.bBox.min.z }
end

---Entities carry no scale, so the template dimensions are also the actual ones.
---@return table
function entity:getBaseSize()
    return self:getSize()
end

function entity:getBBox()
    return self.bBox
end

function entity:getCenter()
    local size = self:getSize()
    local offset = Vector4.new(
        self.bBox.min.x + size.x / 2,
        self.bBox.min.y + size.y / 2,
        self.bBox.min.z + size.z / 2,
        0
    )
    offset = self.rotation:ToQuat():Transform(offset)

    return Vector4.new(
        self.position.x + offset.x,
        self.position.y + offset.y,
        self.position.z + offset.z,
        0
    )
end

function entity:calculateIntersection(origin, ray)
    if not self:getEntity() then
        return { hit = false }
    end

    local hit = nil
    local unscaledHit = nil

    for _, mesh in pairs(self.meshes) do
        local meshPosition = utils.addVector(mesh.position, self.position)
        local meshRotation = utils.multQuat(self.rotation:ToQuat(), mesh.rotation)

        local result = intersection.getBoxIntersection(origin, ray, meshPosition, meshRotation:ToEulerAngles(), mesh.bbox)

        if result.hit then
            if not hit or result.distance < hit.distance then
                hit = result

                unscaledHit = intersection.getBoxIntersection(origin, ray, meshPosition, meshRotation:ToEulerAngles(), intersection.unscaleBBox(mesh.path, mesh.originalScale, mesh.bbox))
            end
        end
    end

    if not hit then return { hit = false } end

    return {
        hit = hit.hit,
        position = hit.position,
        unscaledHit = unscaledHit and unscaledHit.position or hit.position,
        collisionType = "bbox",
        distance = hit.distance,
        bBox = self.bBox,
        objectOrigin = self.position,
        objectRotation = self.rotation,
        normal = hit.normal
    }
end

local function multiplyVectorLikeValue(data, multiplier)
    if type(data) ~= "table" then
        return false
    end

    local changed = false

    if type(data.X) == "number" then
        data.X = data.X * multiplier
        changed = true
    end
    if type(data.Y) == "number" then
        data.Y = data.Y * multiplier
        changed = true
    end
    if type(data.Z) == "number" then
        data.Z = data.Z * multiplier
        changed = true
    end

    if type(data.x) == "number" then
        data.x = data.x * multiplier
        changed = true
    end
    if type(data.y) == "number" then
        data.y = data.y * multiplier
        changed = true
    end
    if type(data.z) == "number" then
        data.z = data.z * multiplier
        changed = true
    end

    if type(data.x) == "table" and type(data.x.Bits) == "number" then
        data.x.Bits = math.floor(data.x.Bits * multiplier)
        changed = true
    end
    if type(data.y) == "table" and type(data.y.Bits) == "number" then
        data.y.Bits = math.floor(data.y.Bits * multiplier)
        changed = true
    end
    if type(data.z) == "table" and type(data.z.Bits) == "number" then
        data.z.Bits = math.floor(data.z.Bits * multiplier)
        changed = true
    end

    return changed
end

local function scaleComponentTransforms(data, multiplier)
    if type(data) ~= "table" then
        return false
    end

    local changed = false

    for key, value in pairs(data) do
        if type(value) == "table" then
            if key == "localTransform" then
                if type(value.Position) == "table" then
                    changed = multiplyVectorLikeValue(value.Position, multiplier) or changed
                end
                if type(value.position) == "table" then
                    changed = multiplyVectorLikeValue(value.position, multiplier) or changed
                end
                if type(value.Scale) == "table" then
                    changed = multiplyVectorLikeValue(value.Scale, multiplier) or changed
                end
                if type(value.scale) == "table" then
                    changed = multiplyVectorLikeValue(value.scale, multiplier) or changed
                end
            elseif key == "visualScale" or key == "scale" then
                changed = multiplyVectorLikeValue(value, multiplier) or changed
            else
                changed = scaleComponentTransforms(value, multiplier) or changed
            end
        end
    end

    return changed
end

local function getNumericVectorField(data, lower, upper)
    if type(data) ~= "table" and type(data) ~= "userdata" then
        return nil
    end

    local value = nil
    pcall(function ()
        value = data[lower]
    end)
    if type(value) == "number" then
        return value
    end
    if type(value) == "table" and type(value.Bits) == "number" then
        return value.Bits / 131072
    end

    pcall(function ()
        value = data[upper]
    end)
    if type(value) == "number" then
        return value
    end
    if type(value) == "table" and type(value.Bits) == "number" then
        return value.Bits / 131072
    end

    return nil
end

local function readVectorLikeValue(data)
    if type(data) ~= "table" and type(data) ~= "userdata" then
        return nil
    end

    local x = getNumericVectorField(data, "x", "X")
    local y = getNumericVectorField(data, "y", "Y")
    local z = getNumericVectorField(data, "z", "Z")

    if x ~= nil or y ~= nil or z ~= nil then
        return {
            x = x or 0,
            y = y or 0,
            z = z or 0
        }
    end

    local vector4 = nil
    pcall(function ()
        if type(data.ToVector4) == "function" then
            vector4 = data:ToVector4()
        end
    end)
    if vector4 then
        return readVectorLikeValue(vector4)
    end

    return nil
end

local function writeVectorLikeValue(data, value)
    if type(data) ~= "table" or type(value) ~= "table" then
        return false
    end

    if type(data.X) == "number" or type(data.Y) == "number" or type(data.Z) == "number" then
        data.X = value.x
        data.Y = value.y
        data.Z = value.z
        return true
    end

    if type(data.x) == "number" or type(data.y) == "number" or type(data.z) == "number" then
        data.x = value.x
        data.y = value.y
        data.z = value.z
        return true
    end

    if
        (type(data.x) == "table" and type(data.x.Bits) == "number")
        or (type(data.y) == "table" and type(data.y.Bits) == "number")
        or (type(data.z) == "table" and type(data.z.Bits) == "number")
    then
        if type(data.x) ~= "table" then data.x = { ["$type"] = "FixedPoint", Bits = 0 } end
        if type(data.y) ~= "table" then data.y = { ["$type"] = "FixedPoint", Bits = 0 } end
        if type(data.z) ~= "table" then data.z = { ["$type"] = "FixedPoint", Bits = 0 } end
        data.x.Bits = math.floor(value.x * 131072)
        data.y.Bits = math.floor(value.y * 131072)
        data.z.Bits = math.floor(value.z * 131072)
        return true
    end

    data.X = value.x
    data.Y = value.y
    data.Z = value.z
    return true
end

local function getLocalPositionTable(componentData)
    if type(componentData) ~= "table" then
        return nil
    end
    if type(componentData.localTransform) ~= "table" then
        return nil
    end
    if type(componentData.localTransform.Position) == "table" then
        return componentData.localTransform.Position
    end
    if type(componentData.localTransform.position) == "table" then
        return componentData.localTransform.position
    end
    return nil
end

local function ensureLocalPositionTable(componentData, defaultData)
    if type(componentData) ~= "table" then
        return nil
    end

    local positionData = getLocalPositionTable(componentData)
    if positionData then
        return positionData
    end

    if type(componentData.localTransform) ~= "table" then
        if type(defaultData) == "table" and type(defaultData.localTransform) == "table" then
            componentData.localTransform = utils.deepcopy(defaultData.localTransform)
        else
            componentData.localTransform = {}
        end
    end

    positionData = getLocalPositionTable(componentData)
    if positionData then
        return positionData
    end

    local defaultLocalTransform = type(defaultData) == "table" and defaultData.localTransform or nil
    if type(defaultLocalTransform) == "table" then
        if type(defaultLocalTransform.Position) == "table" then
            componentData.localTransform.Position = utils.deepcopy(defaultLocalTransform.Position)
            return componentData.localTransform.Position
        end
        if type(defaultLocalTransform.position) == "table" then
            componentData.localTransform.position = utils.deepcopy(defaultLocalTransform.position)
            return componentData.localTransform.position
        end
    end

    componentData.localTransform.Position = { X = 0, Y = 0, Z = 0, W = 0 }
    return componentData.localTransform.Position
end

local function ensureCNameValue(data, key, value)
    if type(data[key]) ~= "table" then
        data[key] = {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = value
        }
    else
        data[key]["$type"] = "CName"
        data[key]["$storage"] = "string"
        data[key]["$value"] = value
    end
end

local function disableParentBinding(componentData, defaultData)
    if type(componentData) ~= "table" then
        return false
    end

    local hasParentBinding = type(componentData.parentTransform) == "table"
        or (type(defaultData) == "table" and type(defaultData.parentTransform) == "table")
    if not hasParentBinding then
        return false
    end

    if type(componentData.parentTransform) ~= "table" then
        if type(defaultData) == "table" and type(defaultData.parentTransform) == "table" then
            componentData.parentTransform = utils.deepcopy(defaultData.parentTransform)
        else
            componentData.parentTransform = {
                HandleId = "0",
                Data = {
                    ["$type"] = "entHardTransformBinding"
                }
            }
        end
    end

    local parentTransform = componentData.parentTransform
    parentTransform.HandleId = parentTransform.HandleId or "0"

    if type(parentTransform.Data) ~= "table" then
        parentTransform.Data = {
            ["$type"] = "entHardTransformBinding"
        }
    end

    parentTransform.Data["$type"] = parentTransform.Data["$type"] or "entHardTransformBinding"
    parentTransform.Data.enabled = 0
    ensureCNameValue(parentTransform.Data, "bindName", "None")
    ensureCNameValue(parentTransform.Data, "slotName", "None")

    return true
end

function entity:canDrawRescaleEntityAction()
    return self.node == "worldEntityNode" or self.node == "worldDeviceNode"
end

function entity:rescaleEntity(multiplier)
    if type(multiplier) ~= "number" or multiplier <= 0 then
        return 0
    end
    if math.abs(multiplier - 1) < 0.000001 then
        return 0
    end

    local defaultCount = utils.tableLength(self.defaultComponentData)
    if defaultCount <= 1 then
        local entityRef = self:getEntity()

        if entityRef and (defaultCount == 0 or (defaultCount == 1 and self.defaultComponentData[self.psControllerID] ~= nil)) then
            self:loadInstanceData(entityRef, true)
        end
    end

    local entityRef = self:getEntity()
    if not entityRef then
        return 0
    end

    if utils.tableLength(self.defaultComponentData) == 0 then
        return 0
    end

    local overridesByName = {}
    local nScaled = 0

    for _, component in pairs(entityRef:GetComponents()) do
        local componentName = component and component.name and component.name.value or nil
        local componentID = CRUIDToString(component.id)
        if componentName and componentID ~= "0" then

            local defaultData = self.defaultComponentData[componentID]
            if type(defaultData) ~= "table" then
                defaultData = red.redDataToJSON(component)
                if type(defaultData) == "table" then
                    self.defaultComponentData[componentID] = utils.deepcopy(defaultData)
                end
            end

            if type(defaultData) == "table" then
                local currentData = utils.deepcopy(defaultData)
                local changes = self.instanceDataChanges[componentID]

                if type(changes) == "table" then
                    for propKey, propValue in pairs(changes) do
                        currentData[propKey] = utils.deepcopy(propValue)
                    end
                end

                local didScale = scaleComponentTransforms(currentData, multiplier)
                local didBake = false

                local bakeOk = pcall(function ()
                    local localToWorld = component:GetLocalToWorld()
                    local worldPosition = localToWorld:GetTranslation()
                    local entityPosition = entityRef:GetWorldPosition()
                    local entityOrientation = entityRef:GetWorldOrientation()
                    local worldDiff = utils.subVector(worldPosition, entityPosition)
                    local inverseEntityOrientation = Quaternion.MulInverse(EulerAngles.new(0, 0, 0):ToQuat(), entityOrientation)
                    local entitySpacePosition = inverseEntityOrientation:Transform(worldDiff)
                    local scaledPosition = utils.multVector(entitySpacePosition, multiplier)

                    local positionData = ensureLocalPositionTable(currentData, defaultData)
                    if positionData then
                        didBake = writeVectorLikeValue(positionData, {
                            x = scaledPosition.x,
                            y = scaledPosition.y,
                            z = scaledPosition.z
                        }) or didBake
                    end
                end)
                if not bakeOk then
                    didBake = false
                end

                local didDetach = false
                if bakeOk then
                    didDetach = disableParentBinding(currentData, defaultData)
                end

                if didScale or didBake or didDetach then
                    local diff = {}

                    for propKey, propValue in pairs(currentData) do
                        local defaultValue = defaultData[propKey]
                        if defaultValue == nil or not utils.deepcompare(propValue, defaultValue, false) then
                            diff[propKey] = propValue
                        end
                    end

                    if utils.tableLength(diff) > 0 then
                        self.instanceDataChanges[componentID] = diff
                        nScaled = nScaled + 1
                    else
                        self.instanceDataChanges[componentID] = nil
                    end

                    local override = {}
                    if type(currentData.localTransform) == "table" then
                        override.localTransform = utils.deepcopy(currentData.localTransform)
                    end
                    if type(currentData.parentTransform) == "table" then
                        override.parentTransform = utils.deepcopy(currentData.parentTransform)
                    end
                    if type(currentData.visualScale) == "table" then
                        override.visualScale = utils.deepcopy(currentData.visualScale)
                    end
                    if type(currentData.scale) == "table" then
                        override.scale = utils.deepcopy(currentData.scale)
                    end

                    if utils.tableLength(override) > 0 then
                        overridesByName[componentName] = override
                    end
                end
            end
        end
    end

    self.componentOverridesByName = overridesByName

    if nScaled > 0 then
        self:respawn()
    end

    return nScaled
end

function entity:drawRescaleEntityAction()
    if not self:canDrawRescaleEntityAction() then return end

    self.rescaleEntityMultiplier = tonumber(self.rescaleEntityMultiplier) or 1
    if self.rescaleEntityMultiplier ~= self.rescaleEntityMultiplier then
        self.rescaleEntityMultiplier = 1
    end
    self.rescaleEntityMultiplier = math.max(0.001, self.rescaleEntityMultiplier)

    ImGui.BeginGroup()
    style.mutedText("Rescale Entity")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.deviceClassName == "" and self.propertiesWidth.app or self.propertiesWidth.class)
    ImGui.SetNextItemWidth(90 * style.viewSize)
    self.rescaleEntityMultiplier = ImGui.InputFloat("##rescaleEntityMultiplier", self.rescaleEntityMultiplier, 0, 0, "x%.3f")
    self.rescaleEntityMultiplier = tonumber(self.rescaleEntityMultiplier) or 1
    if self.rescaleEntityMultiplier ~= self.rescaleEntityMultiplier then
        self.rescaleEntityMultiplier = 1
    end
    self.rescaleEntityMultiplier = math.max(0.001, self.rescaleEntityMultiplier)

    ImGui.SameLine()
    local canApply = self:isSpawned() and math.abs(self.rescaleEntityMultiplier - 1) > 0.000001
    style.pushGreyedOut(not canApply)
    if ImGui.Button("Apply##rescaleEntity") then
        history.addAction(history.getElementChange(self.object))

        local nScaled = self:rescaleEntity(self.rescaleEntityMultiplier)
        if nScaled > 0 then
            ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Rescaled %s components", nScaled)))
        else
            ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Warning, 2500, "No scalable component transforms found"))
        end
    end
    style.popGreyedOut(not canApply)
    ImGui.EndGroup()
    style.tooltip("Multiplier applied to local component position and scale values.\n" .. IconGlyphs.AlertOutline .. " EXPERIMENTAL: May cause issues for components without localTransform or visualScale properties.")
end

function entity:drawEntityBaseProperties()
    spawnable.draw(self)

    if not self.propertiesWidth then
        local app, _ = ImGui.CalcTextSize("Appearance")
        local class, _ = ImGui.CalcTextSize("Device Class Name")
        local padding = ImGui.GetCursorPosX() + 2 * ImGui.GetStyle().ItemSpacing.x

        self.propertiesWidth = {
            app = app + padding,
            class = class + padding
        }
    end

    local greyOut = #self.apps <= 1
    style.pushGreyedOut(greyOut)

    local list = self.apps

    if #self.apps == 0 then
        list = {"No apps"}
    end

    style.mutedText("Appearance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.deviceClassName == "" and self.propertiesWidth.app or self.propertiesWidth.class)
    self.appSearch = self.appSearch or ""
    local selectedApp = self.app
    if selectedApp == nil or selectedApp == "" then
        selectedApp = list[1] or "default"
    end

    local changed
    selectedApp, self.appSearch, changed = style.trackedSearchDropdown(
        "##app",
        "Search appearance...",
        selectedApp,
        self.appSearch,
        list,
        {
            element = self.object,
            width = 160,
            matchContentWidth = true
        }
    )
    if changed and #self.apps > 0 then
        self.app = selectedApp
        self.appIndex = math.max(utils.indexValue(self.apps, self.app) - 1, 0)

        local entity = self:getEntity()

        self.defaultComponentData = {}

        if entity then
            self:respawn()
        end
    end
    ImGui.SameLine()
    ImGui.BeginDisabled(greyOut)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.SkipNext .. "##cycleEntityAppearance") then
        self:cycleAppearance()
    end
    style.pushButtonNoBG(false)
    ImGui.EndDisabled()
    style.tooltip("Select the next entity appearance. Wraps to the first appearance at the end of the list.")
    style.popGreyedOut(greyOut)
    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload .. "##reloadEntityAppearanceList") then
        self:reloadAppearances()
    end
    style.tooltip("Reload appearance list for this asset and refresh cached data.")
    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.ContentCopy .. "##copyEntityAppearance") then
        ImGui.SetClipboardText(self.app)
    end
    style.tooltip("Copy selected appearance")
    style.pushButtonNoBG(false)


    if self.deviceClassName ~= "" then
        style.mutedText("Device Class Name")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.propertiesWidth.class)
        ImGui.Text(self.deviceClassName)
        ImGui.SameLine()

        ImGui.PushID("##copyDeviceClassName")
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.ContentCopy) then
            ImGui.SetClipboardText(self.deviceClassName)
        end
        style.pushButtonNoBG(false)
        ImGui.PopID()
    end
end

function entity:draw()
    self:drawEntityBaseProperties()
    self:drawRescaleEntityAction()
end

function entity:getProperties()
    local properties = spawnable.getProperties(self)
    table.insert(properties, {
        id = self.node,
        name = self.dataType,
        defaultHeader = true,
        draw = function()
            self:draw()
        end
    })
    table.insert(properties, {
        id = self.node .. "instanceData",
        name = "Entity Instance Data",
        defaultHeader = false,
        drawHeader = function()
            self:drawInstanceDataCounter()
        end,
        draw = function()
            self:drawInstanceData()
        end
    })
    return properties
end

function entity:getGroupedProperties()
    local properties = spawnable.getGroupedProperties(self)

    properties["groupedAppearances"] = appearanceHelper.getGroupedProperties(self)

    return properties
end

function entity:prepareInstanceData(data)
    for key, value in pairs(data) do
        if key == "HandleId" then
            data[key] = nil
        end
        if type(value) == "table" then
            self:prepareInstanceData(value)
        end
    end
end

local function assembleInstanceData(default, instanceData)
    instanceData.id = default.id
    instanceData["$type"] = default["$type"]
end

function entity:export(index, length)
    local data = spawnable.export(self)

    if utils.tableLength(self.instanceDataChanges) > 0 then
        local dict = {}

        local i = 0
        if self.instanceDataChanges["0"] then -- Make sure "0" is always first
            dict[tostring(i)] = "0"
            i = i + 1
        end

        for key, _ in pairs(self.instanceDataChanges) do
            if key ~= "0" then
                dict[tostring(i)] = key
                i = i + 1
            end
        end

        local combinedData = {}

        for key, data in pairs(self.defaultComponentData) do
            if self.instanceDataChanges[key] then
                local assembled = utils.deepcopy(self.instanceDataChanges[key])
                assembleInstanceData(data, assembled)
                table.insert(combinedData, assembled)
            end
        end

        self:prepareInstanceData(combinedData)

        data.data.instanceData = {
            ["Data"] = {
                ["$type"] = "entEntityInstanceData",
                ["buffer"] = {
                    ["BufferId"] = utils.nextExportBufferId("EntityBuffer"),
                    ["Type"] = "WolvenKit.RED4.Archive.Buffer.RedPackage, WolvenKit.RED4",
                    ["Data"] = {
                        ["Version"] = 4,
                        ["Sections"] = 6,
                        ["CruidIndex"] = self.instanceDataChanges["0"] and 0 or -1,
                        ["CruidDict"] = dict,
                        ["Chunks"] = combinedData
                    }
                }
            }
        }
    end

    return data
end

-- Instance Data (Mess)

function entity:getSortedKeys(tbl)
    local keys = {}
    local max = 0

    for key, _ in pairs(tbl) do
        max = math.max(max, ImGui.CalcTextSize(tostring(key)))
        table.insert(keys, key)
    end

    table.sort(keys, function (a, b)
        return string.lower(tostring(a)) < string.lower(tostring(b))
    end)

    return keys, max
end

---Hell (Attempt to get the type of the data at the specified path)
---@param componentID number
---@param path table
---@param key string
---@return table { typeName: string, isEnum: boolean, propType: CName }
function entity:getPropTypeInfo(componentID, path, key)
    local function inferTypeInfo(value)
        local valueType = type(value)

        if valueType == "table" then
            if type(value["$type"]) == "string" then
                return { typeName = value["$type"], isEnum = false, propType = nil }
            end

            return { typeName = "table", isEnum = false, propType = nil }
        elseif valueType == "number" then
            if value == math.floor(value) then
                return { typeName = "Int32", isEnum = false, propType = nil }
            end

            return { typeName = "Float", isEnum = false, propType = nil }
        elseif valueType == "boolean" then
            return { typeName = "Bool", isEnum = false, propType = nil }
        elseif valueType == "string" then
            return { typeName = "String", isEnum = false, propType = nil }
        elseif valueType == "nil" then
            return { typeName = "Unknown", isEnum = false, propType = nil }
        end

        return { typeName = valueType, isEnum = false, propType = nil }
    end

    local function getNested(source, nestedPath)
        if type(source) ~= "table" then
            return nil
        end

        return utils.getNestedValue(source, nestedPath)
    end

    local defaultComponent = self.defaultComponentData[componentID]
    local changedComponent = self.instanceDataChanges[componentID]

    -- Step one up, so we can get class of parent, then use that to get property type
    local parentPath = utils.deepcopy(path)
    table.remove(parentPath, #parentPath)

    local value = getNested(defaultComponent, parentPath)
    if value == nil then -- Might be a custom array entry, only present in instanceDataChanges
        value = getNested(changedComponent, parentPath)
    end

    if type(value) ~= "table" then
        return inferTypeInfo(value)
    end

    -- Handle or array entry
    if not value["$type"] then
        if value["HandleId"] then
            -- Step one further up, to get the class of the parent of the handle (Could also step down and retrieve type there)
            table.remove(parentPath, #parentPath)
        end
        if type(key) == "number" then -- Is array entry
            if value["HandleId"] then
                -- Type of handle, by stepping down
                if type(value["Data"]) == "table" then
                    return inferTypeInfo(value["Data"])
                end

                return inferTypeInfo(value["Data"])
            else
                -- If its not a handle, parentPath will be prop which exists on default data (value ~= nil), but the actual array entry does only exist in instanceDataChanges
                if not value[key] then
                    value = getNested(changedComponent, parentPath)
                end

                local entryValue = type(value) == "table" and value[key] or nil
                local typeName = type(entryValue) == "table" and entryValue["$type"] or nil
                local isEnum = false

                if not typeName then -- Is simple type
                    local parentParent = utils.deepcopy(parentPath) -- Grab parent of array, to get type of array
                    table.remove(parentParent, #parentParent)

                    local fullPath = table.concat(path, "/")
                    if not self.typeInfo[fullPath] then
                        local parentData = getNested(changedComponent, parentParent)
                        if parentData == nil then
                            parentData = getNested(defaultComponent, parentParent)
                        end

                        local parentType = type(parentData) == "table" and parentData["$type"] or nil
                        local reflectedClass = type(parentType) == "string" and Reflection.GetClass(parentType) or nil
                        local reflectedProp = reflectedClass and parentPath[#parentPath] and reflectedClass:GetProperty(tostring(parentPath[#parentPath])) or nil
                        local reflectedType = reflectedProp and reflectedProp:GetType() or nil
                        local innerType = reflectedType and reflectedType:GetInnerType() or nil

                        if innerType then
                            isEnum = innerType:IsEnum()
                            typeName = innerType:GetName().value
                            self.typeInfo[fullPath] = { typeName = typeName, isEnum = isEnum, propType = nil }
                        else
                            self.typeInfo[fullPath] = inferTypeInfo(entryValue)
                        end
                    else
                        return self.typeInfo[fullPath]
                    end
                end

                return { typeName = typeName, isEnum = isEnum, propType = nil}
            end
        end
    end

    value = getNested(defaultComponent, parentPath) -- Re-Fetch, in case it was a handle and we changed the path
    if value == nil then -- Array entry, only present in instanceDataChanges
        value = getNested(changedComponent, parentPath)
    end

    if type(value) ~= "table" then
        return inferTypeInfo(value)
    end

    local fullPath = table.concat(path, "/")
    if not self.typeInfo[fullPath] then
        local className = value["$type"]
        local reflectedClass = type(className) == "string" and Reflection.GetClass(className) or nil
        local reflectedProp = reflectedClass and reflectedClass:GetProperty(tostring(key)) or nil
        local propType = reflectedProp and reflectedProp:GetType() or nil

        if propType then
            local propEnum = propType:IsEnum()
            local propTypeName = propType:GetName().value
            self.typeInfo[fullPath] = { typeName = propTypeName, isEnum = propEnum, propType = propType }
        else
            self.typeInfo[fullPath] = inferTypeInfo(value[key])
        end
    end

    return self.typeInfo[fullPath]
end

function entity:updatePropValue(componentID, path, value)
    if not self.instanceDataChanges[componentID] then
        self.instanceDataChanges[componentID] = {}
    end
    if not self.instanceDataChanges[componentID][path[1]] then
        self.instanceDataChanges[componentID][path[1]] = utils.deepcopy(self.defaultComponentData[componentID][path[1]])
    end

    utils.setNestedValue(self.instanceDataChanges[componentID], path, value)
    if utils.deepcompare(self.defaultComponentData[componentID][path[1]], self.instanceDataChanges[componentID][path[1]], false) then
        self.instanceDataChanges[componentID][path[1]] = nil
        if utils.tableLength(self.instanceDataChanges[componentID]) == 0 then
            self.instanceDataChanges[componentID] = nil
        end
    end

    -- Every instance data edit funnels through here, which is why the mark belongs here rather than
    -- at the call sites: most of them push a history action (which marks for them), but the array
    -- entry, colour and light channel paths do not, and the respawn below no longer marks either --
    -- assembly only reports derived state now.
    saveState.markDirty(self.object)

    self:respawn()
end

---@private
---@param componentID number
---@param path table
---@return boolean
function entity:shouldPreviewLocKey(componentID, path)
    local component = self.defaultComponentData[componentID]
    if not component then
        return false
    end

    local componentType = component["$type"]
    if type(componentType) ~= "string" then
        return false
    end

    local pathTargets = locKeyPreviewTargets[componentType]
    local normalizedPath = table.concat(normalizeInstanceDataPath(path), "/")

    -- Generic rule: any *Controller* component supports persistentState/deviceName LocKeys.
    if normalizedPath == "persistentState/deviceName" then
        return string.find(string.lower(componentType), "controller", 1, true) ~= nil
    end

    if not pathTargets then
        return false
    end

    return pathTargets[normalizedPath] == true
end

---@private
---@param value any
---@return string?
function entity:resolveLocKey(value)
    return gameUtils.resolveLocKey(value, self.locKeyPreviewCache)
end

---@private
---@param componentID number
---@param path table
---@param value any
function entity:drawLocKeyPreview(componentID, path, value, cursorPos)
    if not self:shouldPreviewLocKey(componentID, path) then
        return
    end

    self:drawLocalizationStringPreview(value, cursorPos)
end

---@private
---@param value any
---@param cursorPos number?
function entity:drawLocalizationStringPreview(value, cursorPos)
    local localized = self:resolveLocKey(value)
    if not localized then
        return
    end

    if cursorPos ~= nil then
        ImGui.SetCursorPosX(cursorPos)
    end

    local localizedLabel = style.resolveActionLabelNoIconOnly(IconGlyphs.Translate, localized, nil)
    style.mutedText(localizedLabel)
    style.tooltip(localized)
end

---Draws one read only value cell of the record details section.
---@param text string Displayed text
---@param tooltip string Tooltip text
---@param copyValue string Value copied on middle click
local function drawRecordValue(text, tooltip, copyValue)
    ImGui.Text(text)
    style.tooltip(tooltip)

    if ImGui.IsItemHovered() and ImGui.IsItemClicked(ImGuiMouseButton.Middle) then
        ImGui.SetClipboardText(copyValue)
    end
end

---Draws a read only, foldable view of the live TweakDB record a TweakDBID property points at.
---Nothing is drawn when the value does not resolve to a record.
---@private
---@param componentID number
---@param path table
---@param recordID any Current TweakDBID value
function entity:drawRecordDetails(componentID, path, recordID)
    local info = tweakDb.resolveRecord(recordID)
    if not info then return end

    local id = "##recordDetails" .. componentID .. table.concat(path)

    ImGui.SetCursorPosX(ImGui.GetCursorPosX() + ImGui.GetStyle().IndentSpacing)
    local open = ImGui.TreeNodeEx(IconGlyphs.Database .. " Record Details | " .. info.className .. id, ImGuiTreeNodeFlags.SpanFullWidth)
    style.tooltip(info.id .. "\n" .. info.className .. "\n\nLive TweakDB data, read only.\nMiddle click a value to copy it.")

    if not open then return end

    local flats = tweakDb.getRecordFlats(recordID)

    if not flats or #flats == 0 then
        style.mutedText("No data found for this record")
    else
        local labels = {}
        for _, flat in ipairs(flats) do
            table.insert(labels, flat.name)
        end

        local valuePos = ImGui.GetCursorPosX() + utils.getTextMaxWidth(labels) + 2 * ImGui.GetStyle().ItemSpacing.x

        for _, flat in ipairs(flats) do
            local tooltip = flat.raw
            if flat.localized then
                tooltip = tooltip .. "\n" .. IconGlyphs.Translate .. " " .. flat.localized
            end

            style.mutedText(flat.name)
            ImGui.SameLine()
            ImGui.SetCursorPosX(valuePos)
            drawRecordValue(flat.text, tooltip, flat.raw)

            -- Array entries get one row each, so long entries stay readable
            for _, item in ipairs(flat.items or {}) do
                ImGui.SetCursorPosX(valuePos)
                drawRecordValue(item, item, item)
            end
        end
    end

    ImGui.TreePop()
end

function entity:drawStringProp(componentID, key, data, path, type, width, max)
    key = tostring(key)

    ImGui.Text(key)
    ImGui.SameLine()
    ImGui.SetCursorPosX(ImGui.GetCursorPosX() - ImGui.CalcTextSize(key) + max)
    ImGui.SetNextItemWidth(width * style.viewSize)
    local value, _ = style.inputText("##" .. componentID .. table.concat(path), data, 250)
    style.tooltip(type)
    self:drawResetProp(componentID, path)
    if ImGui.IsItemDeactivatedAfterEdit() then
        history.addAction(history.getElementChange(self.object))
        self:updatePropValue(componentID, path, value)
    end

    return value
end

---@param componentID number
---@param path table
---@param typeName table?
function entity:drawResetProp(componentID, path, typeName)
    local modified = self.instanceDataChanges[componentID] ~= nil and utils.getNestedValue(self.instanceDataChanges[componentID], path) ~= nil

    if ImGui.BeginPopupContextItem("##resetComponentProperty" .. componentID .. table.concat(path), ImGuiPopupFlags.MouseButtonRight) then
        if typeName and typeName == "handle:AreaShapeOutline" then
            -- Do this here, before we trim the path
            local outline = utils.getClipboardValue("outline")
            if ImGui.MenuItem("Paste outline" .. (outline and " [" .. #outline.points .. "]" or " [Empty]")) and outline then
                history.addAction(history.getElementChange(self.object))
                self:updatePropValue(componentID, path, {
                    ["$type"] = "AreaShapeOutline",
                    ["height"] = outline.height,
                    ["points"] = outline.points
                })
            end
        end

        local isArray = type(path[#path]) == "number"

        -- Might be array of handles, so check one path index up (.../->index<-/Data)
        if not isArray and #path > 1 then
            isArray = type(path[#path - 1]) == "number"
            path = utils.deepcopy(path)
            table.remove(path, #path)
        end
        local text = isArray and (IconGlyphs.DeleteOutline .. " Remove") or (IconGlyphs.Restore .. " Reset")

        if ImGui.MenuItem(text) and modified then
            history.addAction(history.getElementChange(self.object))
            if not isArray then
                self:updatePropValue(componentID, path, utils.deepcopy(utils.getNestedValue(self.defaultComponentData[componentID], path)))
            else
                self:updatePropValue(componentID, path, nil)
            end
        end

        ImGui.EndPopup()
    end
end

function entity:drawResetComponent(id)
    if ImGui.BeginPopupContextItem("##resetComponent" .. id, ImGuiPopupFlags.MouseButtonRight) then
        if ImGui.MenuItem(IconGlyphs.Restore .. " Reset") and self.instanceDataChanges[id] then
            history.addAction(history.getElementChange(self.object))
            self.instanceDataChanges[id] = nil
            self:respawn()
        end
        ImGui.EndPopup()
    end
end

function entity:drawAddArrayEntry(prop, componentID, path, data)
    if prop and prop:IsArray() then
        ImGui.Button("+")
        if ImGui.BeginPopupContextItem("##" .. componentID .. table.concat(path), ImGuiPopupFlags.MouseButtonLeft) then
            local base = prop:GetInnerType()
            local isHandle = base:GetMetaType() == ERTTIType.Handle
            if isHandle then base = base:GetInnerType() end

            if base:GetMetaType() ~= ERTTIType.Class then
                if base:GetName().value == "Bool" then
                    if ImGui.MenuItem("Bool") then
                        local newPath = utils.deepcopy(path)
                        table.insert(newPath, #data + 1)

                        self:updatePropValue(componentID, newPath, 1)
                    end
                elseif base:GetName().value == "TweakDBID" then
                    if ImGui.MenuItem("TweakDBID (String)") then
                        local newPath = utils.deepcopy(path)
                        table.insert(newPath, #data + 1)

                        self:updatePropValue(componentID, newPath, {
                            ["$type"] = "TweakDBID",
                            ["$storage"] = "string",
                            ["$value"] = ""
                        })
                    end
                else
                    ImGui.Text(string.format("%s not yet supported", base:GetName().value))
                end
            else
                for _, class in pairs(utils.getDerivedClasses(base:GetName().value)) do
                    if ImGui.MenuItem(class) then
                        local newPath = utils.deepcopy(path)
                        table.insert(newPath, #data + 1)
                        if isHandle then
                            self:updatePropValue(componentID, newPath, { HandleId = "0", Data = red.redDataToJSON(NewObject(class)) })
                        else
                            self:updatePropValue(componentID, newPath, red.redDataToJSON(NewObject(class)))
                        end
                    end
                end
            end
            ImGui.EndPopup()
        end
    end
end

---Draw either a class by iterating over each property, or specical cases like DepotPath, CName etc.
---@param componentID number
---@param key string
---@param data any
---@param path table Path to the data, from the root of the component
---@param max number Maximum width of a label text
---@param propertySearch string?
---@param showAllChildren boolean?
function entity:drawTableProp(componentID, key, data, path, max, modified, propertySearch, showAllChildren)
    -- Step one down, to avoid handle structure, gets really fucking ugly later
    if data.HandleId then
        table.insert(path, "Data")
        self:drawInstanceDataProperty(componentID, key, data.Data, path, max, propertySearch, showAllChildren)
        return
    end

    local info = self:getPropTypeInfo(componentID, path, key)

    style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
    if data["DepotPath"] then
        table.insert(path, "DepotPath")
        table.insert(path, "$value")
        self:drawStringProp(componentID, key, data["DepotPath"]["$value"], path, "Resource", 300, max)
        style.popStyleColor(modified)
        return
    elseif info.typeName == "FixedPoint" then
        table.insert(path, "Bits")

        ImGui.Text(key)
        ImGui.SameLine()
        ImGui.SetNextItemWidth(100 * style.viewSize)
        local value = ImGui.InputFloat("##" .. componentID .. table.concat(path), data["Bits"] / 131072, 0, 0, "%.2f")
        if ImGui.IsItemDeactivatedAfterEdit() then
            history.addAction(history.getElementChange(self.object))
            self:updatePropValue(componentID, path, math.floor(value * 131072))
        end
        self:drawResetProp(componentID, path)
        style.popStyleColor(modified)
        return
    elseif info.typeName == "Color" then
        local clampColorChannel = function (value, fallback)
            local number = tonumber(value) or fallback
            number = math.max(0, math.min(255, number))
            return number
        end

        local toColorUnit = function (value, fallback)
            return clampColorChannel(value, fallback) / 255
        end

        local toColorByte = function (value)
            local number = tonumber(value) or 0
            number = math.max(0, math.min(1, number))
            return math.floor(number * 255 + 0.5)
        end

        ImGui.Text(tostring(key))
        ImGui.SameLine()
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() - ImGui.CalcTextSize(tostring(key)) + max)

        local color = {
            toColorUnit(data.Red, 0),
            toColorUnit(data.Green, 0),
            toColorUnit(data.Blue, 0),
            toColorUnit(data.Alpha, 255)
        }

        local widgetId = "##" .. componentID .. table.concat(path)
        local newColor = nil
        local changed = false

        if data.Alpha ~= nil then
            newColor, changed = style.trackedColorAlpha(self.object, widgetId, color, 60)
        else
            newColor, changed = style.trackedColor(self.object, widgetId, color, 60)
        end

        style.tooltip(info.typeName)
        self:drawResetProp(componentID, path)

        if changed then
            local updated = utils.deepcopy(data)
            updated.Red = toColorByte(newColor[1])
            updated.Green = toColorByte(newColor[2])
            updated.Blue = toColorByte(newColor[3])

            if updated.Alpha ~= nil then
                updated.Alpha = toColorByte(newColor[4] or color[4])
            end

            self:updatePropValue(componentID, path, updated)
        end

        style.popStyleColor(modified)
        return
    elseif info.typeName == "TweakDBID" or info.typeName == "CName" then
        table.insert(path, "$value")

        ImGui.Text(tostring(key))
        ImGui.SameLine()
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() - ImGui.CalcTextSize(tostring(key)) + max)
        ImGui.SetNextItemWidth(250 * style.viewSize)
        local value, _ = style.inputText("##" .. componentID .. table.concat(path), data["$value"], 250)
        local finishedEditing = ImGui.IsItemDeactivatedAfterEdit()
        style.tooltip(info.typeName)
        self:drawResetProp(componentID, path)

        if info.typeName == "CName" then
            local cursorPos = ImGui.GetCursorPosX() + max + 2 * ImGui.GetStyle().ItemSpacing.x
            self:drawLocKeyPreview(componentID, path, value, cursorPos)
        else
            -- Use the committed value, so nothing is resolved while the field is being typed in
            self:drawRecordDetails(componentID, path, data["$value"])
        end

        if finishedEditing then
            data["$storage"] = "string"
            history.addAction(history.getElementChange(self.object))
            self:updatePropValue(componentID, path, value)
        end

        style.popStyleColor(modified)
        return
    elseif info.typeName == "NodeRef" then
        local keyName = tostring(key)
        local rawDisplayValue = tostring(data["$value"] or "")
        local displayValue = registry.resolveDisplayRef(self.object, rawDisplayValue)
        if keyName == "floorMarker" and displayValue == rawDisplayValue then
            local siblingMarkerRef = resolveElevatorFloorMarkerNodeRefFromSibling(self.object)
            if siblingMarkerRef and siblingMarkerRef ~= "" then
                displayValue = siblingMarkerRef
            end
        end

        table.insert(path, "$value")

        ImGui.Text(keyName)
        ImGui.SameLine()
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() - ImGui.CalcTextSize(keyName) + max)

        local value, finished = registry.drawNodeRefSelector(style.getMaxWidth(250), displayValue, self.object, false)
        style.tooltip(info.typeName)
        self:drawResetProp(componentID, path)
        if finished then
            if string.find(value, "%D") then
                value, _ = value:gsub("#", "")
                value, _ = tostring(FNV1a64(value)):gsub("ULL", "")
            end

            history.addAction(history.getElementChange(self.object))
            self:updatePropValue(componentID, path, value)
        end

        style.popStyleColor(modified)
        return
    elseif info.typeName == "LocalizationString" then
        table.insert(path, "value")
        local currentValue = self:drawStringProp(componentID, key, data["value"], path, info.typeName, 150, max)
        local cursorPos = ImGui.GetCursorPosX() + max + 2 * ImGui.GetStyle().ItemSpacing.x
        self:drawLocalizationStringPreview(currentValue, cursorPos)
        style.popStyleColor(modified)
        return
    end

    local name = info.typeName .. " | " .. key

    local open = false
    if ImGui.TreeNodeEx(name, ImGuiTreeNodeFlags.SpanFullWidth) then
        self:drawResetProp(componentID, path, info.typeName)
        open = true
        style.popStyleColor(modified)

        local keys, max = self:getSortedKeys(data)
        -- Array uses numeric keys
        if info.propType and info.propType:IsArray() then
            keys = {}
            for key, _ in pairs(data) do table.insert(keys, key) end
        end

        for _, propKey in pairs(keys) do
            local entry = data[propKey]
            local propPath = utils.deepcopy(path)
            table.insert(propPath, propKey)
            self:drawInstanceDataProperty(componentID, propKey, entry, propPath, max, propertySearch, showAllChildren)
        end

        self:drawAddArrayEntry(info.propType, componentID, path, data)

        ImGui.TreePop()
    end
    if not open then
        self:drawResetProp(componentID, path, info.typeName)
        style.popStyleColor(modified)
    end
end

---@private
---@param componentID number
---@param key string Key of data within the parent
---@param data table
---@param path table Path to the data, from the root of the component
---@param max number Maximum width of a text
---@param propertySearch string?
---@param showAllChildren boolean?
function entity:drawInstanceDataProperty(componentID, key, data, path, max, propertySearch, showAllChildren)
    if key == "$type" or key == "$storage" or key == "Flags" then return end

    local propertyFilterActive = type(propertySearch) == "string" and propertySearch ~= ""
    if propertyFilterActive and not showAllChildren then
        local matchesSearch, directMatch = utils.matchesPropertySearchEntry(key, data, propertySearch, {})
        if not matchesSearch then
            return
        end

        showAllChildren = directMatch
    end

    local modified = false
    if self.instanceDataChanges[componentID] and self.instanceDataChanges[componentID][path[1]] then
        if not utils.deepcompare(data, utils.getNestedValue(self.defaultComponentData[componentID], path), false) then
            modified = true
        end
    end

    if type(data) == "table" then
        self:drawTableProp(componentID, key, data, path, max, modified, propertySearch, showAllChildren)
    else
        style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)

        local info = self:getPropTypeInfo(componentID, path, key)
        local locKeyPreviewValue = nil
        local propertyTooltipHandled = false

        if info.typeName == "rendLightChannel" then
            local sectionName = info.typeName .. " | " .. tostring(key)
            local open = false

            if ImGui.TreeNodeEx(sectionName, ImGuiTreeNodeFlags.SpanFullWidth) then
                open = true
                self:drawResetProp(componentID, path, info.typeName)

                local selection = lightComponentUI.decodeLightChannelSelection(data)
                local previous = lightComponentUI.encodeLightChannelSelection(selection)
                selection = style.drawLightChannelsSelector(nil, selection)
                local current = lightComponentUI.encodeLightChannelSelection(selection)

                if current ~= previous then
                    history.addAction(history.getElementChange(self.object))
                    self:updatePropValue(componentID, path, current)
                end

                ImGui.TreePop()
            end

            if not open then
                self:drawResetProp(componentID, path, info.typeName)
            end

            style.tooltip(info.typeName)
            style.popStyleColor(modified)
            return
        end

        ImGui.Text(tostring(key))
        ImGui.SameLine()
        ImGui.SetCursorPosX(ImGui.GetCursorPosX() - ImGui.CalcTextSize(tostring(key)) + max)

        if info.typeName == "Bool" then
            local value, changed = ImGui.Checkbox("##" .. componentID .. table.concat(path), data == 1 and true or false)
            if changed then
                history.addAction(history.getElementChange(self.object))
                self:updatePropValue(componentID, path, value and 1 or 0)
            end
        elseif info.typeName == "Float" then
            ImGui.SetNextItemWidth(100 * style.viewSize)
            local value = ImGui.InputFloat("##" .. componentID .. table.concat(path), data, 0, 0, "%.2f")
            if ImGui.IsItemDeactivatedAfterEdit() then
                value = clampCustomNumericProperty(key, value)
                history.addAction(history.getElementChange(self.object))
                self:updatePropValue(componentID, path, value)
            end
        elseif info.typeName == "uint64" or info.typeName == "Uint64" or info.typeName == "CRUID" or info.typeName == "String" then
            ImGui.SetNextItemWidth(100 * style.viewSize)

            local value, changed = style.inputText("##" .. componentID .. table.concat(path), data, 250)
            if info.typeName == "String" then
                locKeyPreviewValue = value
            end

            if changed then
                history.addAction(history.getElementChange(self.object))
                self:updatePropValue(componentID, path, value)
            end
        elseif string.match(info.typeName, "int") or string.match(info.typeName, "Int") then
            ImGui.SetNextItemWidth(100 * style.viewSize)

            local value = ImGui.InputInt("##" .. componentID .. table.concat(path), data, 0)
            if ImGui.IsItemDeactivatedAfterEdit() then
                value = clampCustomNumericProperty(key, value)
                history.addAction(history.getElementChange(self.object))
                self:updatePropValue(componentID, path, value)
            end
        elseif info.isEnum then
            if not self.enumInfo[info.typeName] then
                self.enumInfo[info.typeName] = utils.enumTable(info.typeName)
            end
            local values = self.enumInfo[info.typeName]

            ImGui.SetNextItemWidth(100 * style.viewSize)
            local value, changed = ImGui.Combo("##" .. componentID .. table.concat(path), utils.indexValue(values, data) - 1, values, #values)
            style.comboValueTooltip(value, values, info.typeName)
            propertyTooltipHandled = true
            if changed then
                history.addAction(history.getElementChange(self.object))
                self:updatePropValue(componentID, path, values[value + 1])
            end
        else
            ImGui.Text(key .. " " .. info.typeName)
        end

        if not propertyTooltipHandled then
            style.tooltip(info.typeName)
        end
        self:drawResetProp(componentID, path)

        if locKeyPreviewValue ~= nil then
            local cursorPos = ImGui.GetCursorPosX() + max + 2 * ImGui.GetStyle().ItemSpacing.x
            self:drawLocKeyPreview(componentID, path, locKeyPreviewValue, cursorPos)
        end

        style.popStyleColor(modified)
    end
end

---@param component table
---@return string
local function getComponentDisplayName(component)
    if type(component) ~= "table" then
        return "Entity"
    end

    if component.name and component.name["$value"] then
        return tostring(component.name["$value"])
    end

    return "Entity"
end

---@param componentKey string|number
---@param componentName string
---@return number
local function getComponentSortPriority(componentKey, componentName)
    local normalizedName = string.lower(componentName)
    local normalizedKey = string.lower(tostring(componentKey))

    if normalizedKey == "0" or normalizedName == "entity" then
        return 0
    end

    if normalizedName == "controller" then
        return 1
    end

    return 2
end

---Builds sorted component entries for the Spawned tab component list.
---@return table
function entity:getSortedComponents()
    local entries = {}

    for key, component in pairs(self.defaultComponentData) do
        if type(component) ~= "table" then
            component = {}
        end

        local componentName = getComponentDisplayName(component)
        local componentType = tostring(component["$type"] or "Unknown")

        table.insert(entries, {
            key = key,
            component = component,
            componentName = componentName,
            componentType = componentType,
            name = componentType .. " | " .. componentName,
            priority = getComponentSortPriority(key, componentName)
        })
    end

    table.sort(entries, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end

        local aType = string.lower(a.componentType)
        local bType = string.lower(b.componentType)
        if aType ~= bType then
            return aType < bType
        end

        local aName = string.lower(a.componentName)
        local bName = string.lower(b.componentName)
        if aName ~= bName then
            return aName < bName
        end

        return string.lower(tostring(a.key)) < string.lower(tostring(b.key))
    end)

    return entries
end

---Whether component data has been loaded, i.e. more than just the (optional) PS controller entry
---@return boolean
function entity:hasLoadedInstanceData()
    local nDefaultData = utils.tableLength(self.defaultComponentData)

    if nDefaultData == 0 then return false end
    if nDefaultData == 1 and self.defaultComponentData[self.psControllerID] ~= nil then return false end

    return true
end

---Number of components in the loaded instance data, excluding the entity itself
---@return number
function entity:getComponentCount()
    local count = utils.tableLength(self.defaultComponentData)

    if self.defaultComponentData["0"] then -- The "0" entry is the entity, not a component
        count = count - 1
    end

    return count
end

---Draws the component counter next to the "Entity Instance Data" header, once components have been loaded
function entity:drawInstanceDataCounter()
    if not self:hasLoadedInstanceData() then return end

    ImGui.SameLine()
    style.mutedText(string.format("(%d %s)", self:getComponentCount(), self:getComponentCount() == 1 and "component" or "components"))
end

function entity:drawInstanceData()
    local nDefaultData = utils.tableLength(self.defaultComponentData)
    if nDefaultData <= 1 then
        local entity = self:getEntity()

        if entity then
            if nDefaultData == 0 or (nDefaultData == 1 and self.defaultComponentData[self.psControllerID] ~= nil) then -- Load default data if either not loaded, or only for the PS controller
                self:loadInstanceData(entity, true)
            end
        else
            ImGui.Text("Entity not spawned")
            return
        end
    end

    self.instanceDataSearchInProperties = self.instanceDataSearchInProperties == true

    if style.drawSearchClearButton('##searchComponentClear', self.instanceDataSearch ~= "", 'Search for component') then
        self.instanceDataSearch = ""
        style.clearSearchInput('##searchComponent', true)
    end

    ImGui.PushItemWidth(200 * style.viewSize)
    self.instanceDataSearch = style.searchInputTextWithHint('##searchComponent', 'Search for component...', self.instanceDataSearch, 100)
    ImGui.PopItemWidth()

    ImGui.SameLine()
    self.instanceDataSearchInProperties, _ = ImGui.Checkbox("Search in properties##instanceDataPropertySearch", self.instanceDataSearchInProperties)
    style.tooltip("Include component property names and values in the filter.")

    local search = self.instanceDataSearch:lower()
    local propertySearch = (self.instanceDataSearchInProperties and search ~= "") and search or nil
    for _, entry in ipairs(self:getSortedComponents()) do
        local key = entry.key
        local component = entry.component
        local componentName = entry.componentName
        local name = entry.name

        local matchesSearch = self.instanceDataSearch == ""
            or string.find(componentName:lower(), search, 1, true) ~= nil
            or string.find(name:lower(), search, 1, true) ~= nil

        if not matchesSearch and self.instanceDataSearchInProperties and search ~= "" then
            matchesSearch = utils.matchesComponentPropertiesSearch(component, self.instanceDataChanges[key], search)
        end

        if matchesSearch then
            style.pushStyleColor(not self.instanceDataChanges[key], ImGuiCol.Text, style.mutedColor)

            local expanded = false
            if ImGui.TreeNodeEx(name, ImGuiTreeNodeFlags.SpanFullWidth) then
                expanded = true
                self:drawResetComponent(key)
                style.popStyleColor(not self.instanceDataChanges[key])

                if lightComponentUI.isLightComponentData(component) then
                    self:drawLightComponentInstanceData(key, component, propertySearch)
                else
                    local keys, max = self:getSortedKeys(component)
                    for _, propKey in pairs(keys) do
                        local entry = component[propKey]
                        local modified = self.instanceDataChanges[key] and self.instanceDataChanges[key][propKey]
                        if modified then entry = self.instanceDataChanges[key][propKey] end

                        style.pushStyleColor(true, ImGuiCol.Text, style.mutedColor)
                        self:drawInstanceDataProperty(key, propKey, entry, { propKey }, max, propertySearch, false)

                        style.popStyleColor(true)
                    end
                end
                ImGui.TreePop()
            end
            if not expanded then
                self:drawResetComponent(key)
                style.popStyleColor(not self.instanceDataChanges[key])
            end
        end
    end
end

lightComponentUI.install(entity)

return entity
