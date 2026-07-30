// @author Akiway
// @version 1.0.0
//
// @description
// Full survey of worldPhysicalDestructionNode and worldBakedDestructionNode across the
// shipped streamingsectors, the same treatment worldInstancedDestructibleMeshNode got in
// extract_destructible_node_usage.wscript. Companion to probe_destruction_nodes.wscript,
// which established that these two are the only other destruction nodes worth authoring.
//
// Outputs (relative to the active project `resources` folder):
//   reports/destruction_node_usage.json
//       -> value histogram per property, per class, plus preset/mask combinations
//   data/spawnables/mesh/physicalDestruction/paths_physical_destruction.txt
//   data/spawnables/mesh/bakedDestruction/paths_baked_destruction.txt
//       -> the meshes each node class is actually placed with, one spawn list each
//   data/static/physical_destruction_mesh_defaults.json
//   data/static/baked_destruction_mesh_defaults.json
//       -> mesh path -> the settings most commonly used with that mesh
//   data/static/destruction_effects.json
//       -> the .effect paths used as fracturingEffect / destructionEffect
//   data/static/destruction_filter_presets.json
//       -> preset -> masks, to check against the existing destructible_filter_presets.json
//
// IMPORTANT, on the two spawn lists: `config.loadLists` merges every .txt in a folder
// into one spawn list with no dedup, so each of these must end up in its own folder in
// the mod. Do not drop them next to paths_destructible.txt.
//
// Long run over ~26k sectors, resumable: the sector list and the running state are cached
// in resources and saved every `saveEvery` sectors. Set `limit` to a few hundred for a
// first pass.

const settings = {
    candidateCachePathInResources: "reports/destruction_sectors_candidates.txt",
    statePathInResources: "reports/destruction_node_usage_state.json",

    reportPathInResources: "reports/destruction_node_usage.json",
    physicalPathsInResources: "data/spawnables/mesh/physicalDestruction/paths_physical_destruction.txt",
    bakedPathsInResources: "data/spawnables/mesh/bakedDestruction/paths_baked_destruction.txt",
    physicalDefaultsInResources: "data/static/physical_destruction_mesh_defaults.json",
    bakedDefaultsInResources: "data/static/baked_destruction_mesh_defaults.json",
    effectsPathInResources: "data/static/destruction_effects.json",
    presetsPathInResources: "data/static/destruction_filter_presets.json",

    // Optional cross check. Written by extract_destructible_meshes.wscript, it holds the
    // meshes carrying destruction parameters. The probe suggested it is the eligibility
    // signal for physical destruction meshes and for baked fractured meshes. Skipped when
    // the file is not in the project resources.
    destructionMeshListInResources: "data/static/destructible_meshes_destruction.txt",

    resumeFromExisting: true,
    forceRebuild: false,

    // 1 = every sector. Raise to sample, e.g. 5 scans a fifth of them.
    sectorStride: 1,

    // 0 = no limit. Set to e.g. 300 for a first pass.
    limit: 0,

    // Value histograms stop collecting new distinct values past this, remaining ones are
    // counted under "<other>". Keeps per instance values like autohide distances bounded.
    maxDistinctValuesPerProperty: 120,

    // Destruction levels read per node. The probe saw 2 to 4, this is headroom.
    maxDestructionLevels: 8,

    progressEvery: 200,
    saveEvery: 2000
};

///Each of these properties is declared on exactly one world node class, checked against
///the type dump. Reflection is blocked in this engine, GetType() is not usable, so
///HasProperty on the signature is how the node class is identified.
const PHYSICAL = "worldPhysicalDestructionNode";
const BAKED = "worldBakedDestructionNode";

const PHYSICAL_SIGNATURE = "destructionParams";
const BAKED_SIGNATURE = "meshFractured";

