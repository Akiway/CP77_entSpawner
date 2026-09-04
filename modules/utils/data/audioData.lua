local cache = require("modules/utils/game/cache")

---Lookups over the shipped audio metadata.
---
---Backed by three generated datasets in `data/audio/`, extracted from the game's own tables:
---`base\sound\event\eventsmetadata.json` (the `audioAudioEventArray`) for per-event facts, and the
---base + EP1 `cooked_metadata.audio_metadata` files for the named presets. Everything here is a
---plain read of that data; nothing is guessed.
---
---What the numbers mean, and why the spawnables lean on them:
--- * `looping` — the event starts something continuous. A `worldStaticSoundEmitterNode` fires its
---   event once when it streams in, so a one-shot plays for its duration and then leaves silence.
---   Out of 3,519 shipped emitters carrying a single event, exactly one uses a non-looping event.
--- * `attenuation` — the Wwise attenuation radius in metres. `0` means the event is not positional:
---   it feeds a bus at a fixed level and ignores where the emitter sits. Again, exactly one shipped
---   emitter out of 3,519 uses such an event.
--- * Shipped emitters set `radius` to the event's own attenuation in 79% of cases, and the median
---   `radius / attenuation` ratio is exactly 1.00 — which is why a fresh emitter seeds its radius
---   from the event rather than from a fixed number.
---@class audioData
local audioData = {}

---Shorthand shown after an emitter-metadata name, keyed by the class the entry came from.
---The class decides what selecting the name actually does, so it is worth surfacing.
local emitterClassLabels = {
    AcousticsEmitterMetadata = "Acoustics",
    PlaylistEmitterMetadata = "Playlist",
    CompoundEmitterMetadata = "Compound",
    DistanceSoundDecoratorMetadata = "Distance",
    DoorDecoratorMetadata = "Door",
    AdvertMetadata = "Advert",
    ShockwaveMetadata = "Shockwave",
    LocomotionEmitterMetadata = "Locomotion",
    AccumulatedSoundDecoratorMetadata = "Accumulated",
    GroupingCountableMetadata = "Grouping",
    VehicleNpcOcclusionMetadata = "Vehicle occlusion"
}

---One-line explanation of each emitter-metadata class, for the selector tooltip.
local emitterClassNotes = {
    AcousticsEmitterMetadata = "Occlusion / obstruction / doppler preset. The usual choice for a plain emitter.",
    PlaylistEmitterMetadata = "Turns the emitter into a radio source playing a named playlist.",
    CompoundEmitterMetadata = "Groups several child emitters under one name.",
    DistanceSoundDecoratorMetadata = "Fires enter / leave events at a trigger distance.",
    DoorDecoratorMetadata = "Open and close loops with timings, for door-shaped emitters.",
    AdvertMetadata = "Advert scheduling: distance and silence between reads.",
    ShockwaveMetadata = "Shockwave propagation settings.",
    LocomotionEmitterMetadata = "Locomotion-driven emitter.",
    AccumulatedSoundDecoratorMetadata = "Collapses repeated sounds into a spam-limited loop.",
    GroupingCountableMetadata = "Counts grouped emitters into an RTPC.",
    VehicleNpcOcclusionMetadata = "Occlusion handling for NPCs inside vehicles."
}

---Selector ordering: the classes a user is likely to want first, then everything else.
local emitterClassOrder = {
    AcousticsEmitterMetadata = 1,
    PlaylistEmitterMetadata = 2,
    CompoundEmitterMetadata = 3,
    DistanceSoundDecoratorMetadata = 4,
    DoorDecoratorMetadata = 5,
    AdvertMetadata = 6
}

---Field order used when describing an emitter-metadata entry, so tooltips read consistently.
local emitterFieldOrder = {
    "occlusionEnabled", "obstuctionEnabled", "ignoreOcclusionRadius", "obstructionFadeTime",
    "repositioningEnabled", "elevateSource", "enableOutdoorness", "leakingFloorHack",
    "dopplerParameter", "postDopplerFactor",
    "playlistMetadataName", "receiverType",
    "triggerDistance", "onEnter", "onLeave", "stopOnlyVirtualSounds",
    "openLoop", "openTime", "closeLoop", "closeTime",
    "minDistance", "minSilenceTime", "maxSilenceTime", "filter"
}

local emitterNames = nil
local emitterLabels = nil
local emitterTooltips = nil
local emitterEventNames = nil
local allEventNames = nil
local oneShotEventNames = nil

