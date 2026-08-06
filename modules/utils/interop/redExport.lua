---Builders for the RED-JSON payloads spawnables write in `export()`.
---
---The shapes are what WolvenKit's importer expects when it reads a node back into a
---streamingsector, and they are easy to get subtly wrong: a missing `$storage`, a resource
---reference written as a bare string, a handle without its `Data` wrapper. Building them in
---one place keeps every spawnable emitting the same thing.
---
---Only the payloads shared by more than one class live here. One-off blocks stay inline in
---the class that owns them, where the surrounding comment can explain them.
local redExport = {}

---RED-JSON payload for a `CName`.
---@param value string? Empty and `nil` both become "None", which is how the game stores an unset CName.
---@return table
function redExport.cName(value)
    local text = value or ""
    if text == "" then
        text = "None"
    end

    return {
        ["$type"] = "CName",
        ["$storage"] = "string",
        ["$value"] = text
    }
end

---RED-JSON payload for a `raRef` resource reference.
---Soft references are what world nodes use for optional resources: the sector loads without
---them, and the game resolves them when the node is streamed in.
---@param path string Depot path of the resource.
---@return table
function redExport.resourceRef(path)
    return {
        ["Flags"] = "Soft",
        ["DepotPath"] = {
            ["$type"] = "ResourcePath",
            ["$storage"] = "string",
            ["$value"] = path
        }
    }
end

---RED-JSON payload for a handle to a `physicsFilterData`.
---The masks are passed in rather than looked up, so this stays independent of where a
---caller gets its preset table from.
---@param preset string Collision filter preset name, e.g. "Destructible".
---@param masks table {queryMask1, queryMask2, simulationMask1, simulationMask2}, as strings.
---@return table
function redExport.filterData(preset, masks)
    return {
        ["Data"] = {
            ["$type"] = "physicsFilterData",
            ["preset"] = redExport.cName(preset),
            ["queryFilter"] = {
                ["$type"] = "physicsQueryFilter",
                ["mask1"] = masks.queryMask1,
                ["mask2"] = masks.queryMask2
            },
            ["simulationFilter"] = {
                ["$type"] = "physicsSimulationFilter",
                ["mask1"] = masks.simulationMask1,
                ["mask2"] = masks.simulationMask2
            }
        }
    }
end

---RED-JSON payload for a `NavGenNavigationSetting`.
---@param navmeshImpact string? Member name of `NavGenNavmeshImpact`; defaults to "Blocking".
---@return table
function redExport.navigationSetting(navmeshImpact)
    return {
        ["$type"] = "NavGenNavigationSetting",
        ["navmeshImpact"] = navmeshImpact or "Blocking"
    }
end

return redExport