///Read for every physical destruction node. Paths with dots are nested lookups.
///Everything the probe measured, including the properties that looked invariant over its
///1099 node sample, so a full pass can confirm them before World Builder hardcodes them.
const PHYSICAL_PROPERTIES = [
    "meshAppearance",
    "forceLODLevel",
    "forceAutoHideDistance",
    "audioMetadata",
    "useMeshNavmeshSettings",
    "navigationSetting.navmeshImpact",
    "systemsToNotifyFlags",
    "isVisibleInGame",
    "isHostOnly",
    "tag",
    "tagExt",
    "destructionParams.startInactive",
    "destructionParams.simulationType",
    "destructionParams.markEdgeChunks",
    "destructionParams.useAggregatesForClusters",
    "destructionParams.turnDynamicOnImpulse",
    "destructionParams.buildConvexForClusters",
    "destructionParams.damageThreshold",
    "destructionParams.damageEndurance",
    "destructionParams.bondEndurance",
    "destructionParams.accumulateDamage",
    "destructionParams.enableImpulseDamage",
    "destructionParams.impulseToDamage",
    "destructionParams.contactToDamage",
    "destructionParams.maxContactImpulseRatio",
    "destructionParams.impulseChildPropagationFactor",
    "destructionParams.impulsePropagationFactor",
    "destructionParams.impulseDiminishingFactor",
    "destructionParams.breakBonds",
    "destructionParams.debrisInstantRemovalThreshold",
    "destructionParams.debrisTimeoutThreshold",
    "destructionParams.debrisTimeout",
    "destructionParams.debrisTimeoutMin",
    "destructionParams.debrisTimeoutMax",
    "destructionParams.fadeOutTime",
    "destructionParams.debrisMaxSeparation",
    "destructionParams.visualsRemain",
    "destructionParams.debrisDestructible",
    "destructionParams.supportDamage",
    "destructionParams.maxAngularVelocity",
    "destructionParams.fractureFieldMask"
];

///Read for every baked destruction node.
const BAKED_PROPERTIES = [
    "meshAppearance",
    "meshFracturedAppearance",
    "numFrames",
    "frameRate",
    "playOnlyOnce",
    "restartOnTrigger",
    "disableCollidersOnTrigger",
    "filterDataSource",
    "filterData.preset",
    "damageThreshold",
    "damageEndurance",
    "impulseToDamage",
    "contactToDamage",
    "accumulateDamage",
    "fractureFieldMask",
    "audioMetadata",
    "useMeshNavmeshSettings",
    "navigationSetting.navmeshImpact",
    "forceAutoHideDistance",
    "occluderType",
    "occluderAutohideDistanceScale",
    "castShadows",
    "castLocalShadows",
    "castRayTracedGlobalShadows",
    "castRayTracedLocalShadows",
    "windImpulseEnabled",
    "removeFromRainMap",
    "renderSceneLayerMask",
    "lodLevelScales",
    "version",
    "isVisibleInGame",
    "isHostOnly",
    "tag",
    "tagExt"
];

///Recorded per mesh so World Builder can pre-fill a newly placed node. Both classes use
///only a few hundred distinct meshes, so unlike the instanced node there is no reason to
///trim this down for file size.
const PHYSICAL_DEFAULT_PROPERTIES = [
    "audioMetadata",
    "forceAutoHideDistance",
    "navigationSetting.navmeshImpact",
    "destructionParams.startInactive",
    "destructionParams.simulationType",
    "destructionParams.markEdgeChunks",
    "destructionParams.useAggregatesForClusters",
    "destructionParams.turnDynamicOnImpulse",
    "destructionParams.buildConvexForClusters",
    "destructionParams.damageThreshold",
    "destructionParams.damageEndurance",
    "destructionParams.bondEndurance",
    "destructionParams.accumulateDamage",
    "destructionParams.impulseToDamage",
    "destructionParams.contactToDamage",
    "destructionParams.impulseChildPropagationFactor",
    "destructionParams.impulsePropagationFactor",
    "destructionParams.impulseDiminishingFactor",
    "destructionParams.breakBonds",
    "destructionParams.debrisTimeout",
    "destructionParams.debrisTimeoutMin",
    "destructionParams.debrisTimeoutMax",
    "destructionParams.debrisMaxSeparation",
    "destructionParams.visualsRemain",
    "destructionParams.supportDamage",
    "destructionParams.fractureFieldMask"
];

const BAKED_DEFAULT_PROPERTIES = [
    "meshFracturedAppearance",
    "numFrames",
    "frameRate",
    "playOnlyOnce",
    "restartOnTrigger",
    "disableCollidersOnTrigger",
    "filterData.preset",
    "damageThreshold",
    "damageEndurance",
    "impulseToDamage",
    "contactToDamage",
    "accumulateDamage",
    "fractureFieldMask",
    "audioMetadata",
    "navigationSetting.navmeshImpact",
    "occluderType",
    "castShadows",
    "castLocalShadows"
];

function logI(m) { try { logger.Info("[destruction-usage] " + m); } catch (_) {} }
function logW(m) { try { logger.Warning("[destruction-usage] " + m); } catch (_) {} }
function logE(m) { try { logger.Error("[destruction-usage] " + m); } catch (_) {} }

