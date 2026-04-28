local utils = require("modules/utils/utils")
local settings = require("modules/utils/settings")
local style = require("modules/ui/style")
local field = require("modules/utils/field")
local history = require("modules/utils/history")
local intersection = require("modules/utils/editor/intersection")
local editor = require("modules/utils/editor/editor")
local projectTagUtil = require("modules/utils/ui/projectTag")

local positionable = require("modules/classes/editor/positionable")

---Class for organizing multiple objects and or groups, with position and rotation
---@class positionableGroup : positionable
---@field origin Vector4
---@field rotation EulerAngles
---@field rotationQuat Quaternion
---@field rotationDragState table?
---@field rotationUIDragStart EulerAngles?
---@field rotationUIDragStartQuat Quaternion?
---@field rotationUIDragValue table
---@field originInitialized boolean
---@field originMode string
---@field supportsSaving boolean
---@field project table?
local positionableGroup = setmetatable({}, { __index = positionable })

local PROJECT_DEFAULT_ICON = "TagOutline"
local PROJECT_DEFAULT_COLOR = { 0.23, 0.35, 0.55 }
local PROJECT_NEUTRAL_KEY = "__no_project__"
local PROJECT_NEUTRAL_LABEL = "No Project"

local function bumpWireframeEpoch(instance)
	if instance and instance.sUI and instance.sUI.bumpWireframeEpoch then
		instance.sUI.bumpWireframeEpoch()
	end
end

---@param value string?
---@return string
local function trimText(value)
    if type(value) ~= "string" then
        return ""
    end

    return value:match("^%s*(.-)%s*$") or ""
end

---@param value number?
---@return number
local function clamp01(value)
    value = tonumber(value) or 0
    return math.max(0, math.min(value, 1))
end

---@param color table?
---@return number[]
local function normalizeProjectColor(color)
    local r = tonumber(color and (color[1] or color["1"] or color.r or color.x))
    local g = tonumber(color and (color[2] or color["2"] or color.g or color.y))
    local b = tonumber(color and (color[3] or color["3"] or color.b or color.z))

    if r == nil or g == nil or b == nil then
        return {
            PROJECT_DEFAULT_COLOR[1],
            PROJECT_DEFAULT_COLOR[2],
            PROJECT_DEFAULT_COLOR[3]
        }
    end

    if r > 1 or g > 1 or b > 1 then
        r = r / 255
        g = g / 255
        b = b / 255
    end

    return {
        clamp01(r),
        clamp01(g),
        clamp01(b)
    }
end

---@param project table?
---@return table?
local function normalizeProjectData(project)
    if type(project) ~= "table" then
        return nil
    end

    local name = trimText(project.name)
    if name == "" then
        return nil
    end

    local icon = type(project.icon) == "string" and IconGlyphs[project.icon] and project.icon or PROJECT_DEFAULT_ICON
    local color = normalizeProjectColor(project.color)

    return {
        name = name,
        icon = icon,
        color = { color[1], color[2], color[3] }
    }
end

---@param data table?
---@return boolean
local function isSerializedSavedGroup(data)
    return type(data) == "table" and (
        data.type == "group"
        or data.modulePath == "modules/classes/editor/positionableGroup"
        or data.modulePath == "modules/classes/editor/randomizedGroup"
    )
end

---@param instance positionableGroup
---@return table<string, table>, table[]
local function collectSavedProjectCatalog(instance)
    local projectMap = {}
    local projectOptions = {}
    local baseUI = instance and instance.sUI and instance.sUI.spawner and instance.sUI.spawner.baseUI
    local savedFiles = baseUI and baseUI.savedUI and baseUI.savedUI.files or nil
    if type(savedFiles) ~= "table" then
        return projectMap, projectOptions
    end

    for _, data in pairs(savedFiles) do
        if isSerializedSavedGroup(data) then
            local project = projectTagUtil.normalizeProject(data.project)
            if project then
                local key = projectTagUtil.normalizeNameKey(project.name)
                if key ~= "" and not projectMap[key] then
                    projectMap[key] = {
                        key = key,
                        project = project
                    }
                    table.insert(projectOptions, projectMap[key])
                end
            end
        end
    end

    table.sort(projectOptions, function(a, b)
        local nameA = a.project.name:lower()
        local nameB = b.project.name:lower()
        if nameA == nameB then
            return a.key < b.key
        end

        return nameA < nameB
    end)

    return projectMap, projectOptions
