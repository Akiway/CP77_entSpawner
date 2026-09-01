local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local registry = require("modules/utils/game/nodeRefRegistry")
local history = require("modules/utils/project/history")
local soundSystemData = require("modules/utils/data/soundSystem")

---Quick setup for `SoundSystemControllerPS` devices: the entry list players pick from, and the
---speaker chain the sound comes out of.
---
---Entries are always written whole. The generic instance data editor cannot author them, because
---`SoundSystemSettings.musicSettings` is a `handle:MusicSettings` that ships null: `convertHandle`
---drops null handles, so the key never reaches the JSON and no row is ever drawn for it.
local quickSoundSystemSetupUI = {
    POPUP_ID = "Quick Sound System Setup##Device"
}

---@param device table
---@param options table?
function quickSoundSystemSetupUI.install(device, options)
    if not device then
        return
    end

    options = options or {}
    local sanitizeConnectionValue = options.sanitizeConnectionValue or utils.sanitizeText
    local boolToInt = options.boolToInt or soundSystemData.boolToInt

    ---Width left for a field once the buttons that follow it on the same row are accounted for.
    ---@param buttonLabels string[]?
    ---@param minWidth number?
    ---@return number
    local function getRowFieldWidth(buttonLabels, minWidth)
        local labels = buttonLabels or {}
        local styleData = ImGui.GetStyle()
        local framePaddingX = styleData.FramePadding.x * 2
        local itemSpacingX = styleData.ItemSpacing.x
        local reservedWidth = 0

        for _, label in ipairs(labels) do
            reservedWidth = reservedWidth + ImGui.CalcTextSize(tostring(label or "")) + framePaddingX
        end

        if #labels > 0 then
            reservedWidth = reservedWidth + itemSpacingX * #labels
        end

        local fieldWidth = (ImGui.GetWindowContentRegionWidth() - ImGui.GetCursorPosX() - reservedWidth) / style.viewSize
        return math.max(tonumber(minWidth) or 140, fieldWidth)
    end

    ---Right-aligns the reorder / delete button cluster of a list row header.
    ---@param labels string[]
    ---@return number
    local function getRightAlignedButtonsX(labels)
        local styleData = ImGui.GetStyle()
        local framePaddingX = styleData.FramePadding.x * 2
        local width = 0

        for index, label in ipairs(labels) do
            width = width + ImGui.CalcTextSize(tostring(label)) + framePaddingX
            if index > 1 then
                width = width + styleData.ItemSpacing.x
            end
        end

        return ImGui.GetWindowContentRegionWidth() - width
    end

    ---X position for fields following `style.drawIconLabelRow` labels.
    ---@param rows { icon: string?, label: string }[]
    ---@return number
    local function getIconLabelFieldX(rows)
        local styleData = ImGui.GetStyle()
        local maxWidth = 0

        for _, row in ipairs(rows or {}) do
            row = row or {}
            local icon = row.icon
            local label = row.label
            local rowWidth = ImGui.CalcTextSize(tostring(label or ""))

            if icon ~= nil and icon ~= "" then
                rowWidth = rowWidth + ImGui.CalcTextSize(tostring(icon)) + styleData.ItemSpacing.x
            end

            maxWidth = math.max(maxWidth, rowWidth)
        end

        return maxWidth + 2 * styleData.ItemSpacing.x
    end

    ---@return string[]
    local function getInteractionOptions(currentValue)
        local seen = {}
        local optionList = {}

        for _, interactionID in ipairs(soundSystemData.INTERACTIONS) do
            if not seen[interactionID] then
                seen[interactionID] = true
                table.insert(optionList, interactionID)
            end
        end

        local current = sanitizeConnectionValue(currentValue)
        if current ~= "" and not seen[current] then
            table.insert(optionList, 1, current)
        end

        return optionList
    end

    ---One `soundSystemSettings` entry.
    ---@param entry table Normalized entry
    ---@param index number
    ---@param count number
    ---@return boolean deleted
    function device:drawSoundSystemEntry(entry, index, count)
        ImGui.PushID("soundSystemEntry" .. index)

        local labelX = getIconLabelFieldX({
            { icon = IconGlyphs.FormatQuoteClose, label = "Caption" },
            { icon = IconGlyphs.Tune, label = "Source" },
            { icon = IconGlyphs.Radio, label = "Station" },
            { icon = IconGlyphs.MusicNote, label = "Sound Event" },
            { icon = IconGlyphs.HeadphonesOff, label = "Status Effect" },
            { icon = IconGlyphs.Chip, label = "Quickhack" }
        })

        local headerLabel = soundSystemData.getEntryLabel(entry, index, function (value)
            return self:resolveLocKey(value)
        end)

        local buttonLabels = { IconGlyphs.ArrowUp, IconGlyphs.ArrowDown, IconGlyphs.DeleteOutline }
        local rightAlignedButtonsX = getRightAlignedButtonsX(buttonLabels)

        self.soundSystemEntryOpenState = self.soundSystemEntryOpenState or {}
        local stateKey = "entry:" .. tostring(index)
        local initialOpen = self.soundSystemEntryOpenState[stateKey]
        if initialOpen == nil then
            initialOpen = true
            self.soundSystemEntryOpenState[stateKey] = initialOpen
        end
        ImGui.SetNextItemOpen(initialOpen, ImGuiCond.Once)

        local sectionFlags = ImGuiTreeNodeFlags.SpanFullWidth + ImGuiTreeNodeFlags.AllowItemOverlap
        local sectionOpen = ImGui.CollapsingHeader(headerLabel .. "##soundSystemEntrySection", sectionFlags)
        self.soundSystemEntryOpenState[stateKey] = sectionOpen

        ImGui.SameLine()
        ImGui.SetCursorPosX(math.max(ImGui.GetCursorPosX(), rightAlignedButtonsX))
        style.pushGreyedOut(index <= 1)
        if ImGui.Button(IconGlyphs.ArrowUp .. "##soundSystemEntryUp") and index > 1 then
            self:moveSoundSystemEntry(index, -1)
            style.popGreyedOut(index <= 1)
            ImGui.PopID()
            return true
        end
        style.popGreyedOut(index <= 1)
        style.tooltip("Move this entry before the previous one.\nEntry order is the button order in game.")

        ImGui.SameLine()
        style.pushGreyedOut(index >= count)
        if ImGui.Button(IconGlyphs.ArrowDown .. "##soundSystemEntryDown") and index < count then
            self:moveSoundSystemEntry(index, 1)
            style.popGreyedOut(index >= count)
            ImGui.PopID()
            return true
        end
        style.popGreyedOut(index >= count)
        style.tooltip("Move this entry after the next one.")

        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline .. "##soundSystemEntryDelete") then
            self:removeSoundSystemEntry(index)
            ImGui.PopID()
            return true
        end
        style.tooltip("Delete this entry.")

        if not sectionOpen then
            ImGui.PopID()
            return false
        end

        local musicData = entry.musicSettings.Data
        local source = soundSystemData.getEntrySource(entry)

        ---@param mutate fun(draft: table)
        local function commit(mutate)
            local draft = utils.deepcopy(entry)
            mutate(draft)
            self:updateSoundSystemEntry(index, draft)
        end

        -- Caption ---------------------------------------------------------------------------------

        style.drawIconLabelRow(IconGlyphs.FormatQuoteClose, "Caption")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)

        self.soundSystemInteractionSearch = self.soundSystemInteractionSearch or {}
        local searchKey = tostring(index)
        local currentInteraction = sanitizeConnectionValue(entry.interactionName["$value"])
        local editedInteraction, searchValue, interactionChanged = style.trackedSearchDropdown(
            "##soundSystemEntryCaption",
            "Search interaction record...",
            currentInteraction,
            self.soundSystemInteractionSearch[searchKey] or "",
            getInteractionOptions(currentInteraction),
            {
                element = self.object,
                width = getRowFieldWidth({}, 220),
                matchContentWidth = true,
                allowCustom = true,
                -- The caption the player will read, not a description of the record: the author is
                -- picking button text, so the button text is what the row has to show.
                optionTooltipFn = function (optionValue)
                    return soundSystemData.getInteractionOptionTooltip(optionValue, function (value)
                        return self:resolveLocKey(value)
                    end)
                end,
                tooltip = "TweakDB record supplying this entry's button caption.\nPick a vanilla record, or type your own Interactions.* id."
            }
        )
        self.soundSystemInteractionSearch[searchKey] = searchValue
        if interactionChanged and sanitizeConnectionValue(editedInteraction) ~= currentInteraction then
            commit(function (draft)
                draft.interactionName["$value"] = sanitizeConnectionValue(editedInteraction)
            end)
            ImGui.PopID()
            return false
        end

        local caption = soundSystemData.getInteractionCaption(currentInteraction, function (value)
            return self:resolveLocKey(value)
        end)

        ImGui.SetCursorPosX(labelX)
        if caption then
            style.mutedText(style.resolveActionLabelNoIconOnly(IconGlyphs.Translate, caption, nil))
            style.tooltip(caption)
        elseif soundSystemData.interactionExists(currentInteraction) then
            style.mutedText("Record has no caption")
            style.tooltip("The record exists but its caption flat is empty, so the button shows nothing.")
        else
            style.styledText(IconGlyphs.AlertOutline .. " Record not in TweakDB", style.warnColor)
            style.tooltip("No such record. Ship a .tweak defining it, or the button renders without a caption.")
        end

        -- Source ----------------------------------------------------------------------------------

        style.drawIconLabelRow(IconGlyphs.Tune, "Source")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        for sourceIndex, musicSource in ipairs(soundSystemData.MUSIC_SOURCES) do
            if sourceIndex > 1 then
                ImGui.SameLine()
            end

            local selected = source == musicSource.key
            if style.switchTabButton(musicSource.label .. "##soundSystemEntrySource" .. musicSource.key, selected, 110 * style.viewSize, 0)
                and not selected then
                commit(function (draft)
                    draft.musicSettings.Data = soundSystemData.createMusicSettings(musicSource.key, draft.musicSettings.Data)
                end)
                ImGui.PopID()
                return false
            end
        end
        style.tooltip("PlayRadio streams a station, PlaySoundEvent fires one audio event.")

        if source == "PlayRadio" then
            style.drawIconLabelRow(IconGlyphs.Radio, "Station")
            ImGui.SameLine()
            ImGui.SetCursorPosX(labelX)
            local stationLabels = soundSystemData.getStationLabels()
            local newStation, stationChanged = style.trackedCombo(
                self.object,
                "##soundSystemEntryStation",
                soundSystemData.getStationComboIndex(musicData.radioStation),
                stationLabels,
                220,
                { tooltip = "Base game stations only. A station added by a mod cannot be selected here:\nthe field is an engine enum, not a record reference." }
            )
            if stationChanged then
                commit(function (draft)
                    draft.musicSettings.Data.radioStation = soundSystemData.getStationByComboIndex(newStation)
                end)
                ImGui.PopID()
                return false
            end
        else
            local eventName = tostring(musicData.soundEvent and musicData.soundEvent["$value"] or "")

            style.drawIconLabelRow(IconGlyphs.MusicNote, "Sound Event")
            ImGui.SameLine()
            ImGui.SetCursorPosX(labelX)
            -- The catalogue is the Static Audio Emitter spawn list: every name in it is an event the
            -- mod already places as a `worldStaticSoundEmitterNode`, which is a far better starting
            -- point than a remembered event name. Custom entries stay allowed, because the list is
            -- the shipped events only.
            self.soundSystemEventSearch = self.soundSystemEventSearch or {}
            local eventSearchKey = tostring(index)
            local eventSearch = self.soundSystemEventSearch[eventSearchKey] or ""

            local editedEvent, eventSearchValue, eventFinished = style.trackedSearchDropdown(
                "##soundSystemEntrySoundEvent",
                "Search audio event...",
                eventName,
                eventSearch,
                soundSystemData.getSoundEventOptions(eventName),
                {
                    element = self.object,
                    width = getRowFieldWidth({ IconGlyphs.Play }, 220),
                    allowCustom = true,
                    -- The catalogue runs to a thousand-odd events, so the list gets more than the
                    -- default height to scroll in. The rows are clipped either way.
                    listHeight = 260,
                    tooltip = "Audio event fired on the connected speakers.\nBrowses the whole Static Audio Emitter list, or takes any event name you type."
                }
            )
            self.soundSystemEventSearch[eventSearchKey] = eventSearchValue

            ImGui.SameLine()
            style.pushButtonNoBG(true)
            local canTest = utils.trimString(eventName) ~= ""
            ImGui.BeginDisabled(not canTest)
            if ImGui.Button(IconGlyphs.Play .. "##soundSystemEventTest") and canTest then
                soundSystemData.testSoundEvent(eventName)
            end
            ImGui.EndDisabled()
            style.pushButtonNoBG(false)
            style.tooltip("Play this event on the player right now.\nSupport is uneven across the audio banks, so hear it before shipping it.")

            if eventFinished and utils.trimString(tostring(editedEvent)) ~= eventName then
                commit(function (draft)
                    draft.musicSettings.Data.soundEvent["$value"] = utils.trimString(tostring(editedEvent))
                end)
                ImGui.PopID()
                return false
            end

            if soundSystemData.isMusicBusEvent(eventName) then
                ImGui.SetCursorPosX(labelX)
                style.styledTextWrapped(
                    IconGlyphs.AlertOutline .. " Music bus event, plays everywhere at full volume rather than from the speakers.",
                    style.warnColor
                )
            end
        end

        -- Status effect ---------------------------------------------------------------------------

        style.drawIconLabelRow(IconGlyphs.HeadphonesOff, "Status Effect")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        local statusIndex = math.max(0, utils.indexValue(soundSystemData.STATUS_EFFECTS, tostring(musicData.statusEffect or "NONE")) - 1)
        local newStatus, statusChanged = style.trackedCombo(
            self.object,
            "##soundSystemEntryStatusEffect",
            statusIndex,
            soundSystemData.STATUS_EFFECTS,
            140,
            { tooltip = "Effect applied to whoever is in range while this entry plays." }
        )
        if statusChanged then
            commit(function (draft)
                draft.musicSettings.Data.statusEffect = soundSystemData.STATUS_EFFECTS[newStatus + 1] or "NONE"
            end)
            ImGui.PopID()
            return false
        end

        -- Quickhack -------------------------------------------------------------------------------

        style.drawIconLabelRow(IconGlyphs.Chip, "Quickhack")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        local isQuickHack = boolToInt(entry.canBeUsedAsQuickHack, 0) == 1
        local newQuickHack, quickHackChanged = style.trackedCheckbox(self.object, "##soundSystemEntryQuickHack", isQuickHack)
        style.tooltip("Expose this entry as a quickhack instead of a regular interaction.\nVanilla pairs this with Interactions.HackVolume and the DEAFENED effect.")
        if quickHackChanged then
            commit(function (draft)
                draft.canBeUsedAsQuickHack = newQuickHack and 1 or 0
            end)
            ImGui.PopID()
            return false
        end

        ImGui.PopID()
        return false
    end

    ---Stable identity for one speaker, shared by its graph box, the selection and the range draft.
    ---@param speakerEntry table
    ---@param index number
    ---@return string
    local function getSpeakerKey(speakerEntry, index)
        return speakerEntry.nodeRef ~= "" and ("nodeRef:" .. speakerEntry.nodeRef) or ("index:" .. tostring(index))
    end

    ---Display name of one speaker, falling back through NodeRef to a placeholder.
    ---@param speakerEntry table
    ---@return string
    local function getSpeakerName(speakerEntry)
        local name = speakerEntry.speakerElement and tostring(speakerEntry.speakerElement.name or "") or ""
        if name ~= "" then
            return name
        end

        return speakerEntry.nodeRef ~= "" and speakerEntry.nodeRef or "Unresolved"
    end

    ---@param value string
    ---@return string
    local function getVisibleLabel(value)
        local text = tostring(value or "")
        local idStart = text:find("##", 1, true)
        if idStart then
            text = text:sub(1, idStart - 1)
        end

        return (text:gsub("%s+$", ""))
    end

    ---@param label string
    ---@param maxWidth number
    ---@return string
    local function fitSingleLineLabel(label, maxWidth)
        local text = tostring(label or "")
        if text == "" or maxWidth <= 0 then
            return ""
        end

        if ImGui.CalcTextSize(text) <= maxWidth then
            return text
        end

        while #text > 1 and ImGui.CalcTextSize(text .. "...") > maxWidth do
            text = text:sub(1, #text - 1)
        end

        return text .. "..."
    end

    ---Title row used by the selected graph item panel.
    ---@param icon string
    ---@param title string
    ---@param subtitle string?
    ---@param action table? `{ label: string, tooltip: string?, danger: boolean?, onClick: function }`
    ---@return boolean actionClicked
    local function drawSoundSystemDetailTitle(icon, title, subtitle, action)
        local styleData = ImGui.GetStyle()
        local actionLabel = action and tostring(action.label or "") or ""
        local visibleActionLabel = action and getVisibleLabel(actionLabel) or ""
        local actionWidth = 0

        if action and actionLabel ~= "" then
            actionWidth = ImGui.CalcTextSize(visibleActionLabel)
                + styleData.FramePadding.x * 2
        end

        local contentWidth = ImGui.GetWindowContentRegionWidth()
        local subtitleText = tostring(subtitle or "")
        local subtitleWidth = subtitleText ~= "" and ImGui.CalcTextSize(subtitleText) or 0
        local iconText = tostring(icon or "")
        local iconPrefix = iconText ~= "" and (iconText .. "  ") or ""
        local iconWidth = iconPrefix ~= "" and ImGui.CalcTextSize(iconPrefix) or 0
        local titleReserve = actionWidth
            + (actionWidth > 0 and styleData.ItemSpacing.x * 2 or 0)
            + (subtitleWidth > 0 and subtitleWidth + styleData.ItemSpacing.x or 0)
            + iconWidth
        local titleText = fitSingleLineLabel(tostring(title or ""), contentWidth - titleReserve)

        ImGui.AlignTextToFramePadding()
        style.styledText(iconPrefix .. titleText, style.highlightColor)

        if subtitleText ~= "" then
            ImGui.SameLine()
            style.mutedText(subtitleText)
        end

        local clicked = false
        if action and actionLabel ~= "" and action.onClick then
            ImGui.SameLine()
            ImGui.SetCursorPosX(math.max(0, contentWidth - actionWidth))

            if action.danger then
                clicked = style.dangerButton(actionLabel)
            else
                clicked = ImGui.Button(actionLabel)
            end

            if action.tooltip then
                style.tooltip(action.tooltip)
            end
            if clicked then
                action.onClick()
            end
        end

        ImGui.Separator()
        ImGui.Spacing()

        return clicked
    end

    ---The speaker picked in the chain graph. Exactly one is ever on screen, so there is no
    ---collapsing header here; optional title actions come from the owning selection panel.
    ---@param speakerEntry table
    ---@param index number
    ---@param options table?
    ---@return boolean removed
    function device:drawSoundSystemSpeaker(speakerEntry, index, options)
        ImGui.PushID("soundSystemSpeaker" .. index)
        options = options or {}

        local labelX = getIconLabelFieldX({
            { label = "Node Ref" },
            { label = "Appearance" },
            { icon = IconGlyphs.SignalDistanceVariant, label = "Range" },
            { icon = IconGlyphs.Radio, label = "Default Station" },
            { icon = IconGlyphs.BugPlayOutline, label = "Glitch SFX" },
            { icon = IconGlyphs.MusicNoteOff, label = "Use Only Glitch SFX" },
            { icon = IconGlyphs.MusicNote, label = "Distraction Station" }
        })

        local stateKey = getSpeakerKey(speakerEntry, index)
        local definition = speakerEntry.definition

        if drawSoundSystemDetailTitle(
            definition and definition.icon or IconGlyphs.Speaker,
            getSpeakerName(speakerEntry),
            tostring(speakerEntry.label),
            options.titleAction
        ) then
            ImGui.PopID()
            return true
        end

        style.mutedText("Node Ref")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        local nodeRefOwner = speakerEntry.speakerElement or self.object
        local editedNodeRef, _, nodeRefFinished = style.trackedTextField(
            nodeRefOwner,
            "##soundSystemSpeakerNodeRef",
            speakerEntry.nodeRef,
            "NodeRef...",
            getRowFieldWidth({ IconGlyphs.ReloadAlert })
        )
        if nodeRefFinished then
            self:updateSpeakerNodeRef(speakerEntry, editedNodeRef)
        end
        if speakerEntry.rawNodeRef ~= speakerEntry.nodeRef then
            style.tooltip("Connection stored as hash/alias, resolved to: " .. tostring(speakerEntry.nodeRef))
        else
            style.tooltip("NodeRef shared by the speaker node and this connection.")
        end

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        local canGenerate = speakerEntry.speakerElement ~= nil
        ImGui.BeginDisabled(not canGenerate)
        if ImGui.Button(IconGlyphs.ReloadAlert .. "##soundSystemSpeakerNodeRefGenerate") and canGenerate then
            self:generateSpeakerNodeRef(speakerEntry)
        end
        ImGui.EndDisabled()
        style.pushButtonNoBG(false)
        if canGenerate then
            style.tooltip("Generate a unique NodeRef and update the connection.")
        else
            style.tooltip("Speaker node not found in this project. The connection points somewhere else.")
        end

        if not speakerEntry.speakerSpawnable then
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " No node in this project carries that NodeRef. It will not play unless the target lives in another sector.",
                style.warnColor
            )
            ImGui.PopID()
            return false
        end

        local speakerSpawnable = speakerEntry.speakerSpawnable

        if definition and #definition.appearances > 1 then
            style.mutedText("Appearance")
            ImGui.SameLine()
            ImGui.SetCursorPosX(labelX)
            local appIndex = math.max(0, utils.indexValue(definition.appearances, tostring(speakerSpawnable.app or "")) - 1)
            local newApp, appChanged = style.trackedCombo(
                speakerEntry.speakerElement or self.object,
                "##soundSystemSpeakerAppearance",
                appIndex,
                definition.appearances,
                200
            )
            style.tooltip("Mesh variant of this speaker.")
            if appChanged then
                speakerSpawnable.app = definition.appearances[newApp + 1] or speakerSpawnable.app
                speakerSpawnable:respawn()
            end
        end

        local setup, componentID = self:getSpeakerSetup(speakerSpawnable)
        if not setup or not componentID then
            style.mutedText("Speaker state is not available yet. It loads once the node is assembled.")
            ImGui.PopID()
            return false
        end

        -- The range drag would respawn the speaker every frame, so it is held in a draft and only
        -- written once the drag ends.
        self.soundSystemRangeDrafts = self.soundSystemRangeDrafts or {}
        local draftKey = stateKey
        local displayedRange = tonumber(self.soundSystemRangeDrafts[draftKey]) or setup.range

        style.drawIconLabelRow(IconGlyphs.SignalDistanceVariant, "Range")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        local newRange, rangeChanged, rangeFinished = style.trackedDragFloat(
            speakerEntry.speakerElement or self.object,
            "##soundSystemSpeakerRange",
            displayedRange,
            0.1,
            0,
            500,
            "%.2f m",
            70
        )
        style.tooltip("Audible radius of this speaker. Ships at 10 m.\nThe deafen/suppress game effect uses it as its radius, so it is also how far a status effect entry reaches.")
        if rangeChanged then
            self.soundSystemRangeDrafts[draftKey] = newRange
            -- Follows the slider live, so the sphere is a preview rather than a report.
            if speakerSpawnable.updateSpeakerRangeSphere then
                speakerSpawnable:updateSpeakerRangeSphere(nil, newRange)
            end
        end
        if rangeFinished then
            self.soundSystemRangeDrafts[draftKey] = nil
            local updated = utils.deepcopy(setup)
            updated.range = math.max(0, tonumber(newRange) or 0)
            setup = self:updateSpeakerSetup(speakerSpawnable, componentID, updated)
        end

        ImGui.SameLine()
        local sphereShown = speakerSpawnable.showSpeakerRangeSphere == true
        local newSphereShown, sphereToggled = style.toggleButton(IconGlyphs.HospitalMarker .. "##soundSystemSpeakerRangeSphere", sphereShown)
        if sphereToggled and speakerSpawnable.setSpeakerRangeSphereVisible then
            history.addAction(history.getElementChange(speakerEntry.speakerElement or self.object))
            speakerSpawnable:setSpeakerRangeSphereVisible(newSphereShown)
        end
        style.tooltip(sphereShown
            and "Hide the range sphere on this speaker."
            or "Draw a sphere at the audible radius, the way the light radius preview does.")

        local stationLabels = soundSystemData.getStationLabels()
        local chainContext = self.soundSystemChainContext or {}
        local defaultOverridden, defaultNote = soundSystemData.describeDefaultStation(
            chainContext.isOn ~= false,
            chainContext.entryCount or 0
        )

        style.drawIconLabelRow(IconGlyphs.Radio, "Default Station")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        style.pushGreyedOut(defaultOverridden)
        local newDefault, defaultChanged = style.trackedCombo(
            speakerEntry.speakerElement or self.object,
            "##soundSystemSpeakerDefaultMusic",
            soundSystemData.getStationComboIndex(setup.defaultMusic),
            stationLabels,
            220,
            { tooltip = "Station this speaker starts on, before anything tells it what to play.\n" .. defaultNote }
        )
        style.popGreyedOut(defaultOverridden)
        if defaultChanged then
            local updated = utils.deepcopy(setup)
            updated.defaultMusic = soundSystemData.getStationByComboIndex(newDefault)
            setup = self:updateSpeakerSetup(speakerSpawnable, componentID, updated)
        end

        if defaultOverridden then
            ImGui.SetCursorPosX(labelX)
            style.mutedText(IconGlyphs.InformationOutline .. " Overridden by this system's starting entry")
            style.tooltip(defaultNote)
        end

        local glitchSFX = tostring(setup.glitchSFX and setup.glitchSFX["$value"] or "")

        style.drawIconLabelRow(IconGlyphs.BugPlayOutline, "Glitch SFX")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)

        self.soundSystemGlitchSFXSearch = self.soundSystemGlitchSFXSearch or {}
        local glitchSFXSearch = self.soundSystemGlitchSFXSearch[draftKey] or ""
        local editedGlitchSFX, glitchSFXSearchValue, glitchSFXFinished = style.trackedSearchDropdown(
            "##soundSystemSpeakerGlitchSFX",
            "Search audio event...",
            glitchSFX,
            glitchSFXSearch,
            soundSystemData.getSoundEventOptions(glitchSFX),
            {
                element = speakerEntry.speakerElement or self.object,
                width = getRowFieldWidth({ IconGlyphs.Play }, 220),
                allowCustom = true,
                listHeight = 260,
                tooltip = "Audio event played when this speaker glitches during the Malfunction quickhack.\nBrowses the whole Static Audio Emitter list, or takes any event name you type."
            }
        )
        self.soundSystemGlitchSFXSearch[draftKey] = glitchSFXSearchValue

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        local testGlitchSFX = utils.trimString(glitchSFX)
        local canTestGlitchSFX = testGlitchSFX ~= "" and testGlitchSFX ~= "None"
        ImGui.BeginDisabled(not canTestGlitchSFX)
        if ImGui.Button(IconGlyphs.Play .. "##soundSystemSpeakerGlitchSFXTest") and canTestGlitchSFX then
            soundSystemData.testSoundEvent(testGlitchSFX)
        end
        ImGui.EndDisabled()
        style.pushButtonNoBG(false)
        style.tooltip("Play this glitch SFX on the player right now.")

        if glitchSFXFinished and utils.trimString(tostring(editedGlitchSFX)) ~= glitchSFX then
            local updated = utils.deepcopy(setup)
            local normalizedGlitchSFX = utils.trimString(tostring(editedGlitchSFX))
            updated.glitchSFX = updated.glitchSFX or {}
            updated.glitchSFX["$type"] = "CName"
            updated.glitchSFX["$storage"] = "string"
            updated.glitchSFX["$value"] = normalizedGlitchSFX ~= "" and normalizedGlitchSFX or "None"
            setup = self:updateSpeakerSetup(speakerSpawnable, componentID, updated)
            glitchSFX = tostring(setup.glitchSFX and setup.glitchSFX["$value"] or "")
        end

        style.drawIconLabelRow(IconGlyphs.MusicNoteOff, "Use Only Glitch SFX")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        local useOnlyGlitchSFX = boolToInt(setup.useOnlyGlitchSFX, 0) == 1
        local newUseOnlyGlitchSFX, useOnlyGlitchSFXChanged = style.trackedCheckbox(
            speakerEntry.speakerElement or self.object,
            "##soundSystemSpeakerUseOnlyGlitchSFX",
            useOnlyGlitchSFX
        )
        style.tooltip("Skip the distraction station during the Malfunction quickhack and play only the glitch SFX.")
        if useOnlyGlitchSFXChanged then
            local updated = utils.deepcopy(setup)
            updated.useOnlyGlitchSFX = newUseOnlyGlitchSFX and 1 or 0
            setup = self:updateSpeakerSetup(speakerSpawnable, componentID, updated)
            useOnlyGlitchSFX = newUseOnlyGlitchSFX
        end

        style.drawIconLabelRow(IconGlyphs.MusicNote, "Distraction Station")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        style.pushGreyedOut(useOnlyGlitchSFX)
        ImGui.BeginDisabled(useOnlyGlitchSFX)
        local newDistraction, distractionChanged = style.trackedCombo(
            speakerEntry.speakerElement or self.object,
            "##soundSystemSpeakerDistractionMusic",
            soundSystemData.getStationComboIndex(setup.distractionMusic),
            stationLabels,
            220,
            {
                tooltip = useOnlyGlitchSFX
                    and (soundSystemData.DISTRACTION_STATION_NOTE .. "\nIgnored while useOnlyGlitchSFX is enabled.")
                    or soundSystemData.DISTRACTION_STATION_NOTE
            }
        )
        ImGui.EndDisabled()
        style.popGreyedOut(useOnlyGlitchSFX)
        if distractionChanged then
            local updated = utils.deepcopy(setup)
            updated.distractionMusic = soundSystemData.getStationByComboIndex(newDistraction)
            self:updateSpeakerSetup(speakerSpawnable, componentID, updated)
        end

        if useOnlyGlitchSFX then
            ImGui.SetCursorPosX(labelX)
            style.mutedText(IconGlyphs.InformationOutline .. " Ignored while useOnlyGlitchSFX is enabled")
            style.tooltip("The Malfunction quickhack will play glitchSFX only.")
        end

        ImGui.PopID()
        return false
    end

    ---Stable identity for one master, shared by its graph box and the selection.
    ---@param masterEntry table
    ---@param index number
    ---@return string
    local function getMasterKey(masterEntry, index)
        local nodeRef = masterEntry.masterSpawnable
            and sanitizeConnectionValue(masterEntry.masterSpawnable.nodeRef)
            or ""

        return nodeRef ~= "" and ("nodeRef:" .. nodeRef) or ("index:" .. tostring(index))
    end

    ---@param masterEntry table
    ---@return string
    local function getMasterName(masterEntry)
        local name = masterEntry.masterElement and tostring(masterEntry.masterElement.name or "") or ""

        return name ~= "" and name or "Unnamed"
    end

    ---The master picked in the chain graph. As with speakers, exactly one is on screen and optional
    ---title actions come from the owning selection panel.
    ---@param masterEntry table
    ---@param index number
    ---@param options table?
    ---@return boolean removed
    function device:drawSoundSystemMaster(masterEntry, index, options)
        ImGui.PushID("soundSystemMaster" .. index)
        options = options or {}

        local labelX = getIconLabelFieldX({
            { label = "Node Ref" },
            { label = "Appearance" },
            { icon = IconGlyphs.Monitor, label = "Starting Menu" },
            { icon = IconGlyphs.Tune, label = "Terminal Preset" }
        })

        local definition = masterEntry.definition

        if drawSoundSystemDetailTitle(
            definition and definition.icon or IconGlyphs.Monitor,
            getMasterName(masterEntry),
            tostring(masterEntry.label),
            options.titleAction
        ) then
            ImGui.PopID()
            return true
        end

        local masterSpawnable = masterEntry.masterSpawnable
        if not masterSpawnable then
            style.mutedText("Master node not found in this project.")
            ImGui.PopID()
            return false
        end

        style.mutedText("Node Ref")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        local currentMasterNodeRef = sanitizeConnectionValue(masterSpawnable.nodeRef)
        local nodeRefOwner = masterEntry.masterElement or self.object
        local editedNodeRef, _, nodeRefFinished = style.trackedTextField(
            nodeRefOwner,
            "##soundSystemMasterNodeRef",
            currentMasterNodeRef,
            "NodeRef...",
            getRowFieldWidth({ IconGlyphs.ReloadAlert })
        )
        if nodeRefFinished then
            self:updateSoundSystemMasterNodeRef(masterEntry, editedNodeRef)
        end
        style.tooltip("NodeRef of this master node. Its connection to this sound system is stored separately.")

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        local canGenerate = masterEntry.masterElement ~= nil
        ImGui.BeginDisabled(not canGenerate)
        if ImGui.Button(IconGlyphs.ReloadAlert .. "##soundSystemMasterNodeRefGenerate") and canGenerate then
            self:generateSoundSystemMasterNodeRef(masterEntry)
        end
        ImGui.EndDisabled()
        style.pushButtonNoBG(false)
        style.tooltip(canGenerate
            and "Generate a unique NodeRef for this master."
            or "Master node not found in this project.")

        if not masterSpawnable.persistent then
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " Persistent is off on this master, so anything the player does to it is forgotten on reload.",
                style.warnColor
            )
        end

        if definition and definition.isComputer then
            local setup, componentID = self:getComputerSetup(masterSpawnable)

            if not setup or not componentID then
                style.mutedText("Computer state is not available yet. It loads once the node is assembled.")
                ImGui.PopID()
                return false
            end

            style.drawIconLabelRow(IconGlyphs.Monitor, "Starting Menu")
            ImGui.SameLine()
            ImGui.SetCursorPosX(labelX)
            local menuIndex = math.max(0, utils.indexValue(soundSystemData.COMPUTER_MENUS, setup.startingMenu) - 1)
            local newMenu, menuChanged = style.trackedCombo(
                masterEntry.masterElement or self.object,
                "##soundSystemMasterStartingMenu",
                menuIndex,
                soundSystemData.COMPUTER_MENUS,
                160,
                { tooltip = "SYSTEM opens straight onto the device page the sound system lives on." }
            )
            if menuChanged then
                local updated = utils.deepcopy(setup)
                updated.startingMenu = soundSystemData.COMPUTER_MENUS[newMenu + 1] or "MAIN"
                setup = self:updateComputerSetup(masterSpawnable, componentID, updated)
            end

            style.drawIconLabelRow(IconGlyphs.Tune, "Terminal Preset")
            ImGui.SameLine()
            ImGui.SetCursorPosX(labelX)

            local isPreset = soundSystemData.isComputerTerminalPreset(setup)
            ImGui.BeginDisabled(isPreset)
            if ImGui.Button("Apply##soundSystemMasterPreset") and not isPreset then
                history.addAction(history.getElementChange(masterEntry.masterElement or self.object))
                self:updateComputerSetup(masterSpawnable, componentID, soundSystemData.applyComputerTerminalPreset(setup))
            end
            ImGui.EndDisabled()
            style.tooltip("Open on the system page, hide the top bar, and turn off the mail, files, internet and newsfeed tabs.")

            ImGui.SameLine()
            if isPreset then
                style.mutedText(IconGlyphs.Check .. " Set up as a sound system terminal")
            else
                style.mutedText("Not set up as a terminal")
            end
        end

        ImGui.PopID()
        return false
    end

    ---Panel under the chain graph: whatever the graph has selected, and nothing else.
    ---Defaults to the system, which is where the entry list lives.
    ---@param childHeight number?
    ---@param entries table[]
    ---@param speakers table[]
    ---@param masters table[]
    function device:drawSoundSystemSelectionPanel(childHeight, entries, speakers, masters)
        local panelHeight = math.max(0, tonumber(childHeight) or (280 * style.viewSize))
        local selection = self.soundSystemSelection or { kind = "system" }

        ---Finds the selected row, or `nil` once it has been deleted from under the selection.
        ---@param list table[]
        ---@param keyFn fun(entry: table, index: number): string
        ---@return table?, number?
        local function findSelected(list, keyFn)
            for index, entry in ipairs(list) do
                if keyFn(entry, index) == selection.key then
                    return entry, index
                end
            end

            return nil, nil
        end

        if not style.beginCard("##soundSystemSelectionChild", {
            height = panelHeight,
            flags = ImGuiWindowFlags.HorizontalScrollbar
        }) then
            style.endCard()
            return
        end

        if selection.kind == "speaker" then
            local speakerEntry, index = findSelected(speakers, getSpeakerKey)
            if speakerEntry and index then
                self:drawSoundSystemSpeaker(speakerEntry, index, {
                    titleAction = {
                        label = IconGlyphs.DeleteOutline .. "##soundSystemSelectedSpeakerDelete",
                        tooltip = "Delete this speaker and remove its connection.",
                        danger = true,
                        onClick = function ()
                            self:removeSpeaker(speakerEntry)
                            self.soundSystemSelection = { kind = "system" }
                        end
                    }
                })
            else
                style.mutedText("That speaker is gone. Pick another box in the graph.")
            end
        elseif selection.kind == "master" then
            local masterEntry, index = findSelected(masters, getMasterKey)
            if masterEntry and index then
                self:drawSoundSystemMaster(masterEntry, index, {
                    titleAction = {
                        label = IconGlyphs.DeleteOutline .. "##soundSystemSelectedMasterDelete",
                        tooltip = "Delete this master.",
                        danger = true,
                        onClick = function ()
                            self:removeSoundSystemMaster(masterEntry)
                            self.soundSystemSelection = { kind = "system" }
                        end
                    }
                })
            else
                style.mutedText("That master is gone. Pick another box in the graph.")
            end
        else
            local addLabel, addHiddenText = style.resolveActionLabel(IconGlyphs.Plus, "Add Entry", "soundSystemAddEntry", nil, true)
            local systemName = self.object and tostring(self.object.name or "") or ""
            drawSoundSystemDetailTitle(
                soundSystemData.SYSTEM_ICON,
                systemName ~= "" and systemName or "Sound System",
                string.format("%d %s", #entries, #entries == 1 and "entry" or "entries"),
                {
                    label = addLabel,
                    tooltip = addHiddenText
                        and (addHiddenText .. "\nAdd one button to the device UI.")
                        or "Add one button to the device UI.",
                    onClick = function ()
                        self:addSoundSystemEntry()
                    end
                }
            )

            if #entries == 0 then
                ImGui.TextWrapped("No entries yet. Each entry becomes one button on the device UI.")
            else
                for index, entry in ipairs(entries) do
                    if self:drawSoundSystemEntry(entry, index, #entries) then
                        break
                    end
                end
            end

            if #entries > soundSystemData.RECOMMENDED_MAX_ENTRIES then
                ImGui.Dummy(0, 4 * style.viewSize)
                style.styledTextWrapped(
                    string.format(
                        "%s %d entries. Past about %d the buttons start overlapping on the device UI.",
                        IconGlyphs.AlertOutline,
                        #entries,
                        soundSystemData.RECOMMENDED_MAX_ENTRIES
                    ),
                    style.warnColor
                )
            end

            -- A radio or a jukebox wired here looks connected in the editor and does nothing in
            -- game, because `RefreshSlaves` only forwards to `SpeakerControllerPS`. Saying so here
            -- is the difference between a five minute fix and an evening of guessing.
            local ignored = self.getIgnoredSlaveConnections and self:getIgnoredSlaveConnections() or {}
            if #ignored > 0 then
                ImGui.Dummy(0, 6 * style.viewSize)
                ImGui.Separator()
                style.styledTextWrapped(
                    string.format(
                        "%s %d connected device%s the sound system cannot drive:",
                        IconGlyphs.AlertOutline,
                        #ignored,
                        #ignored == 1 and "" or "s"
                    ),
                    style.warnColor
                )

                for _, connection in ipairs(ignored) do
                    local name = connection.element and tostring(connection.element.name or "") or ""
                    style.mutedText(string.format(
                        "  %s  |  %s",
                        name ~= "" and name or connection.nodeRef,
                        connection.className
                    ))
                    style.tooltip(connection.reason .. "\n" .. connection.nodeRef)
                end
            end
        end

        ImGui.Dummy(0, 8 * style.viewSize)
        style.endCard()
    end

    -- Chain graph ---------------------------------------------------------------------------------

    local GRAPH_NODE_HEIGHT = 36
    local GRAPH_ROW_GAP = 24
    local GRAPH_NODE_GAP = 10
    local GRAPH_PADDING = 10
    local GRAPH_NODE_PADDING_X = 10
    local GRAPH_MIN_NODE_WIDTH = 76
    local GRAPH_MAX_NODE_WIDTH = 200
    local GRAPH_SUBTITLE_RATIO = 0.82
    ---Square, so it reads as an action rather than as another node in the row.
    local GRAPH_ADD_SIZE = 26

    ---Shortens a label to fit a node box, so a long element name cannot blow the layout out.
    ---@param label string
    ---@param maxWidth number
    ---@param fontRatio number
    ---@return string
    local function fitLabel(label, maxWidth, fontRatio)
        local text = tostring(label or "")
        if text == "" then
            return ""
        end

        local function widthOf(value)
            return (ImGui.CalcTextSize(value)) * fontRatio
        end

        if widthOf(text) <= maxWidth then
            return text
        end

        while #text > 1 and widthOf(text .. "...") > maxWidth do
            text = text:sub(1, #text - 1)
        end

        return text .. "..."
    end

    ---Title text for the graph node. Icons are drawn separately so they can sit centered across the
    ---whole item rather than riding the title line.
    ---@param item table
    ---@return string
    local function getGraphNodeTitle(item)
        return tostring(item.title or "")
    end

    ---One box of the chain graph. Draws itself and reports a left click.
    ---@param drawList table
    ---@param item table `{ id, x, y, width, height, color, icon, title, subtitle, tooltip, selected }`
    ---@return boolean clicked
    local function drawGraphNode(drawList, item)
        local x, y, width, height = item.x, item.y, item.width, item.height
        local color = item.color

        ImGui.SetCursorScreenPos(x, y)
        local clicked = ImGui.InvisibleButton(item.id, width, height)
        local hovered = ImGui.IsItemHovered()

        if item.tooltip then
            style.tooltip(item.tooltip)
        end

        -- The context menu has to be bound to the item while it is still the last one submitted,
        -- which is why the caller hands it in rather than opening it afterwards.
        if item.drawContextMenu then
            item.drawContextMenu()
        end

        local alpha = item.selected and 0x77000000 or (hovered and 0x55000000 or 0x26000000)
        local fillColor = alpha + (color % 0x1000000)
        local rounding = 3 * style.viewSize
        local borderWidth = ((item.selected or hovered) and 2 or 1) * style.viewSize

        ImGui.ImDrawListAddRectFilled(drawList, x, y, x + width, y + height, fillColor, rounding)
        ImGui.ImDrawListAddRect(drawList, x, y, x + width, y + height, color, rounding, 0, borderWidth)

        local fontSize = ImGui.GetFontSize()
        local styleData = ImGui.GetStyle()
        local innerPaddingX = GRAPH_NODE_PADDING_X * style.viewSize
        local icon = tostring(item.icon or "")
        local hasIcon = icon ~= ""
        local iconWidth, iconHeight = 0, fontSize

        if hasIcon then
            iconWidth, iconHeight = ImGui.CalcTextSize(icon)
        end

        local iconSpacing = hasIcon and styleData.ItemSpacing.x or 0
        local textLeft = x + innerPaddingX + iconWidth + iconSpacing
        local textWidth = math.max(1, width - 2 * innerPaddingX - iconWidth - iconSpacing)
        local titleText = fitLabel(getGraphNodeTitle(item), textWidth, 1)
        local titleWidth = ImGui.CalcTextSize(titleText)
        local subtitle = item.subtitle

        if hasIcon then
            ImGui.ImDrawListAddText(
                drawList,
                fontSize,
                x + innerPaddingX,
                y + (height - iconHeight) / 2,
                style.highlightColor,
                icon
            )
        end

        if subtitle and subtitle ~= "" then
            local subtitleText = fitLabel(subtitle, textWidth, GRAPH_SUBTITLE_RATIO)
            local subtitleWidth = ImGui.CalcTextSize(subtitleText) * GRAPH_SUBTITLE_RATIO
            local blockHeight = fontSize + fontSize * GRAPH_SUBTITLE_RATIO
            local top = y + (height - blockHeight) / 2
            local titleX = hasIcon and textLeft or (x + (width - titleWidth) / 2)
            local subtitleX = hasIcon and textLeft or (x + (width - subtitleWidth) / 2)

            ImGui.ImDrawListAddText(drawList, fontSize, titleX, top, style.highlightColor, titleText)
            ImGui.ImDrawListAddText(
                drawList,
                fontSize * GRAPH_SUBTITLE_RATIO,
                subtitleX,
                top + fontSize,
                style.mutedColor,
                subtitleText
            )
        else
            ImGui.ImDrawListAddText(
                drawList,
                fontSize,
                hasIcon and textLeft or (x + (width - titleWidth) / 2),
                y + (height - fontSize) / 2,
                style.highlightColor,
                titleText
            )
        end

        return clicked and item.suppressClick ~= true, hovered
    end

    ---Square dashed-looking box that ends the master and speaker rows.
    ---@param drawList table
    ---@param id string
    ---@param x number
    ---@param y number
    ---@param size number
    ---@param color integer
    ---@param tooltip string
    ---@param disabled boolean
    ---@param suppressClick boolean?
    ---@return boolean clicked
    local function drawGraphAddButton(drawList, id, x, y, size, color, tooltip, disabled, suppressClick)
        ImGui.SetCursorScreenPos(x, y)
        local clicked = ImGui.InvisibleButton(id, size, size) and not disabled and suppressClick ~= true
        local itemHovered = ImGui.IsItemHovered()
        local hovered = itemHovered and not disabled

        style.tooltip(tooltip)

        local accent = disabled and style.greyedColor or color
        local rounding = 3 * style.viewSize

        if hovered then
            ImGui.ImDrawListAddRectFilled(drawList, x, y, x + size, y + size, 0x40000000 + (accent % 0x1000000), rounding)
        end
        ImGui.ImDrawListAddRect(drawList, x, y, x + size, y + size, accent, rounding, 0, 1 * style.viewSize)

        local glyph = IconGlyphs.Plus
        local glyphWidth, glyphHeight = ImGui.CalcTextSize(glyph)
        ImGui.ImDrawListAddText(
            drawList,
            ImGui.GetFontSize(),
            x + (size - glyphWidth) / 2,
            y + (size - glyphHeight) / 2,
            disabled and style.greyedColor or style.highlightColor,
            glyph
        )

        return clicked, itemHovered
    end

    ---Width a node needs for its two lines, clamped so one long name cannot dominate the row.
    ---@param item table
    ---@return number
    local function getGraphNodeWidth(item)
        local styleData = ImGui.GetStyle()
        local icon = tostring(item.icon or "")
        local iconWidth = icon ~= "" and (ImGui.CalcTextSize(icon) + styleData.ItemSpacing.x) or 0
        local titleWidth = ImGui.CalcTextSize(getGraphNodeTitle(item))
        local subtitleWidth = item.subtitle and (ImGui.CalcTextSize(tostring(item.subtitle)) * GRAPH_SUBTITLE_RATIO) or 0
        local contentWidth = iconWidth + math.max(titleWidth, subtitleWidth) + 2 * GRAPH_NODE_PADDING_X * style.viewSize

        return math.max(
            GRAPH_MIN_NODE_WIDTH * style.viewSize,
            math.min(GRAPH_MAX_NODE_WIDTH * style.viewSize, contentWidth)
        )
    end

    ---Elbow connector from the bottom edge of one node to the top edge of another.
    local function drawGraphLink(drawList, fromX, fromY, toX, toY, color)
        local midY = (fromY + toY) / 2
        local thickness = 1.5 * style.viewSize

        ImGui.ImDrawListAddLine(drawList, fromX, fromY, fromX, midY, color, thickness)
        ImGui.ImDrawListAddLine(drawList, fromX, midY, toX, midY, color, thickness)
        ImGui.ImDrawListAddLine(drawList, toX, midY, toX, toY, color, thickness)
    end

    ---Boxes-and-lines picture of the chain, and the only way to move around the popup: masters on
    ---top, this system in the middle, speakers at the bottom. Left click selects, which is what the
    ---panel underneath draws; right click opens create/remove shortcuts; the box at the end of each
    ---outer row adds one.
    ---@param entries table[]
    ---@param speakers table[]
    ---@param masters table[]
    function device:drawSoundSystemChainGraph(entries, speakers, masters)
        local nodeHeight = GRAPH_NODE_HEIGHT * style.viewSize
        local rowGap = GRAPH_ROW_GAP * style.viewSize
        local nodeGap = GRAPH_NODE_GAP * style.viewSize
        local padding = GRAPH_PADDING * style.viewSize
        local addSize = GRAPH_ADD_SIZE * style.viewSize
        local contentHeight = nodeHeight * 3 + rowGap * 2

        local systemColor = soundSystemData.getChainColor("system")
        local speakerColor = soundSystemData.getChainColor("speaker")
        local masterColor = soundSystemData.getChainColor("master")

        local selection = self.soundSystemSelection or { kind = "system" }
        local addSpeakerPopupId = "##soundSystemGraphAddSpeaker"
        local addMasterPopupId = "##soundSystemGraphAddMaster"
        local graphContextPopupId = "##soundSystemGraphContext"
        local canAddMaster = sanitizeConnectionValue(self.nodeRef) ~= ""

        local function addEntryFromGraph()
            self:addSoundSystemEntry()
            self.soundSystemSelection = { kind = "system" }
        end

        ---@param definition table
        ---@param fallbackIcon string
        ---@return string
        local function getDefinitionMenuLabel(definition, fallbackIcon)
            return string.format("%s  %s", definition.icon or fallbackIcon, definition.label or definition.key)
        end

        local function drawSpeakerDefinitionMenuItems()
            for _, definition in ipairs(soundSystemData.getSpeakerDefinitions()) do
                if ImGui.MenuItem(getDefinitionMenuLabel(definition, IconGlyphs.Speaker)) then
                    self:addSpeaker(definition.key)
                    ImGui.CloseCurrentPopup()
                end
            end
        end

        local function drawMasterDefinitionMenuItems()
            for _, definition in ipairs(soundSystemData.getMasterDefinitions()) do
                if ImGui.MenuItem(getDefinitionMenuLabel(definition, IconGlyphs.Monitor)) then
                    self:addSoundSystemMaster(definition.key)
                    ImGui.CloseCurrentPopup()
                end
                style.tooltip(tostring(definition.hint))
            end
        end

        local function drawGraphCreationMenu()
            if ImGui.MenuItem(IconGlyphs.Plus .. " Add Entry") then
                addEntryFromGraph()
                ImGui.CloseCurrentPopup()
            end

            if ImGui.BeginMenu(IconGlyphs.DesktopClassic .. " Add Master", canAddMaster) then
                drawMasterDefinitionMenuItems()
                ImGui.EndMenu()
            end
            if not canAddMaster then
                style.tooltip("Requires a NodeRef on this sound system.")
            end

            if ImGui.BeginMenu(IconGlyphs.Speaker .. " Add Speaker") then
                drawSpeakerDefinitionMenuItems()
                ImGui.EndMenu()
            end
        end

        ---Measures one row. The add box is excluded from the row width, so it cannot offset the
        ---nodes; the extent width only reserves scroll space for the floated add box.
        ---@param items table[]
        ---@param hasAddButton boolean
        ---@param emptyNote string?
        ---@return table[], number, number
        local function buildRow(items, hasAddButton, emptyNote)
            local rowWidth = 0

            for index, item in ipairs(items) do
                item.width = getGraphNodeWidth(item)
                item.height = nodeHeight
                rowWidth = rowWidth + item.width
                if index > 1 then
                    rowWidth = rowWidth + nodeGap
                end
            end

            if #items == 0 and emptyNote then
                rowWidth = ImGui.CalcTextSize(emptyNote) * GRAPH_SUBTITLE_RATIO
            end

            local extentWidth = rowWidth
            if hasAddButton then
                local addOffset = rowWidth > 0 and (nodeGap + addSize) or addSize
                extentWidth = rowWidth + 2 * addOffset
            end

            return items, rowWidth, extentWidth
        end

        local masterItems = {}
        for index, masterEntry in ipairs(masters) do
            local key = getMasterKey(masterEntry, index)
            local definition = masterEntry.definition

            table.insert(masterItems, {
                icon = definition and definition.icon or IconGlyphs.Monitor,
                title = getMasterName(masterEntry),
                subtitle = tostring(masterEntry.label or "Master"),
                tooltip = "Master: drives this sound system.\nClick to edit it, right click to remove it.",
                color = masterColor,
                selected = selection.kind == "master" and selection.key == key,
                select = { kind = "master", key = key },
                remove = function () self:removeSoundSystemMaster(masterEntry) end
            })
        end

        local speakerItems = {}
        for index, speakerEntry in ipairs(speakers) do
            local key = getSpeakerKey(speakerEntry, index)
            local definition = speakerEntry.definition
            local broken = speakerEntry.speakerSpawnable == nil

            local subtitle = "unresolved"
            if speakerEntry.speakerSpawnable then
                local setup = self:getSpeakerSetup(speakerEntry.speakerSpawnable)
                subtitle = setup and string.format("%.1f m", tonumber(setup.range) or 0) or "loading"
            end

            table.insert(speakerItems, {
                icon = definition and definition.icon or IconGlyphs.Speaker,
                title = getSpeakerName(speakerEntry),
                subtitle = subtitle,
                tooltip = broken
                    and "No node in this project carries that NodeRef.\nClick to edit it, right click to remove it."
                    or "Speaker: plays what this system pushes.\nClick to edit it, right click to remove it.",
                color = broken and style.warnColor or speakerColor,
                selected = selection.kind == "speaker" and selection.key == key,
                select = { kind = "speaker", key = key },
                remove = function () self:removeSpeaker(speakerEntry) end
            })
        end

        local systemName = self.object and tostring(self.object.name or "") or ""
        local systemItems = { {
            icon = soundSystemData.SYSTEM_ICON,
            title = systemName ~= "" and systemName or "Sound System",
            subtitle = string.format("%d %s", #entries, #entries == 1 and "entry" or "entries"),
            tooltip = "This sound system.\nClick to edit its entries, right click to add an entry.",
            color = systemColor,
            selected = selection.kind ~= "speaker" and selection.kind ~= "master",
            select = { kind = "system" },
            contextMenu = function ()
                if ImGui.MenuItem(IconGlyphs.Plus .. " Add Entry") then
                    addEntryFromGraph()
                    ImGui.CloseCurrentPopup()
                end
            end
        } }

        local emptyMasterNote = "No master wired to this system"
        local emptySpeakerNote = "No speaker connected, nothing will be audible"

        local masterRow, masterWidth, masterExtentWidth = buildRow(masterItems, true, emptyMasterNote)
        local speakerRow, speakerWidth, speakerExtentWidth = buildRow(speakerItems, true, emptySpeakerNote)
        local systemRow, systemWidth, systemExtentWidth = buildRow(systemItems, false)

        local contentWidth = math.max(masterExtentWidth, speakerExtentWidth, systemExtentWidth) + 2 * padding

        local styleData = ImGui.GetStyle()
        local parentAvailableWidth = ImGui.GetContentRegionAvail()
        -- The two spare pixels are slack against rounding in the child's inner height: without them
        -- the content lands a fraction over and ImGui adds a vertical scrollbar for it.
        local graphHeight = contentHeight + 2 * styleData.WindowPadding.y + 2 * style.viewSize

        -- A horizontal scrollbar eats into the child's height, which would then produce a vertical
        -- scrollbar as well. The child gets the parent's width less its own padding and border, so
        -- the need is knowable here -- and the guess is deliberately conservative, since reserving
        -- a few unused pixels is invisible where a stray vertical scrollbar is not.
        local childInnerWidth = parentAvailableWidth - 2 * styleData.WindowPadding.x - 2 * style.viewSize
        local scrollbarSlack = style.viewSize
        local needsHorizontalScrollbar = contentWidth > childInnerWidth + scrollbarSlack
        if needsHorizontalScrollbar then
            graphHeight = graphHeight + styleData.ScrollbarSize
        end

        local graphFlags = ImGuiWindowFlags.NoScrollbar + ImGuiWindowFlags.NoScrollWithMouse
        if needsHorizontalScrollbar then
            graphFlags = ImGuiWindowFlags.HorizontalScrollbar + ImGuiWindowFlags.NoScrollWithMouse
        end

        if not ImGui.BeginChild("##soundSystemChainGraph", 0, graphHeight, true, graphFlags) then
            ImGui.EndChild()
            return
        end

        local drawList = ImGui.GetWindowDrawList()
        local startX, startY = ImGui.GetCursorPosX(), ImGui.GetCursorPosY()
        local availableWidth = ImGui.GetContentRegionAvail()
        local layoutWidth = math.max(availableWidth, contentWidth)

        -- Reserved before anything is drawn: the boxes below are placed by screen position, which
        -- the child window does not account for when sizing its scroll extent.
        -- The dummy's lower-right corner is the extent; putting its upper-left there adds one pixel
        -- of overflow and can make the scrollbars flash when the graph already fits.
        ImGui.SetCursorPos(startX + math.max(1, layoutWidth) - 1, startY + math.max(1, contentHeight) - 1)
        ImGui.Dummy(1, 1)
        ImGui.SetCursorPos(startX, startY)

        local windowX, windowY = ImGui.GetWindowPos()
        local scrollX = (ImGui.GetScrollX and ImGui.GetScrollX()) or 0
        local scrollMaxX = (ImGui.GetScrollMaxX and ImGui.GetScrollMaxX()) or 0
        local graphHovered = ImGui.IsWindowHovered and ImGui.IsWindowHovered()
        local mouseX, mouseY = 0, 0
        if ImGui.GetMousePos then
            mouseX, mouseY = ImGui.GetMousePos()
        end
        local overVisibleGraphContent = graphHovered
            and mouseX >= windowX + startX
            and mouseX <= windowX + startX + availableWidth
            and mouseY >= windowY + startY
            and mouseY <= windowY + startY + contentHeight
        local graphItemHovered = false
        local graphControlBounds = {}

        local scrollY = (ImGui.GetScrollY and ImGui.GetScrollY()) or 0
        local originX = windowX + startX - scrollX
        local originY = windowY + startY - scrollY

        ---@param row table[]
        ---@param rowWidth number
        ---@param rowY number
        ---@param idPrefix string
        ---@param addOptions table? `{ id, popupId, color, tooltip, disabled }`
        ---@return table[] placed
        local function drawRow(row, rowWidth, rowY, idPrefix, addOptions)
            local placed = {}
            local rowLeft = math.max(padding, (layoutWidth - rowWidth) / 2)
            local cursorX = originX + rowLeft

            for index, item in ipairs(row) do
                item.id = idPrefix .. tostring(index)
                item.x = cursorX
                item.y = rowY
                item.suppressClick = false

                if item.contextMenu or item.remove then
                    local contextMenuFn = item.contextMenu
                    local removeFn = item.remove
                    item.drawContextMenu = function ()
                        if ImGui.BeginPopupContextItem(item.id .. "Context", ImGuiPopupFlags.MouseButtonRight) then
                            if contextMenuFn then
                                contextMenuFn()
                            end

                            if contextMenuFn and removeFn then
                                ImGui.Separator()
                            end

                            if removeFn and ImGui.MenuItem(IconGlyphs.DeleteOutline .. " Remove") then
                                removeFn()
                                -- The removed node was very likely the selected one, and its key is
                                -- about to match nothing.
                                self.soundSystemSelection = { kind = "system" }
                            end
                            ImGui.EndPopup()
                        end
                    end
                end

                local clicked, hovered = drawGraphNode(drawList, item)
                if hovered then
                    graphItemHovered = true
                end

                if clicked then
                    self.soundSystemSelection = item.select
                end

                table.insert(placed, {
                    centerX = cursorX + item.width / 2,
                    top = rowY,
                    bottom = rowY + nodeHeight
                })
                table.insert(graphControlBounds, {
                    x = cursorX,
                    y = rowY,
                    width = item.width,
                    height = nodeHeight
                })

                cursorX = cursorX + item.width + nodeGap
            end

            if addOptions then
                local addY = rowY + (nodeHeight - addSize) / 2
                local addX = originX + rowLeft + rowWidth + (rowWidth > 0 and nodeGap or 0)
                local clicked, hovered = drawGraphAddButton(
                    drawList,
                    addOptions.id,
                    addX,
                    addY,
                    addSize,
                    addOptions.color,
                    addOptions.tooltip,
                    addOptions.disabled == true
                )
                if hovered then
                    graphItemHovered = true
                end
                if clicked then
                    ImGui.OpenPopup(addOptions.popupId)
                end
                table.insert(graphControlBounds, {
                    x = addX,
                    y = addY,
                    width = addSize,
                    height = addSize
                })
            end

            return placed
        end

        local masterY = originY
        local systemY = masterY + nodeHeight + rowGap
        local speakerY = systemY + nodeHeight + rowGap

        local placedMasters = drawRow(masterRow, masterWidth, masterY, "##soundSystemGraphMaster", {
            id = "##soundSystemGraphAddMasterButton",
            popupId = addMasterPopupId,
            color = masterColor,
            disabled = not canAddMaster,
            tooltip = canAddMaster
                and "Spawn a device that drives this sound system, wired and set up."
                or "Requires a NodeRef on this sound system."
        })
        local placedSystem = drawRow(systemRow, systemWidth, systemY, "##soundSystemGraphSystem")
        local placedSpeakers = drawRow(speakerRow, speakerWidth, speakerY, "##soundSystemGraphSpeaker", {
            id = "##soundSystemGraphAddSpeakerButton",
            popupId = addSpeakerPopupId,
            color = speakerColor,
            tooltip = "Spawn a speaker on this system and connect it."
        })

        local systemNode = placedSystem[1]
        if systemNode then
            for _, master in ipairs(placedMasters) do
                drawGraphLink(drawList, master.centerX, master.bottom, systemNode.centerX, systemNode.top, masterColor)
            end

            for _, speaker in ipairs(placedSpeakers) do
                drawGraphLink(drawList, systemNode.centerX, systemNode.bottom, speaker.centerX, speaker.top, speakerColor)
            end
        end

        -- Empty rows would otherwise read as a rendering bug rather than as missing wiring. The
        -- note is centered like row content; the add box floats after it without moving it.
        local fontSize = ImGui.GetFontSize()

        ---@param text string
        ---@param rowY number
        ---@param rowWidth number
        local function drawEmptyRowNote(text, rowY, rowWidth)
            local rowLeft = math.max(padding, (layoutWidth - rowWidth) / 2)

            ImGui.ImDrawListAddText(
                drawList,
                fontSize * GRAPH_SUBTITLE_RATIO,
                originX + rowLeft,
                rowY + (nodeHeight - fontSize * GRAPH_SUBTITLE_RATIO) / 2,
                style.extraMutedColor,
                text
            )
        end

        if #masterRow == 0 then
            drawEmptyRowNote(emptyMasterNote, masterY, masterWidth)
        end

        if #speakerRow == 0 then
            drawEmptyRowNote(emptySpeakerNote, speakerY, speakerWidth)
        end

        local graphControlHovered = graphItemHovered
        for _, bounds in ipairs(graphControlBounds) do
            if mouseX >= bounds.x
                and mouseX <= bounds.x + bounds.width
                and mouseY >= bounds.y
                and mouseY <= bounds.y + bounds.height then
                graphControlHovered = true
                break
            end
        end

        if self.soundSystemGraphPanButton ~= nil then
            if not ImGui.IsMouseDown or not ImGui.IsMouseDown(self.soundSystemGraphPanButton) then
                self.soundSystemGraphPanButton = nil
            end
        end

        local blankGraphHovered = overVisibleGraphContent and not graphControlHovered
        local canvasHovered = false
        if blankGraphHovered or self.soundSystemGraphPanButton ~= nil then
            ImGui.SetCursorPos(startX, startY)
            ImGui.InvisibleButton("##soundSystemGraphCanvas", availableWidth, contentHeight)
            canvasHovered = ImGui.IsItemHovered()
            ImGui.SetCursorPos(startX, startY)
        end

        if scrollMaxX > 0 and ImGui.SetScrollX then
            local nextScrollX = scrollX

            ---@param mouseButton integer
            ---@return boolean
            local function applyDragPan(mouseButton)
                if not ImGui.IsMouseDragging or not ImGui.GetMouseDragDelta or not ImGui.ResetMouseDragDelta then
                    return false
                end

                local threshold = mouseButton == ImGuiMouseButton.Left and (style.draggingThreshold or 0) or 0
                local alreadyPanning = self.soundSystemGraphPanButton == mouseButton
                local canStart = (mouseButton == ImGuiMouseButton.Middle and overVisibleGraphContent)
                    or canvasHovered

                if not alreadyPanning and not canStart then
                    return false
                end
                if not ImGui.IsMouseDragging(mouseButton, threshold) then
                    return false
                end

                local dragX = ImGui.GetMouseDragDelta(mouseButton, threshold)
                if dragX ~= 0 then
                    nextScrollX = math.min(math.max(nextScrollX - dragX, 0), scrollMaxX)
                    ImGui.ResetMouseDragDelta(mouseButton)
                end

                self.soundSystemGraphPanButton = mouseButton
                return true
            end

            applyDragPan(ImGuiMouseButton.Middle)
            applyDragPan(ImGuiMouseButton.Left)

            if nextScrollX ~= scrollX then
                ImGui.SetScrollX(nextScrollX)
            end
        end

        if blankGraphHovered
            and ImGui.IsMouseReleased
            and ImGui.IsMouseReleased(ImGuiMouseButton.Right) then
            ImGui.OpenPopup(graphContextPopupId)
        end

        if ImGui.BeginPopup(graphContextPopupId) then
            drawGraphCreationMenu()
            ImGui.EndPopup()
        end

        if ImGui.BeginPopup(addSpeakerPopupId) then
            drawSpeakerDefinitionMenuItems()
            ImGui.EndPopup()
        end

        if ImGui.BeginPopup(addMasterPopupId) then
            drawMasterDefinitionMenuItems()
            ImGui.EndPopup()
        end

        ImGui.EndChild()
    end

    function device:drawSoundSystemSetupPopup()
        -- Taller than it was: the chain graph takes a fixed slice off the top, and the lists below
        -- it still have to show a couple of rows without scrolling.
        local defaultWidth = 660 * style.viewSize
        local defaultHeight = 700 * style.viewSize
        local minWidth = 600 * style.viewSize
        local minHeight = 560 * style.viewSize
        local screenWidth, screenHeight = GetDisplayResolution()
        local maxWidth = math.max(minWidth, screenWidth - 40 * style.viewSize)
        local maxHeight = math.max(minHeight, screenHeight - 40 * style.viewSize)

        ImGui.SetNextWindowSize(defaultWidth, defaultHeight, ImGuiCond.FirstUseEver)
        ImGui.SetNextWindowSizeConstraints(minWidth, minHeight, maxWidth, maxHeight)

        local popupIsOpen = ImGui.BeginPopupModal(quickSoundSystemSetupUI.POPUP_ID, true)
        if not popupIsOpen then
            self.soundSystemPopupWasOpen = false
            return
        end

        local settingsLabelX = utils.getTextMaxWidth({
            "Sound System Node Ref",
            "Device State",
            "Starting Entry"
        }) + 4 * ImGui.GetStyle().ItemSpacing.x

        local function applyNodeRef(newNodeRef)
            local normalizedNodeRef = sanitizeConnectionValue(newNodeRef)
            local currentNodeRef = sanitizeConnectionValue(self.nodeRef)
            if normalizedNodeRef == currentNodeRef then
                return
            end

            local masterEntries = currentNodeRef ~= ""
                and self.getSoundSystemMasters
                and self:getSoundSystemMasters()
                or {}

            local changes = { history.getElementChange(self.object) }
            for _, masterEntry in ipairs(masterEntries) do
                if masterEntry.masterElement then
                    table.insert(changes, history.getElementChange(masterEntry.masterElement))
                end
            end

            if #changes > 1 then
                history.addAction(history.getComposite(changes))
            else
                history.addAction(changes[1])
            end

            self.nodeRef = normalizedNodeRef
            for _, masterEntry in ipairs(masterEntries) do
                if masterEntry.connection then
                    masterEntry.connection.nodeRef = normalizedNodeRef
                end
            end

            registry.invalidate()
            if self.object.sUI and self.object.sUI.cachePaths then
                self.object.sUI.cachePaths()
            end
        end

        local canGenerateNodeRef = self.object ~= nil and self.object.parent ~= nil
        local popupJustOpened = not self.soundSystemPopupWasOpen
        self.soundSystemPopupWasOpen = true

        -- A sound system without a NodeRef cannot be connected to anything, and the .psrep entry is
        -- keyed on it, so it is generated up front rather than left as a step to remember.
        if popupJustOpened and canGenerateNodeRef and sanitizeConnectionValue(self.nodeRef) == "" then
            local generated = sanitizeConnectionValue(registry.generate(self.object))
            if generated ~= "" then
                applyNodeRef(generated)
            end
        end

        style.mutedText("Sound System Node Ref")
        ImGui.SameLine()
        ImGui.SetCursorPosX(settingsLabelX)
        local editedNodeRef, _, nodeRefFinished = style.trackedTextField(
            self.object,
            "##soundSystemNodeRef",
            sanitizeConnectionValue(self.nodeRef),
            "NodeRef...",
            getRowFieldWidth({ IconGlyphs.ReloadAlert })
        )
        if nodeRefFinished then
            applyNodeRef(editedNodeRef)
        end
        style.tooltip("Masters connect to this NodeRef, and the persistent state entry is keyed on it.")

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        ImGui.BeginDisabled(not canGenerateNodeRef)
        if ImGui.Button(IconGlyphs.ReloadAlert .. "##soundSystemNodeRefGenerate") and canGenerateNodeRef then
            applyNodeRef(registry.generate(self.object))
        end
        ImGui.EndDisabled()
        style.pushButtonNoBG(false)
        style.tooltip("Generate a unique NodeRef for this sound system.")

        if not self.persistent then
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " Persistent is off, so the entries below are not written to the .psrep file and the system starts from its shipped state.",
                style.warnColor
            )
            local canPersist = sanitizeConnectionValue(self.nodeRef) ~= ""
            ImGui.BeginDisabled(not canPersist)
            if ImGui.Button("Enable Persistent##soundSystemEnablePersistent") and canPersist then
                history.addAction(history.getElementChange(self.object))
                self.persistent = true
            end
            ImGui.EndDisabled()
            style.tooltip(canPersist and "Write this system's entries to the .psrep file." or "Requires a NodeRef.")
        end

        ImGui.Dummy(0, 4 * style.viewSize)

        local entries, componentID = self:getSoundSystemEntries()

        if not componentID then
            ImGui.TextWrapped("Sound system state is not available yet. Ensure the device is spawned and assembled.")
            ImGui.Separator()
            if ImGui.Button("Close##soundSystemSetupPopupClose") then
                ImGui.CloseCurrentPopup()
            end
            ImGui.EndPopup()
            return
        end

        style.mutedText("Device State")
        ImGui.SameLine()
        ImGui.SetCursorPosX(settingsLabelX)
        local currentState = tostring(self:getComponentPathValue(self, componentID, soundSystemData.DEVICE_STATE_PATH) or "ON")
        local stateIndex = math.max(0, utils.indexValue(soundSystemData.DEVICE_STATES, currentState) - 1)
        local newState, stateChanged = style.trackedCombo(
            self.object,
            "##soundSystemDeviceState",
            stateIndex,
            soundSystemData.DEVICE_STATES,
            120,
            { tooltip = "OFF leaves the system silent until something switches it on, usually a quest." }
        )
        if stateChanged then
            self:updateComponentPathValue(
                self,
                componentID,
                soundSystemData.DEVICE_STATE_PATH,
                soundSystemData.DEVICE_STATES[newState + 1] or "ON"
            )
        end

        style.mutedText("Starting Entry")
        ImGui.SameLine()
        ImGui.SetCursorPosX(settingsLabelX)

        if #entries == 0 then
            style.mutedText("Add an entry first")
        else
            local entryLabels = {}
            for index, entry in ipairs(entries) do
                table.insert(entryLabels, soundSystemData.getEntryLabel(entry, index, function (value)
                    return self:resolveLocKey(value)
                end))
            end

            local defaultAction = math.floor(tonumber(
                self:getComponentPathValue(self, componentID, soundSystemData.DEFAULT_ACTION_PATH)
            ) or 0)
            defaultAction = math.max(0, math.min(defaultAction, #entries - 1))

            local newDefaultAction, defaultActionChanged = style.trackedCombo(
                self.object,
                "##soundSystemDefaultAction",
                defaultAction,
                entryLabels,
                getRowFieldWidth({}, 260),
                { tooltip = "Entry the system plays on load. Stored as a zero-based index." }
            )
            if defaultActionChanged then
                self:updateComponentPathValue(self, componentID, soundSystemData.DEFAULT_ACTION_PATH, newDefaultAction)
            end
        end

        ImGui.Dummy(0, 8 * style.viewSize)

        local speakers = self:getSpeakerEntries()
        local masters = self:getSoundSystemMasters()
        self.soundSystemSelection = self.soundSystemSelection or { kind = "system" }

        -- Read once here and handed down, so each speaker row does not re-read the system state to
        -- work out whether its default station is ever heard.
        self.soundSystemChainContext = {
            isOn = currentState ~= "OFF",
            entryCount = #entries
        }

        -- Graph, then whatever it has selected --------------------------------------------------

        self:drawSoundSystemChainGraph(entries, speakers, masters)

        ImGui.Dummy(0, 6 * style.viewSize)

        local _, popupContentAvailY = ImGui.GetContentRegionAvail()
        local footerReserveHeight = ImGui.GetFrameHeightWithSpacing() + 14 * style.viewSize
        local panelHeight = math.max(0, popupContentAvailY - footerReserveHeight)

        self:drawSoundSystemSelectionPanel(panelHeight, entries, speakers, masters)

        ImGui.Separator()
        if ImGui.Button("Close##soundSystemSetupPopupClose") then
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end
end

return quickSoundSystemSetupUI
