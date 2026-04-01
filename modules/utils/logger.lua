--[[
    Simple logger library for logging messages to both spdlog (mod log) and CET console
    MIT Licensed by sprt_ in 2025
    v1.0.0
]]

local prefix = ""
local info = "[INFO ] "
local warn = "[WARN ] "
local error = "[ERROR] "

---@class logger
---@field info fun(message: any, modLogOnly: boolean?)
---@field warn fun(message: any, modLogOnly: boolean?)
---@field error fun(message: any, modLogOnly: boolean?)
local logger = {}
logger.__index = logger

local function getJsonModule()
    return require("libs/json")
end

local function getString(message)
    if message == nil then
        return "nil"
    end
    if type(message) == "string" then
        return message
    elseif type(message) == "table" then
        return getJsonModule().stringify(message, true)
    elseif type(message) == "userdata" then
        return tostring(message):match("%b{}"):sub(2, -2):match("^%s*(.-)%s*$")
    else
        return tostring(message)
    end
end

---@param message any
---@param modLogOnly boolean?
function logger.info(message, modLogOnly)
    message = prefix .. info .. getString(message)
    if not modLogOnly then
        print(message)
    end
    spdlog.info(message)
end

---@param message any
---@param modLogOnly boolean?
function logger.warn(message, modLogOnly)
    message = prefix .. warn .. getString(message)
    if not modLogOnly then
        print(message)
    end
    spdlog.info(message)
end

---@param message any
---@param modLogOnly boolean?
function logger.error(message, modLogOnly)
    message = prefix .. error .. getString(message)
    if not modLogOnly then
        print(message)
    end
    spdlog.info(message)
end

return logger
