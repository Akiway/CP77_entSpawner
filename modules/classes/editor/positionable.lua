local utils = require("modules/utils/utils")
local gameUtils = require("modules/utils/gameUtils")
local settings = require("modules/utils/settings")
local history = require("modules/utils/history")
local style = require("modules/ui/style")
local field = require("modules/utils/field")
local editor = require("modules/utils/editor/editor")
local axl = require("modules/utils/axl")

local scatteredConfig = require("modules/classes/editor/scatteredConfig")

local element = require("modules/classes/editor/element")

---Element with position, rotation and optionally scale, handles the rendering / editing of those. Values have to be provided by the inheriting class
---@class positionable : element
---@field transformExpanded boolean
---@field rotationRelative boolean
---@field hasScale boolean
---@field scaleLocked boolean
---@field rotationLocked boolean
---@field relativeOffset table
---@field visualizerState boolean
---@field visualizerDirection string
---@field visualizerNewDirection string
---@field visualizerChanged boolean
---@field controlsHovered boolean
---@field randomizationSettings table
---@field scatterConfig scatteredConfig
---@field applyRotationWhenDropped boolean
local positionable = setmetatable({}, { __index = element })

local TRANSFORM_FAST_COLOR = 0xFF0099FF
local TRANSFORM_SLOW_COLOR = 0xFFB8B800
local TRANSFORM_PRECISION_COLOR = 0xFFFF66B3

---@return boolean
local function isCameraAttachedToPlayer()
    if editor.active then
        return false
    end

    local xUtilsMod = GetMod("XUtils")
    if xUtilsMod and xUtilsMod.CameraController and xUtilsMod.CameraController.isActive() then
        return false
    end

    local player = Game.GetPlayer()
    if not player then
        return true
    end

    local fpp = player:GetFPPCameraComponent()
    if not fpp or not fpp.IsActive then
        return true
    end

    local ok, active = pcall(function ()
        return fpp:IsActive()
    end)

    if ok and active ~= nil then
        return active == true
    end

    return true
end

---@return Vector4?
local function getPlayerOrDetachedCameraPosition()
    local player = Game.GetPlayer()
    if not player then
        return nil
    end

    if isCameraAttachedToPlayer() then
        return player:GetWorldPosition()
    end

    return editor.getCameraPosition() or player:GetWorldPosition()
end

---@param instance positionable
---@return positionable[]
local function getSelectedPositionables(instance)
	local selected = {}
	if not instance or not instance.sUI or not instance.sUI.root then
		return selected
	end

	for _, path in ipairs(instance.sUI.root:getPathsRecursive(true)) do
		if path.ref and path.ref.selected and utils.isA(path.ref, "positionable") then
			table.insert(selected, path.ref)
		end
	end

	return selected
end

---@return boolean
local function selectedVisualizersEnabled()
	return settings.selectedVisualizersEnabled ~= false
end

---@param instance positionable
---@param axis string
---@return boolean
local function isTransformAxisLocked(instance, axis)
	local spawnableRef = instance and instance.spawnable
	if not spawnableRef or not spawnableRef.isTransformAxisLocked then
		return false
	end

	return spawnableRef:isTransformAxisLocked(axis) == true
end

---@param axes table?
---@param axis string
---@return boolean
local function isAxisVisible(axes, axis)
    if type(axes) ~= "table" then
        return true
    end

    return axes[axis] ~= false
end

---@param instance positionable
---@return table
local function getTransformUIConfig(instance)
    local hasScale = instance and instance.hasScale == true
    local config = {
        showPosition = true,
        showRelative = true,
        showRotation = true,
        showScale = hasScale,
        axes = {
            position = { x = true, y = true, z = true },
            relative = { x = true, y = true, z = true },
            rotation = { roll = true, pitch = true, yaw = true },
            scale = { x = true, y = true, z = true }
        }
    }

    local spawnableRef = instance and instance.spawnable
    if not spawnableRef or not spawnableRef.getTransformUIConfig then
        return config
    end

    local override = spawnableRef:getTransformUIConfig()
    if type(override) ~= "table" then
        return config
    end

    if override.showPosition == false then config.showPosition = false end
    if override.showRelative == false then config.showRelative = false end
    if override.showRotation == false then config.showRotation = false end
    if override.showScale ~= nil then
        config.showScale = override.showScale == true and hasScale
    end

    if type(override.axes) == "table" then
        for section, sectionAxes in pairs(override.axes) do
            if type(config.axes[section]) == "table" and type(sectionAxes) == "table" then
                for axis, visible in pairs(sectionAxes) do
                    if config.axes[section][axis] ~= nil then
                        config.axes[section][axis] = visible ~= false
                    end
                end
            end
        end
    end

    return config
end

