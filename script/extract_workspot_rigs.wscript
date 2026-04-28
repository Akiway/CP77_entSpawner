// @author Akiway
// @version 1.0.0
//
// @description
// Build data/static/workspot_rigs.json from workspot paths listed in:
// data/spawnables/ai/aiSpot/paths_workspot.txt
// (also supports paths.workspot.txt fallback names).
//
// Output shape:
// {
//   "version": 1,
//   "workspots": {
//     "base\\workspots\\...\\some.workspot": [
//       "base\\characters\\...\\some_skeleton.rig"
//     ]
//   }
// }

const settings = {
    workspotListDirInResources: "aiSpot",
    workspotListFallbackFiles: [
        "paths_workspot.txt"
    ],
    outputPathInResources: "workspot_rigs.json",
    debugPathInResources: "data/static/workspot_rigs_debug.json",
    includeEmptyWorkspots: true,
    resumeFromExisting: true,
    reuseEmptyCachedEntries: false,
    forceRebuild: false,
    progressEvery: 100,
    saveEvery: 250,
    maxTraversalDepth: 40,
    maxTraversalNodes: 80000,
    resolveRigHashes: true
};

function logInfo(message) {
    try {
        logger.Info("[workspot-rigs] " + message);
    } catch (_) {}
}

function logWarn(message) {
    try {
        logger.Warning("[workspot-rigs] " + message);
    } catch (_) {}
}

function logError(message) {
    try {
        logger.Error("[workspot-rigs] " + message);
    } catch (_) {}
}

function asString(value) {
    if (value === null || value === undefined) {
        return "";
    }
    return String(value);
}

function hasOwn(obj, key) {
    return Object.prototype.hasOwnProperty.call(obj, key);
}