end

---@param a table?
---@param b table?
---@return boolean
local function areProjectsEqual(a, b)
    local first = projectTagUtil.normalizeProject(a)
    local second = projectTagUtil.normalizeProject(b)

    if first == nil or second == nil then
        return first == nil and second == nil
    end

    return first.name == second.name
        and first.icon == second.icon
        and first.color[1] == second.color[1]
        and first.color[2] == second.color[2]
        and first.color[3] == second.color[3]
end

---@param instance positionableGroup
---@param project table?
local function setProjectAssignment(instance, project)
    local normalized = projectTagUtil.normalizeProject(project)
    if areProjectsEqual(instance.project, normalized) then
        return
    end

    history.addAction(history.getElementChange(instance))

    if normalized then
        instance.project = {
            name = normalized.name,
            icon = normalized.icon,
            color = { normalized.color[1], normalized.color[2], normalized.color[3] }
        }
    else
        instance.project = nil
    end

    if instance.sUI and instance.sUI.invalidateCache then
        instance.sUI.invalidateCache(false)
    end
end

---@param instance positionableGroup
local function primeProjectCreateState(instance)
    local current = projectTagUtil.normalizeProject(instance.project)
    instance.projectCreateState = {
        name = "",
        icon = current and current.icon or projectTagUtil.DEFAULT_ICON,
        color = projectTagUtil.normalizeColor(current and current.color or nil)
    }
    instance.projectCreateIconSearch = instance.projectCreateIconSearch or ""
end

---@param instance positionableGroup
local function drawRootProjectTagSelector(instance)
    local projectMap, projectOptions = collectSavedProjectCatalog(instance)
    local currentProject = projectTagUtil.normalizeProject(instance.project)
    local currentKey = currentProject and projectTagUtil.normalizeNameKey(currentProject.name) or PROJECT_NEUTRAL_KEY
    local previewText = currentProject and currentProject.name or PROJECT_NEUTRAL_LABEL
    local previewIcon = IconGlyphs[(currentProject and currentProject.icon) or projectTagUtil.DEFAULT_ICON] or ""
    local comboSelectionApplied = false

    style.mutedText("Project Tag")
    ImGui.SameLine()
    ImGui.SetNextItemWidth(200 * style.viewSize)

    if ImGui.BeginCombo("##rootGroupProjectAssign" .. instance.id, previewIcon .. " " .. previewText) then
        local neutralSelected = currentKey == PROJECT_NEUTRAL_KEY
        if ImGui.Selectable((IconGlyphs[projectTagUtil.DEFAULT_ICON] or "") .. " " .. PROJECT_NEUTRAL_LABEL, neutralSelected)
            and currentKey ~= PROJECT_NEUTRAL_KEY then
            setProjectAssignment(instance, nil)
            comboSelectionApplied = true
            ImGui.CloseCurrentPopup()
        end

        if not comboSelectionApplied then
            for _, option in ipairs(projectOptions) do
                local selected = currentKey == option.key
                local icon = IconGlyphs[option.project.icon] or IconGlyphs[projectTagUtil.DEFAULT_ICON] or ""
                local label = string.format("%s %s##rootProjectOption%s%s", icon, option.project.name, option.key, instance.id)

                if ImGui.Selectable(label, selected) and currentKey ~= option.key then
                    setProjectAssignment(instance, option.project)
                    comboSelectionApplied = true
                    ImGui.CloseCurrentPopup()
                    break
                end
            end
        end

        if not comboSelectionApplied then
            ImGui.Separator()
            local plusIcon = IconGlyphs.Plus or "+"
            if ImGui.Selectable(string.format("%s Create new project tag...##rootProjectCreate%s", plusIcon, instance.id), false) then
                primeProjectCreateState(instance)
                instance.pendingProjectCreatePopupId = "##rootProjectCreatePopup" .. instance.id
            end
        end

        ImGui.EndCombo()
    end

    ImGui.SameLine()
    style.pushGreyedOut(currentProject == nil)
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Close .. "##rootProjectClear" .. instance.id) and currentProject ~= nil then
        setProjectAssignment(instance, nil)
    end
    style.pushButtonNoBG(false)
    style.popGreyedOut(currentProject == nil)
    style.tooltip("Remove project attribution")

    local popupId = "##rootProjectCreatePopup" .. instance.id
    if instance.pendingProjectCreatePopupId == popupId then
        ImGui.OpenPopup(popupId)
        instance.pendingProjectCreatePopupId = nil
    end

    if not instance.projectCreateState then
        primeProjectCreateState(instance)
    end

    local editorState = instance.projectCreateState
    if ImGui.BeginPopup(popupId) then
        style.mutedText("Create project tag for this group")
        ImGui.Separator()

        ImGui.SetNextItemWidth(220 * style.viewSize)
        editorState.name, _ = ImGui.InputTextWithHint("##rootProjectName" .. instance.id, "Project name...", editorState.name or "", 100)

        editorState.icon, instance.projectCreateIconSearch, _ = field.drawIconSelector("spawnedRootProject:" .. instance.id, editorState.icon, instance.projectCreateIconSearch)
        ImGui.SameLine()
        editorState.color, _ = style.trackedColor(nil, "##rootProjectColor" .. instance.id, editorState.color, 58)

        local normalizedName = projectTagUtil.normalizeNameKey(editorState.name)
        local existingProject = projectMap[normalizedName]
        if existingProject then
            style.mutedText("Existing project name detected. Assignment will reuse the existing shared project data.")
        end

        ImGui.Dummy(0, 8 * style.viewSize)
        local canAssign = projectTagUtil.trimText(editorState.name) ~= ""
        style.pushGreyedOut(not canAssign)
        if ImGui.Button("Assign##rootProjectAssign" .. instance.id) and canAssign then
            local targetProject = existingProject and existingProject.project or {
                name = editorState.name,
                icon = editorState.icon,
                color = editorState.color
            }

            setProjectAssignment(instance, targetProject)
            ImGui.CloseCurrentPopup()
        end
        style.popGreyedOut(not canAssign)

        ImGui.SameLine()
        if ImGui.Button("Cancel##rootProjectCancel" .. instance.id) then
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end
end

