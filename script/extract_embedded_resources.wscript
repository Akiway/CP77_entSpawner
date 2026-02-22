// @author Akiway
// @version 1.0.0
//
// @description
// Extract resources listed in embedded_files_sectors.json

//////////////// Modify this //////////////////

// Try paths in this order (raw first, then resources).
const inputPathsInRawOrResources = [
    "embedded_files_sectors.json"
];

// Save a run report in project raw folder.
const writeReportToRaw = true;
const reportPathInRaw = "embedded_extract_report.json";

// Skip files that are already present in the project archive folder.
const skipAlreadyInProject = true;

// Log progress every N processed resources.
const progressInterval = 100;

///////////////////////////////////////////////

const logInfo = (msg) => logger.Info(`[extract_embedded_resources] ${msg}`);
const logWarn = (msg) => logger.Warning(`[extract_embedded_resources] ${msg}`);
const logError = (msg) => logger.Error(`[extract_embedded_resources] ${msg}`);

// Mirror WolvenKit ResourcePath.SanitizePath for stable hashing.
const sanitizeResourcePath = (text) => {
    if (!text || typeof text !== "string") {
        return "";
    }

    const trimChars = new Set(["'", "\"", "/", "\\", " ", "\n", "\r"]);
    let start = 0;
    let end = text.length - 1;

    while (start <= end && trimChars.has(text[start])) {
        start += 1;
    }
    while (end >= start && trimChars.has(text[end])) {
        end -= 1;
    }

    const trimmed = text.substring(start, end + 1);
    let out = "";
    for (const ch of trimmed) {
        if (ch === "\\" || ch === "/") {
            if (out.length === 0 || out[out.length - 1] !== "\\") {
                out += "\\";
            }
        } else {
            out += ch;
        }
    }
    return out.toLowerCase();
};

const pathHashKey = (path) => wkit.HashString(sanitizeResourcePath(path), "fnv1a64").toString();

const tryGetEmbeddedHashKey = (embeddedFileNameObj) => {
    try {
        if (embeddedFileNameObj && embeddedFileNameObj.GetRedHash) {
            return embeddedFileNameObj.GetRedHash().toString();
        }
    } catch (_) {}

    try {
        if (embeddedFileNameObj && embeddedFileNameObj.GetResolvedText) {
            const resolved = embeddedFileNameObj.GetResolvedText();
            if (resolved && resolved.length > 0) {
                return pathHashKey(resolved);
            }
        }
    } catch (_) {}

    try {
        const asString = `${embeddedFileNameObj}`;
        if (asString && asString !== "[object Object]") {
            return pathHashKey(asString);
        }
    } catch (_) {}

    return null;
};

const loadJsonText = () => {
    for (const candidatePath of inputPathsInRawOrResources) {
        let jsonText = wkit.LoadRawJsonFromProject(candidatePath, "json");
        if (jsonText && jsonText.length > 0) {
            return { source: "raw", inputPath: candidatePath, jsonText };
        }

        jsonText = wkit.LoadFromResources(candidatePath);
        if (jsonText && jsonText.length > 0) {
            return { source: "resources", inputPath: candidatePath, jsonText };
        }
    }

    return null;
};

