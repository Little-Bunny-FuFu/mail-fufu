-- Mail-fufu: TakeEngine.lua
-- Headless attachment-collection state machine (design plan §3.4). Shared by
-- "Get Checked" (batch), right-click take and the open-mail "Take All" button.
--
-- It addresses attachments by (mailIndex, attachmentIndex) like Blizzard's own
-- OpenAllMailMixin (Blizzard_MailFrame/MailFrame.lua, both branches): it never pages the
-- inbox and never clicks Blizzard buttons. Mails are processed in DESCENDING index order,
-- so a mail that disappears (emptied, or a deleted pending-auction invoice) never shifts
-- the indices of the mails still to do.
--
-- Pacing: one mail command at a time. No command (including the first) is issued while
-- C_Mail.IsCommandPending() is true (documented in MailInfoDocumentation.lua, both
-- branches) or sooner than MIN_DELAY after the previous one. A pending Take/Delete counts
-- as done when the inbox count drops (the mail was removed), CLOSE_INBOX_ITEM names its
-- mail, or the money/attachment is gone from an unchanged inbox; re-checks run on MAIL_INBOX_UPDATE,
-- MAIL_FAILED, CLOSE_INBOX_ITEM and a 0.2 s C_Timer ticker (safety net for missed
-- events). Blizzard's Open All waits OPEN_ALL_MAIL_MIN_DELAY = 0.15 s between commands;
-- the same minimum is kept here.
--
-- Public API (ns.TakeEngine):
--   Start(job) -> true when a run started
--       job = { mails = { mailIndex, ... },          -- any order; sorted descending here
--               source = "batch" | "rightclick" | "takeall",
--               deletePending = bool,                -- delete "seller_temp_invoice" mails
--               marks = array }                      -- optional: marks[i] = false when mail i finishes
--   Stop(reason)        reason: "done" | "closed" | "user" | "timeout" | "bagsfull" |
--                               "changed" | "canceled" | "error" | any string
--   IsRunning()
--   RegisterCallback(fn)   fn("started", source) / fn("stopped", reason)
--   PrintMoneyLine(mailIndex, copper)   per-mail money chat line (honours printMoney)

local ADDON, ns = ...
local L = ns.L

local Engine = {}
ns.TakeEngine = Engine

local TIMEOUT = 10        -- seconds one attachment may take before the run aborts (I3)
local TICK = 0.2          -- safety-net ticker
local MIN_DELAY = 0.15    -- Blizzard OPEN_ALL_MAIL_MIN_DELAY (MailFrame.lua, both branches)
local AWAIT_DROP = 2      -- max seconds to wait for a CLOSE_INBOX_ITEM removal to reach the count

local STATE_IDLE, STATE_RUNNING, STATE_WAITING = "IDLE", "RUNNING", "WAITING"

local state = STATE_IDLE
local job
local ticker
local stepping = false
local callbacks = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function MaxAttachments()
	-- ATTACHMENTS_MAX = 16: MailFrame.lua line 3, both branches.
	return ATTACHMENTS_MAX or 16
end

-- Identity of the mail at an index. There is no mail GUID API; sender + subject does not
-- change while attachments are taken, so it detects index shifts (new mail arriving at
-- the front) before the engine takes from the wrong mail.
local function SigAt(index)
	local _, _, sender, subject = GetInboxHeaderInfo(index)
	return (sender or "") .. "\001" .. (subject or "")
end
Engine.Sig = SigAt        -- shared with Inbox.lua (check marks)

-- invoiceType, itemName for an invoice mail; nil for anything else.
-- UNVERIFIED: Blizzard only calls GetInboxInvoiceInfo after GetInboxText() reported an
-- invoice; calling it on a plain mail is expected to return nil. pcall keeps a C error from
-- breaking the run, and GetInboxText is deliberately avoided (it marks the mail read).
local function InvoiceInfo(index)
	local ok, invoiceType, itemName = pcall(GetInboxInvoiceInfo, index)
	if ok then
		return invoiceType, itemName
	end
	return nil, nil
