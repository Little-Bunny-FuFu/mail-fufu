-- Mail-fufu: History.lua
-- Sent-mail history (design plan §1.4 H1-H4, P4 brief):
--   H1 log store in MailFufuHistory (own SavedVariable), capped at options.historyLength
--   H2 history window (ScrollBox list, newest first, current realm or all realms)
--   H3 32x32 envelope-glyph button over the MailFrame envelope portrait
--   H4 slash subcommands: /mailfufu history, /mailfufu last
--
-- Taint rules (§3.9): the only touches on Blizzard objects are a HookScript on MailFrame
-- (OnShow, to keep the portrait button above the portrait) and the standard
-- tinsert(UISpecialFrames, name) registration that makes Escape / CloseAllWindows close
-- our own window. Everything else is SetScript on frames this file creates.
--
-- Blizzard names checked in wow-ui-source on branch live (12.1.5) AND origin/forever (1.60.1):
--   Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml (loaded as [Family] on Forever)
--     PortraitFrameTemplate -> PortraitFrameTemplateNoCloseButton -> PortraitFrameTexturedBaseTemplate
--     -> PortraitFrameBaseTemplate (mixin PortraitFrameMixin): parentKeys PortraitContainer
--     (.portrait texture, frameLevel 400), TitleContainer (.TitleText), CloseButton.
--   Blizzard_SharedXML/PortraitFrame.lua: PortraitFrameMixin = CreateFromMixins(TitledPanelMixin);
--     :SetPortraitToAsset(texture), :SetTitle(title), :GetPortrait().
--   Blizzard_MailFrame/MailFrame.xml: MailFrame inherits ButtonFrameTemplate (-> PortraitFrameBaseTemplate),
--     so MailFrame.PortraitContainer.portrait is the envelope (MailFrame.lua SetPortraitToAsset Mail-Icon).
--   Blizzard_SharedXML/Shared/Scroll/: WowScrollBoxList (ScrollTemplates.xml), MinimalScrollBar
--     (MinimalScrollBar.xml), CreateScrollBoxListLinearView (ScrollBoxLinearView.lua),
--     ScrollBoxListViewMixin:SetElementInitializer / :SetElementExtent (ScrollBoxListView.lua),
--     ScrollBoxListMixin:SetDataProvider (ScrollBox.lua), ScrollUtil.InitScrollBoxListWithScrollBar
--     (ScrollUtil.lua); CreateDataProvider (Blizzard_SharedXML/DataProvider.lua).
--   UICheckButtonTemplate parentKey "Text" (Shared/Button/CheckButtonTemplates.xml line 54).
--   UISpecialFrames / CloseSpecialWindows (Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua).
--   GameTooltip_SetTitle / GameTooltip_AddInstructionLine (SharedTooltipTemplates.lua), GameTooltip_Hide.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat

local History = {}
ns.History = History

local FRAME_NAME = "MailFufuHistoryFrame"
local WIDTH, HEIGHT = 450, 535
local ROW_HEIGHT = 54           -- three lines: header, subject, attachments
local ITEMS_IN_ROW = 3          -- attachments named in a row before "+N more"
local DATE_FORMAT = "%Y-%m-%d %H:%M"
local MAIL_ICON = "Interface\\MailFrame\\Mail-Icon"                  -- MailFrame.lua, both branches
local HILIGHT = "Interface\\Buttons\\UI-Common-MouseHilight"         -- MailFrame.xml, both branches
-- Portrait button glyph (layout spec 2026-11-09 §2 B12): Mail-fufu's own 64x64 art drawn
-- into the 32x32 button; the pushed art is pre-shifted (no runtime offset).
local HISTORY_ICON = "Interface\\AddOns\\Mail-fufu\\Images\\HistoryIcon"
local HISTORY_ICON_PUSHED = "Interface\\AddOns\\Mail-fufu\\Images\\HistoryIconPushed"
local PORTRAIT_BUTTON_SIZE = 32
local PORTRAIT_BUTTON_X, PORTRAIT_BUTTON_Y = 5, -7   -- MailFrame TOPLEFT -> x 5..37, y -7..-39
local PORTRAIT_BUTTON_LEVEL = 500                    -- above PortraitContainer (400)

local frame             -- the history window (created on first use)
local showAllRealms = false