function positionable:new(sUI)
	local o = element.new(self, sUI)

	o.modulePath = "modules/classes/editor/positionable"

	o.transformExpanded = true
	o.rotationRelative = false
	o.hasScale = false
	o.scaleLocked = true
	o.rotationLocked = false
	o.relativeOffset = {
		x = 0,
		y = 0,
		z = 0
	}

	o.visualizerState = false
	o.visualizerDirection = "none"
	o.visualizerNewDirection = "none"
	o.visualizerChanged = false

	o.controlsHovered = false
	o.applyRotationWhenDropped = true

	o.randomizationSettings = {
		probability = 0.5
	}

	o.scatterConfig = scatteredConfig:new(o)

	o.class = utils.combine(o.class, { "positionable" })

	setmetatable(o, { __index = self })
   	return o
end

function positionable:load(data, silent)
	element.load(self, data, silent)
	self.transformExpanded = data.transformExpanded
	self.rotationRelative = data.rotationRelative
	self.scaleLocked = data.scaleLocked
	self.rotationLocked = data.rotationLocked
	if self.rotationLocked == nil then self.rotationLocked = false end

	for key, setting in pairs(data.randomizationSettings or {}) do
		self.randomizationSettings[key] = setting
	end

	self.scatterConfig:load(data.scatterConfig)

	if self.scaleLocked == nil then self.scaleLocked = true end
	if self.transformExpanded == nil then self.transformExpanded = true end
	if self.rotationRelative == nil then self.rotationRelative = false end

	self.applyRotationWhenDropped = data.applyRotationWhenDropped == nil and true or data.applyRotationWhenDropped
end

function positionable:drawTransform()
	local position = self:getPosition()
	local rotation = self:getRotation()
	local scale = self:getScale()
	local transformUI = getTransformUIConfig(self)
	self.controlsHovered = false
	self.visualizerChanged = false
	self.visualizerNewDirection = "none"

	if transformUI.showPosition then
		self:drawPosition(position, transformUI.axes.position)
	end
	if transformUI.showRelative then
		self:drawRelativePosition(transformUI.axes.relative)
	end
	if transformUI.showRotation then
		self:drawRotation(rotation, transformUI.axes.rotation)
	end
	if transformUI.showScale then
		self:drawScale(scale, transformUI.axes.scale)
	end

	if not self.controlsHovered and self.visualizerDirection ~= "none" then
		if not settings.gizmoOnSelected then
			self:setVisualizerState(false) -- Set vis state first, as loading the mesh app (vis direction) can screw with it
		end
		self:setVisualizerDirection("none")
		return
	end

	-- Only update once, to avoid "ghost arrows" from doing multiple LoadAppearance() calls in a single frame
	if self.visualizerChanged and self.visualizerNewDirection ~= self.visualizerDirection then
		self:setVisualizerDirection(self.visualizerNewDirection)
	end
end

---Draw the active Transform drag multiplier beside the property header.
function positionable:drawTransformModeIndicator()
	local altDown = ImGui.IsKeyDown(ImGuiKey.LeftAlt) or ImGui.IsKeyDown(ImGuiKey.RightAlt)
	local shiftDown = ImGui.IsKeyDown(ImGuiKey.LeftShift) or ImGui.IsKeyDown(ImGuiKey.RightShift)
	local ctrlDown = ImGui.IsKeyDown(ImGuiKey.LeftCtrl) or ImGui.IsKeyDown(ImGuiKey.RightCtrl)
	local label
	local color

	if altDown then
		label = "Precision mode"
		color = TRANSFORM_PRECISION_COLOR
	elseif shiftDown then
		label = "Slow mode"
		color = TRANSFORM_SLOW_COLOR
	elseif ctrlDown then
		label = "Fast mode"
		color = TRANSFORM_FAST_COLOR
	else
		return
	end

	ImGui.SameLine()
	style.styledText(label, color)
end

function positionable:getProperties()
	local properties = element.getProperties(self)

	table.insert(properties, {
		id = "transform",
		name = "Transform",
		defaultHeader = true,
		drawHeader = function ()
			self:drawTransformModeIndicator()
		end,
		draw = function ()
			self:drawTransform()
		end
	})

	table.insert(properties, {
		id = "general",
		name = "General",
		defaultHeader = false,
		draw = function ()
			self:drawGeneralProperties()
		end
	})

	if self.parent and utils.isA(self.parent, "randomizedGroup") then
		table.insert(properties, {
			id = "randomizationSelf",
			name = "Entry Randomization",
			defaultHeader = false,
			draw = function ()
				self:drawEntryRandomization()
			end
		})
	end

	if self.parent and self.parent.parent and utils.isA(self.parent.parent, "scatteredGroup") and self.parent.name == "Base" then
		table.insert(properties, {
			id = "scatteredShelf",
			name = "Entry Scattering",
			defaultHeader = false,
			draw = function ()
				self.scatterConfig:draw()
			end
		})
	end

	return properties
end

