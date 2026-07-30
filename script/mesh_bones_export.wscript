// @author Akiway
// @version 1.0.2
//
// @description
// Export boneRigMatrices count + W positions for meshes listed in paths_bended.txt

const settings = {
    listResourcePath: "entSpawner/paths_bended.txt",
    outJson: "reports/bended_rig_matrices.json",
    outCsv: "reports/bended_rig_matrices.csv",
    firstN: 0 // 0 = all
};

function logI(m){ try{ logger.Info(m); }catch(_){} }
function logW(m){ try{ logger.Warning(m); }catch(_){} }
function logE(m){ try{ logger.Error(m); }catch(_){} }

function asNum(v, d){
    if (d === undefined) d = 0;
    if (v === null || v === undefined) return d;
    var n = Number(v);
    return isNaN(n) ? d : n;
}

function get(obj, a, b){
    if (!obj) return null;
    if (obj[a] !== undefined && obj[a] !== null) return obj[a];
    if (b && obj[b] !== undefined && obj[b] !== null) return obj[b];
    return null;
}

function normPath(p){
    return String(p || "").trim().replace(/\//g, "\\");
}

function parseList(txt){
    var out = [];
    var seen = {};
    var lines = String(txt || "").split(/\r?\n/);

    for (var i = 0; i < lines.length; i++){
        var s = lines[i].trim();
        if (!s) continue;
        if (s.indexOf("//") === 0 || s.indexOf("#") === 0 || s.indexOf(";") === 0) continue;
        s = normPath(s);
        if (!/\.mesh$/i.test(s)) continue;

        var k = s.toLowerCase();
        if (seen[k]) continue;
        seen[k] = true;
        out.push(s);
    }
    return out;
}

function csvEsc(v){
    var s = (v === null || v === undefined) ? "" : String(v);
    if (s.indexOf('"') >= 0) s = s.replace(/"/g, '""');
    if (/[,"\r\n]/.test(s)) s = '"' + s + '"';
    return s;
}

function getCr2wJson(meshPath){
    // OpenAs.Json should be safest for scripts
    var txt = null;
    try { txt = wkit.GetFile(meshPath, OpenAs.Json); } catch (_) {}
    if (!txt) {
        // fallback numeric enum in case host enum binding is odd
        try { txt = wkit.GetFile(meshPath, 2); } catch (_) {}
    }
    if (!txt) return null;

    try { return JSON.parse(String(txt)); } catch (_) { return null; }
}

function extract(meshPath){
    var dto = getCr2wJson(meshPath);
    if (!dto) return { meshPath: meshPath, error: "GetFile(OpenAs.Json) failed or invalid JSON" };

    var data = get(dto, "Data", "data");
    var root = data ? get(data, "RootChunk", "rootChunk") : null;
    if (!root) return { meshPath: meshPath, error: "RootChunk missing in JSON Data" };

    var mats = get(root, "boneRigMatrices", "BoneRigMatrices");
    if (!Array.isArray(mats)) mats = [];

    var points = [];
    for (var i = 0; i < mats.length; i++){
        var m = mats[i] || {};
        var w = get(m, "W", "w") || {};
        points.push({
            index: i,
            x: asNum(get(w, "X", "x"), 0),
            y: asNum(get(w, "Y", "y"), 0),
            z: asNum(get(w, "Z", "z"), 0)
        });
    }

    return {
        meshPath: meshPath,
        matrixCount: mats.length,
        positions: points
    };
}

(function main(){
    var raw = wkit.LoadFromResources(settings.listResourcePath);
    if (!raw || String(raw).trim() === ""){
        throw new Error("List not found/empty: resources/" + settings.listResourcePath);
    }

    var list = parseList(raw);
    if (list.length === 0) throw new Error("No mesh entries in list");
    if (settings.firstN > 0 && list.length > settings.firstN) list = list.slice(0, settings.firstN);

    logI("[rig-report] Loaded " + list.length + " meshes from resources/" + settings.listResourcePath);
    logI("[rig-report] Sample[0]: " + list[0]);

    var rows = [];
    var ok = 0, fail = 0;

    for (var i = 0; i < list.length; i++){
        if ((i + 1) % 25 === 0) logI("[rig-report] " + (i + 1) + "/" + list.length);
        var r = extract(list[i]);
        rows.push(r);
        if (r.error) fail++; else ok++;
    }

    var csv = [];
    csv.push("mesh_path,matrix_count,positions,error");
    for (var j = 0; j < rows.length; j++){
        var r2 = rows[j];
        var ptxt = "";
        if (r2.positions && r2.positions.length){
            var parts = [];
            for (var k = 0; k < r2.positions.length; k++){
                var p = r2.positions[k];
                parts.push(p.index + "(" + p.x + "," + p.y + "," + p.z + ")");
            }
            ptxt = parts.join("|");
        }
        csv.push([
            csvEsc(r2.meshPath),
            csvEsc(r2.matrixCount || 0),
            csvEsc(ptxt),
            csvEsc(r2.error || "")
        ].join(","));
    }

    wkit.SaveToResources(settings.outJson, JSON.stringify(rows, null, 2));
    wkit.SaveToResources(settings.outCsv, csv.join("\n"));

    logI("[rig-report] Done. OK=" + ok + " FAIL=" + fail);
    logI("[rig-report] JSON: resources/" + settings.outJson);
    logI("[rig-report] CSV : resources/" + settings.outCsv);
})();
