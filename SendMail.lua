-- Mail-fufu: SendMail.lua
-- Send Mail tab behaviour (design plan §1.1 S1, S4, S8, S9; §3.5):
--   * To-field prefill with this character's last addressee (S1)
--   * Send-click capture -> MAIL_SEND_SUCCESS -> remember addressee, dispatch MAIL_SENT
--   * the addressee dropdown button next to the To field (S4; menu lives in Addressees.lua)
--   * "Money: <amount>" auto-subject (S8)
--   * open all bags when the Send Mail tab is clicked (S9)
--
-- Hooking follows §3.9: hooksecurefunc / HookScript only, no Blizzard script or global is
-- replaced. Blizzard names used, checked against wow-ui-source (live 12.1.5 + origin/forever):
--   SendMailFrame_Reset()           Blizzard_MailFrame/MailFrame.lua, both branches; called by
--                                   MailFrame's MAIL_SEND_SUCCESS handler
--   MailFrameTab_OnClick(self, tabID)  both branches; tabID may be nil -> self:GetID()
--   SendMailFrame_SendMail()        both branches; the single function every send calls
--   SendMailMailButton              named on both (Forever adds mixin SendMailButtonMixin)
--   SendMailNameEditBox + SendMailNameEditBoxMiddle ($parentMiddle texture), both branches
--   SendMailSubjectEditBox, SendMailMoney (MoneyInputFrameTemplate: parentKeys gold/silver/
--       copper, Blizzard_MoneyFrame/Mainline/MoneyInputFrame.xml), MoneyInputFrame_GetCopper
--   OpenAllBags(frame)              Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua
--   GOLD/SILVER/COPPER_AMOUNT_SYMBOL, COPPER_PER_GOLD/SILVER  (used by FormattingUtil.lua /
--       MoneyInputFrame.lua)
--   Interface\ChatFrame\UI-ChatIcon-ScrollDown-Up / -Down / -Disabled and
--       Interface\Buttons\UI-Common-MouseHilight  (UIDropDownMenuTemplate's toggle button,
--       Blizzard_SharedXML/Mainline/UIDropDownMenuTemplates.xml lines 195-213, identical on
--       both branches; also Blizzard_StoreUI/Blizzard_Shared_StoreUITemplates.xml)
--   Button.HandlesGlobalMouseEvent(buttonName, event) is the hook Blizzard_Menu/Menu.lua
--       queries on the mouse focus before closing open menus on GLOBAL_MOUSE_DOWN.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat

local floor = math.floor

local SendMail = {}
ns.SendMail = SendMail
ns.RegisterModule("SendMail", SendMail)

local DROPDOWN_SIZE = 24
local DROPDOWN_NARROW = 18
-- Layout spec 2026-11-09 §2 B9: LEFT -> To box RIGHT (+5, +0) on retail-style mail frames
-- (+2 was the classic-frame value). Forever 1.60 ships the same SendMailNameEditBox geometry
-- as live (109x25 at TOPLEFT 90,-30; MailFrame.xml, both branches), so 0 on both clients.
local DROPDOWN_X, DROPDOWN_Y = 5, 0
-- Stock chat scroll-down arrow, the art Blizzard's own dropdown toggle uses (see header).
local DROPDOWN_ART = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-"
local DROPDOWN_HILIGHT = "Interface\\Buttons\\UI-Common-MouseHilight"

local active = false
local sending = false             -- our Send-click flag (S1: MAIL_SEND_SUCCESS also fires at odd times)
local justSentTo, justSentSubject
local justSentItems, justSentMoney, justSentCOD   -- attachments read at send-click for the history log
local subjectIsOurs = false       -- S8: subject was last written by the money auto-subject
local dropButton
local origBoxWidth, origMiddleWidth
local narrowed = false

-- ---------------------------------------------------------------------------
-- To field
-- ---------------------------------------------------------------------------

-- Put a name in the To field, select-all so typing replaces it. "" clears the field.
function SendMail.SetTo(name)
	local box = SendMailNameEditBox
	if not box then return end
	if not name or name == "" then
		box:SetText("")
		if box:IsVisible() then box:SetFocus() end
		return
	end
	box:SetText(name)
	box:SetCursorPosition(0)
	box:HighlightText()
end

local function HighlightTo()
	local box = SendMailNameEditBox
	if box and box:GetText() ~= "" then
		box:SetCursorPosition(0)
		box:HighlightText()
	end
end

local function PrefillLast()
	local last = ns.Addressees.GetLastTo()
	if last then SendMail.SetTo(last) end
end

-- ---------------------------------------------------------------------------
-- Money auto-subject (S8)
-- ---------------------------------------------------------------------------