function positionableGroup:new(sUI)
	local o = positionable.new(self, sUI)

	o.name = "New Group"
	o.modulePath = "modules/classes/editor/positionableGroup"

	o.origin = nil
	o.rotation = nil
	o.rotationQuat = nil
	o.rotationDragState = nil
	o.rotationUIDragStart = nil
	o.rotationUIDragStartQuat = nil
	o.rotationUIDragValue = { roll = nil, pitch = nil }
	o.originInitialized = false
	o.originMode = "autoCenter"
	o.autoCenterCacheValid = false
	o.autoCenterCacheMin = nil
	o.autoCenterCacheMax = nil
	o.autoCenterCacheCenter = nil
	o.class = utils.combine(o.class, { "positionableGroup" })
	o.quickOperations = {
		[IconGlyphs.ContentSaveOutline] = {
			operation = positionableGroup.save,
			condition = function (instance)
				return instance.parent ~= nil and instance.parent:isRoot(true)
			end
		}
	}
	o.supportsSaving = true
	o.applyRotationWhenDropped = false
	o.project = nil

	setmetatable(o, { __index = self })
   	return o
end

function positionableGroup:load(data, silent)
	positionable.load(self, data, silent)

	-- Backward compatibility:
	-- Legacy data may only have `pos` (and often 0,0,0 for nested groups).
	-- Prefer explicit origin when present, otherwise fallback to legacy pos
	-- only when it is meaningful, or auto-center when it is zero.
	local legacyPos = data.pos
	local hasLegacyPos = legacyPos ~= nil
	local legacyPosIsZero = true
	if hasLegacyPos then
		local x = legacyPos.x or 0
		local y = legacyPos.y or 0
		local z = legacyPos.z or 0
		legacyPosIsZero = x == 0 and y == 0 and z == 0
	end

	if data.origin == nil then
		if hasLegacyPos and not legacyPosIsZero then
			data.origin = legacyPos
			data.originMode = data.originMode or "manual"
			if data.originInitialized == nil then
				data.originInitialized = true
			end
		else
			data.originMode = data.originMode or "autoCenter"
			data.origin = { x = 0, y = 0, z = 0 }
			if data.originInitialized == nil then
				data.originInitialized = false
			end
		end
	else
		data.originMode = data.originMode or "manual"
		if data.originInitialized == nil then
			data.originInitialized = true
		end
	end

	data.rotation = data.rotation or { roll = 0, pitch = 0, yaw = 0 }

	self.origin = Vector4.new(data.origin.x, data.origin.y, data.origin.z, 0)
	self.originMode = data.originMode
	self.originInitialized = data.originMode ~= "autoCenter" or data.originInitialized == true

	self.rotation = EulerAngles.new(data.rotation.roll, data.rotation.pitch, data.rotation.yaw)
	self.rotationQuat = self.rotation:ToQuat()
	self.project = normalizeProjectData(data.project)
	self:invalidateAutoCenterCache(false)
	bumpWireframeEpoch(self)