---Formats a number without a trailing `.0`, so `3` reads as `3` and `0.2` as `0.2`.
---@param value number
---@return string
local function formatNumber(value)
    if value == math.floor(value) then
        return string.format("%d", value)
    end

    return (string.format("%.3f", value):gsub("0+$", ""):gsub("%.$", ""))
end

--- Events ---------------------------------------------------------------------------------------

---Metadata for one audio event.
---@param name string? Event name (`CName` value).
---@return { attenuation: number, looping: boolean, duration: number?, tags: string[]?, unknown: boolean? }? event
function audioData.getEvent(name)
    if not name or name == "" then return nil end

    local events = cache.staticData.soundEvents
    if type(events) ~= "table" then return nil end

    return events[name]
end

---Attenuation radius of an event, in metres.
---@param name string? Event name.
---@return number? attenuation `nil` when the event is unknown or not positional.
function audioData.getEventAttenuation(name)
    local event = audioData.getEvent(name)
    if not event then return nil end

    local attenuation = tonumber(event.attenuation) or 0
    if attenuation <= 0 then return nil end

    return attenuation
end

---Whether an event will actually keep playing on a static emitter.
---@param name string? Event name.
---@return boolean usable True only for looping events with a non-zero attenuation.
function audioData.isEmitterUsable(name)
    local event = audioData.getEvent(name)

    return event ~= nil and event.looping == true and (tonumber(event.attenuation) or 0) > 0
end

---Tags an event carries, i.e. the Wwise authoring hierarchy it sits in.
---@param name string? Event name.
---@return string[] tags Empty when the event is unknown or untagged.
function audioData.getEventTags(name)
    local event = audioData.getEvent(name)

    return (event and event.tags) or {}
end

---The tag vocabulary offered as a browser filter.
---Only tags describing at least a handful of listed events are kept, so the list stays readable.
---@return string[] tags
function audioData.getEventTagList()
    local tags = cache.staticData.soundEventTags

    return type(tags) == "table" and tags or {}
end

---Every audio event the game knows, sorted. Used where the field is not an emitter: a door's
---`openEvent` is a one-shot and would never appear in the emitter list.
---@return string[] names
function audioData.getAllEventNames()
    if allEventNames then return allEventNames end

    allEventNames = {}

    local events = cache.staticData.soundEvents
    if type(events) == "table" then
        for name in pairs(events) do
            table.insert(allEventNames, name)
        end
    end

    table.sort(allEventNames)

    return allEventNames
end

---Every event that keeps playing on a positional emitter, sorted.
---These are the only events worth offering for a static emitter or an ambient area's active events.
---@return string[] names
function audioData.getEmitterEventNames()
    if emitterEventNames then return emitterEventNames end

    emitterEventNames = {}

    local events = cache.staticData.soundEvents
    if type(events) == "table" then
        for name, event in pairs(events) do
            if event.looping == true and (tonumber(event.attenuation) or 0) > 0 then
                table.insert(emitterEventNames, name)
            end
        end
    end

    table.sort(emitterEventNames)

    return emitterEventNames
end

---Every event that ends on its own, sorted.
---
---For a field that fires an event and never stops it -- a transform animation's sound track, a
---one-off device operation -- a looping event is a trap: it starts and keeps going with nothing left
---holding a handle to stop it. Events with no metadata are kept, since nothing says they loop and
---they are referenced by shipped data; `describeEvent` marks them as unknown.
---@return string[] names
function audioData.getOneShotEventNames()
    if oneShotEventNames then return oneShotEventNames end

    oneShotEventNames = {}

    local events = cache.staticData.soundEvents
    if type(events) == "table" then
        for name, event in pairs(events) do
            if event.looping ~= true then
                table.insert(oneShotEventNames, name)
            end
        end
    end

    table.sort(oneShotEventNames)

    return oneShotEventNames
end