const loaded = loadJsonText();
if (!loaded) {
    logError(`Could not load any input JSON from raw/resources. Tried: ${inputPathsInRawOrResources.join(", ")}`);
} else {
    let sectorsData = null;
    try {
        sectorsData = JSON.parse(loaded.jsonText);
    } catch (err) {
        logError(`Invalid JSON in "${loaded.inputPath}": ${err}`);
    }

    if (sectorsData && typeof sectorsData === "object") {
        const sectorByResourcePath = new Map();
        const uniqueResources = new Set();
        let invalidSectorEntries = 0;
        let invalidResourceEntries = 0;
        let totalResourceEntries = 0;

        for (const [sectorPath, resources] of Object.entries(sectorsData)) {
            if (!Array.isArray(resources)) {
                invalidSectorEntries += 1;
                logWarn(`Skipping sector "${sectorPath}" because its value is not an array.`);
                continue;
            }

            for (const resourcePath of resources) {
                totalResourceEntries += 1;

                if (typeof resourcePath !== "string" || resourcePath.length === 0) {
                    invalidResourceEntries += 1;
                    continue;
                }

                uniqueResources.add(resourcePath);
                if (!sectorByResourcePath.has(resourcePath)) {
                    sectorByResourcePath.set(resourcePath, sectorPath);
                }
            }
        }

        const resourcesToProcess = Array.from(uniqueResources);
        let extractedFromArchive = 0;
        let extractedFromEmbedded = 0;
        let skippedAlreadyPresent = 0;
        let missingInArchives = 0;
        let missingAfterBothPasses = 0;
        let processed = 0;

        logInfo(`Loaded from ${loaded.source}.`);
        logInfo(`Input path: ${loaded.inputPath}`);
        logInfo(`Sectors: ${Object.keys(sectorsData).length}`);
        logInfo(`Resource entries: ${totalResourceEntries}`);
        logInfo(`Unique resources: ${resourcesToProcess.length}`);

        const unresolved = new Set();
        for (const resourcePath of resourcesToProcess) {
            processed += 1;

            if (skipAlreadyInProject && wkit.FileExistsInProject(resourcePath)) {
                skippedAlreadyPresent += 1;
            } else if (wkit.FileExists(resourcePath)) {
                wkit.Extract(resourcePath);
                extractedFromArchive += 1;
            } else {
                unresolved.add(resourcePath);
            }

            if (processed % progressInterval === 0 || processed === resourcesToProcess.length) {
                logInfo(`Archive pass ${processed}/${resourcesToProcess.length} (directExtracted=${extractedFromArchive}, unresolved=${unresolved.size}, skipped=${skippedAlreadyPresent})`);
            }
        }

        let sectorFilesScanned = 0;
        let sectorFilesMissing = 0;
        let embeddedCandidatesSeen = 0;
        let embeddedTypeUnavailable = false;
        let embeddedPassError = null;

        if (unresolved.size > 0) {
            try {
                const unresolvedHashes = new Map();
                for (const resourcePath of unresolved) {
                    const hashKey = pathHashKey(resourcePath);
                    if (!unresolvedHashes.has(hashKey)) {
                        unresolvedHashes.set(hashKey, []);
                    }
                    unresolvedHashes.get(hashKey).push(resourcePath);
                }

                const sectorsToScan = new Set();
                for (const resourcePath of unresolved) {
                    const sectorPath = sectorByResourcePath.get(resourcePath);
                    if (sectorPath) {
                        sectorsToScan.add(sectorPath);
                    }
                }

                let sectorsProcessed = 0;
                const sectorsTotal = sectorsToScan.size;

                for (const sectorPath of sectorsToScan) {
                    sectorsProcessed += 1;
                    try {
                        const sectorFile = wkit.GetFileFromArchive(sectorPath, OpenAs.CR2W);
                        if (!sectorFile) {
                            sectorFilesMissing += 1;
                            continue;
                        }

                        sectorFilesScanned += 1;
                        const embeddedFiles = sectorFile.EmbeddedFiles;
                        if (!embeddedFiles) {
                            continue;
                        }

                        for (const embeddedFile of embeddedFiles) {
                            try {
                                embeddedCandidatesSeen += 1;
                                const hashKey = tryGetEmbeddedHashKey(embeddedFile.FileName);
                                if (!hashKey || !unresolvedHashes.has(hashKey)) {
                                    continue;
                                }

                                const candidates = unresolvedHashes.get(hashKey);
                                for (const targetPath of candidates) {
                                    if (!unresolved.has(targetPath)) {
                                        continue;
                                    }

                                    // Reuse the CR2W container returned by archive lookup.
                                    // Only the root chunk matters for SaveToProject.
                                    sectorFile.RootChunk = embeddedFile.Content;
                                    try {
                                        sectorFile.MetaData.FileName = targetPath;
                                    } catch (_) {}
                                    wkit.SaveToProject(targetPath, sectorFile);

                                    unresolved.delete(targetPath);
                                    extractedFromEmbedded += 1;
                                }
                            } catch (entryErr) {
                                if (!embeddedPassError) {
                                    embeddedPassError = `entry error: ${entryErr}`;
                                }
                            }
                        }
                    } catch (sectorErr) {
                        if (!embeddedPassError) {
                            embeddedPassError = `sector error: ${sectorErr}`;
                        }
                    }

                    if (sectorsProcessed % progressInterval === 0 || sectorsProcessed === sectorsTotal) {
                        logInfo(`Embedded pass ${sectorsProcessed}/${sectorsTotal} (embeddedExtracted=${extractedFromEmbedded}, remaining=${unresolved.size})`);
                    }
                }
            } catch (err) {
                embeddedTypeUnavailable = true;
                embeddedPassError = `${err}`;
                logError(`Embedded extraction pass failed: ${err}`);
            }
        }

        missingInArchives = unresolved.size + extractedFromEmbedded;
        missingAfterBothPasses = unresolved.size;

        const report = {
            inputPath: loaded.inputPath,
            source: loaded.source,
            sectors: Object.keys(sectorsData).length,
            totalResourceEntries,
            uniqueResources: resourcesToProcess.length,
            extracted: extractedFromArchive + extractedFromEmbedded,
            extractedFromArchive,
            extractedFromEmbedded,
            skippedAlreadyPresent,
            missingInArchives,
            missingAfterBothPasses,
            invalidSectorEntries,
            invalidResourceEntries,
            embeddedTypeUnavailable,
            embeddedPassError,
            sectorFilesScanned,
            sectorFilesMissing,
            embeddedCandidatesSeen
        };

        if (writeReportToRaw) {
            wkit.SaveToRaw(reportPathInRaw, JSON.stringify(report, null, 2));
            logInfo(`Saved report to raw: ${reportPathInRaw}`);
        }

        logInfo(`Done. extracted=${report.extracted}, direct=${extractedFromArchive}, embedded=${extractedFromEmbedded}, missing=${missingAfterBothPasses}`);
    }
}