end

function positionableGroup:serialize()
	local data = positionable.serialize(self)

	self.origin = self.origin or self:getPosition()
	self.rotation = self.rotation or EulerAngles.new(0, 0, 0)
	self.rotationQuat = self.rotationQuat or self.rotation:ToQuat()
	self.originInitialized = self.originInitialized or (#self.childs > 0)
	self.originMode = self.originMode or "autoCenter"

	data.origin = { x = self.origin.x, y = self.origin.y, z = self.origin.z }
	data.originInitialized = self.originInitialized
	data.originMode = self.originMode
	data.rotation = { roll = self.rotation.roll, pitch = self.rotation.pitch, yaw = self.rotation.yaw }
	data.project = normalizeProjectData(self.project)

	return data
end

function positionableGroup:addChild(child, index)
	positionable.addChild(self, child, index)
end

---@param propagate boolean?
function positionableGroup:invalidateAutoCenterCache(propagate)
	self.autoCenterCacheValid = false
	self.autoCenterCacheMin = nil
	self.autoCenterCacheMax = nil
	self.autoCenterCacheCenter = nil

	if propagate and self.parent and utils.isA(self.parent, "positionableGroup") then
		self.parent:invalidateAutoCenterCache(true)
	end
end

---@param entry element
---@param min Vector4
---@param max Vector4
local function accumulateWorldMinMax(entry, min, max)
	if entry:isLocked() then
		return
	end

	if utils.isA(entry, "spawnableElement") then
		local entrySize = entry:getSize()
		local entryPos = entry:getCenter()

		if entrySize and entryPos then
			local halfSize = utils.multVector(entrySize, 0.5)
			local entryMin = utils.subVector(entryPos, halfSize)
			local entryMax = utils.addVector(entryPos, halfSize)

			min.x = math.min(min.x, entryMin.x)
			min.y = math.min(min.y, entryMin.y)
			min.z = math.min(min.z, entryMin.z)
			max.x = math.max(max.x, entryMax.x)
			max.y = math.max(max.y, entryMax.y)
			max.z = math.max(max.z, entryMax.z)
		end

		return
	end

	if utils.isA(entry, "positionableGroup") then
		for _, child in pairs(entry.childs) do
			accumulateWorldMinMax(child, min, max)
		end
	end
end

function positionableGroup:getDirection(direction)
    local groupQuat = self:getRotation():ToQuat()

    if direction == "forward" then
        return groupQuat:GetForward()
    elseif direction == "right" then
        return groupQuat:GetRight()
    elseif direction == "up" then
        return groupQuat:GetUp()
    else
		return groupQuat:GetForward()
    end
end

---Gets all the positionable leaf objects, i.e. positionable's without childs
---@return positionable[]
function positionableGroup:getPositionableLeafs()
	local objects = {}

	local function collectLeafs(entry)
		if entry:isLocked() then
			-- Locked entries are excluded from group-level transforms and batch operations.
		elseif utils.isA(entry, "spawnableElement") then
			table.insert(objects, entry)
		elseif utils.isA(entry, "positionableGroup") then
			for _, child in pairs(entry.childs) do
				collectLeafs(child)
			end
		end
	end

	for _, entry in pairs(self.childs) do
		collectLeafs(entry)
	end

	return objects
end

function positionableGroup:drawGeneralProperties()
	positionable.drawGeneralProperties(self)
	style.mutedText("Show Group Wireframe")
	ImGui.SameLine()
	settings.groupWireframeEnabled, _ = style.trackedCheckbox(self, "##showGroupWireframe", settings.groupWireframeEnabled)
	style.tooltip("Only visible in 3D-Editor mode, show boundaries and origin.")
end

function positionableGroup:getExtraGroupedProperties()
    if self.parent == nil or not self.parent:isRoot(true) then
        return {}
    end

    return {
        rootProjectTag = {
            id = "rootProjectTag",
            name = "Project Tag",
            draw = function ()
                drawRootProjectTagSelector(self)
            end
        }
    }
end

function positionableGroup:getWorldMinMax()
	if self.autoCenterCacheValid and self.autoCenterCacheMin and self.autoCenterCacheMax then
		return self.autoCenterCacheMin, self.autoCenterCacheMax
	end

	local min = Vector4.new(math.huge, math.huge, math.huge, 0)
	local max = Vector4.new(-math.huge, -math.huge, -math.huge, 0)

	local leafs = self:getPositionableLeafs()

	if #leafs == 0 then
		local pos = self:getPosition()
		return pos, pos
	end

	for _, entry in pairs(self.childs) do
		accumulateWorldMinMax(entry, min, max)
	end

	if min.x == math.huge then
		min = Vector4.new(0, 0, 0, 0)
		max = Vector4.new(0, 0, 0, 0)
	end

	self.autoCenterCacheMin = min
	self.autoCenterCacheMax = max
	self.autoCenterCacheCenter = utils.addVector(utils.multVector(utils.subVector(max, min), 0.5), min)
	self.autoCenterCacheValid = true

	return min, max
end

function positionableGroup:getCenter()
	if self.autoCenterCacheValid and self.autoCenterCacheCenter then
		return self.autoCenterCacheCenter
	end

	local min, max = self:getWorldMinMax()
	return self.autoCenterCacheCenter or utils.addVector(utils.multVector(utils.subVector(max, min), 0.5), min)
end

function positionableGroup:setOriginToCenter()
	self.originMode = "autoCenter"
	self:invalidateAutoCenterCache(false)
	if #self.childs == 0 then
		self.origin = Vector4.new(0, 0, 0, 1)
	else
		self.origin = self:getCenter()
	end
	self.originInitialized = true
	bumpWireframeEpoch(self)
end

function positionableGroup:setOrigin(v)
	self.origin = v
	self.originMode = "manual"
	self.originInitialized = true
	bumpWireframeEpoch(self)
end

function positionableGroup:getPosition()
	self.originMode = self.originMode or "autoCenter"

	if self.originMode == "autoCenter" then
		if #self.childs == 0 then
			return Vector4.new(0, 0, 0, 1)
		end
		return self:getCenter()
	end

	if self.origin == nil then
		if #self.childs == 0 then
			self.origin = Vector4.new(0, 0, 0, 1)
		else
			self.origin = self:getCenter()
		end
		self.originInitialized = true
	end
	return self.origin
end

function positionableGroup:setPosition(position)
	local delta = utils.subVector(position, self:getPosition())
	self:setPositionDelta(delta)
end

function positionableGroup:setPositionDelta(delta)
	if self.originMode ~= "autoCenter" then
		self.origin = utils.addVector(self:getPosition(), delta)
	end
	local leafs = self:getPositionableLeafs()

	for _, entry in pairs(leafs) do
		entry:setPositionDelta(delta)
	end
end

function positionableGroup:drawRotation(rotation)
	local locked = self.rotationLocked
	local shiftActive = (ImGui.IsKeyDown(ImGuiKey.LeftShift) or ImGui.IsKeyDown(ImGuiKey.RightShift)) and not ImGui.IsMouseDragging(0, 0)
	local finished = false
	local unstableZoneThreshold = 3.6
	local function drawLiveAngleFromStart(value, name, axis)
		local steps = settings.rotSteps
		local formatText = "%.2f"
		local shiftDown = ImGui.IsKeyDown(ImGuiKey.LeftShift) or ImGui.IsKeyDown(ImGuiKey.RightShift)
		local ctrlDown = ImGui.IsKeyDown(ImGuiKey.LeftCtrl) or ImGui.IsKeyDown(ImGuiKey.RightCtrl)

		if shiftDown then
			steps = steps * 0.1 * settings.precisionMultiplier
			formatText = "%.3f"
		elseif ctrlDown then
			steps = steps * settings.coarsePrecisionMultiplier
		end

		local displayValue = self.rotationUIDragValue[axis] or value
		local inUnstableZone = math.abs(displayValue) <= unstableZoneThreshold
		if inUnstableZone then
			ImGui.PushStyleColor(ImGuiCol.FrameBg, 1.0, 0.55, 0.0, 0.35)
			ImGui.PushStyleColor(ImGuiCol.FrameBgHovered, 1.0, 0.55, 0.0, 0.45)
			ImGui.PushStyleColor(ImGuiCol.FrameBgActive, 1.0, 0.55, 0.0, 0.55)
		end
		local newValue, changed = ImGui.DragFloat("##" .. name, displayValue, steps, -99999, 99999, formatText .. " " .. name, ImGuiSliderFlags.NoRoundToFormat)
		if inUnstableZone then
			ImGui.PopStyleColor(3)
		end
		self.controlsHovered = (ImGui.IsItemHovered() or ImGui.IsItemActive()) or self.controlsHovered

		if (ImGui.IsItemHovered() or ImGui.IsItemActive()) and axis ~= self.visualizerDirection then
			self:setVisualizerDirection(axis)
		end

		local finishedAxis = ImGui.IsItemDeactivatedAfterEdit()

		if changed and not history.propBeingEdited then
			history.addAction(history.getElementChange(self))
			history.propBeingEdited = true
		end

		if changed then
			if not self.rotationUIDragStart then
				self.rotationUIDragStart = EulerAngles.new(rotation.roll, rotation.pitch, rotation.yaw)
				self.rotationUIDragStartQuat = self.rotationQuat or self:getRotation():ToQuat()
				self.rotationUIDragValue.roll = rotation.roll
				self.rotationUIDragValue.pitch = rotation.pitch
				self:beginRotationDrag()
			end

			local start = self.rotationUIDragStart
			local startQuat = self.rotationUIDragStartQuat or start:ToQuat()
			local angleDelta = (axis == "roll" and (newValue - start.roll) or (newValue - start.pitch))
			local localAxis = axis == "roll" and Vector4.new(0, 1, 0, 0) or Vector4.new(1, 0, 0, 0)
			local worldAxis = startQuat:Transform(localAxis):Normalize()
			local stepQuat = Quaternion.SetAxisAngle(worldAxis, Deg2Rad(angleDelta))
			local targetQuat = Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](stepQuat, startQuat)

			self.rotationUIDragValue[axis] = newValue
			self:applyRotationDrag(stepQuat, targetQuat, targetQuat:ToEulerAngles())
		end

		if finishedAxis then
			self.rotationUIDragStart = nil
			self.rotationUIDragStartQuat = nil
			self.rotationUIDragValue.roll = nil
			self.rotationUIDragValue.pitch = nil
			self:endRotationDrag()
			history.propBeingEdited = false
			self:onEdited()
		end

		return finishedAxis
	end

	ImGui.PushItemWidth(80 * style.viewSize)
	style.popGreyedOut(not locked)
    finished = drawLiveAngleFromStart(rotation.roll, "Roll", "roll")
	self:handleRightAngleChange("roll", shiftActive and not finished)
    ImGui.SameLine()
    finished = drawLiveAngleFromStart(rotation.pitch, "Pitch", "pitch") or finished
	self:handleRightAngleChange("pitch", shiftActive and not finished)
    ImGui.SameLine()
	finished = self:drawProp(rotation.yaw, "Yaw", "yaw")
	self:handleRightAngleChange("yaw", shiftActive and not finished)
	ImGui.SameLine()
	style.pushButtonNoBG(true)
	if ImGui.Button(IconGlyphs.Numeric0BoxMultipleOutline) then
		history.addAction(history.getElementChange(self))
		self:setRotationIdentity()
	end
	style.pushButtonNoBG(false)
	style.tooltip("Set current group rotation as identity\nKeeps current rotation, but treats it as the new zero.")
	style.popGreyedOut(locked)
	ImGui.SameLine()
	style.mutedText(IconGlyphs.AlertOutline)
	style.tooltip("Experimental Roll/Pitch\nUnreliable between -3.60° and 3.60°\nUse with caution")
