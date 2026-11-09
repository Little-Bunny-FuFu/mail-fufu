-- Mail-fufu: OpenMail.lua
-- Open-mail panel features (design plan §1.3 O1-O3, §3.7) plus the inbox-row tooltip
-- mail text (§1.2 I6):
--   O1  "Take All" button: one-mail run of the take engine (TakeEngine.lua).
--   O2  "Forward" button: copies subject and body into the Send tab.
--   O3  money chat line when the player clicks Blizzard's money attachment by hand.
--   I6  mail body appended to the inbox-row tooltip (ns.Inbox.OnItemTooltip).
--
-- Every Blizzard name used here exists on both client shapes (wow-ui-source
-- Blizzard_MailFrame/MailFrame.lua|xml, branch live = 12.1.5 and origin/forever = 1.60.1):
--   OpenMailFrame, OpenMailHorizontalBarLeft, OpenMailReplyButton, OpenMailMoneyButton,
--   OpenMailSubject, InboxFrame.openMailID, OpenMailFrame.money / .cod (set at the end of
--   OpenMail_Update / OpenMailMixin:Update), SendMailNameEditBox, SendMailSubjectEditBox,
--   SendMailBodyEditBox, MailFrameTab_OnClick (global on both), and for the Take All
--   room-making OpenMailScrollFrame, OpenMailScrollChildFrame, OpenStationeryBackgroundLeft,
--   OpenStationeryBackgroundRight, OpenMailAttachmentText (MailFrame.xml, both branches).
-- Hooks: only Compat.HookOpenMailUpdate (dual shape) and HookScript (§3.9).

local ADDON, ns = ...
local L = ns.L

local Engine = ns.TakeEngine

local OpenMail = {}
ns.OpenMail = OpenMail

local takeAllButton
local forwardButton

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Index of the mail shown in the open-mail panel, or nil. Blizzard sets
-- InboxFrame.openMailID to 0 or nil when no mail is open (InboxFrame_OnClick /
-- OpenMail_Delete, both branches).
local function OpenMailIndex()
	if not OpenMailFrame or not OpenMailFrame:IsShown() or not InboxFrame then
		return nil
	end
	local index = InboxFrame.openMailID
	if type(index) ~= "number" or index < 1 or index > GetInboxNumItems() then
		return nil
	end
	return index
end

local function HasAnyItem(index)
	for a = 1, ATTACHMENTS_MAX or 16 do
		if HasInboxItem(index, a) then
			return true
		end
	end
	return false
end

-- Take All is wanted when the open mail still has money or an item attachment.
-- OpenMailFrame.money is nil when the mail has no money left (OpenMail_Update:
-- "if money == 0 then ... OpenMailFrame.money = nil"). The letter (text item) is never
-- counted: HasInboxItem only reports real attachments.
local function WantsTakeAll(index)
	return (OpenMailFrame.money or HasAnyItem(index)) and true or false
end

local function ShowButtonTooltip(button, text)
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	GameTooltip_AddNormalLine(GameTooltip, text, true)
	GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- O1 Take All / O2 Forward visibility
-- ---------------------------------------------------------------------------

function OpenMail.Refresh()
	if not takeAllButton then return end
	local index = OpenMailIndex()
	if not index then
		takeAllButton:Hide()
		forwardButton:Hide()
		return
	end

	if WantsTakeAll(index) then
		takeAllButton:Show()
		-- OpenMailFrame.cod is set from CODAmount on every update and becomes nil once the
		-- player has accepted the COD on one item, which enables the button.
		takeAllButton:SetEnabled(not Engine.IsRunning() and not OpenMailFrame.cod)
	else
		takeAllButton:Hide()
	end

	-- Forward follows Reply: hidden with the gamepad UI on Forever
	-- (OpenMailMixin:InitializeGamepad hides ReplyButton) and for limited accounts
	-- (no Send tab).
	forwardButton:SetShown(OpenMailReplyButton:IsShown() and not ns.Compat.IsLimitedMode())
