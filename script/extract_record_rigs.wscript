// @author Akiway
// @version 1.0.0
//
// @description
// Build data/static/record_rigs.json from record IDs listed in
// resources/data/spawnables/entity/records/*.txt.
// The output matches entSpawner runtime expectations:
// {
//   "version": 1,
//   "records": {
//     "Some.RecordID": [
//       "base\\characters\\...\\some_skeleton.rig"
//     ]
//   }
// }

const settings = {
    recordListDirInResources: "records",
    recordListFallbackFiles: [
        "records.txt"
    ],
    attemptWarmTweakDb: true,
    tweakDbWarmupSleepMs: 1500,
    debugSampleCount: 12,
    outputPathInResources: "record_rigs.json",
    alsoSaveToRaw: false,
    resumeFromExisting: true,
    reuseEmptyCachedEntries: false,
    forceRebuild: false,
    includeEmptyRecords: true,
    progressEvery: 50,
    saveEvery: 100,
    maxTemplateDepth: 64,
    maxTemplateNodes: 60000,
    maxRecordSearchDepth: 32,
    maxRecordSearchNodes: 20000
};

function logInfo(message) {
    try {
        logger.Info("[record-rigs] " + message);
    } catch (_) {}
}

function logWarn(message) {
    try {
        logger.Warning("[record-rigs] " + message);
    } catch (_) {}
}

