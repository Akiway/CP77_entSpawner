local utils = require("modules/utils/core/utils")
local gameUtils = require("modules/utils/game/gameUtils")
local config = require("modules/utils/core/config")

---Shared sound system / speaker data.
---Read by the device spawnable, the quick setup popup and the editor viewport overlay, so the
---entity paths, controller IDs and station names stay in sync between them.
---
---Everything here is verified against the shipped entities and the live TweakDB:
---`sound_system.ent` carries a single `SoundSystemController` (`controller`), `speaker.ent` and
---`speaker_virtual.ent` a single `SpeakerController` (`controller`).
---@class soundSystem
local soundSystem = {}

soundSystem.SOUND_SYSTEM_CONTROLLER_CLASS = "SoundSystemControllerPS"
soundSystem.SPEAKER_CONTROLLER_CLASS = "SpeakerControllerPS"
soundSystem.COMPUTER_CONTROLLER_CLASS = "ComputerControllerPS"
soundSystem.RADIO_CONTROLLER_CLASS = "RadioControllerPS"

soundSystem.SOUND_SYSTEM_PATH = "base\\gameplay\\devices\\home_appliances\\radio_sets\\sound_system.ent"
---CRUID of the `controller` component in `sound_system.ent`, used as fallback when the entity has
---not finished assembling and `getPersistentComponentID` cannot scan for the class.
soundSystem.SOUND_SYSTEM_COMPONENT_ID = "1907122819767472128"
---CRUID of the `controller` component in both speaker entities.
soundSystem.SPEAKER_COMPONENT_ID = "1874784723462000640"

soundSystem.SETTINGS_PATH = { "persistentState", "Data", "soundSystemSettings" }
soundSystem.DEFAULT_ACTION_PATH = { "persistentState", "Data", "defaultAction" }
soundSystem.DEVICE_STATE_PATH = { "persistentState", "Data", "deviceState" }
soundSystem.SPEAKER_SETUP_PATH = { "persistentState", "Data", "speakerSetup" }

---Entries past this render as overlapping buttons in the device UI.
soundSystem.RECOMMENDED_MAX_ENTRIES = 6

soundSystem.STATUS_EFFECTS = { "NONE", "DEAFENED", "SUPRESS_NOISE" }
soundSystem.DEVICE_STATES = { "ON", "OFF" }

---The two concrete `MusicSettings` subclasses. The base class is abstract in practice: it carries
---only `statusEffect` and no sound of its own.
soundSystem.MUSIC_SOURCES = {
    { key = "PlayRadio", label = "Radio station" },
    { key = "PlaySoundEvent", label = "Sound event" }
}

---`ERadioStationList` members in enum order, paired with the TweakDB record the localized station
---name lives on. Mod-added stations cannot be selected here: the field is an engine enum, not a
---record reference, so it only understands these fourteen.
---Each `record` is confirmed by its `icon` flat, which spells the enum member out
---(`RadioStation.AttRock.icon` is `UIIcon.RadioAttitudeRock` = `ATTITUDE_ROCK`).
---`fallback` is the shipped en-us name, used until TweakDB and localization are ready.
---@type { enum: string, record: string, fallback: string }[]
soundSystem.STATIONS = {
    { enum = "AGGRO_INDUSTRIAL",   record = "RadioStation.AggroIndie",   fallback = "89.3 RADIO VEXELSTROM" },
    { enum = "ELECTRO_INDUSTRIAL", record = "RadioStation.ElectroIndie", fallback = "92.9 Night FM" },
    { enum = "HIP_HOP",            record = "RadioStation.HipHop",       fallback = "101.9 The Dirge" },
    { enum = "AGGRO_TECHNO",       record = "RadioStation.AggroTechno",  fallback = "103.5 Radio PEBKAC" },
    { enum = "DOWNTEMPO",          record = "RadioStation.Downtempo",    fallback = "88.9 Pacific Dreams" },
    { enum = "ATTITUDE_ROCK",      record = "RadioStation.AttRock",      fallback = "107.3 Morro Rock Radio" },
    { enum = "POP",                record = "RadioStation.Pop",          fallback = "98.7 Body Heat Radio" },
    { enum = "LATINO",             record = "RadioStation.Latino",       fallback = "106.9 30 PRINCIPALES" },
    { enum = "METAL",              record = "RadioStation.Metal",        fallback = "96.1 Ritual FM" },
    { enum = "MINIMAL_TECHNO",     record = "RadioStation.MinimTech",    fallback = "95.2 Samizdat Radio" },
    { enum = "JAZZ",               record = "RadioStation.Jazz",         fallback = "91.9 Royal Blue Radio" },
    { enum = "GROWL",              record = "RadioStation.GrowlFM",      fallback = "89.7 Growl FM" },
    { enum = "DARK_STAR",          record = "RadioStation.DarkStar",     fallback = "107.5 Dark Star" },
    { enum = "IMPULSE_FM",         record = "RadioStation.Impulse",      fallback = "99.9 Impulse" }
}