function normalizeForPathCompare(value) {
    return asString(value).replace(/\//g, "\\").toLowerCase();
}

function normalizeResourcePath(value) {
    var s = asString(value).trim();
    if (!s) {
        return "";
    }

    while (
        s.length >= 2 &&
        ((s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') ||
         (s.charAt(0) === "'" && s.charAt(s.length - 1) === "'"))
    ) {
        s = s.substring(1, s.length - 1).trim();
    }

    if (!s) {
        return "";
    }

    return s.replace(/\//g, "\\");
}

function normalizeRigPath(value) {
    var p = normalizeResourcePath(value);
    if (!p) {
        return null;
    }

    var lower = p.toLowerCase();
    if (lower.length < 5 || lower.substring(lower.length - 4) !== ".rig") {
        return null;
    }

    return lower;
}

function normalizeWorkspotPath(value) {
    var p = normalizeResourcePath(value);
    if (!p) {
        return null;
    }

    var lower = p.toLowerCase();
    if (lower.length < 10 || lower.substring(lower.length - 9) !== ".workspot") {
        return null;
    }

    return p;
}

function normalizeRigList(list) {
    var result = [];
    var seen = Object.create(null);

    if (!Array.isArray(list)) {
        return result;
    }

    for (var i = 0; i < list.length; i++) {
        var normalized = normalizeRigPath(list[i]);
        if (!normalized) {
            continue;
        }
        if (hasOwn(seen, normalized)) {
            continue;
        }
        seen[normalized] = true;
        result.push(normalized);
    }

    result.sort();
    return result;
}

function parseJsonSafe(text, label) {
    if (!text || asString(text).trim() === "") {
        return null;
    }

    try {
        return JSON.parse(asString(text));
    } catch (err) {
        logWarn("Invalid JSON for " + label + ": " + err);
        return null;
    }
}

function parseWorkspotPathsFromText(text, sourceLabel) {
    var out = [];
    var seen = Object.create(null);
    var lines = asString(text).split(/\r?\n/);

    for (var i = 0; i < lines.length; i++) {
        var raw = asString(lines[i]).trim();
        if (!raw) {
            continue;
        }
        if (raw.indexOf("//") === 0 || raw.indexOf("#") === 0 || raw.indexOf(";") === 0) {
            continue;
        }

        var normalized = normalizeWorkspotPath(raw);
        if (!normalized) {
            continue;
        }

        var key = normalized.toLowerCase();
        if (hasOwn(seen, key)) {
            continue;
        }

        seen[key] = true;
        out.push(normalized);
    }

    logInfo("Loaded " + out.length + " workspots from " + sourceLabel);
    return out;
}

function discoverWorkspotListFiles() {
    var result = [];
    var seen = Object.create(null);
    var base = normalizeForPathCompare(settings.workspotListDirInResources);
    if (base.charAt(base.length - 1) !== "\\") {
        base += "\\";
    }

    try {
        var files = wkit.GetProjectFiles("resources");
        if (files) {
            for (var entry of files) {
                var rel = asString(entry);
                if (!rel) {
                    continue;
                }

                var norm = normalizeForPathCompare(rel);
                if (norm.indexOf(base) !== 0) {
                    continue;
                }

                if (norm.substring(norm.length - 4) !== ".txt") {
                    continue;
                }

                if (norm.indexOf("workspot") < 0) {
                    continue;
                }

                if (!hasOwn(seen, norm)) {
                    seen[norm] = true;
                    result.push(rel.replace(/\//g, "\\"));
                }
            }
        }
    } catch (_) {}

    if (result.length === 0) {
        for (var i = 0; i < settings.workspotListFallbackFiles.length; i++) {
            var fallback = settings.workspotListFallbackFiles[i];
            var fallbackNorm = normalizeForPathCompare(fallback);
            if (!hasOwn(seen, fallbackNorm)) {
                seen[fallbackNorm] = true;
                result.push(fallback.replace(/\//g, "\\"));
            }
        }
    }

    result.sort();
    return result;
}

function loadTargetWorkspots() {
    var files = discoverWorkspotListFiles();
    var all = [];
    var seen = Object.create(null);

    for (var i = 0; i < files.length; i++) {
        var relPath = files[i];
        var text = null;

        try {
            text = wkit.LoadFromResources(relPath);
        } catch (_) {}

        if (!text || asString(text).trim() === "") {
            continue;
        }

        var parsed = parseWorkspotPathsFromText(text, "resources/" + relPath);
        for (var j = 0; j < parsed.length; j++) {
            var workspot = parsed[j];
            var key = workspot.toLowerCase();
            if (hasOwn(seen, key)) {
                continue;
            }
            seen[key] = true;
            all.push(workspot);
        }
    }

    all.sort();
    return all;
}

function normalizeHashString(value) {
    if (value === null || value === undefined) {
        return null;
    }

    var s = asString(value).trim();
    if (!s) {
        return null;
    }

    if (!/^\d+$/.test(s)) {
        return null;
    }

    if (s === "0") {
        return null;
    }

    return s;
}

function isPathCandidateWithExtension(value, preferredExtension) {
    var s = normalizeResourcePath(value);
    if (!s) {
        return false;
    }

    var lower = s.toLowerCase();
    if (preferredExtension && preferredExtension.length > 0) {
        return lower.substring(lower.length - preferredExtension.length) === preferredExtension;
    }

    return s.indexOf("\\") >= 0 || s.indexOf("/") >= 0;
}

function findPathInJsonObject(jsonObj, preferredExtension) {
    if (!jsonObj || typeof jsonObj !== "object") {
        return null;
    }

    var ext = preferredExtension ? preferredExtension.toLowerCase() : "";

    var direct = [
        jsonObj.FileName,
        jsonObj.fileName,
        jsonObj.Path,
        jsonObj.path
    ];
    for (var i = 0; i < direct.length; i++) {
        if (isPathCandidateWithExtension(direct[i], ext)) {
            return normalizeResourcePath(direct[i]);
        }
    }

    var stack = [{ node: jsonObj, depth: 0 }];
    var visited = new Set();
    var visitedCount = 0;
    var maxDepth = 16;
    var maxNodes = 10000;

    while (stack.length > 0) {
        var item = stack.pop();
        var node = item.node;
        var depth = item.depth;

        if (!node || typeof node !== "object") {
            continue;
        }
        if (visited.has(node)) {
            continue;
        }

        visited.add(node);
        visitedCount += 1;
        if (visitedCount > maxNodes) {
            break;
        }

        if (Array.isArray(node)) {
            if (depth >= maxDepth) {
                continue;
            }
            for (var a = 0; a < node.length; a++) {
                var arrVal = node[a];
                if (typeof arrVal === "string") {
                    if (isPathCandidateWithExtension(arrVal, ext)) {
                        return normalizeResourcePath(arrVal);
                    }
                } else if (arrVal && typeof arrVal === "object") {
                    stack.push({ node: arrVal, depth: depth + 1 });
                }
            }
            continue;
        }

        for (var key in node) {
            if (!hasOwn(node, key)) {
                continue;
            }

            var val = node[key];
            if (typeof val === "string") {
                var keyLower = asString(key).toLowerCase();
                var hinted = keyLower.indexOf("path") >= 0 || keyLower.indexOf("file") >= 0 || keyLower === "$value";
                if (hinted && isPathCandidateWithExtension(val, ext)) {
                    return normalizeResourcePath(val);
                }
                if (!ext && isPathCandidateWithExtension(val, ext)) {
                    return normalizeResourcePath(val);
                }
            } else if (val && typeof val === "object" && depth < maxDepth) {
                stack.push({ node: val, depth: depth + 1 });
            }
        }
    }

    return null;
}

var hashToPathCache = Object.create(null);

function tryResolveHashToPath(hashValue, preferredExtension) {
    if (!settings.resolveRigHashes) {
        return null;
    }

    var hashString = normalizeHashString(hashValue);
    if (!hashString) {
        return null;
    }

    var cacheKey = hashString + "|" + asString(preferredExtension || "");
    if (hasOwn(hashToPathCache, cacheKey)) {
        return hashToPathCache[cacheKey];
    }

    var resolved = null;
    try {
        var gameFile = wkit.GetFile(hashString, OpenAs.GameFile);
        if (gameFile) {
            if (typeof gameFile.Name === "string" && gameFile.Name.length > 0) {
                resolved = gameFile.Name;
            } else if (typeof gameFile.FileName === "string" && gameFile.FileName.length > 0) {
                resolved = gameFile.FileName;
            } else if (typeof gameFile.fileName === "string" && gameFile.fileName.length > 0) {
                resolved = gameFile.fileName;
            }
        }
    } catch (_) {}

    if (!resolved) {
        var jsonText = null;
        try {
            jsonText = wkit.GetFile(hashString, OpenAs.Json);
        } catch (_) {}
        if (!jsonText) {
            try {
                jsonText = wkit.GetFile(hashString, 2);
            } catch (_) {}
        }

        if (jsonText) {
            var dto = parseJsonSafe(jsonText, "hash " + hashString);
            if (dto && typeof dto === "object") {
                resolved = findPathInJsonObject(dto, preferredExtension || "");
            }
        }
    }

    resolved = resolved ? normalizeResourcePath(resolved) : null;
    hashToPathCache[cacheKey] = resolved;
    return resolved;
}

function addRigPath(pathValue, rigsSet) {
    var normalized = normalizeRigPath(pathValue);
    if (!normalized) {
        return;
    }
    rigsSet[normalized] = true;
}

function addRigFromValue(value, rigsSet, allowHashResolve) {
    if (value === null || value === undefined) {
        return;
    }

    if (typeof value === "string") {
        addRigPath(value, rigsSet);
        var asHash = normalizeHashString(value);
        if (allowHashResolve && asHash) {
            var resolved0 = tryResolveHashToPath(asHash, ".rig");
            if (resolved0) {
                addRigPath(resolved0, rigsSet);
            }
        }
        return;
    }

    if (typeof value === "number") {
        if (allowHashResolve) {
            var resolvedNum = tryResolveHashToPath(value, ".rig");
            if (resolvedNum) {
                addRigPath(resolvedNum, rigsSet);
            }
        }
        return;
    }

    if (typeof value !== "object") {
        return;
    }

    if (typeof value.$value === "string") {
        addRigPath(value.$value, rigsSet);
    }
    if (typeof value.Path === "string") {
        addRigPath(value.Path, rigsSet);
    }
    if (typeof value.path === "string") {
        addRigPath(value.path, rigsSet);
    }
    if (typeof value.ResolvedText === "string") {
        addRigPath(value.ResolvedText, rigsSet);
    }
    if (typeof value.resolvedText === "string") {
        addRigPath(value.resolvedText, rigsSet);
    }

    if (value.DepotPath !== undefined && value.DepotPath !== null) {
        addRigFromValue(value.DepotPath, rigsSet, allowHashResolve);
    }
    if (value.depotPath !== undefined && value.depotPath !== null) {
        addRigFromValue(value.depotPath, rigsSet, allowHashResolve);
    }

    if (allowHashResolve) {
        var hashValue = value.hash;
        if (hashValue === undefined || hashValue === null) {
            hashValue = value.Hash;
        }
        if (hashValue === undefined || hashValue === null) {
            hashValue = value.$value;
        }

        var resolvedPath = tryResolveHashToPath(hashValue, ".rig");
        if (resolvedPath) {
            addRigPath(resolvedPath, rigsSet);
        }
    }
}

function extractRigsFromWorkspotJson(workspotJson) {
    var rigsSet = Object.create(null);

    var data = null;
    var root = null;
    var tree = null;
    var finalAnimsets = null;

    if (workspotJson && typeof workspotJson === "object") {
        data = workspotJson.Data || workspotJson.data || null;
        root =
            (data && (data.RootChunk || data.rootChunk)) ||
            workspotJson.RootChunk ||
            workspotJson.rootChunk ||
            null;
        tree =
            (root && (root.workspotTree || root.WorkspotTree)) ||
            workspotJson.workspotTree ||
            workspotJson.WorkspotTree ||
            null;
        finalAnimsets = tree && (tree.finalAnimsets || tree.FinalAnimsets);
    }

    if (Array.isArray(finalAnimsets)) {
        for (var fa = 0; fa < finalAnimsets.length; fa++) {
            var animset = finalAnimsets[fa];
            if (!animset || typeof animset !== "object") {
                continue;
            }
            addRigFromValue(animset.rig, rigsSet, true);
            addRigFromValue(animset.Rig, rigsSet, true);
            addRigFromValue(animset, rigsSet, false);
        }
    }

    var stack = [{ node: workspotJson, depth: 0, rigHint: false }];
    var visited = new Set();
    var visitedCount = 0;

    while (stack.length > 0) {
        var item = stack.pop();
        var node = item.node;
        var depth = item.depth;
        var rigHint = item.rigHint === true;
        var nodeType = typeof node;

        if (nodeType === "string") {
            addRigPath(node, rigsSet);
            continue;
        }

        if (!node || nodeType !== "object") {
            continue;
        }

        if (visited.has(node)) {
            continue;
        }

        visited.add(node);
        visitedCount += 1;
        if (visitedCount > settings.maxTraversalNodes) {
            logWarn("Traversal capped at " + settings.maxTraversalNodes + " nodes");
            break;
        }

        addRigFromValue(node, rigsSet, rigHint);

        if (depth >= settings.maxTraversalDepth) {
            continue;
        }

        if (Array.isArray(node)) {
            for (var i = 0; i < node.length; i++) {
                var arrValue = node[i];
                if (typeof arrValue === "string") {
                    addRigPath(arrValue, rigsSet);
                } else if (arrValue && typeof arrValue === "object") {
                    stack.push({ node: arrValue, depth: depth + 1, rigHint: rigHint });
                }
            }
            continue;
        }

        for (var key in node) {
            if (!hasOwn(node, key)) {
                continue;
            }

            var value = node[key];
            var keyLower = asString(key).toLowerCase();
            var keyHasRig = keyLower === "rig" || keyLower.indexOf("rig") >= 0;
            if (keyHasRig) {
                addRigFromValue(value, rigsSet, true);
            }

            if (typeof value === "string") {
                addRigPath(value, rigsSet);
            } else if (value && typeof value === "object") {
                stack.push({ node: value, depth: depth + 1, rigHint: keyHasRig || rigHint });
            }
        }
    }

    return Object.keys(rigsSet).sort();
}

function loadWorkspotJson(workspotPath) {
    var normalized = normalizeWorkspotPath(workspotPath);
    if (!normalized) {
        return null;
    }

    var jsonText = null;
    try {
        jsonText = wkit.GetFile(normalized, OpenAs.Json);
    } catch (_) {}

    if (!jsonText) {
        try {
            jsonText = wkit.GetFile(normalized, 2);
        } catch (_) {}
    }

    if (!jsonText) {
        return null;
    }

    return parseJsonSafe(jsonText, "workspot " + normalized);
}

function loadExistingWorkspotMap() {
    var text = null;

    try {
        text = wkit.LoadFromResources(settings.outputPathInResources);
    } catch (_) {}

    if (!text) {
        try {
            text = wkit.LoadRawJsonFromProject(settings.outputPathInResources, "json");
        } catch (_) {}
    }

    if (!text) {
        return Object.create(null);
    }

    var parsed = parseJsonSafe(text, settings.outputPathInResources);
    if (!parsed || typeof parsed !== "object") {
        return Object.create(null);
    }

    var map = null;
    if (parsed.workspots && typeof parsed.workspots === "object") {
        map = parsed.workspots;
    } else {
        map = parsed;
    }

    var cleaned = Object.create(null);
    for (var key in map) {
        if (!hasOwn(map, key)) {
            continue;
        }
        cleaned[key] = normalizeRigList(map[key]);
    }

    return cleaned;
}

function shouldReuseExistingWorkspot(workspotMap, workspotPath) {
    if (!hasOwn(workspotMap, workspotPath)) {
        return false;
    }

    if (settings.reuseEmptyCachedEntries) {
        return true;
    }

    var current = workspotMap[workspotPath];
    return Array.isArray(current) && current.length > 0;
}

function buildOutputPayload(workspotMap) {
    var keys = Object.keys(workspotMap).sort();
    var ordered = {};

    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        ordered[key] = normalizeRigList(workspotMap[key]);
    }

    return {
        version: 1,
        workspots: ordered
    };
}

function saveOutput(workspotMap, reason) {
    var payload = buildOutputPayload(workspotMap);
    var json = JSON.stringify(payload, null, 2);

    try {
        wkit.SaveToResources(settings.outputPathInResources, json);
    } catch (err) {
        logWarn("SaveToResources failed (" + reason + "): " + err);
    }

    logInfo("Saved " + reason + " -> resources/" + settings.outputPathInResources);
}

(function main() {
    logInfo("Starting workspot rig extraction");

    var targetWorkspots = loadTargetWorkspots();
    if (targetWorkspots.length === 0) {
        throw new Error(
            "No workspots loaded from resources/" +
            settings.workspotListDirInResources +
            " (expected .txt list with .workspot entries)"
        );
    }

    logInfo("Found " + targetWorkspots.length + " target workspots from resources list(s)");

    var workspotMap = Object.create(null);
    if (settings.resumeFromExisting && !settings.forceRebuild) {
        var existing = loadExistingWorkspotMap();
        var pruned = Object.create(null);

        for (var p = 0; p < targetWorkspots.length; p++) {
            var workspot = targetWorkspots[p];
            if (hasOwn(existing, workspot)) {
                pruned[workspot] = existing[workspot];
            }
        }

        workspotMap = pruned;
        logInfo(
            "Loaded existing cache entries: " + Object.keys(existing).length +
            ", reusable for current target list: " + Object.keys(workspotMap).length
        );
    }

    var stats = {
        handled: 0,
        computed: 0,
        skippedExisting: 0,
        filesLoaded: 0,
        filesMissingOrInvalid: 0,
        withRigs: 0,
        withoutRigs: 0,
        hashResolvesAttempted: 0
    };

    var originalTryResolveHashToPath = tryResolveHashToPath;
    tryResolveHashToPath = function(hashValue, preferredExtension) {
        stats.hashResolvesAttempted += 1;
        return originalTryResolveHashToPath(hashValue, preferredExtension);
    };

    for (var i = 0; i < targetWorkspots.length; i++) {
        var workspotPath = targetWorkspots[i];
        stats.handled += 1;

        if (!settings.forceRebuild && shouldReuseExistingWorkspot(workspotMap, workspotPath)) {
            stats.skippedExisting += 1;
            if (stats.handled % settings.progressEvery === 0 || stats.handled === targetWorkspots.length) {
                logInfo(
                    "Progress " + stats.handled + "/" + targetWorkspots.length +
                    " (computed=" + stats.computed +
                    ", skipped=" + stats.skippedExisting + ")"
                );
            }
            continue;
        }

        var workspotJson = loadWorkspotJson(workspotPath);
        var rigs = [];

        if (workspotJson) {
            stats.filesLoaded += 1;
            rigs = extractRigsFromWorkspotJson(workspotJson);
        } else {
            stats.filesMissingOrInvalid += 1;
            rigs = [];
        }

        var normalizedRigs = normalizeRigList(rigs);
        if (normalizedRigs.length > 0) {
            stats.withRigs += 1;
        } else {
            stats.withoutRigs += 1;
        }

        if (settings.includeEmptyWorkspots || normalizedRigs.length > 0) {
            workspotMap[workspotPath] = normalizedRigs;
        }

        stats.computed += 1;

        if (stats.handled % settings.progressEvery === 0 || stats.handled === targetWorkspots.length) {
            logInfo(
                "Progress " + stats.handled + "/" + targetWorkspots.length +
                " (computed=" + stats.computed +
                ", withRigs=" + stats.withRigs +
                ", withoutRigs=" + stats.withoutRigs + ")"
            );
        }

        if (settings.saveEvery > 0 && stats.handled % settings.saveEvery === 0) {
            saveOutput(workspotMap, "checkpoint " + stats.handled + "/" + targetWorkspots.length);
        }
    }

    saveOutput(workspotMap, "final");

    logInfo("Finished");
    logInfo("Workspots total: " + targetWorkspots.length);
    logInfo("Workspots computed: " + stats.computed);
    logInfo("Workspots skipped(existing): " + stats.skippedExisting);
    logInfo("Workspot files loaded: " + stats.filesLoaded);
    logInfo("Workspot files missing/invalid: " + stats.filesMissingOrInvalid);
    logInfo("Rig results(with/without): " + stats.withRigs + "/" + stats.withoutRigs);
    logInfo("Output: resources/" + settings.outputPathInResources);

    try {
        wkit.SaveToResources(settings.debugPathInResources, JSON.stringify({
            timestamp: new Date().toISOString(),
            settings: settings,
            stats: stats
        }, null, 2));
        logInfo("Debug: resources/" + settings.debugPathInResources);
    } catch (errDebug) {
        logWarn("Failed to write debug report: " + errDebug);
    }

    if (stats.withRigs === 0) {
        logWarn("No rigs were resolved. Check counters above (filesLoaded and filesMissingOrInvalid).");
    }
})();
