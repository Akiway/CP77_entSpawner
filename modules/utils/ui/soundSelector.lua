local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local audioData = require("modules/utils/data/audioData")
local soundSystemData = require("modules/utils/data/soundSystem")

---Searchable sound-event selector with metadata filters.
---
---Every audio field in the engine is a plain `CName`, so a selector over 23,424 event names is the
---only thing standing between an author and a silently dropped typo. Names alone are a poor index:
---the same kind of sound is split across `amb_bl_`, `amb_g_` and `amb_int_` prefixes, and nothing in
---a name says whether the event loops, how long it runs or how far it carries. The shipped metadata
---does say all of that, so this component filters on it instead.
---
---Two kinds of criteria, which is the whole point of the component:
--- * **Mandatory** - fixed by the field being edited, passed as `require`. A `worldStaticSoundEmitterNode`
---   fires its event once when it streams in, so only a looping, positional event keeps playing there;
---   a transform-animation sound track starts an event and never stops it, so only a one-shot behaves.
---   Those criteria are shown, locked, and explained rather than silently applied - the author can see
---   why the list is short, and `allowCustom` still lets a name be typed past them.
--- * **Optional** - anything the author wants to narrow by: category, range, length, playback.
---
---Adding a criterion means adding one entry to `criteria` below; the header, the summary line, the
---reset button and the filter-signature cache key all derive from that table.
---@class soundSelector
local soundSelector = {}

---Widest value either range criterion accepts. Attenuation runs to 20,000 m and durations to just
---over an hour in the shipped tables, so the drags are not capped below what the data holds.
local MAX_RANGE = 20000
local MAX_DURATION = 4000

---Popup width the filter header needs. Wider than most of the combos this hangs off, which is what
---`popupMinWidth` is for.
local POPUP_WIDTH = 460

---Height of the inline category list, in unscaled style units.
local TAG_LIST_HEIGHT = 110

--- Criteria -------------------------------------------------------------------------------------

---One filterable piece of event metadata.
---@class SoundCriterion
---@field id string Key in the state table, and the key `require` / `hide` address it by.
---@field label string Row label in the filter header.
---@field kind "choice"|"range"|"tags"
---@field tooltip string? Row tooltip.
---@field options { key: string, label: string, tooltip: string? }[]? `choice` only, first entry is the neutral one.
---@field unit string? `range` only, drawn after the two drags.
---@field max number? `range` only.
---@field format string? `range` only.
---@field test fun(event: table?, selection: any): boolean Whether one event passes. `event` is nil for a name with no metadata at all.
---@field isActive fun(selection: any): boolean Whether the criterion is narrowing anything.
---@field summarize fun(selection: any): string Short text for the collapsed summary line.

---@param value any
---@return number
local function toNumber(value)
    return tonumber(value) or 0
end

---@param event table?
---@return number
local function attenuationOf(event)
    return event and (tonumber(event.attenuation) or 0) or 0
end

---@param event table?
---@return number
local function durationOf(event)
    return event and (tonumber(event.duration) or 0) or 0
end

