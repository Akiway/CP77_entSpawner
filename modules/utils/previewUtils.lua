local preview = {
    elements = {}
}

function preview.addHUDText(key, size, x, y, color)
    color = color or "MainColors.Blue"

    local text = inkText.new()
    text:SetText("")
    text:SetFontSize(math.floor(size))
    text:SetAnchor(inkEAnchor.TopLeft)
    text:SetAnchorPoint(0.5, 0.5)
    text:SetVisible(false)
    text:SetFontFamily("base\\gameplay\\gui\\fonts\\orbitron\\orbitron.inkfontfamily")
    text:SetStyle("base\\gameplay\\gui\\common\\main_colors.inkstyle")
    text:BindProperty("tintColor", color)
    text:SetTranslation(x, y)
    text:SetFitToContent(false)
    text:SetHorizontalAlignment(textHorizontalAlignment.Left)
    text:Reparent(Game.GetInkSystem():GetLayer("inkHUDLayer"):GetVirtualWindow())

    preview.elements[key] = text
end

function preview.addLight(entity, intensity, ev, distance)
    local component = gameLightComponent.new()
    component.name = "light"
    component.intensity = intensity or 5
    component.turnOnByDefault = true
    component.innerAngle = 179
    component.outerAngle = 179
    component.radius = 5
    component.type = ELightType.LT_Spot
    component.useInParticles = false
    component.useInTransparents = false
    component.EV = ev or 0.75
    component:SetLocalOrientation(EulerAngles.new(0, 0, 180):ToQuat())
    component:SetLocalPosition(Vector4.new(0, distance or 1, 0, 0))
    entity:AddComponent(component)
end

function preview.addHUD()
    local _, height = GetDisplayResolution()
    local factor = height / 1440

    preview.addHUDText("previewFirstLine", 30 * factor, 730, 180)
    preview.addHUDText("previewSecondLine", 30 * factor, 730, 180 + 45 * factor)
    preview.addHUDText("previewThirdLine", 30 * factor, 730, 180 + 90 * factor, "MainColors.Red")
end

function preview.getBackplaneSize(size)
    return size / 10
end

function preview.getTopLeft(backplaneSize)
    return backplaneSize / 2
end

---Compute a normalized base preview size from intensity and configured bounds.
---@param intensity number
---@param multiplier number?
---@param options table?
---@return number size
function preview.getIntensityBaseSize(intensity, multiplier, options)
    options = options or {}
    local minIntensity = tonumber(options.minIntensity) or 50
    local maxIntensity = tonumber(options.maxIntensity) or 1000
    local minScale = tonumber(options.minScale) or 0.002
    local maxScale = tonumber(options.maxScale) or 0.04

    local range = math.max(maxIntensity - minIntensity, 1)
    local clampedIntensity = math.max(math.min(tonumber(intensity) or minIntensity, maxIntensity), minIntensity)
    local normalizedIntensity = (clampedIntensity - minIntensity) / range
    local baseSize = minScale + normalizedIntensity * (maxScale - minScale)

    return baseSize * (tonumber(multiplier) or 1)
end

---Compute cone visualizer scale for an angle-driven spotlight preview.
---@param angle number
---@param size number
---@param radiusFloorRatio number
---@return { x: number, y: number, z: number }
function preview.getSpotConeSize(angle, size, radiusFloorRatio)
    local baseSize = math.max(tonumber(size) or 0, 0)
    local clampedAngle = math.max(math.min(tonumber(angle) or 0, 170), 0.1)
    local floorRatio = math.max(tonumber(radiusFloorRatio) or 0, 0)
    local halfAngleRadians = math.rad(clampedAngle * 0.5)
    -- cone.mesh is centered and spans roughly 1.5 units across its main axis.
    local coneRadiusScale = baseSize * 1.5 * math.tan(halfAngleRadians)
    coneRadiusScale = math.max(math.min(coneRadiusScale, baseSize * 8), baseSize * floorRatio)

    return { x = coneRadiusScale, y = coneRadiusScale, z = baseSize }
end

---Compute triangular-prism spotlight preview scale from angle and thickness.
---@param angle number
---@param thicknessBase number
---@param length number
---@param thicknessFloorRatio number
---@return { x: number, y: number, z: number }
function preview.getSpotPrismSize(angle, thicknessBase, length, thicknessFloorRatio)
    local baseThickness = math.max(tonumber(thicknessBase) or 0, 0)
    local coneLikeSize = preview.getSpotConeSize(angle, baseThickness, thicknessFloorRatio)
    local prismThickness = coneLikeSize.x

    return { x = prismThickness, y = math.max(tonumber(length) or 0, 0), z = baseThickness }
end

return preview
