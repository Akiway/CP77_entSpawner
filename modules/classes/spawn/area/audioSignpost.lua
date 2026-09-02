local triggerArea = require("modules/classes/spawn/area/triggerArea")
local area = require("modules/classes/spawn/area/area")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local cache = require("modules/utils/game/cache")
local history = require("modules/utils/project/history")

---Class for worldAudioSignpostTriggerNode
---
---A signpost tells the music system what kind of place the player just walked into - a gang's turf, a
---megabuilding lobby, the badlands - so it can pick matching exploration music. Every shipped node
---uses a matched `<theme>_START` / `<theme>_STOP` pair with a five second exit cooldown, and leaves
---the re-enter and pre-exit signposts unset, so the theme picker below writes both halves at once.
---
---Unlike Ambient Area, the settings live on the node itself; the notifier only carries the trigger
---channels, and every shipped node listens on `TC_Player`.
---@class audioSignpost : triggerArea
---@field private enterSignpost string
---@field private exitSignpost string
---@field private reEnterSignpost string
---@field private preExitSignpost string
---@field private exitCooldown number
local audioSignpost = setmetatable({}, { __index = triggerArea })

---Theme names that ship with both halves of the pair, derived from the harvested signpost lists.
local themeCache = nil

---@return string[] themes
local function getThemes()
    if themeCache then return themeCache end

    themeCache = {}

    local signposts = cache.staticData.signposts
    if type(signposts) ~= "table" then return themeCache end

    local stops = {}
    for _, name in ipairs(signposts.exit or {}) do
        local theme = tostring(name):match("^(.+)_STOP$")
        if theme then stops[theme] = true end
    end

    for _, name in ipairs(signposts.enter or {}) do
        local theme = tostring(name):match("^(.+)_START$")
        if theme and stops[theme] then
            table.insert(themeCache, theme)
        end
    end

    table.sort(themeCache)

    return themeCache
end

---@param value string
---@return table cname
local function cname(value)
    return {
        ["$type"] = "CName",
        ["$storage"] = "string",
        ["$value"] = (value and value ~= "") and value or "None"
    }
end

function audioSignpost:new()
	local o = triggerArea.new(self)

    o.spawnListType = "files"
    o.dataType = "Audio Signpost Area"
    o.spawnDataPath = "data/spawnables/area/audioSignpost/"
    o.modulePath = "area/audioSignpost"
    o.node = "worldAudioSignpostTriggerNode"
    o.description = "Tells the music system what kind of place this is, so exploration music matches it."
    o.previewNote = "Not previewed in editor."
    o.icon = IconGlyphs.Cast

    o.triggerType = "Audio Signpost"
    -- TC_Player, the only channel any shipped signpost listens on.
    o.channels = { false, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false }

    o.enterSignpost = "ow_generic_START"
    o.exitSignpost = "ow_generic_STOP"
    o.reEnterSignpost = ""
    o.preExitSignpost = ""
    o.exitCooldown = 5

    o.themeSearch = ""
    o.signpostSearch = {}
    o.maxSignpostPropertyWidth = nil

    setmetatable(o, { __index = self })
   	return o
end

function audioSignpost:save()
    local data = triggerArea.save(self)

    data.enterSignpost = self.enterSignpost
    data.exitSignpost = self.exitSignpost
    data.reEnterSignpost = self.reEnterSignpost
    data.preExitSignpost = self.preExitSignpost
    data.exitCooldown = self.exitCooldown

    return data
end

---Theme the current enter/exit pair corresponds to, or `""` when they do not form a pair.
---@return string theme
function audioSignpost:getTheme()
    local theme = tostring(self.enterSignpost or ""):match("^(.+)_START$")

    if theme and self.exitSignpost == theme .. "_STOP" then
        return theme
    end

    return ""
end