---Interaction records worth offering as an entry caption, ordered by how useful they are on a sound
---system. The first six are the ones CDPR actually uses on shipped systems; the rest are the vanilla
---records whose caption reads as a music or audio control. Any other `Interactions.*` record can
---still be typed in by hand.
---
---No descriptions here on purpose: the picker shows each record's live localized caption, which is
---the button text the player will read, and that beats anything that could be written about it.
---@type string[]
soundSystem.INTERACTIONS = {
    "Interactions.AmbientSounds",
    "Interactions.Off",
    "Interactions.Play",
    "Interactions.HackVolume",
    "Interactions.Overcharge",
    "Interactions.Upload",
    "Interactions.Stop",
    "Interactions.On",
    "Interactions.Next",
    "Interactions.Previous",
    "Interactions.Repeat",
    "Interactions.ChangeMusicHack",
    "Interactions.UploadMusicData",
    "Interactions.VinylPlayerTurnOn",
    "Interactions.VinylPlayerTurnOff",
    "Interactions.Power",
    "Interactions.Turn_On",
    "Interactions.Turn_Power_off",
    "Interactions.Activate",
    "Interactions.Deactivate",
    "Interactions.Distract",
    "Interactions.QuickHackDistraction"
}

---Sound events on the music bus are not positional: they play at full volume everywhere, ignoring
---the speaker chain. CDPR shipped one anyway (`mus_test_radio_chippin_in`), so this warns.
soundSystem.MUSIC_BUS_PREFIX = "mus_"

---Icon standing for the sound system itself in the chain graph.
soundSystem.SYSTEM_ICON = IconGlyphs.SurroundSound

---Speaker entities that can be added to a sound system.
---`appearances` are ordered by how often they appear in the shipped world.
soundSystem.SPEAKER_DEFINITIONS = {
    speaker = {
        key = "speaker",
        label = "Speaker",
        icon = IconGlyphs.Speaker,
        spawnData = "base\\gameplay\\devices\\home_appliances\\radio_sets\\speaker.ent",
        namePrefix = "Speaker",
        defaultApp = "speaker_set_small",
        appearances = {
            "speaker_set_small",
            "speaker_set_big",
            "speaker_single",
            "speaker_single_gold",
            "speaker_array_a",
            "speaker_array_b"
        }
    },
    virtual = {
        key = "virtual",
        label = "Virtual Speaker (no mesh)",
        icon = IconGlyphs.Speaker,
        spawnData = "base\\gameplay\\devices\\home_appliances\\radio_sets\\speaker_virtual.ent",
        namePrefix = "Speaker_Virtual",
        defaultApp = "default",
        appearances = { "default" }
    }
}

soundSystem.SPEAKER_ORDER = { "speaker", "virtual" }

---One color per role in a sound system chain, packed ABGR for ImGui. Shared by the viewport helper
---and the chain graph in the quick setup, so a purple box in the popup and a purple line in the
---world mean the same thing. `contrast` is the high-contrast wireframe style.
soundSystem.CHAIN_COLORS = {
    system  = { normal = 0xFF996600, contrast = 0xFFFFCC00 },
    speaker = { normal = 0xFF007F00, contrast = 0xFF50FF50 },
    master  = { normal = 0xFFAA44AA, contrast = 0xFFFF77FF }
}

---@param role string `system`, `speaker` or `master`
---@param highContrast boolean?
---@return integer
function soundSystem.getChainColor(role, highContrast)
    local pair = soundSystem.CHAIN_COLORS[tostring(role or "")] or soundSystem.CHAIN_COLORS.system

    return highContrast and pair.contrast or pair.normal
end

---Preview sphere drawn at a speaker's audible radius, the same idea as the light radius preview.
---A separate component name from the position marker, so the two can be toggled independently.
soundSystem.RANGE_SPHERE_COMPONENT = "speaker_range_sphere"
soundSystem.RANGE_SPHERE_COLOR = "ghostwhite"

---Device controllers a sound system can drive. `SoundSystemControllerPS.RefreshSlaves` casts every
---immediate slave to `SpeakerControllerPS` and skips anything else, so this is the whole list --
---a radio or a jukebox wired to a sound system is silently ignored by the game.
soundSystem.DRIVEABLE_SLAVE_CLASSES = {
    [soundSystem.SPEAKER_CONTROLLER_CLASS] = true
}

soundSystem.JUKEBOX_CONTROLLER_CLASS = "JukeboxControllerPS"

---Media devices authors reach for expecting them to follow a sound system, and why they do not.
soundSystem.MEDIA_SLAVE_NOTES = {
    [soundSystem.RADIO_CONTROLLER_CLASS] = "A radio keeps its own station and ignores ChangeMusicAction.",
    [soundSystem.JUKEBOX_CONTROLLER_CLASS] = "A jukebox keeps its own station and ignores ChangeMusicAction."
}