end

function positionableGroup:setRotationIdentity()
	self:setIdentity(EulerAngles.new(0, 0, 0))
end

---@param rotation EulerAngles|table
function positionableGroup:setIdentity(rotation)
	local roll = rotation and rotation.roll or 0
	local pitch = rotation and rotation.pitch or 0
	local yaw = rotation and rotation.yaw or 0

	self.rotationDragState = nil
	self.rotationUIDragStart = nil
	self.rotationUIDragStartQuat = nil
	self.rotationUIDragValue.roll = nil
	self.rotationUIDragValue.pitch = nil
	self.rotation = EulerAngles.new(roll, pitch, yaw)
	self.rotationQuat = self.rotation:ToQuat()
	bumpWireframeEpoch(self)
end

function positionableGroup:beginRotationDrag()
	local pos = self:getPosition()
	local leafs = self:getPositionableLeafs()
	local entries = {}

	for _, entry in pairs(leafs) do
		table.insert(entries, {
			entry = entry,
			startRelativePosition = utils.subVector(entry:getPosition(), pos),
			startRotationQuat = entry:getRotation():ToQuat()
		})
	end

	self.rotationDragState = {
		position = pos,
		entries = entries
	}
end

---@param stepQuat Quaternion
---@param targetQuat Quaternion
---@param targetEuler EulerAngles?
function positionableGroup:applyRotationDrag(stepQuat, targetQuat, targetEuler)
	if self.rotationLocked then return end
	if not self.rotationDragState then
		self:beginRotationDrag()
	end

	local state = self.rotationDragState
	self.rotationQuat = targetQuat
	self.rotation = targetEuler or targetQuat:ToEulerAngles()

	for _, data in pairs(state.entries) do
		local newRotation = Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](stepQuat, data.startRotationQuat):ToEulerAngles()
		data.entry:setRotation(newRotation)

		local newPosition = utils.addVector(state.position, stepQuat:Transform(data.startRelativePosition))
		data.entry:setPosition(newPosition)
	end
