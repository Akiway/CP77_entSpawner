// @author Akiway
// @version 1.1.0
//
// @description
// Build a class lookup list for entity templates (.ent) used by World Builder.
//
// Input:
// - resources/spawnable/entity/templates/paths_ent.txt (preferred)
// - resources/spawnables/entity/templates/paths_ent.txt
// - any discovered resources/**/paths_ent.txt
//
// Output line format:
//   {className} {path}
// where className may be empty, yielding:
//    {path}
//
// Example lines:
//   LiftControllerPS base\gameplay\devices\elevators\platform_elevator\q305_bunker_elevator.ent
//    base\some\entity\without\device_class.ent

const settings = {
    listPathCandidatesInResources: [
        "spawnable\\entity\\templates\\paths_ent.txt",
        "spawnables\\entity\\templates\\paths_ent.txt",
        "entity\\templates\\paths_ent.txt",
        "paths_ent.txt"
    ],
    outputPathInResources: "data/static/entity_template_device_classes.txt",
    alsoSaveToRaw: false,
    outputPathInRaw: "entity_template_device_classes.txt",
    resumeFromExisting: true,
    // If true, excluded paths keep their previously cached class (when present in existing output).
    // If false, excluded paths are always emitted with an empty class.
    keepExistingExcludedClassNames: false,
    // Case-insensitive partial path filters. Any .ent path containing one of these
    // fragments is still written to output but class extraction is skipped.
    // Examples:
    // "ep1\\quest\\main_quests\\q302\\"
    // "base\\worlds\\03_night_city\\sectors\\"
    excludedPathFragments: [
    ],
    saveEvery: 300,
    progressEvery: 200,
    persistentStateWindowChars: 4000
};

function logInfo(message) {
    try { logger.Info("[ent-classes] " + message); } catch (_) {}
}

function logWarn(message) {
    try { logger.Warning("[ent-classes] " + message); } catch (_) {}
}

function logError(message) {
    try { logger.Error("[ent-classes] " + message); } catch (_) {}
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

function normalizeExcludedPathFragment(value) {
    var normalized = normalizeForPathCompare(value);
    if (!normalized) {
        return "";
    }

    // Keep fragment matching broad and user-friendly:
    // remove optional leading/trailing slashes.
    normalized = normalized.replace(/^\\+/, "").replace(/\\+$/, "");
    return normalized;
}

function buildExcludedFragments() {
    var fragments = [];
    var seen = Object.create(null);
    var input = settings.excludedPathFragments || [];

    for (var i = 0; i < input.length; i++) {
        var fragment = normalizeExcludedPathFragment(input[i]);
        if (!fragment) {
            continue;
        }

        if (hasOwn(seen, fragment)) {
            continue;
        }

        seen[fragment] = true;
        fragments.push(fragment);
    }

    return fragments;
}

function isExcludedEntPath(path, excludedFragments) {
    if (!excludedFragments || excludedFragments.length === 0) {
        return false;
    }

    var normalizedPath = normalizeForPathCompare(path);
    for (var i = 0; i < excludedFragments.length; i++) {
        if (normalizedPath.indexOf(excludedFragments[i]) >= 0) {
            return true;
        }
    }

    return false;
}

function parseEntPathsFromText(text, sourceLabel) {
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

        var path = normalizeResourcePath(raw);
        if (!path || !/\.ent$/i.test(path)) {
            continue;
        }

        var key = normalizeForPathCompare(path);
        if (hasOwn(seen, key)) {
            continue;
        }

        seen[key] = true;
        out.push(path);
    }

    logInfo("Loaded " + out.length + " template paths from " + sourceLabel);
    return out;
}

function discoverListFiles() {
    var result = [];
    var seen = Object.create(null);

    try {
        var files = wkit.GetProjectFiles("resources");
        if (files) {
            for (var entry of files) {
                var rel = normalizeResourcePath(entry);
                if (!rel) {
                    continue;
                }

                var norm = normalizeForPathCompare(rel);
                if (!/\\paths_ent\.txt$/i.test(norm) && norm !== "paths_ent.txt") {
                    continue;
                }

                if (!hasOwn(seen, norm)) {
                    seen[norm] = true;
                    result.push(rel);
                }
            }
        }
    } catch (_) {}

    for (var i = 0; i < settings.listPathCandidatesInResources.length; i++) {
        var candidate = normalizeResourcePath(settings.listPathCandidatesInResources[i]);
        var candidateKey = normalizeForPathCompare(candidate);
        if (!hasOwn(seen, candidateKey)) {
            seen[candidateKey] = true;
            result.push(candidate);
        }
    }

    result.sort(function(a, b) {
        return normalizeForPathCompare(a) < normalizeForPathCompare(b) ? -1 : 1;
    });

    return result;
}