---@type SoundCriterion[]
local criteria = {
    {
        id = "playback",
        label = "Playback",
        kind = "choice",
        tooltip = "Whether the event keeps going or ends on its own.",
        options = {
            { key = "any", label = "Any" },
            { key = "loop", label = "Looping", tooltip = "Keeps playing until something stops it.\nWhat an emitter or an ambient area's active events need." },
            { key = "oneshot", label = "One-shot", tooltip = "Plays through and ends.\nWhat a field that fires an event and never stops it needs." }
        },
        test = function (event, selection)
            if selection == "loop" then
                return event ~= nil and event.looping == true
            end

            if selection == "oneshot" then
                -- An event with no metadata is kept: nothing says it loops, and it is referenced by
                -- shipped data. `getEventShortNote` marks it as unknown on the row.
                return event == nil or event.looping ~= true
            end

            return true
        end,
        isActive = function (selection) return selection ~= "any" end,
        summarize = function (selection) return selection == "loop" and "Looping" or "One-shot" end
    },
    {
        id = "space",
        label = "Positioning",
        kind = "choice",
        tooltip = "Whether the event is heard from where it sits, or at a fixed level everywhere.",
        options = {
            { key = "any", label = "Any" },
            { key = "positional", label = "Positional", tooltip = "Has an attenuation radius, so it fades with distance and comes from the node's position." },
            { key = "flat", label = "2D", tooltip = "No attenuation: feeds a bus at a fixed level and ignores where the node sits.\nUseful for music and UI, useless for an emitter." }
        },
        test = function (event, selection)
            if selection == "positional" then
                return attenuationOf(event) > 0
            end

            if selection == "flat" then
                return event ~= nil and attenuationOf(event) <= 0
            end

            return true
        end,
        isActive = function (selection) return selection ~= "any" end,
        summarize = function (selection) return selection == "positional" and "Positional" or "2D" end
    },
    {
        id = "range",
        label = "Range",
        kind = "range",
        unit = "m",
        max = MAX_RANGE,
        format = "%.0f",
        tooltip = "Attenuation radius, in metres. Leave a bound at 0 for no limit.\nThis is what separates a 5 m interior hum from a 130 m city element.",
        test = function (event, selection)
            local value = attenuationOf(event)
            if selection.min > 0 and value < selection.min then return false end
            if selection.max > 0 and value > selection.max then return false end

            return true
        end,
        isActive = function (selection) return selection.min > 0 or selection.max > 0 end,
        summarize = function (selection)
            if selection.min > 0 and selection.max > 0 then
                return string.format("%.0f-%.0fm", selection.min, selection.max)
            end

            return selection.min > 0 and string.format("%.0fm+", selection.min) or string.format("under %.0fm", selection.max)
        end
    },
    {
        id = "duration",
        label = "Length",
        kind = "range",
        unit = "s",
        max = MAX_DURATION,
        format = "%.2f",
        tooltip = "How long the event runs, in seconds. Leave a bound at 0 for no limit.\nOnly one-shots carry a length; a looping event has none and is filtered out by any bound set here.",
        test = function (event, selection)
            local value = durationOf(event)
            if selection.min > 0 and value < selection.min then return false end
            if selection.max > 0 and (value <= 0 or value > selection.max) then return false end

            return true
        end,
        isActive = function (selection) return selection.min > 0 or selection.max > 0 end,
        summarize = function (selection)
            if selection.min > 0 and selection.max > 0 then
                return string.format("%.2g-%.2gs", selection.min, selection.max)
            end

            return selection.min > 0 and string.format("%.2gs+", selection.min) or string.format("under %.2gs", selection.max)
        end
    },
    {
        id = "tags",
        label = "Category",
        kind = "tags",
        tooltip = "The Wwise authoring hierarchy the event sits in, which is the only category system the game\nships for audio events. Name prefixes split the same kind of sound across several groups, so this\ngroups the list far better. Only ambient-side events carry categories.",
        test = function (event, selection)
            local tags = event and event.tags
            if type(tags) ~= "table" then return false end

            if selection.matchAll then
                for tag, enabled in pairs(selection.keys) do
                    if enabled == true and utils.indexValue(tags, tag) == -1 then
                        return false
                    end
                end

                return true
            end

            for _, tag in ipairs(tags) do
                if selection.keys[tag] == true then return true end
            end

            return false
        end,
        isActive = function (selection)
            for _, enabled in pairs(selection.keys) do
                if enabled == true then return true end
            end

            return false
        end,
        summarize = function (selection)
            local count = 0
            local last = ""
            for tag, enabled in pairs(selection.keys) do
                if enabled == true then
                    count = count + 1
                    last = tag
                end
            end

            return count == 1 and last or string.format("%d categories", count)
        end
    },
    {
        id = "documented",
        label = "Metadata",
        kind = "choice",
        tooltip = "A handful of events are referenced by shipped data but missing from the audio tables, so\nnothing is known about them. They are kept by default, since CDPR uses them.",
        options = {
            { key = "any", label = "Any" },
            { key = "documented", label = "Documented only", tooltip = "Hide events the audio tables know nothing about." }
        },
        test = function (event, selection)
            if selection ~= "documented" then return true end

            return event ~= nil and event.unknown ~= true
        end,
        isActive = function (selection) return selection ~= "any" end,
        summarize = function () return "Documented" end
    }
}