function normPath(p) {
    return String(p || "").trim().replace(/\//g, "\\");
}

///CFloat.ToString() follows the current culture, which may render 147.26 as "147,268112".
function normalizeNumberText(text) {
    const value = String(text);
    if (/^-?\d+,\d+$/.test(value)) {
        return value.replace(",", ".");
    }
    return value;
}

///Reads any RED value as text. Reflection is blocked, but ToString() is a plain method
///call and CName/ResourcePath expose GetResolvedText().
function readValue(value) {
    if (value === null || value === undefined) {
        return null;
    }
    try {
        const text = value.GetResolvedText();
        if (text !== undefined && text !== null) {
            return String(text);
        }
    } catch (_) {}
    try {
        const text = value.ToString();
        if (text !== undefined && text !== null) {
            return normalizeNumberText(text);
        }
    } catch (_) {}
    return null;
}

///Depot path of a raRef/rRef value, empty string when unset.
function readReference(value) {
    if (value === null || value === undefined) {
        return "";
    }
    try {
        if (value.IsSet === false) {
            return "";
        }
    } catch (_) {}
    try {
        const depot = value.DepotPath;
        if (depot !== undefined && depot !== null) {
            const text = depot.GetResolvedText();
            if (text !== undefined && text !== null) {
                return normPath(text);
            }
        }
    } catch (_) {}
    return "";
}

function xpath(root, path) {
    try {
        const result = root.GetFromXPath(path);
        if (result && result.Item1) {
            const value = result.Item2;
            return value === undefined ? null : value;
        }
    } catch (_) {}
    return null;
}

///////////////////////////////////////////////////////////////////////////////
// Aggregation helpers
///////////////////////////////////////////////////////////////////////////////

function bump(map, key) {
    const name = key === null || key === undefined || key === "" ? "<unset>" : String(key);
    map[name] = (map[name] || 0) + 1;
}

function bumpCapped(map, key, cap) {
    const name = key === null || key === undefined || key === "" ? "<unset>" : String(key);
    if (map[name] === undefined && Object.keys(map).length >= cap) {
        map["<other>"] = (map["<other>"] || 0) + 1;
        return;
    }
    map[name] = (map[name] || 0) + 1;
}

function mostCommon(map) {
    let best = null;
    let bestCount = -1;
    for (const key in map) {
        if (map[key] > bestCount) {
            best = key;
            bestCount = map[key];
        }
    }
    return best;
}

function countKeys(map) {
    return Object.keys(map).length;
}

function sumValues(map) {
    let total = 0;
    for (const key in map) {
        total += map[key];
    }
    return total;
}

///////////////////////////////////////////////////////////////////////////////
// Candidates and state
///////////////////////////////////////////////////////////////////////////////

function collectSectorPaths() {
    logI("Enumerating game archives...");

    const paths = [];
    const seen = {};
    let total = 0;

    for (const file of wkit.GetArchiveFiles()) {
        total++;
        let name = "";
        try { name = String(file.FileName || ""); } catch (_) { continue; }
        if (!name || !name.toLowerCase().endsWith(".streamingsector")) {
            continue;
        }
        const path = normPath(name);
        const key = path.toLowerCase();
        if (seen[key]) {
            continue;
        }
        seen[key] = true;
        paths.push(path);
    }

    logI("Archive entries: " + total + ", unique sectors: " + paths.length);
    paths.sort();
    return paths;
}

function parsePathList(text) {
    const out = [];
    const lines = String(text || "").split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        if (line && line.toLowerCase().endsWith(".streamingsector")) {
            out.push(normPath(line));
        }
    }
    return out;
}

function getCandidates() {
    if (settings.resumeFromExisting && !settings.forceRebuild) {
        const cached = wkit.LoadFromResources(settings.candidateCachePathInResources);
        if (cached && String(cached).trim() !== "") {
            const list = parsePathList(cached);
            if (list.length > 0) {
                logI("Reusing cached sector list (" + list.length + " sectors)");
                return list;
            }
        }
    }

    const list = collectSectorPaths();
    wkit.SaveToResources(settings.candidateCachePathInResources, list.join("\n"));
    logI("Sector list saved to resources/" + settings.candidateCachePathInResources);
    return list;
}

function emptyClassState() {
    return {
        nodes: 0,
        sectors: 0,
        properties: {},
        meshes: {}
    };
}

function emptyState(candidateCount) {
    const state = {
        version: 1,
        candidateCount: candidateCount,
        nextIndex: 0,
        physical: emptyClassState(),
        baked: emptyClassState()
    };

    // Physical only: destruction level structure and the effects hung off the levels.
    state.physical.levelCounts = {};
    state.physical.levelPresetsByIndex = {};
    state.physical.fracturingEffects = {};
    state.physical.presets = {};

    // Baked only: the intact mesh to fractured mesh pairing, and its own effect list.
    state.baked.destructionEffects = {};
    state.baked.presets = {};
    state.baked.fracturedMeshes = {};

    return state;
}

