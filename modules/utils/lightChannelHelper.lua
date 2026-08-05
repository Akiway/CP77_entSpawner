local style = require("modules/ui/style")
local history = require("modules/utils/history")
local utils = require("modules/utils/utils")

local lcHelper = {}
local GROUPED_LIGHT_CHANNELS_ID = "lcGrouped"
local DEFAULT_LIGHT_CHANNEL_SELECTION = { true, true, true, true, true, true, true, true, true, false, false, false }

---Bit values of the `rendLightChannel` bitfield, keyed by the names in `style.lightChannelEnum`.
---`LC_Automated` sits at bit 15, so the mask can not be derived from the selection index alone.
local lightChannelBitValues = {
    LC_Channel1 = 1,
    LC_Channel2 = 2,
    LC_Channel3 = 4,
    LC_Channel4 = 8,
    LC_Channel5 = 16,
    LC_Channel6 = 32,
    LC_Channel7 = 64,
    LC_Channel8 = 128,
    LC_ChannelWorld = 256,
    LC_Character = 512,
    LC_Player = 1024,
    LC_Automated = 32768
}

---Builds the numeric `rendLightChannel` mask for a channel selection.
---@param selection boolean[] Channel states, in `style.lightChannelEnum` order.
---@return number mask
function lcHelper.getMask(selection)
    local mask = 0

    for index, name in ipairs(style.lightChannelEnum) do
        local bit = lightChannelBitValues[name]

        if bit and selection[index] then
            mask = mask + bit
        end
    end

    return mask
end

---Builds a value that can be assigned to a native `rendLightChannel` property.
---Prefers `BitField`, falls back to `Enum` on CET builds without it, and to the raw mask as a last resort.
---@param selection boolean[] Channel states, in `style.lightChannelEnum` order.
---@return any lightChannel
function lcHelper.getBitField(selection)
    local mask = lcHelper.getMask(selection)

    local ok, value = pcall(function ()
        return BitField.new("rendLightChannel", mask)
    end)
    if ok and value ~= nil then
        return value
    end

    ok, value = pcall(function ()
        return Enum.new("rendLightChannel", mask)
    end)
    if ok and value ~= nil then
        return value
    end

    return mask
end

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
