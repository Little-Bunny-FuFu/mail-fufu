-- Mail-fufu: Compat.lua
-- Client-shape detection and hook helpers.
--
-- Retail 12.1.x ships the mail UI as global functions (InboxFrame_Update, OpenMail_Update);
-- the WoW Forever client (1.60.x, interface 16001) ships a mixin refactor of the same file
-- (InboxFrame:Update(), OpenMailFrame:Update(), unnamed page buttons). Every hook target is
-- resolved here by FEATURE DETECTION, never by build number (design plan §0.1 / §3.9).
-- Only hooksecurefunc is used: Blizzard functions are never replaced or wrapped.

local ADDON, ns = ...
local L = ns.L

local Compat = {}
ns.Compat = Compat

local function ReportMissing(what)
	-- Core loads after Compat; resolve the printer at call time.
	if ns.PrintError then
		ns.PrintError(format(L.HOOK_TARGET_MISSING, what), true)
	end
end

-- True when the mail UI is the mixin/parentKey shape (Forever 1.60, probably retail 12.2).
function Compat.HasMixinMail()
	return InboxFrame ~= nil and type(InboxFrame.Update) == "function"
end

-- Informational only (debug output). Never branch feature code on this.
function Compat.IsForever()
	return select(4, GetBuildInfo()) == 16001
end

-- Post-hook the inbox redraw on either client shape.
-- fn is called with NO arguments on both shapes (the mixin passes self; it is dropped so
-- callers see one signature). Returns true when a hook was installed.
function Compat.HookInboxUpdate(fn)
	if InboxFrame and type(InboxFrame.Update) == "function" then
		hooksecurefunc(InboxFrame, "Update", function() fn() end)
		return true
	elseif type(InboxFrame_Update) == "function" then
		hooksecurefunc("InboxFrame_Update", function() fn() end)
		return true
	end
	ReportMissing(L.HOOK_INBOX_UPDATE)
	return false
end

-- Post-hook the open-mail panel redraw on either client shape. fn gets NO arguments.
function Compat.HookOpenMailUpdate(fn)
	if OpenMailFrame and type(OpenMailFrame.Update) == "function" then
		hooksecurefunc(OpenMailFrame, "Update", function() fn() end)
		return true
	elseif type(OpenMail_Update) == "function" then
		hooksecurefunc("OpenMail_Update", function() fn() end)
		return true
	end
	ReportMissing(L.HOOK_OPENMAIL_UPDATE)
	return false
end

-- Storage key for per-realm data. What GetRealmName() returns on Forever is unverified
-- (print it with /mailfufu debug), hence the fallbacks.
function Compat.RealmKey()
	local realm = GetRealmName and GetRealmName()
	if not realm or realm == "" then
		realm = select(2, UnitFullName("player"))
	end
	if not realm or realm == "" then
		realm = "Unknown"
	end
	return realm
end

function Compat.FactionKey()
	local faction = UnitFactionGroup("player")
	if not faction or faction == "" then
		faction = "Neutral"
	end
	return faction
end

-- Register an event that may not exist on every client. The Forever client throws on an
-- unknown event name, so the call is wrapped in pcall. Returns true on success.
function Compat.SafeRegisterEvent(frame, event)
	local ok = pcall(frame.RegisterEvent, frame, event)
	return ok and true or false
end

function Compat.SafeUnregisterEvent(frame, event)
	local ok = pcall(frame.UnregisterEvent, frame, event)
	return ok and true or false
end

-- Forever with the gamepad UI hides some stock buttons (Open All); do not force-show them.
function Compat.IsGamepadUI()
	return InputUtil ~= nil and type(InputUtil.IsGamepadUIEnabled) == "function"
		and InputUtil.IsGamepadUIEnabled() and true or false
end

-- Trial / limited accounts: Blizzard hides the Send tab.
function Compat.IsLimitedMode()
	return type(GameLimitedMode_IsActive) == "function" and GameLimitedMode_IsActive() and true or false
end