function positionable:getGroupedProperties()
	local properties = element.getGroupedProperties(self)

	if self.parent and self.parent.parent and utils.isA(self.parent.parent, "scatteredGroup") and self.parent.name == "Base" then
		properties["groupedScatteredProperties"] = {
			id = "groupedScatteredProperties",
			name = "Entry Scattering",
			draw = function (element, entries)
				self.scatterConfig:drawGrouped(element, entries)
			end
		}
	end

	return properties
end

function positionable:drawGeneralProperties()
	ImGui.PushItemWidth(80 * style.viewSize)
	style.mutedText("Apply Rotation When Dropped")
	ImGui.SameLine()
	self.applyRotationWhenDropped, _ = style.trackedCheckbox(self, "##applyRotationWhenDropped", self.applyRotationWhenDropped)

	style.mutedText("Quick Rotation Step")
	ImGui.SameLine()
	local changed
	settings.rotationShiftClickStep, changed = field.advancedTrackedFloat(nil, "##shiftClickRotationStep", settings.rotationShiftClickStep, {
		step = 0.5,
		shiftStep = 5,
		min = 0,
		max = 360,
		format = "%.2f",
		shiftFormat = "%.2f",
		width = 80
	})
	if changed then
		settings.save()
	end
	style.tooltip("Amount added/subtracted when Shift+Left/Right clicking Roll/Pitch/Yaw fields.")
end

function positionable:setSelected(state)
	local updated = state ~= self.selected
	local hasSelectionContext = self.sUI ~= nil and self.sUI.multiSelectActive ~= nil and self.sUI.rangeSelectActive ~= nil
	local isBatchSelection = hasSelectionContext and (self.sUI.multiSelectActive() or self.sUI.rangeSelectActive()) or false
	local allowSelectedVisualizers = selectedVisualizersEnabled()

	element.setSelected(self, state)

	if updated and not self.hovered and settings.gizmoOnSelected and allowSelectedVisualizers then
		if isBatchSelection and state then
			self:setVisualizerState(false)
		else
			self:setVisualizerState(state)
		end
	end

	if updated then
		if state and not allowSelectedVisualizers then
			self:setVisualizerState(false)
			self:setVisualizerDirection("none")
		end

		local selectedEntries = getSelectedPositionables(self)
		local selectedCount = #selectedEntries

		if isBatchSelection then
			if selectedCount > 1 then
				self:setVisualizerState(false)
			elseif not state and selectedCount == 1 and settings.gizmoOnSelected and allowSelectedVisualizers then
				for _, entry in ipairs(selectedEntries) do
					if entry ~= self then
						entry:setVisualizerState(true)
					end
				end
			end
			return
		end

		if state then
			if selectedCount > 1 then
				for _, entry in ipairs(selectedEntries) do
					if entry ~= self then
						entry:setVisualizerState(false)
					end
				end

				self:setVisualizerState(false)
			end
		elseif selectedCount == 1 and settings.gizmoOnSelected and allowSelectedVisualizers then
			for _, entry in ipairs(selectedEntries) do
				if entry ~= self then
					entry:setVisualizerState(true)
				end
			end
		end
	end
end

function positionable:setHovered(state)
	local allowSelectedVisualizers = selectedVisualizersEnabled()
	local updated = state ~= self.hovered
	element.setHovered(self, state)

	if updated and (not self.selected or (not settings.gizmoOnSelected and allowSelectedVisualizers)) then
		self:setVisualizerState(state)
		self:setVisualizerDirection("none")
	end
end

function positionable:setVisualizerDirection(direction)
	if not settings.gizmoOnSelected then
		local canAutoShow = not self.selected or selectedVisualizersEnabled()
		if direction ~= "none" and not self.hovered and not self.visualizerState and canAutoShow then
			self:setVisualizerState(true)
		end
	end
	self.visualizerDirection = direction
end

function positionable:setVisualizerState(state)
	if self.selected and not selectedVisualizersEnabled() then
		state = false
	end

	if state then
		local showOnHover = settings.gizmoOnHover and (self.hovered or self.controlsHovered)
		local showOnSelected = settings.gizmoOnSelected and self.selected and selectedVisualizersEnabled()
		if not showOnHover and not showOnSelected then
			state = false
		end
	end

	self.visualizerState = state
end

function positionable:onEdited() end

local POSITION_COLOR = 0xFFFFFF80 -- light Yellow
local ROTATION_COLOR = 0xFF80FFFF -- light Cyan
local SCALE_COLOR = 0xFFFF80FF -- light Fuchsia

---@param color number
---@param alpha number
---@return number
local function applyPackedColorAlpha(color, alpha)
    local packed = math.floor(tonumber(color) or style.regularColor)
    local a = math.floor(packed / 0x1000000) % 0x100
    local rgb = packed % 0x1000000
    local alphaClamped = math.max(0, math.min(1, tonumber(alpha) or 1))
    local nextAlpha = math.max(0, math.min(255, math.floor(a * alphaClamped + 0.5)))
    return nextAlpha * 0x1000000 + rgb