function loadState(candidateCount) {
    if (!settings.resumeFromExisting || settings.forceRebuild) {
        return emptyState(candidateCount);
    }

    const raw = wkit.LoadFromResources(settings.statePathInResources);
    if (!raw || String(raw).trim() === "") {
        return emptyState(candidateCount);
    }

    let state = null;
    try {
        state = JSON.parse(String(raw));
    } catch (_) {
        logW("State file is not valid JSON, starting over");
        return emptyState(candidateCount);
    }

    if (!state || state.version !== 1 || state.candidateCount !== candidateCount) {
        logW("State does not match the current sector list, starting over");
        return emptyState(candidateCount);
    }

    logI("Resuming at " + state.nextIndex + "/" + candidateCount +
        " (physical: " + state.physical.nodes + ", baked: " + state.baked.nodes + ")");
    return state;
}

function saveState(state) {
    wkit.SaveToResources(settings.statePathInResources, JSON.stringify(state));
}

///////////////////////////////////////////////////////////////////////////////
// Node recording
///////////////////////////////////////////////////////////////////////////////

///Reads a property list into `values` and into the class wide histograms.
function readProperties(root, index, properties, bucket, values) {
    for (let i = 0; i < properties.length; i++) {
        const property = properties[i];
        const value = readValue(xpath(root, "nodes:" + index + "." + property));
        values[property] = value;

        if (!bucket.properties[property]) {
            bucket.properties[property] = {};
        }
        bumpCapped(bucket.properties[property], value, settings.maxDistinctValuesPerProperty);
    }
}

///Records the most common value of each property against the mesh it was seen on.
function recordMeshDefaults(bucket, meshPath, properties, values) {
    if (!meshPath) {
        return null;
    }

    if (!bucket.meshes[meshPath]) {
        bucket.meshes[meshPath] = { count: 0 };
    }
    const entry = bucket.meshes[meshPath];
    entry.count++;

    for (let i = 0; i < properties.length; i++) {
        const property = properties[i];
        if (!entry[property]) {
            entry[property] = {};
        }
        bumpCapped(entry[property], values[property], 16);
    }

    return entry;
}

///Number of entries in a node's destructionLevelData, -1 when it cannot be walked.
function countDestructionLevels(root, index) {
    const array = xpath(root, "nodes:" + index + ".destructionLevelData");
    if (!array) {
        return 0;
    }

    let levels = 0;
    try {
        for (const _ of array) {
            levels++;
        }
    } catch (_) {
        return -1;
    }
    return levels;
}

function recordPhysicalNode(root, index, state) {
    const bucket = state.physical;
    bucket.nodes++;

    const values = {};
    readProperties(root, index, PHYSICAL_PROPERTIES, bucket, values);

    const meshPath = readReference(xpath(root, "nodes:" + index + ".mesh"));
    const entry = recordMeshDefaults(bucket, meshPath, PHYSICAL_DEFAULT_PROPERTIES, values);

    // Every destruction level, not just the first: the probe found level 0 is always the
    // "Destructible" preset while later levels vary, e.g. "Debris" on the middle level.
    const levelCount = countDestructionLevels(root, index);
    bump(bucket.levelCounts, String(levelCount));

    const levelSignature = [];
    const readable = Math.min(levelCount < 0 ? 0 : levelCount, settings.maxDestructionLevels);

    for (let level = 0; level < readable; level++) {
        const base = "nodes:" + index + ".destructionLevelData:" + level;

        const preset = readValue(xpath(root, base + ".filterData.preset"));
        const effect = readReference(xpath(root, base + ".fracturingEffect"));

        // preset -> mask combination, to confirm the masks follow from the preset alone.
        const combo = [
            readValue(xpath(root, base + ".filterData.queryFilter.mask1")),
            readValue(xpath(root, base + ".filterData.queryFilter.mask2")),
            readValue(xpath(root, base + ".filterData.simulationFilter.mask1")),
            readValue(xpath(root, base + ".filterData.simulationFilter.mask2"))
        ].join("|");

        const presetName = preset || "<unset>";
        if (!bucket.presets[presetName]) {
            bucket.presets[presetName] = {};
        }
        bump(bucket.presets[presetName], combo);

        // Which presets appear at which depth.
        const key = "level" + level;
        if (!bucket.levelPresetsByIndex[key]) {
            bucket.levelPresetsByIndex[key] = {};
        }
        bump(bucket.levelPresetsByIndex[key], presetName);

        if (effect) {
            bump(bucket.fracturingEffects, effect);
        }

        levelSignature.push(presetName + "~" + effect);
    }

    // One histogram entry per whole level layout, so the most common complete layout of a
    // mesh can be restored rather than a mix of unrelated most common levels.
    if (entry) {
        if (!entry.levels) {
            entry.levels = {};
        }
        bumpCapped(entry.levels, levelSignature.join("|"), 16);
    }
}