---True when a connected device actually reacts to this system's entries.
---@param controllerClass string?
---@return boolean
function soundSystem.isDriveableSlaveClass(controllerClass)
    return soundSystem.DRIVEABLE_SLAVE_CLASSES[tostring(controllerClass or "")] == true
end

---Why a connected device will not follow the sound system, or `nil` when it will.
---@param controllerClass string?
---@return string?
function soundSystem.getSlaveRejectionReason(controllerClass)
    local className = tostring(controllerClass or "")
    if className == "" or soundSystem.isDriveableSlaveClass(className) then
        return nil
    end

    return soundSystem.MEDIA_SLAVE_NOTES[className]
        or "Only SpeakerControllerPS devices follow a sound system; this one is ignored."
end

---CRUID of the `controller` component, shared by every shipped computer entity.
soundSystem.COMPUTER_COMPONENT_ID = "1131680419258347532"
soundSystem.COMPUTER_SETUP_PATH = { "persistentState", "Data", "computerSetup" }
---`EComputerMenuType`
soundSystem.COMPUTER_MENUS = { "MAIN", "SYSTEM", "FILES", "MAILS", "NEWSFEED", "INTERNET", "INVALID" }

---Devices that can drive a sound system, all of them observed doing so in the shipped world.
---A master owns the connection: it is the master's `deviceConnections` that names the sound system,
---not the other way round.
soundSystem.MASTER_DEFINITIONS = {
    laptop = {
        key = "laptop",
        label = "Laptop",
        icon = IconGlyphs.DesktopClassic,
        hint = "CDPR's own choice on three of the four shipped sound systems",
        spawnData = "base\\gameplay\\devices\\masters\\computers\\laptop_1.ent",
        controllerClass = "ComputerControllerPS",
        componentID = "1131680419258347532",
        namePrefix = "Sound_System_Laptop",
        defaultApp = "laptop_laptop_1",
        isComputer = true
    },
    computer = {
        key = "computer",
        label = "Computer",
        icon = IconGlyphs.DesktopClassic,
        hint = "Desk computer, same controller as the laptop",
        spawnData = "base\\gameplay\\devices\\masters\\computers\\computer_1.ent",
        controllerClass = "ComputerControllerPS",
        componentID = "1131680419258347532",
        namePrefix = "Sound_System_Computer",
        defaultApp = "computer_computer_1",
        isComputer = true
    },
    switch = {
        key = "switch",
        label = "Virtual Switch (no mesh)",
        icon = IconGlyphs.ToggleSwitchOffOutline,
        hint = "Plain on/off with no UI, used on the q115 ambient systems",
        spawnData = "base\\gameplay\\devices\\masters\\switches\\switch_virtual.ent",
        controllerClass = "SimpleSwitchControllerPS",
        componentID = "1121129486117040128",
        namePrefix = "Sound_System_Switch",
        defaultApp = "default",
        isComputer = false
    },
    accessPoint = {
        key = "accessPoint",
        label = "Virtual Access Point (no mesh)",
        icon = IconGlyphs.AccessPointNetwork,
        hint = "Puts the system on a network so it can be quickhacked",
        spawnData = "base\\gameplay\\devices\\masters\\access_points\\virtual_accesspoint.ent",
        controllerClass = "AccessPointControllerPS",
        componentID = "1685296358694252544",
        namePrefix = "Sound_System_AccessPoint",
        defaultApp = "default",
        isComputer = false
    }
}

soundSystem.MASTER_ORDER = { "laptop", "computer", "switch", "accessPoint" }

---The computer flags the sound-system guide prescribes, so the machine opens straight onto the
---sound system page instead of the desktop. Five of the seven differ from the shipped defaults.
soundSystem.COMPUTER_TERMINAL_PRESET = {
    startingMenu = "SYSTEM",
    systemMenu = 1,
    hideTopNavigationBar = 1,
    mailsMenu = 0,
    filesMenu = 0,
    internetMenu = 0,
    newsFeedMenu = 0
}

local MASTER_BY_SPAWNDATA = {}
for key, definition in pairs(soundSystem.MASTER_DEFINITIONS) do
    MASTER_BY_SPAWNDATA[string.lower(definition.spawnData)] = key
end

local SPEAKER_BY_SPAWNDATA = {}
for key, definition in pairs(soundSystem.SPEAKER_DEFINITIONS) do
    SPEAKER_BY_SPAWNDATA[string.lower(definition.spawnData)] = key
end

local stationIndexByEnum = {}
for index, station in ipairs(soundSystem.STATIONS) do
    stationIndexByEnum[station.enum] = index
end

local stationLabelCache = {}
local locKeyCache = {}
---Interaction captions and record existence are read once per entry per frame while the popup is
---open, so both are memoized. `false` records a confirmed miss.
local interactionCaptionCache = {}
local interactionExistsCache = {}

---@param value any
---@param defaultValue number?
---@return number
local function boolToInt(value, defaultValue)
    if value == nil then
        value = defaultValue
    end

    return (value == true or value == 1) and 1 or 0
end

soundSystem.boolToInt = boolToInt

