---@class logger
---@method info(... any)
---@method error(... any)
---@method warn(... any)

local logger = {}
logger.__index = logger
local CONSOLE_PREFIX = "[World Builder] "
local INFO_PREFIX = "[Info] "
local WARN_PREFIX = "[Warn] "
local ERROR_PREFIX = "[Error] "

---@param ... any
---@return string
local function formatMessage(...)
    local count = select("#", ...)
    if count == 0 then
        return ""
    end

    if count == 1 then
        return tostring((...))
    end

    local parts = {}
    for i = 1, count do
        parts[i] = tostring(select(i, ...))
    end

    return table.concat(parts, " ")
end

---@param ... any
function logger:info(...)
    local message = formatMessage(...)
    print(CONSOLE_PREFIX .. INFO_PREFIX .. message)
    spdlog.info(INFO_PREFIX .. message)
end

---@param ... any
function logger:error(...)
    local message = formatMessage(...)
    print(CONSOLE_PREFIX .. ERROR_PREFIX .. message)
    spdlog.error(ERROR_PREFIX .. message)
end

---@param ... any
function logger:warn(...)
    local message = formatMessage(...)
    print(CONSOLE_PREFIX .. WARN_PREFIX .. message)
    if spdlog.warning then
        spdlog.warning(WARN_PREFIX .. message)
    else
        spdlog.error(WARN_PREFIX .. message)
    end
end

return logger
