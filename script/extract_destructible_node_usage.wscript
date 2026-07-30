// @author Akiway
// @version 1.0.0
//
// @description
// Surveys how CDPR actually configures worldInstancedDestructibleMeshNode across the
// shipped streamingsectors, so World Builder can drop the properties nobody varies,
// derive collision masks from the filter preset, and pre-fill per mesh defaults.
//
// Outputs (relative to the active project `resources` folder):
//   reports/destructible_node_usage.json
//       -> value histogram per property, filter preset/mask combinations, effect usage
//   data/static/destructible_filter_presets.json
//       -> preset name -> collision masks (plus how many mask variants that preset has)
//   data/static/destructible_effects.json
//       -> the .effect paths actually used as fracturingEffect / idleEffect
//   data/static/destructible_mesh_defaults.json
//       -> mesh path -> the settings most commonly used with that mesh
//
// There are ~48k sectors, so this is a long run. It is resumable (candidate list and
// state are cached in resources) and `sectorStride` can sample every Nth sector for a
// faster first pass. Start with `limit` set to a few hundred to sanity check the output.

const settings = {
    candidateCachePathInResources: "reports/destructible_sectors_candidates.txt",
    statePathInResources: "reports/destructible_node_usage_state.json",

    reportPathInResources: "reports/destructible_node_usage.json",
    presetsPathInResources: "data/static/destructible_filter_presets.json",
    effectsPathInResources: "data/static/destructible_effects.json",
    meshDefaultsPathInResources: "data/static/destructible_mesh_defaults.json",

    resumeFromExisting: true,
    forceRebuild: false,

    // 1 = every sector. Raise to sample, e.g. 5 scans a fifth of them.
    sectorStride: 1,

    // 0 = no limit. Set to e.g. 300 for a first pass.
    limit: 0,

    // Value histograms stop collecting new distinct values past this, remaining ones are
    // counted under "<other>". Keeps per instance values like autohide distances bounded.
    maxDistinctValuesPerProperty: 120,

    progressEvery: 200,
    saveEvery: 2000
};

// Present on worldInstancedDestructibleMeshNode and on no other world node class, so it
// identifies the node type. Reflection is blocked in this engine, GetType() is not usable.
const SIGNATURE_PROPERTY = "fracturingEffect";

// Read for every destructible node found. Paths with dots are nested lookups.
const TRACKED_PROPERTIES = [
    "simulationType",
    "filterDataSource",
    "startInactive",
    "turnDynamicOnImpulse",
    "useAggregate",
    "enableSelfCollisionInAggregate",
    "isDestructible",
    "damageThreshold",
    "damageEndurance",
    "accumulateDamage",
    "impulseToDamage",
    "isPierceable",
    "isWorkspot",
    "useMeshNavmeshSettings",
    "navigationSetting.navmeshImpact",
    "windImpulseEnabled",
    "removeFromRainMap",
    "occluderType",
    "occluderAutohideDistanceScale",
    "castShadows",
    "castLocalShadows",
    "castRayTracedGlobalShadows",
    "castRayTracedLocalShadows",
    "renderSceneLayerMask",
    "lodLevelScales",
    "version",
    "systemsToNotifyFlags",
    "isVisibleInGame",
    "isHostOnly",
    "tag",
    "tagExt",
    "forceAutoHideDistance",
    "staticMeshAppearance",
    "filterData.preset",
    "filterData.queryFilter.mask1",
    "filterData.queryFilter.mask2",
    "filterData.simulationFilter.mask1",
    "filterData.simulationFilter.mask2"
];

// Resource reference properties, read through DepotPath rather than ToString().
const REFERENCE_PROPERTIES = ["mesh", "staticMesh", "fracturingEffect", "idleEffect"];

// Recorded per mesh so World Builder can pre-fill a newly placed node. Only properties
// World Builder still lets the user change are kept: the ones it hardcodes on export
// (damageThreshold, impulseToDamage, accumulateDamage, useMeshNavmeshSettings,
// navigationSetting.navmeshImpact) would only bloat the shipped file. Their global
// distribution is still in the report.
const MESH_DEFAULT_PROPERTIES = [
    "simulationType",
    "filterDataSource",
    "filterData.preset",
    "isDestructible",
    "startInactive",
    "turnDynamicOnImpulse",
    "damageEndurance",
    "fracturingEffect",
    "idleEffect"
];