end

-- "from <sender>" or "from auction of <item>" for the money chat line (O3).
local function MoneySourceText(mailIndex)
	local invoiceType, itemName = InvoiceInfo(mailIndex)
	if invoiceType == "seller" and itemName then
		return format(L.FROM_AUCTION, itemName)
	end
	local _, _, sender = GetInboxHeaderInfo(mailIndex)
	return format(L.FROM, sender or UNKNOWN)
end

local function PrintMoney(copper, fromText)
	if not ns.GetOption("printMoney") then return end
	if not copper or copper <= 0 then return end
	ns.Print(format(L.RECEIVE_MONEY, GetMoneyString(copper, true), fromText))
end

-- Public: chat line for money taken from mailIndex (call while the mail still exists).
function Engine.PrintMoneyLine(mailIndex, copper)
	if not mailIndex or not copper or copper <= 0 then return end
	PrintMoney(copper, MoneySourceText(mailIndex))
end

local function FireCallbacks(what, arg)
	for i = 1, #callbacks do
		local ok, err = pcall(callbacks[i], what, arg)
		if not ok then
			geterrorhandler()(err)
		end
	end
end

function Engine.RegisterCallback(fn)
	if type(fn) == "function" then
		tinsert(callbacks, fn)
	end
end

function Engine.IsRunning()
	return state ~= STATE_IDLE
end

local function MailFrameShown()
	return MailFrame ~= nil and MailFrame:IsShown()
end

-- Blizzard's own Open All run is active while its button reads OPEN_ALL_MAIL_BUTTON_OPENING
-- (OpenAllMailMixin:StartOpening, both branches). Two runners must not interleave.
local function BlizzardOpenAllRunning()
	return OpenAllMail ~= nil and OpenAllMail:GetText() == OPEN_ALL_MAIL_BUTTON_OPENING
end

-- When the mail being emptied is the one shown in the open-mail panel, freeze the panel's
-- attachment layout exactly like Blizzard's attachment click does
-- (OpenMailAttachment_OnClick: "OpenMailFrame.updateButtonPositions = false", live
-- MailFrame.lua ~line 922 / forever ~line 1176). Taint rationale: a plain field write that
-- Blizzard itself performs from an insecure click handler; the field is only read by the
-- open-mail layout code, never by a protected path (design plan §3.9 rule 4).
local function FreezeOpenMailLayout(mailIndex)
	if OpenMailFrame and OpenMailFrame:IsShown() and InboxFrame and InboxFrame.openMailID == mailIndex then
		OpenMailFrame.updateButtonPositions = false -- luacheck: ignore 122
	end
end

-- ---------------------------------------------------------------------------
-- Stop
-- ---------------------------------------------------------------------------

function Engine.Stop(reason)
	if state == STATE_IDLE then return end
	local finished = job
	state = STATE_IDLE
	job = nil
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
	C_Mail.SetOpeningAll(false)

	reason = reason or "user"
	if reason == "timeout" then
		ns.PrintError(L.TIMEOUT)          -- red line + IG_QUEST_LOG_ABANDON_QUEST sound
	elseif reason == "bagsfull" then
		ns.PrintError(L.BAGS_FULL)
	elseif reason == "changed" then
		ns.PrintError(L.INBOX_CHANGED, true)
	end

	if finished and finished.source == "batch" and finished.totalMoney > 0 and ns.GetOption("printTotal") then
		ns.Print(format(L.TOTAL, GetMoneyString(finished.totalMoney, true)))
	end

	FireCallbacks("stopped", reason)
end

-- ---------------------------------------------------------------------------
-- Step
-- ---------------------------------------------------------------------------

