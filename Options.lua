-- Mail-fufu: Options.lua
-- Settings category built with the modern Settings API (vertical layout + proxy settings).
-- Signatures checked against wow-ui-source Interface/AddOns/Blizzard_Settings_Shared/
-- (identical on branch live 12.1.5 and origin/forever 1.60.1):
--   Blizzard_Settings.lua
--     Settings.RegisterVerticalLayoutCategory(name)            -> category, layout
--     Settings.RegisterProxySetting(categoryTbl, variable, variableType, name,
--                                   defaultValue, getValue, setValue) -> setting
--     Settings.CreateCheckbox(category, setting, tooltip)       -> initializer
--     Settings.CreateSlider(category, setting, options, tooltip) -> initializer
--     Settings.CreateSliderOptions(minValue, maxValue, rate)    (rate = step size)
--     SettingsSliderOptionsMixin:SetLabelFormatter(labelType, value)
--     Settings.RegisterInitializer(category, initializer)       (-> layout:AddInitializer)
--     Settings.RegisterAddOnCategory(category)
--     Settings.OpenToCategory(categoryID, scrollToElementName)
--   Blizzard_SettingControls.lua
--     CreateSettingsButtonInitializer(name, buttonText, buttonClick, tooltip, addSearchTags, ...)
--       (addSearchTags must be non-nil: the function asserts it)
--     CreateSettingsListSectionHeaderInitializer(name, tooltip, newTagID)
--   Blizzard_Setting.lua
--     SettingMixin:NotifyUpdate()  re-reads the getter and refreshes the control
--   Blizzard_SharedXML/Shared/Slider/MinimalSlider.lua
--     MinimalSliderWithSteppersMixin.Label = { Left, Right, Top, Min, Max }
-- The legacy interface-options registration is gone on both clients and is never used.

local ADDON, ns = ...
local L = ns.L

local Options = {}
ns.Options = Options
ns.modules.Options = Options

local SECTION_ORDER = { "SEND", "INBOX", "CHAT", "HISTORY" }
local SECTION_LABEL = {
	SEND = L.OPT_HEADER_SEND,
	INBOX = L.OPT_HEADER_INBOX,
	CHAT = L.OPT_HEADER_CHAT,
	HISTORY = L.OPT_HEADER_HISTORY,
}

local category
local settingsByKey = {}
local inSetter = false

-- Proxy variable name per option: MAILFUFU_<KEY>.
local function VariableName(key)
	return "MAILFUFU_" .. strupper(key)
end

local function AddHeader(text)
	Settings.RegisterInitializer(category, CreateSettingsListSectionHeaderInitializer(text))
end

local function AddButton(label, buttonText, onClick, tooltip)
	-- addSearchTags = true: the label and button text are searchable in the Settings panel.
	local initializer = CreateSettingsButtonInitializer(label, buttonText, onClick, tooltip, true)
	Settings.RegisterInitializer(category, initializer)
end

local function AddOption(def)
	local key = def.key
	local function GetValue()
		return ns.GetOption(key)
	end
	local function SetValue(value)
		inSetter = true
		ns.SetOption(key, value)
		inSetter = false
	end

	local varType = (def.kind == "bool") and Settings.VarType.Boolean or Settings.VarType.Number
	local setting = Settings.RegisterProxySetting(category, VariableName(key), varType,
		L["OPT_" .. key], def.default, GetValue, SetValue)
	settingsByKey[key] = setting

	local tooltip = L["OPT_" .. key .. "_TIP"]
	if def.kind == "bool" then
		Settings.CreateCheckbox(category, setting, tooltip)
	else
		local sliderOptions = Settings.CreateSliderOptions(def.min, def.max, def.step)
		sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
		Settings.CreateSlider(category, setting, sliderOptions, tooltip)
	end
end

local function OnClearList()
	ns.Confirm(L.CLEAR_LIST_CONFIRM, function()
		ns.Addressees.Clear()
		ns.Print(L.CLEAR_LIST_DONE)
	end)
end

local function OnResetPosition()
	ns.History.ResetPosition()
end

local function Build()
	if category or not Settings or not Settings.RegisterVerticalLayoutCategory then return end
	category = Settings.RegisterVerticalLayoutCategory(L.ADDON_TITLE)

	for _, section in ipairs(SECTION_ORDER) do
		AddHeader(SECTION_LABEL[section])
		for _, def in ipairs(ns.OPTION_DEFS) do
			if def.section == section then
				AddOption(def)
			end
		end
		if section == "SEND" then
			AddButton(L.CLEAR_LIST_LABEL, L.CLEAR_LIST_BUTTON, OnClearList, L.CLEAR_LIST_TIP)
		elseif section == "HISTORY" then
			AddButton(L.RESET_POS_LABEL, L.RESET_POS_BUTTON, OnResetPosition, L.RESET_POS_TIP)
		end
	end

	Settings.RegisterAddOnCategory(category)
end

function Options.OnLogin()
	Build()
end

-- Keep the panel in sync when an option changes from outside the panel (slash command,
-- another module). Changes made by the panel itself are already shown.
function Options.OPTION_CHANGED(key)
	if inSetter then return end
	local setting = settingsByKey[key]
	if setting then
		setting:NotifyUpdate()
	end
end

-- Blizzard closes the Settings panel with ToggleGameMenu() (SettingsPanelMixin:
-- TransitionBackOpeningPanel, both branches), so a panel opened from the game world lands
-- on the game menu. When we opened it, hide that menu again: from a ToggleGameMenu post-hook
-- (same frame, so no flash), with a next-frame timer that also clears the flag when
-- Blizzard did not call ToggleGameMenu (Edit Mode).
-- shortcut: skipped in combat (the game menu stays up), revisit only if that annoys.
local openedByUs, hideHooked, hidePending = false, false, false

local function HideGameMenu()
	if not hidePending then return end
	hidePending = false
	if GameMenuFrame and GameMenuFrame:IsShown() and not InCombatLockdown() then
		HideUIPanel(GameMenuFrame)
	end
end

local function OnSettingsHide()
	if not openedByUs then return end
	openedByUs = false
	hidePending = true
	C_Timer.After(0, HideGameMenu)
end

function Options.Open()
	if not category then Build() end
	if category then
		if not hideHooked and SettingsPanel then
			hideHooked = true
			SettingsPanel:HookScript("OnHide", OnSettingsHide)
			hooksecurefunc("ToggleGameMenu", HideGameMenu)
		end
		openedByUs = hideHooked
		Settings.OpenToCategory(category:GetID())
	end
end
