"""Regenerates the audio datasets under `data/audio/` from the game's own audio tables.

Run this after a game update, or whenever the source tables change.

Step 1 - convert three archive files to WolvenKit JSON, into a working directory of your choice:

    base\\sound\\event\\eventsmetadata.json          ->  eventsmetadata.json
    base\\sound\\metadata\\cooked_metadata.audio_metadata  ->  cooked_base.json
    ep1\\sound\\metadata\\cooked_metadata.audio_metadata   ->  cooked_ep1.json

  Despite its extension, `eventsmetadata.json` is a CR2W wrapping a `JsonResource` whose root is an
  `audioAudioEventArray`, so it needs converting like the other two.

  Convert them on a CLEAN install. Radio mods ship their own `cooked_metadata.audio_metadata`, and
  a modded copy wins archive resolution - the dataset would then describe that install, not the game.

Step 2 - run this script:

    python build_audio_data.py <working directory>

What it writes:

  data/audio/soundEvents.json         every audio event the game knows, with the facts that decide
                                      how it behaves: `attenuation` (Wwise radius in metres, 0 means
                                      not positional), `looping`, `duration`. Events the Sounds
                                      browser offers also carry `tags`, the filter vocabulary.
                                      The full set is needed because the instance-data editor
                                      annotates audio fields on any component, not only emitters.
  data/audio/emitterMetadata.json     every valid `emitterMetadataName`, i.e. every entry deriving
                                      from `audioEmitterMetadata`, base and EP1 merged.
  data/audio/audioVocabularies.json   the closed name sets behind Reverb, Metadata Parent,
                                      Parameters, and the radio tables.
  data/spawnables/visual/sounds/...   the Sounds browser list, regenerated from the same set.

Nothing already listed is dropped: the event list is the union of what the metadata says is valid
and whatever the previous list held, so an event CDPR placed but the tables disagree with survives.
"""
import collections
import io
import json
import os
import sys

# Repo root, two levels up from script/audio/.
MOD = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
AUDIO = os.path.join(MOD, "data", "audio")
SOUND_LIST = os.path.join(MOD, "data", "spawnables", "visual", "sounds", "sounds.txt")

# A tag must describe at least this many listed events to be offered as a browser filter, which
# keeps the ~830 raw tags down to a list somebody can actually scan.
TAG_MIN = 5

# Every class deriving from `audioEmitterMetadata`; the node's `emitterMetadataName` accepts any of
# them by name. Classes with no shipped entries are listed too, so a game update that adds one is
# picked up without editing this file.
EMITTER_CLASSES = {
    "audioAccumulatedSoundDecoratorMetadata", "audioAcousticsEmitterMetadata",
    "audioAdvertMetadata", "audioCompoundEmitterMetadata",
    "audioDistanceSoundDecoratorMetadata", "audioDoorDecoratorMetadata",
    "audioGroupingCountableMetadata", "audioLocomotionEmitterMetadata",
    "audioLoopedSoundEmitterMetadata", "audioParamMixerDecoratorMetadata",
    "audioPlaylistEmitterMetadata", "audioShockwaveMetadata",
    "audioVehicleNpcOcclusionMetadata",
}

value = lambda x: x["$value"] if isinstance(x, dict) else x


def load(path):
    # WolvenKit writes a BOM.
    with io.open(path, encoding="utf-8-sig") as handle:
        return json.load(handle)


def scalars(entry):
    """Keeps an entry's scalar and CName fields; nested structs are not useful in a tooltip."""
    out = {}
    for key, field in entry.items():
        if key in ("$type", "name"):
            continue
        if isinstance(field, dict) and field.get("$type") == "CName":
            if value(field) != "None":
                out[key] = value(field)
        elif isinstance(field, (int, float, str)):
            out[key] = field
    return out


