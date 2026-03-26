local utils = require("modules/utils/utils")
local color = require("modules/utils/color")

---Utilities for project-tag normalization and lightweight UI display data.
---This module is intentionally UI-adjacent: it prepares label/color/icon data that
---different UIs (Saved, Spawned, etc.) can render with their own style rules.
---@class projectTag
local projectTag = {
    DEFAULT_ICON = "Tag",
    DEFAULT_COLOR = { 0.24, 0.24, 0.24 },
    DEFAULT_MIN_CONTRAST_RATIO = 4
}

---Trim leading/trailing whitespace safely.
---@param value string?
---@return string trimmed
function projectTag.trimText(value)
    if type(value) ~= "string" then
        return ""
    end

    return value:match("^%s*(.-)%s*$") or ""
end

---Normalize a tag/project name into a case-insensitive lookup key.
---@param value string?
---@return string key
function projectTag.normalizeNameKey(value)
    return projectTag.trimText(value):lower()
end

---Normalize project color using shared color utility and module defaults.
---@param colorData table?
---@return number[] normalized
function projectTag.normalizeColor(colorData)
    return color.normalizeRGB(colorData, projectTag.DEFAULT_COLOR)
end

---Normalize icon key to an existing IconGlyph, with fallback.
---@param icon string?
---@return string normalized
function projectTag.normalizeIcon(icon)
    if type(icon) == "string" and icon ~= "" and IconGlyphs and IconGlyphs[icon] then
        return icon
    end

    return projectTag.DEFAULT_ICON
end

---Normalize project metadata (`name`, `icon`, `color`) using module defaults.
---Returns `nil` when project is missing or its name is empty.
---@param project table?
---@return table? normalized
function projectTag.normalizeProject(project)
    local source = type(project) == "table" and project or nil

    local name = projectTag.trimText(source and source.name)
    if name == "" then
        return nil
    end

    local icon = projectTag.normalizeIcon(source and source.icon)
    local normalizedColor = projectTag.normalizeColor(source and source.color)

    return {
        name = name,
        icon = icon,
        color = normalizedColor
    }
end

---Build display-ready project-tag data for a root-level saved group.
---Returns `nil` when the element is not a root `positionableGroup` or has no project.
---@param element element
---@return table? tag
function projectTag.getRootGroupTag(element)
    if not utils.isA(element, "positionableGroup") then
        return nil
    end

    if element.parent == nil or not element.parent:isRoot(true) then
        return nil
    end

    local normalizedProject = projectTag.normalizeProject(element.project)
    if not normalizedProject then
        return nil
    end

    local icon = IconGlyphs[normalizedProject.icon] or IconGlyphs[projectTag.DEFAULT_ICON] or ""
    local label = icon ~= "" and (icon .. " " .. normalizedProject.name) or normalizedProject.name
    local textColor = color.readableTextColor(
        normalizedProject.color,
        projectTag.DEFAULT_MIN_CONTRAST_RATIO
    )

    return {
        label = label,
        color = normalizedProject.color,
        textColor = textColor,
        project = normalizedProject
    }
end

---Measure a label using current ImGui font metrics and an optional scale.
---@param label string
---@param fontScale number?
---@return number width
---@return number height
function projectTag.getLabelSize(label, fontScale)
    local scale = tonumber(fontScale) or 1
    local width, height = ImGui.CalcTextSize(label or "")
    return width * scale, height * scale
end

return projectTag
