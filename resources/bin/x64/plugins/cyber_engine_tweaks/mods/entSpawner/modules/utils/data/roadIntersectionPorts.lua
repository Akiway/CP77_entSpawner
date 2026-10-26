local config = require("modules/utils/core/config")
local utils = require("modules/utils/core/utils")

---Road ports of vanilla intersection meshes: where a bended road meets the intersection, in mesh space.
---Data comes from data/static/road_intersection_ports.json (extracted from the 2.5 sectors).
local roadIntersectionPorts = {}

local storePath = "data/static/road_intersection_ports.json"
local store = {}
local storeLoaded = false

local function normalizePath(path)
    return utils.normalizePath(path, {
        separator = "backslash",
        lowercase = true,
        emptyAsNil = true
    })
end

local function isVector3(value)
    return type(value) == "table" and type(value[1]) == "number" and type(value[2]) == "number" and type(value[3]) == "number"
end

local function loadStore()
    if storeLoaded then return end
    storeLoaded = true

    local data = config.loadFile(storePath)
    if type(data) ~= "table" or type(data.intersections) ~= "table" then return end

    for path, ports in pairs(data.intersections) do
        local key = normalizePath(path)
        if key and type(ports) == "table" then
            local valid = {}
            for _, port in ipairs(ports) do
                if isVector3(port.position) and isVector3(port.forward) and isVector3(port.up) then
                    table.insert(valid, {
                        position = port.position,
                        forward = port.forward,
                        up = port.up,
                        width = tonumber(port.width) or 0,
                        road = type(port.road) == "string" and port.road or nil
                    })
                end
            end
            if #valid > 0 then
                store[key] = valid
            end
        end
    end
end

---Profile of the vanilla road a port was measured on, e.g. `rt_2x2_with_sidewalks_24m_jt_2`.
---@param road string?
---@return string?
function roadIntersectionPorts.getRoadProfile(road)
    if not road then return nil end
    local file = road:match("([^\\]+)%.mesh$")
    return file and (file:match("^br_[^_]+_(.+)$") or file) or nil
end

---Ports of an intersection mesh, in mesh space.
---@param meshPath string
---@return table[]? ports `{ position, forward, up, width, road }`; `forward` points away from the intersection.
function roadIntersectionPorts.getPorts(meshPath)
    loadStore()
    local key = normalizePath(meshPath)
    return key and store[key] or nil
end

return roadIntersectionPorts