function audioSignpost:drawAudioSignpost(changed)
    if changed then
        self.trigger = { ["$type"] = "worldAudioSignpostTriggerNotifier" }

        return
    end

    if not self.maxSignpostPropertyWidth then
        self.maxSignpostPropertyWidth = utils.getTextMaxWidth({ "Theme", "Enter", "Exit", "Re-enter", "Pre-exit", "Exit Cooldown" }) + 8 * ImGui.GetStyle().ItemSpacing.x
    end
    local max = self.maxSignpostPropertyWidth

    style.mutedText("Theme")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    local theme, newSearch, _ = style.trackedSearchDropdown("##theme", "Search theme...", self:getTheme(), self.themeSearch or "", getThemes(), {
        element = self.object,
        width = style.getMaxWidth(250),
        matchContentWidth = true,
        tooltip = "Picks both halves of the pair at once. Every shipped signpost uses a matched pair."
    })
    self.themeSearch = newSearch
    if theme ~= "" and theme ~= self:getTheme() then
        history.addAction(history.getElementChange(self.object))
        self.enterSignpost = theme .. "_START"
        self.exitSignpost = theme .. "_STOP"
    end

    self.signpostSearch = self.signpostSearch or {}

    ---@param label string
    ---@param field string
    ---@param options string[]
    ---@param tooltip string
    local function drawSignpost(label, field, options, tooltip)
        style.mutedText(label)
        ImGui.SameLine()
        ImGui.SetCursorPosX(max)
        local value, search, _ = style.trackedSearchDropdown("##" .. field, "Search...", self[field], self.signpostSearch[field] or "", options, {
            element = self.object,
            width = style.getMaxWidth(250),
            matchContentWidth = true,
            allowCustom = true,
            clearable = true,
            tooltip = tooltip
        })
        self[field] = value
        self.signpostSearch[field] = search
    end

    local signposts = cache.staticData.signposts or {}

    drawSignpost("Enter", "enterSignpost", signposts.enter or {}, "Fired when the player enters the area.")
    drawSignpost("Exit", "exitSignpost", signposts.exit or {}, "Fired when the player leaves, after the cooldown below.")
    drawSignpost("Re-enter", "reEnterSignpost", signposts.enter or {}, "Fired instead of Enter when the player comes back within the cooldown.\nNo shipped signpost sets this.")
    drawSignpost("Pre-exit", "preExitSignpost", signposts.exit or {}, "Fired the moment the player leaves, before the cooldown.\nNo shipped signpost sets this.")

    style.mutedText("Exit Cooldown")
    ImGui.SameLine()
    ImGui.SetCursorPosX(max)
    self.exitCooldown, _ = style.trackedDragFloat(self.object, "##exitCooldown", self.exitCooldown, 0.1, 0, 999, "%.1fs", 80)
    style.tooltip("Seconds after leaving before the exit signpost fires.\nEvery shipped signpost uses 5.")
end

function audioSignpost:getAvailableTriggers()
    return {
        ["Audio Signpost"] = audioSignpost.drawAudioSignpost
    }
end

function audioSignpost:draw()
    -- Only one trigger type applies, so the type combo `triggerArea:draw` would add is skipped -
    -- the same shape `ambientArea` uses.
    area.draw(self)

    if ImGui.TreeNodeEx(self.triggerType, ImGuiTreeNodeFlags.SpanFullWidth) then
        self:drawChannelSelect()
        self:drawAudioSignpost(false)
        ImGui.TreePop()
    end
end

function audioSignpost:export(key, length, markersZOffset)
    local data = triggerArea.export(self, key, length, markersZOffset)
    data.type = "worldAudioSignpostTriggerNode"

    data.data.enterSignpost = cname(self.enterSignpost)
    data.data.exitSignpost = cname(self.exitSignpost)
    data.data.reEnterSignpost = cname(self.reEnterSignpost)
    data.data.preExitSignpost = cname(self.preExitSignpost)
    data.data.exitCooldown = self.exitCooldown

    return data
end

return audioSignpost