end

local function TakeAll_OnClick()
	local index = OpenMailIndex()
	if not index then return end
	-- The engine freezes the open-mail layout itself (OpenMailFrame.updateButtonPositions =
	-- false in TakeEngine.lua FreezeOpenMailLayout) before its first take; not repeated here.
	Engine.Start({ mails = { index }, source = "takeall" })
	OpenMail.Refresh()
end

-- ---------------------------------------------------------------------------
-- O1 room-making for Take All (layout spec §5)
-- ---------------------------------------------------------------------------
-- Blizzard's open-mail update (live OpenMail_Update / Forever OpenMailMixin:Update; the
-- "Resize the scroll frame" block is identical on both branches) sets, on EVERY run:
--   OpenMailScrollFrame / OpenMailScrollChildFrame height = scrollHeight (min(256, 305 - areay))
--   OpenMailHorizontalBarLeft TOPLEFT -> OpenMailFrame BOTTOMLEFT (2, 39 + areay)
--   OpenStationeryBackgroundLeft / Right height = scrollHeight, texcoord bottom = scrollHeight / 256
--   OpenMailAttachmentText TOPLEFT -> OpenMailFrame BOTTOMLEFT (computed)
-- With Take All shown we take 8 px off the letter area, lift the bar with it and tuck the
-- "Take attachments:" caption 2 px under the bar, so the 22 px button (anchored to the
-- bar) clears the first attachment row. (OpenScrollBarBackgroundTop from the spec exists
-- on neither branch, so there is nothing to clamp.)
--
-- Taint rationale (design plan §3.9): these are SetHeight / SetPoint / SetTexCoord layout
-- writes on Blizzard regions, the same kind of call Inbox.lua makes to shift and narrow
-- the MailItem rows. No Blizzard table field is written, no script or function replaced,
-- none of these frames is protected, and Blizzard rewrites every one of them on its next
-- update.
--
-- Idempotent: each pass starts from the values Blizzard has just written (read once, then
-- one fixed delta). Blizzard's update can return early (invalid mail id) without
-- re-laying out, so the bar's anchor is the sentinel: Blizzard always leaves it relative
-- to OpenMailFrame BOTTOMLEFT, ours is relative to TOPLEFT. Anything else = already
-- applied, skip; the delta never accumulates.
local TAKEALL_ROOM = 8          -- px taken from the letter scroll area (spec §5)
local BAR_BELOW_SCROLL = 80     -- bar top = 84 (scroll frame top) + height - 4 (spec §5)
local CAPTION_X, CAPTION_Y = 12, -2

local function MakeTakeAllRoom()
	if not (takeAllButton and OpenMailScrollFrame and OpenMailScrollChildFrame
		and OpenStationeryBackgroundLeft and OpenStationeryBackgroundRight and OpenMailAttachmentText) then
		return
	end
	local index = InboxFrame and InboxFrame.openMailID
	-- Not OpenMailIndex(): Blizzard runs the update BEFORE ShowUIPanel(OpenMailFrame).
	if type(index) ~= "number" or index < 1 or index > GetInboxNumItems() then return end
	if not WantsTakeAll(index) then return end

	local _, relativeTo, relativePoint = OpenMailHorizontalBarLeft:GetPoint(1)
	if relativeTo ~= OpenMailFrame or relativePoint ~= "BOTTOMLEFT" then return end

	local height = OpenMailScrollFrame:GetHeight() - TAKEALL_ROOM
	if height < 1 then return end
	local coordBottom = math.min(height, 256) / 256

	OpenMailScrollFrame:SetHeight(height)
	OpenMailScrollChildFrame:SetHeight(height)
	OpenMailHorizontalBarLeft:SetPoint("TOPLEFT", OpenMailFrame, "TOPLEFT", 2, -(height + BAR_BELOW_SCROLL))
	OpenStationeryBackgroundLeft:SetHeight(height)
	OpenStationeryBackgroundLeft:SetTexCoord(0, 1, 0, coordBottom)
	OpenStationeryBackgroundRight:SetHeight(height)
	OpenStationeryBackgroundRight:SetTexCoord(0, 1, 0, coordBottom)
	-- Take All shown implies at least one attachment button, i.e. Blizzard's "with
	-- attachments" caption branch; the spec's no-attachment centring never applies here.
	OpenMailAttachmentText:SetPoint("TOPLEFT", OpenMailHorizontalBarLeft, "BOTTOMLEFT", CAPTION_X, CAPTION_Y)
