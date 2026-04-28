local style = require("modules/ui/style")
local history = require("modules/utils/history")
local utils = require("modules/utils/utils")

local lcHelper = {}
local GROUPED_LIGHT_CHANNELS_ID = "lcGrouped"
local DEFAULT_LIGHT_CHANNEL_SELECTION = { true, true, true, true, true, true, true, true, true, false, false, false }

---Returns the grouped editor state bucket for light channels.
---@param element element Root/group element that owns `groupOperationData`.
---@return { selected: boolean[] }
local function getOrCreateGroupedLightChannelData(element)
    local groupedData = element.groupOperationData[GROUPED_LIGHT_CHANNELS_ID]

    if groupedData == nil then
        groupedData = {
            selected = utils.deepcopy(DEFAULT_LIGHT_CHANNEL_SELECTION)
        }
        element.groupOperationData[GROUPED_LIGHT_CHANNELS_ID] = groupedData
    end

    return groupedData
end

---Draw callback for the grouped light-channel editor.
---@param element element Root/group element currently rendering grouped properties.
---@param entries spawnableElement[] Selected entries to apply settings to.
local function drawGroupedLightChannels(element, entries)
    local groupedData = getOrCreateGroupedLightChannelData(element)
    groupedData.selected = style.drawLightChannelsSelector(nil, groupedData.selected)

    if ImGui.Button("Apply to selected") then
        history.addAction(history.getMultiSelectChange(entries))

        local nApplied = 0

        for _, entry in ipairs(entries) do
            if entry.spawnable.lightChannels ~= nil then
                entry.spawnable.lightChannels = utils.deepcopy(groupedData.selected)
                nApplied = nApplied + 1
            end
        end

        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Applied light channel settings to %s nodes", nApplied)))
    end

    style.tooltip("Apply the current light channels to all selected entries.")
end

---Builds the grouped-property descriptor consumed by the editor group-operations panel.
---The descriptor is reused by light, fog, reflection probe, and light-channel area spawnables.
---@param spawnable spawnable Spawnable instance requesting grouped light-channel operations.
---@return {name: string, id: string, data: {selected: boolean[]}, draw: fun(element: element, entries: spawnableElement[]), entries: table[]}
function lcHelper.getGroupedProperties(spawnable)
    return {
		name = "Light Channels",
        id = GROUPED_LIGHT_CHANNELS_ID,
		data = {
            selected = utils.deepcopy(DEFAULT_LIGHT_CHANNEL_SELECTION)
        },
		draw = drawGroupedLightChannels,
		entries = { spawnable }
	}
end

return lcHelper