---Short muted summary of an event, for the line under the selector.
---@param name string? Event name.
---@return string summary Empty when nothing is known about the event.
function audioData.describeEvent(name)
    local event = audioData.getEvent(name)
    if not event then return "" end

    if event.unknown then
        return "No metadata - this event is referenced by shipped data but missing from the audio tables"
    end

    local parts = {}
    table.insert(parts, event.looping and "Looping" or "One-shot")

    local duration = tonumber(event.duration)
    if not event.looping and duration and duration > 0 then
        table.insert(parts, string.format("%ss", formatNumber(duration)))
    end

    local attenuation = tonumber(event.attenuation) or 0
    if attenuation > 0 then
        table.insert(parts, string.format("%sm range", formatNumber(attenuation)))
    else
        table.insert(parts, "not positional")
    end

    local tags = event.tags
    if tags and #tags > 0 then
        table.insert(parts, table.concat(tags, ", "))
    end

    return table.concat(parts, "  |  ")
end

---Compact, context-neutral summary of an event: what it is, without judging whether it suits an
---emitter. A one-shot is the right answer for a door's `openEvent`, so nothing is flagged here.
---@param name string? Event name.
---@return string note Empty when the event is unknown.
function audioData.getEventShortNote(name)
    local event = audioData.getEvent(name)
    if not event then return "" end
    if event.unknown then return "no metadata" end

    local parts = {}

    if event.looping then
        table.insert(parts, "loop")
    else
        local duration = tonumber(event.duration)
        table.insert(parts, (duration and duration > 0) and (formatNumber(duration) .. "s") or "one-shot")
    end

    local attenuation = tonumber(event.attenuation) or 0
    table.insert(parts, attenuation > 0 and (formatNumber(attenuation) .. "m") or "2D")

    return table.concat(parts, ", ")
end

---Annotation for one row of the Sounds browser: the event's range, or a warning when it will not
---keep playing on an emitter. Range is the fact worth seeing while choosing, because it separates a
---5 m interior hum from a 130 m city element long before either is placed.
---@param name string? Event name.
---@return { text: string, tooltip: string, warn: boolean? }? note `nil` when there is nothing to say.
function audioData.getEventRowNote(name)
    local event = audioData.getEvent(name)
    if not event then return nil end

    local warning = audioData.getEmitterWarning(name)
    if warning then
        return { text = IconGlyphs.AlertOutline, tooltip = warning, warn = true }
    end

    local attenuation = tonumber(event.attenuation) or 0
    if attenuation <= 0 then return nil end

    return { text = formatNumber(attenuation) .. "m", tooltip = audioData.describeEvent(name) }
end

---Why an event will not behave on a static emitter, if it will not.
---@param name string? Event name.
---@return string? warning `nil` when the event is fine, or unknown to the metadata.
function audioData.getEmitterWarning(name)
    local event = audioData.getEvent(name)
    if not event or event.unknown then return nil end

    if not event.looping then
        return "This event is a one-shot. An emitter fires its event once when it streams in, so this plays through and then goes silent."
    end

    if (tonumber(event.attenuation) or 0) <= 0 then
        return "This event has no attenuation, so it is not positional: it plays at a fixed level regardless of where the emitter sits, or feeds a bus and is inaudible."
    end

    return nil
end

--- Emitter metadata -----------------------------------------------------------------------------

---Raw entry behind an `emitterMetadataName` value.
---@param name string? Metadata name.
---@return table? entry Carries `class` plus that class's scalar fields.
function audioData.getEmitterMetadata(name)
    if not name or name == "" then return nil end

    local all = cache.staticData.emitterMetadata
    if type(all) ~= "table" then return nil end

    return all[name]
end

---Builds the sorted selector list and its label / tooltip maps, once.
local function buildEmitterLists()
    if emitterNames then return end

    emitterNames = {}
    emitterLabels = {}
    emitterTooltips = {}

    local all = cache.staticData.emitterMetadata
    if type(all) ~= "table" then return end

    for name, entry in pairs(all) do
        table.insert(emitterNames, name)

        local class = entry.class or ""
        local classLabel = emitterClassLabels[class] or class
        emitterLabels[name] = classLabel ~= "" and string.format("%s  (%s)", name, classLabel) or name

        local lines = {}
        local note = emitterClassNotes[class]
        if note then
            table.insert(lines, note)
        end

        -- Ordered fields first, so comparable presets line up; anything unlisted follows.
        local seen = {}
        for _, field in ipairs(emitterFieldOrder) do
            local value = entry[field]
            if value ~= nil then
                seen[field] = true
                table.insert(lines, string.format("%s: %s", field,
                    type(value) == "number" and formatNumber(value) or tostring(value)))
            end
        end

        local rest = {}
        for field, value in pairs(entry) do
            if field ~= "class" and not seen[field] then
                table.insert(rest, string.format("%s: %s", field,
                    type(value) == "number" and formatNumber(value) or tostring(value)))
            end
        end
        table.sort(rest)
        for _, line in ipairs(rest) do
            table.insert(lines, line)
        end

        emitterTooltips[name] = table.concat(lines, "\n")
    end

    table.sort(emitterNames, function (a, b)
        local orderA = emitterClassOrder[all[a].class or ""] or 99
        local orderB = emitterClassOrder[all[b].class or ""] or 99
        if orderA ~= orderB then
            return orderA < orderB
        end

        return a < b
    end)
