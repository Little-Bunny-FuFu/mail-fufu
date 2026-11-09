-- Mail-fufu: Inbox.lua
-- Inbox features (design plan §1.2 / §3.6):
--   I1 per-mail checkboxes + marks table      I2 toolbar (Mark/Clear All/Page, Get Checked)
--   I3 Get Checked -> ns.TakeEngine (batch)   I4 right-click take / delete
--   I7 Open All show/hide + enable/disable    InboxTooMuchMail relocation
-- I6 (mail text in the row tooltip) is P3: define ns.Inbox.OnItemTooltip(button) and the
-- InboxFrameItem_OnEnter post-hook installed here will call it.
--
-- Taint rules (§3.9): only hooksecurefunc / HookScript on Blizzard objects; SetScript is
-- used only on frames this file creates. Mail actions are direct C calls.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat
local Engine = ns.TakeEngine

local Inbox = {}
ns.Inbox = Inbox

local ROWS = 7                 -- INBOXITEMS_TO_DISPLAY (MailFrame.lua line 1, both branches)
local ROW_SHIFT = 30           -- rows move right to make room for the checkboxes
local ROW_SHRINK = 17          -- row 305 -> 288, subject 248 -> 231 (MailFrame.xml sizes)

-- Toolbar art (layout spec 2026-11-09 §2 B1-B5, §3): each button is a text-less Blizzard
-- UIPanelButtonTemplate, so the red plate and its Up / Down / Disabled / Highlight states are
-- Blizzard's own (identical on retail and Forever). Mail-fufu's Images\ textures are only
-- transparent gold glyph overlays (tools\Generate-Art.ps1) drawn on top of that plate; the
-- glyph follows the plate at runtime: 1 px down-right while pressed, desaturated while disabled.
-- Every toolbar button is 34 px tall (spec size), so the template's native 22 px plate is
-- stretched vertically; that is accepted.
local IMAGES = "Interface\\AddOns\\Mail-fufu\\Images\\"
local TOOLBAR_Y = -23          -- spec B1-B5: row y -23..-57
local ICON_W, ICON_H = 34, 34
-- Icon glyphs: 64x64 canvases shown as a 34x34 texture covering the whole button, so the
-- bottom-left-justified art sits flush against the plate edge (user preference 2026-11-09).
local ICON_GLYPH = 34
-- Get Checked glyph: 128x64 canvas, art in the top-left 112x34 px at 1:1.
local GC_WIDTH, GC_HEIGHT = 112, 34
local GC_TEXCOORD_R, GC_TEXCOORD_B = 112 / 128, 34 / 64
-- Get Checked's right-hand (empty) slot, which holds the backpack icon. These MIRROR $GcSlot
-- in tools\Generate-Art.ps1 (RightX, Y, Bevel): change both together. The bag icon fills the
-- slot interior: TOPLEFT at (slot x + bevel, -(slot y + bevel)), size = slot - 2 * bevel.
local GC_SLOT_X, GC_SLOT_Y, GC_SLOT_SIZE, GC_SLOT_BEVEL = 79, 6, 22, 2
local GC_BAG_X, GC_BAG_Y = GC_SLOT_X + GC_SLOT_BEVEL, GC_SLOT_Y + GC_SLOT_BEVEL   -- 81, 8
local GC_BAG_SIZE = GC_SLOT_SIZE - 2 * GC_SLOT_BEVEL   -- 18

-- marks[i] = true when the mail at absolute inbox index i is checked. Always a proper
-- array of booleans (length = number of mails); the engine writes false into it.
local marks = {}
Inbox.marks = marks
-- sigs[i] = identity (sender .. subject) of the mail at index i at the last refresh.
local sigs = {}

local checks = {}             -- checkbox per visible row
local toolbar = {}            -- markAll, clearAll, markPage, clearPage, getChecked
local lastNumItems = 0
local titleHiddenByUs = false
local rightClickSnap = {}     -- [rowButton] = { index =, wasRead = } captured in PreClick

local function Sig(index)
	local _, _, sender, subject = GetInboxHeaderInfo(index)
	return (sender or "") .. "\001" .. (subject or "")
end

local function PageFirstIndex()
	local page = (InboxFrame and InboxFrame.pageNum) or 1
	return (page - 1) * (INBOXITEMS_TO_DISPLAY or ROWS) + 1
end

