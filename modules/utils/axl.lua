local utils = require("modules/utils/utils")

local axl = {}

---@param value number?
---@return string
function axl.formatNumber(value)
    local fixed = string.format("%.3f", tonumber(value) or 0)
    local rounded = tonumber(fixed) or 0

    if rounded == 0 then
        return "0.0"
    end
    if rounded == math.floor(rounded) then
        return string.format("%.1f", rounded)
    end

    return fixed
end

---@param value any
---@return string
local function normalizeInlineValue(value)
    local normalized = tostring(value or "")
    normalized = normalized:gsub("[\r\n]+", " ")
    return utils.trimString(normalized)
end

---@param position Vector4|table?
---@param orientation Quaternion|table?
---@param scale Vector4|table?
---@param indent string?
---@param include table?
---@return string
function axl.formatTransform(position, orientation, scale, indent, include)
    position = position or {}
    orientation = orientation or {}
    scale = scale or {}
    indent = indent or "          "
    include = include or {}

    local lines = {}

    if include.position ~= false then
        table.insert(lines, string.format("%sposition: [%s, %s, %s, 0.0]", indent,
            axl.formatNumber(position.x),
            axl.formatNumber(position.y),
            axl.formatNumber(position.z)))
    end

    if include.orientation ~= false then
        table.insert(lines, string.format("%sorientation: [%s, %s, %s, %s]", indent,
            axl.formatNumber(orientation.i),
            axl.formatNumber(orientation.j),
            axl.formatNumber(orientation.k),
            axl.formatNumber(orientation.r == nil and 1 or orientation.r)))
    end

    if include.scale ~= false then
        table.insert(lines, string.format("%sscale: [%s, %s, %s]", indent,
            axl.formatNumber(scale.x == nil and 1 or scale.x),
            axl.formatNumber(scale.y == nil and 1 or scale.y),
            axl.formatNumber(scale.z == nil and 1 or scale.z)))
    end

    return table.concat(lines, "\n")
end

---@param mutation table
---@param include table?
---@return string
function axl.formatNodeMutation(mutation, include)
    mutation = mutation or {}

    local sectorPath = normalizeInlineValue(mutation.sectorPath)
    local nodeType = normalizeInlineValue(mutation.nodeType)
    local debugName = normalizeInlineValue(mutation.debugName)
    local resource = normalizeInlineValue(mutation.resource)
    local appearance = normalizeInlineValue(mutation.appearance)
    local lines = {
        "streaming:",
        "  sectors:",
        "    - path: " .. sectorPath,
        string.format("      expectedNodes: %d", math.floor(tonumber(mutation.expectedNodes) or 0)),
        "      nodeMutations:",
        string.format("        - index: %d", math.floor(tonumber(mutation.index) or 0))
    }

    if debugName ~= "" then
        table.insert(lines, "          # [Debug Name: " .. debugName .. "]")
    end

    table.insert(lines, "          type: " .. nodeType)

    if resource ~= "" then
        table.insert(lines, "          # resource: " .. resource)
    end

    if appearance ~= "" then
        table.insert(lines, "          # appearance: " .. appearance)
    end

    table.insert(lines, axl.formatTransform(
        mutation.position,
        mutation.orientation,
        mutation.scale,
        "          ",
        include
    ))

    return table.concat(lines, "\n")
end

return axl