--- Presets --------------------------------------------------------------------------------------

---Criteria that come up more than once, so a call site names the reason rather than restating it.
---Each carries a `require` (locked) or `defaults` (pre-set, still the author's to change) map plus
---the `notes` explaining it, and is merged under whatever the caller passes of its own.
soundSelector.presets = {
    ---What a `worldStaticSoundEmitterNode` needs: an event that keeps playing and is heard from
    ---where the node sits. Measured over the shipped world, exactly one emitter out of 3,519 breaks
    ---either half of this, which is why the emitter side takes it as a rule.
    emitter = {
        require = { playback = "loop", space = "positional" },
        notes = {
            playback = "This field fires its event once when it streams in, so a one-shot plays through and then leaves silence. Only looping events are listed.",
            space = "An event with no attenuation is not positional: it plays at a fixed level regardless of where the node sits, or feeds a bus and is inaudible here."
        }
    },
    ---What a field that starts an event and never stops it needs - a transform animation's sound
    ---track, a one-off device operation. A looping event started there runs forever with nothing
    ---left holding a handle to stop it.
    oneShot = {
        require = { playback = "oneshot" },
        notes = {
            playback = "This field starts its event and never stops it, so a looping event would run forever with nothing holding a handle to stop it. Only one-shots are listed."
        }
    }
}

---The same criteria as a preset, pre-set instead of locked.
---
---Use this wherever the shipped data breaks the rule the preset states. An ambient area's active
---events want a looping, positional event for the same reason an emitter does, but 54 of the 591
---events CDPR ships in that field are neither -- so hiding them would be hiding vanilla. Pre-setting
---the filter puts the right list in front of the author and leaves the other 54 one click away.
---@param preset table One of `soundSelector.presets`.
---@return table opts Merge-ready `defaults` / `notes` pair.
function soundSelector.preferred(preset)
    return { defaults = preset.require, notes = preset.notes }
end

--- State ----------------------------------------------------------------------------------------

---Per-selector filter and search state, keyed by `stateKey`. Transient UI state that belongs to a
---field rather than to the data being edited, so it is deliberately not kept on the element: an
---element table can be rebuilt between frames, and this must survive that.
local states = {}

---Filtered option lists, keyed by the signature of the criteria that produced them. Filtering runs
---over the whole catalogue, so it is done once per distinct filter rather than once per frame.
local filteredCache = {}
local filteredCacheOrder = {}
local FILTERED_CACHE_LIMIT = 12

---Writes one criterion's value into the state table it is stored across.
---@param state table
---@param id string Criterion id.
---@param value any Same shape `require` and `defaults` use.
local function applySelection(state, id, value)
    if id == "range" or id == "duration" then
        if type(value) == "table" then
            state[id .. "Min"] = toNumber(value.min)
            state[id .. "Max"] = toNumber(value.max)
        end

        return
    end

    if id == "tags" then
        if type(value) == "table" then
            state.tagKeys = {}
            for _, tag in ipairs(value) do
                state.tagKeys[tostring(tag)] = true
            end
            state.tagsAll = value.matchAll == true
        end

        return
    end

    state[id] = tostring(value)
end

---Neutral state, before any default is seeded into it.
---@return table state
local function newState()
    return {
        search = "",
        expanded = false,
        scopeAll = false,
        tagSearch = "",
        playback = "any",
        space = "any",
        documented = "any",
        rangeMin = 0,
        rangeMax = 0,
        durationMin = 0,
        durationMax = 0,
        tagKeys = {},
        tagsAll = false
    }
end

---@param key string
---@param defaults table<string, any>? Seeded on first use only, so a filter the author then changes stays changed.
---@return table state
local function getState(key, defaults)
    local state = states[key]

    if not state then
        state = newState()

        for id, value in pairs(defaults or {}) do
            applySelection(state, id, value)
        end

        states[key] = state
    end

    return state
end

---Current value of one criterion: the mandatory value when the field forces one, else what the
---author has picked. `require` entries are the same shape as the state they replace.
---@param criterion SoundCriterion
---@param state table
---@param required table
---@return any selection
local function getSelection(criterion, state, required)
    local forced = required[criterion.id]

    if criterion.kind == "choice" then
        return forced ~= nil and tostring(forced) or state[criterion.id]
    end

    if criterion.kind == "range" then
        if type(forced) == "table" then
            return { min = toNumber(forced.min), max = toNumber(forced.max) }
        end

        return { min = state[criterion.id .. "Min"], max = state[criterion.id .. "Max"] }
    end

    -- tags
    if type(forced) == "table" then
        local keys = {}
        for _, tag in ipairs(forced) do
            keys[tostring(tag)] = true
        end

        return { keys = keys, matchAll = forced.matchAll == true }
    end

    return { keys = state.tagKeys, matchAll = state.tagsAll }
end

---Stable text standing for one criterion's current selection, so the filtered list can be cached.
---@param criterion SoundCriterion
---@param selection any
---@return string
local function signatureOf(criterion, selection)
    if criterion.kind == "choice" then
        return tostring(selection)
    end

    if criterion.kind == "range" then
        return string.format("%g:%g", selection.min, selection.max)
    end

    local tags = {}
    for tag, enabled in pairs(selection.keys) do
        if enabled == true then
            table.insert(tags, tag)
        end
    end
    table.sort(tags)

    return table.concat(tags, ",") .. (selection.matchAll and "|all" or "|any")
end

--- Filtering ------------------------------------------------------------------------------------

---The pool a selector draws from, before any criterion narrows it.
---@param opts table
---@param state table
---@return string[] names
---@return boolean restricted True while a caller-supplied pool is in force.
local function getPool(opts, state)
    local pool = opts.pool

    if type(pool) == "table" and type(pool.names) == "table" and not (state.scopeAll and pool.lock ~= true) then
        return pool.names, true
    end

    return audioData.getAllEventNames(), false
end

---Names passing every criterion.
---@param names string[]
---@param selections table<string, any>
---@return { names: string[], set: table<string, boolean> } entry
local function filterNames(names, selections)
    local matches = {}
    local set = {}

    for _, name in ipairs(names) do
        local event = audioData.getEvent(name)
        local passes = true

        for _, criterion in ipairs(criteria) do
            local selection = selections[criterion.id]
            if selection ~= nil and criterion.isActive(selection) and not criterion.test(event, selection) then
                passes = false
                break
            end
        end

        if passes then
            table.insert(matches, name)
            set[name] = true
        end
    end

    return { names = matches, set = set }
end

---Cached filter result for one signature, evicted oldest-first.
---@param signature string
---@param build fun(): table
---@return table entry
local function getCached(signature, build)
    local cached = filteredCache[signature]
    if cached then return cached end

    cached = build()
    filteredCache[signature] = cached
    table.insert(filteredCacheOrder, signature)

    while #filteredCacheOrder > FILTERED_CACHE_LIMIT do
        local dropped = table.remove(filteredCacheOrder, 1)
        filteredCache[dropped] = nil
    end

    return cached
end

---The option list, with the current value kept in it whether or not it passes the filters: a name
---the author already chose, or typed past the filters, has to stay selectable or picking it again
---would mean retyping it. Kept out of the cache signature - it varies per field while the filter
---does not - and memoized on the cache entry, so the expensive pass is still shared.
---@param entry table Result of `filterNames`.
---@param keep string
---@return string[] names
local function withCurrent(entry, keep)
    if keep == "" or entry.set[keep] then
        return entry.names
    end

    entry.withCurrent = entry.withCurrent or {}
    local cached = entry.withCurrent[keep]

    if not cached then
        cached = { keep }
        for _, name in ipairs(entry.names) do
            table.insert(cached, name)
        end
        entry.withCurrent[keep] = cached
    end

    return cached
end

---Puts every optional criterion back to where the field started it. Locked ones are read from
---`require`, so they are unaffected either way.
---@param state table
---@param defaults table<string, any>? The field's own pre-set criteria.
local function resetOptional(state, defaults)
    for key, value in pairs(newState()) do
        -- `search` is the typed query, not a filter, and clearing it here would be a surprise.
        if key ~= "search" and key ~= "expanded" then
            state[key] = value
        end
    end

    for id, value in pairs(defaults or {}) do
        applySelection(state, id, value)
    end
end

--- Header ---------------------------------------------------------------------------------------

---Draws one criterion's control, greyed out and lock-marked when the field forces its value.
---@param criterion SoundCriterion
---@param state table
---@param required table
---@param notes table<string, string> Per-criterion explanation supplied by the field.
---@param labelWidth number
local function drawCriterion(criterion, state, required, notes, labelWidth)
    local locked = required[criterion.id] ~= nil
    -- The field's own note, when it has one, says more than the generic description ever could -
    -- it is the reason this particular field cares. Shown whether the criterion is locked or only
    -- pre-set, since either way the author is owed the why.
    local note = notes[criterion.id]
        or (locked and "Fixed by the field being edited." or nil)

    if locked then
        style.styledText(IconGlyphs.Lock, style.mutedColor)
        style.tooltip(note)
        ImGui.SameLine()
    end

    style.mutedText(criterion.label)
    style.tooltip(note or criterion.tooltip or "")
    ImGui.SameLine()
    ImGui.SetCursorPosX(labelWidth)

    local selection = getSelection(criterion, state, required)

    style.pushGreyedOut(locked)

    if criterion.kind == "choice" then
        for index, option in ipairs(criterion.options) do
            if index > 1 then ImGui.SameLine() end

            if style.switchTabButton(option.label .. "##" .. criterion.id .. option.key, selection == option.key) and not locked then
                state[criterion.id] = option.key
            end
            style.tooltip(note or option.tooltip or "")
        end

    elseif criterion.kind == "range" then
        local width = 70

        ImGui.SetNextItemWidth(width * style.viewSize)
        local newMin = ImGui.DragFloat("##" .. criterion.id .. "Min", selection.min, 0.5, 0, criterion.max, criterion.format)
        if not locked then
            state[criterion.id .. "Min"] = math.min(math.max(newMin, 0), criterion.max)
        end
        style.tooltip(note or "Lower bound, 0 for none.")

        ImGui.SameLine()
        style.mutedText("-")
        ImGui.SameLine()

        ImGui.SetNextItemWidth(width * style.viewSize)
        local newMax = ImGui.DragFloat("##" .. criterion.id .. "Max", selection.max, 0.5, 0, criterion.max, criterion.format)
        if not locked then
            state[criterion.id .. "Max"] = math.min(math.max(newMax, 0), criterion.max)
        end
        style.tooltip(note or "Upper bound, 0 for none.")

        ImGui.SameLine()
        style.mutedText(criterion.unit or "")

    else
        local tags = audioData.getEventTagList()

        if style.drawSearchClearButton("##tagSearchClear", state.tagSearch ~= "") then
            state.tagSearch = ""
            style.clearSearchInput("##tagSearch", true)
        end

        ImGui.SetNextItemWidth(180 * style.viewSize)
        state.tagSearch = style.searchInputTextWithHint("##tagSearch", "Search category...", state.tagSearch, 100)

        ImGui.SameLine()
        local nextMatchAll, matchAllChanged = style.toggleButton(IconGlyphs.SetCenter .. "##tagsAll", selection.matchAll)
        if matchAllChanged and not locked then
            state.tagsAll = nextMatchAll
        end
        style.tooltip(note or "Require every selected category instead of any of them.")

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.CloseCircleOutline .. "##tagsClear") and not locked then
            state.tagKeys = {}
        end
        style.pushButtonNoBG(false)
        style.tooltip("Unselect every category")

        ---Rows of the category list. Pulled out and called through `pcall` so that however it
        ---fails, the `EndChild` below still runs: an unclosed child window is a crash, not an error.
        local function drawTagRows()
            local query = string.lower(state.tagSearch or "")
            local drawn = 0

            for _, tag in ipairs(tags) do
                if utils.safePatternMatch(string.lower(tag), query) then
                    drawn = drawn + 1
                    local checked = selection.keys[tag] == true
                    local newChecked, changed = ImGui.Checkbox(tag .. "##tag" .. tag, checked)
                    if changed and not locked then
                        state.tagKeys[tag] = newChecked or nil
                    end
                end
            end

            if drawn == 0 then
                style.mutedText("No matching categories")
            end
        end

        ImGui.SetCursorPosX(labelWidth)

        -- `EndChild` is unconditional: ImGui pairs it with `BeginChild` whether or not the child
        -- turned out to be visible, and inside a combo popup it regularly is not.
        local tagListVisible = ImGui.BeginChild("##tagList", 0, TAG_LIST_HEIGHT * style.viewSize, true)
        if tagListVisible then
            pcall(drawTagRows)
        end
        ImGui.EndChild()
    end

    style.popGreyedOut(locked)