function recordBakedNode(root, index, state) {
    const bucket = state.baked;
    bucket.nodes++;

    const values = {};
    readProperties(root, index, BAKED_PROPERTIES, bucket, values);

    const meshPath = readReference(xpath(root, "nodes:" + index + ".mesh"));
    const fracturedPath = readReference(xpath(root, "nodes:" + index + ".meshFractured"));
    const effect = readReference(xpath(root, "nodes:" + index + ".destructionEffect"));

    values["meshFractured"] = fracturedPath;
    values["destructionEffect"] = effect;

    if (!bucket.properties["meshFractured"]) {
        bucket.properties["meshFractured"] = {};
    }
    bump(bucket.properties["meshFractured"], fracturedPath === "" ? "<unset>" : "<set>");

    if (!bucket.properties["destructionEffect"]) {
        bucket.properties["destructionEffect"] = {};
    }
    bump(bucket.properties["destructionEffect"], effect === "" ? "<unset>" : "<set>");

    if (effect) {
        bump(bucket.destructionEffects, effect);
    }
    if (fracturedPath) {
        bump(bucket.fracturedMeshes, fracturedPath);
    }

    const preset = values["filterData.preset"] || "<unset>";
    const combo = [
        readValue(xpath(root, "nodes:" + index + ".filterData.queryFilter.mask1")),
        readValue(xpath(root, "nodes:" + index + ".filterData.queryFilter.mask2")),
        readValue(xpath(root, "nodes:" + index + ".filterData.simulationFilter.mask1")),
        readValue(xpath(root, "nodes:" + index + ".filterData.simulationFilter.mask2"))
    ].join("|");
    if (!bucket.presets[preset]) {
        bucket.presets[preset] = {};
    }
    bump(bucket.presets[preset], combo);

    const entry = recordMeshDefaults(bucket, meshPath, BAKED_DEFAULT_PROPERTIES, values);

    // Is the intact mesh to fractured mesh mapping fixed? If every mesh has exactly one
    // fractured counterpart, World Builder can fill it in automatically.
    if (entry) {
        if (!entry.meshFractured) {
            entry.meshFractured = {};
        }
        bumpCapped(entry.meshFractured, fracturedPath === "" ? "<unset>" : fracturedPath, 16);

        if (!entry.destructionEffect) {
            entry.destructionEffect = {};
        }
        bumpCapped(entry.destructionEffect, effect === "" ? "<unset>" : effect, 16);
    }
}

///////////////////////////////////////////////////////////////////////////////
// Sector scan
///////////////////////////////////////////////////////////////////////////////

///Walks a sector's nodes. Detection uses RedBaseClass.HasProperty on a signature property
///unique to each class; GetType() throws because reflection is disabled.
function scanSector(path, state) {
    let cr2w = null;
    try {
        cr2w = wkit.GetFileFromArchive(path, OpenAs.CR2W);
    } catch (_) {
        return false;
    }
    if (!cr2w) {
        return false;
    }

    try {
        const root = cr2w.RootChunk;
        if (!root) {
            return false;
        }

        const nodes = xpath(root, "nodes");
        if (!nodes) {
            return false;
        }

        let index = 0;
        let foundPhysical = false;
        let foundBaked = false;

        for (const handle of nodes) {
            try {
                const node = handle ? handle.Chunk : null;
                if (node) {
                    if (node.HasProperty(PHYSICAL_SIGNATURE) === true) {
                        recordPhysicalNode(root, index, state);
                        foundPhysical = true;
                    } else if (node.HasProperty(BAKED_SIGNATURE) === true) {
                        recordBakedNode(root, index, state);
                        foundBaked = true;
                    }
                }
            } catch (_) {}

            index++;
        }

        if (foundPhysical) {
            state.physical.sectors++;
        }
        if (foundBaked) {
            state.baked.sectors++;
        }

        return true;
    } catch (_) {
        return false;
    } finally {
        try { cr2w.Dispose(); } catch (_) {}
    }
}

///////////////////////////////////////////////////////////////////////////////
// Output
///////////////////////////////////////////////////////////////////////////////

function buildPropertyReport(bucket) {
    const properties = {};
    for (const property in bucket.properties) {
        const values = bucket.properties[property];
        const total = sumValues(values);
        const best = mostCommon(values);
        properties[property] = {
            distinct: countKeys(values),
            mostCommon: best,
            mostCommonShare: total > 0 ? Math.round((values[best] / total) * 1000) / 10 : 0,
            values: values
        };
    }
    return properties;
}

