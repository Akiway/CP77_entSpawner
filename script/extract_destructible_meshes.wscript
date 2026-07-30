// @author Akiway
// @version 1.0.0
//
// @description
// Build the World Builder asset list for the "Destructible Mesh" node type
// (worldInstancedDestructibleMeshNode).
//
// A mesh can only be placed as a worldInstancedDestructibleMeshNode when it ships
// its own physics collision data, which is stored as a `meshMeshParamPhysics`
// entry inside CMesh.parameters. This script scans every .mesh in the game
// archives (or an existing path list) and keeps the ones carrying that parameter.
//
// Meshes that additionally carry destruction parameters (chunk hierarchy, bonds,
// ...) can actually break apart ingame (node.isDestructible = 1); they are written
// to a second list so World Builder can tell both cases apart.
//
// Outputs (relative to the active project `resources` folder):
//   data/spawnables/mesh/destructible/paths_destructible.txt
//       -> meshes with meshMeshParamPhysics, the "Destructible Mesh" spawn list
//   data/static/destructible_meshes_destruction.txt
//       -> subset that also has destruction data. Kept out of the spawn data folder,
//          which World Builder reads whole, so it does not end up in the spawn list
//   reports/destructible_meshes_report.json
//       -> per mesh detail (parameter type names, bone count, errors)
//
// The scan is long (tens of thousands of meshes). It is resumable: the candidate
// list and the progress state are cached in resources, so re-running after an
// abort continues where it stopped. Set `forceRebuild` to start over.

const settings = {
    // "archives" scans every .mesh in the game archives (authoritative, slow).
    // "list" only re-checks the paths of an existing World Builder list (fast).
    source: "archives",

    // Use the input list below when the archive scan comes back empty.
    fallbackToInputList: true,

    // Number of archive entries logged on scan start, to diagnose an empty result.
    probeSamples: 5,

    // Meshes inspected before checking that parameter names can be read at all.
    selfCheckSamples: 25,

    // Used when source === "list", and by the fallback. First existing file wins.
    inputListCandidatesInResources: [
        "data/spawnables/mesh/all/paths_mesh.txt",
        "data/spawnables/mesh/physics/paths_filtered_mesh.txt",
        "paths_mesh.txt"
    ],

    // Extensions considered when scanning the archives.
    meshExtensions: [".mesh"],

    // The spawn list folder is scanned whole by World Builder, so only the spawnable
    // list may live there. The destruction flags go to data/static instead.
    outputPathInResources: "data/spawnables/mesh/destructible/paths_destructible.txt",
    destructionOutputPathInResources: "data/static/destructible_meshes_destruction.txt",
    reportPathInResources: "reports/destructible_meshes_report.json",

    // Resume support.
    candidateCachePathInResources: "reports/destructible_meshes_candidates.txt",
    statePathInResources: "reports/destructible_meshes_state.json",
    resumeFromExisting: true,
    forceRebuild: false,

    // Only meshes with physics end up in the report, so it stays small.
    writeReport: true,
    writeDestructionList: true,

    // 0 = no limit. Set to e.g. 500 for a quick dry run.
    limit: 0,

    progressEvery: 250,
    saveEvery: 2000
};

const PHYSICS_PARAM = "meshMeshParamPhysics";

// Any of these means the mesh can be fractured ingame.
const DESTRUCTION_PARAMS = {
    "meshMeshParamDestructionStepData": true,
    "meshMeshParamDestructionBonds": true,
    "meshMeshParamDestructionBoneChunkMapping": true,
    "meshMeshParamDestructionChunkIndicesOffsets": true,
    "meshMeshParamBakedDestructionData": true
};

function logI(m) { try { logger.Info("[destructible-meshes] " + m); } catch (_) {} }
function logW(m) { try { logger.Warning("[destructible-meshes] " + m); } catch (_) {} }
function logE(m) { try { logger.Error("[destructible-meshes] " + m); } catch (_) {} }