end

---Draws the filter header inside the popup: a one-line summary that says what is already being
---filtered on, and the controls behind it.
---@param state table
---@param opts table
---@param required table
---@param notes table<string, string>
---@param defaults table<string, any> The field's own pre-set criteria, for the reset button.
---@param selections table<string, any>
---@param matchCount number
---@param poolCount number
local function drawHeader(state, opts, required, notes, defaults, selections, matchCount, poolCount)
    local hidden = opts.hide or {}
    local summary = {}
    local anyOptional = false
    local startY = ImGui.GetCursorPosY()

    for _, criterion in ipairs(criteria) do
        if not hidden[criterion.id] then
            local selection = selections[criterion.id]
            if selection ~= nil and criterion.isActive(selection) then
                local text = criterion.summarize(selection)
                table.insert(summary, required[criterion.id] ~= nil and (IconGlyphs.Lock .. text) or text)
            end

            if required[criterion.id] == nil then
                anyOptional = true
            end
        end
    end

    local expanded, toggled = style.toggleButton(IconGlyphs.Filter .. "##soundFilters", state.expanded)
    if toggled then
        state.expanded = expanded
    end
    style.tooltip("Filter the list on what the audio tables know about each event.\nA locked criterion is fixed by the field being edited and says why in its tooltip.")

    ImGui.SameLine()
    style.mutedText(string.format("%d of %d", matchCount, poolCount))
    style.tooltip("Events matching the filters, out of the pool this field draws from.")

    if #summary > 0 then
        ImGui.SameLine()
        style.mutedText("| " .. table.concat(summary, ", "))
    end

    if state.expanded then
        ImGui.Separator()

        local labels = {}
        for _, criterion in ipairs(criteria) do
            if not hidden[criterion.id] then
                table.insert(labels, IconGlyphs.Lock .. criterion.label)
            end
        end
        local labelWidth = utils.getTextMaxWidth(labels) + 3 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()

        local pool = opts.pool
        if type(pool) == "table" and type(pool.names) == "table" then
            local locked = pool.lock == true

            if locked then
                style.styledText(IconGlyphs.Lock, style.mutedColor)
                style.tooltip(pool.note or "This field only accepts names from this list.")
                ImGui.SameLine()
            end

            style.mutedText("Source")
            style.tooltip(pool.note or "Which set of events the list is drawn from.")
            ImGui.SameLine()
            ImGui.SetCursorPosX(labelWidth)

            style.pushGreyedOut(locked)
            if style.switchTabButton((pool.label or "Shipped") .. "##scopePool", not state.scopeAll or locked) and not locked then
                state.scopeAll = false
            end
            style.tooltip(pool.note or "")
            ImGui.SameLine()
            if style.switchTabButton("All events##scopeAll", state.scopeAll and not locked) and not locked then
                state.scopeAll = true
            end
            style.tooltip(locked and (pool.note or "") or "Widen to every event the game knows.\nAnything outside the shipped list is untested in this field.")
            style.popGreyedOut(locked)
        end

        for _, criterion in ipairs(criteria) do
            if not hidden[criterion.id] then
                drawCriterion(criterion, state, required, notes, labelWidth)
            end
        end

        if anyOptional then
            if ImGui.Button("Reset filters##soundFiltersReset") then
                resetOptional(state, defaults)
            end
            style.tooltip("Put every filter you can change back to where this field started it.\nThe locked ones stay, since the field needs them.")
        end
    end

    ImGui.Separator()

    -- Measured so the option list below can give back exactly what the panel took, keeping the
    -- popup the same height open or closed. Without that the popup has to grow the frame the panel
    -- appears, and everything under it spends that frame outside the popup's clip rect.
    state.headerHeight = (ImGui.GetCursorPosY() - startY) / style.viewSize
    if not state.expanded then
        state.collapsedHeaderHeight = state.headerHeight
    end
