--[[
    Simple json library for converting between json encoded strings and tables
    MIT Licensed by sprt_ in 2025

    Modified to include encoding for uint32 values which aren't natively support by lua.
]]

local logger = require("modules/utils/logger")

---@class json
---@field stringify fun(value: table, prettyPrint: boolean?, indentLevel: number?):string
---@field parse fun(jsonStr: string):table?
local json = {}
json.__index = json

local function escapeString(str)
    return str:gsub("\\", "\\\\")  -- Escape backslashes
              :gsub('"', '\\"')    -- Escape double quotes
              :gsub("\b", "\\b")   -- Escape backspace
              :gsub("\f", "\\f")   -- Escape form feed
              :gsub("\n", "\\n")   -- Escape newline
              :gsub("\r", "\\r")   -- Escape carriage return
              :gsub("\t", "\\t")   -- Escape tab
end

---@param value table
---@param prettyPrint boolean?
---@param indentLevel number?
---@return string
function json.stringify(value, prettyPrint, indentLevel)
    prettyPrint = prettyPrint or false
    indentLevel = indentLevel or 0
    local indent = string.rep("  ", indentLevel)  -- Two spaces per indent level
    local nextIndent = string.rep("  ", indentLevel + 1)
    local newLine = "\n"
    local space = " "
    if not prettyPrint then
        indent = ""
        nextIndent = ""
        newLine = ""
        space = ""
    end

    if type(value) == "table" then
        local jsonStr = {}
        local isArray = #value > 0

        for key, val in pairs(value) do
            if isArray then
                jsonStr[#jsonStr + 1] = nextIndent .. json.stringify(val, prettyPrint, indentLevel + 1)
            else
                jsonStr[#jsonStr + 1] = string.format('%s"%s":' .. space ..'%s', nextIndent, tostring(key), json.stringify(val, prettyPrint, indentLevel + 1))
            end
        end

        if isArray then
            return "[" .. newLine .. table.concat(jsonStr, "," .. newLine) .. newLine .. indent .. "]"
        else
            return "{" .. newLine .. table.concat(jsonStr, "," .. newLine) .. newLine .. indent .. "}"
        end
    elseif type(value) == "string" then
        if (string.find(value, "uint32:", 1, true) == 1) then
            return string.format('%s', string.sub(value, 8))
        end
        return string.format('"%s"', escapeString(value))
    elseif type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    else
        return "null"
    end
end

---@param jsonStr string
---@return table?
function json.parse(jsonStr)
    -- Remove whitespace
    jsonStr = jsonStr:gsub("^%s*(.-)%s*$", "%1")

    local pos = 1

    if jsonStr:sub(pos, pos) ~= "{" and jsonStr:sub(pos, pos) ~= "[" then
        logger.error("JSON Error: Expected '{' or '[' at position " .. pos)
        return nil
    end

    local function parseValue()
        local char = jsonStr:sub(pos, pos)

        if jsonStr:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        end

        if jsonStr:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        end
        if jsonStr:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        end

        local num = jsonStr:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        if num then
            pos = pos + #num
            return tonumber(num)
        end

        if char == '"' then
            local value = ""
            pos = pos + 1
            while pos <= #jsonStr do
                char = jsonStr:sub(pos, pos)
                if char == '"' then
                    pos = pos + 1
                    return value
                end
                if char == '\\' then
                    pos = pos + 1
                    if pos > #jsonStr then
                        logger.error("JSON Error: Unclosed escape sequence in string at position " .. pos)
                        return nil
                    end
                    char = jsonStr:sub(pos, pos)
                    if char == 'n' then char = '\n'
                    elseif char == 'r' then char = '\r'
                    elseif char == 't' then char = '\t'
                    elseif char == 'b' then char = '\b'
                    elseif char == 'f' then char = '\f'
                    end
                end
                value = value .. char
                pos = pos + 1
            end
            logger.error("JSON Error: Unclosed string, reached end of string")
            return nil
        end
        
        if char == '[' then
            pos = pos + 1
            local arr = {}
            -- Skip initial whitespace
            while pos <= #jsonStr and jsonStr:sub(pos, pos):match('%s') do
                pos = pos + 1
            end
            
            if pos <= #jsonStr and jsonStr:sub(pos, pos) == ']' then
                pos = pos + 1
                return arr
            end
            
            while pos <= #jsonStr do
                char = jsonStr:sub(pos, pos)
                if char == ']' then
                    pos = pos + 1
                    return arr
                end
                
                local value = parseValue()
                if value == nil then
                    logger.error("JSON Error: Failed to parse array value at position " .. pos)
                    return nil
                end
                table.insert(arr, value)
                
                -- Skip whitespace after value
                while pos <= #jsonStr and jsonStr:sub(pos, pos):match('%s') do
                    pos = pos + 1
                end
                
                -- Expect comma or closing bracket
                if pos <= #jsonStr then
                    char = jsonStr:sub(pos, pos)
                    if char == ']' then
                        pos = pos + 1
                        return arr
                    elseif char == ',' then
                        pos = pos + 1
                    else
                        logger.error("JSON Error: Expected ',' or ']' in array at position " .. pos .. ", found '" .. char .. "'")
                        return nil
                    end
                end
                
                -- Skip whitespace after comma
                while pos <= #jsonStr and jsonStr:sub(pos, pos):match('%s') do
                    pos = pos + 1
                end
            end
            logger.error("JSON Error: Unclosed array, reached end of string")
            return nil
        end
        
        if char == '{' then
            pos = pos + 1
            local obj = {}
            -- Skip initial whitespace
            while pos <= #jsonStr and jsonStr:sub(pos, pos):match('%s') do
                pos = pos + 1
            end
            
            while pos <= #jsonStr do
                char = jsonStr:sub(pos, pos)
                if char == '}' then
                    pos = pos + 1
                    return obj
                end
                
                if char == '"' then
                    local key = parseValue()
                    
                    -- Skip whitespace and colon
                    while pos <= #jsonStr and jsonStr:sub(pos, pos):match('%s') do
                        pos = pos + 1
                    end
                    
                    if pos > #jsonStr then
                        logger.error("JSON Error: Expected ':' after key '" .. key .. "' but reached end of string")
                        return nil
                    end
                    
                    if jsonStr:sub(pos, pos) ~= ':' then
                        logger.error("JSON Error: Expected ':' after key '" .. key .. "' at position " .. pos .. ", found '" .. jsonStr:sub(pos, pos) .. "'")
                        return nil
                    end
                    pos = pos + 1
                    
                    -- Skip whitespace after colon
                    while pos <= #jsonStr and jsonStr:sub(pos, pos):match('%s') do
                        pos = pos + 1
                    end
                    
                    obj[key] = parseValue()
                    if obj[key] == nil then
                        logger.error("JSON Error: Failed to parse value for key '" .. key .. "' at position " .. pos)
                        return nil
                    end
                    
                    -- Skip whitespace after value
                    while pos <= #jsonStr and jsonStr:sub(pos, pos):match('%s') do
                        pos = pos + 1
                    end
                    
                    -- Expect comma or closing brace
                    if pos <= #jsonStr then
                        char = jsonStr:sub(pos, pos)
                        if char == '}' then
                            pos = pos + 1
                            return obj
                        elseif char == ',' then
                            pos = pos + 1
                        else
                            logger.error("JSON Error: Expected ',' or '}' in object at position " .. pos .. ", found '" .. char .. "'")
                            return nil
                        end
                    end
                    
                    -- Skip whitespace after comma
                    while pos <= #jsonStr and jsonStr:sub(pos, pos):match('%s') do
                        pos = pos + 1
                    end
                else
                    logger.error("JSON Error: Expected '\"' for object key at position " .. pos .. ", found '" .. char .. "'")
                    return nil
                end
            end
            logger.error("JSON Error: Unclosed object, reached end of string")
            return nil
        end
        logger.error("JSON Error: Unexpected character at position " .. pos .. ": '" .. char .. "'")
        return nil
    end
    
    return parseValue()
end

return json