function normPath(p) {
    return String(p || "").trim().replace(/\//g, "\\");
}

function hasMeshExtension(path) {
    const lower = String(path || "").toLowerCase();
    for (let i = 0; i < settings.meshExtensions.length; i++) {
        if (lower.endsWith(settings.meshExtensions[i])) {
            return true;
        }
    }
    return false;
}

// ClearScript exposes .NET collections differently depending on the host type
// (`for...of` iterator, explicit enumerator, or plain indexer), and a shape that does
// not apply silently yields nothing. Every known shape is tried until one produces
// items, and the winning one is reported so a zero result is diagnosable.
const enumerationStrategies = [
    {
        name: "for-of",
        run: function (source, callback) {
            let count = 0;
            for (const item of source) {
                callback(item, count);
                count++;
            }
            return count;
        }
    },
    {
        name: "GetEnumerator",
        run: function (source, callback) {
            const enumerator = source.GetEnumerator();
            let count = 0;
            try {
                while (enumerator.MoveNext()) {
                    callback(enumerator.Current, count);
                    count++;
                }
            } finally {
                try { enumerator.Dispose(); } catch (_) {}
            }
            return count;
        }
    },
    {
        name: "indexer",
        run: function (source, callback) {
            let length = source.Count;
            if (length === undefined || length === null) {
                length = source.Length;
            }
            if (length === undefined || length === null) {
                throw new Error("no Count/Length");
            }

            let count = 0;
            for (let i = 0; i < length; i++) {
                callback(source[i], count);
                count++;
            }
            return count;
        }
    }
];

///Runs `callback` over a .NET collection. `factory` must return a fresh collection on
///every call, since a strategy that fails may have partially consumed the previous one.
///@returns number of items seen, -1 when no strategy worked at all
function forEachItem(factory, callback, label) {
    let anyStrategyRan = false;

    for (let i = 0; i < enumerationStrategies.length; i++) {
        const strategy = enumerationStrategies[i];
        const source = typeof factory === "function" ? factory() : factory;

        if (!source) {
            return 0;
        }

        try {
            const count = strategy.run(source, callback);
            anyStrategyRan = true;

            if (count > 0) {
                if (label) {
                    logI(label + ": enumerated " + count + " entries via " + strategy.name);
                }
                return count;
            }
        } catch (e) {
            if (label) {
                logW(label + ": " + strategy.name + " failed (" + e + ")");
            }
        }
    }

    if (label) {
        logW(label + ": every enumeration strategy returned nothing");
    }

    return anyStrategyRan ? 0 : -1;
}

// Last resort identification: the property that only this mesh parameter type carries.
// Used when neither GetType() nor ToString() is reachable on the host object.
const PARAM_SIGNATURES = [
    { property: "PhysicsData", name: PHYSICS_PARAM },
    { property: "Bonds", name: "meshMeshParamDestructionBonds" },
    { property: "BoneChunkMasks", name: "meshMeshParamDestructionBoneChunkMapping" },
    { property: "ChunkOffsets", name: "meshMeshParamDestructionChunkIndicesOffsets" },
    { property: "IsInstantRemovable", name: "meshMeshParamDestructionStepData" },
    { property: "RegionData", name: "meshMeshParamBakedDestructionData" }
];

///RED class name of a parameter chunk, e.g. "meshMeshParamPhysics".
///`String(hostObject)` is not usable here: the host does not route it to .NET ToString(),
///it yields "[object Object]" even for types that override ToString.
function redTypeName(chunk) {
    if (chunk === null || chunk === undefined) {
        return "";
    }

    try {
        const type = chunk.GetType();
        if (type && type.Name) {
            const name = String(type.Name);
            if (name && name.indexOf("mesh") === 0) {
                return name;
            }
        }
    } catch (_) {}

    for (let i = 0; i < PARAM_SIGNATURES.length; i++) {
        try {
            const value = chunk[PARAM_SIGNATURES[i].property];
            if (value !== undefined && value !== null) {
                return PARAM_SIGNATURES[i].name;
            }
        } catch (_) {}
    }

    return "";
}

///////////////////////////////////////////////////////////////////////////////
// Candidate list
///////////////////////////////////////////////////////////////////////////////

function parsePathList(text) {
    const out = [];
    const seen = {};
    const lines = String(text || "").split(/\r?\n/);

    for (let i = 0; i < lines.length; i++) {
        let line = lines[i].trim();
        if (!line) continue;
        if (line.indexOf("//") === 0 || line.indexOf("#") === 0 || line.indexOf(";") === 0) continue;

        line = normPath(line);
        if (!hasMeshExtension(line)) continue;

        const key = line.toLowerCase();
        if (seen[key]) continue;
        seen[key] = true;
        out.push(line);
    }

    return out;
}

function loadInputList() {
    for (let i = 0; i < settings.inputListCandidatesInResources.length; i++) {
        const candidate = settings.inputListCandidatesInResources[i];
        const raw = wkit.LoadFromResources(candidate);
        if (raw && String(raw).trim() !== "") {
            logI("Using input list resources/" + candidate);
            return parsePathList(raw);
        }
    }

    throw new Error("No input list found, tried: " + settings.inputListCandidatesInResources.join(", "));
}

///Reads the depot path of one archive entry. `FileName` resolves the name hash through
///the string pool and falls back to "<hash>.bin" when the hash is unknown, so entries
///with an unresolved name can never be used as a World Builder asset path.
function getArchiveEntryPath(file) {
    if (!file) {
        return "";
    }

    const properties = ["FileName", "Name", "NameOrHash"];
    for (let i = 0; i < properties.length; i++) {
        try {
            const value = file[properties[i]];
            if (value !== undefined && value !== null) {
                const text = String(value);
                if (text) {
                    return text;
                }
            }
        } catch (_) {}
    }

    return "";
}

function scanArchivesForMeshes() {
    logI("Enumerating game archives, this takes a moment...");

    const paths = [];
    const seen = {};
    const samples = [];
    let total = 0;
    let named = 0;

    const seenCount = forEachItem(function () { return wkit.GetArchiveFiles(); }, function (file) {
        total++;

        const name = getArchiveEntryPath(file);
        if (samples.length < settings.probeSamples) {
            samples.push(name || "<unresolved>");
        }

        if (!name) {
            return;
        }
        named++;

        if (!hasMeshExtension(name)) {
            return;
        }

        const path = normPath(name);
        const key = path.toLowerCase();
        if (seen[key]) {
            return;
        }
        seen[key] = true;
        paths.push(path);
    }, "Archives");

    if (seenCount < 0) {
        logE("Could not enumerate wkit.GetArchiveFiles() at all. Is a project open with the game archives indexed?");
    }

    logI("Archive entries: " + total + ", with resolved name: " + named + ", unique mesh paths: " + paths.length);
    if (samples.length > 0) {
        logI("First entries seen: " + samples.join(" | "));
    }

    if (paths.length === 0 && named === 0 && total > 0) {
        logW("Archive entries were found but none resolved to a readable path, the hash pool looks empty.");
    }

    paths.sort();
    return paths;
}

function getCandidates() {
    if (settings.resumeFromExisting && !settings.forceRebuild) {
        const cached = wkit.LoadFromResources(settings.candidateCachePathInResources);
        if (cached && String(cached).trim() !== "") {
            const list = parsePathList(cached);
            if (list.length > 0) {
                logI("Reusing cached candidate list (" + list.length + " meshes)");
                return list;
            }
        }
    }

    let list = settings.source === "list" ? loadInputList() : scanArchivesForMeshes();

    // Archive enumeration depends on how the host exposes .NET collections. When it
    // comes back empty, fall back to the shipped World Builder mesh list so the run
    // still produces a usable result instead of stopping.
    if (list.length === 0 && settings.source !== "list" && settings.fallbackToInputList) {
        logW("Archive scan produced no meshes, falling back to the input list");
        list = loadInputList();
    }

    list.sort();

    wkit.SaveToResources(settings.candidateCachePathInResources, list.join("\n"));
    logI("Candidate list saved to resources/" + settings.candidateCachePathInResources);

    return list;
}

///////////////////////////////////////////////////////////////////////////////
// State
///////////////////////////////////////////////////////////////////////////////

function emptyState(candidateCount) {
    return {
        version: 1,
        candidateCount: candidateCount,
        nextIndex: 0,
        physics: [],
        destruction: [],
        report: [],
        failed: 0
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
        logW("State file does not match the current candidate list, starting over");
        return emptyState(candidateCount);
    }

    state.physics = state.physics || [];
    state.destruction = state.destruction || [];
    state.report = state.report || [];
    state.failed = state.failed || 0;

    logI("Resuming at " + state.nextIndex + "/" + candidateCount + " (" + state.physics.length + " hits so far)");
    return state;
}

function saveState(state) {
    wkit.SaveToResources(settings.statePathInResources, JSON.stringify(state));
}

///////////////////////////////////////////////////////////////////////////////
// Mesh inspection
///////////////////////////////////////////////////////////////////////////////

///Each of these RED property names occurs in exactly one meshMeshParam* class, so the
///presence of the property identifies the parameter type without needing its class name.
const PARAM_PROPERTY_TO_TYPE = {
    "physicsData": PHYSICS_PARAM,
    "bonds": "meshMeshParamDestructionBonds",
    "boneChunkMasks": "meshMeshParamDestructionBoneChunkMapping",
    "chunkOffsets": "meshMeshParamDestructionChunkIndicesOffsets",
    "isInstantRemovable": "meshMeshParamDestructionStepData",
    "regionData": "meshMeshParamBakedDestructionData"
};

const PARAM_PROPERTIES = Object.keys(PARAM_PROPERTY_TO_TYPE);

function asCount(value) {
    if (value === undefined || value === null) {
        return -1;
    }
    const number = Number(value);
    return isNaN(number) ? -1 : number;
}

///Direct access to the generated CMesh members. Only available when the host does not
///restrict `CR2WFile.RootChunk` to its declared `RedBaseClass` type.
function inspectTyped(path, cr2w) {
    const root = cr2w ? cr2w.RootChunk : null;
    if (!root) {
        return { usable: false };
    }

    let parameters = null;
    try {
        parameters = root.Parameters;
    } catch (_) {}

    if (!parameters || asCount(parameters.Count) < 0) {
        return { usable: false };
    }

    const names = [];
    forEachItem(parameters, function (handle) {
        if (!handle) {
            return;
        }

        let chunk = null;
        try { chunk = handle.Chunk; } catch (_) {}
        if (!chunk) {
            try { chunk = handle.GetValue(); } catch (_) {}
        }

        const name = redTypeName(chunk);
        if (name && names.indexOf(name) < 0) {
            names.push(name);
        }
    });

    let boneCount = 0;
    try {
        const bones = root.BoneNames;
        boneCount = Math.max(asCount(bones ? bones.Count : null), 0);
    } catch (_) {}

    return { usable: true, params: names, boneCount: boneCount };
}

///`RedBaseClass.GetFromXPath(string)` is declared to return `(bool, object?)`. An `object`
///return carries no declared type, so the host cannot restrict it and the real collection
///comes through. Array elements are addressed with `:`, nested properties with `.`.
function inspectXPath(path, cr2w) {
    const root = cr2w ? cr2w.RootChunk : null;
    if (!root || typeof root.GetFromXPath !== "function") {
        return { usable: false };
    }

    let arrayResult = null;
    try {
        arrayResult = root.GetFromXPath("parameters");
    } catch (_) {
        return { usable: false };
    }

    if (!arrayResult) {
        return { usable: false };
    }

    // Item1 false means this mesh simply carries no `parameters`, which is a valid answer
    // and must not be mistaken for the access path being unavailable.
    if (!arrayResult.Item1 || !arrayResult.Item2) {
        return { usable: true, params: [], boneCount: 0 };
    }

    const count = asCount(arrayResult.Item2.Count);
    if (count < 0) {
        return { usable: false };
    }

    const names = [];
    for (let i = 0; i < count; i++) {
        for (let p = 0; p < PARAM_PROPERTIES.length; p++) {
            const property = PARAM_PROPERTIES[p];
            let probe = null;
            try {
                probe = root.GetFromXPath("parameters:" + i + "." + property);
            } catch (_) {
                continue;
            }

            if (probe && probe.Item1 && probe.Item2 !== null && probe.Item2 !== undefined) {
                const name = PARAM_PROPERTY_TO_TYPE[property];
                if (names.indexOf(name) < 0) {
                    names.push(name);
                }
                break;
            }
        }
    }

    let boneCount = 0;
    try {
        const bones = root.GetFromXPath("boneNames");
        if (bones && bones.Item1 && bones.Item2) {
            boneCount = Math.max(asCount(bones.Item2.Count), 0);
        }
    } catch (_) {}

    return { usable: true, params: names, boneCount: boneCount };
}

///Guaranteed fallback: serialize to RED-JSON and look for the parameter class names in
///the text. No parsing, since a mesh JSON is large and only the `$type` values matter.
function inspectJson(path) {
    let text = null;
    try {
        text = wkit.GetFile(path, OpenAs.Json);
    } catch (e) {
        return { usable: false };
    }

    if (!text) {
        return { usable: false };
    }

    const json = String(text);
    if (json.length === 0) {
        return { usable: false };
    }

    const names = [];
    for (let p = 0; p < PARAM_PROPERTIES.length; p++) {
        const name = PARAM_PROPERTY_TO_TYPE[PARAM_PROPERTIES[p]];
        if (json.indexOf('"' + name + '"') >= 0 && names.indexOf(name) < 0) {
            names.push(name);
        }
    }

    return { usable: true, params: names, boneCount: 0 };
}

const inspectionStrategies = [
    { name: "typed", needsCr2w: true, run: inspectTyped },
    { name: "xpath", needsCr2w: true, run: inspectXPath },
    { name: "json", needsCr2w: false, run: inspectJson }
];

let activeStrategy = null;

function runStrategy(strategy, path) {
    if (!strategy.needsCr2w) {
        return strategy.run(path, null);
    }

    let cr2w = null;
    try {
        cr2w = wkit.GetFileFromArchive(path, OpenAs.CR2W);
    } catch (e) {
        return { usable: false, error: "load failed: " + e };
    }

    if (!cr2w) {
        return { usable: false, error: "not found in archives" };
    }

    try {
        return strategy.run(path, cr2w);
    } catch (e) {
        return { usable: false, error: "read failed: " + e };
    } finally {
        try { cr2w.Dispose(); } catch (_) {}
    }
}

///Reads the mesh parameter types of one mesh. The way the host exposes the CR2W object
///graph decides which access path works, so the strategies are probed once and the first
///one that can reach `CMesh.parameters` is kept for the whole run.
function inspectMesh(path) {
    if (activeStrategy) {
        const result = runStrategy(activeStrategy, path);
        if (result.usable) {
            return result;
        }
        return { error: result.error || (activeStrategy.name + " could not read this mesh") };
    }

    let lastError = null;

    for (let i = 0; i < inspectionStrategies.length; i++) {
        const strategy = inspectionStrategies[i];
        const result = runStrategy(strategy, path);

        if (result.usable) {
            activeStrategy = strategy;
            logI("Mesh inspection strategy: " + strategy.name);
            return result;
        }

        lastError = result.error || lastError;
    }

    return { error: lastError || "no inspection strategy could read the mesh parameters" };
}

///////////////////////////////////////////////////////////////////////////////
// Main
///////////////////////////////////////////////////////////////////////////////

(function main() {
    const candidates = getCandidates();
    if (candidates.length === 0) {
        throw new Error("No mesh candidates to process");
    }

    let end = candidates.length;
    if (settings.limit > 0 && settings.limit < end) {
        end = settings.limit;
        logI("Limit active: only the first " + end + " meshes are processed");
    }

    const state = loadState(candidates.length);

    // If parameter type names never resolve, every mesh looks physics-less. Catch that
    // early instead of letting the run finish with an empty list.
    let paramsResolved = 0;
    let selfCheckDone = state.nextIndex > 0;

    for (let i = state.nextIndex; i < end; i++) {
        const path = candidates[i];
        const result = inspectMesh(path);

        if (!result.error) {
            paramsResolved += result.params.length;
        }

        if (!selfCheckDone && (i - state.nextIndex + 1) >= settings.selfCheckSamples) {
            selfCheckDone = true;
            if (paramsResolved === 0) {
                logW("No mesh parameter type could be read in the first " + settings.selfCheckSamples + " meshes.");
                logW("Every mesh will look physics-less. Sample: " + candidates[state.nextIndex]);
            } else {
                logI("Self check ok, resolved " + paramsResolved + " mesh parameters in the first " + settings.selfCheckSamples + " meshes");
            }
        }

        if (result.error) {
            state.failed++;
            if (settings.writeReport) {
                state.report.push({ path: path, error: result.error });
            }
        } else {
            let hasPhysics = false;
            let hasDestruction = false;

            for (let p = 0; p < result.params.length; p++) {
                const name = result.params[p];
                if (name === PHYSICS_PARAM) {
                    hasPhysics = true;
                } else if (DESTRUCTION_PARAMS[name]) {
                    hasDestruction = true;
                }
            }

            if (hasPhysics) {
                state.physics.push(path);
                if (hasDestruction) {
                    state.destruction.push(path);
                }

                if (settings.writeReport) {
                    state.report.push({
                        path: path,
                        hasDestruction: hasDestruction,
                        boneCount: result.boneCount,
                        params: result.params
                    });
                }
            }
        }

        state.nextIndex = i + 1;

        if (settings.progressEvery > 0 && state.nextIndex % settings.progressEvery === 0) {
            logI(state.nextIndex + "/" + end + " - physics: " + state.physics.length + ", destruction: " + state.destruction.length + ", failed: " + state.failed);
        }

        if (settings.saveEvery > 0 && state.nextIndex % settings.saveEvery === 0) {
            saveState(state);
        }
    }

    saveState(state);

    state.physics.sort();
    state.destruction.sort();

    wkit.SaveToResources(settings.outputPathInResources, state.physics.join("\n"));
    logI("Wrote " + state.physics.length + " paths to resources/" + settings.outputPathInResources);

    if (settings.writeDestructionList) {
        wkit.SaveToResources(settings.destructionOutputPathInResources, state.destruction.join("\n"));
        logI("Wrote " + state.destruction.length + " paths to resources/" + settings.destructionOutputPathInResources);
    }

    if (settings.writeReport) {
        wkit.SaveToResources(settings.reportPathInResources, JSON.stringify({
            version: 1,
            source: settings.source,
            scanned: state.nextIndex,
            physicsCount: state.physics.length,
            destructionCount: state.destruction.length,
            failedCount: state.failed,
            entries: state.report
        }, null, 2));
        logI("Wrote report to resources/" + settings.reportPathInResources);
    }

    logI("Done. scanned=" + state.nextIndex + " physics=" + state.physics.length + " destruction=" + state.destruction.length + " failed=" + state.failed);
})();