local function FinishMail(mail, clearMark)
	if clearMark and job.marks and job.marks[mail] then
		job.marks[mail] = false   -- keep the marks table a proper array (no nil holes)
	end
	job.mailPos = job.mailPos + 1
end

-- Next item attachment slot of a mail (highest slot first, Blizzard order), skipping
-- slots and itemIDs that already reported MAIL_FAILED.
local function FindAttachment(mail)
	for a = MaxAttachments(), 1, -1 do
		if HasInboxItem(mail, a) and not job.failedSlots[mail .. ":" .. a] then
			-- GetInboxItem -> name, itemID, texture, count, quality, canUse, isCurrency
			-- (OpenAllMailMixin:ShouldSkipCurrentAttachment, both branches)
			local _, itemID, _, _, _, _, isCurrency = GetInboxItem(mail, a)
			if isCurrency or not itemID or not job.failedItemIDs[itemID] then
				return a, itemID
			end
		end
	end
	return nil
end

-- Money or any item attachment left on a mail?
local function HasRemainingLoot(mail)
	if C_Mail.HasInboxMoney(mail) then return true end
	for a = 1, MaxAttachments() do
		if HasInboxItem(mail, a) then return true end
	end
	return false
end

-- Outcome of the pending command: "done" (+ gone = the mail was removed), "changed"
-- (the inbox changed under us; nothing is credited) or "wait".
-- The inbox COUNT decides first: sender + subject cannot tell two identical adjacent mails
-- apart (an emptied, auto-deleted auction mail is replaced at its index by an identical
-- older one), nor see a new identical mail arriving at the front.
local function PendingOutcome(p)
	local count = GetInboxNumItems()
	if count < p.numItems then
		return "done", true                      -- the mail we emptied/deleted was removed
	end
	if count > p.numItems or SigAt(p.mail) ~= job.sigs[p.mail] then
		return "changed"
	end
	if p.kind == "money" then
		if C_Mail.HasInboxMoney(p.mail) then return "wait" end
		return "done", false
	elseif p.kind == "item" then
		if HasInboxItem(p.mail, p.att) then return "wait" end
		return "done", false
	end
	return "wait"                                -- "delete": same mail still at its index
end

-- Bookkeeping for a completed pending command. Called exactly once per command, at the
-- point where job.pending is cleared, so money is credited once.
local function PendingDone(p, gone)
	if p.kind == "money" then
		job.totalMoney = job.totalMoney + (p.amount or 0)
		PrintMoney(p.amount, p.fromText)
	elseif p.kind == "delete" then
		job.deleted[p.mail] = true
		gone = true
	end
	if gone then
		job.gone[p.mail] = true
	end
end

local function Begin(kind, mail, extra)
	local p = extra or {}
	p.kind = kind
	p.mail = mail
	p.startedAt = GetTime()
	p.numItems = GetInboxNumItems()
	job.pending = p
	job.nextCommandAt = p.startedAt + MIN_DELAY
	state = STATE_WAITING
	FreezeOpenMailLayout(mail)
end