end

---@param idSuffix string
---@param segments {text: string, color: number?}[]
---@param enabled boolean?
---@return boolean
local function drawColoredPopupMenuItem(idSuffix, segments, enabled)
    local itemEnabled = enabled ~= false
    local selectableFlags = 0
    if ImGuiSelectableFlags then
        selectableFlags = ImGuiSelectableFlags.SpanAvailWidth or ImGuiSelectableFlags.None or 0
    end

    ImGui.BeginDisabled(not itemEnabled)
    ImGui.PushStyleColor(ImGuiCol.Text, 0, 0, 0, 0)
    local clicked = ImGui.Selectable(" ##coloredMenuItem" .. idSuffix, false, selectableFlags)
    ImGui.PopStyleColor()
    ImGui.EndDisabled()

    local drawList = ImGui.GetWindowDrawList()
    local fontSize = ImGui.GetFontSize()
    local minX, minY = ImGui.GetItemRectMin()
    local cursorX = minX + ImGui.GetStyle().FramePadding.x
    local cursorY = minY + ImGui.GetStyle().FramePadding.y
    local alpha = itemEnabled and 1 or (ImGui.GetStyle().DisabledAlpha or 0.6)

    for _, segment in ipairs(segments) do
        local segmentText = segment.text or ""
        local segmentColor = applyPackedColorAlpha(segment.color or style.regularColor, alpha)
        ImGui.ImDrawListAddText(drawList, fontSize, cursorX, cursorY, segmentColor, segmentText)
        local width, _ = ImGui.CalcTextSize(segmentText)
        cursorX = cursorX + width
    end

    if clicked then
        ImGui.CloseCurrentPopup()
    end

    return clicked
end