end

function positionableGroup:endRotationDrag()
	self.rotationDragState = nil
end

function positionableGroup:setRotation(rotation)
	if self.rotationLocked then return end

	self.rotationDragState = nil
	local pos = self:getPosition()
	local leafs = self:getPositionableLeafs()
	local currentQuat = self.rotationQuat or self:getRotation():ToQuat()
	local targetQuat = rotation:ToQuat()
	local deltaQuat = Quaternion.MulInverse(targetQuat, currentQuat)

	self.rotationQuat = targetQuat
	self.rotation = EulerAngles.new(rotation.roll, rotation.pitch, rotation.yaw)

	for _, entry in pairs(leafs) do
		local relativePosition = utils.subVector(entry:getPosition(), pos)
		local entryQuat = entry:getRotation():ToQuat()

		local newRotation = Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](deltaQuat, entryQuat):ToEulerAngles()
		entry:setRotation(newRotation)

		local newPosition = utils.addVector(pos, deltaQuat:Transform(relativePosition))
		entry:setPosition(newPosition)
	end
end

function positionableGroup:getRotation()
	if self.rotation == nil then
		self.rotation = EulerAngles.new(0, 0, 0)
	end
	if self.rotationQuat == nil then
		self.rotationQuat = self.rotation:ToQuat()
	end
	return self.rotation