-- ---------------------------------------------------------------------------
-- Marks maintenance
-- ---------------------------------------------------------------------------
-- The plan's minimal rule (new mail inserted at the front, tail trimmed) mis-shifts every
-- mark when the inbox is over capacity: emptied mails vanish and Blizzard refills the
-- list with OLDER mails appended at the END (MailFrame_RefreshInbox / CheckInbox). So
-- marks are carried over by identity instead: walk the old and new lists in order and
-- match each new mail to the next old mail with the same sender + subject. Handles
-- deletions anywhere, front insertions and tail appends; unmatched (new) mails start
-- unchecked. Identical-looking mails (same sender and subject) may swap marks; harmless.
local function RemapMarks(numItems)
	local oldN = #sigs
	local same = (oldN == numItems)
	local newSigs = {}
	for i = 1, numItems do
		newSigs[i] = Sig(i)
		if same and newSigs[i] ~= sigs[i] then
			same = false
		end
	end
	if same then
		for i = 1, numItems do
			if marks[i] == nil then marks[i] = false end
		end
		return
	end

	local newMarks = {}
	local o = 1
	for j = 1, numItems do
		local found
		for k = o, oldN do
			if sigs[k] == newSigs[j] then
				found = k
				break
			end
		end
		if found then
			newMarks[j] = marks[found] and true or false
			o = found + 1
		else
			newMarks[j] = false
		end
	end

	-- Refill the SAME tables: the engine holds a reference to marks.
	wipe(marks)
	wipe(sigs)
	for j = 1, numItems do
		marks[j] = newMarks[j]
		sigs[j] = newSigs[j]
	end
end

local function AnyMarked()
	for i = 1, #marks do
		if marks[i] then return true end
	end
	return false
end

local function SetMarks(first, last, value)
	if last > #marks then last = #marks end
	for i = first, last do
		marks[i] = value
	end
end

-- ---------------------------------------------------------------------------
-- Refresh (InboxUpdate post-hook, engine callbacks, our own clicks)
-- ---------------------------------------------------------------------------

local function RefreshChecks()
	local running = Engine.IsRunning()
	local index = PageFirstIndex()
	for i = 1, ROWS do
		local cb = checks[i]
		if cb then
			if index <= lastNumItems then
				cb.index = index
				cb:SetChecked(marks[index] and true or false)
				cb:SetEnabled(not running)
				cb:Show()
			else
				cb.index = nil
				cb:SetChecked(false)
				cb:Hide()
			end
		end
		index = index + 1
	end
end

-- Plain SetEnabled: the template's OnEnable/OnDisable swap the plate, our hooks the glyph.
local function RefreshToolbar()
	if not toolbar.markAll then return end
	local running = Engine.IsRunning()
	local hasMail = lastNumItems > 0
	local markable = hasMail and not running
	toolbar.markAll:SetEnabled(markable)
	toolbar.clearAll:SetEnabled(markable)
	toolbar.markPage:SetEnabled(markable)
	toolbar.clearPage:SetEnabled(markable)
	toolbar.getChecked:SetEnabled(markable and AnyMarked())
end

-- Red "too much mail" warning: moved up over the title (the toolbar sits where it was);
-- the title is hidden while the warning shows on the inbox tab.
local function RefreshTitle(numItems, totalItems)
	local title = MailFrame and MailFrame.TitleContainer
	if not title then return end
	local overflow = InboxFrame:IsShown() and totalItems and numItems and totalItems > numItems
	if overflow then
		if title:IsShown() then
			title:Hide()
			titleHiddenByUs = true
		end
	elseif titleHiddenByUs then
		title:Show()
		titleHiddenByUs = false
	end
end

local function RestoreTitle()
	if titleHiddenByUs and MailFrame and MailFrame.TitleContainer then
		MailFrame.TitleContainer:Show()
	end
	titleHiddenByUs = false
end

-- I7 enable rule. Never touch the button while Blizzard's own run is active (its text is
-- OPEN_ALL_MAIL_BUTTON_OPENING then: OpenAllMailMixin:StartOpening, both branches).
local function RefreshOpenAllEnabled()
	if not OpenAllMail then return end
	if OpenAllMail:GetText() == OPEN_ALL_MAIL_BUTTON_OPENING then return end
	OpenAllMail:SetEnabled(lastNumItems > 0 and not Engine.IsRunning())
end

