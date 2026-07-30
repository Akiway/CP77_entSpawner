// @author Akiway
// @version 1.0.0
//
// @description
// Diagnostic for extract_destructible_meshes.wscript. Runs in a few seconds and prints
// which parts of the WolvenKit scripting API behave as expected:
//   1. can wkit.GetArchiveFiles() be enumerated, and with which access shape
//   2. do archive entries expose a readable depot path
//   3. can a known mesh be opened and its CMesh.parameters read
//   4. can the RED class name of a parameter be resolved
//
// Run this first when the extraction finds no meshes, then paste the log.

const settings = {
    // Entries pulled from the archives before stopping, keep it small.
    maxArchiveEntries: 200,

    // Meshes known to carry meshMeshParamPhysics, used for the read-back test.
    testMeshes: [
        "base\\environment\\decoration\\public_utility\\fixtures\\newspaper_stand\\newspaper_stand_d_dst.mesh",
        "base\\environment\\decoration\\misc\\paper\\newspaper\\newspaper_h_folded_tabloid.mesh"
    ]
};

function logI(m) { try { logger.Info("[probe] " + m); } catch (_) {} }
function logW(m) { try { logger.Warning("[probe] " + m); } catch (_) {} }
function logE(m) { try { logger.Error("[probe] " + m); } catch (_) {} }

function describe(value) {
    if (value === undefined) return "undefined";
    if (value === null) return "null";
    try {
        return String(value);
    } catch (e) {
        return "<toString failed: " + e + ">";
    }
}

function probeMember(owner, name) {
    try {
        const value = owner[name];
        if (value === undefined) {
            return "undefined";
        }
        if (typeof value === "function") {
            return "function";
        }
        return describe(value);
    } catch (e) {
        return "<threw: " + e + ">";
    }
}

///////////////////////////////////////////////////////////////////////////////
// 1 + 2. Archive enumeration
///////////////////////////////////////////////////////////////////////////////

function probeArchives() {
    logI("--- 1. wkit.GetArchiveFiles() ---");

    let source = null;
    try {
        source = wkit.GetArchiveFiles();
    } catch (e) {
        logE("GetArchiveFiles() threw: " + e);
        return;
    }

    if (!source) {
        logE("GetArchiveFiles() returned " + describe(source));
        return;
    }

    logI("returned object: " + describe(source));
    logI("  .Count    -> " + probeMember(source, "Count"));
    logI("  .Length   -> " + probeMember(source, "Length"));
    logI("  .GetEnumerator -> " + probeMember(source, "GetEnumerator"));

    const firstEntries = [];

    const strategies = [
        {
            name: "for-of",
            run: function (collection, collect) {
                let count = 0;
                for (const item of collection) {
                    collect(item);
                    count++;
                    if (count >= settings.maxArchiveEntries) break;
                }
                return count;
            }
        },
        {
            name: "GetEnumerator",
            run: function (collection, collect) {
                const enumerator = collection.GetEnumerator();
                let count = 0;
                while (enumerator.MoveNext()) {
                    collect(enumerator.Current);
                    count++;
                    if (count >= settings.maxArchiveEntries) break;
                }
                try { enumerator.Dispose(); } catch (_) {}
                return count;
            }
        },
        {
            name: "indexer",
            run: function (collection, collect) {
                let length = collection.Count;
                if (length === undefined || length === null) {
                    length = collection.Length;
                }
                if (length === undefined || length === null) {
                    throw new Error("no Count/Length");
                }
                let count = 0;
                for (let i = 0; i < length && count < settings.maxArchiveEntries; i++) {
                    collect(collection[i]);
                    count++;
                }
                return count;
            }
        }
    ];

    let workingEntry = null;

    for (let s = 0; s < strategies.length; s++) {
        const strategy = strategies[s];
        firstEntries.length = 0;

        try {
            const count = strategy.run(wkit.GetArchiveFiles(), function (item) {
                if (firstEntries.length < 5) {
                    firstEntries.push(item);
                }
                if (!workingEntry && item) {
                    workingEntry = item;
                }
            });
            logI(strategy.name + " -> " + count + " entries");
        } catch (e) {
            logW(strategy.name + " -> failed: " + e);
        }
    }

    logI("--- 2. archive entry properties ---");

    if (!workingEntry) {
        logE("No archive entry could be read, enumeration is the problem.");
        return;
    }

    logI("entry toString: " + describe(workingEntry));
    const properties = ["FileName", "Name", "NameOrHash", "Extension", "NameHash64", "Size"];
    for (let i = 0; i < properties.length; i++) {
        logI("  ." + properties[i] + " -> " + probeMember(workingEntry, properties[i]));
    }

    let meshCount = 0;
    let namedCount = 0;
    try {
        let scanned = 0;
        for (const item of wkit.GetArchiveFiles()) {
            let name = "";
            try { name = String(item.FileName || ""); } catch (_) {}
            // Unresolved hashes come back as "<hash>.bin" instead of a depot path.
            if (name && !/^\d+\.bin$/.test(name)) {
                namedCount++;
            }
            if (name.toLowerCase().endsWith(".mesh")) {
                meshCount++;
                if (meshCount <= 3) {
                    logI("  mesh sample: " + name);
                }
            }
            scanned++;
            if (scanned >= 20000) break;
        }
        logI("in the first " + scanned + " entries: " + namedCount + " named, " + meshCount + " .mesh");
    } catch (e) {
        logW("sample scan failed: " + e);
    }
}