function buildPresetReport(presets) {
    const out = {};
    for (const preset in presets) {
        out[preset] = {
            variants: countKeys(presets[preset]),
            uses: sumValues(presets[preset]),
            combinations: presets[preset]
        };
    }
    return out;
}

///preset -> masks, using the most common combination seen for that preset.
function buildPresetMasks(sources) {
    const merged = {};
    for (let i = 0; i < sources.length; i++) {
        const presets = sources[i];
        for (const preset in presets) {
            if (preset === "<unset>") {
                continue;
            }
            if (!merged[preset]) {
                merged[preset] = {};
            }
            for (const combo in presets[preset]) {
                merged[preset][combo] = (merged[preset][combo] || 0) + presets[preset][combo];
            }
        }
    }

    const out = {};
    for (const preset in merged) {
        const combo = mostCommon(merged[preset]);
        if (!combo) {
            continue;
        }
        const parts = String(combo).split("|");
        out[preset] = {
            queryMask1: parts[0],
            queryMask2: parts[1],
            simulationMask1: parts[2],
            simulationMask2: parts[3],
            uses: sumValues(merged[preset]),
            variants: countKeys(merged[preset])
        };
    }
    return out;
}

///Turns a level signature, "preset~effect" per level joined by "|", back into the array
///it was built from in recordPhysicalNode. Returns null when there is nothing usable.
function decodeLevelSignature(signature) {
    if (signature === null || signature === undefined || signature === "" || signature === "<other>") {
        return null;
    }

    const levels = [];
    const parts = String(signature).split("|");
    for (let i = 0; i < parts.length; i++) {
        if (parts[i] === "") {
            continue;
        }
        const separator = parts[i].indexOf("~");
        const preset = separator === -1 ? parts[i] : parts[i].substring(0, separator);
        const effect = separator === -1 ? "" : parts[i].substring(separator + 1);

        const level = { preset: preset };
        if (effect !== "") {
            level.fracturingEffect = effect;
        }
        levels.push(level);
    }

    return levels.length > 0 ? levels : null;
}

///Reduces a mesh's histograms to the single most common value of each property.
function reduceMeshEntry(entry, properties) {
    const reduced = { uses: entry.count };
    for (let i = 0; i < properties.length; i++) {
        const property = properties[i];
        const value = entry[property] ? mostCommon(entry[property]) : null;
        if (value !== null && value !== "<unset>" && value !== "<other>") {
            reduced[property] = value;
        }
    }
    return reduced;
}

function sortedMeshPaths(meshes) {
    const paths = Object.keys(meshes);
    paths.sort(function (a, b) {
        const la = a.toLowerCase();
        const lb = b.toLowerCase();
        return la < lb ? -1 : (la > lb ? 1 : 0);
    });
    return paths;
}

///Loads the destruction parameter mesh list, lowercased, or null when absent.
function loadDestructionMeshList() {
    let raw = null;
    try {
        raw = wkit.LoadFromResources(settings.destructionMeshListInResources);
    } catch (_) {
        return null;
    }
    if (!raw || String(raw).trim() === "") {
        return null;
    }

    const set = {};
    const lines = String(raw).split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
        const line = normPath(lines[i]).toLowerCase();
        if (line && line.endsWith(".mesh")) {
            set[line] = true;
        }
    }
    return set;
}

function crossCheck(paths, list) {
    if (!list) {
        return undefined;
    }
    let inList = 0;
    let namedDst = 0;
    for (let i = 0; i < paths.length; i++) {
        const key = paths[i].toLowerCase();
        if (list[key]) {
            inList++;
        }
        if (key.indexOf("_dst") !== -1) {
            namedDst++;
        }
    }
    return { total: paths.length, withDestructionParameters: inList, namedDst: namedDst };
}