function loadEntPathList() {
    var listFiles = discoverListFiles();
    var out = [];
    var seen = Object.create(null);
    var loadedAny = false;

    for (var i = 0; i < listFiles.length; i++) {
        var relPath = listFiles[i];
        var text = null;

        try {
            text = wkit.LoadFromResources(relPath);
        } catch (_) {}

        if (!text || asString(text).trim() === "") {
            continue;
        }

        loadedAny = true;
        var parsed = parseEntPathsFromText(text, "resources/" + relPath);
        for (var j = 0; j < parsed.length; j++) {
            var entPath = parsed[j];
            var key = normalizeForPathCompare(entPath);
            if (hasOwn(seen, key)) {
                continue;
            }

            seen[key] = true;
            out.push(entPath);
        }
    }

    if (!loadedAny) {
        throw new Error(
            "Could not load any paths_ent.txt from resources. Tried: " + listFiles.join(", ")
        );
    }

    return out;
}

function loadEntJsonText(path) {
    var text = null;

    try {
        text = wkit.GetFile(path, OpenAs.Json);
    } catch (_) {}

    if (!text) {
        try {
            // Fallback for hosts where enum binding differs.
            text = wkit.GetFile(path, 2);
        } catch (_) {}
    }

    return text ? asString(text) : null;
}

function extractControllerClassFromTypeText(typeText) {
    var text = asString(typeText);
    if (!text) {
        return "";
    }

    var match = text.match(/([A-Za-z_][A-Za-z0-9_]*ControllerPS)\b/);
    return match ? match[1] : "";
}

function pickBestClass(candidates) {
    if (!Array.isArray(candidates) || candidates.length === 0) {
        return "";
    }

    var generic = {
        gameDeviceComponentPS: true,
        ScriptableDeviceComponentPS: true,
        MasterControllerPS: true
    };

    for (var i = 0; i < candidates.length; i++) {
        var cls = candidates[i];
        if (!generic[cls]) {
            return cls;
        }
    }

    return candidates[0];
}

function extractControllerClassesInSlice(textSlice) {
    var found = [];
    var seen = Object.create(null);
    var regex = /([A-Za-z_][A-Za-z0-9_]*ControllerPS)\b/g;
    var match = null;

    while ((match = regex.exec(textSlice)) !== null) {
        var cls = match[1];
        if (!cls || hasOwn(seen, cls)) {
            continue;
        }
        seen[cls] = true;
        found.push(cls);
    }

    return found;
}

function extractControllerClassFromEntJsonText(jsonText) {
    var text = asString(jsonText);
    if (!text) {
        return "";
    }

    // First pass: classes near "persistentState" for best precision.
    var lower = text.toLowerCase();
    var needle = "\"persistentstate\"";
    var index = lower.indexOf(needle);
    var contextualClasses = [];
    var contextualSeen = Object.create(null);

    while (index >= 0) {
        var slice = text.substring(index, Math.min(text.length, index + settings.persistentStateWindowChars));
        var classes = extractControllerClassesInSlice(slice);
        for (var i = 0; i < classes.length; i++) {
            var cls = classes[i];
            if (!hasOwn(contextualSeen, cls)) {
                contextualSeen[cls] = true;
                contextualClasses.push(cls);
            }
        }

        index = lower.indexOf(needle, index + needle.length);
    }

    var bestContextClass = pickBestClass(contextualClasses);
    if (bestContextClass) {
        return bestContextClass;
    }

    // Second pass: any class token in the whole ent JSON.
    var globalClasses = extractControllerClassesInSlice(text);
    var bestGlobalClass = pickBestClass(globalClasses);
    if (bestGlobalClass) {
        return bestGlobalClass;
    }

    // Last fallback for explicit type strings that might omit ControllerPS token boundaries.
    var typed = extractControllerClassFromTypeText(text);
    if (typed) {
        return typed;
    }

    return "";
}

function parseExistingOutputLines(text) {
    var map = Object.create(null);
    var lines = asString(text).split(/\r?\n/);

    for (var i = 0; i < lines.length; i++) {
        var raw = asString(lines[i]);
        if (!raw || raw.trim() === "") {
            continue;
        }

        if (raw.trim().indexOf("//") === 0 || raw.trim().indexOf("#") === 0 || raw.trim().indexOf(";") === 0) {
            continue;
        }

        var className = "";
        var path = "";

        if (/^\s/.test(raw)) {
            path = normalizeResourcePath(raw.trim());
        } else {
            var parts = raw.split(/\s+/, 2);
            if (parts.length === 1) {
                path = normalizeResourcePath(parts[0]);
            } else {
                className = asString(parts[0]).trim();
                path = normalizeResourcePath(raw.substring(parts[0].length).trim());
            }
        }

        if (!path || !/\.ent$/i.test(path)) {
            continue;
        }

        map[normalizeForPathCompare(path)] = {
            path: path,
            className: className
        };
    }

    return map;
}