-- I7 show rule. On Forever with the gamepad UI Blizzard hides the button itself
-- (InboxMixin:InitializeGamepad); never force it back.
local function ApplyOpenAllShown()
	if not OpenAllMail or Compat.IsGamepadUI() then return end
	local show = ns.GetOption("showOpenAll") and true or false
	if OpenAllMail:IsShown() ~= show then
		OpenAllMail:SetShown(show)
		-- Hiding fires OpenAllMailMixin:OnHide -> StopOpening -> C_Mail.SetOpeningAll(false);
		-- re-assert our own run's flag if one is active.
		if not show and Engine.IsRunning() then
			C_Mail.SetOpeningAll(true)
		end
	end
end

function Inbox.Refresh()
	if not InboxFrame then return end
	local numItems, totalItems = GetInboxNumItems()
	numItems = numItems or 0
	RemapMarks(numItems)
	lastNumItems = numItems
	RefreshChecks()
	RefreshToolbar()
	RefreshTitle(numItems, totalItems)
	RefreshOpenAllEnabled()
end

-- Redraw without re-reading headers (after our own mark changes).
local function RefreshMarksOnly()
	RefreshChecks()
	RefreshToolbar()
end

-- ---------------------------------------------------------------------------
-- I4: right-click take / delete
-- ---------------------------------------------------------------------------

-- Re-validate right before deleting: the popup may have been open while the inbox changed.
local function DeleteIfStillTextOnly(data)
	if type(data) ~= "table" or not data.index then return end
	local index = data.index
	if index > GetInboxNumItems() or Sig(index) ~= data.sig then return end
	local _, _, _, _, money, CODAmount, _, itemCount = GetInboxHeaderInfo(index)
	if (money and money > 0) or (itemCount and itemCount > 0) or (CODAmount and CODAmount > 0) then return end
	if Engine.IsRunning() or C_Mail.IsCommandPending() then return end
	if not InboxItemCanDelete(index) then return end
	-- Direct C call (not OpenMail_Delete / OpenMailDeleteMixin, whose names differ per
	-- client). Blizzard hides the open-mail panel itself on CLOSE_INBOX_ITEM.
	DeleteInboxItem(index)
end

StaticPopupDialogs["MAILFUFU_CONFIRM_DELETE_MAIL"] = {
	text = "%s",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, data)
		DeleteIfStillTextOnly(data)
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

-- wasRead = read state captured BEFORE Blizzard's click handler opened (and so read) it.
function Inbox.OnRightClick(index, wasRead)
	if not index or index > GetInboxNumItems() then return end
	local _, _, sender, _, money, CODAmount, _, itemCount = GetInboxHeaderInfo(index)
	if CODAmount and CODAmount > 0 then return end      -- COD: plain click only
	local hasLoot = (money and money > 0) or (itemCount and itemCount > 0)
	if hasLoot then
		if ns.GetOption("rightClickTake") then
			Engine.Start({ mails = { index }, source = "rightclick" })
		end
		return
	end

	if not ns.GetOption("rightClickDelete") then return end
	-- A pending command here usually means Blizzard's own close-delete is in flight.
	if Engine.IsRunning() or C_Mail.IsCommandPending() then return end
	if not InboxItemCanDelete(index) then return end

	local data = { index = index, sig = Sig(index) }
	local who = sender or UNKNOWN
	if not wasRead then
		StaticPopup_Show("MAILFUFU_CONFIRM_DELETE_MAIL", format(L.DELETE_UNREAD_Q, who), nil, data)
	elseif ns.GetOption("promptDeleteRead") then
		StaticPopup_Show("MAILFUFU_CONFIRM_DELETE_MAIL", format(L.DELETE_Q, who), nil, data)
	else
		DeleteIfStillTextOnly(data)
	end
end

local function HookRowButton(button)
	-- PreClick runs before the XML OnClick (which opens the mail and so marks it read).
	button:HookScript("PreClick", function(self, mouseButton)
		if mouseButton == "RightButton" and self.index then
			local _, _, _, _, _, _, _, _, wasRead = GetInboxHeaderInfo(self.index)
			rightClickSnap[self] = { index = self.index, wasRead = wasRead and true or false }
		else
			rightClickSnap[self] = nil
		end
	end)
	-- Post-hook: Blizzard's OnClick has already toggled the open-mail panel (and our
	-- InboxFrame_OnClick hook has stopped any running take).
	button:HookScript("OnClick", function(self, mouseButton)
		local snap = rightClickSnap[self]
		rightClickSnap[self] = nil
		if mouseButton ~= "RightButton" then return end
		-- Shift-click (MAILAUTOLOOTTOGGLE) is Blizzard's auto-loot; leave it alone.
		if IsModifiedClick("MAILAUTOLOOTTOGGLE") then return end
		local wasRead = snap and snap.index == self.index and snap.wasRead or false
		Inbox.OnRightClick(self.index, wasRead)
	end)