end

local function OnOpenMailUpdate()
	MakeTakeAllRoom()
	OpenMail.Refresh()
end

-- ---------------------------------------------------------------------------
-- O2 Forward
-- ---------------------------------------------------------------------------

local function Forward_OnClick()
	local index = OpenMailIndex()
	if not index then return end

	local _, _, _, subject = GetInboxHeaderInfo(index)
	subject = subject or OpenMailSubject:GetText() or ""
	-- Already read by Blizzard when the mail was opened, so no extra read side effect.
	local body = GetInboxText(index)

	-- Same tab switch Blizzard's own Reply makes (OpenMail_Reply live line 850 /
	-- OpenMailReplyMixin:Reply forever line 1092: MailFrameTab_OnClick(nil, 2)). It sets
	-- SendMailFrame.sendMode = "send", so the mode write below must come after it.
	MailFrameTab_OnClick(nil, 2)

	SendMailNameEditBox:SetText("")

	local prefix = L.FORWARD_PREFIX .. " "
	if strlower(subject:sub(1, #prefix)) ~= strlower(prefix) then
		subject = prefix .. subject
	end
	SendMailSubjectEditBox:SetText(subject)   -- the edit box caps it at 64 letters

	if body and body:find("%S") then
		SendMailBodyEditBox:SetText("\n---\n" .. body)   -- capped at 500 letters by the box
	else
		SendMailBodyEditBox:SetText("")
	end
	SendMailBodyEditBox:SetFocus()
	SendMailBodyEditBox:SetCursorPosition(0)

	-- Taint rationale (design plan §3.9 rule 4): SendMailFrame_SendMail (live line 949,
	-- forever line 1276, identical) does
	--   local replyMailID = SendMailFrame.sendMode == "reply" and SendMailFrame.replyMailID or nil
	--   SendMail(name, subject, body, replyMailID)
	-- and the MAIL_SEND_SUCCESS handler returns to the inbox tab when sendMode == "reply".
	-- Blizzard's Reply writes this exact pair from an insecure click handler; neither field
	-- reaches a protected function (SendMail is not protected), and the next
	-- MailFrameTab_OnClick rewrites sendMode from secure code. replyMailID = nil keeps a
	-- stale id from an earlier Reply from being sent with the forward (SendMailFrame_Reset
	-- never clears it on either branch).
	SendMailFrame.sendMode = "reply" -- luacheck: ignore 122
	SendMailFrame.replyMailID = nil  -- luacheck: ignore 122
end

-- ---------------------------------------------------------------------------
-- I6 tooltip mail text (called from Inbox.lua's InboxFrameItem_OnEnter post-hook)
-- ---------------------------------------------------------------------------

-- Blizzard re-runs InboxFrameItem_OnEnter from the row's OnUpdate every frame while the
-- tooltip is owned (MailFrame.xml, both branches), and SetOwner clears the tooltip each
-- time, so this rebuilds the same lines each frame. Keep it to one C call and a scan.
local function OnItemTooltip(button)
	if not ns.GetOption("tooltipText") then return end
	local index = button and button.index
	if not index or not GameTooltip:IsOwned(button) then return end

	-- GetInboxText marks the mail read (warned in the option tooltip) and may return an
	-- empty body until the next MAIL_INBOX_UPDATE; the per-frame refresh picks it up.
	local body = GetInboxText(index)
	if button.hasItem or button.money or button.cod then
		GameTooltip:AddLine(" ")
	end
	GameTooltip_AddNormalLine(GameTooltip, L.MAIL_TEXT_HEADER)
	if body and body:find("%S") then
		GameTooltip:AddLine(body, 0.85, 0.85, 0.85, true)
	else
		GameTooltip:AddLine(L.NO_TEXT, 0.85, 0.85, 0.85)
	end
	GameTooltip:Show()
end

if ns.Inbox then
	ns.Inbox.OnItemTooltip = OnItemTooltip
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function OpenMail.OnLogin()
	if not OpenMailFrame or not OpenMailHorizontalBarLeft or not OpenMailReplyButton then return end

	-- O1. Spec §2 B7: 125x22, TOPRIGHT -> OpenMailHorizontalBarLeft BOTTOMRIGHT (+67, +5)
	-- (bar x 2..258 -> button x 200..325). Blizzard re-anchors the bar on every update and
	-- MakeTakeAllRoom lifts it 8 px while the button is wanted, so the button follows it.
	takeAllButton = CreateFrame("Button", "MailFufuTakeAllButton", OpenMailFrame, "UIPanelButtonTemplate")
	takeAllButton:SetSize(125, 22)
	takeAllButton:SetPoint("TOPRIGHT", OpenMailHorizontalBarLeft, "BOTTOMRIGHT", 67, 5)
	takeAllButton:SetText(L.TAKE_ALL)
	takeAllButton:SetScript("OnClick", TakeAll_OnClick)
	takeAllButton:SetScript("OnEnter", function(self) ShowButtonTooltip(self, L.TAKE_ALL_TIP) end)
	takeAllButton:SetScript("OnLeave", GameTooltip_Hide)
	takeAllButton:Hide()

	-- O2. Left of Reply, same 82x22 size as Blizzard's Reply/Delete buttons (MailFrame.xml).
	forwardButton = CreateFrame("Button", "MailFufuForwardButton", OpenMailFrame, "UIPanelButtonTemplate")
	forwardButton:SetSize(82, 22)
	forwardButton:SetPoint("RIGHT", OpenMailReplyButton, "LEFT", 0, 0)
	forwardButton:SetText(L.FORWARD)
	forwardButton:SetScript("OnClick", Forward_OnClick)
	forwardButton:SetScript("OnEnter", function(self) ShowButtonTooltip(self, L.FORWARD_TIP) end)
	forwardButton:SetScript("OnLeave", GameTooltip_Hide)
	forwardButton:Hide()

	ns.Compat.HookOpenMailUpdate(OnOpenMailUpdate)
	OpenMailFrame:HookScript("OnShow", OpenMail.Refresh)
	Engine.RegisterCallback(function()
		OpenMail.Refresh()
	end)

	-- O3. OpenMailMoneyButton's XML OnClick (identical on both branches) runs
	--   OpenMailFrame.updateButtonPositions = false; TakeInboxMoney(InboxFrame.openMailID)
	-- PreClick runs before that handler, so OpenMailFrame.money and the mail's sender /
	-- invoice data are read while the money is certainly still there. (The take is
	-- asynchronous, so an OnClick post-hook would usually work too, but PreClick removes
	-- the dependency on server timing.) The button takes clicks from both mouse buttons
	-- (RegisterForClicks("LeftButtonUp", "RightButtonUp")); PreClick fires for both.
	-- While the engine runs it prints its own money lines, so a manual click is not echoed.
	OpenMailMoneyButton:HookScript("PreClick", function()
		if Engine.IsRunning() then return end
		local index = OpenMailIndex()
		if index and OpenMailFrame.money then
			Engine.PrintMoneyLine(index, OpenMailFrame.money)   -- honours printMoney
		end
	end)
end

ns.RegisterModule("OpenMail", OpenMail)