---@protected
---@param name string
---@param axis string?
function positionable:drawCopyPaste(name, axis)
    local popupId = string.format("##pasteProperty_%s_%s_%s", tostring(self.id or 0), tostring(axis or ""), tostring(name or ""))
	if not ImGui.IsKeyDown(ImGuiKey.LeftShift) and ImGui.BeginPopupContextItem(popupId, ImGuiPopupFlags.MouseButtonRight) then
        local frameCount = ImGui.GetFrameCount and ImGui.GetFrameCount() or nil
        if frameCount ~= nil then
            if self._drawCopyPasteFrame == frameCount and self._drawCopyPastePopupId == popupId then
                ImGui.EndPopup()
                return
            end
            self._drawCopyPasteFrame = frameCount
            self._drawCopyPastePopupId = popupId
        end

        local transformUI = getTransformUIConfig(self)
        local showPosition = transformUI.showPosition
        local showRotation = transformUI.showRotation
        local scaleAxes = transformUI.axes and transformUI.axes.scale or nil
        local showScaleInputs = transformUI.showScale
            and (isAxisVisible(scaleAxes, "x") or isAxisVisible(scaleAxes, "y") or isAxisVisible(scaleAxes, "z"))
        local renderedSection = false

        local function beginSection(hasItems)
            if not hasItems then
                return false
            end

            if renderedSection then
                ImGui.Separator()
            end

            renderedSection = true
            return true
        end

        local positionIconLabel = style.resolveActionLabelNoIconOnly(IconGlyphs.AxisArrow, "position", nil)
        local rotationIconLabel = style.resolveActionLabelNoIconOnly(IconGlyphs.RotateOrbit, "rotation", nil)
        local scaleIconLabel = style.resolveActionLabelNoIconOnly(IconGlyphs.RulerSquare, "scale", nil)

        if beginSection(showPosition or showRotation) then

            if showPosition and drawColoredPopupMenuItem(name .. "CopyPosition", {
                { text = "Copy " },
                { text = positionIconLabel, color = POSITION_COLOR }
            }) then
                local pos = self:getPosition()
                utils.insertClipboardValue("position", { x = pos.x, y = pos.y, z = pos.z })
            end
            if showRotation and drawColoredPopupMenuItem(name .. "CopyRotation", {
                { text = "Copy " },
                { text = rotationIconLabel, color = ROTATION_COLOR }
            }) then
                local rot = self:getRotation()
                utils.insertClipboardValue("rotation", { roll = rot.roll, pitch = rot.pitch, yaw = rot.yaw })
            end
            if showScaleInputs and drawColoredPopupMenuItem(name .. "CopyScale", {
                { text = "Copy " },
                { text = scaleIconLabel, color = SCALE_COLOR }
            }) then
                local scale = self:getScale()
                utils.insertClipboardValue("scale", { x = scale.x, y = scale.y, z = scale.z })
            end
            if showPosition and showRotation and drawColoredPopupMenuItem(name .. "CopyPositionRotation", {
                { text = "Copy " },
                { text = positionIconLabel, color = POSITION_COLOR },
                { text = " & " },
                { text = rotationIconLabel, color = ROTATION_COLOR }
            }) then
                local pos = self:getPosition()
                local rot = self:getRotation()
                utils.insertClipboardValue("position", { x = pos.x, y = pos.y, z = pos.z })
                utils.insertClipboardValue("rotation", { roll = rot.roll, pitch = rot.pitch, yaw = rot.yaw })
            end
            if showPosition and showRotation and showScaleInputs and drawColoredPopupMenuItem(name .. "CopyPositionRotationScale", {
                { text = "Copy " },
                { text = positionIconLabel, color = POSITION_COLOR },
                { text = ", " },
                { text = rotationIconLabel, color = ROTATION_COLOR },
                { text = " & " },
                { text = scaleIconLabel, color = SCALE_COLOR }
            }) then
                local pos = self:getPosition()
                local rot = self:getRotation()
                local scale = self:getScale()
                utils.insertClipboardValue("position", { x = pos.x, y = pos.y, z = pos.z })
                utils.insertClipboardValue("rotation", { roll = rot.roll, pitch = rot.pitch, yaw = rot.yaw })
                utils.insertClipboardValue("scale", { x = scale.x, y = scale.y, z = scale.z })
            end
        end

        if beginSection(showPosition or showRotation) then
            local copiedPosition = utils.getClipboardValue("position")
            local copiedRotation = utils.getClipboardValue("rotation")
            local copiedScale = utils.getClipboardValue("scale")

            if showPosition and drawColoredPopupMenuItem(name .. "PastePosition", {
                { text = "Paste " },
                { text = positionIconLabel, color = POSITION_COLOR }
            }, copiedPosition ~= nil) then
                history.addAction(history.getElementChange(self))
                self:setPosition(Vector4.new(copiedPosition.x, copiedPosition.y, copiedPosition.z, 0))
            end

            if showRotation and drawColoredPopupMenuItem(name .. "PasteRotation", {
                { text = "Paste " },
                { text = rotationIconLabel, color = ROTATION_COLOR }
            }, copiedRotation ~= nil) then
                history.addAction(history.getElementChange(self))
                self:setRotation(EulerAngles.new(copiedRotation.roll, copiedRotation.pitch, copiedRotation.yaw))
            end
            if showScaleInputs and drawColoredPopupMenuItem(name .. "PasteScale", {
                { text = "Paste " },
                { text = scaleIconLabel, color = SCALE_COLOR }
            }, copiedScale ~= nil) then
                history.addAction(history.getElementChange(self))
                self:setScale({ x = copiedScale.x, y = copiedScale.y, z = copiedScale.z }, true)
            end

            if showPosition and showRotation and drawColoredPopupMenuItem(name .. "PastePositionRotation", {
                { text = "Paste " },
                { text = positionIconLabel, color = POSITION_COLOR },
                { text = " & " },
                { text = rotationIconLabel, color = ROTATION_COLOR }
            }, copiedPosition ~= nil and copiedRotation ~= nil) then
                history.addAction(history.getElementChange(self))
                self:setPosition(Vector4.new(copiedPosition.x, copiedPosition.y, copiedPosition.z, 0))
                self:setRotation(EulerAngles.new(copiedRotation.roll, copiedRotation.pitch, copiedRotation.yaw))
            end

            if showPosition and showRotation and showScaleInputs and drawColoredPopupMenuItem(name .. "PastePositionRotationScale", {
                { text = "Paste " },
                { text = positionIconLabel, color = POSITION_COLOR },
                { text = ", " },
                { text = rotationIconLabel, color = ROTATION_COLOR },
                { text = " & " },
                { text = scaleIconLabel, color = SCALE_COLOR }
            }, copiedPosition ~= nil and copiedRotation ~= nil and copiedScale ~= nil) then
                history.addAction(history.getElementChange(self))
                self:setPosition(Vector4.new(copiedPosition.x, copiedPosition.y, copiedPosition.z, 0))
                self:setRotation(EulerAngles.new(copiedRotation.roll, copiedRotation.pitch, copiedRotation.yaw))
                self:setScale({ x = copiedScale.x, y = copiedScale.y, z = copiedScale.z }, true)
            end
        end

        if beginSection(showRotation) then
            if ImGui.MenuItem(string.format("%s Rotation", self.rotationLocked and "Unlock" or "Lock")) then
                history.addAction(history.getElementChange(self))
                self.rotationLocked = not self.rotationLocked
            end
            if ImGui.MenuItem(string.format("%s Rotation and Set Zero", self.rotationLocked and "Unlock" or "Lock")) then
                history.addAction(history.getElementChange(self))
                self:setRotation(EulerAngles.new(0, 0, 0))
                self.rotationLocked = not self.rotationLocked
            end
        end

        if beginSection(true) then
            if showRotation and ImGui.MenuItem("Copy rotation as Quaternion to clipboard") then
                local quat = self:getRotation():ToQuat()
                ImGui.SetClipboardText(string.format("i = %.6f, j = %.6f, k = %.6f, r = %.6f", quat.i, quat.j, quat.k, quat.r))
            end
            if ImGui.MenuItem("Copy Transform for AXL node mutation") then
                local position = self:getPosition()
                local orientation = self:getRotation():ToQuat()
                local scale = self:getScale()
                ImGui.SetClipboardText(axl.formatTransform(position, orientation, scale))
            end
        end
        ImGui.EndPopup()
    end