function writeOutputs(state) {
    const physicalMeshes = sortedMeshPaths(state.physical.meshes);
    const bakedMeshes = sortedMeshPaths(state.baked.meshes);
    const bakedFractured = sortedMeshPaths(state.baked.fracturedMeshes);
    const destructionList = loadDestructionMeshList();

    // 1. Spawn lists, one per node class.
    wkit.SaveToResources(settings.physicalPathsInResources, physicalMeshes.join("\n"));
    wkit.SaveToResources(settings.bakedPathsInResources, bakedMeshes.join("\n"));

    // 2. Per mesh defaults.
    const physicalDefaults = {};
    for (const meshPath in state.physical.meshes) {
        const entry = state.physical.meshes[meshPath];
        const reduced = reduceMeshEntry(entry, PHYSICAL_DEFAULT_PROPERTIES);

        // The whole level layout, restored from the most common signature of that mesh.
        const levels = decodeLevelSignature(entry.levels ? mostCommon(entry.levels) : null);
        if (levels) {
            reduced.levels = levels;
        }

        physicalDefaults[meshPath] = reduced;
    }
    wkit.SaveToResources(settings.physicalDefaultsInResources,
        JSON.stringify({ version: 1, meshes: physicalDefaults }, null, 2));

    const bakedDefaults = {};
    let fixedPairing = 0;
    let variablePairing = 0;
    for (const meshPath in state.baked.meshes) {
        const entry = state.baked.meshes[meshPath];
        const reduced = reduceMeshEntry(entry, BAKED_DEFAULT_PROPERTIES);

        const fractured = entry.meshFractured ? mostCommon(entry.meshFractured) : null;
        if (fractured !== null && fractured !== "<unset>" && fractured !== "<other>") {
            reduced.meshFractured = fractured;
        }
        // How many distinct fractured meshes this intact mesh was paired with.
        const pairings = entry.meshFractured ? countKeys(entry.meshFractured) : 0;
        reduced.fracturedVariants = pairings;
        if (pairings > 1) {
            variablePairing++;
        } else if (pairings === 1) {
            fixedPairing++;
        }

        const effect = entry.destructionEffect ? mostCommon(entry.destructionEffect) : null;
        if (effect !== null && effect !== "<unset>" && effect !== "<other>") {
            reduced.destructionEffect = effect;
        }

        bakedDefaults[meshPath] = reduced;
    }
    wkit.SaveToResources(settings.bakedDefaultsInResources,
        JSON.stringify({ version: 1, meshes: bakedDefaults }, null, 2));

    // 3. Effect lists.
    const fracturing = Object.keys(state.physical.fracturingEffects).sort();
    const destruction = Object.keys(state.baked.destructionEffects).sort();
    wkit.SaveToResources(settings.effectsPathInResources, JSON.stringify({
        version: 1,
        physicalFracturing: fracturing,
        bakedDestruction: destruction
    }, null, 2));

    // 4. Preset masks, merged across both classes.
    const presetMasks = buildPresetMasks([state.physical.presets, state.baked.presets]);
    wkit.SaveToResources(settings.presetsPathInResources,
        JSON.stringify({ version: 1, presets: presetMasks }, null, 2));

    // 5. Full report.
    const report = {
        version: 1,
        sectorsScanned: state.nextIndex,
        physical: {
            nodes: state.physical.nodes,
            sectors: state.physical.sectors,
            distinctMeshes: physicalMeshes.length,
            destructionLevelCounts: state.physical.levelCounts,
            presetsByLevel: state.physical.levelPresetsByIndex,
            filterPresets: buildPresetReport(state.physical.presets),
            fracturingEffects: state.physical.fracturingEffects,
            meshCrossCheck: crossCheck(physicalMeshes, destructionList),
            properties: buildPropertyReport(state.physical)
        },
        baked: {
            nodes: state.baked.nodes,
            sectors: state.baked.sectors,
            distinctMeshes: bakedMeshes.length,
            distinctFracturedMeshes: bakedFractured.length,
            fracturedPairing: { fixed: fixedPairing, variable: variablePairing },
            filterPresets: buildPresetReport(state.baked.presets),
            destructionEffects: state.baked.destructionEffects,
            meshCrossCheck: crossCheck(bakedMeshes, destructionList),
            fracturedMeshCrossCheck: crossCheck(bakedFractured, destructionList),
            properties: buildPropertyReport(state.baked)
        }
    };
    wkit.SaveToResources(settings.reportPathInResources, JSON.stringify(report, null, 2));

    return report;
}