---Reads a TweakDB flat and normalizes a LocKey wrapper into the `LocKey#<id>` text form used
---everywhere else in the mod. LocKeys stringify as `LocKey(1234ull)`.
---@param flatPath string
---@return string?
local function readFlatAsText(flatPath)
    local ok, value = pcall(function ()
        return TweakDB:GetFlat(flatPath)
    end)

    if not ok or value == nil then
        return nil
    end

    if type(value) == "string" then
        return value ~= "" and value or nil
    end

    local okText, text = pcall(function () return tostring(value) end)
    if not okText or type(text) ~= "string" then
        return nil
    end

    local locKeyHash = text:match("^LocKey%((%d+)ull%)$")
    if locKeyHash then
        return "LocKey#" .. locKeyHash
    end

    return text ~= "" and text or nil
end

soundSystem.readFlat = readFlatAsText

---Secondary localization key the shipped interaction records take their button text from. Their own
---`caption` flat is empty -- verified across all of `INTERACTIONS` -- so this is the real source.
soundSystem.INTERACTION_LOCALIZATION_PREFIX = "Gameplay-Devices-Interactions-"

---Text the player reads on this interaction's button, or `nil` when nothing resolves.
---
---Two sources, in this order, because vanilla and modded records carry it differently:
---  1. the record's own `caption` flat -- empty on every shipped `Interactions.*` record, but set on
---     custom ones, including the records World Builder generates into `<project>_interactions.yaml`;
---  2. the localization entry `Gameplay-Devices-Interactions-<name>`, which is where the shipped
---     records actually get their text from.
---
---Reading only the flat, as this used to, resolves nothing for any vanilla record.
---
---`resolveLocKey` is only needed to *compute* a caption; an already cached one comes back without it.
---@param interactionID string?
---@param resolveLocKey fun(value: any): string?
---@return string?
function soundSystem.getInteractionCaption(interactionID, resolveLocKey)
    local id = utils.trimString(tostring(interactionID or ""))
    if id == "" then
        return nil
    end

    local cached = interactionCaptionCache[id]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    if type(resolveLocKey) ~= "function" then
        return nil
    end

    ---@param candidate string?
    ---@return string?
    local function resolve(candidate)
        if not candidate then
            return nil
        end

        local localized = resolveLocKey(candidate)
        if not localized then
            return nil
        end

        localized = utils.trimString(localized)
        if localized == "" or localized == "None" then
            return nil
        end

        return localized
    end

    local caption = resolve(readFlatAsText(id .. ".caption"))

    if not caption then
        -- The shipped records key their text off `name`, not off the record path, so a renamed or
        -- aliased record still resolves.
        local recordName = readFlatAsText(id .. ".name")
        if not recordName or recordName == "" then
            recordName = id:match("%.([^%.]+)$")
        end

        if recordName and recordName ~= "" then
            caption = resolve(soundSystem.INTERACTION_LOCALIZATION_PREFIX .. recordName)
        end
    end

    interactionCaptionCache[id] = caption or false
    return caption
end

---True when the interaction record resolves in the live TweakDB.
---@param interactionID string?
---@return boolean
function soundSystem.interactionExists(interactionID)
    local id = utils.trimString(tostring(interactionID or ""))
    if id == "" then
        return false
    end

    local cached = interactionExistsCache[id]
    if cached ~= nil then
        return cached
    end

    local ok, exists = pcall(function ()
        return TweakDB:GetRecord(id) ~= nil
    end)
    local result = ok and exists == true

    -- Only a hit is final: a record the author is about to add with a .tweak should be picked up
    -- once it exists, so misses are re-checked.
    if result then
        interactionExistsCache[id] = true
    end

    return result
end

---Tooltip for one row of the caption picker: the caption the player will actually read on the
---button, so the author picks by the text rather than by the record name.
---@param interactionID string?
---@param resolveLocKey fun(value: any): string?
---@return string?
function soundSystem.getInteractionOptionTooltip(interactionID, resolveLocKey)
    local id = utils.trimString(tostring(interactionID or ""))
    if id == "" then
        return nil
    end

    local caption = soundSystem.getInteractionCaption(id, resolveLocKey)
    if caption then
        return caption
    end

    return soundSystem.interactionExists(id) and "Record has no caption." or "Not in TweakDB yet."
end