function logError(message) {
    try {
        logger.Error("[record-rigs] " + message);
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

function enumerableToArray(value) {
    var out = [];
    if (!value) {
        return out;
    }

    try {
        for (var item of value) {
            out.push(item);
        }
    } catch (_) {}

    return out;
}

function normalizeResourcePath(value) {
    var s = asString(value).trim();
    if (!s) {
        return "";
    }

    // Strip outer quotes if present.
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

    // Normalize separators for RED resource paths.
    s = s.replace(/\//g, "\\");
    return s;
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

function parseRecordIdsFromText(text, sourceLabel) {
    var ids = [];
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

        var key = raw.toLowerCase();
        if (hasOwn(seen, key)) {
            continue;
        }
        seen[key] = true;
        ids.push(raw);
    }

    logInfo("Loaded " + ids.length + " records from " + sourceLabel);
    return ids;
}

function discoverRecordListFiles() {
    var result = [];
    var seen = Object.create(null);
    var base = normalizeForPathCompare(settings.recordListDirInResources);
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

                if (!hasOwn(seen, norm)) {
                    seen[norm] = true;
                    result.push(rel.replace(/\//g, "\\"));
                }
            }
        }
    } catch (_) {}

    if (result.length === 0) {
        for (var i = 0; i < settings.recordListFallbackFiles.length; i++) {
            var fallback = settings.recordListFallbackFiles[i];
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

function loadTargetRecordIds() {
    var files = discoverRecordListFiles();
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

        var parsed = parseRecordIdsFromText(text, "resources/" + relPath);
        for (var j = 0; j < parsed.length; j++) {
            var id = parsed[j];
            var key = id.toLowerCase();
            if (hasOwn(seen, key)) {
                continue;
            }
            seen[key] = true;
            all.push(id);
        }
    }

    all.sort();
    return all;
}

function listTweakDbRecords() {
    try {
        return enumerableToArray(wkit.GetRecords());
    } catch (_) {
        return [];
    }
}

function tryWarmTweakDb() {
    var initial = listTweakDbRecords();
    if (initial.length > 0) {
        return { warmed: true, records: initial, strategy: "already-loaded" };
    }

    // Heuristic warmup: opening a local tweak/yaml document triggers LoadTweakDB in WolvenKit.
    var warmupCandidates = [
        "__record_rigs_warmup__.yaml",
        "resources\\__record_rigs_warmup__.yaml"
    ];

    try {
        wkit.SaveToResources("__record_rigs_warmup__.yaml", "{}\n");
    } catch (_) {}

    var opened = false;
    for (var i = 0; i < warmupCandidates.length; i++) {
        try {
            if (wkit.OpenDocument(warmupCandidates[i])) {
                opened = true;
                break;
            }
        } catch (_) {}
    }

    if (opened && settings.tweakDbWarmupSleepMs > 0) {
        try {
            wkit.Sleep(settings.tweakDbWarmupSleepMs);
        } catch (_) {}
    }

    var after = listTweakDbRecords();
    try {
        wkit.DeleteFile("__record_rigs_warmup__.yaml", "resources");
    } catch (_) {}

    return {
        warmed: after.length > 0,
        records: after,
        strategy: opened ? "open-temp-yaml" : "none"
    };
}

function buildRecordCaseMap(allTdbRecords) {
    var lowerToExact = Object.create(null);

    for (var i = 0; i < allTdbRecords.length; i++) {
        var id = asString(allTdbRecords[i]);
        if (!id) {
            continue;
        }
        var lower = id.toLowerCase();
        if (!hasOwn(lowerToExact, lower)) {
            lowerToExact[lower] = id;
        }
    }

    return lowerToExact;
}

function loadExistingRecordMap() {
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
    if (parsed.records && typeof parsed.records === "object") {
        map = parsed.records;
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

function shouldReuseExistingRecord(recordMap, recordId) {
    if (!hasOwn(recordMap, recordId)) {
        return false;
    }

    if (settings.reuseEmptyCachedEntries) {
        return true;
    }

    var current = recordMap[recordId];
    return Array.isArray(current) && current.length > 0;
}

function buildOutputPayload(recordMap) {
    var keys = Object.keys(recordMap).sort();
    var ordered = {};

    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        ordered[key] = normalizeRigList(recordMap[key]);
    }

    return {
        version: 1,
        records: ordered
    };
}

function saveOutput(recordMap, reason) {
    var payload = buildOutputPayload(recordMap);
    var json = JSON.stringify(payload, null, 2);

    try {
        wkit.SaveToResources(settings.outputPathInResources, json);
    } catch (err) {
        logWarn("SaveToResources failed (" + reason + "): " + err);
    }

    if (settings.alsoSaveToRaw) {
        try {
            wkit.SaveToRaw(settings.outputPathInResources, json);
        } catch (err2) {
            logWarn("SaveToRaw failed (" + reason + "): " + err2);
        }
    }

    logInfo("Saved " + reason + " -> resources/" + settings.outputPathInResources);
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

function looksLikeResourcePath(text) {
    var s = normalizeResourcePath(text);
    if (!s) {
        return false;
    }

    // Typical RED depot path characteristics.
    return s.indexOf("\\") >= 0 || s.indexOf("/") >= 0 || s.toLowerCase().indexOf(".ent") >= 0;
}

function extractLocatorFromValue(value) {
    if (value === null || value === undefined) {
        return null;
    }

    if (typeof value === "string") {
        var str = normalizeResourcePath(value);
        if (!str) {
            return null;
        }
        var hashString = normalizeHashString(str);
        if (hashString) {
            return hashString;
        }
        if (looksLikeResourcePath(str)) {
            return str;
        }
        return null;
    }

    if (typeof value === "number") {
        return normalizeHashString(value);
    }

    if (typeof value !== "object") {
        return null;
    }

    // Common RED json wrappers.
    var directCandidates = [
        value.$value,
        value.Path,
        value.path,
        value.ResolvedText,
        value.resolvedText,
        value.DepotPath,
        value.depotPath,
        value.resourcePath,
        value.ResourcePath
    ];

    for (var i = 0; i < directCandidates.length; i++) {
        var candidate = extractLocatorFromValue(directCandidates[i]);
        if (candidate) {
            return candidate;
        }
    }

    var hashCandidate = normalizeHashString(value.hash) || normalizeHashString(value.Hash);
    if (hashCandidate) {
        return hashCandidate;
    }

    return null;
}

function extractLocatorFromFlatText(flatText) {
    var flatObj = parseJsonSafe(flatText, "flat entityTemplatePath");
    if (!flatObj) {
        return null;
    }

    var locator = extractLocatorFromValue(flatObj);
    if (locator) {
        return locator;
    }

    return null;
}

function findEntityTemplateNode(recordObj) {
    if (!recordObj || typeof recordObj !== "object") {
        return null;
    }

    var stack = [{ node: recordObj, depth: 0 }];
    var visited = new Set();
    var visitedCount = 0;

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
        if (visitedCount > settings.maxRecordSearchNodes) {
            break;
        }

        if (Array.isArray(node)) {
            if (depth >= settings.maxRecordSearchDepth) {
                continue;
            }
            for (var i = 0; i < node.length; i++) {
                if (node[i] && typeof node[i] === "object") {
                    stack.push({ node: node[i], depth: depth + 1 });
                }
            }
            continue;
        }

        for (var key in node) {
            if (!hasOwn(node, key)) {
                continue;
            }

            var value = node[key];
            if (asString(key).toLowerCase() === "entitytemplatepath") {
                return value;
            }

            if (depth < settings.maxRecordSearchDepth && value && typeof value === "object") {
                stack.push({ node: value, depth: depth + 1 });
            }
        }
    }

    return null;
}

function getTemplateLocator(recordId) {
    var flatPath = recordId + ".entityTemplatePath";

    try {
        var flatText = wkit.GetFlat(flatPath);
        var fromFlat = extractLocatorFromFlatText(flatText);
        if (fromFlat) {
            return { locator: fromFlat, source: "flat" };
        }
    } catch (_) {}

    try {
        var recordText = wkit.GetRecord(recordId);
        var recordObj = parseJsonSafe(recordText, "record " + recordId);
        if (recordObj && typeof recordObj === "object") {
            var templateNode = findEntityTemplateNode(recordObj);
            var fromRecord = extractLocatorFromValue(templateNode);
            if (fromRecord) {
                return { locator: fromRecord, source: "record" };
            }
        }
    } catch (_) {}

    return null;
}

function toTemplateCacheKey(locator) {
    var normalized = normalizeResourcePath(locator);
    if (!normalized) {
        return null;
    }

    var hashString = normalizeHashString(normalized);
    if (hashString) {
        return "hash:" + hashString;
    }

    return "path:" + normalized.toLowerCase();
}

function addRigPath(pathValue, rigsSet) {
    var normalized = normalizeRigPath(pathValue);
    if (!normalized) {
        return;
    }
    rigsSet[normalized] = true;
}

var hashToPathCache = Object.create(null);

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

    // Fast-path for common metadata wrappers.
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

    // Bounded traversal to discover any path-like fields.
    var stack = [{ node: jsonObj, depth: 0 }];
    var visited = new Set();
    var visitedCount = 0;
    var maxDepth = 16;
    var maxNodes = 8000;

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

function tryResolveHashToPath(hashValue, preferredExtension) {
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

    // Fallback: open by hash as JSON and mine metadata/path fields.
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

function addRigFromValue(value, rigsSet, allowHashResolve) {
    if (value === null || value === undefined) {
        return;
    }

    if (typeof value === "string") {
        addRigPath(value, rigsSet);
        return;
    }

    if (typeof value !== "object") {
        return;
    }

    // Common wrappers.
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
        var resolvedPath = tryResolveHashToPath(value.hash || value.Hash || value.$value, ".rig");
        if (resolvedPath) {
            addRigPath(resolvedPath, rigsSet);
        }
    }
}

function extractRigsFromTemplateJson(templateJson) {
    var rigsSet = Object.create(null);
    var stack = [{ node: templateJson, depth: 0, rigHint: false }];
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
        if (visitedCount > settings.maxTemplateNodes) {
            logWarn("Template traversal capped at " + settings.maxTemplateNodes + " nodes");
            break;
        }

        addRigFromValue(node, rigsSet, rigHint);

        if (depth >= settings.maxTemplateDepth) {
            continue;
        }

        if (Array.isArray(node)) {
            for (var i = 0; i < node.length; i++) {
                var arrValue = node[i];
                if (typeof arrValue === "string") {
                    addRigPath(arrValue, rigsSet);
                }
                if (arrValue && typeof arrValue === "object") {
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

function loadTemplateJson(locator) {
    var normalizedLocator = normalizeResourcePath(locator);
    if (!normalizedLocator) {
        return null;
    }

    var jsonText = null;

    try {
        jsonText = wkit.GetFile(normalizedLocator, OpenAs.Json);
    } catch (_) {}

    if (!jsonText) {
        try {
            // Fallback when enum binding is unavailable in some hosts.
            jsonText = wkit.GetFile(normalizedLocator, 2);
        } catch (_) {}
    }

    if (!jsonText) {
        return null;
    }

    return parseJsonSafe(jsonText, "template " + normalizedLocator);
}

(function main() {
    logInfo("Starting record rig extraction");

    var targetRecords = loadTargetRecordIds();
    if (targetRecords.length === 0) {
        throw new Error(
            "No record IDs loaded from resources/" +
            settings.recordListDirInResources +
            " (expected .txt files, e.g. records.txt)"
        );
    }

    logInfo("Found " + targetRecords.length + " target records from resources list(s)");

    var tdbAllRecords = [];
    var tdbWarmStrategy = "disabled";
    if (settings.attemptWarmTweakDb) {
        var warmup = tryWarmTweakDb();
        tdbAllRecords = warmup.records || [];
        tdbWarmStrategy = warmup.strategy;
        logInfo("TweakDB warmup strategy: " + tdbWarmStrategy + ", records visible: " + tdbAllRecords.length);
    } else {
        tdbAllRecords = listTweakDbRecords();
        logInfo("TweakDB warmup skipped, records visible: " + tdbAllRecords.length);
    }

    if (tdbAllRecords.length === 0) {
        throw new Error(
            "TweakDB is not loaded in WolvenKit. Open Tweak Browser (or any .yaml/.tweak) once, then run this script again."
        );
    }

    var lowerCaseToTdb = buildRecordCaseMap(tdbAllRecords);
    var resolvedTargetRecords = [];
    var remappedByCase = 0;
    var notInTdbList = 0;
    for (var r = 0; r < targetRecords.length; r++) {
        var inputId = targetRecords[r];
        var canonical = lowerCaseToTdb[inputId.toLowerCase()];
        if (canonical) {
            if (canonical !== inputId) {
                remappedByCase += 1;
            }
            resolvedTargetRecords.push(canonical);
        } else {
            notInTdbList += 1;
            resolvedTargetRecords.push(inputId);
        }
    }
    targetRecords = resolvedTargetRecords;
    logInfo("Target remap by case: " + remappedByCase + ", not found in loaded TweakDB list: " + notInTdbList);

    var recordMap = Object.create(null);
    if (settings.resumeFromExisting && !settings.forceRebuild) {
        var existing = loadExistingRecordMap();
        var pruned = Object.create(null);

        for (var p = 0; p < targetRecords.length; p++) {
            var rid = targetRecords[p];
            if (hasOwn(existing, rid)) {
                pruned[rid] = existing[rid];
            }
        }

        recordMap = pruned;
        logInfo(
            "Loaded existing cache entries: " + Object.keys(existing).length +
            ", reusable for current target list: " + Object.keys(recordMap).length
        );
    }

    var templateRigCache = Object.create(null);

    var stats = {
        handled: 0,
        computed: 0,
        skippedExisting: 0,
        tdbRecordsVisible: tdbAllRecords.length,
        tdbWarmStrategy: tdbWarmStrategy,
        tdbHasRecordTrue: 0,
        tdbHasRecordFalse: 0,
        fromFlat: 0,
        fromRecord: 0,
        noTemplate: 0,
        templateCacheHits: 0,
        templatesLoaded: 0,
        templatesMissing: 0,
        withRigs: 0,
        withoutRigs: 0,
        debugSamples: []
    };

    for (var i = 0; i < targetRecords.length; i++) {
        var recordId2 = targetRecords[i];
        stats.handled += 1;

        if (!settings.forceRebuild && shouldReuseExistingRecord(recordMap, recordId2)) {
            stats.skippedExisting += 1;
            if (stats.handled % settings.progressEvery === 0 || stats.handled === targetRecords.length) {
                logInfo(
                    "Progress " + stats.handled + "/" + targetRecords.length +
                    " (computed=" + stats.computed +
                    ", skipped=" + stats.skippedExisting + ")"
                );
            }
            continue;
        }

        var hasRecord = false;
        try {
            hasRecord = wkit.HasTDBID(recordId2);
        } catch (_) {}
        if (hasRecord) {
            stats.tdbHasRecordTrue += 1;
        } else {
            stats.tdbHasRecordFalse += 1;
        }

        var rigs = [];
        var locatorInfo = getTemplateLocator(recordId2);
        if (locatorInfo && locatorInfo.locator) {
            if (locatorInfo.source === "flat") {
                stats.fromFlat += 1;
            } else if (locatorInfo.source === "record") {
                stats.fromRecord += 1;
            }

            var templateKey = toTemplateCacheKey(locatorInfo.locator);
            if (templateKey && hasOwn(templateRigCache, templateKey)) {
                stats.templateCacheHits += 1;
                rigs = templateRigCache[templateKey];
            } else {
                var templateJson = loadTemplateJson(locatorInfo.locator);
                if (templateJson) {
                    stats.templatesLoaded += 1;
                    rigs = extractRigsFromTemplateJson(templateJson);
                } else {
                    stats.templatesMissing += 1;
                    rigs = [];
                }

                if (templateKey) {
                    templateRigCache[templateKey] = rigs;
                }
            }
        } else {
            stats.noTemplate += 1;
            rigs = [];
        }

        if (stats.debugSamples.length < settings.debugSampleCount) {
            var sample = null;
            if (!hasRecord || !locatorInfo || !locatorInfo.locator) {
                sample = {
                    record: recordId2,
                    hasTdbId: hasRecord,
                    locatorSource: locatorInfo ? locatorInfo.source : "",
                    locator: locatorInfo ? asString(locatorInfo.locator) : "",
                    hasFlatEntityTemplatePath: false
                };

                try {
                    var probeFlat = wkit.GetFlat(recordId2 + ".entityTemplatePath");
                    sample.hasFlatEntityTemplatePath = probeFlat !== null && probeFlat !== undefined && asString(probeFlat) !== "";
                } catch (_) {}
            } else if (locatorInfo && locatorInfo.locator) {
                sample = {
                    record: recordId2,
                    hasTdbId: hasRecord,
                    locatorSource: locatorInfo.source,
                    locator: asString(locatorInfo.locator)
                };
            }

            if (sample) {
                stats.debugSamples.push(sample);
            }
        }

        var normalizedRigs = normalizeRigList(rigs);
        if (normalizedRigs.length > 0) {
            stats.withRigs += 1;
        } else {
            stats.withoutRigs += 1;
        }

        if (settings.includeEmptyRecords || normalizedRigs.length > 0) {
            recordMap[recordId2] = normalizedRigs;
        }

        stats.computed += 1;

        if (stats.handled % settings.progressEvery === 0 || stats.handled === targetRecords.length) {
            logInfo(
                "Progress " + stats.handled + "/" + targetRecords.length +
                " (computed=" + stats.computed +
                ", withRigs=" + stats.withRigs +
                ", withoutRigs=" + stats.withoutRigs +
                ", templateCacheHits=" + stats.templateCacheHits + ")"
            );
        }

        if (settings.saveEvery > 0 && stats.handled % settings.saveEvery === 0) {
            saveOutput(recordMap, "checkpoint " + stats.handled + "/" + targetRecords.length);
        }
    }

    saveOutput(recordMap, "final");

    logInfo("Finished");
    logInfo("Records total: " + targetRecords.length);
    logInfo("Records computed: " + stats.computed);
    logInfo("Records skipped(existing): " + stats.skippedExisting);
    logInfo("TweakDB visible records: " + stats.tdbRecordsVisible + " (warmup=" + stats.tdbWarmStrategy + ")");
    logInfo("HasTDBID true/false: " + stats.tdbHasRecordTrue + "/" + stats.tdbHasRecordFalse);
    logInfo("Locator source(flat/record/missing): " + stats.fromFlat + "/" + stats.fromRecord + "/" + stats.noTemplate);
    logInfo("Templates loaded/missing/cacheHits: " + stats.templatesLoaded + "/" + stats.templatesMissing + "/" + stats.templateCacheHits);
    logInfo("Rig results(with/without): " + stats.withRigs + "/" + stats.withoutRigs);
    logInfo("Output: resources/" + settings.outputPathInResources);

    var debugReportPath = "data/static/record_rigs_debug.json";
    try {
        wkit.SaveToResources(debugReportPath, JSON.stringify({
            timestamp: new Date().toISOString(),
            settings: settings,
            stats: stats
        }, null, 2));
        logInfo("Debug: resources/" + debugReportPath);
    } catch (errDebug) {
        logWarn("Failed to write debug report: " + errDebug);
    }

    if (stats.withRigs === 0) {
        logWarn("No rigs were resolved. Check final counters above (especially templatesLoaded and noTemplate).");
    }
})();