function logSummary(report) {
    logI("");
    logI("================= destruction node usage =================");
    logI("Sectors scanned: " + report.sectorsScanned);
    logI("");

    logI("-- worldPhysicalDestructionNode --");
    logI("  " + report.physical.nodes + " nodes in " + report.physical.sectors + " sectors, " +
        report.physical.distinctMeshes + " distinct meshes");
    let levels = "";
    for (const count in report.physical.destructionLevelCounts) {
        levels += " " + count + "=" + report.physical.destructionLevelCounts[count];
    }
    logI("  destruction levels:" + levels);
    for (const key in report.physical.presetsByLevel) {
        const presets = report.physical.presetsByLevel[key];
        let line = "";
        for (const preset in presets) {
            line += " " + preset + "=" + presets[preset];
        }
        logI("  " + key + ":" + line);
    }
    logI("  fracturing effects: " + countKeys(report.physical.fracturingEffects));
    if (report.physical.meshCrossCheck) {
        const c = report.physical.meshCrossCheck;
        logI("  meshes with destruction parameters: " + c.withDestructionParameters + "/" + c.total +
            ", named *_dst*: " + c.namedDst);
    }

    logI("");
    logI("-- worldBakedDestructionNode --");
    logI("  " + report.baked.nodes + " nodes in " + report.baked.sectors + " sectors, " +
        report.baked.distinctMeshes + " distinct meshes, " +
        report.baked.distinctFracturedMeshes + " distinct fractured meshes");
    logI("  intact -> fractured pairing: " + report.baked.fracturedPairing.fixed + " fixed, " +
        report.baked.fracturedPairing.variable + " with several variants");
    logI("  destruction effects: " + countKeys(report.baked.destructionEffects));
    if (report.baked.fracturedMeshCrossCheck) {
        const c = report.baked.fracturedMeshCrossCheck;
        logI("  fractured meshes with destruction parameters: " + c.withDestructionParameters + "/" + c.total);
    }

    logI("");
    logI("-- collision filter presets, both classes --");
    for (const preset in report.physical.filterPresets) {
        const entry = report.physical.filterPresets[preset];
        logI("  physical " + preset + ": " + entry.uses + " uses, " + entry.variants + " mask variant(s)");
    }
    for (const preset in report.baked.filterPresets) {
        const entry = report.baked.filterPresets[preset];
        logI("  baked    " + preset + ": " + entry.uses + " uses, " + entry.variants + " mask variant(s)");
    }

    logI("");
    logI("-- properties that never varied (candidates for hardcoding) --");
    const classes = [["physical", report.physical], ["baked", report.baked]];
    for (let i = 0; i < classes.length; i++) {
        const name = classes[i][0];
        const properties = classes[i][1].properties;
        let line = "";
        let count = 0;
        for (const property in properties) {
            if (properties[property].distinct === 1) {
                line += "\n      " + property + " = " + properties[property].mostCommon;
                count++;
            }
        }
        logI("  " + name + ": " + count + " of " + countKeys(properties) + line);
    }

    logI("");
    logI("Outputs:");
    logI("  resources/" + settings.reportPathInResources);
    logI("  resources/" + settings.physicalPathsInResources);
    logI("  resources/" + settings.bakedPathsInResources);
    logI("  resources/" + settings.physicalDefaultsInResources);
    logI("  resources/" + settings.bakedDefaultsInResources);
    logI("  resources/" + settings.effectsPathInResources);
    logI("  resources/" + settings.presetsPathInResources);
    logI("");
    logW("The two paths_*.txt each need their own folder in the mod: loadLists merges");
    logW("every .txt in a folder into one spawn list, without removing duplicates.");
    logI("==========================================================");
}

///////////////////////////////////////////////////////////////////////////////
// Main
///////////////////////////////////////////////////////////////////////////////

(function main() {
    const candidates = getCandidates();
    if (candidates.length === 0) {
        throw new Error("No sectors to scan");
    }

    const stride = Math.max(1, Math.floor(settings.sectorStride) || 1);
    let end = candidates.length;
    if (settings.limit > 0 && settings.limit < end) {
        end = settings.limit;
        logI("Limit active: only the first " + end + " sectors are considered");
    }
    if (stride > 1) {
        logI("Stride active: scanning every " + stride + "th sector");
    }

    const state = loadState(candidates.length);
    let scanned = 0;
    let selfCheckDone = state.nextIndex > 0;

    for (let i = state.nextIndex; i < end; i++) {
        if (i % stride === 0) {
            scanSector(candidates[i], state);
            scanned++;
        }

        state.nextIndex = i + 1;

        if (!selfCheckDone && scanned >= 200) {
            selfCheckDone = true;
            if (state.physical.nodes === 0 && state.baked.nodes === 0) {
                logW("No physical or baked destruction node in the first 200 sectors scanned.");
                logW("That can be normal, but if it persists the signature detection is off.");
            } else {
                logI("Self check ok: physical=" + state.physical.nodes + " baked=" + state.baked.nodes);
            }
        }

        if (settings.progressEvery > 0 && state.nextIndex % settings.progressEvery === 0) {
            logI(state.nextIndex + "/" + end + " sectors - physical: " + state.physical.nodes +
                " (" + countKeys(state.physical.meshes) + " meshes), baked: " + state.baked.nodes +
                " (" + countKeys(state.baked.meshes) + " meshes)");
        }

        if (settings.saveEvery > 0 && state.nextIndex % settings.saveEvery === 0) {
            saveState(state);
            writeOutputs(state);
        }
    }

    saveState(state);
    logSummary(writeOutputs(state));
})();