local function DoStep()
	if not MailFrameShown() then
		Engine.Stop("closed")
		return
	end

	local now = GetTime()
	local p = job.pending
	if p and now - p.startedAt > TIMEOUT then
		Engine.Stop("timeout")
		return
	end

	-- A mail inserted anywhere (even one identical to a neighbour) grows the count.
	local numItems = GetInboxNumItems()
	if numItems > job.lastCount then
		Engine.Stop("changed")
		return
	end
	job.lastCount = numItems

	-- Pacing gate for EVERY command (also the first one, which may follow a manual take,
	-- and the next one after MAIL_FAILED): one server command at a time, MIN_DELAY apart.
	if C_Mail.IsCommandPending() or now < job.nextCommandAt then
		return                                       -- wait (ticker/events re-enter)
	end
	local await = job.awaitDrop
	if await then
		if numItems >= await.count and now - await.at < AWAIT_DROP then
			return                                   -- removal announced, not yet in the list
		end
		job.awaitDrop = nil
	end

	if p then
		local outcome, gone = PendingOutcome(p)
		if outcome == "wait" then
			return                                   -- keep waiting (timeout above)
		elseif outcome == "changed" then
			Engine.Stop("changed")                   -- nothing credited; marks survive
			return
		end
		job.pending = nil
		state = STATE_RUNNING
		PendingDone(p, gone)
	end

	while true do
		local mail = job.mails[job.mailPos]
		if not mail then
			Engine.Stop("done")
			return
		end

		if job.gone[mail] then
			-- We emptied/deleted it and it was removed (or is being removed). Its mark is not
			-- touched: Inbox re-maps marks by identity once the row disappears.
			FinishMail(mail, false)
		elseif mail > numItems or SigAt(mail) ~= job.sigs[mail] then
			Engine.Stop("changed")                   -- indices shifted under us
			return
		else
			-- GetInboxHeaderInfo -> packageIcon, stationeryIcon, sender, subject, money,
			-- CODAmount, daysLeft, itemCount, wasRead, wasReturned, textCreated, canReply, isGM
			local _, _, _, _, money, CODAmount, _, _, _, _, _, _, isGM = GetInboxHeaderInfo(mail)
			if (CODAmount and CODAmount > 0) or isGM then
				-- COD must be accepted by hand; GM mail must be opened by hand (same rule as
				-- OpenAllMailMixin:ShouldSkipCurrentMail). Mark stays set.
				FinishMail(mail, false)
			elseif job.deletePending and not job.deleted[mail] and InvoiceInfo(mail) == "seller_temp_invoice" then
				if InboxItemCanDelete(mail) then
					Begin("delete", mail)
					DeleteInboxItem(mail)
					return
				end
				FinishMail(mail, false)
			elseif C_Mail.HasInboxMoney(mail) and not job.moneyFailed[mail] then
				-- Capture the chat text now: the mail may vanish once emptied.
				Begin("money", mail, { amount = money, fromText = MoneySourceText(mail) })
				TakeInboxMoney(mail)
				return
			else
				local att, itemID = FindAttachment(mail)
				if att then
					-- Same check Blizzard makes before every take
					-- (OpenAllMailMixin:AdvanceAndProcessNextItem, both branches).
					if C_Container.CalculateTotalNumberOfFreeBagSlots() == 0 then
						Engine.Stop("bagsfull")
						return
					end
					Begin("item", mail, { att = att, itemID = itemID })
					TakeInboxItem(mail, att)
					return
				end
				-- Nothing eligible left. The mark is cleared only when the mail is really
				-- empty: loot skipped after MAIL_FAILED stays marked for a later retry.
				FinishMail(mail, not HasRemainingLoot(mail))
			end
		end
	end
end

local function Step()
	if state == STATE_IDLE or stepping then return end
	stepping = true
	local ok, err = pcall(DoStep)
	stepping = false
	if not ok then
		Engine.Stop("error")
		geterrorhandler()(err)
	end
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