---Localized display name of a station, resolved live so it follows the players language.
---Falls back to the English station name when TweakDB or the localization system is not ready.
---@param enumName string `ERadioStationList` member
---@return string
function soundSystem.getStationLabel(enumName)
    enumName = tostring(enumName or "")

    local cached = stationLabelCache[enumName]
    if cached then
        return cached
    end

    local index = stationIndexByEnum[enumName]
    local station = index and soundSystem.STATIONS[index] or nil
    if not station then
        return enumName ~= "" and enumName or "None"
    end

    ---@param value string?
    ---@return string?
    local function localize(value)
        if type(value) ~= "string" then
            return nil
        end

        local localized = gameUtils.resolveLocKey(utils.trimString(value), locKeyCache)
        if type(localized) ~= "string" then
            return nil
        end

        localized = utils.trimString(localized)

        return localized ~= "" and localized ~= "None" and localized or nil
    end

    -- The `gamedataRadioStation_Record` is the authority: its `displayName` is the same LocKey the
    -- radio UI prints, so the picker reads as the station name in the player's language.
    local label = localize(readFlatAsText(station.record .. ".displayName"))

    -- `RadioStationDataProvider.GetChannelName` hands back a localization *key*
    -- ("Gameplay-Devices-Radio-RadioStationElectroIndie"), not a name, so it has to go through the
    -- same lookup. Only a fallback, for a station whose record cannot be read.
    if not label then
        local okProvider, providerKey = pcall(function ()
            return RadioStationDataProvider.GetChannelName(enumName)
        end)
        if okProvider then
            label = localize(providerKey)
        end
    end

    if not label then
        -- Do not cache the fallback, so the real name is picked up once TweakDB is ready.
        return station.fallback
    end

    stationLabelCache[enumName] = label
    return label
end

---Station labels in enum order, for a combo. Index in this table matches `STATIONS`.
---@return string[]
function soundSystem.getStationLabels()
    local labels = {}

    for _, station in ipairs(soundSystem.STATIONS) do
        table.insert(labels, soundSystem.getStationLabel(station.enum))
    end

    return labels
end

---Zero-based combo index of a station enum member.
---@param enumName string?
---@return number
function soundSystem.getStationComboIndex(enumName)
    local index = stationIndexByEnum[tostring(enumName or "")]

    return index and (index - 1) or 0
end

---Enum member for a zero-based combo index.
---@param comboIndex number?
---@return string
function soundSystem.getStationByComboIndex(comboIndex)
    local station = soundSystem.STATIONS[(tonumber(comboIndex) or 0) + 1]

    return station and station.enum or soundSystem.STATIONS[1].enum
end

---The Static Audio Emitter spawn list. Every name in it is an audio event the mod already ships as
---a placeable `worldStaticSoundEmitterNode`, which makes it the closest thing to a vetted event
---catalogue -- far better than asking the author to remember an event name.
soundSystem.STATIC_AUDIO_EMITTER_PATH = "data/spawnables/visual/sounds/"

---Rows rendered when the picker is opened with an empty search box. The full catalogue is only
---filtered in once the author types, so the list stays responsive.
soundSystem.SOUND_EVENT_BROWSE_LIMIT = 150
---Cap on how many catalogue matches one search shows.
soundSystem.SOUND_EVENT_MATCH_LIMIT = 200

local staticAudioEmitterEvents = nil

---Every audio event from the Static Audio Emitter spawn list, sorted, loaded once.
---@return string[]
function soundSystem.getStaticAudioEmitterEvents()
    if staticAudioEmitterEvents then
        return staticAudioEmitterEvents
    end

    local events = {}
    local ok, entries = pcall(function ()
        return config.loadLists(soundSystem.STATIC_AUDIO_EMITTER_PATH)
    end)

    if ok and type(entries) == "table" then
        local seen = {}
        for _, entry in ipairs(entries) do
            local name = utils.trimString(tostring(entry and entry.name or ""))
            if name ~= "" and not seen[name] then
                seen[name] = true
                table.insert(events, name)
            end
        end
    end

    staticAudioEmitterEvents = events

    return staticAudioEmitterEvents
end

---Options for the sound event picker: the head of the Static Audio Emitter catalogue while the
---search box is empty, its matches once the author types. Both are capped, because
---`trackedSearchDropdown` draws every option it is handed on every frame the popup is open.
---@param currentValue string?
---@param query string?
---@return string[]
function soundSystem.getSoundEventOptions(currentValue, query)
    local options = {}
    local seen = {}

    local function push(name)
        name = utils.trimString(tostring(name or ""))
        if name ~= "" and name ~= "None" and not seen[name] then
            seen[name] = true
            table.insert(options, name)
        end
    end

    push(currentValue)

    local normalizedQuery = string.lower(utils.trimString(tostring(query or "")))
    local limit = normalizedQuery == ""
        and soundSystem.SOUND_EVENT_BROWSE_LIMIT
        or soundSystem.SOUND_EVENT_MATCH_LIMIT

    for _, name in ipairs(soundSystem.getStaticAudioEmitterEvents()) do
        if #options >= limit then
            break
        end
        if normalizedQuery == "" or string.find(string.lower(name), normalizedQuery, 1, true) then
            push(name)
        end
    end

    return options
end