end

---@protected
function positionable:drawProp(prop, name, axis, disableInput)
	local steps = (axis == "roll" or axis == "pitch" or axis == "yaw") and settings.rotSteps or settings.posSteps

	local flags = ImGuiSliderFlags.NoRoundToFormat
	if disableInput then
		flags = flags + ImGuiSliderFlags.NoInput
	end

	local newValue, changed, finished = field.advancedTrackedFloat(nil, "##" .. axis, prop, {
		step = steps,
		min = -99999,
		max = 99999,
		format = "%.2f",
		shiftFormat = "%.3f",
		manualEditFormat = "%.3f",
		suffix = " " .. name,
		width = 80,
		flags = flags
	})
	self.controlsHovered = (ImGui.IsItemHovered() or ImGui.IsItemActive()) or self.controlsHovered
	if (ImGui.IsItemHovered() or ImGui.IsItemActive()) then
		-- Active item should have priority over hovered
		if not self.visualizerChanged or ImGui.IsItemActive() then
			self.visualizerNewDirection = axis
		end

		self.visualizerChanged = true
	end

	if finished then
		history.propBeingEdited = false
		self:onEdited()
	end
	if changed and not history.propBeingEdited then
		history.addAction(history.getElementChange(self))
		history.propBeingEdited = true
	end
    if changed or finished then
		if axis == "x" then
			self:setPositionDelta(Vector4.new(newValue - prop, 0, 0, 0))
		elseif axis == "y" then
			self:setPositionDelta(Vector4.new(0, newValue - prop, 0, 0))
		elseif axis == "z" then
			self:setPositionDelta(Vector4.new(0, 0, newValue - prop, 0))
		elseif axis == "relX" or axis == "relY" or axis == "relZ" then
			if axis == "relX" then
				local v = self:getDirection("right")
				self:setPositionDelta(Vector4.new((v.x * (newValue - self.relativeOffset.x)), (v.y * (newValue - self.relativeOffset.x)), (v.z * (newValue - self.relativeOffset.x)), 0))
				self.relativeOffset.x = newValue
			elseif axis == "relY" then
				v = self:getDirection("forward")
				self:setPositionDelta(Vector4.new((v.x * (newValue - self.relativeOffset.y)), (v.y * (newValue - self.relativeOffset.y)), (v.z * (newValue - self.relativeOffset.y)), 0))
				self.relativeOffset.y = newValue
			elseif axis == "relZ" then
				v = self:getDirection("up")
				self:setPositionDelta(Vector4.new((v.x * (newValue - self.relativeOffset.z)), (v.y * (newValue - self.relativeOffset.z)), (v.z * (newValue - self.relativeOffset.z)), 0))
				self.relativeOffset.z = newValue
			end

			if finished then
				self.relativeOffset = { x = 0, y = 0, z = 0 }
			end
		elseif axis == "roll" then
			self:setRotationDelta(EulerAngles.new(newValue - prop, 0, 0))
		elseif axis == "pitch" then
			self:setRotationDelta(EulerAngles.new(0, newValue - prop, 0))
		elseif axis == "yaw" then
			self:setRotationDelta(EulerAngles.new(0, 0, newValue - prop))
		elseif axis == "scaleX" then
			self:setScaleDelta({ x = newValue - prop, y = 0, z = 0 }, finished)
		elseif axis == "scaleY" then
			self:setScaleDelta({ x = 0, y = newValue - prop, z = 0 }, finished)
		elseif axis == "scaleZ" then
			self:setScaleDelta({ x = 0, y = 0, z = newValue - prop }, finished)
		end
    end

	self:drawCopyPaste(name, axis)

	return finished
end