///////////////////////////////////////////////////////////////////////////////
// 3 + 4. Mesh parameters
///////////////////////////////////////////////////////////////////////////////

// Each of these RED property names belongs to exactly one meshMeshParam* class.
const PARAM_PROPERTIES = [
    "physicsData",
    "bonds",
    "boneChunkMasks",
    "chunkOffsets",
    "isInstantRemovable",
    "regionData"
];

function probeXPath(root) {
    logI("  -- GetFromXPath route --");

    let result = null;
    try {
        result = root.GetFromXPath("parameters");
    } catch (e) {
        logE("  GetFromXPath('parameters') threw: " + e);
        return;
    }

    if (!result) {
        logE("  GetFromXPath('parameters') returned " + describe(result));
        return;
    }

    logI("  tuple .Item1 -> " + probeMember(result, "Item1"));
    logI("  tuple .Item2 -> " + probeMember(result, "Item2"));

    const array = result.Item2;
    if (!array) {
        logE("  no parameters collection behind the tuple");
        return;
    }

    logI("  parameters.Count -> " + probeMember(array, "Count"));

    const count = Number(array.Count);
    if (isNaN(count)) {
        logE("  parameters count is not readable");
        return;
    }

    for (let i = 0; i < count; i++) {
        const found = [];
        for (let p = 0; p < PARAM_PROPERTIES.length; p++) {
            try {
                const probe = root.GetFromXPath("parameters:" + i + "." + PARAM_PROPERTIES[p]);
                if (probe && probe.Item1 && probe.Item2 !== null && probe.Item2 !== undefined) {
                    found.push(PARAM_PROPERTIES[p]);
                }
            } catch (e) {
                found.push(PARAM_PROPERTIES[p] + "=<threw: " + e + ">");
            }
        }
        logI("  parameters:" + i + " -> " + (found.length ? found.join(", ") : "none of the known properties"));
    }
}

function probeMesh(path) {
    logI("--- 3. " + path + " ---");

    let cr2w = null;
    try {
        cr2w = wkit.GetFileFromArchive(path, OpenAs.CR2W);
    } catch (e) {
        logE("GetFileFromArchive(OpenAs.CR2W) threw: " + e);
        return;
    }

    if (!cr2w) {
        logE("GetFileFromArchive returned null, path not found in the archives");
        return;
    }

    const root = cr2w.RootChunk;
    if (!root) {
        logE("RootChunk is " + describe(root));
        return;
    }

    logI("RootChunk: " + describe(root));
    logI("  .Parameters -> " + probeMember(root, "Parameters"));
    logI("  .BoneNames  -> " + probeMember(root, "BoneNames"));
    logI("  .GetFromXPath -> " + probeMember(root, "GetFromXPath"));
    logI("  .GetPropertyNames -> " + probeMember(root, "GetPropertyNames"));

    // Members typed as a RED class get restricted to their declared type by the host,
    // which hides the generated properties. Anything declared `object` comes through
    // unrestricted, so GetFromXPath is the way in.
    probeXPath(root);

    const parameters = root.Parameters;
    if (!parameters) {
        logW("CMesh.Parameters is not reachable, see the GetFromXPath results above");
        return;
    }

    logI("  Parameters.Count -> " + probeMember(parameters, "Count"));

    const chunks = [];

    try {
        let n = 0;
        for (const handle of parameters) {
            chunks.push(handle);
            n++;
        }
        logI("  for-of over Parameters -> " + n);
    } catch (e) {
        logW("  for-of over Parameters failed: " + e);
    }

    if (chunks.length === 0) {
        try {
            const count = parameters.Count;
            for (let i = 0; i < count; i++) {
                chunks.push(parameters[i]);
            }
            logI("  indexer over Parameters -> " + chunks.length);
        } catch (e) {
            logW("  indexer over Parameters failed: " + e);
        }
    }

    logI("--- 4. parameter type names ---");

    if (chunks.length === 0) {
        logE("No parameter could be read from this mesh.");
        return;
    }

    for (let i = 0; i < chunks.length; i++) {
        const handle = chunks[i];
        let chunk = null;
        try { chunk = handle.Chunk; } catch (e) { logW("  [" + i + "] .Chunk threw: " + e); }
        if (!chunk) {
            try { chunk = handle.GetValue(); } catch (_) {}
        }

        if (!chunk) {
            logW("  [" + i + "] no chunk behind the handle (" + describe(handle) + ")");
            continue;
        }

        let byType = "n/a";
        try {
            const type = chunk.GetType();
            byType = type ? describe(type.Name) : "null type";
        } catch (e) {
            byType = "<threw: " + e + ">";
        }

        logI("  [" + i + "] ToString=" + describe(chunk) + " | GetType().Name=" + byType + " | PhysicsData=" + probeMember(chunk, "PhysicsData"));
    }
}

(function main() {
    logI("WolvenKit " + (function () { try { return wkit.ProgramVersion(); } catch (_) { return "?"; } })());

    probeArchives();

    for (let i = 0; i < settings.testMeshes.length; i++) {
        probeMesh(settings.testMeshes[i]);
    }

    logI("Probe done.");
})();