function logI(m) { try { logger.Info("[node-usage] " + m); } catch (_) {} }
function logW(m) { try { logger.Warning("[node-usage] " + m); } catch (_) {} }
function logE(m) { try { logger.Error("[node-usage] " + m); } catch (_) {} }

function normPath(p) {
    return String(p || "").trim().replace(/\//g, "\\");
}

///CFloat.ToString() uses the current culture, which may render 147.26 as "147,268112".
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

function emptyState(candidateCount) {
    return {
        version: 1,
        candidateCount: candidateCount,
        nextIndex: 0,
        sectorsWithNodes: 0,
        nodesFound: 0,
        properties: {},
        presets: {},
        fracturingEffects: {},
        idleEffects: {},
        meshes: {}
    };
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

    logI("Resuming at " + state.nextIndex + "/" + candidateCount + " (" + state.nodesFound + " nodes so far)");
    return state;
}

function saveState(state) {
    wkit.SaveToResources(settings.statePathInResources, JSON.stringify(state));
}

///////////////////////////////////////////////////////////////////////////////
// Sector scan
///////////////////////////////////////////////////////////////////////////////

///Records one destructible node into the aggregates.
function recordNode(root, index, state) {
    state.nodesFound++;

    const meshPath = readReference(xpath(root, "nodes:" + index + ".mesh"));
    const values = {};

    for (let i = 0; i < TRACKED_PROPERTIES.length; i++) {
        const property = TRACKED_PROPERTIES[i];
        const value = readValue(xpath(root, "nodes:" + index + "." + property));
        values[property] = value;

        if (!state.properties[property]) {
            state.properties[property] = {};
        }
        bumpCapped(state.properties[property], value, settings.maxDistinctValuesPerProperty);
    }

    for (let i = 0; i < REFERENCE_PROPERTIES.length; i++) {
        const property = REFERENCE_PROPERTIES[i];
        const value = readReference(xpath(root, "nodes:" + index + "." + property));
        values[property] = value;

        if (property === "mesh") {
            continue;
        }

        if (!state.properties[property]) {
            state.properties[property] = {};
        }
        bumpCapped(state.properties[property], value === "" ? "<unset>" : "<set>", 8);
    }

    if (values["fracturingEffect"]) {
        bump(state.fracturingEffects, values["fracturingEffect"]);
    }
    if (values["idleEffect"]) {
        bump(state.idleEffects, values["idleEffect"]);
    }

    // preset -> mask combination, to see whether the masks follow from the preset alone.
    const preset = values["filterData.preset"] || "<unset>";
    const combo = [
        values["filterData.queryFilter.mask1"],
        values["filterData.queryFilter.mask2"],
        values["filterData.simulationFilter.mask1"],
        values["filterData.simulationFilter.mask2"]
    ].join("|");

    if (!state.presets[preset]) {
        state.presets[preset] = {};
    }
    bump(state.presets[preset], combo);

    if (meshPath) {
        if (!state.meshes[meshPath]) {
            state.meshes[meshPath] = { count: 0 };
        }
        const entry = state.meshes[meshPath];
        entry.count++;

        for (let i = 0; i < MESH_DEFAULT_PROPERTIES.length; i++) {
            const property = MESH_DEFAULT_PROPERTIES[i];
            if (!entry[property]) {
                entry[property] = {};
            }
            bumpCapped(entry[property], values[property], 16);
        }
    }
}

///Walks a sector's nodes. Detection uses RedBaseClass.HasProperty, which is a direct
///call on the node; probing via GetFromXPath for every node in every sector is far too
///slow, and GetType() throws because reflection is disabled.
function scanSector(path, state) {
    let cr2w = null;
    try {
        cr2w = wkit.GetFileFromArchive(path, OpenAs.CR2W);
    } catch (e) {
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
        let found = 0;

        for (const handle of nodes) {
            let isTarget = false;

            try {
                const node = handle ? handle.Chunk : null;
                if (node) {
                    isTarget = node.HasProperty(SIGNATURE_PROPERTY) === true;
                }
            } catch (_) {
                isTarget = false;
            }

            if (isTarget) {
                recordNode(root, index, state);
                found++;
            }

            index++;
        }

        if (found > 0) {
            state.sectorsWithNodes++;
        }

        return true;
    } catch (e) {
        return false;
    } finally {
        try { cr2w.Dispose(); } catch (_) {}
    }
}

///////////////////////////////////////////////////////////////////////////////
// Output
///////////////////////////////////////////////////////////////////////////////

function writeOutputs(state) {
    // 1. Full report.
    const properties = {};
    for (const property in state.properties) {
        const values = state.properties[property];
        properties[property] = {
            distinct: countKeys(values),
            mostCommon: mostCommon(values),
            values: values
        };
    }

    const presets = {};
    for (const preset in state.presets) {
        presets[preset] = {
            variants: countKeys(state.presets[preset]),
            combinations: state.presets[preset]
        };
    }

    wkit.SaveToResources(settings.reportPathInResources, JSON.stringify({
        version: 1,
        sectorsScanned: state.nextIndex,
        sectorsWithNodes: state.sectorsWithNodes,
        nodesFound: state.nodesFound,
        properties: properties,
        filterPresets: presets,
        fracturingEffects: state.fracturingEffects,
        idleEffects: state.idleEffects
    }, null, 2));
    logI("Report -> resources/" + settings.reportPathInResources);

    // 2. Preset -> masks, using the most common combination of each preset.
    const presetMap = {};
    for (const preset in state.presets) {
        if (preset === "<unset>") {
            continue;
        }
        const combo = mostCommon(state.presets[preset]);
        if (!combo) {
            continue;
        }
        const parts = String(combo).split("|");
        let total = 0;
        for (const key in state.presets[preset]) {
            total += state.presets[preset][key];
        }
        presetMap[preset] = {
            queryMask1: parts[0],
            queryMask2: parts[1],
            simulationMask1: parts[2],
            simulationMask2: parts[3],
            uses: total,
            variants: countKeys(state.presets[preset])
        };
    }
    wkit.SaveToResources(settings.presetsPathInResources, JSON.stringify({ version: 1, presets: presetMap }, null, 2));
    logI("Filter presets -> resources/" + settings.presetsPathInResources);

    // 3. Effect lists.
    const fracturing = Object.keys(state.fracturingEffects).sort();
    const idle = Object.keys(state.idleEffects).sort();
    wkit.SaveToResources(settings.effectsPathInResources, JSON.stringify({
        version: 1,
        fracturing: fracturing,
        idle: idle
    }, null, 2));
    logI("Effects -> resources/" + settings.effectsPathInResources + " (" + fracturing.length + " fracturing, " + idle.length + " idle)");

    // 4. Per mesh defaults, reduced to the most common value of each property.
    const meshDefaults = {};
    for (const meshPath in state.meshes) {
        const entry = state.meshes[meshPath];
        const reduced = { uses: entry.count };
        for (let i = 0; i < MESH_DEFAULT_PROPERTIES.length; i++) {
            const property = MESH_DEFAULT_PROPERTIES[i];
            const value = entry[property] ? mostCommon(entry[property]) : null;
            if (value !== null && value !== "<unset>" && value !== "<other>") {
                reduced[property] = value;
            }
        }
        meshDefaults[meshPath] = reduced;
    }
    wkit.SaveToResources(settings.meshDefaultsPathInResources, JSON.stringify({ version: 1, meshes: meshDefaults }, null, 2));
    logI("Mesh defaults -> resources/" + settings.meshDefaultsPathInResources + " (" + countKeys(meshDefaults) + " meshes)");
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

        if (!selfCheckDone && scanned >= 50) {
            selfCheckDone = true;
            if (state.nodesFound === 0) {
                logW("No destructible node in the first 50 sectors scanned. That can be normal,");
                logW("but if it persists the '" + SIGNATURE_PROPERTY + "' detection is not matching.");
            } else {
                logI("Self check ok, " + state.nodesFound + " nodes in the first 50 sectors");
            }
        }

        if (settings.progressEvery > 0 && state.nextIndex % settings.progressEvery === 0) {
            logI(state.nextIndex + "/" + end + " sectors - nodes: " + state.nodesFound + ", meshes: " + countKeys(state.meshes) + ", effects: " + countKeys(state.fracturingEffects));
        }

        if (settings.saveEvery > 0 && state.nextIndex % settings.saveEvery === 0) {
            saveState(state);
            writeOutputs(state);
        }
    }

    saveState(state);
    writeOutputs(state);

    logI("Done. sectors=" + state.nextIndex + " withNodes=" + state.sectorsWithNodes + " nodes=" + state.nodesFound + " meshes=" + countKeys(state.meshes));
})();