def main(work):
    events_root = load(os.path.join(work, "eventsmetadata.json"))["Data"]["RootChunk"]["root"]["Data"]

    entries = []
    for name in ("cooked_base.json", "cooked_ep1.json"):
        entries += [e["Data"] for e in load(os.path.join(work, name))["Data"]["RootChunk"]["entries"]]

    # ---- events ---------------------------------------------------------------------------------
    meta = {}
    for event in events_root["events"]:
        meta.setdefault(value(event["redId"]), event)

    # An emitter only keeps playing a looping, positional event. Out of 3,519 shipped emitters
    # carrying one event, exactly one breaks each half of that rule.
    usable = {n for n, e in meta.items() if e["isLooping"] and e["maxAttenuation"] > 0}

    previous = [l.strip() for l in io.open(SOUND_LIST, encoding="utf-8") if l.strip()] \
        if os.path.exists(SOUND_LIST) else []
    names = sorted(usable | set(previous))

    tag_count = collections.Counter()
    for name in names:
        for tag in meta.get(name, {}).get("tags", []):
            tag_count[value(tag)] += 1
    tags = sorted(t for t, c in tag_count.items() if c >= TAG_MIN)
    tag_set = set(tags)
    tag_set_owners = set(names)

    # Every event the game knows, not only the ones the Sounds browser offers: the instance-data
    # editor annotates audio fields on any component, and a door's `openEvent` is a one-shot that
    # would never appear in an emitter list.
    events = {}
    for name in sorted(set(meta) | set(names)):
        event = meta.get(name)
        if event is None:
            # Referenced by shipped world data but absent from the audio tables.
            events[name] = {"attenuation": 0, "looping": False, "unknown": True}
            continue

        out = {"attenuation": round(event["maxAttenuation"], 2),
               "looping": bool(event["isLooping"])}
        # Duration is only trustworthy when non-zero: the cooker leaves it at 0 both for loops and
        # for one-shots it could not measure.
        if not event["isLooping"] and event["maxDuration"] > 0:
            out["duration"] = round(event["maxDuration"], 3)
        # Tags are only carried for events the browser lists, since that is the only place they are
        # used as a filter, and carrying all of them would double the file.
        if name in tag_set_owners:
            kept = [value(t) for t in event["tags"] if value(t) in tag_set]
            if kept:
                out["tags"] = kept
        events[name] = out

    # ---- cooked metadata ------------------------------------------------------------------------
    emitter_metadata = {}
    for entry in entries:
        if entry["$type"] in EMITTER_CLASSES and "name" in entry:
            emitter_metadata[value(entry["name"])] = dict(
                # Trimmed of the `audio` prefix; `audioData.lua` maps it to a display label.
                {"class": entry["$type"][5:]}, **scalars(entry))

    def named(class_name):
        return sorted({value(e["name"]) for e in entries
                       if e["$type"] == class_name and "name" in e})

    vocabularies = {
        # `Reverb` takes these base names; the engine appends a size suffix at runtime.
        "reverbs": named("audioDynamicReverbSettings"),
        # `MetadataParent` inherits one of these interior presets.
        "ambientAreaPresets": named("audioAmbientAreaSettings"),
        # `Parameters[].name` - Wwise RTPCs.
        "gameParameters": sorted({value(p["redId"]) for p in events_root["gameParameter"]}),
        "acousticZones": named("audioAcousticZoneMetadata"),
        "playlists": named("audioPlaylistMetadata"),
        "radioStations": named("audioRadioStationMetadata"),
        # `worldAudioAttractAreaNode.audioAttractSoundSettings[].sounds`.
        "attractAreas": named("audioAudioAttractAreaSounds"),
        # `ambientPaletteTag` on emitters, and the palette exclusion area.
        "ambientPalettes": named("audioAmbientPaletteBrushCategory"),
    }

    # ---- write ----------------------------------------------------------------------------------
    def dump(path, data, indent):
        with io.open(path, "w", encoding="utf-8") as handle:
            # Compact where the file is machine-sized; readable where a human might scan it.
            separators = (",", ":") if indent is None else None
            json.dump(data, handle, indent=indent, separators=separators, sort_keys=True)

    dump(os.path.join(AUDIO, "soundEvents.json"), {"events": events, "tags": tags}, None)
    dump(os.path.join(AUDIO, "emitterMetadata.json"), emitter_metadata, 0)
    dump(os.path.join(AUDIO, "audioVocabularies.json"), vocabularies, 1)

    with io.open(SOUND_LIST, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(names) + "\n")

    print(f"soundEvents.json       {len(events)} events ({len(usable)} looping + positional, {len(names)} offered), {len(tags)} tags")
    print(f"emitterMetadata.json   {len(emitter_metadata)} names "
          f"{dict(collections.Counter(e['class'] for e in emitter_metadata.values()).most_common())}")
    for key, entry in vocabularies.items():
        print(f"  {key:20s} {len(entry)}")
    print(f"sounds.txt             {len(names)} lines (was {len(previous)})")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
