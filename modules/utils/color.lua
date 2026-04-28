---Shared color utilities for UI and draw-list rendering.
---Conventions:
---1) Normalized color channels are in [0, 1].
---2) Inputs may be arrays (`{1,2,3}`) or keyed tables (`{r,g,b}` / `{x,y,z}`).
---3) `packAABBGGRR` returns packed integers compatible with this project's ImGui draw-list usage.
---@class color
local color = {}

---Normalize arbitrary numeric channels from flexible table shapes.
---Supports indexed arrays (`[1]`, `[2]`, ...), stringified indices (`"1"`), and optional named keys.
---@param source table? Source table to normalize.
---@param options table? Optional configuration:
---`count` (`number`): output channel count.
---`fallback` (`table`): fallback source values.
---`keys` (`table`): per-channel alias lists, e.g. `keys[1] = {"r","x","Red"}`.
---`min` (`number`): optional lower clamp.
---`max` (`number`): optional upper clamp.
---@return number[] normalized
function color.normalizeChannels(source, options)
    options = options or {}

    local fallback = type(options.fallback) == "table" and options.fallback or {}
    local count = tonumber(options.count) or math.max(#fallback, 0)
    local keys = type(options.keys) == "table" and options.keys or {}
    local hasMin = options.min ~= nil
    local hasMax = options.max ~= nil
    local minValue = tonumber(options.min) or 0
    local maxValue = tonumber(options.max) or 0
    local src = type(source) == "table" and source or nil
    local normalized = {}

    local function readChannel(candidate, index, aliases)
        if type(candidate) ~= "table" then
            return nil
        end

        local value = tonumber(candidate[index] or candidate[tostring(index)])
        if value ~= nil then
            return value
        end

        if type(aliases) ~= "table" then
            return nil
        end

        for _, key in ipairs(aliases) do
            value = tonumber(candidate[key])
            if value ~= nil then
                return value
            end
        end

        return nil
    end

    for index = 1, count do
        local aliases = keys[index]
        local channel = readChannel(src, index, aliases)
        if channel == nil then
            channel = readChannel(fallback, index, aliases) or 0
        end

        if hasMin then
            channel = math.max(channel, minValue)
        end
        if hasMax then
            channel = math.min(channel, maxValue)
        end

        normalized[index] = channel
    end

    return normalized
end

---Clamp a numeric value to the inclusive [0, 1] range.
---@param value number?
---@return number clamped
function color.clamp01(value)
    value = tonumber(value) or 0
    return math.max(0, math.min(value, 1))
end

---Read one channel from a flexible color table shape.
---Supports index key, string index key, and named keys.
---@param candidate table?
---@param index number
---@param keyA string
---@param keyB string
---@return number? channel
local function readColorChannel(candidate, index, keyA, keyB)
    return tonumber(candidate and (candidate[index] or candidate[tostring(index)] or candidate[keyA] or candidate[keyB]))
end

---Normalize an RGB color into `{r,g,b}` with each channel in [0, 1].
---If any source channel is >1, channels are interpreted as byte-based [0, 255] values.
---@param source table? Raw input color.
---@param fallback number[]? Fallback color used when input is missing/invalid.
---@return number[] normalized
function color.normalizeRGB(source, fallback)
    local fallbackColor = fallback or { 0, 0, 0 }

    local fallbackR = readColorChannel(fallbackColor, 1, "r", "x") or 0
    local fallbackG = readColorChannel(fallbackColor, 2, "g", "y") or 0
    local fallbackB = readColorChannel(fallbackColor, 3, "b", "z") or 0

    if type(source) ~= "table" then
        return {
            color.clamp01(fallbackR),
            color.clamp01(fallbackG),
            color.clamp01(fallbackB)
        }
    end

    local r = readColorChannel(source, 1, "r", "x")
    local g = readColorChannel(source, 2, "g", "y")
    local b = readColorChannel(source, 3, "b", "z")

    if r == nil or g == nil or b == nil then
        return {
            color.clamp01(fallbackR),
            color.clamp01(fallbackG),
            color.clamp01(fallbackB)
        }
    end

    if r > 1 or g > 1 or b > 1 then
        r = r / 255
        g = g / 255
        b = b / 255
    end

    return {
        color.clamp01(r),
        color.clamp01(g),
        color.clamp01(b)
    }
end

---Linearize a normalized sRGB channel for luminance calculations.
---@param value number
---@return number linearized
function color.linearizeChannel(value)
    value = color.clamp01(value)
    if value <= 0.04045 then
        return value / 12.92
    end

    return ((value + 0.055) / 1.055) ^ 2.4
end

---Compute WCAG relative luminance from an RGB color.
---@param rgb number[]
---@return number luminance
function color.relativeLuminance(rgb)
    local normalized = color.normalizeRGB(rgb, { 0, 0, 0 })
    local r = color.linearizeChannel(normalized[1])
    local g = color.linearizeChannel(normalized[2])
    local b = color.linearizeChannel(normalized[3])

    return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

---Compute contrast ratio between a background color and white/black text.
---@param bgRgb number[]
---@param useWhiteText boolean
---@return number ratio
function color.contrastRatio(bgRgb, useWhiteText)
    local lumBg = color.relativeLuminance(bgRgb)
    local lumText = useWhiteText and 1 or 0
    local lighter = math.max(lumBg, lumText)
    local darker = math.min(lumBg, lumText)

    return (lighter + 0.05) / (darker + 0.05)
end

---Choose a readable text color (white or black) for a background color.
---Returns RGBA with alpha always set to 1.
---@param bgRgb number[]
---@param minContrast number?
---@return number[] rgba
function color.readableTextColor(bgRgb, minContrast)
    local threshold = tonumber(minContrast) or 4.5
    local whiteContrast = color.contrastRatio(bgRgb, true)
    if whiteContrast >= threshold then
        return { 1, 1, 1, 1 }
    end

    return { 0, 0, 0, 1 }
end

---Adjust brightness by adding `amount` to each RGB channel, then clamp to [0, 1].
---Positive values lighten, negative values darken.
---@param baseRgb number[]
---@param amount number
---@return number[] adjusted
function color.adjustBrightness(baseRgb, amount)
    local normalized = color.normalizeRGB(baseRgb, { 0, 0, 0 })
    local delta = tonumber(amount) or 0
    return {
        color.clamp01(normalized[1] + delta),
        color.clamp01(normalized[2] + delta),
        color.clamp01(normalized[3] + delta)
    }
end

---Pack an RGB(A) color into `AABBGGRR` integer format.
---If `alpha` is omitted, reads `rgb[4]`/`rgb.a`/`rgb.w`, defaulting to 1.
---@param rgb number[]
---@param alpha number?
---@return integer packed
function color.packAABBGGRR(rgb, alpha)
    local normalized = color.normalizeRGB(rgb, { 0, 0, 0 })
    local aSource = alpha
    if aSource == nil then
        aSource = tonumber(rgb and (rgb[4] or rgb.a or rgb.w)) or 1
    end

    local a = math.floor(color.clamp01(aSource) * 255 + 0.5)
    local r = math.floor(color.clamp01(normalized[1]) * 255 + 0.5)
    local g = math.floor(color.clamp01(normalized[2]) * 255 + 0.5)
    local b = math.floor(color.clamp01(normalized[3]) * 255 + 0.5)

    return a * 0x1000000 + b * 0x10000 + g * 0x100 + r
end

---Format an RGB color as a hexadecimal string (`#RRGGBB`).
---@param source table?
---@param fallback number[]?
---@return string hex
function color.formatHexRGB(source, fallback)
    local normalized = color.normalizeRGB(source, fallback or { 1, 1, 1 })
    local red = math.floor(color.clamp01(normalized[1]) * 255 + 0.5)
    local green = math.floor(color.clamp01(normalized[2]) * 255 + 0.5)
    local blue = math.floor(color.clamp01(normalized[3]) * 255 + 0.5)

    return string.format("#%02X%02X%02X", red, green, blue)
end

---Build a detailed color tooltip string with hex, byte channels, and normalized channels.
---@param source table?
---@param fallback number[]?
---@return string tooltip
function color.formatPreviewTooltip(source, fallback)
    local normalized = color.normalizeRGB(source, fallback or { 1, 1, 1 })
    local red = math.floor(color.clamp01(normalized[1]) * 255 + 0.5)
    local green = math.floor(color.clamp01(normalized[2]) * 255 + 0.5)
    local blue = math.floor(color.clamp01(normalized[3]) * 255 + 0.5)

    return string.format(
        "#%02X%02X%02X\nR: %d, G: %d, B: %d\n(%.3f, %.3f, %.3f)",
        red,
        green,
        blue,
        red,
        green,
        blue,
        normalized[1],
        normalized[2],
        normalized[3]
    )
end

---Parse `#RRGGBB` or `RRGGBB` into normalized RGB channels.
---@param hexText string?
---@return number[]? rgb
function color.parseHexRGB(hexText)
    if type(hexText) ~= "string" then
        return nil
    end

    local normalized = hexText:gsub("%s+", "")
    if normalized:sub(1, 1) == "#" then
        normalized = normalized:sub(2)
    end

    normalized = normalized:upper()
    if #normalized ~= 6 or normalized:find("[^0-9A-F]") then
        return nil
    end

    local red = tonumber(normalized:sub(1, 2), 16)
    local green = tonumber(normalized:sub(3, 4), 16)
    local blue = tonumber(normalized:sub(5, 6), 16)
    if not red or not green or not blue then
        return nil
    end

    return color.normalizeRGB({ red, green, blue }, nil)
end

return color