end

---Every valid `emitterMetadataName` value, ordered by how likely it is to be wanted.
---@return string[] names
function audioData.getEmitterMetadataNames()
    buildEmitterLists()

    return emitterNames
end

---Selector label for one metadata name, e.g. `..._ignore_3m  (Acoustics)`.
---@param name string
---@return string label
function audioData.getEmitterMetadataLabel(name)
    buildEmitterLists()

    return emitterLabels[name] or name
end

---Selector tooltip listing what the preset actually sets.
---@param name string
---@return string? tooltip
function audioData.getEmitterMetadataTooltip(name)
    buildEmitterLists()

    return emitterTooltips[name]
end

--- Vocabularies ---------------------------------------------------------------------------------

---Closed name set for a field that only accepts entries from the cooked metadata.
---@param key "reverbs"|"ambientAreaPresets"|"gameParameters"|"acousticZones"|"playlists"|"radioStations"|"attractAreas"|"ambientPalettes"
---@return string[] names
function audioData.getVocabulary(key)
    local vocab = cache.staticData.audioVocabularies
    if type(vocab) ~= "table" then return {} end

    local list = vocab[key]

    return type(list) == "table" and list or {}
end

---Merges name lists into one sorted, deduplicated selector list, dropping blanks and `None`.
---@param ... string[] Lists to merge, in order of authority.
---@return string[] names
function audioData.mergeNames(...)
    local merged = {}
    local seen = {}

    for _, list in ipairs({ ... }) do
        for _, name in ipairs(list or {}) do
            if name ~= "" and name ~= "None" and not seen[name] then
                seen[name] = true
                table.insert(merged, name)
            end
        end
    end

    table.sort(merged)

    return merged
end

---Merges a closed vocabulary with names harvested from shipped world data.
---The vocabulary is authoritative, but a harvested name that is missing from it is still something
---CDPR shipped, so it is kept rather than hidden.
---@param key string Vocabulary key, see `audioData.getVocabulary`.
---@param harvested string[]? Names collected from sector data.
---@return string[] names
function audioData.getMergedVocabulary(key, harvested)
    return audioData.mergeNames(audioData.getVocabulary(key), harvested)
end

--- Audio fields on arbitrary instance data ------------------------------------------------------
--
-- Audio fields are plain `CName` everywhere in the engine, so the generic instance-data editor draws
-- them as free text: the names are not guessable and a wrong one is silently dropped. What kind of
-- name a field wants is encoded only in its name and its owning class, so that is what is matched
-- here. Recognition is deliberately conservative - being wrong costs a needless dropdown, but the
-- selectors all allow a custom value, so nothing becomes uneditable.

---Property names whose vocabulary is known exactly, on any class.
---@type table<string, string>
local fieldKindsByName = {
    -- Named entries in the cooked metadata.
    emitterMetadataName = "emitterMetadata",
    EmitterDecorator = "emitterMetadata",
    emitterDecoratorMetadata = "emitterMetadata",
    defaultEmitterName = "emitterMetadata",
    trafficEmitterMetadata = "emitterMetadata",
    Reverb = "reverb",
    MetadataParent = "ambientAreaPreset",
    playlistMetadataName = "playlist",
    -- Sound events, named unambiguously.
    event = "event",
    soundName = "event",
    soundEvent = "event",
    audioEvent = "event",
    audioEventName = "event",
    soundEventName = "event",
    loopSound = "event",
    loopAudioEvent = "event",
    spammingSound = "event",
    reflectionEvent = "event",
    trackEventName = "event",
    blipEventName = "event",
    voEventOverride = "event",
    -- `SSFXOperationData.sfxName`, fed straight to `GameObject.PlaySound` / `StopSound`. Named
    -- against the suffix rules below (it ends in `Name`, not in `Sound`), so it needs the exact entry.
    sfxName = "event"
}

