local settings = require("modules/utils/core/settings")
local utils = require("modules/utils/core/utils")
local cache = require("modules/utils/game/cache")

---Resource type compatibility checks for spawnable assets.
---
---Every spawnable class hands its `spawnData` path to the game as a resource of one specific type:
---an entity template for `StaticEntitySpec.templatePath`, a mesh for `entMeshComponent.mesh`, a
---material for a decal, and so on. Handing over a path of a different type does not fail, it takes
---the game down with it, and nothing in the API validates the type for us before that happens.
---
---So the type is inferred from the depot path extension, which is reliable because the extension
---*is* the resource class in this engine, and checked before anything is spawned. The check is
---also the only place that knows which classes accept which extension, so it can name the class
---that should have been used instead.
local assetValidation = {}

---A resource type one or more spawnable classes accept.
---@class assetKind
---@field label string Human readable name of the resource type.
---@field extensions string[] Accepted depot extensions, lowercase, without the dot.

---@type table<string, assetKind>
local kinds = {
    entity = { label = "entity template", extensions = { "ent" } },
    mesh = { label = "mesh", extensions = { "mesh", "w2mesh" } },
    material = { label = "material", extensions = { "mi", "mt" } },
    particle = { label = "particle system", extensions = { "particle" } },
    effect = { label = "effect", extensions = { "effect" } },
    envProbe = { label = "environment probe", extensions = { "envprobe" } },
    workspot = { label = "workspot", extensions = { "workspot" } }
}

---What one spawnable class accepts as its asset.
---@class assetRule
---@field kind assetKind
---@field allowList string? Path list the asset must appear in, for classes whose node needs the
---asset to be authored for it (cloth, destruction, ...). Only ever a warning: the lists cover the
---shipped assets, so a modded one that belongs there is not in them.

---@type table<string, assetRule>
local rulesByModule = {}

---@param kind assetKind
---@param modulePaths string[]
---@param allowList string?
local function declare(kind, modulePaths, allowList)
    for _, modulePath in ipairs(modulePaths) do
        rulesByModule[modulePath] = { kind = kind, allowList = allowList }
    end
end

-- `entity/entity` and `physics/destructionMesh` are the base classes of the ones below them and are
-- not offered in Spawn New, but a payload can still name one, so they are covered too.
declare(kinds.entity, { "entity/entity", "entity/entityTemplate", "entity/ammEntity", "entity/device" })
declare(kinds.mesh, { "mesh/mesh", "mesh/rotatingMesh", "mesh/proxyMesh", "physics/destructionMesh" })
declare(kinds.mesh, { "mesh/clothMesh" }, "data/spawnables/mesh/cloth/paths.txt")
declare(kinds.mesh, { "mesh/bendedMesh" }, "data/spawnables/mesh/bended/paths_bended.txt")
declare(kinds.mesh, { "physics/dynamicMesh" }, "data/spawnables/mesh/physics/paths_filtered_mesh.txt")
declare(kinds.mesh, { "physics/destructibleMesh" }, "data/spawnables/mesh/destructible/paths_destructible.txt")
declare(kinds.mesh, { "physics/physicalDestruction" }, "data/spawnables/mesh/physicalDestruction/paths_physical_destruction.txt")
declare(kinds.mesh, { "physics/bakedDestruction" }, "data/spawnables/mesh/bakedDestruction/paths_baked_destruction.txt")
declare(kinds.material, { "visual/decal" })
declare(kinds.particle, { "visual/particle" })
declare(kinds.effect, { "visual/effect" })
declare(kinds.envProbe, { "meta/reflectionProbe" })
declare(kinds.workspot, { "ai/aiSpot" })

-- Reverse index, so a rejected asset can name the classes that would take it.
---@type table<string, string[]>
local modulesByExtension = {}
for modulePath, rule in pairs(rulesByModule) do
    for _, extension in ipairs(rule.kind.extensions) do
        modulesByExtension[extension] = modulesByExtension[extension] or {}
        table.insert(modulesByExtension[extension], modulePath)
    end
end
for _, modulePaths in pairs(modulesByExtension) do
    table.sort(modulePaths)
end

---Outcome of checking one asset path against one spawnable class.
---@class assetCheckResult
---@field ok boolean True when nothing is wrong with the asset.
---@field severity string `none`, `warning` (spawnable, but suspicious) or `error` (would crash).
---@field code string? `extension`, `missing` or `unlisted`.
---@field found string Extension of the checked path, without the dot. Empty when there is none.
---@field expected string[] Extensions the class accepts.
---@field kindLabel string Human readable name of the resource type the class expects.
---@field acceptedBy string[] Module paths of the classes that accept `found`.
---@field path string The checked path.

---@type assetCheckResult
local OK = {
    ok = true,
    severity = "none",
    found = "",
    expected = {},
    kindLabel = "",
    acceptedBy = {},
    path = ""
}

-- Results are memoized per class and path. Editing the search field in Spawn New checks a new path
-- on every keystroke, so the table is dropped wholesale once it grows past what a session needs.
local RESULT_CACHE_LIMIT = 4096
local resultCache = {}
local resultCacheSize = 0

---Depot extension of a path, lowercase and without the dot.
---@param path string
---@return string
function assetValidation.getExtension(path)
    if type(path) ~= "string" then return "" end

    local fileName = path:match("[^\\/]+$") or path
    local extension = fileName:match("%.([%w_]+)$")

    return extension and extension:lower() or ""
end

---@param path string
---@return boolean? exists nil when the depot could not be asked, which is not an answer.
local function resourceExists(path)
    local ok, exists = pcall(function ()
        return Game.GetResourceDepot():ResourceExists(ResRef.FromString(path))
    end)

    if not ok then return nil end

    return exists == true
end