end

--- Drawing --------------------------------------------------------------------------------------

---@class SoundSelectorOpts
---@field stateKey string? Key the filter and search state is kept under. Defaults to `id`; pass one explicitly wherever `id` is only unique inside an `ImGui.PushID` scope.
---@field element table? Element used for undo history tracking when the selection changes.
---@field require table<string, any>? Mandatory criteria, keyed by criterion id: `playback` / `space` / `documented` take an option key, `range` / `duration` a `{ min, max }` table, `tags` a list of tag names. Shown locked in the header.
---@field defaults table<string, any>? Criteria pre-set the first time this field is drawn, in the same shape as `require`, but left the author's to change. Use these where the shipped data breaks the rule often enough that hiding the exceptions would be wrong.
---@field notes table<string, string>? Why each criterion is required or pre-set, shown on its row.
---@field preset table? One of `soundSelector.presets`, or `soundSelector.preferred(...)` of one. Merged under the caller's own `require` / `defaults` / `notes`.
---@field pool { names: string[], label: string?, note: string?, lock: boolean? }? Restricted candidate set, e.g. the names shipped data actually uses in this field. Offered alongside the full catalogue unless `lock` is set.
---@field hide table<string, boolean>? Criteria not offered at all, keyed by id.
---@field width number? Combo width in unscaled style units (default `250`).
---@field listHeight number? Height of the option list (default `220`).
---@field hint string? Search placeholder.
---@field tooltip string? Helper text appended after the current value.
---@field allowCustom boolean? Allow a typed name that is in no list (default `true`). The vocabularies are the shipped ones, and a modded soundbank adds its own.
---@field clearable boolean? Right-clicking the combo clears the selection.
---@field showNote boolean? Draw the event's loop / length / range summary after the combo (default `true`).
---@field showTest boolean? Draw a button that plays the event right now (default `false`).
---@field testTarget userdata? Game object the test button emits from, default the player.