---Never treated as audio, despite matching a rule below: these carry a different vocabulary.
---`audioTag` is the clearest trap - it is a material tag on `CMaterialInstance`, a grouping tag on
---`gameaudioeventsPlaySound`, and a radio cue on `worldAudioTagNode`, all with different values.
---@type table<string, boolean>
local fieldKindDenyList = {
    audioTag = true,
    soundBank = true,
    revSoundbankName = true,
    revElectricSoundbankName = true,
    reverbSoundbankName = true,
    interiorReverbBus = true,
    audioMetadata = true,
    audioMetadataName = true,
    voiceTag = true,
    voiceTagName = true,
    voTrigger = true,
    voTriggerVariations = true,
    eventName = true,
    eventAction = true,
    eventSource = true,
    eventGenerate = true,
    eventReceive = true,
    eventExecutionTag = true,
    emitter = true,
    emitterName = true,
    EmitterName = true,
    inputEmitterName = true,
    -- A gameplay event name, not a Wwise one, despite sitting on an `audio*` class.
    gameplayEvent = true
}

---Suffixes that mark a `CName` as a sound event. `Event` alone is far too common outside audio
---(anim graphs, quest nodes, particle systems), so it only counts on an `audio*` class - where every
---such property in the shipped class dump genuinely is one.
local eventSuffixesAnywhere = { "Sound", "SFX", "Sfx", "AudioEvent", "SoundEvent" }
local eventSuffixesOnAudioClass = { "Event" }

---@param name string
---@param suffix string
---@return boolean
local function endsWith(name, suffix)
    return #name >= #suffix and name:sub(-#suffix) == suffix
end

---What kind of audio name a property wants, if any.
---@param propertyName string? Property key as it appears in the instance data.
---@param ownerClass string? `$type` of the struct the property sits on.
---@return "event"|"emitterMetadata"|"reverb"|"ambientAreaPreset"|"playlist"|nil kind
function audioData.getFieldKind(propertyName, ownerClass)
    local name = tostring(propertyName or "")
    if name == "" or fieldKindDenyList[name] then return nil end

    local exact = fieldKindsByName[name]
    if exact then return exact end

    for _, suffix in ipairs(eventSuffixesAnywhere) do
        if endsWith(name, suffix) then return "event" end
    end

    if type(ownerClass) == "string" and ownerClass:sub(1, 5) == "audio" then
        for _, suffix in ipairs(eventSuffixesOnAudioClass) do
            if endsWith(name, suffix) then return "event" end
        end
    end

    return nil
end

---Selector configuration for one field kind.
---@param kind string
---@return { options: string[], hint: string, tooltip: string, displayFn: function?, tooltipFn: function?, matchWidth: boolean? }? config
function audioData.getFieldSelector(kind)
    if kind == "event" then
        return {
            options = audioData.getAllEventNames(),
            hint = "Search sound event...",
            tooltip = "Wwise audio event. Hover an entry for whether it loops, how long it lasts and how far it carries.",
            tooltipFn = audioData.describeEvent
        }
    elseif kind == "emitterMetadata" then
        return {
            options = audioData.getEmitterMetadataNames(),
            hint = "Search preset...",
            tooltip = "Named emitter preset from the cooked audio metadata.",
            displayFn = audioData.getEmitterMetadataLabel,
            tooltipFn = audioData.getEmitterMetadataTooltip,
            matchWidth = true
        }
    elseif kind == "reverb" then
        return {
            options = audioData.getVocabulary("reverbs"),
            hint = "Search reverb...",
            tooltip = "Reverb preset. Base name only - the engine appends the size suffix at runtime.",
            matchWidth = true
        }
    elseif kind == "ambientAreaPreset" then
        return {
            options = audioData.getVocabulary("ambientAreaPresets"),
            hint = "Search preset...",
            tooltip = "Ambient area preset to inherit settings from.",
            matchWidth = true
        }
    elseif kind == "playlist" then
        return {
            options = audioData.getVocabulary("playlists"),
            hint = "Search playlist...",
            tooltip = "Radio playlist from the cooked audio metadata.",
            matchWidth = true
        }
    end

    return nil
end

---Drops the cached selector lists, so a data reload is picked up.
function audioData.invalidate()
    emitterNames = nil
    emitterLabels = nil
    emitterTooltips = nil
    emitterEventNames = nil
    allEventNames = nil
    oneShotEventNames = nil
end

return audioData