function loadExistingOutputMap() {
    var text = null;

    try {
        text = wkit.LoadFromResources(settings.outputPathInResources);
    } catch (_) {}

    if (!text) {
        try {
            text = wkit.LoadRawJsonFromProject(settings.outputPathInResources, "txt");
        } catch (_) {}
    }

    if (!text) {
        return Object.create(null);
    }

    return parseExistingOutputLines(text);
}

function buildOutputText(pathEntriesInOrder, byPathKey) {
    var lines = [];

    for (var i = 0; i < pathEntriesInOrder.length; i++) {
        var path = pathEntriesInOrder[i];
        var key = normalizeForPathCompare(path);
        var entry = byPathKey[key];
        if (!entry) {
            entry = { path: path, className: "" };
        }

        var className = asString(entry.className).trim();
        if (className) {
            lines.push(className + " " + entry.path);
        } else {
            lines.push(" " + entry.path);
        }
    }

    return lines.join("\n") + "\n";
}

function saveOutput(text, reason) {
    try {
        wkit.SaveToResources(settings.outputPathInResources, text);
    } catch (err) {
        logWarn("SaveToResources failed (" + reason + "): " + err);
        if (settings.alsoSaveToRaw) {
            try {
                wkit.SaveToRaw(settings.outputPathInRaw, text);
                logInfo("Saved fallback output to raw/" + settings.outputPathInRaw);
            } catch (rawErr) {
                logError("SaveToRaw failed: " + rawErr);
            }
        }
    }
}

(function main() {
    logInfo("Starting entity class extraction");

    var entPaths = loadEntPathList();
    if (entPaths.length === 0) {
        throw new Error("No .ent paths found in list files");
    }

    logInfo("Total unique .ent entries: " + entPaths.length);
    var excludedFragments = buildExcludedFragments();
    if (excludedFragments.length > 0) {
        logInfo("Excluded partial paths configured: " + excludedFragments.length);
    }

    var byPathKey = Object.create(null);
    if (settings.resumeFromExisting) {
        byPathKey = loadExistingOutputMap();
        logInfo("Loaded existing entries: " + Object.keys(byPathKey).length);
    }

    var stats = {
        total: entPaths.length,
        processed: 0,
        computed: 0,
        reused: 0,
        excluded: 0,
        missingClass: 0,
        missingJson: 0,
        saveCount: 0
    };

    for (var i = 0; i < entPaths.length; i++) {
        var path = entPaths[i];
        var key = normalizeForPathCompare(path);

        stats.processed += 1;

        if (isExcludedEntPath(path, excludedFragments)) {
            var existingEntry = byPathKey[key];
            var existingClassName = existingEntry ? asString(existingEntry.className).trim() : "";

            byPathKey[key] = {
                path: path,
                className: settings.keepExistingExcludedClassNames ? existingClassName : ""
            };

            stats.excluded += 1;
        } else if (settings.resumeFromExisting && hasOwn(byPathKey, key)) {
            stats.reused += 1;
        } else {
            var jsonText = loadEntJsonText(path);
            var className = "";

            if (!jsonText) {
                stats.missingJson += 1;
            } else {
                className = extractControllerClassFromEntJsonText(jsonText);
            }

            if (!className) {
                stats.missingClass += 1;
            }

            byPathKey[key] = {
                path: path,
                className: className
            };

            stats.computed += 1;
        }

        if ((stats.processed % settings.progressEvery) === 0 || stats.processed === entPaths.length) {
            logInfo(
                "Progress " + stats.processed + "/" + stats.total +
                " (computed=" + stats.computed +
                ", reused=" + stats.reused +
                ", excluded=" + stats.excluded +
                ", noClass=" + stats.missingClass +
                ", noJson=" + stats.missingJson + ")"
            );
        }

        if ((stats.processed % settings.saveEvery) === 0) {
            var partialText = buildOutputText(entPaths, byPathKey);
            saveOutput(partialText, "periodic");
            stats.saveCount += 1;
        }
    }

    var outText = buildOutputText(entPaths, byPathKey);
    saveOutput(outText, "final");

    logInfo(
        "Done. total=" + stats.total +
        ", computed=" + stats.computed +
        ", reused=" + stats.reused +
        ", excluded=" + stats.excluded +
        ", missingClass=" + stats.missingClass +
        ", missingJson=" + stats.missingJson +
        ", periodicSaves=" + stats.saveCount +
        ", output=resources/" + settings.outputPathInResources
    );
})();