-- "12g 5s 3c" with zero parts omitted (plain text: the subject cannot hold coin textures).
function SendMail.ShortMoney(copper)
	local gold = floor(copper / COPPER_PER_GOLD)
	local silver = floor((copper % COPPER_PER_GOLD) / COPPER_PER_SILVER)
	local rest = copper % COPPER_PER_SILVER
	local parts = {}
	if gold > 0 then tinsert(parts, gold .. GOLD_AMOUNT_SYMBOL) end
	if silver > 0 then tinsert(parts, silver .. SILVER_AMOUNT_SYMBOL) end
	if rest > 0 then tinsert(parts, rest .. COPPER_AMOUNT_SYMBOL) end
	return table.concat(parts, " ")
end

local function UpdateMoneySubject()
	local subjectBox = SendMailSubjectEditBox
	if not subjectBox or not SendMailMoney then return end
	if subjectBox:GetText() ~= "" and not subjectIsOurs then return end -- user's subject
	local ok, copper = pcall(MoneyInputFrame_GetCopper, SendMailMoney)
	copper = ok and tonumber(copper) or 0
	if copper > 0 then
		-- Programmatic SetText: OnTextChanged fires with userInput = false, flag survives.
		subjectBox:SetText(format(L.MONEY_SUBJECT, SendMail.ShortMoney(copper)))
		subjectIsOurs = true
	elseif subjectIsOurs then
		subjectBox:SetText("")
		subjectIsOurs = false
	end
end

local function OnSubjectChanged(self, userInput)
	if userInput then subjectIsOurs = false end
end

-- ---------------------------------------------------------------------------
-- Dropdown button (S4)
-- ---------------------------------------------------------------------------
local function ApplyDropdownVisibility()
	if not dropButton then return end
	local box, middle = SendMailNameEditBox, SendMailNameEditBoxMiddle
	if ns.GetOption("hideDropdown") then
		dropButton:Hide()
		if narrowed then
			box:SetWidth(origBoxWidth)
			if middle and origMiddleWidth then middle:SetWidth(origMiddleWidth) end
			narrowed = false
		end
	else
		if not narrowed then
			box:SetWidth(origBoxWidth - DROPDOWN_NARROW)
			if middle and origMiddleWidth then middle:SetWidth(origMiddleWidth - DROPDOWN_NARROW) end
			narrowed = true
		end
		dropButton:Show()
	end
end

local function DropdownOnClick(self)
	ns.Addressees.ToggleMenu(self, SendMail.SetTo)
end