end

function positionableGroup:setRotationDelta(delta)
	if self.rotationLocked then return end

	local pos = self:getPosition()
	local leafs = self:getPositionableLeafs()
	local workingQuat = self.rotationQuat or self:getRotation():ToQuat()
	local deltaQuat = EulerAngles.new(0, 0, 0):ToQuat()

	local function applyLocalAxisDelta(localAxis, angleDeg)
		if angleDeg == 0 then return end

		local worldAxis = workingQuat:Transform(localAxis):Normalize()
		local stepQuat = Quaternion.SetAxisAngle(worldAxis, Deg2Rad(angleDeg))

		deltaQuat = Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](stepQuat, deltaQuat)
		workingQuat = Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](stepQuat, workingQuat)
	end

	-- Keep mapping aligned with existing element behavior:
	-- roll -> local Y, pitch -> local X, yaw -> local Z.
	applyLocalAxisDelta(Vector4.new(0, 1, 0, 0), delta.roll)
	applyLocalAxisDelta(Vector4.new(1, 0, 0, 0), delta.pitch)
	applyLocalAxisDelta(Vector4.new(0, 0, 1, 0), delta.yaw)

	self.rotationQuat = workingQuat
	self.rotation = workingQuat:ToEulerAngles()

	for _, entry in pairs(leafs) do
		local relativePosition = utils.subVector(entry:getPosition(), pos)
		local entryQuat = entry:getRotation():ToQuat()

		local newRotation = Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](deltaQuat, entryQuat):ToEulerAngles()
		entry:setRotation(newRotation)

		local newPosition = utils.addVector(pos, deltaQuat:Transform(relativePosition))
		entry:setPosition(newPosition)
	end