---Draws the selector.
---@param id string Combo ID, `##` prefixed.
---@param value string Currently selected event name.
---@param opts SoundSelectorOpts?
---@return string value
---@return boolean finished True on the frame the selection changed.
function soundSelector.draw(id, value, opts)
    opts = opts or {}
    value = tostring(value or "")

    local preset = opts.preset or {}

    ---@param field string
    ---@return table merged The preset's entry with the caller's own layered over it.
    local function merge(field)
        local merged = {}
        for key, entry in pairs(preset[field] or {}) do merged[key] = entry end
        for key, entry in pairs(opts[field] or {}) do merged[key] = entry end

        return merged
    end

    local required = merge("require")
    local notes = merge("notes")
    -- A criterion the field locks is not also seeded as a default: `getSelection` reads it straight
    -- off `require`, and seeding it would only leave a stale value behind if the lock ever went.
    local defaults = merge("defaults")
    for key in pairs(required) do defaults[key] = nil end

    local state = getState(tostring(opts.stateKey or id), defaults)

    local hidden = opts.hide or {}

    ---Resolves the whole filter in one go: what each criterion is set to, which pool is in force,
    ---and the names that survive. Run once before the popup opens, and again inside it after the
    ---header has drawn, so a filter the author changes narrows the list on the same frame.
    ---@return table selections
    ---@return string[] matches
    ---@return string[] pool
    ---@return boolean restricted
    local function resolve()
        local selections = {}
        local parts = {}

        for _, criterion in ipairs(criteria) do
            -- A hidden criterion still applies when the field forces it: hiding it says "do not
            -- offer this", not "ignore what this field needs".
            if not hidden[criterion.id] or required[criterion.id] ~= nil then
                local selection = getSelection(criterion, state, required)
                selections[criterion.id] = selection
                table.insert(parts, criterion.id .. "=" .. signatureOf(criterion, selection))
            end
        end

        local pool, restricted = getPool(opts, state)
        table.insert(parts, "pool=" .. (restricted and tostring((opts.pool and opts.pool.label) or #pool) or "all"))

        local entry = getCached(table.concat(parts, ";"), function ()
            return filterNames(pool, selections)
        end)

        return selections, withCurrent(entry, value), pool, restricted
    end

    local selections, matches, pool = resolve()

    -- The list gives back what the filter panel takes, down to a floor that keeps it worth
    -- scrolling, so opening the panel barely moves the popup's height. `headerHeight` is last
    -- frame's measurement, so the first frame after an expand is still too tall; it settles on the
    -- next, and `trackedSearchDropdown` now closes its child window either way.
    local baseListHeight = opts.listHeight or 220
    local headerGrowth = math.max(0, (state.headerHeight or 0) - (state.collapsedHeaderHeight or 0))

    local newValue, searchValue, finished = style.trackedSearchDropdown(
        id,
        opts.hint or "Search sound event...",
        value,
        state.search,
        matches,
        {
            element = opts.element,
            width = opts.width or 250,
            listHeight = math.max(150, baseListHeight - headerGrowth),
            popupMinWidth = POPUP_WIDTH,
            allowCustom = opts.allowCustom ~= false,
            clearable = opts.clearable,
            tooltip = opts.tooltip,
            emptyListText = "No event matches these filters",
            -- Deliberately not `matchContentWidth`: that measures every option with `CalcTextSize`
            -- on every frame, and the catalogue runs to over twenty thousand names.
            optionAnnotationFn = function (optionText)
                return audioData.getEventShortNote(optionText)
            end,
            optionTooltipFn = function (optionText)
                return audioData.describeEvent(optionText)
            end,
            drawHeaderFn = function ()
                drawHeader(state, opts, required, notes, defaults, selections, #matches, #pool)
            end,
            -- Resolved inside the popup so a filter changed in the header narrows the list on the
            -- same frame, rather than one frame later. The header's own counts stay a frame behind,
            -- which is the one thing that cannot be both drawn first and counted after.
            optionsFn = function ()
                selections, matches, pool = resolve()

                return matches
            end
        }
    )
    state.search = searchValue

    if opts.showTest == true then
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        local testable = utils.trimString(value)
        local canTest = testable ~= "" and testable ~= "None"
        ImGui.BeginDisabled(not canTest)
        if ImGui.Button(IconGlyphs.Play .. id .. "Test") and canTest then
            soundSystemData.testSoundEvent(testable, opts.testTarget)
        end
        ImGui.EndDisabled()
        style.pushButtonNoBG(false)
        style.tooltip("Play this event right now.\nSupport is uneven across the audio banks, so hear it before shipping it.")
    end

    if opts.showNote ~= false and value ~= "" then
        local note = audioData.getEventShortNote(value)
        if note ~= "" then
            ImGui.SameLine()
            style.mutedText(note)
            style.tooltip(audioData.describeEvent(value))
        end
    end

    return newValue, finished
end

---Drops the cached filter results, so a data reload is picked up.
function soundSelector.invalidate()
    filteredCache = {}
    filteredCacheOrder = {}
end

return soundSelector