---Formats a list of extensions as `.a`, `.b` or `.c`.
---@param extensions string[]
---@return string
local function formatExtensions(extensions)
    local formatted = {}
    for index, extension in ipairs(extensions) do
        formatted[index] = "." .. extension
    end

    if #formatted <= 1 then
        return formatted[1] or "?"
    end

    return table.concat(formatted, ", ", 1, #formatted - 1) .. " or " .. formatted[#formatted]
end

---Checks whether one asset path is of the resource type a spawnable class can spawn.
---
---Classes whose `spawnData` is not a depot path (records, sound events, collision shapes, ...) have
---no rule and always pass, as does an empty path: refusing to spawn that one is `spawnable:spawn`'s
---job, and it says so in its own terms.
---@param modulePath string? Module path of the spawnable class, as in `spawnable.modulePath`.
---@param path string? Asset path to check.
---@return assetCheckResult
function assetValidation.check(modulePath, path)
    local rule = rulesByModule[modulePath or ""]
    if not rule then return OK end

    path = utils.trimString(path)
    if path == "" then return OK end

    local cacheKey = modulePath .. "|" .. path
    local cached = resultCache[cacheKey]
    if cached then return cached end

    local found = assetValidation.getExtension(path)
    local result = {
        ok = true,
        severity = "none",
        found = found,
        expected = rule.kind.extensions,
        kindLabel = rule.kind.label,
        acceptedBy = modulesByExtension[found] or {},
        path = path
    }

    local accepted = false
    for _, extension in ipairs(rule.kind.extensions) do
        if found == extension then
            accepted = true
            break
        end
    end

    local exists
    if accepted then
        exists = resourceExists(path)
    end

    if not accepted then
        result.ok = false
        result.severity = "error"
        result.code = "extension"
    elseif exists == false then
        -- Not fatal: the depot only knows the archives currently loaded, and a path it does not
        -- know simply spawns nothing.
        result.ok = false
        result.severity = "warning"
        result.code = "missing"
    elseif rule.allowList and not cache.isSpawnDataInSet(path, rule.allowList) then
        result.ok = false
        result.severity = "warning"
        result.code = "unlisted"
    end

    -- An unreachable depot is not a verdict, so that run is not remembered as one. The extension
    -- alone decides the fatal case, so that one is always conclusive.
    if accepted and exists == nil then
        return result
    end

    if resultCacheSize >= RESULT_CACHE_LIMIT then
        resultCache = {}
        resultCacheSize = 0
    end

    resultCache[cacheKey] = result
    resultCacheSize = resultCacheSize + 1

    return result
end

---Whether a spawnable class carries a depot resource path in its `spawnData`.
---
---True for exactly the classes that have a rule, which is the same thing: a class without one
---either puts something else there (a TweakDB record, a sound event, a collision shape hash) or
---never leaves the placeholder entity every non asset backed node spawns through. Those have no
---asset path to point somewhere else, however much their World Node section shows one.
---@param modulePath string?
---@return boolean
function assetValidation.hasAssetPath(modulePath)
    return rulesByModule[modulePath or ""] ~= nil
end

---Whether an asset appears in the curated list of the class that would spawn it.
---True for every class without a list, since then nothing constrains the asset.
---@param modulePath string?
---@param path string?
---@return boolean
function assetValidation.isAssetListed(modulePath, path)
    local rule = rulesByModule[modulePath or ""]
    if not rule or not rule.allowList then return true end

    return cache.isSpawnDataInSet(path or "", rule.allowList)
end

---One line describing what is wrong, suitable for a toast.
---@param result assetCheckResult
---@param label string Display name of the class the asset was checked against ("Static Mesh").
---@return string
function assetValidation.getSummary(result, label)
    if result.ok then return "" end

    if result.code == "extension" then
        local found = result.found ~= "" and ("." .. result.found) or "extensionless"
        return string.format("\"%s\" needs a %s file, not a %s one", label, formatExtensions(result.expected), found)
    end

    if result.code == "missing" then
        return string.format("Asset not found in any loaded archive: \"%s\"", result.path)
    end

    return string.format("This asset is not one of the meshes authored for \"%s\"", label)
end

---Multi line explanation, suitable for a tooltip.
---@param result assetCheckResult
---@param label string Display name of the class the asset was checked against ("Static Mesh").
---@return string
function assetValidation.getDetail(result, label)
    if result.ok then return "" end

    if result.code == "extension" then
        local found = result.found ~= "" and ("." .. result.found) or "no"
        return table.concat({
            string.format("\"%s\" spawns the asset as a %s, which has to be a %s file.", label, result.kindLabel, formatExtensions(result.expected)),
            string.format("This path has %s extension, so it is a different kind of resource.", found),
            "",
            "Handing it over anyway crashes the game, so the spawn is refused."
        }, "\n")
    end

    if result.code == "missing" then
        return table.concat({
            string.format("No loaded archive contains \"%s\".", result.path),
            "",
            "The asset will spawn as nothing. Check the path for typos, or install the mod it comes from."
        }, "\n")
    end

    return table.concat({
        string.format("\"%s\" needs a mesh authored for its node type, and this one is not in the list of assets known to be.", label),
        "",
        "It may still work, but it can also spawn wrong or not at all."
    }, "\n")
end

---The reason this asset must not be spawned by this class, or nil when it may be.
---Only ever the type mismatch: the warnings describe assets that spawn badly, not fatally.
---@param modulePath string?
---@param path string?
---@param label string Display name of the class, for the message.
---@return string? reason
function assetValidation.getSpawnBlock(modulePath, path, label)
    if settings.validateAssetTypes == false then return nil end

    local result = assetValidation.check(modulePath, path)
    if result.severity ~= "error" then return nil end

    return assetValidation.getSummary(result, label)
end

return assetValidation