end

function positionableGroup:onEdited()
	local leafs = self:getPositionableLeafs()

	for _, entry in pairs(leafs) do
		entry:onEdited()
	end
end

function positionableGroup:getSize()
	local min, max = self:getWorldMinMax()
	return utils.subVector(max, min)
end

function positionableGroup:dropToSurface(isMulti, direction, excludeDict)
	if isMulti then self:dropChildrenToSurface(isMulti, direction); return end

	local excludeDict = excludeDict or {}
	local leafs = self:getPositionableLeafs()
	for _, entry in pairs(leafs) do
		excludeDict[entry.id] = true
	end

	local size = self:getSize()
	local bBox = {
		min = Vector4.new(-size.x / 2, -size.y / 2, -size.z / 2, 0),
		max = Vector4.new(size.x / 2, size.y / 2, size.z / 2, 0)
	}

	local toOrigin = utils.multVector(direction, -999)
	local origin = intersection.getBoxIntersection(utils.subVector(self:getCenter(), toOrigin), utils.multVector(direction, -1), self:getCenter(), self:getRotation(), bBox --[[ -9 +9 ]])

	if not origin.hit then return end

	origin.position = utils.addVector(origin.position, utils.multVector(direction, 0.025))
	local hit = editor.getRaySceneIntersection(direction, origin.position, excludeDict, true)

	if not hit.hit then return end

	local target = utils.multVector(hit.result.normal, -1)
	local current = origin.normal

	local axis = current:Cross(target)
	local angle = Vector4.GetAngleBetween(current, target)
	local diff = Quaternion.SetAxisAngle(self:getRotation():ToQuat():TransformInverse(axis):Normalize(), math.rad(angle))

	if not isMulti then
		history.addAction(history.getElementChange(self))
	end

	local newRotation = Game['OperatorMultiply;QuaternionQuaternion;Quaternion'](self:getRotation():ToQuat(), diff)
	if self.applyRotationWhenDropped then
		self:setRotation(newRotation:ToEulerAngles())
	end

	local offset = utils.multVecXVec(newRotation:Transform(origin.normal), Vector4.new(size.x / 2, size.y / 2, size.z / 2, 0))
	local newCenter = utils.addVector(hit.result.unscaledHit or hit.result.position, utils.multVector(hit.result.normal, offset:Length())) -- phyiscal hits dont have unscaledHit

	if hit.hit then
		self:setPosition(utils.addVector(newCenter, utils.subVector(self:getPosition(), self:getCenter())))
		self:onEdited()
	end
end

function positionableGroup:dropChildrenToSurface(_, direction, excludeSelf, excludeDict)
	local leafs = self.childs
	table.sort(leafs, function (a, b)
		return a:getPosition().z < b:getPosition().z
	end)

	local excludeDict = excludeDict or {}
	if excludeSelf then
		for _, entry in pairs(leafs) do
			excludeDict[entry.id] = true
		end
	end

	local task = require("modules/utils/pipeline/tasks"):new()
	task.tasksTodo = #leafs
	task.taskDelay = 0.03

	for _, entry in pairs(leafs) do
		task:addTask(function ()
			entry:dropToSurface(true, direction, excludeDict)
			task:taskCompleted()
		end)
	end

	history.addAction(history.getElementChange(self))

	task:run(true)
end

return positionableGroup