---@protected
function positionable:drawPosition(position, axes)
    local showX = isAxisVisible(axes, "x")
    local showY = isAxisVisible(axes, "y")
    local showZ = isAxisVisible(axes, "z")

    if not showX and not showY and not showZ then
        return
    end

	style.drawIconLabelRow(IconGlyphs.AxisArrow, nil, {iconColor = POSITION_COLOR, fieldX = ImGui.CalcTextSize(IconGlyphs.AxisArrow) + ImGui.GetStyle().ItemSpacing.x})
	ImGui.SameLine()
	style.tooltip("Position")

	ImGui.PushItemWidth(80 * style.viewSize)
    local drewAxis = false

    if showX then
        self:drawProp(position.x, "X", "x")
        drewAxis = true
    end
    if showY then
        if drewAxis then
            ImGui.SameLine()
        end
        self:drawProp(position.y, "Y", "y")
        drewAxis = true
    end
    if showZ then
        if drewAxis then
            ImGui.SameLine()
        end
        ImGui.BeginDisabled(isTransformAxisLocked(self, "z"))
        self:drawProp(position.z, "Z", "z")
        ImGui.EndDisabled()
    end
    ImGui.PopItemWidth()

    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.AccountArrowLeftOutline) then
		history.addAction(history.getElementChange(self))
		local pos = getPlayerOrDetachedCameraPosition()

        if pos then
            self:setPositionDelta(Vector4.new(pos.x - position.x, pos.y - position.y, pos.z - position.z, 0))
        end
    end
	if ImGui.IsItemHovered() then style.setCursorRelative(5, 5) end
	style.tooltip("Set to player position, or camera position when detached.")

	ImGui.SameLine()
    local teleportDisabledByEditor = editor.active == true
	if style.warnButton(IconGlyphs.RunFast, {
        tooltip = "Teleport player to asset",
        disabled = teleportDisabledByEditor,
        disabledTooltip = "Teleportation disabled while in 3D-Editor mode",
        tooltipOffsetX = 5,
        tooltipOffsetY = 5
    }) then
		gameUtils.teleportPlayer(self:getPosition())
	end

    style.pushButtonNoBG(false)
end

---@protected
function positionable:drawRelativePosition(axes)
    local showX = isAxisVisible(axes, "x")
    local showY = isAxisVisible(axes, "y")
    local showZ = isAxisVisible(axes, "z")

    if not showX and not showY and not showZ then
        return
    end

	style.drawIconLabelRow(IconGlyphs.AxisArrowInfo, nil, {iconColor = POSITION_COLOR, fieldX = ImGui.CalcTextSize(IconGlyphs.AxisArrow) + ImGui.GetStyle().ItemSpacing.x})
	ImGui.SameLine()
	style.tooltip("Relative Position\nMove the object along its local axes, based on its current rotation.")

    ImGui.PushItemWidth(80 * style.viewSize)
	style.pushGreyedOut(not self.visible or self.hiddenByParent)
    local drewAxis = false

    if showX then
        self:drawProp(self.relativeOffset.x, "Rel X", "relX")
        drewAxis = true
    end
    if showY then
        if drewAxis then
            ImGui.SameLine()
        end
        self:drawProp(self.relativeOffset.y, "Rel Y", "relY")
        drewAxis = true
    end
    if showZ then
        if drewAxis then
            ImGui.SameLine()
        end
        ImGui.BeginDisabled(isTransformAxisLocked(self, "relZ"))
        self:drawProp(self.relativeOffset.z, "Rel Z", "relZ")
        ImGui.EndDisabled()
    end
	style.popGreyedOut(not self.visible or self.hiddenByParent)
    ImGui.PopItemWidth()
end

function positionable:handleRightAngleChange(axis, shiftActive)
	if not shiftActive or self.rotationLocked then return end
	local step = math.abs(tonumber(settings.rotationShiftClickStep) or 90)

	local function applyRightAngle(angle)
		history.addAction(history.getElementChange(self))
		self:setRotationDelta(EulerAngles.new(axis == "roll" and angle or 0, axis == "pitch" and angle or 0, axis == "yaw" and angle or 0))
		self:onEdited()
	end

	if ImGui.IsItemHovered() and ImGui.IsMouseReleased(ImGuiMouseButton.Left) and shiftActive then
		applyRightAngle(step)
	end
	if ImGui.IsItemHovered() and ImGui.IsMouseReleased(ImGuiMouseButton.Right) and shiftActive then
		applyRightAngle(-step)
	end
end