function Engine.Start(spec)
	if state ~= STATE_IDLE then return false end
	if type(spec) ~= "table" or type(spec.mails) ~= "table" then return false end
	if not MailFrameShown() then return false end
	if BlizzardOpenAllRunning() then
		ns.PrintError(L.OPEN_ALL_BUSY, true)
		return false
	end

	local numItems = GetInboxNumItems()
	local list, seen, sigs = {}, {}, {}
	for _, index in ipairs(spec.mails) do
		if type(index) == "number" and index >= 1 and index <= numItems and not seen[index] then
			seen[index] = true
			tinsert(list, index)
			sigs[index] = SigAt(index)
		end
	end
	if #list == 0 then return false end
	table.sort(list, function(a, b) return a > b end)

	-- No up-front bag-space refusal: a batch may need no bag space at all (pending-auction
	-- invoice deletions, money, text-only mails). The free-slot check right before each
	-- TakeInboxItem stops the run with "bagsfull" instead.
	job = {
		mails = list,
		sigs = sigs,
		mailPos = 1,
		pending = nil,
		lastCount = numItems,
		nextCommandAt = 0,      -- the pacing gate still waits for C_Mail.IsCommandPending()
		failedItemIDs = {},
		failedSlots = {},
		moneyFailed = {},
		deleted = {},
		gone = {},
		totalMoney = 0,
		deletePending = spec.deletePending and true or false,
		source = spec.source or "batch",
		marks = type(spec.marks) == "table" and spec.marks or nil,
	}
	state = STATE_RUNNING
	-- Mirror Blizzard's Open All (StartOpening/StopOpening). Semantics UNVERIFIED (plan §2.1).
	C_Mail.SetOpeningAll(true)
	ticker = C_Timer.NewTicker(TICK, Step)
	FireCallbacks("started", job.source)
	Step()
	return true
end

-- ---------------------------------------------------------------------------
-- Events (routed by Core through ns.Dispatch; no self argument)
-- ---------------------------------------------------------------------------

function Engine.MAIL_INBOX_UPDATE()
	Step()
end

-- MAIL_FAILED(itemID): itemID is nilable (MailInfoDocumentation). Also fires for send
-- failures, so it only counts while a take is pending.
function Engine.MAIL_FAILED(itemID)
	if state == STATE_IDLE or not job.pending then return end
	local p = job.pending
	if p.kind == "item" then
		local id = itemID or p.itemID
		if id then job.failedItemIDs[id] = true end
		job.failedSlots[p.mail .. ":" .. p.att] = true
	elseif p.kind == "money" then
		job.moneyFailed[p.mail] = true
	else
		job.deleted[p.mail] = true     -- do not retry the delete
	end
	job.pending = nil
	state = STATE_RUNNING
	Step()
end

-- CLOSE_INBOX_ITEM(mailID): the mail at mailID was removed. If it is the mail of the
-- pending command, that command is complete (the mail we emptied/deleted went away).
-- Otherwise, if it is the mail being processed, remember that so the index mismatch is not
-- mistaken for an inbox shift.
function Engine.CLOSE_INBOX_ITEM(mailID)
	if state == STATE_IDLE then return end
	local p = job.pending
	if p and mailID and mailID == p.mail then
		job.pending = nil
		state = STATE_RUNNING
		PendingDone(p, true)
		-- If the event precedes the inbox list update, hold the next command until the count
		-- drops, so that drop is not credited to the next command (bounded, see DoStep).
		if GetInboxNumItems() >= p.numItems then
			job.awaitDrop = { count = p.numItems, at = GetTime() }
		end
	elseif mailID and mailID == job.mails[job.mailPos] then
		job.gone[mailID] = true
	end
	Step()
end

function Engine.MAIL_CLOSED()
	Engine.Stop("closed")
end

-- Forever (and probably retail 12.2) only: the server cancelled an open-all run.
-- Registered through ns.RegisterEvent (pcall-safe) because live 12.1.5 does not know it.
function Engine.MAIL_OPEN_ALL_CANCELED()
	Engine.Stop("canceled")
end

function Engine.OnLogin()
	if not MailFrame then return end
	ns.RegisterEvent("MAIL_OPEN_ALL_CANCELED")
	MailFrame:HookScript("OnHide", function()
		Engine.Stop("closed")
	end)
	-- A left/right click on an inbox row cancels a run (I3). InboxFrame_OnClick is a global on
	-- both branches (live MailFrame.lua line 330, forever line 459). A right-click take starts
	-- its new run from the row's OnClick post-hook, which runs after this.
	hooksecurefunc("InboxFrame_OnClick", function()
		if Engine.IsRunning() then
			Engine.Stop("user")
		end
	end)
end

ns.RegisterModule("TakeEngine", Engine)