-- ---------------------------------------------------------------------------
-- Log store (H1)
-- ---------------------------------------------------------------------------
local function Entries()
	local history = ns.history
	if history and type(history.entries) == "table" then
		return history.entries
	end
	return nil
end

local function FormatWhen(when)
	if type(when) == "number" then
		return date(DATE_FORMAT, when)
	end
	return UNKNOWN
end

local function Text(value)
	if value == nil or value == "" then return UNKNOWN end
	return tostring(value)
end

-- ---------------------------------------------------------------------------
-- Attachment formatting (items, money, C.O.D. stored by History.Add)
-- ---------------------------------------------------------------------------
local function MoneyText(copper)
	if type(copper) ~= "number" or copper <= 0 then return nil end
	return GetMoneyString(copper, true)
end

-- "[Item Link]x5" (link when the client gave one, else the plain name).
local function ItemText(item, withIcon)
	if type(item) ~= "table" then return nil end
	local text = item.link or item.name
	if not text or text == "" then text = UNKNOWN end
	if (tonumber(item.count) or 1) > 1 then
		text = text .. "x" .. item.count
	end
	if withIcon and type(item.icon) == "number" then
		text = "|T" .. item.icon .. ":14|t " .. text
	end
	return text
end

local function HasAttachments(e)
	return (type(e.items) == "table" and #e.items > 0)
		or MoneyText(e.money) ~= nil or MoneyText(e.cod) ~= nil
end

-- One-line summary: "[A]x5, [B], +3 more  money: 12g 5s"; nil when the mail carried
-- nothing. limit caps the items named (nil = all).
local function AttachmentSummary(e, limit)
	local parts = {}
	local items = e.items
	if type(items) == "table" and #items > 0 then
		local n = #items
		local shown = limit and math.min(n, limit) or n
		local names = {}
		for i = 1, shown do
			names[#names + 1] = ItemText(items[i])
		end
		if n > shown then
			names[#names + 1] = format(L.HISTORY_MORE, n - shown)
		end
		parts[#parts + 1] = table.concat(names, ", ")
	end
	local money = MoneyText(e.money)
	if money then parts[#parts + 1] = format(L.HISTORY_MONEY, money) end
	local cod = MoneyText(e.cod)
	if cod then parts[#parts + 1] = format(L.HISTORY_COD, cod) end
	if #parts == 0 then return nil end
	return table.concat(parts, "  ")
end

-- Full attachment block for tooltips: header, one line per item (icon + link), money lines.
local function AddAttachmentLines(tooltip, e)
	if not HasAttachments(e) then
		tooltip:AddLine(L.HISTORY_NO_ATTACH, 0.5, 0.5, 0.5)
		return
	end
	local items = e.items
	if type(items) == "table" and #items > 0 then
		tooltip:AddLine(L.HISTORY_TT_ITEMS, 1, 0.82, 0)
		for i = 1, #items do
			tooltip:AddLine(ItemText(items[i], true), 1, 1, 1)
		end
	end
	local money = MoneyText(e.money)
	if money then tooltip:AddDoubleLine(L.HISTORY_TT_MONEY, money, 1, 0.82, 0, 1, 1, 1) end
	local cod = MoneyText(e.cod)
	if cod then tooltip:AddDoubleLine(L.HISTORY_TT_COD, cod, 1, 0.82, 0, 1, 1, 1) end
end

-- Drop the oldest entries until at most n remain (n = 0 empties the log).
function History.Truncate(n)
	local entries = Entries()
	if not entries then return end
	n = tonumber(n) or ns.GetOption("historyLength") or 0
	if n < 0 then n = 0 end
	local excess = #entries - n
	if excess <= 0 then return end
	if n == 0 then
		wipe(entries)
		return
	end
	-- Shift the kept tail to the front in one pass instead of n x tremove(t, 1).
	for i = 1, n do
		entries[i] = entries[i + excess]
	end
	for i = #entries, n + 1, -1 do
		entries[i] = nil
	end
end

-- Append one sent mail. items = array of { name, id, link, count, icon } (or nil), money
-- and cod in copper. Empty values are not stored so old and attachment-less entries look
-- alike. Returns the stored entry, or nil when the history is off.
function History.Add(to, subject, items, money, cod)
	local entries = Entries()
	local maxLen = ns.GetOption("historyLength") or 0
	if not entries or maxLen <= 0 then return nil end
	local entry = {
		to = to or "",
		subject = subject or "",
		from = UnitName("player"),
		realm = Compat.RealmKey(),
		faction = Compat.FactionKey(),
		zone = GetRealZoneText(),
		subzone = GetMinimapZoneText(),
		when = time(),
	}
	if type(items) == "table" and #items > 0 then
		entry.items = items
	end
	if type(money) == "number" and money > 0 then entry.money = money end
	if type(cod) == "number" and cod > 0 then entry.cod = cod end
	entries[#entries + 1] = entry
	History.Truncate(maxLen)
	return entry
end

-- Entries newest first; only the current realm unless allRealms is true.
-- Returns a fresh array of { n = displayNumber, entry = entry }.
function History.GetEntries(allRealms)
	local list = {}
	local entries = Entries()
	if not entries then return list end
	local realm = Compat.RealmKey()
	for i = #entries, 1, -1 do
		local e = entries[i]
		if type(e) == "table" and (allRealms or e.realm == realm) then
			list[#list + 1] = { n = #list + 1, entry = e }
		end
	end
	return list
end

-- Most recent entry of the current realm (what the window shows first by default).
function History.GetLast()
	local entries = Entries()
	if not entries then return nil end
	local realm = Compat.RealmKey()
	for i = #entries, 1, -1 do
		local e = entries[i]
		if type(e) == "table" and e.realm == realm then
			return e
		end
	end
	return nil
end

function History.PrintLast()
	local e = History.GetLast()
	if not e then
		ns.Print(L.LAST_NONE)
		return
	end
	local line = format(L.LAST_LINE, FormatWhen(e.when), Text(e.from), Text(e.to), e.subject or "")
	local summary = AttachmentSummary(e)
	if summary then
		line = line .. " " .. format(L.LAST_ATTACH, summary)
	end
	ns.Print(line)
end

-- ---------------------------------------------------------------------------
-- History window (H2)
-- ---------------------------------------------------------------------------
local function RowTooltip(row)
	local e = row.entry
	if not e then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip_SetTitle(GameTooltip, (e.subject and e.subject ~= "") and e.subject or L.HISTORY_TT_ITEMS)
	GameTooltip:AddDoubleLine(L.HISTORY_TT_TO, Text(e.to), 1, 0.82, 0, 1, 1, 1)
	GameTooltip:AddLine(" ")
	AddAttachmentLines(GameTooltip, e)
	GameTooltip:Show()
end

local function InitRow(row, data)
	if not row.line1 then
		row.line1 = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.line1:SetPoint("TOPLEFT", 6, -4)
		row.line1:SetPoint("TOPRIGHT", -6, -4)
		row.line1:SetJustifyH("LEFT")
		row.line1:SetWordWrap(false)
		row.line2 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.line2:SetPoint("TOPLEFT", row.line1, "BOTTOMLEFT", 0, -4)
		row.line2:SetPoint("TOPRIGHT", row.line1, "BOTTOMRIGHT", 0, -4)
		row.line2:SetJustifyH("LEFT")
		row.line2:SetWordWrap(false)
		row.line3 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.line3:SetPoint("TOPLEFT", row.line2, "BOTTOMLEFT", 0, -3)
		row.line3:SetPoint("TOPRIGHT", row.line2, "BOTTOMRIGHT", 0, -3)
		row.line3:SetJustifyH("LEFT")
		row.line3:SetWordWrap(false)
		-- Hover lists every attachment (the row names at most ITEMS_IN_ROW of them).
		row:EnableMouse(true)
		row:SetScript("OnEnter", RowTooltip)
		row:SetScript("OnLeave", GameTooltip_Hide)
	end
	local e = data.entry
	row.entry = e
	local from = Text(e.from)
	-- In "All realms" mode, tag senders from other realms so equal names stay distinguishable.
	if showAllRealms and e.realm and e.realm ~= Compat.RealmKey() then
		from = from .. "-" .. tostring(e.realm)
	end
	row.line1:SetText(format(L.HISTORY_LINE1, data.n, from, FormatWhen(e.when), Text(e.to)))
	row.line2:SetText(format(L.HISTORY_LINE2, e.subject or ""))
	local summary = AttachmentSummary(e, ITEMS_IN_ROW)
	if summary then
		row.line3:SetFontObject("GameFontHighlightSmall")
		row.line3:SetText(format(L.HISTORY_LINE3, summary))
	else
		row.line3:SetFontObject("GameFontDisableSmall")
		row.line3:SetText(L.HISTORY_NO_ATTACH)
	end
end

local function ApplyPosition()
	if not frame then return end
	frame:ClearAllPoints()
	local p = ns.db and ns.db.ui and ns.db.ui.historyPoint
	if type(p) == "table" and type(p[1]) == "string" and type(p[2]) == "number" and type(p[3]) == "number" then
		frame:SetPoint(p[1], UIParent, p[1], p[2], p[3])
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
end

-- Save as { "TOPLEFT", x, y } relative to UIParent's TOPLEFT (schema §3.8: { point, x, y }).
-- Computed from the frame edges because GetPoint() after StopMovingOrSizing may use a
-- different relative point than the frame point, which the 3-field schema cannot express.
local function SavePosition()
	if not (frame and ns.db and ns.db.ui) then return end
	local left, top = frame:GetLeft(), frame:GetTop()
	local parentTop = UIParent:GetTop()
	if not (left and top and parentTop) then return end
	ns.db.ui.historyPoint = { "TOPLEFT", left, top - parentTop }
	ApplyPosition()
end

function History.Refresh()
	if not (frame and frame:IsShown()) then return end
	local list = History.GetEntries(showAllRealms)
	frame.ScrollBox:SetDataProvider(CreateDataProvider(list))
	frame.EmptyText:SetShown(#list == 0)
end

local function CreateWindow()
	if frame then return frame end

	frame = CreateFrame("Frame", FRAME_NAME, UIParent, "PortraitFrameTemplate")
	frame:Hide()
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:EnableMouse(true)
	frame:SetClampedToScreen(true)
	frame:SetPortraitToAsset(MAIL_ICON)
	frame:SetTitle(L.HISTORY_TITLE)

	-- Dragging (only while the historyMovable option is on).
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		if ns.GetOption("historyMovable") then
			self:StartMoving()
		end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		-- Our own SavedVariables hold the position; keep it out of layout-local.txt.
		self:SetUserPlaced(false)
		SavePosition()
	end)
	frame:SetScript("OnShow", function()
		ApplyPosition()
		History.Refresh()
	end)

	-- Header: "All realms" toggle, right of the portrait, below the title bar.
	local allRealms = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	allRealms:SetSize(24, 24)
	allRealms:SetPoint("TOPLEFT", frame, "TOPLEFT", 60, -26)
	allRealms.Text:SetText(L.HISTORY_ALL_REALMS)
	allRealms:SetChecked(showAllRealms)
	allRealms:SetScript("OnClick", function(self)
		showAllRealms = self:GetChecked() and true or false
		PlaySound(showAllRealms and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
		History.Refresh()
	end)
	frame.AllRealms = allRealms

	-- List area with a faint dark backing so the text reads well on the rock background.
	local scrollBox = CreateFrame("Frame", nil, frame, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -62)
	scrollBox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -26, 10)
	frame.ScrollBox = scrollBox

	local backing = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	backing:SetColorTexture(0, 0, 0, 0.35)
	backing:SetPoint("TOPLEFT", scrollBox, "TOPLEFT", -2, 2)
	backing:SetPoint("BOTTOMRIGHT", scrollBox, "BOTTOMRIGHT", 2, -2)

	local scrollBar = CreateFrame("EventFrame", nil, frame, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
	frame.ScrollBar = scrollBar

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	view:SetElementInitializer("Frame", InitRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

	local empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
	empty:SetPoint("CENTER", scrollBox, "CENTER", 0, 0)
	empty:SetText(L.HISTORY_EMPTY)
	empty:Hide()
	frame.EmptyText = empty

	-- Escape and CloseAllWindows hide frames listed in UISpecialFrames (CloseSpecialWindows).
	-- Standard addon pattern; it only appends our own frame's name.
	tinsert(UISpecialFrames, FRAME_NAME)

	return frame
end

function History.Show()
	CreateWindow():Show()
end

function History.Hide()
	if frame then frame:Hide() end
end

function History.Toggle()
	CreateWindow()
	frame:SetShown(not frame:IsShown())
end

-- Options button "Reset history window position" (Options.lua calls this).
function History.ResetPosition()
	if ns.db and ns.db.ui then
		ns.db.ui.historyPoint = nil
	end
	ApplyPosition()
	ns.Print(L.HISTORY_POS_RESET)
end

-- ---------------------------------------------------------------------------
-- Portrait button on MailFrame (H3)
-- ---------------------------------------------------------------------------
local portraitButton

local function RaisePortraitButton()
	if not portraitButton then return end
	local level = PORTRAIT_BUTTON_LEVEL
	local container = MailFrame.PortraitContainer
	if container and container.GetFrameLevel and container:GetFrameLevel() >= level then
		level = container:GetFrameLevel() + 1
	end
	portraitButton:SetFrameLevel(level)
end

local function PortraitTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip_SetTitle(GameTooltip, L.HISTORY_LAST_TITLE)
	local e = History.GetLast()
	if e then
		GameTooltip:AddDoubleLine(L.HISTORY_TT_DATE, FormatWhen(e.when), 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddDoubleLine(L.HISTORY_TT_TO, Text(e.to), 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddDoubleLine(L.HISTORY_TT_FROM, Text(e.from), 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddDoubleLine(L.HISTORY_TT_SUBJECT, e.subject or "", 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddLine(" ")
		AddAttachmentLines(GameTooltip, e)
	else
		GameTooltip:AddLine(L.LAST_NONE, 1, 1, 1)
	end
	GameTooltip:AddLine(" ")
	GameTooltip_AddInstructionLine(GameTooltip, L.HINT_LEFT)
	GameTooltip_AddInstructionLine(GameTooltip, L.HINT_RIGHT)
	GameTooltip:Show()
end

local function CreatePortraitButton()
	if portraitButton or not MailFrame then return end
	-- One button on MailFrame serves both tabs (the spec's copy on SendMailFrame is not
	-- needed); MailFrame TOPLEFT = InboxFrame TOPLEFT on both branches.
	local b = CreateFrame("Button", nil, MailFrame)
	b:SetSize(PORTRAIT_BUTTON_SIZE, PORTRAIT_BUTTON_SIZE)
	b:SetPoint("TOPLEFT", MailFrame, "TOPLEFT", PORTRAIT_BUTTON_X, PORTRAIT_BUTTON_Y)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetNormalTexture(HISTORY_ICON)
	b:SetPushedTexture(HISTORY_ICON_PUSHED)
	b:SetHighlightTexture(HILIGHT, "ADD")
	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			if ns.Options and ns.Options.Open then
				ns.Options.Open()
			end
		else
			History.Toggle()
		end
	end)
	b:SetScript("OnEnter", PortraitTooltip)
	b:SetScript("OnLeave", GameTooltip_Hide)
	portraitButton = b
	History.portraitButton = b
	RaisePortraitButton()
	-- Toplevel raising re-levels MailFrame's children; re-check on every show.
	MailFrame:HookScript("OnShow", RaisePortraitButton)
end

-- ---------------------------------------------------------------------------
-- Lifecycle and messages
-- ---------------------------------------------------------------------------
function History.OnLogin()
	-- Apply a cap lowered while the addon was not loaded (or by a hand-edited file).
	History.Truncate(ns.GetOption("historyLength"))
	CreatePortraitButton()
end

-- From SendMail.lua after a confirmed successful send.
function History.MAIL_SENT(to, subject, items, money, cod)
	History.Add(to, subject, items, money, cod)
	local line = format(L.SENT_LINE, Text(to), subject or "")
	-- Summarise from the arguments so the chat line is complete even with the history off.
	local summary = AttachmentSummary({ items = items, money = money, cod = cod })
	if summary then
		line = line .. " " .. format(L.LAST_ATTACH, summary)
	end
	ns.Print(line)
	History.Refresh()
end

function History.OPTION_CHANGED(key, value)
	if key == "historyLength" then
		History.Truncate(value)
		History.Refresh()
	end
end

-- ---------------------------------------------------------------------------
-- Slash subcommands (H4)
-- ---------------------------------------------------------------------------
ns.RegisterSlash("history", function() History.Toggle() end)
ns.RegisterSlash("last", function() History.PrintLast() end)

ns.RegisterModule("History", History)