---@protected
function positionable:drawRotation(rotation, axes)
    local showRoll = isAxisVisible(axes, "roll")
    local showPitch = isAxisVisible(axes, "pitch")
    local showYaw = isAxisVisible(axes, "yaw")

    if not showRoll and not showPitch and not showYaw then
        return
    end

	style.drawIconLabelRow(IconGlyphs.RotateOrbit, nil, {iconColor = ROTATION_COLOR, fieldX = ImGui.CalcTextSize(IconGlyphs.RotateOrbit) + ImGui.GetStyle().ItemSpacing.x})
	ImGui.SameLine()
	style.tooltip("Rotation")

    ImGui.PushItemWidth(80 * style.viewSize)
	local locked = self.rotationLocked
	local shiftActive = (ImGui.IsKeyDown(ImGuiKey.LeftShift) or ImGui.IsKeyDown(ImGuiKey.RightShift)) and not ImGui.IsMouseDragging(0, 0)

	local finished = false
    local drewAxis = false
	style.pushGreyedOut(locked)
    if showRoll then
        finished = self:drawProp(rotation.roll, "Roll", "roll", shiftActive) or finished
        self:handleRightAngleChange("roll", shiftActive and not finished)
        drewAxis = true
    end
    if showPitch then
        if drewAxis then
            ImGui.SameLine()
        end
        finished = self:drawProp(rotation.pitch, "Pitch", "pitch", shiftActive) or finished
        self:handleRightAngleChange("pitch", shiftActive and not finished)
        drewAxis = true
    end
    if showYaw then
        if drewAxis then
            ImGui.SameLine()
        end
        finished = self:drawProp(rotation.yaw, "Yaw", "yaw", shiftActive) or finished
        self:handleRightAngleChange("yaw", shiftActive and not finished)
    end
	style.popGreyedOut(locked)
    if drewAxis then
        ImGui.SameLine()

        local nextRotationRelative, rotationRelativeChanged = style.toggleButton(IconGlyphs.HorizontalRotateClockwise, self.rotationRelative)
        if rotationRelativeChanged then
            history.addAction(history.getElementChange(self))
        end
        self.rotationRelative = nextRotationRelative
        style.tooltip("Toggle relative rotation")
    end
    ImGui.PopItemWidth()
end

function positionable:drawScale(scale, axes)
	if not self.hasScale then return end

    local showX = isAxisVisible(axes, "x")
    local showY = isAxisVisible(axes, "y")
    local showZ = isAxisVisible(axes, "z")

    if not showX and not showY and not showZ then
        return
    end

	style.drawIconLabelRow(IconGlyphs.RulerSquare, nil, {iconColor = SCALE_COLOR, fieldX = ImGui.CalcTextSize(IconGlyphs.RulerSquare) + ImGui.GetStyle().ItemSpacing.x})
	ImGui.SameLine()
	style.tooltip("Scale")

	ImGui.PushItemWidth(80 * style.viewSize)

    local drawnAxes = 0
    local function drawScaleAxis(value, name, axis)
        if drawnAxes > 0 then
            ImGui.SameLine()
        end
        self:drawProp(value, name, axis)
        drawnAxes = drawnAxes + 1
    end

    if showX then
        drawScaleAxis(scale.x, "X", "scaleX")
    end
    if showY then
        drawScaleAxis(scale.y, "Y", "scaleY")
    end
    if showZ then
        drawScaleAxis(scale.z, "Z", "scaleZ")
    end

    if drawnAxes >= 2 then
        ImGui.SameLine()
        local nextScaleLocked, scaleLockChanged = style.toggleButton(IconGlyphs.LinkVariant, self.scaleLocked)
        if scaleLockChanged then
            history.addAction(history.getElementChange(self))
        end
        self.scaleLocked = nextScaleLocked
        style.tooltip("Locks the scale axes together")
    end

	ImGui.PopItemWidth()
end

function positionable:drawEntryRandomization()
	style.mutedText("Spawning Probability")
	ImGui.SameLine()
	self.randomizationSettings.probability, _, finished = style.trackedDragFloat(self, "##probability", self.randomizationSettings.probability, 0.01, 0, 1, "%.2f")
	if finished then
		self.parent:applyRandomization(true)
	end
	style.tooltip("The base probability of this element being spawned, also depends on randomization mode of parent group.")
end

function positionable:setPosition(position)
end

function positionable:setPositionDelta(delta)
end

---@return Vector4
function positionable:getPosition()
	return Vector4.new(0, 0, 0, 0)
end

function positionable:setRotation(rotation)
end

function positionable:setRotationDelta(delta)
end

---@return EulerAngles
function positionable:getRotation()
	return EulerAngles.new(0, 0, 0)
end

function positionable:setScale(scale, finished)

end

function positionable:setScaleDelta(delta, finished)

end

function positionable:getSize()

end

function positionable:getCenter()

end

function positionable:getScale()
	return Vector4.new(1, 1, 1, 0)
end

---@param direction string
---@return Vector4?
function positionable:getDirection(direction)
	if direction == "right" then
		return Vector4.new(1, 0, 0, 0)
	elseif direction == "forward" then
		return Vector4.new(0, 1, 0, 0)
	elseif direction == "up" then
		return Vector4.new(0, 0, 1, 0)
	end
end

function positionable:dropToSurface(grouped, direction, excludeDict)

end

function positionable:serialize()
	local data = element.serialize(self)

	data.transformExpanded = self.transformExpanded
	data.rotationRelative = self.rotationRelative
	data.scaleLocked = self.scaleLocked
	data.rotationLocked = self.rotationLocked
	data.randomizationSettings = utils.deepcopy(self.randomizationSettings)
	data.pos = utils.fromVector(self:getPosition()) -- For savedUI
	data.scatterConfig = self.scatterConfig:serialize()
	data.applyRotationWhenDropped = self.applyRotationWhenDropped

	return data
end

return positionable