local function DropdownOnEnter(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(L.DROPDOWN_TIP, 1, 1, 1, 1, true)
	GameTooltip:Show()
end

-- Keep Blizzard_Menu from closing our menu on the mouse-down that precedes our own toggle
-- click (same contract DropdownButtonMixin uses).
local function DropdownHandlesGlobalMouseEvent(self, buttonName, event)
	return event == "GLOBAL_MOUSE_DOWN" and buttonName == "LeftButton"
end

local function CreateDropdownButton()
	local box = SendMailNameEditBox
	local button = CreateFrame("Button", nil, box)
	button:SetSize(DROPDOWN_SIZE, DROPDOWN_SIZE)
	button:SetPoint("LEFT", box, "RIGHT", DROPDOWN_X, DROPDOWN_Y)
	button:SetNormalTexture(DROPDOWN_ART .. "Up")
	button:SetPushedTexture(DROPDOWN_ART .. "Down")
	button:SetDisabledTexture(DROPDOWN_ART .. "Disabled")
	button:SetHighlightTexture(DROPDOWN_HILIGHT, "ADD")
	button:SetScript("OnClick", DropdownOnClick)
	button:SetScript("OnEnter", DropdownOnEnter)
	button:SetScript("OnLeave", GameTooltip_Hide)
	button.HandlesGlobalMouseEvent = DropdownHandlesGlobalMouseEvent
	return button
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- Post-hook: Blizzard has just emptied the form (after a successful send). Prefill the
-- name that was just sent (captured at click time, so hook/event order does not matter).
local function OnSendFormReset()
	subjectIsOurs = false
	if sending and justSentTo and justSentTo ~= "" then
		SendMail.SetTo(justSentTo)
	else
		PrefillLast()
	end
end

local function OnSendFrameShow()
	local box = SendMailNameEditBox
	if box:GetText() == "" then
		PrefillLast()
	else
		HighlightTo()
	end
end

-- Attachments, money and C.O.D. of the mail being sent, read at send-click. The client
-- keeps the attachment slots and the money box filled until MAIL_SEND_SUCCESS runs
-- SendMailFrame_Reset, so reading them after SendMail() is safe.
--   HasSendMailItem(i) / GetSendMailItem(i) -> name, itemID, texture, count: MailFrame.lua
--     SendMailFrame_Update, both branches. GetSendMailItemLink(i) is a C API Blizzard's
--     own UI never calls, so it is type-checked and the name is the fallback.
--   Money vs C.O.D. follows SendMailMailButton_OnClick (both branches): the amount goes
--     to C.O.D. when the SendMailCODButton radio is checked, otherwise it is sent money.
local function CaptureAttachments()
	local items
	for i = 1, (ATTACHMENTS_MAX_SEND or 12) do
		if HasSendMailItem(i) then
			local name, itemID, texture, count = GetSendMailItem(i)
			local link
			if type(GetSendMailItemLink) == "function" then
				link = GetSendMailItemLink(i)
			end
			items = items or {}
			items[#items + 1] = { name = name, id = itemID, link = link, count = count or 1, icon = texture }
		end
	end
	local copper = 0
	if SendMailMoney then
		local ok, value = pcall(MoneyInputFrame_GetCopper, SendMailMoney)
		if ok and type(value) == "number" then copper = value end
	end
	local money, cod = 0, 0
	if copper > 0 then
		if SendMailCODButton and SendMailCODButton:GetChecked() then
			cod = copper
		else
			money = copper
		end
	end
	return items, money, cod
end

local function OnSendClick()
	sending = true
	justSentTo = ns.Addressees.NameCase(SendMailNameEditBox:GetText())
	justSentSubject = SendMailSubjectEditBox:GetText()
	-- Never let a logging failure surface as an error on Blizzard's send path.
	local ok, items, money, cod = pcall(CaptureAttachments)
	if ok then
		justSentItems, justSentMoney, justSentCOD = items, money, cod
	else
		justSentItems, justSentMoney, justSentCOD = nil, 0, 0
	end
end

local function OnTabClick(self, tabID)
	if not tabID and self and self.GetID then
		tabID = self:GetID()
	end
	if tabID == 2 then
		OpenAllBags(MailFrame)
	end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
function SendMail.OnLogin()
	if Compat.IsLimitedMode() then return end
	if not (MailFrame and SendMailFrame and SendMailNameEditBox and SendMailSubjectEditBox
		and SendMailMailButton and SendMailMoney) then
		return
	end
	active = true

	-- Original widths read at login, never hard-coded (both clients use 109 / 100 today).
	origBoxWidth = SendMailNameEditBox:GetWidth()
	origMiddleWidth = SendMailNameEditBoxMiddle and SendMailNameEditBoxMiddle:GetWidth() or nil

	dropButton = CreateDropdownButton()
	ApplyDropdownVisibility()

	if type(SendMailFrame_Reset) == "function" then
		hooksecurefunc("SendMailFrame_Reset", OnSendFormReset)
	else
		ns.PrintError(format(L.HOOK_TARGET_MISSING, L.HOOK_SEND_RESET), true)
	end
	-- Send capture. SendMailFrame_SendMail() is the global every send goes through on both
	-- branches (live SendMailMailButton_OnClick; Forever SendMailButtonMixin:OnClick, which
	-- the gamepad binding calls directly via GenerateClosure, bypassing OnClick script
	-- hooks). There is no confirmation-popup send path on either branch. The post-hook runs
	-- after SendMail() was issued; the To/subject fields still hold the sent values.
	if type(SendMailFrame_SendMail) == "function" then
		hooksecurefunc("SendMailFrame_SendMail", OnSendClick)
	else
		ns.PrintError(format(L.HOOK_TARGET_MISSING, L.HOOK_SEND_CAPTURE), true)
	end
	if type(MailFrameTab_OnClick) == "function" then
		hooksecurefunc("MailFrameTab_OnClick", OnTabClick)
	else
		ns.PrintError(format(L.HOOK_TARGET_MISSING, L.HOOK_TAB_CLICK), true)
	end

	SendMailFrame:HookScript("OnShow", OnSendFrameShow)
	SendMailFrame:HookScript("OnHide", ns.Addressees.CloseMenu)
	SendMailNameEditBox:HookScript("OnEscapePressed", ns.Addressees.CloseMenu)
	SendMailSubjectEditBox:HookScript("OnTextChanged", OnSubjectChanged)

	local money = SendMailMoney
	for _, key in ipairs({ "gold", "silver", "copper" }) do
		local editBox = money[key]
		if editBox then
			editBox:HookScript("OnTextChanged", UpdateMoneySubject)
		end
	end
end

function SendMail.OnMailShow()
	if not active then return end
	PrefillLast()
end

function SendMail.OnMailClosed()
	sending = false
	justSentTo, justSentSubject = nil, nil
	justSentItems, justSentMoney, justSentCOD = nil, nil, nil
end

function SendMail.MAIL_SEND_SUCCESS()
	if not active then return end
	if sending and justSentTo and justSentTo ~= "" then
		ns.Addressees.Remember(justSentTo)
		ns.Addressees.SetLastTo(justSentTo)
		ns.Dispatch("MAIL_SENT", justSentTo, justSentSubject, justSentItems, justSentMoney, justSentCOD)
	end
	sending = false
	justSentTo, justSentSubject = nil, nil
	justSentItems, justSentMoney, justSentCOD = nil, nil, nil
end

function SendMail.MAIL_FAILED()
	sending = false
end

function SendMail.OPTION_CHANGED(key)
	if not active then return end
	if key == "hideDropdown" then
		if ns.GetOption("hideDropdown") then ns.Addressees.CloseMenu() end
		ApplyDropdownVisibility()
	end
end