end

-- ---------------------------------------------------------------------------
-- Frame construction
-- ---------------------------------------------------------------------------

-- Spec §2: tooltips anchored ANCHOR_TOPLEFT (above the strip, so the Get Checked tip does
-- not spill over the open-mail panel). Content stays title + wrapped body line.
local function ShowButtonTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
	GameTooltip_SetTitle(GameTooltip, self.tipTitle)
	GameTooltip_AddNormalLine(GameTooltip, self.tipText, true)
	GameTooltip:Show()
end

local function SetupToolbarButton(b, title, tip, onClick)
	b:SetMotionScriptsWhileDisabled(true)   -- tooltip also while disabled
	b.tipTitle = title
	b.tipText = tip
	b:SetScript("OnEnter", ShowButtonTooltip)
	b:SetScript("OnLeave", GameTooltip_Hide)
	b:SetScript("OnClick", onClick)
	b:Disable()                              -- spec: disabled at load; Refresh enables
end

-- Overlays (the glyph, plus Get Checked's bag icon) follow the template plate: 1 px down-right
-- while pressed (d = 1), back at rest (d = 0). A sized glyph (icon buttons) is centred; an
-- unsized one (Get Checked) covers the whole button.
local function PlaceOverlays(b, d)
	if b.glyphSize then
		b.glyph:SetPoint("CENTER", b, "CENTER", d, -d)
	else
		b.glyph:SetPoint("TOPLEFT", b, "TOPLEFT", d, -d)
		b.glyph:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", d, -d)
	end
	if b.bagIcon then
		b.bagIcon:SetPoint("TOPLEFT", b, "TOPLEFT", GC_BAG_X + d, -GC_BAG_Y - d)
	end
end

local function DesaturateOverlays(b, desaturated)
	b.glyph:SetDesaturated(desaturated)
	if b.bagIcon then
		b.bagIcon:SetDesaturated(desaturated)
	end
end

-- Text-less UIPanelButtonTemplate with a gold glyph overlay. The template (both branches)
-- binds OnMouseDown / OnMouseUp / OnShow / OnEnable / OnDisable in XML <Scripts> to the
-- UIPanelButton_* functions that swap its Left/Middle/Right plate textures, so the glyph
-- follows via HookScript; SetScript would replace those handlers and freeze the plate.
-- glyphSize: square glyph size centred on the button, or nil to cover the whole button.
local function CreateGlyphButton(width, height, art, glyphSize)
	local b = CreateFrame("Button", nil, InboxFrame, "UIPanelButtonTemplate")
	b:SetSize(width, height)
	local glyph = b:CreateTexture(nil, "OVERLAY")   -- above the BACKGROUND plate
	glyph:SetTexture(IMAGES .. art)
	if glyphSize then
		glyph:SetSize(glyphSize, glyphSize)
	end
	b.glyph = glyph
	b.glyphSize = glyphSize
	PlaceOverlays(b, 0)
	b:HookScript("OnMouseDown", function(self) if self:IsEnabled() then PlaceOverlays(self, 1) end end)
	b:HookScript("OnMouseUp", function(self) PlaceOverlays(self, 0) end)
	b:HookScript("OnShow", function(self) PlaceOverlays(self, 0) end)   -- hidden before mouse-up
	b:HookScript("OnEnable", function(self) DesaturateOverlays(self, false) end)
	b:HookScript("OnDisable", function(self) DesaturateOverlays(self, true) end)
	return b
end

-- B1-B4: 34x34 button; art = 64x64 glyph base name in Images\, shown 28x28 centred.
local function CreateIconButton(art, title, tip, onClick)
	local b = CreateGlyphButton(ICON_W, ICON_H, art, ICON_GLYPH)
	SetupToolbarButton(b, title, tip, onClick)
	DesaturateOverlays(b, not b:IsEnabled())
	return b
end

-- B5: 112x34 button; glyph = the 112x34 crop of the 128x64 GetChecked canvas.
local function CreatePlateButton(title, tip, onClick)
	local b = CreateGlyphButton(GC_WIDTH, GC_HEIGHT, "GetChecked")
	b.glyph:SetTexCoord(0, GC_TEXCOORD_R, 0, GC_TEXCOORD_B)
	-- Blizzard's backpack icon in the glyph's right-hand slot (the slot is drawn empty in the
	-- art; geometry = GC_SLOT_* above). Inv_misc_bag_08 is the asset Blizzard uses as the
	-- backpack ContainerFrame portrait on both clients (ContainerFrame.lua, live + forever).
	local bag = b:CreateTexture(nil, "OVERLAY", nil, 1)   -- above the glyph's empty slot
	bag:SetTexture("Interface\\Icons\\Inv_misc_bag_08")
	bag:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- trim the icon's baked border
	bag:SetSize(GC_BAG_SIZE, GC_BAG_SIZE)
	b.bagIcon = bag
	PlaceOverlays(b, 0)
	SetupToolbarButton(b, title, tip, onClick)
	DesaturateOverlays(b, not b:IsEnabled())
	return b
end

local function PlayCheckSound(on)
	PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
end

local function OnMarkAll()
	if Engine.IsRunning() then return end
	SetMarks(1, #marks, true)
	PlayCheckSound(true)
	RefreshMarksOnly()
end

local function OnClearAll()
	if Engine.IsRunning() then return end
	SetMarks(1, #marks, false)
	PlayCheckSound(false)
	RefreshMarksOnly()
end

local function OnMarkPage()
	if Engine.IsRunning() then return end
	local first = PageFirstIndex()
	SetMarks(first, first + ROWS - 1, true)
	PlayCheckSound(true)
	RefreshMarksOnly()
end

local function OnClearPage()
	if Engine.IsRunning() then return end
	local first = PageFirstIndex()
	SetMarks(first, first + ROWS - 1, false)
	PlayCheckSound(false)
	RefreshMarksOnly()
end

local function OnGetChecked()
	if Engine.IsRunning() then return end
	local list = {}
	for i = #marks, 1, -1 do
		if marks[i] then
			tinsert(list, i)
		end
	end
	if #list == 0 then return end
	Engine.Start({
		mails = list,
		source = "batch",
		deletePending = ns.GetOption("deletePendingAuction"),
		marks = marks,
	})
end

-- Spec §2 / §4 geometry (InboxFrame TOPLEFT origin; TOPLEFT-relative, so identical on the
-- 384-wide live InboxFrame and the 338-wide Forever one):
--   Mark All x 62..96 | Clear All 96..130 | gap 7 | Mark Page 137..171 | Clear Page 171..205
--   | gap 7 | Get Checked 212..324; all y -23..-57 (34 px tall).
local function CreateToolbar()
	toolbar.markAll   = CreateIconButton("MarkAll",   L.MARK_ALL,   L.MARK_ALL_TIP,   OnMarkAll)
	toolbar.clearAll  = CreateIconButton("ClearAll",  L.CLEAR_ALL,  L.CLEAR_ALL_TIP,  OnClearAll)
	toolbar.markPage  = CreateIconButton("MarkPage",  L.MARK_PAGE,  L.MARK_PAGE_TIP,  OnMarkPage)
	toolbar.clearPage = CreateIconButton("ClearPage", L.CLEAR_PAGE, L.CLEAR_PAGE_TIP, OnClearPage)
	toolbar.getChecked = CreatePlateButton(L.GET_CHECKED, L.GET_CHECKED_TIP, OnGetChecked)

	toolbar.markAll:SetPoint("TOPLEFT", InboxFrame, "TOPLEFT", 62, TOOLBAR_Y)
	toolbar.clearAll:SetPoint("TOPLEFT", toolbar.markAll, "TOPRIGHT", 0, 0)
	toolbar.markPage:SetPoint("TOPLEFT", toolbar.clearAll, "TOPRIGHT", 7, 0)
	toolbar.clearPage:SetPoint("TOPLEFT", toolbar.markPage, "TOPRIGHT", 0, 0)
	toolbar.getChecked:SetPoint("TOPLEFT", toolbar.clearPage, "TOPRIGHT", 7, 0)

	-- Spec §1 / B1-B5 "Hidden when": limited-mode (trial) accounts get no toolbar.
	if Compat.IsLimitedMode() then
		toolbar.markAll:Hide()
		toolbar.clearAll:Hide()
		toolbar.markPage:Hide()
		toolbar.clearPage:Hide()
		toolbar.getChecked:Hide()
	end
end

local function ShiftAndNarrowRows()
	-- Row 1: re-apply its own anchors shifted right (rows 2-7 hang off the previous row).
	local row1 = _G.MailItem1
	local n = row1:GetNumPoints()
	local points = {}
	for i = 1, n do
		points[i] = { row1:GetPoint(i) }
	end
	if n > 0 then
		row1:ClearAllPoints()
		for i = 1, n do
			local p = points[i]
			row1:SetPoint(p[1], p[2] or InboxFrame, p[3] or p[1], (p[4] or 0) + ROW_SHIFT, p[5] or 0)
		end
	end

	for i = 1, ROWS do
		local row = _G["MailItem" .. i]
		local subject = _G["MailItem" .. i .. "Subject"]
		if row then
			row:SetWidth(row:GetWidth() - ROW_SHRINK)
		end
		if subject then
			subject:SetWidth(subject:GetWidth() - ROW_SHRINK)
		end
	end
end

local function CreateCheckboxes()
	for i = 1, ROWS do
		local row = _G["MailItem" .. i]
		if row then
			local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
			cb:SetSize(27, 27)
			cb:SetPoint("TOPLEFT", row, "TOPLEFT", -25, -9)
			cb:SetScript("OnClick", function(self)
				local index = self.index
				if not index or Engine.IsRunning() or index > #marks then
					self:SetChecked(index and marks[index] or false)
					return
				end
				local on = self:GetChecked() and true or false
				marks[index] = on
				PlayCheckSound(on)
				RefreshToolbar()
			end)
			cb:Hide()
			checks[i] = cb
		end
	end
end

local function RelocateTooMuchMail()
	if not InboxTooMuchMail then return end
	InboxTooMuchMail:ClearAllPoints()
	InboxTooMuchMail:SetPoint("TOP", InboxFrame, "TOP", -13, 4)
	InboxTooMuchMail:SetFrameStrata("HIGH")
end

-- ---------------------------------------------------------------------------
-- Lifecycle and events
-- ---------------------------------------------------------------------------

function Inbox.OnLogin()
	if not MailFrame or not InboxFrame or not _G.MailItem1 then return end

	ShiftAndNarrowRows()
	CreateCheckboxes()
	CreateToolbar()
	RelocateTooMuchMail()
	ApplyOpenAllShown()

	for i = 1, ROWS do
		local button = _G["MailItem" .. i .. "Button"]
		if button then
			HookRowButton(button)
		end
	end

	Compat.HookInboxUpdate(Inbox.Refresh)

	-- MailFrameTab_OnClick(self, tabID): global on both branches (live line 141,
	-- forever line 189); tabID may be nil -> self:GetID().
	hooksecurefunc("MailFrameTab_OnClick", function(self, tabID)
		local id = tabID or (self and self.GetID and self:GetID())
		if id == 1 then
			local numItems, totalItems = GetInboxNumItems()
			RefreshTitle(numItems, totalItems)
		else
			RestoreTitle()
		end
	end)
	MailFrame:HookScript("OnHide", RestoreTitle)

	-- P3 (I6) hook point: OpenMail/tooltip code defines ns.Inbox.OnItemTooltip(button).
	-- InboxFrameItem_OnEnter is global on both branches and is re-run every frame from the
	-- row's OnUpdate while the tooltip is owned, so the callee must stay cheap.
	hooksecurefunc("InboxFrameItem_OnEnter", function(button)
		if Inbox.OnItemTooltip then
			Inbox.OnItemTooltip(button)
		end
	end)

	Engine.RegisterCallback(function()
		Inbox.Refresh()
	end)
end

-- Fresh marks for every visit to the mailbox (§2.4 MAIL_SHOW).
function Inbox.OnMailShow()
	wipe(marks)
	wipe(sigs)
	lastNumItems = 0
	ApplyOpenAllShown()
	Inbox.Refresh()
end

function Inbox.OnMailClosed()
	wipe(marks)
	wipe(sigs)
	lastNumItems = 0
	StaticPopup_Hide("MAILFUFU_CONFIRM_DELETE_MAIL")
	RestoreTitle()
end

function Inbox.OPTION_CHANGED(key, value)
	if key == "showOpenAll" then
		ApplyOpenAllShown()
	elseif key == "rightClickDelete" then
		-- Read at click time; turning it off also drops a delete prompt still on screen.
		if not value then
			StaticPopup_Hide("MAILFUFU_CONFIRM_DELETE_MAIL")
		end
	elseif key == "rightClickTake" then
		-- Read at click time; a running take is not interrupted by the toggle.
	end
end

ns.RegisterModule("Inbox", Inbox)