---@param eventName string?
---@return boolean
function soundSystem.isMusicBusEvent(eventName)
    local normalized = string.lower(utils.trimString(tostring(eventName or "")))

    return normalized ~= "" and normalized:sub(1, #soundSystem.MUSIC_BUS_PREFIX) == soundSystem.MUSIC_BUS_PREFIX
end

---@param spawnData string?
---@return table?
function soundSystem.resolveSpeakerDefinition(spawnData)
    local key = SPEAKER_BY_SPAWNDATA[string.lower(tostring(spawnData or ""))]

    return key and soundSystem.SPEAKER_DEFINITIONS[key] or nil
end

---Speaker definitions in display order.
---@return table[]
function soundSystem.getSpeakerDefinitions()
    local definitions = {}

    for _, key in ipairs(soundSystem.SPEAKER_ORDER) do
        local definition = soundSystem.SPEAKER_DEFINITIONS[key]
        if definition then
            table.insert(definitions, definition)
        end
    end

    return definitions
end

---Builds the `musicSettings` handle payload for one entry.
---Always returns fresh tables, never anything shared with a cached payload.
---@param sourceKey string `PlayRadio` or `PlaySoundEvent`
---@param previous table? Existing `musicSettings.Data`, so `statusEffect` survives a source swap
---@return table
function soundSystem.createMusicSettings(sourceKey, previous)
    sourceKey = tostring(sourceKey or "PlayRadio")
    if sourceKey ~= "PlaySoundEvent" then
        sourceKey = "PlayRadio"
    end

    previous = type(previous) == "table" and previous or {}

    local statusEffect = tostring(previous.statusEffect or "NONE")
    if utils.indexValue(soundSystem.STATUS_EFFECTS, statusEffect) == -1 then
        statusEffect = "NONE"
    end

    if sourceKey == "PlaySoundEvent" then
        local eventName = ""
        if type(previous.soundEvent) == "table" then
            eventName = tostring(previous.soundEvent["$value"] or "")
        end
        if eventName == "" or eventName == "None" then
            -- A fresh sound-event entry starts on the first catalogue event rather than empty, so
            -- the row has something the test button can actually play.
            eventName = soundSystem.getStaticAudioEmitterEvents()[1] or ""
        end

        return {
            ["$type"] = "PlaySoundEvent",
            soundEvent = {
                ["$type"] = "CName",
                ["$storage"] = "string",
                ["$value"] = eventName
            },
            statusEffect = statusEffect
        }
    end

    local radioStation = tostring(previous.radioStation or "")
    if stationIndexByEnum[radioStation] == nil then
        radioStation = soundSystem.STATIONS[1].enum
    end

    return {
        ["$type"] = "PlayRadio",
        radioStation = radioStation,
        statusEffect = statusEffect
    }
end

---Builds a complete `SoundSystemSettings` array entry.
---The generic instance data editor cannot construct the `musicSettings` handle -- `convertHandle`
---drops null handles, so the key never reaches the JSON and no row is ever drawn for it. Entries
---are therefore always built here, whole, and written through `updateComponentPathValue`.
---@param options table? `{ interactionName, canBeUsedAsQuickHack, source, radioStation, soundEvent, statusEffect }`
---@return table
function soundSystem.createEntry(options)
    options = options or {}

    local musicSettings = soundSystem.createMusicSettings(options.source or "PlayRadio", {
        radioStation = options.radioStation,
        statusEffect = options.statusEffect,
        soundEvent = options.soundEvent and {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = tostring(options.soundEvent)
        } or nil
    })

    return {
        ["$type"] = "SoundSystemSettings",
        canBeUsedAsQuickHack = boolToInt(options.canBeUsedAsQuickHack, 0),
        interactionName = {
            ["$type"] = "TweakDBID",
            ["$storage"] = "string",
            ["$value"] = tostring(options.interactionName or soundSystem.INTERACTIONS[1])
        },
        musicSettings = {
            HandleId = "0",
            Data = musicSettings
        }
    }
end

---Repairs a `SoundSystemSettings` entry read back from instance data, so the popup never has to
---guard against a half-written or hand-edited entry.
---@param entry table?
---@return table
function soundSystem.normalizeEntry(entry)
    local normalized = utils.deepcopy(type(entry) == "table" and entry or {})
    normalized["$type"] = "SoundSystemSettings"
    normalized.canBeUsedAsQuickHack = boolToInt(normalized.canBeUsedAsQuickHack, 0)

    if type(normalized.interactionName) ~= "table" then
        normalized.interactionName = {
            ["$type"] = "TweakDBID",
            ["$storage"] = "string",
            ["$value"] = soundSystem.INTERACTIONS[1]
        }
    else
        normalized.interactionName["$type"] = "TweakDBID"
        normalized.interactionName["$storage"] = "string"
        normalized.interactionName["$value"] = tostring(normalized.interactionName["$value"] or "")
    end

    local handle = normalized.musicSettings
    local data = type(handle) == "table" and handle.Data or nil
    local sourceKey = type(data) == "table" and tostring(data["$type"] or "") or ""

    if sourceKey ~= "PlayRadio" and sourceKey ~= "PlaySoundEvent" then
        sourceKey = "PlayRadio"
    end

    normalized.musicSettings = {
        HandleId = type(handle) == "table" and tostring(handle.HandleId or "0") or "0",
        Data = soundSystem.createMusicSettings(sourceKey, data)
    }

    return normalized
end

---@param entry table?
---@return string `PlayRadio` or `PlaySoundEvent`
function soundSystem.getEntrySource(entry)
    local data = type(entry) == "table"
        and type(entry.musicSettings) == "table"
        and entry.musicSettings.Data
        or nil

    local sourceKey = type(data) == "table" and tostring(data["$type"] or "") or ""

    return sourceKey == "PlaySoundEvent" and "PlaySoundEvent" or "PlayRadio"
end

---Short human label for one entry, used in headers and in the default-entry picker.
---@param entry table?
---@param index number
---@param resolveLocKey fun(value: any): string? Caller supplies the spawnables cached resolver
---@return string
function soundSystem.getEntryLabel(entry, index, resolveLocKey)
    local normalized = soundSystem.normalizeEntry(entry)
    local source = soundSystem.getEntrySource(normalized)
    local data = normalized.musicSettings.Data

    local sound
    if source == "PlaySoundEvent" then
        sound = tostring(data.soundEvent and data.soundEvent["$value"] or "")
        if sound == "" or sound == "None" then
            sound = "No sound event"
        end
    else
        sound = soundSystem.getStationLabel(data.radioStation)
    end

    local caption = utils.trimString(tostring(normalized.interactionName["$value"] or ""))
    local captionLabel = caption:match("^Interactions%.(.+)$") or caption

    local localizedCaption = soundSystem.getInteractionCaption(caption, resolveLocKey)
    if localizedCaption then
        captionLabel = localizedCaption
    end

    if captionLabel == "" then
        captionLabel = "No caption"
    end

    return string.format("%d. %s  |  %s", index, captionLabel, sound)
end

---Whether a speaker's `defaultMusic` is ever heard, given the state of the system driving it.
---
---`SoundSystemControllerPS.GameAttached` builds a `ChangeMusicAction` from `defaultAction` and calls
---`RefreshSlaves_Event`, but `OnRefreshSlavesEvent` only forwards it while the system `IsON()`. The
---speaker's own `GameAttached` has already set its current station to `defaultMusic`, so the two
---race and the system wins whenever it is on and has an entry.
---@param systemIsOn boolean
---@param entryCount number
---@return boolean overridden
---@return string note
function soundSystem.describeDefaultStation(systemIsOn, entryCount)
    if systemIsOn and (tonumber(entryCount) or 0) > 0 then
        return true, "Overridden at load: the system is ON and pushes its starting entry to every "
            .. "speaker as soon as it attaches.\nOnly heard if something other than this system "
            .. "turns the speaker on."
    end

    if not systemIsOn then
        return false, "Heard at load: the system is OFF, so it pushes nothing and the speaker falls "
            .. "back to this station."
    end

    return false, "Heard at load: the system has no entries to push, so the speaker falls back to "
        .. "this station."
end

---`distractionMusic` never involves the sound system at all.
soundSystem.DISTRACTION_STATION_NOTE =
    "Independent of the sound system.\nPlayed by the speaker's own Malfunction quickhack "
    .. "(Distract Enemies) alongside the glitch SFX; the previous station is restored when the "
    .. "hack ends."

---@param setup table?
---@return table
function soundSystem.normalizeSpeakerSetup(setup)
    local normalized = utils.deepcopy(type(setup) == "table" and setup or {})
    normalized["$type"] = "SpeakerSetup"

    local defaultMusic = tostring(normalized.defaultMusic or "")
    if stationIndexByEnum[defaultMusic] == nil then
        defaultMusic = "AGGRO_INDUSTRIAL"
    end
    normalized.defaultMusic = defaultMusic

    local distractionMusic = tostring(normalized.distractionMusic or "")
    if stationIndexByEnum[distractionMusic] == nil then
        distractionMusic = "METAL"
    end
    normalized.distractionMusic = distractionMusic

    normalized.range = math.max(0, tonumber(normalized.range) or 10)
    normalized.useOnlyGlitchSFX = boolToInt(normalized.useOnlyGlitchSFX, 0)

    if type(normalized.glitchSFX) ~= "table" then
        normalized.glitchSFX = {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = "dev_radio_ditraction_glitching"
        }
    else
        normalized.glitchSFX["$type"] = "CName"
        normalized.glitchSFX["$storage"] = "string"
        normalized.glitchSFX["$value"] = tostring(normalized.glitchSFX["$value"] or "None")
    end

    return normalized
end

---@param spawnData string?
---@return table?
function soundSystem.resolveMasterDefinition(spawnData)
    local key = MASTER_BY_SPAWNDATA[string.lower(tostring(spawnData or ""))]

    return key and soundSystem.MASTER_DEFINITIONS[key] or nil
end

---Master definitions in display order.
---@return table[]
function soundSystem.getMasterDefinitions()
    local definitions = {}

    for _, key in ipairs(soundSystem.MASTER_ORDER) do
        local definition = soundSystem.MASTER_DEFINITIONS[key]
        if definition then
            table.insert(definitions, definition)
        end
    end

    return definitions
end

---@param setup table?
---@return table
function soundSystem.normalizeComputerSetup(setup)
    local normalized = utils.deepcopy(type(setup) == "table" and setup or {})
    normalized["$type"] = "ComputerSetup"

    local startingMenu = tostring(normalized.startingMenu or "")
    if utils.indexValue(soundSystem.COMPUTER_MENUS, startingMenu) == -1 then
        startingMenu = "MAIN"
    end
    normalized.startingMenu = startingMenu

    for _, key in ipairs({ "mailsMenu", "filesMenu", "systemMenu", "internetMenu", "newsFeedMenu", "hideTopNavigationBar" }) do
        normalized[key] = boolToInt(normalized[key], 0)
    end

    return normalized
end

---Applies the sound-system terminal flags onto a computer setup, leaving everything else alone.
---@param setup table?
---@return table
function soundSystem.applyComputerTerminalPreset(setup)
    local normalized = soundSystem.normalizeComputerSetup(setup)

    for key, value in pairs(soundSystem.COMPUTER_TERMINAL_PRESET) do
        normalized[key] = value
    end

    return normalized
end

---True when a computer is already set up as a sound-system terminal.
---@param setup table?
---@return boolean
function soundSystem.isComputerTerminalPreset(setup)
    if type(setup) ~= "table" then
        return false
    end

    local normalized = soundSystem.normalizeComputerSetup(setup)

    for key, value in pairs(soundSystem.COMPUTER_TERMINAL_PRESET) do
        if normalized[key] ~= value then
            return false
        end
    end

    return true
end

---LocKey a station's name lives under, e.g. `LocKey#2122` for Attitude Rock. Used as the caption of
---a generated interaction record, so the button reads as the station name in every shipped language.
---@param enumName string?
---@return string?
function soundSystem.getStationCaptionLocKey(enumName)
    local index = stationIndexByEnum[tostring(enumName or "")]
    local station = index and soundSystem.STATIONS[index] or nil
    if not station then
        return nil
    end

    local displayName = readFlatAsText(station.record .. ".displayName")
    if type(displayName) == "string" and displayName:match("^LocKey#%d+$") then
        return displayName
    end

    return nil
end

---Caption an entry's generated record should carry: the station name for a radio entry, and nothing
---for a sound event, where no name exists to borrow.
---@param entry table Normalized entry
---@return string?
function soundSystem.getGeneratedCaptionFor(entry)
    if soundSystem.getEntrySource(entry) ~= "PlayRadio" then
        return nil
    end

    local data = entry.musicSettings and entry.musicSettings.Data or nil

    return soundSystem.getStationCaptionLocKey(data and data.radioStation)
end

---Escapes a value for a double quoted YAML scalar.
---@param value any
---@return string
local function yamlQuote(value)
    local text = tostring(value or "")
    text = text:gsub("\\", "\\\\"):gsub('"', '\\"')

    return '"' .. text .. '"'
end

---Builds a TweakXL `.yaml` defining the interaction records a project references but the game does
---not have. Records are emitted in the order given, so a re-export produces a stable file.
---@param records { id: string, caption: string?, name: string? }[]
---@param projectName string?
---@return string?
function soundSystem.buildInteractionTweak(records, projectName)
    if type(records) ~= "table" or #records == 0 then
        return nil
    end

    local lines = {
        "# Generated by World Builder for " .. tostring(projectName or "this project") .. ".",
        "# Drop this into r6/tweaks/ so the sound system buttons have captions.",
        "# Records already present in TweakDB are not listed here.",
        ""
    }

    for _, record in ipairs(records) do
        local id = utils.trimString(tostring(record.id or ""))
        if id ~= "" then
            local shortName = record.name
            if not shortName or shortName == "" then
                shortName = id:match("%.([^%.]+)$") or id
            end

            table.insert(lines, id .. ":")
            table.insert(lines, "  $type: gamedataInteractionBase_Record")
            table.insert(lines, "  action: Choice1")
            table.insert(lines, "  name: " .. yamlQuote(shortName))
            table.insert(lines, "  captionIcon: ChoiceCaptionParts.None")

            if record.caption and utils.trimString(tostring(record.caption)) ~= "" then
                table.insert(lines, "  caption: " .. yamlQuote(record.caption))
            end

            table.insert(lines, "")
        end
    end

    return table.concat(lines, "\n")
end

---Plays a sound event on the player, so the author can hear it without leaving the editor.
---@param eventName string?
---@return boolean played
function soundSystem.testSoundEvent(eventName)
    local normalized = utils.trimString(tostring(eventName or ""))
    if normalized == "" then
        return false
    end

    local ok = pcall(function ()
        GameObject.PlaySoundEvent(Game.GetPlayer(), normalized)
    end)

    return ok
end

---Drops the cached station labels, so a language change or a late TweakDB load is picked up.
function soundSystem.invalidateLabels()
    stationLabelCache = {}
    locKeyCache = {}
    interactionCaptionCache = {}
    interactionExistsCache = {}
end

return soundSystem
